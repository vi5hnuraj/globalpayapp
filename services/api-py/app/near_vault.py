"""The NEAR vault, as the backend sees it.

`near-scanpay/` is the contract that now holds the money rules; this module is the only place the
backend talks to it. Two things live here:

* `NearVault` — the low-level calls and the exact command lines, so an operator can read what will be
  signed before it is signed (`complete_command` and friends are pure functions);
* `NearChainClient` — the same shape the settler already expects from an EVM `ChainClient`
  (`send`, `offramp_state`, `deadlines`, `chain_time`, `tx_url`), so the settlement loop does not need
  a second implementation of its own logic.

Reads go over the public RPC with no key. Writes are signed by `near-cli-rs`, which keeps the key in
its own keychain — the backend never holds a NEAR private key. A write that fails returns a warning and
a `ChainError`; it never half-succeeds, because a NEAR transaction either lands or does not.
"""

from __future__ import annotations

import asyncio
import base64
import json
from dataclasses import dataclass
from typing import Any

import httpx

from .chain import ChainError, Deadlines, OnchainOfframp, TxResult
from .near_receipts import NEAR_RPC, run_anchor

# The contract's enum order, translated to the numbers the store and the settler already understand.
STATUS_BY_NAME = {
    "Locked": 1,
    "Completed": 2,
    "Refunded": 3,
    "Reversed": 4,
    "Released": 5,
    "Disputed": 6,
}

# The EVM method names the settler uses, mapped to what the NEAR contract actually exposes.
METHOD_MAP = {
    "completeOfframp": "complete",
    "refundOfframp": "refund",
    "reverseOfframp": "resolve_dispute",
    "reclaimOfframp": "reclaim",
}


@dataclass
class NearWindows:
    completable_delay: int
    reclaim_after: int
    dispute_window: int
    dispute_timeout: int


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def lock_message(payee: str, inr_paise: int, payment_id: str) -> str:
    """The `msg` for `ft_transfer_call`: it is what turns a token transfer into an escrow lock."""
    return json.dumps({"id": str(payment_id), "payee": str(payee), "inr_paise": int(inr_paise)}, sort_keys=True)


def _cli(contract: str, method: str, args: dict[str, Any], account: str, near_cli: str, network: str) -> list[str]:
    return [
        near_cli,
        "contract",
        "call-function",
        "as-transaction",
        contract,
        method,
        "json-args",
        json.dumps(args, sort_keys=True),
        "prepaid-gas",
        "100 TeraGas",
        "attached-deposit",
        "0 NEAR",
        "sign-as",
        account,
        "network-config",
        network,
        "sign-with-keychain",
        "send",
    ]


class NearVault:
    """Read the vault, and build the commands that change it."""

    def __init__(
        self,
        contract: str,
        *,
        token: str = "",
        rpc_url: str = NEAR_RPC,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 8.0,
        near_cli: str = "near",
        account: str = "",
        network: str = "testnet",
    ) -> None:
        self.contract = contract
        self.token = token
        self.rpc_url = rpc_url
        self.near_cli = near_cli
        self.account = account
        self.network = network
        self._client = httpx.Client(transport=transport, timeout=timeout)

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> "NearVault":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    # ---- reads ----------------------------------------------------------------------------------

    def _view(self, method: str, args: dict[str, Any] | None = None) -> Any:
        payload = {
            "jsonrpc": "2.0",
            "id": "globalpay",
            "method": "query",
            "params": {
                "request_type": "call_function",
                "finality": "final",
                "account_id": self.contract,
                "method_name": method,
                "args_base64": _b64(json.dumps(args or {}).encode()),
            },
        }
        try:
            res = self._client.post(self.rpc_url, json=payload)
            res.raise_for_status()
            body = res.json()
        except httpx.HTTPError as e:
            raise ChainError("near_view", f"RPC unavailable: {e}") from e
        except ValueError as e:
            raise ChainError("near_view", f"RPC returned non-JSON: {e}") from e
        if isinstance(body.get("error"), dict):
            raise ChainError("near_view", str(body["error"].get("message") or body["error"]))
        result = body.get("result")
        if not isinstance(result, dict) or "result" not in result:
            raise ChainError("near_view", "RPC response had no result")
        raw = bytes(result["result"])
        return json.loads(raw.decode()) if raw else None

    def offramp(self, id_: str) -> dict[str, Any] | None:
        out = self._view("offramp", {"id": str(id_)})
        return out if isinstance(out, dict) else None

    def chain_time(self) -> int:
        payload = {"jsonrpc": "2.0", "id": "globalpay", "method": "block",
                   "params": {"finality": "final"}}
        try:
            res = self._client.post(self.rpc_url, json=payload)
            res.raise_for_status()
            header = res.json()["result"]["header"]
        except (httpx.HTTPError, ValueError, KeyError) as e:
            raise ChainError("near_time", f"could not read the block timestamp: {e}") from e
        # `timestamp` is nanoseconds in a JSON string; the rest of the backend works in seconds.
        return int(header["timestamp"]) // 1_000_000_000

    def windows(self) -> NearWindows:
        w = self._view("windows") or {}
        return NearWindows(
            completable_delay=int(w.get("completable_delay", 0)),
            reclaim_after=int(w.get("reclaim_after", 0)),
            dispute_window=int(w.get("dispute_window", 0)),
            dispute_timeout=int(w.get("dispute_timeout", 0)),
        )

    def is_anchored(self, digest: str) -> bool:
        return self._view("is_anchored", {"digest": str(digest)}) is True

    def receipt_count(self) -> int:
        out = self._view("receipt_count")
        return int(out) if isinstance(out, (int, float)) else 0

    def deadlines_of(self, id_: str) -> Deadlines | None:
        o = self.offramp(id_)
        if o is None:
            return None
        w = self.windows()
        return Deadlines(
            completable_at=int(o["completable_at"]),
            reclaimable_at=int(o["reclaimable_at"]),
            dispute_window=w.dispute_window,
            releasable_at=int(o.get("dispute_deadline") or 0) + w.dispute_timeout,
        )

    # ---- writes (shown, then run) ---------------------------------------------------------------

    def complete_command(self, id_: str, payout_ref: str, digest: str) -> list[str]:
        return _cli(self.contract, "complete",
                    {"id": id_, "payout_ref": payout_ref, "digest": digest},
                    self.account, self.near_cli, self.network)

    def refund_command(self, id_: str, reason: int) -> list[str]:
        return _cli(self.contract, "refund", {"id": id_, "reason": int(reason)},
                    self.account, self.near_cli, self.network)

    def reclaim_command(self, id_: str) -> list[str]:
        return _cli(self.contract, "reclaim", {"id": id_}, self.account, self.near_cli, self.network)

    def dispute_command(self, id_: str) -> list[str]:
        return _cli(self.contract, "dispute", {"id": id_}, self.account, self.near_cli, self.network)

    def resolve_command(self, id_: str, refund_payer: bool) -> list[str]:
        return _cli(self.contract, "resolve_dispute", {"id": id_, "refund_payer": bool(refund_payer)},
                    self.account, self.near_cli, self.network)

    def lock_command(self, *, amount: int, payee: str, inr_paise: int, payment_id: str) -> list[str]:
        """`ft_transfer_call` on the token: the payer's money and the lock arrive in one transaction."""
        if not self.token:
            raise ChainError("lock", "no token account configured")
        return [
            self.near_cli, "contract", "call-function", "as-transaction", self.token, "ft_transfer_call",
            "json-args",
            json.dumps({"receiver_id": self.contract, "amount": str(int(amount)),
                        "msg": lock_message(payee, inr_paise, payment_id)}, sort_keys=True),
            "prepaid-gas", "100 TeraGas", "attached-deposit", "1 yoctoNEAR",
            "sign-as", self.account, "network-config", self.network,
            "sign-with-keychain", "send",
        ]

    def run(self, command: list[str], *, timeout: float = 120.0) -> tuple[bool, str]:
        return run_anchor(command, timeout=timeout)


class NearChainClient:
    """The settler's view of the NEAR vault, matching the EVM client's methods.

    The settlement loop only needs these five calls, so the port is small: it reads state over RPC and
    signs through the CLI. Anything the EVM client offered that has no meaning here (logs, filters,
    permits) is deliberately absent rather than faked.
    """

    def __init__(self, vault: NearVault, *, chain: str = "near") -> None:
        self.vault = vault
        self.chain = chain

    @property
    def cfg(self) -> Any:
        return None  # no EVM chain config; present so callers can probe it

    async def chain_time(self) -> int:
        return await asyncio.to_thread(self.vault.chain_time)

    async def offramp_state(self, id_: str | bytes) -> OnchainOfframp:
        o = await asyncio.to_thread(self.vault.offramp, str(id_))
        if o is None:
            return OnchainOfframp(user="", amount=0, inr_paise=0, locked_at=0, completed_at=0, status=0,
                                  qr_commitment="")
        status = STATUS_BY_NAME.get(str(o.get("status")), 0)
        return OnchainOfframp(
            user=str(o.get("payer") or ""),
            amount=int(o.get("amount") or 0),
            inr_paise=int(o.get("inr_paise") or 0),
            locked_at=int(o.get("locked_at") or 0),
            completed_at=int(o.get("dispute_deadline") or 0),
            status=status,
            qr_commitment="",
        )

    async def deadlines(self, id_: str | bytes) -> Deadlines:
        d = await asyncio.to_thread(self.vault.deadlines_of, str(id_))
        if d is None:
            raise ChainError("deadlines", f"{id_} is not on the vault")
        return d

    async def send(self, account: Any, fn: str, args: tuple | list) -> TxResult:
        """Translate the settler's EVM call names into the NEAR contract's methods."""
        method = METHOD_MAP.get(fn)
        if method is None:
            raise ChainError(fn, f"the NEAR vault has no equivalent of {fn}")
        a = list(args)
        if fn == "completeOfframp":
            command = self.vault.complete_command(str(a[0]), str(a[1]), str(a[2]))
        elif fn == "refundOfframp":
            command = self.vault.refund_command(str(a[0]), int(a[1]))
        elif fn == "reverseOfframp":
            command = self.vault.resolve_command(str(a[0]), True)
        else:  # reclaimOfframp
            command = self.vault.reclaim_command(str(a[0]))
        ok, out = await asyncio.to_thread(self.vault.run, command)
        if not ok:
            raise ChainError(method, out or "the NEAR call failed")
        return TxResult(hash=tx_hash_of(out), block=0, gas_used=0)

    def tx_url(self, tx_hash: str) -> str:
        return f"https://testnet.nearblocks.io/txns/{tx_hash}"


def tx_hash_of(output: str) -> str:
    """near-cli-rs prints `Transaction ID: <hash>` among its box-drawing lines."""
    for line in (output or "").splitlines():
        if "Transaction ID:" in line:
            return line.split("Transaction ID:", 1)[1].strip().strip("│").strip()
    return ""
