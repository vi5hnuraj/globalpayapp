"""RazorpayX payout rail: what each vendor answer means for the user's escrow.

Nothing here touches the network: httpx.MockTransport stands in for RazorpayX, and the same
Outcome/exit-code mapping the production script uses is asserted directly.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from app.payout_runner import NEEDS_OPERATOR_PREFIX, PayoutRunner, run_black_box
from app.razorpayx import Outcome, RazorpayXClient, RazorpayXError

from .conftest import FakeSettler, QR, store_quote  # noqa: F401  (fixtures)
from .test_workers import locked_row, make_runner, PARSED

JOB = {"idempotencyKey": "0xabc", "offrampId": "0xabc", "upiId": "chaipoint@okaxis",
       "payeeName": "Chai Point", "inrPaise": 1000, "amountInr": "10.00"}


def client(handler) -> RazorpayXClient:
    return RazorpayXClient("rzp_test_key", "secret", "1234567890",
                           transport=httpx.MockTransport(handler))


def payout(status: str, utr: str | None = None) -> dict:
    body = {"id": "pout_123", "status": status, "amount": 1000, "currency": "INR"}
    if utr:
        body["utr"] = utr
    return body


def script(*responses: httpx.Response, seen: list | None = None):
    """A transport that answers create, then each poll, in order."""
    queue = list(responses)

    def handler(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append((request.method, request.url.path, request.headers.get("X-Payout-Idempotency")))
        return queue.pop(0) if queue else httpx.Response(500, json={"error": {"code": "boom"}})

    return handler


async def test_processed_with_utr_is_paid(monkeypatch):
    seen: list = []
    c = client(script(httpx.Response(200, json=payout("queued")), httpx.Response(200, json=payout("processed", "123456789012")), seen=seen))
    r = await c.pay(JOB, timeout_sec=5, poll_sec=0.01)
    assert r.outcome is Outcome.PAID and r.utr == "123456789012" and r.exit_code == 0
    await c.close()
    # The idempotency header is what stops a retry from paying the merchant twice.
    assert seen[0] == ("POST", "/v1/payouts", "0xabc")
    assert seen[1] == ("GET", "/v1/payouts/pout_123", None)


@pytest.mark.parametrize("status", ["failed", "rejected", "cancelled", "reversed"])
async def test_definitive_failure_is_refundable(status):
    c = client(script(httpx.Response(200, json=payout(status))))
    r = await c.pay(JOB, timeout_sec=1, poll_sec=0.01)
    await c.close()
    assert r.outcome is Outcome.FAILED and r.exit_code == 1


async def test_never_final_is_unknown_not_a_refund():
    c = client(script(httpx.Response(200, json=payout("queued"))))
    r = await c.pay(JOB, timeout_sec=0.05, poll_sec=0.01)
    await c.close()
    assert r.outcome is Outcome.UNKNOWN and r.exit_code == 2
    assert r.payout_id == "pout_123"


async def test_processed_without_utr_needs_a_human():
    c = client(script(httpx.Response(200, json=payout("processed"))))
    r = await c.pay(JOB, timeout_sec=1, poll_sec=0.01)
    await c.close()
    assert r.outcome is Outcome.UNKNOWN


async def test_4xx_on_create_fails_but_5xx_is_unknown():
    four = client(script(httpx.Response(400, json={"error": {"code": "BAD_REQUEST", "description": "bad vpa"}})))
    assert (await four.pay(JOB, timeout_sec=1)).outcome is Outcome.FAILED
    await four.close()
    five = client(script(httpx.Response(503, json={"error": {"code": "UNAVAILABLE"}})))
    assert (await five.pay(JOB, timeout_sec=1)).outcome is Outcome.UNKNOWN
    await five.close()


async def test_bad_job_is_refused_without_calling_the_api():
    calls: list = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, json=payout("processed", "x"))

    c = client(handler)
    assert (await c.pay({**JOB, "upiId": "not-a-vpa"})).outcome is Outcome.FAILED
    assert (await c.pay({**JOB, "inrPaise": 0})).outcome is Outcome.FAILED
    await c.close()
    assert calls == []


def test_missing_credentials_raise_without_leaking_them():
    with pytest.raises(RazorpayXError) as e:
        RazorpayXClient("", "SUPERSECRET123", "123")
    assert "SUPERSECRET123" not in str(e.value)


# ---- the runner's side of exit 2 --------------------------------------------------------------

class UnknownBox:
    def __init__(self, detail=f"{NEEDS_OPERATOR_PREFIX}: unknown outcome"):
        self.detail, self.calls = detail, 0

    async def __call__(self, cmd, job, timeout):
        self.calls += 1
        return False, self.detail, ""


async def test_ambiguous_payout_is_parked_not_refunded(store, chain, user):
    p = locked_row(store, chain, user.address)
    box = UnknownBox()
    settler = FakeSettler()
    runner = make_runner(store, settler, box)
    assert await runner.dispatch(p, PARSED) == "unknown"
    row = store.get_payment(p["id"])
    assert row["dispatch_state"] == "NEEDS_OPERATOR"
    assert row["pending_refund"] is None and settler.refunds == []
    # and it is never re-run
    assert await runner.dispatch(store.get_payment(p["id"]), PARSED) == "skipped"
    assert box.calls == 1


async def test_real_exit_code_two_is_reported_as_unknown():
    import sys
    cmd = f"{sys.executable} -c 'import sys; sys.stderr.write(\"ambiguous\\n\"); sys.exit(2)'"
    ok, detail, _ = await run_black_box(cmd, JOB, 10)
    assert ok is False and detail.startswith(NEEDS_OPERATOR_PREFIX)
