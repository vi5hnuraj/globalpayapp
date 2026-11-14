from __future__ import annotations

import json
from dataclasses import dataclass, field

import pytest

from app.near_payout import (
    NearPayoutService,
    NearWriteError,
    NearWriteResult,
    payout_commitment,
)
from app.store import Store


ID = "near-unit-test"
ACCOUNT = "payer.testnet"
UTR = "123456789012"
PAYOUT_ID = "pout_unit_test"


@dataclass
class FakeNear:
    locks: dict[str, dict] = field(default_factory=dict)

    async def lock(self, id_: str):
        value = self.locks.get(id_)
        return dict(value) if value else None


class FakeWriter:
    def __init__(self, near: FakeNear) -> None:
        self.near = near
        self.calls: list[str] = []
        self.fail_settlement = False

    async def start_payout(self, id_: str) -> NearWriteResult:
        self.calls.append("start")
        self.near.locks[id_]["status"] = "PayoutPending"
        return NearWriteResult("1" * 44)

    async def settle(self, id_: str, payout_ref: str) -> NearWriteResult:
        self.calls.append(f"settle:{payout_ref}")
        if self.fail_settlement:
            raise NearWriteError("settlement receipt failed")
        self.near.locks[id_]["status"] = "Settled"
        return NearWriteResult("2" * 44)

    async def refund(self, id_: str) -> NearWriteResult:
        self.calls.append("refund")
        self.near.locks[id_]["status"] = "Refunded"
        return NearWriteResult("3" * 44)


def seed() -> tuple[Store, FakeNear, FakeWriter]:
    store = Store()
    store.insert_near_quote({
        "id": ID,
        "account_id": ACCOUNT,
        "amount": "1000",
        "inr_paise": 100,
        "rate_e6": "100000000",
        "qr_text": "upi://pay?pa=merchant@okaxis&pn=Merchant&am=1&cu=INR",
        "upi_id": "merchant@okaxis",
        "payee_name": "Merchant",
        "view_token": "v" * 64,
        "deadline": 1800,
        "created_at": 1700,
    })
    store.record_near_payment({
        "id": ID,
        "account_id": ACCOUNT,
        "amount": "1000",
        "inr_paise": 100,
        "tx_hash": "4" * 44,
        "status": "Locked",
    })
    near = FakeNear({ID: {
        "id": ID,
        "payer": ACCOUNT,
        "amount": "1000",
        "locked_at": 1700,
        "status": "Locked",
    }})
    return store, near, FakeWriter(near)


def service(store, near, writer, black_box, *, rail="razorpayx", enabled=True):
    return NearPayoutService(
        store,
        near,
        writer,
        command="razorpayx",
        rail=rail,
        enabled=enabled,
        black_box=black_box,
        clock=lambda: 1701,
    )


async def paid_box(command, job, timeout):
    assert command == "razorpayx" and job["upiId"] == "merchant@okaxis"
    return True, "exit 0", json.dumps({"utr": UTR, "payoutId": PAYOUT_ID})


@pytest.mark.asyncio
async def test_paid_payout_settles_to_treasury_and_stores_only_a_commitment():
    store, near, writer = seed()
    result = await service(store, near, writer, paid_box).dispatch(ID)

    assert result == "settled"
    payment = store.get_near_payment(ID)
    expected = payout_commitment(json.dumps({"utr": UTR, "payoutId": PAYOUT_ID}), ID)
    assert payment["payout_state"] == "SETTLED"
    assert payment["status"] == "Settled"
    assert payment["payout_ref"] == expected
    assert payment["settlement_tx"] == "2" * 44
    assert near.locks[ID]["status"] == "Settled"
    assert writer.calls == ["start", f"settle:{expected}"]
    assert UTR not in json.dumps(payment) and PAYOUT_ID not in json.dumps(payment)


@pytest.mark.asyncio
async def test_claim_removes_cancellation_before_async_provider_work_starts():
    store, near, writer = seed()
    payout = service(store, near, writer, paid_box)

    assert payout.claim(ID) is True
    assert store.get_near_payment(ID)["payout_state"] == "FREEZING"
    assert writer.calls == []  # no chain/provider side effect in the synchronous HTTP path

    assert await payout.dispatch(ID) == "settled"
    assert writer.calls[0] == "start"


@pytest.mark.asyncio
async def test_definitive_provider_failure_refunds_the_frozen_escrow():
    async def failed_box(*_):
        return False, "exit 1 rejected", ""

    store, near, writer = seed()
    result = await service(store, near, writer, failed_box).dispatch(ID)

    assert result == "refunded"
    assert near.locks[ID]["status"] == "Refunded"
    assert store.get_near_payment(ID)["payout_state"] == "REFUNDED"
    assert writer.calls == ["start", "refund"]


@pytest.mark.asyncio
async def test_unknown_provider_outcome_stays_frozen_for_operator_review():
    async def unknown_box(*_):
        return False, "needs_operator: provider timed out", ""

    store, near, writer = seed()
    result = await service(store, near, writer, unknown_box).dispatch(ID)

    assert result == "unknown"
    assert near.locks[ID]["status"] == "PayoutPending"
    payment = store.get_near_payment(ID)
    assert payment["payout_state"] == "NEEDS_OPERATOR"
    assert writer.calls == ["start"]


@pytest.mark.asyncio
async def test_exit_zero_without_both_provider_fields_never_settles():
    async def incomplete_box(*_):
        return True, "exit 0", json.dumps({"utr": UTR})

    store, near, writer = seed()
    result = await service(store, near, writer, incomplete_box).dispatch(ID)

    assert result == "unknown"
    assert near.locks[ID]["status"] == "PayoutPending"
    assert store.get_near_payment(ID)["payout_state"] == "NEEDS_OPERATOR"
    assert writer.calls == ["start"]


@pytest.mark.asyncio
async def test_failed_treasury_transfer_remains_paid_and_is_never_refundable():
    store, near, writer = seed()
    writer.fail_settlement = True
    result = await service(store, near, writer, paid_box).dispatch(ID)

    assert result == "settlement_failed"
    assert near.locks[ID]["status"] == "PayoutPending"
    payment = store.get_near_payment(ID)
    assert payment["payout_state"] == "PAID"
    assert payment["payout_ref"]
    assert "refund" not in writer.calls


@pytest.mark.asyncio
async def test_stub_rail_cannot_freeze_pay_or_settle_even_if_enabled_flag_is_true():
    called = False

    async def stub_box(*_):
        nonlocal called
        called = True
        return True, "exit 0", json.dumps({"utr": UTR, "payoutId": PAYOUT_ID})

    store, near, writer = seed()
    payout = service(store, near, writer, stub_box, rail="stub", enabled=True)
    assert payout.enabled is False
    assert await payout.dispatch(ID) == "disabled"
    assert called is False
    assert writer.calls == []
    assert near.locks[ID]["status"] == "Locked"


@pytest.mark.asyncio
async def test_crash_during_provider_handoff_is_reviewed_not_retried_or_refunded():
    store, near, writer = seed()
    assert store.cas_near_payout(ID, "NONE", "FREEZING")
    assert store.cas_near_payout(ID, "FREEZING", "DISPATCHING")
    payout = service(store, near, writer, paid_box)

    actions = await payout.recover()

    assert actions == [f"{ID}:review"]
    assert store.get_near_payment(ID)["payout_state"] == "NEEDS_OPERATOR"
    assert writer.calls == []


def test_payout_commitment_is_domain_separated_and_needs_id_plus_utr():
    output = json.dumps({"utr": UTR, "payoutId": PAYOUT_ID})
    first = payout_commitment(output, ID)
    assert first and len(first) == 64 and int(first, 16) != 0
    assert payout_commitment(output, "another-id") != first
    assert payout_commitment(json.dumps({"utr": UTR}), ID) is None
    assert payout_commitment(json.dumps({"payoutId": PAYOUT_ID}), ID) is None
