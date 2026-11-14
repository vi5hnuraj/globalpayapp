#!/usr/bin/env python3
"""Prod payout rail (APP_ENV=prod, PAYOUT_RAIL=razorpayx): RazorpayX Payouts.

The contract, the same one dev_payout_stub.py and every PAYOUT_COMMAND follow:
  stdin   one JSON job: {idempotencyKey, offrampId, chain, upiId, payeeName, inrPaise, amountInr, lockTx}
  exit 0  only once the merchant is paid. RazorpayX payouts go queued -> processing -> processed,
          so wait for "processed" within the deadline; "accepted" is not "paid".
  stdout  a JSON line {"utr": "<bank UTR>"} so the onchain payoutRef is keccak256(utr)
  exit 1  definitively not paid (rejected, reversed, cancelled, failed) -> the caller may refund
  exit 2  unknown: the final state could not be learned, so the money may have moved. The caller
          must park the payment for a human and must NOT refund it automatically.

Keys come from the environment or the .env file (RAZORPAY_API_KEY, RAZORPAY_API_SECRET); never log them.
RAZORPAYX_ACCOUNT_NUMBER is the current account the payout leaves from.
RAZORPAYX_POLL_TIMEOUT_SEC keeps our own deadline inside the caller's PAYOUT_TIMEOUT_SEC kill timer,
so an ambiguous payout reports "unknown" instead of being killed (a kill would look like a failure).
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.keys import _lookup  # noqa: E402
from app.razorpayx import Outcome, RazorpayXClient, RazorpayXError  # noqa: E402

# The runner kills the command at PAYOUT_TIMEOUT_SEC (30 s by default). Answer before that.
DEFAULT_DEADLINE = 25.0


def _deadline() -> float:
    raw = os.environ.get("RAZORPAYX_POLL_TIMEOUT_SEC") or ""
    try:
        value = float(raw)
    except ValueError:
        value = 0.0
    if value > 0:
        return value
    # Leave a few seconds inside the caller's own timeout, which defaults to 30 s.
    try:
        outer = float(os.environ.get("PAYOUT_TIMEOUT_SEC") or 30)
    except ValueError:
        outer = 30.0
    return max(5.0, min(DEFAULT_DEADLINE, outer - 5.0))


def _env_file() -> str:
    """The same .env the backend reads, so the child sees the same keys without them being exported."""
    explicit = os.environ.get("GLOBALPAY_ENV_FILE") or os.environ.get("ENV_FILE") or os.environ.get("DOTENV_PATH")
    if explicit:
        return explicit
    return str(Path(__file__).resolve().parents[3] / ".env")  # repo root, next to README.md


def _env(name: str) -> str | None:
    return _lookup(name, _env_file())


def main() -> int:
    try:
        job = json.load(sys.stdin)
    except ValueError:
        print("[razorpayx] stdin is not a JSON job; nobody was paid", file=sys.stderr)
        return 1

    key_id = _env("RAZORPAY_API_KEY")
    key_secret = _env("RAZORPAY_API_SECRET")
    account = _env("RAZORPAYX_ACCOUNT_NUMBER")
    if not (key_id and key_secret and account):
        # Configuration is missing, so we cannot even ask: this is unknown, never a refund.
        print("[razorpayx] RAZORPAY_API_KEY, RAZORPAY_API_SECRET or RAZORPAYX_ACCOUNT_NUMBER "
              "is not set; no payout was attempted", file=sys.stderr)
        return 2

    async def run() -> int:
        client = RazorpayXClient(key_id, key_secret, account,
                                 base_url=os.environ.get("RAZORPAYX_API_BASE") or "https://api.razorpay.com/v1")
        try:
            result = await client.pay(job, timeout_sec=_deadline())
        except RazorpayXError as e:
            print(f"[razorpayx] {e}", file=sys.stderr)
            return 2
        finally:
            await client.close()

        if result.outcome is Outcome.PAID:
            print(json.dumps({"utr": result.utr, "payoutId": result.payout_id}))
            print(f"[razorpayx] paid {job.get('amountInr')} INR, utr {result.utr}", file=sys.stderr)
            return 0
        if result.outcome is Outcome.FAILED:
            print(f"[razorpayx] refused: {result.detail}", file=sys.stderr)
            return 1
        print(f"[razorpayx] unknown outcome, park for a human: {result.detail}", file=sys.stderr)
        return 2

    return asyncio.run(run())


if __name__ == "__main__":
    sys.exit(main())
