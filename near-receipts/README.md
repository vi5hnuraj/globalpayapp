# Receipts anchored on NEAR

A settled rupee payment has two parties who can disagree later. GlobalPay's vault says `COMPLETED`
when the stablecoin moved — that is not the same as the merchant being paid, and the bank reference
(UTR) that would prove it is private. So each settled payment gets a receipt, the receipt is hashed,
and **only the digest goes on NEAR**. A merchant, an auditor or a buyer can recompute the digest from
their own copy and ask the contract whether it was anchored, without publishing a UPI ID, a payee name
or a UTR.

The payments themselves settle in `near-scanpay`. The backend pays the merchant over the local rail
before it anchors the receipt, and the contract records only that a receipt was anchored.

## What is in here

| Path | What it is |
|---|---|
| `src/lib.rs` | The contract: an owner-managed anchor allow-list and one digest per payment. |
| `scripts/deploy-testnet.sh` | Build, create the account, deploy, allow the relayer to anchor. |
| `../services/api-py/app/near_receipts.py` | Receipt body, canonical digest, read-only RPC client, the anchor call. |
| `../services/api-py/tests/test_near_receipts.py` | 20 tests: digest stability, privacy, RPC parsing, the settler hook. |

## Try it without a chain

```sh
cd near-receipts && cargo test          # 14 contract tests, no network
cd ../services/api-py && uv run pytest tests/test_near_receipts.py -q   # 20 integration tests
```

Build the wasm (no `cargo-near` needed):

```sh
cargo build --target wasm32-unknown-unknown --release
# target/wasm32-unknown-unknown/release/globalpay_receipts.wasm
```

## Deployed on testnet

| | |
|---|---|
| Contract | `globalpay-receipts.testnet` (owner = the same account) |
| Anchor account | `globalpay-receipts.testnet` |
| First anchored receipt | `0xcdcd…cdcd`, digest `b3c1f7e6…8b7c2d`, verified with `is_anchored` |
| Deploy tx | `Gqy3ys7iStZNupBWAUTm4Q9pdokEc6C6huMsbiPNNKD` |

Verified live: `is_anchored(digest)` → `true`, `receipt(payment_id)` returns the record with
`utr_hash` (never the UTR), and a copy with one changed amount fails verification.

## Deploying to testnet

You need a logged-in `near` CLI (`npm install -g near-cli`, then `near login`) on a testnet account
with a few NEAR for storage. Nothing in this repo holds that key.

```sh
OWNER_ACCOUNT=you.testnet \
CONTRACT_ID=receipts.you.testnet \
ANCHOR_ACCOUNT=relayer.you.testnet \
  ./scripts/deploy-testnet.sh
```

Then set on the backend and restart it:

```sh
NEAR_RECEIPTS_CONTRACT=receipts.you.testnet
NEAR_ANCHOR_ACCOUNT=relayer.you.testnet     # the account near-cli is logged in as
```

With both set, every offramp the settler completes also anchors its receipt. **With either unset,
nothing changes** — the settler's `on_settled` hook is `None`, which is the default, so an existing
deployment behaves exactly as before.

## The contract

State: `owner`, an `anchors` list (max 8), `receipts: payment_id -> Receipt`, and a digest index.

| Method | Who | What |
|---|---|---|
| `new(owner)` | deploy | Sets the owner. |
| `add_anchor(account)` / `remove_anchor(account)` | owner | Who may anchor. Removing one takes effect immediately. |
| `anchor(payment_id, digest, chain, amount, utr_hash, paid_at)` | an anchor | Records one receipt. Rejects a duplicate payment id, a digest belonging to another payment, a non-64-hex digest, a raw (unhashed) UTR, and `paid_at = 0`. Emits NEP-297 `receipt_anchored`. |
| `receipt(payment_id)` | anyone | The stored receipt, or `null`. |
| `is_anchored(digest)` | anyone | The check that matters. |
| `receipt_count()` / `anchors()` / `owner()` | anyone | Bookkeeping. |

**A receipt is never replaced.** A second `anchor` for the same payment id panics rather than
overwriting, so what was recorded first is what stays. The tests cover that explicitly, because a
receipt you can quietly rewrite proves nothing.

### Why an allow-list

An open `anchor` would let anyone claim a payment id with a digest of their choosing, and the point of
anchoring is that a specific backend saw a specific settlement. Only accounts the owner added can
write. That also means the anchor is **only as truthful as the backend**: it records what GlobalPay
saw, not a proof that money moved. Nothing here should be read as a payment proof on its own — the
repo's rule is the same one that applies to `COMPLETED`.

## The digest

```
body   = {payment_id, offramp_id, chain, amount, inr_paise, utr_hash, paid_at[, vault]}
digest = sha256(json.dumps(body, sort_keys=True, separators=(",", "")))   # hex, 64 chars
```

`utr` is hashed on the way in (`sha256(utr)`), so a caller cannot accidentally anchor the reference
itself, and an empty UTR anchors as `""`, never `null`. The canonical form is fixed by test: key order
cannot change the digest, and any change to an amount, a time or a UTR does.

## Checking a receipt

```sh
near view receipts.you.testnet is_anchored '{"digest":"<64 hex>"}' --networkId testnet
near view receipts.you.testnet receipt '{"payment_id":"0x…"}' --networkId testnet
```

In Python, with the same body the merchant kept:

```python
from app.near_receipts import NearReceipts
NearReceipts("receipts.you.testnet").verifies(body)   # True once anchored
```

## What is not proven here

- **Not a payment proof.** The digest says "this backend recorded this settlement"; it does not move
  money and cannot prove a merchant's bank account was credited. That still needs the payout rail's
  own confirmation.
- **The anchor is best-effort.** If NEAR is unreachable, the settler logs a warning and the payment
  stays completed — a bookkeeping failure must never undo a payout. Such a receipt is simply
  unanchored, and re-anchoring it later is a decision for an operator, not automatic.
- **Not deployed by this repo.** Deploying needs an account and NEAR for storage, which is a human's
  job (`scripts/deploy-testnet.sh` prints exactly what it will do).
