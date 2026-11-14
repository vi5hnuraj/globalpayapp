# GlobalPay NEAR escrow

This callback-safe NEP-141 vault is the crypto side of GlobalPay's **stablecoin in, INR or crypto
out** flow. It accepts one configured token through `ft_transfer_call`, prevents payer cancellation
before an off-chain payout starts, and transfers a paid escrow to the configured crypto treasury.

The contract does not call RazorpayX and does not know a UPI ID. Private merchant data and raw UTRs
remain in the backend. On-chain payout evidence is only a 32-byte lowercase-hex commitment.

## State machine

```text
Locked
  ├─ payer cancels before payout → RefundPending → Refunded
  │                                  └─ failed transfer → Locked
  └─ settler starts payout → PayoutPending
       ├─ provider definitively failed → RefundPending → Refunded
       │                                  └─ failed transfer → PayoutPending
       ├─ provider outcome unknown → PayoutPending (operator review; never auto-refund)
       └─ provider paid + evidence → SettlementPending → Settled (to treasury)
                                          └─ failed transfer → PayoutPending
```

`total_locked` is reduced only after the NEP-141 transfer receipt succeeds. A failed callback never
makes tokens simultaneously refundable and payable. Once `start_payout` succeeds, the payer cannot
refund; only the settler may refund after a definitive provider failure.

## Methods

| Method | Caller | Purpose |
|---|---|---|
| `new(owner, token, settler, treasury)` | deployer | Initialize one-token escrow |
| `migrate(treasury)` | existing owner/contract | Upgrade the former lock/refund layout without changing locks |
| `ft_on_transfer(sender_id, amount, msg)` | token | Accept `{ "id": "..." }` and create a lock |
| `request_refund(id)` | payer while `Locked`; settler while `Locked/PayoutPending` | Callback-safe refund |
| `start_payout(id)` | settler | Freeze payer cancellation before provider hand-off |
| `request_settlement(id, payout_ref)` | settler | Callback-safe transfer to treasury after verified payout |
| `get_lock`, `total_locked`, `payout_reference` | anyone | Public state and commitment views |
| role/configuration views and setters | owner/anyone as appropriate | Owner, token, settler and treasury configuration |

Payout commitments are unique, non-zero, 64-character lowercase hex strings. The backend computes
the deployed format as SHA-256 over canonical JSON containing a domain, escrow ID, provider payout ID
and UTR; only the hash reaches this contract.

## Test and build

```sh
cargo fmt -- --check
cargo test
cargo build --target wasm32-unknown-unknown --release
```

The 25 unit tests cover authorization, payer refund cutoff, definitive-failure refunds, unknown
outcomes, transfer callbacks, retries, duplicate payout evidence, terminal settlement, aggregate
accounting and migration of a pre-upgrade lock.

## Testnet deployment

Fresh install:

```sh
CONTRACT_ID=vault.globalpay-receipts.testnet \
TOKEN_ACCOUNT=usdc.fakes.testnet \
OWNER_ACCOUNT=globalpay-receipts.testnet \
SETTLER_ACCOUNT=globalpay-receipts.testnet \
TREASURY_ACCOUNT=treasury.globalpay-receipts.testnet \
  ./scripts/deploy-testnet.sh
```

An existing initialized contract is never changed implicitly. Upgrade the legacy lock/refund layout
only with `MODE=upgrade`; use `MODE=migrate` only to recover an interrupted deploy where the new WASM
landed but migration did not.

`usdc.fakes.testnet` currently reports `Bridged USDC`, symbol `USDC.e`, and six decimals. It is a
permissionless test asset—not production Circle USDC. Deployment and transaction evidence is in
`../deployments/near-testnet.json`.
