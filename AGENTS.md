# GlobalPay

Scan a local payment QR and pay it from a stablecoin wallet with no gas; the merchant is paid ordinary
local currency. The escrow and receipts are NEAR contracts (`near-scanpay/`, `near-receipts/`) on
testnet, and the Flutter app signs native NEAR transactions with an Ed25519 key held in Android
Keystore behind biometrics. UPI/INR is the implemented reference corridor, not the product boundary:
a new corridor adds a QR parser and a payout adapter. Current progress is in `docs/status.md`.

## Rules that can cost money

- **A real payout spends real money.** No live provider may be enabled without an explicit
  `APP_ENV=prod`, `NEAR_PAYOUTS=1`, funded settler account and an operator watching the first payment.
- **Never refund an unknown payout.** A provider timeout or 5xx means the merchant may already have
  been paid. Park the row for a human; only a definite failure may move escrow back to the payer.
- **Never run `services/api-py` with its workers on against the deployed vault unless it is the
  deployed instance.** The listener refunds any `LOCKED` lock missing from its own database, so a second
  backend can cancel live payments. Use `WORKERS=0` or a dry run.
- **Keep the deployed payout rail on the stub** unless the phone payer is stopped. Two independent
  payers can pay the merchant twice.
- **The NEAR contracts are the live money path.** `near-scanpay/` and `near-receipts/` are the contracts
  the product uses; a change means passing their `cargo test` suites and deploying a fresh testnet
  build. `contracts/` is the legacy EVM vault kept for reference and is not used by the NEAR app.
- **Off-chain payment data stays private.** UPI IDs, payee names, raw QR text, salts and UTRs never go
  on-chain or into a public receipt. Only a SHA-256 commitment is stored. See `near-receipts/README.md`.

## Commands

Python projects use `uv` and Python 3.12. There is no CI and no configured Python linter, so run the
checks below yourself.

| Project | Run | Test | One test |
|---|---|---|---|
| `services/api-py` | `uv run uvicorn app.main:app --port 8788` | `uv run pytest -m "not live"` | `uv run pytest tests/test_workers.py::test_failure_refunds_reason_3` |
| `apps/mobile-flutter` | `flutter run --dart-define=NEAR_MVP=true` | `flutter test` | `flutter test test/near_wallet_test.dart` |
| `apps/web` (legacy EVM PWA) | `npm run dev` | `npm test` | `npx vitest run -t "splitSignature"` |
| `near-scanpay` | — | `cargo test` | `cargo test tests::successful_settlement_moves_to_terminal_state_and_reduces_accounting` |
| `near-receipts` | — | `cargo test` | `cargo test tests::a_stranger_cannot_anchor` |

- **`services/api-py`:** `uv run pytest -m live` makes read-only calls to the testnet. `--dry-run`
  simulates transactions without broadcasting. `CHAINS=near` enables no legacy EVM chain.
- **`apps/mobile-flutter`:** `flutter analyze` must stay at 0 errors and 0 warnings. The NEAR wallet is
  behind `NEAR_MVP=true`; the ordinary build keeps the preserved card wallet.
- **`apps/web`:** `npm run build` also type-checks. It still describes the legacy EVM flow.
- **`near-scanpay` / `near-receipts`:** `cargo test` runs offline against `near-sdk`'s VM. The wasm
  build is `cargo build --target wasm32-unknown-unknown --release`; deploy with each crate's
  `scripts/deploy-testnet.sh`.

## How a payment flows

```
Flutter wallet --/near/quote--> services/api-py --lock args--> near-scanpay (ft_transfer_call locks USDC.e)
                                        | backend re-reads the final transaction from NEAR RPC
                                        | production-only payout adapter pays the merchant locally
Flutter wallet --/near/track--> services/api-py verifies and records the lock
```

1. `POST /near/quote` validates the QR, prices the local amount, stores `qrText` and `salt` privately,
   and returns a private quote plus native `ft_transfer_call` arguments.
2. The Flutter app signs and sends a native NEAR transaction with its biometric-keystore Ed25519 key,
   so the payer never handles a seed phrase or gas manually.
3. The token's `ft_transfer_call` invokes `near-scanpay.ft_on_transfer`, which creates a unique lock;
   the tokens are already in the contract before the lock exists.
4. `POST /near/track` fetches the transaction from NEAR itself and verifies its action, amount, lock
   id, vault and every receipt before recording it.
5. `Locked -> PayoutPending -> SettlementPending -> Settled`. A definitive payout failure goes back to
   `RefundPending -> Refunded`; an unknown outcome stays frozen for a human. Raw UPI details and UTRs
   stay off-chain; settlement stores only a SHA-256 commitment to payout id + UTR.

**`Locked` doesn't prove the merchant was paid.** The chain can only record what the backend reports.
Don't treat any on-chain state as proof of a bank credit in new code; the payout adapter is the
authority.

## Things that must stay in step

There is no shared package between these projects, so a change on one side needs a matching change on
the other:

- **API paths on the shared hostname:** a new top-level route goes in `apps/web/deploy/Caddyfile` and
  `API_PATHS` in `apps/web/vite.config.ts`. The web app can't use those paths for its own pages.
- **Hosts the browser calls directly:** `connect-src` in `apps/web/deploy/Caddyfile` must list them, or
  the feature works everywhere except production. If the NEAR RPC in `/near/config` changes, change it
  there too.
- **UPI QR parsing:** `services/api-py/app/qr.py` has the final say, and `apps/web/src/lib/upi.ts`
  mirrors it.
- **NEAR deployment facts:** `deployments/near-testnet.json`, `/near/config` and the README table must
  name the same token, vault, treasury and receipt accounts.

## Design decisions that aren't obvious

- **The Flutter wallet key is Ed25519 in Android Keystore.** Flutter generates the seed locally; a
  biometric-bound AES-GCM key wraps it, and every transaction decrypts it behind a fresh
  strong-biometric prompt. The seed never reaches the backend or the repository, and the serializer is
  pinned byte-for-byte against `near-api-js 7.1.0` in the Flutter tests.
- **The EMV card is a possession factor, not a payment credential.** The card proves presence at
  onboarding; ordinary QR payments need the biometric-protected wallet key.
- **Quotes last 90 seconds.** Request them last, after every other check has passed.
- **The backend re-reads the chain.** `/near/track` verifies the final transaction itself; it never
  accepts an app-supplied hash as proof.
- **Receipts are commitments, not proofs of bank credit.** `near-receipts` stores one digest per
  payment and rejects a raw UTR, a duplicate payment id and a digest bound to another payment.
- **Payout outcomes are three-valued:** paid, definitely failed, unknown. Only definitely failed may
  refund automatically.
- **Legacy modules are reference only.** `apps/web/` and `contracts/` describe the earlier EVM product
  and are not part of the NEAR path.

## Deployment

One host serves the web app and the API through Caddy. It runs copies of the code, not a git checkout,
so `main` and the server can differ.

- **Backend:** `/opt/globalpay`, under the `globalpay` systemd service, with its database in
  `/var/lib/globalpay`.
- **Secrets:** `/etc/globalpay/`.
- **Web app:** `/var/www/globalpay`. Steps are in `apps/web/README.md`.
- **Domain:** set `GLOBALPAY_DOMAIN`; the Caddyfile has no hostname baked in.

## More detail

| File | Covers |
|---|---|
| `docs/status.md` | Current progress and decisions |
| `near-receipts/README.md` | NEAR receipt contract, digest rules and deployment |
| `near-scanpay/README.md` | NEAR vault state machine, callbacks and deployment |
| `services/api-py/README.md` | API, environment variables, backend internals |
| `apps/mobile-flutter/README.md` | Wallet build, NEAR_MVP defines and demo flow |
| `apps/web/README.md` | Legacy EVM PWA setup |
