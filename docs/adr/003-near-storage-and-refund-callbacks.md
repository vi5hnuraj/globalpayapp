# ADR 003: NEP-141 storage and callback-safe refunds

- **Status:** Accepted and deployed for the hackathon MVP
- **Date:** 2026-11-14

## Problem

NEAR cross-contract calls execute as separate receipts. Updating a lock to `Refunded` before
`ft_transfer` succeeds would produce false state. Likewise, panicking in a callback after tokens have
moved can leave accounting inconsistent.

The previous `near-scanpay.complete()` prototype transferred tokens before its dispute window and had
no callback. It was not deployed for the MVP and has been removed from the exported interface.

## Decision

The minimal escrow has three states:

```text
Locked -> RefundPending -> Refunded
              |
              +-- failed ft_transfer -> Locked
```

Rules:

1. A lock is created only by the configured token's `ft_on_transfer` callback.
2. The token amount is included in `total_locked` immediately after acceptance.
3. Only the payer or configured settler can request a refund.
4. `request_refund` changes the state to `RefundPending` but leaves `total_locked` unchanged.
5. The vault calls `ft_transfer` with one yoctoNEAR and chains a private callback.
6. The callback uses bounded `promise_result_checked`.
7. Success changes the state to `Refunded` and subtracts the amount exactly once.
8. Failure restores `Locked`, leaves accounting unchanged and permits retry.
9. A pending or refunded lock cannot start another concurrent refund.
10. The callback checks its predecessor explicitly and avoids deliberate panic paths after a transfer.

Both the payer and vault must be registered with the NEP-141 token. For `usdc.fakes.testnet`, each
registration requires 0.00125 NEAR.

## Verification

- 15 Rust unit tests cover lock validation, authorization, callback results, retry and accounting.
- Successful lock/refund: `73W2…2S7a` / `2WHh…tK4n`.
- A real failure was induced by unregistering the empty payer token account before refund:
  `574Q444RCD1oNeYVmDzHV7rN3WCqqeLkV2Kv6YGp2KfV`.
- The token receipt failed, callback returned false, state returned to `Locked`, and all accounting and
  tokens remained in the vault.
- After re-registration, retry `6UnQ…sTfvC` succeeded and final balances returned to 100/0 with
  `total_locked = 0`.

## Limitations

`near-sandbox` was not installed in the build environment. Promise success/failure is unit-tested and
both paths were exercised on real testnet, but no near-workspaces sandbox suite is claimed.
