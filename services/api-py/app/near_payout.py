"""Production-only NEAR escrow -> RazorpayX -> treasury orchestration.

The ordering is the money rule:

    Locked --on-chain freeze--> PayoutPending --RazorpayX PAID--> SettlementPending -> Settled
                                      |-- FAILED --> RefundPending -> Refunded
                                      |-- UNKNOWN --> PayoutPending (operator review; never refund)

The development stub is never accepted by this service. It is enabled only when the application is
explicitly configured for the production ``razorpayx`` rail. Raw UTRs and payout IDs are consumed in
memory and replaced with one SHA-256 commitment before anything is stored or sent on-chain.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import shlex
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable

from .payout_runner import NEEDS_OPERATOR_PREFIX, run_black_box
from .quote_math import format_paise
from .store import Store

log = logging.getLogger("globalpay.near-payout")

BlackBox = Callable[[str, dict, float], Awaitable[tuple[bool, str, str]]]
TX_RE = re.compile(r"Transaction ID:\s*([1-9A-HJ-NP-Za-km-z]{40,50})")


class NearWriteError(RuntimeError):
    def __init__(self, message: str, *, unknown: bool = False) -> None:
        super().__init__(message)
        self.unknown = unknown


@dataclass(frozen=True)
class NearWriteResult:
    tx_hash: str


class NearVaultWriter:
    """Build and execute the three settler calls through near-cli-rs's keychain."""

    def __init__(
        self,
        *,
        contract: str,
        account: str,
        near_cli: str = "near",
        network: str = "testnet",
        timeout: float = 120.0,
    ) -> None:
        self.contract = contract
        self.account = account
        self.near_cli = near_cli
        self.network = network
        self.timeout = timeout

    def command(self, method: str, args: dict[str, Any], *, gas_tgas: int) -> list[str]:
        return [
            *shlex.split(self.near_cli),
            "contract",
            "call-function",
            "as-transaction",
            self.contract,
            method,
            "json-args",
            json.dumps(args, sort_keys=True, separators=(",", ":")),
            "prepaid-gas",
            f"{gas_tgas} TeraGas",
            "attached-deposit",
            "0 NEAR",
            "sign-as",
            self.account,
            "network-config",
            self.network,
            "sign-with-keychain",
            "send",
        ]

    async def call(self, method: str, args: dict[str, Any], *, gas_tgas: int) -> NearWriteResult:
        try:
            proc = await asyncio.create_subprocess_exec(
                *self.command(method, args, gas_tgas=gas_tgas),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except (OSError, ValueError) as exc:
            raise NearWriteError(f"could not start near-cli: {type(exc).__name__}") from exc
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), self.timeout)
        except asyncio.TimeoutError as exc:
            proc.kill()
            await proc.wait()
            raise NearWriteError("near-cli timed out; transaction outcome is unknown", unknown=True) from exc
        text = stdout.decode(errors="replace")
        if proc.returncode != 0:
            tail = stderr.decode(errors="replace").strip().splitlines()[-1:] or [""]
            raise NearWriteError(f"near-cli failed: {tail[0][:300]}")
        match = TX_RE.search(text)
        if match is None:
            # A successful CLI exit without a transaction hash is not enough evidence to advance a
            # money state. The chain read in the caller may still reconcile it.
            raise NearWriteError("near-cli returned no transaction hash", unknown=True)
        return NearWriteResult(match.group(1))

    async def start_payout(self, id_: str) -> NearWriteResult:
        return await self.call("start_payout", {"id": id_}, gas_tgas=20)

    async def settle(self, id_: str, payout_ref: str) -> NearWriteResult:
        return await self.call(
            "request_settlement", {"id": id_, "payout_ref": payout_ref}, gas_tgas=60
        )

    async def refund(self, id_: str) -> NearWriteResult:
        return await self.call("request_refund", {"id": id_}, gas_tgas=60)


def payout_commitment(stdout: str, id_: str) -> str | None:
    """Commit to provider payout ID + UTR without persisting either private value."""
    for line in reversed((stdout or "").splitlines()):
        if not line.strip().startswith("{"):
            continue
        try:
            body = json.loads(line)
        except ValueError:
            continue
        payout_id = body.get("payoutId")
        utr = body.get("utr")
        if not (isinstance(payout_id, str) and payout_id.startswith("pout_")):
            return None
        if not (isinstance(utr, str) and utr.strip()):
            return None
        evidence = {
            "domain": "globalpay-near-payout-v1",
            "offrampId": id_,
            "payoutId": payout_id,
            "utr": utr.strip(),
        }
        encoded = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()
    return None


class NearPayoutService:
    def __init__(
        self,
        store: Store,
        near: Any,
        writer: NearVaultWriter,
        *,
        command: str,
        rail: str,
        enabled: bool = False,
        timeout_sec: float = 30.0,
        max_lock_age_sec: int = 600,
        black_box: BlackBox = run_black_box,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.store = store
        self.near = near
        self.writer = writer
        self.command = command
        self.rail = rail
        # A stub can exercise EVM demos, but it must never claim a NEAR merchant payment or release
        # escrow to treasury. Both the explicit gate and the production rail name must agree.
        self.enabled = bool(enabled and rail == "razorpayx")
        self.timeout_sec = timeout_sec
        self.max_lock_age_sec = max_lock_age_sec
        self.black_box = black_box
        self.clock = clock

    def claim(self, id_: str) -> bool:
        """Remove UI/API cancellation immediately; the async worker then freezes it on-chain."""
        return self.enabled and self.store.cas_near_payout(
            id_, "NONE", "FREEZING", "freezing payer refund before payout"
        )

    async def dispatch(self, id_: str) -> str:
        if not self.enabled:
            return "disabled"
        payment = self.store.get_near_payment(id_)
        quote = self.store.get_near_quote(id_)
        if payment is None or quote is None:
            return "missing"
        state = payment.get("payout_state") or "NONE"
        if state == "NONE":
            if not self.claim(id_):
                return "skipped"
        elif state != "FREEZING":
            return "skipped"

        try:
            lock = await self.near.lock(id_)
            if not lock or lock.get("status") not in ("Locked", "PayoutPending"):
                return self._unexpected(id_, "FREEZING", lock, "lock was not refundable before payout")
            locked_at = int(lock.get("locked_at") or 0)
            if locked_at and self.clock() - locked_at > self.max_lock_age_sec:
                self.store.cas_near_payout(
                    id_, "FREEZING", "NONE", f"lock older than {self.max_lock_age_sec}s; payout not started"
                )
                return "too_late"
            if lock.get("status") == "Locked":
                try:
                    await self.writer.start_payout(id_)
                except NearWriteError as exc:
                    if exc.unknown:
                        self.store.update_near_payment(id_, payout_detail=str(exc)[:500])
                        return "freeze_unknown"
                    lock = await self.near.lock(id_)
                    if not lock or lock.get("status") != "PayoutPending":
                        self.store.cas_near_payout(id_, "FREEZING", "NONE", str(exc)[:500])
                        return "freeze_failed"
            lock = await self.near.lock(id_)
            if not lock or lock.get("status") != "PayoutPending":
                return self._unexpected(id_, "FREEZING", lock, "payout freeze did not finalize")
        except Exception as exc:
            self.store.update_near_payment(id_, payout_detail=f"freeze check failed: {type(exc).__name__}"[:500])
            return "freeze_unknown"

        if not self.store.cas_near_payout(
            id_,
            "FREEZING",
            "DISPATCHING",
            "handing frozen payment to RazorpayX",
            payout_started_at=int(self.clock()),
        ):
            return "skipped"
        return await self._run_provider(payment, quote)

    async def _run_provider(self, payment: dict, quote: dict) -> str:
        id_ = payment["id"]
        inr_paise = int(payment["inr_paise"])
        job = {
            "idempotencyKey": id_,
            "offrampId": id_,
            "chain": "near",
            "upiId": quote["upi_id"],
            "payeeName": quote.get("payee_name"),
            "inrPaise": inr_paise,
            "amountInr": format_paise(inr_paise),
            "lockTx": payment["tx_hash"],
        }
        ok, detail, stdout = await self.black_box(self.command, job, self.timeout_sec)
        if ok:
            payout_ref = payout_commitment(stdout, id_)
            if payout_ref is None:
                self.store.cas_near_payout(
                    id_, "DISPATCHING", "NEEDS_OPERATOR", "paid exit lacked payout ID + UTR evidence"
                )
                return "unknown"
            if not self.store.cas_near_payout(
                id_, "DISPATCHING", "PAID", detail[:500], payout_ref=payout_ref
            ):
                return "skipped"
            return await self._settle(id_)

        if detail.startswith(NEEDS_OPERATOR_PREFIX):
            self.store.cas_near_payout(id_, "DISPATCHING", "NEEDS_OPERATOR", detail[:500])
            return "unknown"

        # Only an explicit provider exit 1 or a failure to spawn reaches this branch. A timeout or
        # unexpected process exit is mapped to NEEDS_OPERATOR by run_black_box.
        if self.store.cas_near_payout(id_, "DISPATCHING", "FAILED", detail[:500]):
            return await self._refund(id_)
        return "skipped"

    async def _settle(self, id_: str) -> str:
        payment = self.store.get_near_payment(id_)
        if not payment or not payment.get("payout_ref"):
            return "missing_evidence"
        if not self.store.cas_near_payout(id_, "PAID", "SETTLING", "moving escrow to treasury"):
            return "skipped"
        tx_hash: str | None = None
        try:
            result = await self.writer.settle(id_, payment["payout_ref"])
            tx_hash = result.tx_hash
        except NearWriteError as exc:
            self.store.update_near_payment(id_, payout_detail=str(exc)[:500])
            if exc.unknown:
                return "settlement_unknown"
        try:
            lock = await self.near.lock(id_)
        except Exception:
            return "settlement_unknown"
        status = (lock or {}).get("status")
        if status == "Settled":
            self.store.cas_near_payout(
                id_,
                "SETTLING",
                "SETTLED",
                "RazorpayX paid; escrow settled to treasury",
                settlement_tx=tx_hash,
                settled_at=int(self.clock()),
            )
            self.store.update_near_payment(id_, "Settled")
            return "settled"
        if status == "PayoutPending":
            # A known failed chain transaction is retryable; the provider is already paid, so this
            # returns to PAID, never to a refundable state.
            self.store.cas_near_payout(id_, "SETTLING", "PAID", "treasury transfer failed; retry required")
            return "settlement_failed"
        return "settlement_unknown"

    async def _refund(self, id_: str) -> str:
        if not self.store.cas_near_payout(id_, "FAILED", "REFUNDING", "definitive payout failure; refunding"):
            return "skipped"
        tx_hash: str | None = None
        try:
            result = await self.writer.refund(id_)
            tx_hash = result.tx_hash
        except NearWriteError as exc:
            self.store.update_near_payment(id_, payout_detail=str(exc)[:500])
            if exc.unknown:
                return "refund_unknown"
        try:
            lock = await self.near.lock(id_)
        except Exception:
            return "refund_unknown"
        status = (lock or {}).get("status")
        if status == "Refunded":
            self.store.cas_near_payout(
                id_, "REFUNDING", "REFUNDED", "definitive payout failure; escrow refunded", refund_tx=tx_hash
            )
            self.store.update_near_payment(id_, "Refunded")
            return "refunded"
        if status == "PayoutPending":
            self.store.cas_near_payout(id_, "REFUNDING", "FAILED", "refund transfer failed; retry required")
            return "refund_failed"
        return "refund_unknown"

    async def reconcile(self, id_: str) -> str:
        """Read-only chain reconciliation for UI polling; it never starts or retries a payout."""
        payment = self.store.get_near_payment(id_)
        if payment is None:
            return "missing"
        try:
            lock = await self.near.lock(id_)
        except Exception:
            return "unavailable"
        status = (lock or {}).get("status")
        state = payment.get("payout_state") or "NONE"
        if status == "Settled" and state in ("PAID", "SETTLING"):
            self.store.cas_near_payout(
                id_, state, "SETTLED", "RazorpayX paid; escrow settled to treasury", settled_at=int(self.clock())
            )
            self.store.update_near_payment(id_, "Settled")
            return "settled"
        if status == "Refunded" and state in ("FAILED", "REFUNDING"):
            self.store.cas_near_payout(id_, state, "REFUNDED", "escrow refund finalized")
            self.store.update_near_payment(id_, "Refunded")
            return "refunded"
        return "unchanged"

    async def recover(self) -> list[str]:
        """Conservatively recover crash states without ever repeating an ambiguous provider call."""
        actions: list[str] = []
        for payment in self.store.near_payments_where(("DISPATCHING",)):
            if self.store.cas_near_payout(
                payment["id"],
                "DISPATCHING",
                "NEEDS_OPERATOR",
                "crashed during RazorpayX hand-off; merchant may be paid; never auto-refund or re-run",
            ):
                actions.append(f"{payment['id']}:review")
        for payment in self.store.near_payments_where(("PAID",)):
            actions.append(f"{payment['id']}:{await self._settle(payment['id'])}")
        for payment in self.store.near_payments_where(("FAILED",)):
            actions.append(f"{payment['id']}:{await self._refund(payment['id'])}")
        # FREEZING is before provider hand-off and is safe to resume: DISPATCHING is durably written
        # before the provider command can run. SETTLING/REFUNDING only reconcile terminal outcomes.
        for payment in self.store.near_payments_where(("FREEZING",)):
            actions.append(f"{payment['id']}:{await self.dispatch(payment['id'])}")
        for payment in self.store.near_payments_where(("SETTLING", "REFUNDING")):
            actions.append(f"{payment['id']}:{await self.reconcile(payment['id'])}")
        return actions

    def _unexpected(self, id_: str, from_state: str, lock: dict | None, detail: str) -> str:
        status = (lock or {}).get("status") or "missing"
        self.store.cas_near_payout(
            id_, from_state, "NEEDS_OPERATOR", f"{detail}; on-chain status {status}"[:500]
        )
        return "review"
