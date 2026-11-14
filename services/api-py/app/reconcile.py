"""Operator view: the payments that did not finish cleanly, and why.

Every row here is one a human should look at. Nothing in this module changes state — it only reads —
so calling it can never pay, refund or complete anything.

Why each bucket exists:

  ambiguous_payout    The rail could not say whether the merchant was paid. The escrow is still
                      locked and must NOT be refunded automatically: refunding could pay the
                      merchant and return the user's money. Reconcile against the provider using the
                      offramp id, which is also the payout's idempotency key.
  crashed_dispatch    The process died between the CAS to DISPATCHING and recording a result. Same
                      problem as above, caught by age rather than by the park flag.
  refund_pending      A refund is owed but has not reached the chain; the settler loop retries.
  completion_pending  The rail reported success but `completeOfframp` has not landed. The escrow is
                      still locked, so the merchant may be paid while the vault says LOCKED.
  dispute_relaying    A dispute was claimed but never recorded as relayed.
  dispute_failed      Relaying the dispute failed; the user's report needs attention.
  onramp_stale        An onramp order has been waiting for fiat for over a day.
"""

from __future__ import annotations

import time
from typing import Any

DEFAULT_STALE_SEC = 600
ONRAMP_STALE_SEC = 86_400
COMPLETION_STALE_SEC = 3_600


def _age(now: int, ts: Any) -> int | None:
    try:
        value = int(ts or 0)
    except (TypeError, ValueError):
        return None
    return max(0, now - value) if value else None


def reconcile_report(store: Any, *, now: int | None = None,
                     stale_after_sec: int = DEFAULT_STALE_SEC) -> dict:
    """Read-only. Returns {"generatedAt", "total", "counts", "items"} with the oldest first."""
    t = int(now if now is not None else time.time())
    items: list[dict] = []

    def add(kind: str, row: dict, detail: str, *, refundable: bool, age: int | None) -> None:
        items.append({
            "kind": kind,
            "id": row.get("id"),
            "chain": row.get("chain"),
            "status": row.get("status"),
            "dispatch": row.get("dispatch_state"),
            "refundable": refundable,
            "ageSec": age,
            "detail": detail,
        })

    # 1. The rail's answer was (or may have been) lost. Never refund these automatically.
    for p in store.payments_where(dispatch=["NEEDS_OPERATOR"]):
        add("ambiguous_payout", p,
            "the payout rail could not confirm the merchant result; check the provider for this "
            "offramp id (its idempotency key) before refunding",
            refundable=False, age=_age(t, p.get("dispatch_started_at") or p.get("updated_at")))
    for p in store.payments_where(dispatch=["DISPATCHING"]):
        age = _age(t, p.get("dispatch_started_at"))
        if age is not None and age > stale_after_sec:
            add("crashed_dispatch", p,
                "handed to the payout rail but no result was ever recorded; the provider may have "
                "paid, so check before refunding",
                refundable=False, age=age)

    # 2. A refund is owed but has not landed.
    for p in store.pending_refunds():
        age = _age(t, p.get("updated_at"))
        if age is not None and age > stale_after_sec:
            add("refund_pending", p,
                f"refund reason {p.get('refund_reason')} has not reached the chain; the settler "
                "loop retries, so check the refund's revert reason",
                refundable=True, age=age)

    # 3. The rail says paid, the chain still says locked.
    for p in store.payments_where(statuses=["LOCKED"], dispatch=["DISPATCHED"]):
        age = _age(t, p.get("dispatched_at"))
        if age is not None and age > max(stale_after_sec * 4, COMPLETION_STALE_SEC):
            add("completion_pending", p,
                "the rail reports the merchant paid but completeOfframp has not landed, so the "
                "escrow is still LOCKED",
                refundable=False, age=age)

    # 4. Disputes stuck in flight.
    for d in store.list_disputes(statuses=["RELAYING"]):
        age = _age(t, d.get("updated_at"))
        if age is not None and age > stale_after_sec:
            add("dispute_relaying", d,
                "a dispute was claimed but never recorded as relayed; the user's report is "
                "unresolved",
                refundable=False, age=age)
    for d in store.list_disputes(statuses=["FAILED"]):
        add("dispute_failed", d,
            f"relaying the dispute failed ({d.get('error') or 'no reason recorded'}); the user "
            "still has no resolution",
            refundable=False, age=_age(t, d.get("updated_at")))

    # 5. An onramp nobody finished paying.
    for o in store.onramps_by_status("AWAITING_FIAT"):
        age = _age(t, o.get("created_at"))
        if age is not None and age > ONRAMP_STALE_SEC:
            add("onramp_stale", o,
                "an onramp order has waited for fiat for over a day; expire it or confirm the "
                "payment by hand",
                refundable=False, age=age)

    counts: dict[str, int] = {}
    for item in items:
        counts[item["kind"]] = counts.get(item["kind"], 0) + 1
    items.sort(key=lambda i: -(i["ageSec"] or 0))
    return {"generatedAt": t, "total": len(items), "counts": dict(sorted(counts.items())),
            "items": items}
