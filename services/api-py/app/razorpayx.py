"""RazorpayX Payouts: the production payout rail (APP_ENV=prod, PAYOUT_RAIL=razorpayx).

One job in, one answer out. The contract is the same one every PAYOUT_COMMAND follows: the caller
hands us {idempotencyKey, offrampId, upiId, payeeName, inrPaise, ...} and only an exit 0 means the
merchant's bank has the money.

Outcomes:

  PAID      RazorpayX says `processed`; we have the bank UTR.
  FAILED    RazorpayX says `failed`, `rejected`, `cancelled` or `reversed`; nobody was paid, so the
            caller may refund the user's escrow.
  UNKNOWN   We could not learn the final state (timeout, network, 5xx, a status we do not know).
            The money may or may not have moved, so the row must go to a human and must NOT be
            refunded automatically.

Idempotency: every payout is sent with `X-Payout-Idempotency: <idempotencyKey>`, so a retried job
returns the original payout instead of paying the merchant twice. The UPI fund account is created
with a `reference_id` derived from the VPA, so repeated payouts to one merchant reuse it.

Keys come from the environment or the .env file (app/keys.py); nothing here logs them.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from enum import Enum
from typing import Any

import httpx

PAYOUTS_BASE = "https://api.razorpay.com/v1"

# Statuses RazorpayX documents for a payout, grouped by what they mean for us.
PAID_STATUSES = frozenset({"processed"})
FAILED_STATUSES = frozenset({"failed", "rejected", "cancelled", "reversed"})
PENDING_STATUSES = frozenset({"created", "initiated", "queued", "processing", "pending", "scheduled",
                              "retried", "on_hold", "held"})


class Outcome(str, Enum):
    PAID = "paid"
    FAILED = "failed"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class PayoutResult:
    outcome: Outcome
    detail: str
    utr: str | None = None
    payout_id: str | None = None

    @property
    def exit_code(self) -> int:
        """0 paid, 1 definitively not paid, 2 unknown (do not refund)."""
        return {Outcome.PAID: 0, Outcome.FAILED: 1, Outcome.UNKNOWN: 2}[self.outcome]


class RazorpayXError(RuntimeError):
    """A RazorpayX call failed. The message never contains key material."""


def _clean(value: Any) -> str:
    """RazorpayX rejects characters it does not recognise in names and narrations."""
    return " ".join(str(value or "").split())[:50] or "GlobalPay"


class RazorpayXClient:
    """The payouts API, with an injectable transport so tests never touch the network."""

    def __init__(self, key_id: str, key_secret: str, account_number: str, *,
                 base_url: str = PAYOUTS_BASE, timeout: float = 20.0,
                 transport: httpx.AsyncBaseTransport | None = None) -> None:
        if not (key_id and key_secret and account_number):
            raise RazorpayXError("RazorpayX needs an API key, secret and payout account number")
        self.account_number = account_number
        self._http = httpx.AsyncClient(base_url=base_url, auth=(key_id, key_secret),
                                       timeout=timeout, transport=transport)

    async def close(self) -> None:
        await self._http.aclose()

    async def _request(self, method: str, path: str, **kw: Any) -> dict:
        try:
            r = await self._http.request(method, path, **kw)
        except httpx.HTTPError as e:
            raise RazorpayXError(f"{method} {path}: {type(e).__name__}") from None
        if r.status_code >= 400:
            try:
                err = r.json().get("error") or {}
            except ValueError:
                err = {}
            raise RazorpayXError(f"{method} {path}: HTTP {r.status_code} "
                                 f"{err.get('code', '')} {err.get('description', '')}".strip())
        try:
            return r.json()
        except ValueError:
            raise RazorpayXError(f"{method} {path}: reply is not JSON") from None

    async def _payout(self, idempotency_key: str, upi_id: str, payee_name: str,
                      inr_paise: int, reference: str) -> dict:
        body = {
            "account_number": self.account_number,
            "amount": int(inr_paise),
            "currency": "INR",
            "mode": "UPI",
            "purpose": "payout",
            "queue_if_low_balance": True,
            "reference_id": reference,
            "narration": "GlobalPay",
            # Inline contact + fund account: RazorpayX dedupes on reference_id, so a retry does not
            # create a second merchant identity.
            "contact": {
                "name": _clean(payee_name),
                "type": "customer",
                "reference_id": f"rr-{reference}"[:40],
            },
            "fund_account": {
                "account_type": "vpa",
                "vpa": {"address": upi_id},
                "contact": {
                    "name": _clean(payee_name),
                    "type": "customer",
                    "reference_id": f"rr-{reference}"[:40],
                },
            },
        }
        return await self._request("POST", "/payouts", json=body,
                                   headers={"X-Payout-Idempotency": idempotency_key})

    async def pay(self, job: dict[str, Any], *, timeout_sec: float = 45.0,
                  poll_sec: float = 1.5, clock=time.monotonic) -> PayoutResult:
        """Submits the payout and waits for a final status. Never raises for a vendor failure."""
        idempotency_key = str(job.get("idempotencyKey") or job.get("offrampId") or "")
        offramp_id = str(job.get("offrampId") or idempotency_key)
        upi_id = str(job.get("upiId") or "").strip()
        payee_name = str(job.get("payeeName") or upi_id or "UPI merchant")
        try:
            inr_paise = int(job["inrPaise"])
        except (KeyError, TypeError, ValueError):
            return PayoutResult(Outcome.FAILED, "job has no usable inrPaise")
        if not idempotency_key:
            return PayoutResult(Outcome.FAILED, "job has no idempotency key")
        if "@" not in upi_id or len(upi_id) > 255:
            return PayoutResult(Outcome.FAILED, "job has no usable UPI id")
        if inr_paise <= 0:
            return PayoutResult(Outcome.FAILED, "job has a non-positive amount")

        try:
            created = await self._payout(idempotency_key, upi_id, payee_name, inr_paise, offramp_id)
        except RazorpayXError as e:
            # Nothing was accepted: a 4xx means the request will never work, so it is a definite
            # failure. Anything else (5xx, network) may have created the payout, so it is unknown.
            text = str(e)
            if "HTTP 4" in text and "HTTP 5" not in text:
                return PayoutResult(Outcome.FAILED, text)
            return PayoutResult(Outcome.UNKNOWN, text)

        payout_id = created.get("id")
        if not isinstance(payout_id, str) or not payout_id.startswith("pout_"):
            return PayoutResult(Outcome.UNKNOWN, "RazorpayX accepted the request without a payout id")
        result = self._classify(created, payout_id)
        if result.outcome is not Outcome.UNKNOWN:
            return result

        deadline = clock() + timeout_sec
        while clock() < deadline:
            await asyncio.sleep(poll_sec)
            try:
                fetched = await self._request("GET", f"/payouts/{payout_id}")
            except RazorpayXError as e:
                # Keep trying until the deadline; a blip is not a verdict.
                result = PayoutResult(Outcome.UNKNOWN, str(e), payout_id=payout_id)
                continue
            result = self._classify(fetched, payout_id)
            if result.outcome is not Outcome.UNKNOWN:
                return result
        return PayoutResult(Outcome.UNKNOWN,
                            f"no final status within {timeout_sec:g}s (last: {result.detail})",
                            payout_id=payout_id)

    @staticmethod
    def _classify(payout: dict, payout_id: str) -> PayoutResult:
        status = str(payout.get("status") or "").lower()
        utr = payout.get("utr")
        utr = utr.strip() if isinstance(utr, str) else None
        if status in PAID_STATUSES:
            if not utr:
                # "processed" with no UTR cannot prove a bank credit, so it needs a human.
                return PayoutResult(Outcome.UNKNOWN, "processed without a UTR", payout_id=payout_id)
            return PayoutResult(Outcome.PAID, f"processed ({utr})", utr=utr, payout_id=payout_id)
        if status in FAILED_STATUSES:
            reason = payout.get("failure_reason") or payout.get("status_details") or status
            return PayoutResult(Outcome.FAILED, f"{status}: {reason}", payout_id=payout_id)
        return PayoutResult(Outcome.UNKNOWN, f"status {status or 'missing'}",
                            payout_id=payout_id)
