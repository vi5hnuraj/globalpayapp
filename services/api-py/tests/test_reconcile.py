"""The operator report: it must surface the payments a human has to settle, and never refund them.

Every test drives the store into a state the worker loops can leave behind, then asserts the row is
reported with the right advice. The report is read-only, so none of these change the payments.
"""

from __future__ import annotations

import time

from app.reconcile import reconcile_report

from .test_workers import ID, locked_row

ONRAMP = "0x" + "d4" * 32
NOW = int(time.time())


def kinds(report: dict) -> list[str]:
    return [item["kind"] for item in report["items"]]


def test_a_clean_database_reports_nothing(store):
    report = reconcile_report(store)
    assert report["total"] == 0 and report["counts"] == {} and report["items"] == []


def test_ambiguous_payout_is_reported_and_never_refundable(store, chain, user):
    locked_row(store, chain, user.address)
    assert store.cas_dispatch(ID, "NONE", "DISPATCHING")
    assert store.cas_dispatch(ID, "DISPATCHING", "NEEDS_OPERATOR", "rail could not confirm")
    report = reconcile_report(store)
    assert kinds(report) == ["ambiguous_payout"]
    item = report["items"][0]
    assert item["id"] == ID and item["refundable"] is False
    assert "idempotency" in item["detail"]


def test_crashed_dispatch_is_reported_only_once_it_is_old(store, chain, user):
    locked_row(store, chain, user.address)
    assert store.cas_dispatch(ID, "NONE", "DISPATCHING", dispatch_started_at=NOW)
    assert kinds(reconcile_report(store)) == []  # just handed off: it may still be mid-call
    report = reconcile_report(store, now=NOW + 5_000, stale_after_sec=600)
    assert kinds(report) == ["crashed_dispatch"] and report["items"][0]["ageSec"] == 5_000


def test_refund_that_never_landed_is_reported(store, chain, user):
    locked_row(store, chain, user.address)
    assert store.cas_dispatch(ID, "NONE", "DISPATCHING")
    assert store.cas_dispatch(ID, "DISPATCHING", "FAILED", "rail said no", pending_refund=3)
    report = reconcile_report(store, now=NOW + 5_000, stale_after_sec=600)
    assert kinds(report) == ["refund_pending"]
    assert report["items"][0]["refundable"] is True


def test_paid_but_still_locked_is_reported(store, chain, user):
    locked_row(store, chain, user.address)
    assert store.cas_dispatch(ID, "NONE", "DISPATCHING")
    assert store.cas_dispatch(ID, "DISPATCHING", "DISPATCHED", "exit 0", dispatched_at=NOW - 7_200)
    report = reconcile_report(store)
    assert kinds(report) == ["completion_pending"]


def test_both_dispute_problems_are_reported(store):
    store.begin_dispute({"id": ID, "chain": "local", "user": "0x" + "11" * 20,
                         "deadline": NOW + 300, "user_sig": "0xdead"})
    store.finish_dispute(ID, "FAILED", error="relaying reverted")
    report = reconcile_report(store)
    assert kinds(report) == ["dispute_failed"]
    assert "reverted" in report["items"][0]["detail"]


def test_a_day_old_onramp_is_reported(store):
    store.insert_onramp({"id": ONRAMP, "chain": "local", "wallet": "0x" + "22" * 20,
                         "inr_paise": 50_000, "amount": "5000000", "rate_e6": "100000000",
                         "status": "AWAITING_FIAT"})
    assert kinds(reconcile_report(store)) == []  # fresh: the user may still be paying
    report = reconcile_report(store, now=NOW + 2 * 86_400)
    assert kinds(report) == ["onramp_stale"]


def test_the_report_is_ordered_oldest_first(store, chain, user):
    locked_row(store, chain, user.address)
    assert store.cas_dispatch(ID, "NONE", "DISPATCHING", dispatch_started_at=NOW - 60)
    assert store.cas_dispatch(ID, "DISPATCHING", "NEEDS_OPERATOR")
    store.begin_dispute({"id": "0x" + "33" * 32, "chain": "local", "user": "0x" + "44" * 20,
                         "deadline": NOW + 300, "user_sig": "0xbeef"})
    store.finish_dispute("0x" + "33" * 32, "FAILED", error="x")
    report = reconcile_report(store)
    # oldest first: the payout has been parked for a minute, the dispute only just failed
    assert [i["kind"] for i in report["items"]] == ["ambiguous_payout", "dispute_failed"]
    assert report["counts"] == {"ambiguous_payout": 1, "dispute_failed": 1}
