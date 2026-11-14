# Project status

Last updated 2026-11-15. Update this when something ships or a decision changes.

## NEAR hackathon MVP — latest status

This section supersedes the older NEAR prototype notes later in this file.

| Piece | State |
|---|---|
| Network/token | Verified on `testnet`; `usdc.fakes.testnet` reports `USDC.e`, 6 decimals, and is explicitly a test asset |
| Accounts | Demo, vault and `treasury.globalpay-receipts.testnet` exist; all three are registered for the test token |
| Safe vault | Upgraded at `vault.globalpay-receipts.testnet` to callback-safe refund and treasury settlement; migration preserved old lock history |
| Payout lifecycle | `Locked → PayoutPending → SettlementPending → Settled`; definitive failure refunds, unknown stays frozen for review |
| Real chain evidence | Lock/refund/failure/retry, Flutter-signed lock/refund, migration and synthetic treasury settlement verified on testnet |
| Backend | `/near/*` plus production-gated RazorpayX orchestration implemented; 230 offline tests pass |
| Flutter | Dark GlobalPay wallet home, real holdings, Pay UPI, NEP-141 Send, account-QR Receive, separate Activity/Cards tabs, card security and existing card-wallet entry; 18 tests pass |
| Flutter hardware run | POCO biometric/Keystore signed lock `D7UL…FqRp` and refund `BRAk…yPAW`; launcher/splash and debug APK build verified |
| NFC | Existing EMV reader/DDA remains; POCO has no NFC, so physical card proof is still blocked and debug stand-in is disclosed in-app |
| INR payout | RazorpayX `PAID/FAILED/UNKNOWN` is integrated but no live payout was authorized or sent; synthetic settlement proves only the crypto treasury leg |

Deployment details and transaction hashes are in `deployments/near-testnet.json`. Hackathon-facing
status, architecture and demo instructions are in `docs/hackathon/`.

## Live

| Part | State |
|---|---|
| Contracts | NEAR testnet: vault, treasury and receipt accounts (see `deployments/near-testnet.json`) |
| NEAR MVP vault | Deployed on NEAR testnet for lock/refund/settlement |
| Backend | Deployed, serving quotes and settlement |
| Web app | Deployed and used in live demos |
| Phone payer | Runs on one laptop and phone, in live mode for demos |

## Legacy EVM wallet removed (2026-11-15)

The React Native wallet, relayer, EVM wallet contracts, PWA, terminal and Pi reader that lived under
`wallet/` were removed together with their duplicated build output. The NEAR wallet in
`apps/mobile-flutter` and the `/near` backend are the only payment path. Root `contracts/` remains as
read-only reference until its Arc Studio history is archived.

## In progress: long-lived agents

Prize target: NEAR (escrow, receipts and the mobile wallet).

| Step | State |
|---|---|
| 1: agents and runs | Done |
| 2: per-agent wallets | Done. Chef reuses the first wallet, and a second real wallet was created, funded and approved |
| 3: agent behaviour | Done. Real models chose a vegetarian or a chicken dish from the profile alone, against a fake off-ramp |
| 4: extension | Done, and used from a person's own Chrome |
| 5: food test site | Done. The mock stores are kept locally, not in git |
| 6: real sites | In progress. Amazon reached a real QR, a real lock and the phone. Swiggy reached its cart. Zomato not tried |
| 7: NEAR receipts | Implemented in `near-receipts/` and anchored on testnet |
| 8: submission | Not started |

**Live payments through the agent server:** no rupee payment has succeeded through an agent's wallet yet. A real Chef run stopped at a locked phone, and a real ₹256 Amazon run stopped when the phone's UPI Lite balance was too low. In both, the panel correctly said Not paid while the chain said `COMPLETED`, and those test USDC can be disputed. The earlier ₹1 through the first wallet and the phone was before the extension existed.

## Decisions

- Agents are long-lived: a name, avatar, instructions and profile, with a run history and their own Circle wallet.
- Models never write an agent's stored memory.
- The agent is fully autonomous under its limits, with a kill switch until submission.
- Success comes from the payer's result, not on-chain `COMPLETED`.
- The agent loop is a plain state machine in Python, using OpenAI through a `Decider` interface.
- The demo site is chosen by rehearsing on real sites, with `apps/mock-store/foodie/` as the fallback. The phone receives the merchant's raw QR, but the backend still refuses BharatQR.
- Order-placing clicks go ahead on their own only when UPI is visibly selected and the total is within the limit.
- Each Circle wallet pays from a capped allowance, with no permit. See `docs/verify-log.md`.
- NEAR receipts hold the payout record: a payment id maps to one digest, never replaced. See `near-receipts/README.md`.
- Browser wallets only for now, with WalletConnect as a possible later addition.

## Parked

- **Reporting payout results to the backend.** Until then, `COMPLETED` can appear when nobody was paid. The agent avoids this by reading the payer's result directly, but the backend and PWA don't yet.
- **A full NEAR payout board** beyond the receipt anchor, until the agent works.

## First real agent payment (2026-11-07)

An agent ordered and paid on a real site from its own wallet, and the phone reported the merchant was paid. It paid for a dearer variant, because a hover effect left the wanted item's button covered. The pointer now moves when that happens, but the run limit is the only hard protection against a costly substitute, so keep it tight.

## Razorpay and swap readiness (checked 2026-11-07)

- **`APP_ENV=prod` can't start yet, on purpose.** `razorpayx` isn't implemented, and `phone` and `stub` are dev rails. The workable setup is `APP_ENV=dev` with `COLLECT_RAIL=razorpay`.
- **Live Razorpay keys would charge real rupees for testnet tokens.** Nothing in the code prevents this, so keep `rzp_test_` keys until the vaults are on mainnet.
- **Tested against Razorpay's test API:** creating, fetching and cancelling a link, and the real webhook secret. Paying on the hosted page and real webhook delivery still need a person, because the page asks for a mobile number and has an hCaptcha.
- **Vault pools are nearly empty on the legacy EVM path,** so those quotes are refused; the NEAR vault is funded with test `USDC.e`.
- **Deployed 2026-11-07 with `APP_ENV=dev`, `COLLECT_RAIL=razorpay` and `rzp_test_` keys,** as a decision for the hackathon. Razorpay disables a webhook that keeps failing for 24 hours.
- **The swap needs the updated Caddyfile.** Under the old CSP the browser can't reach the Arc RPC or Circle.

## Needed from people

- [ ] Enough UPI Lite balance on the phone before any real order. The agent can't see that balance before it locks funds.
- [ ] One ₹1 test purchase on the live site, then top up the vault pools.
- [ ] Decide whether a real run may pay when the QR is slightly below the page's earlier total. Today the amount check refuses it, before any funds lock.
- [ ] Your own details in Chef's profile. It currently holds a test diet.
- [ ] A new model API key after the event. The current one has been exposed in a chat.
- [ ] The backend's "section 5" rules, probably in `HANDOFF-payment-cycle-api-metamask.md`, which isn't in the repo.
- [ ] A public repo, required by both prizes. Scan the history for secrets first.
- [ ] Removing `apps/mock-store/upi.png` from this branch's history before going public, or merging with a squash. It's a personal UPI QR, in earlier commits on the branch.
- [ ] New operator keys before any real funds. The current testnet seed and test wallet key have been exposed in a chat.

## Flutter app (2026-11-12)

`apps/mobile-flutter` is the phone client: a GlobalPay card-and-fingerprint wallet that pays UPI QRs through GlobalPay. It replaces the React Native app for the payer's phone only — the backend, relayer and vaults are unchanged, and the web app, extension and Pi terminal stay where they are.

- **Digest computed on the phone.** `lib/eip712.dart` rebuilds the vault's `OfframpIntent` hash in Dart, and `/api/scanpay/start` now returns the intent and domain so the app can check the digest it was handed. A relayer that shows one amount and signs another is refused before the fingerprint prompt. `test/eip712_test.dart` pins the result to ethers' `TypedDataEncoder` output.
- **One tap, one fingerprint.** The card is read and the quote fetched during the same tap (the same ordering as the React Native screen), then the card signs the 4-byte challenge and the fingerprint prompt shows the quoted amount.
- **Native pieces:** `EmvCard` (port of `mobile/lib/emv.js`) runs the ISO-DEP APDU exchange, the certificate chain and INTERNAL AUTHENTICATE over `nfc_manager`; `MainActivity.kt` holds the P-256 keystore key and signs behind a `BiometricPrompt`. Both are ports, so the card data never leaves the phone and the key never leaves the keystore.
- **Verified:** `flutter analyze` has no errors (info lints only), `flutter test` passes 11/11, and `flutter build apk --debug` produces `build/app/outputs/flutter-apk/app-debug.apk`.
- **The look is GlobalPay's, not stock Material.** The screens follow GlobalPay's paper-and-ink design: warm paper `#F6F5EF`, near-black ink `#171914`, Bricolage Grotesque headings with Instrument Sans text (both bundled in `assets/fonts/`), ink primary buttons, yellow for selection, green `#36744A` for success, and the navy card gradient of the site's `.fallback-card`. Colours, type and button shapes live in `lib/theme.dart`, taken from the live `globalpay.web.app` stylesheet so the phone and the web app match; the shared widgets (card, hero art, meter, panels) are in `lib/ui.dart`.
- **Hardware caveat:** the POCO M2 Pro has no NFC, so a compile-time-only `DEV_FAKE_CARD=true` stand-in persists one RSA key and signs the same EMV block the contract checks. It is covered by a chain-equivalent test and is off in ordinary builds. A physical EMV tap still needs a separate NFC phone before production can be claimed.
- **Ran on a real phone (2026-11-13).** Installed on the connected POCO M2 Pro and screenshotted: onboarding renders in the GlobalPay tokens. `testAVD` also boots now — its system image (`android-34;google_apis;arm64-v8a`) had never been downloaded, and the disk was full, so the AVD's leftover 1.2 GB qcow2 overlay was dropped and its data partition cut to 2 GB.
- **A black screen means transparent colours.** A rewrite of `lib/theme.dart` wrote them as six digits, `Color(0xF0F4F0)`, which Dart reads as alpha 0 — every surface painted nothing. Colour literals need the eight-digit `0xFFF0F4F0` form.
- **In the app:** create a wallet from a card and a fingerprint, pay a UPI QR, send, receive, freeze and unfreeze, cards and history.
- **Real-phone local demo:** signup reached the chain after fixing WebAuthn's `challengeIndex` (the contract expects the offset of `"challenge":"`, not the value); the wallet then sent 5 test USDT, froze and unfroze on-chain, and displayed the resulting balance/history. The Mac firewall blocks Node over Wi-Fi, so this phone uses `adb reverse tcp:8787 tcp:8787` and a loopback build.
- **Person-to-person tap:** the Receive screen can act as a GlobalPay terminal. It knows its own wallet, reads the sender's linked card, and `/api/p2p/start` puts an amount+recipient-bound request on the sender's registered phone. The sender fingerprints it and the receiver gets the token; no address is typed. A local two-wallet chain test passes all eight checks. The sender can scan the receiver's QR as the no-NFC fallback.
- **UPI merge proof:** a camera-scanned UPI QR now returns the full signed intent/domain (the relayer needed a restart after `scanpay.js` changed), the Flutter client rebuilds the same digest, and a local six-check test proves card + phone lock only the quoted amount in `ScanPayVault`. This proves escrow, not INR delivery: local `PAYOUT_COMMAND` is the stub and `scripts/razorpayx_payout.py` is still deliberately unimplemented.
- **Not in the app yet:** dispute, phone recovery, editing limits, adding a second card, the swap and the Razorpay on-ramp. All of these exist on-chain or in the backend; only the screens are missing.

## Web app restyled to the live GlobalPay site (2026-11-12)

`apps/web` no longer looks like the old dark-green theme: it now follows **https://globalpay.web.app/**, whose stylesheet was pulled for the real tokens rather than the older PWA stylesheet.

- **Colour:** paper `#F6F5EF`, ink `#171914`, soft ink `#62665C`, line `#DEDFD5`, electric yellow `#FFE600` for everything selected (toggle, bottom-nav pill, sidebar), green `#36744A` only for success, purple `#7B5CCA` for the focus ring. Cards are `#FFFEF9` and bands `#EEEFE6`, as the site's receipt and wallet sections are. Dark mode is kept as the site's `--night` (`#171C18`) — the site itself is light-only, but `e2e/app.spec.ts` has a dark-mode test.
- **Type:** Bricolage Grotesque for headings at 600 and `-0.055em`, Instrument Sans 17px/1.6 for body, JetBrains Mono for the small uppercase eyebrow labels (the `caption` variant). All three are bundled through `@fontsource`, so nothing is fetched at runtime. Neither new face carries ₹, so Roboto's latin-ext stays in the stack for that glyph alone — checked with `fontTools`.
- **Shape:** pill buttons (999px) with a `scale(0.97)` press, tonal secondary buttons instead of outlined, 28px/6px list corners unchanged. The entrance flourish `rr-stagger` is applied to the connect screen again, so `motion.spec.ts` can see it.
- **Checked:** `npm run build` (type-check + build), `npm test` 92/92, `npx playwright test` 52 passed and 1 skipped (the live testnet test, which needs its environment variables).
- **Four e2e colour assertions were stale** from an older palette and were retargeted; three specs found the connect button with `/^Connect/`, which now matches both the page's "Connect Wallet" and the injected wallet's "Connect Test Wallet", so they name the wallet's exactly.

## Using the web app on the local chain (2026-11-12)

The browser needs an EIP-1193 wallet, and a fresh Chromium has none, so `apps/web/src/lib/devWallet.ts` offers a **local test wallet (Hardhat)**. It is a provider shim that signs typed data with Hardhat's published account #0.

- **Two gates, both required:** `import.meta.env.DEV` (so it is dead code in `npm run build`) and a backend reporting chain 31337. It cannot appear in a production build.
- It only implements the six methods the app calls, all reads or `eth_signTypedData_v4`; the app never sends a transaction, so nothing here can move funds without the backend relaying it.
- The demo account needs test USDT: `MockUSDT.mint(0xf39F…2266, 500e6)` from account #0.
- Verified end to end in the running app: ₹250 QR → quote at ₹100.06/USDT → signed by the local wallet → `LOCKED` → settler `COMPLETED`, with the dispute window shown.
- **`npx vitest run` is green (92 tests).** An older note recorded three jsdom `localStorage` failures at `about:blank`; `vite.config.ts` now sets `environmentOptions.jsdom.url`, so they no longer happen.

## RazorpayX payout rail implemented; phone app gaps closed (2026-11-14)

The payout rail was the single biggest production blocker: escrow worked, but nothing could prove
the merchant got rupees. It is now implemented, and the phone app grew the screens that were listed
as missing.

- **`scripts/razorpayx_payout.py` is real.** It creates a UPI payout with `X-Payout-Idempotency`
  (the offramp id), polls until a final status, prints `{"utr": ...}` so the onchain `payoutRef`
  becomes `keccak256(utr)`, and exits **0 paid / 1 definitively not paid / 2 unknown**. Logic lives
  in `app/razorpayx.py` so it is unit-testable with `httpx.MockTransport`.
- **Exit 2 is a new outcome, not a failure.** `payout_runner.run_black_box` maps it to a
  `needs_operator:` detail and `PayoutRunner.dispatch` parks the row in `NEEDS_OPERATOR` — no
  refund, no re-run. Refunding an ambiguous payout would pay the merchant and return the escrow.
  A "processed" payout with no UTR is treated the same way, because it cannot prove a bank credit.
  A 4xx from RazorpayX is a definite failure; 5xx and network errors are unknown.
- **`PAYOUT_RAIL=razorpayx` is marked implemented**, so `APP_ENV=prod` starts once its three
  variables are set (`RAZORPAY_API_KEY`, `RAZORPAY_API_SECRET`, `RAZORPAYX_ACCOUNT_NUMBER`).
- **Phone app:** *Add money* (onramp order → payment link / UPI instructions → poll to PAID),
  *UPI payments* (GlobalPay's `/offramps` list), a payment detail screen with escrow, payout state,
  disclosure that `COMPLETED` is not "merchant paid", the dispute window, and
  **Report merchant not paid**, plus *Wallet* settings: spending limits, the card-only small-payment
  rule, adding a second card, and cancelling a lost-phone recovery. Home links to all of them.
- **Disputes are phone-only onchain**, so the relayer gained `/api/scanpay/dispute/start` and
  `/api/scanpay/dispute/:id`: it asks the vault for `hashDispute`, the fingerprint signs it, and the
  wallet calls `dispute`. No card tap, and the funds can only return to that wallet.
- **Android:** release builds are HTTPS-only (`usesCleartextTraffic="false"`; the debug manifest
  overrides it for a LAN relayer), and `android/keystore.properties` supplies the release keystore
  when present — without it the build warns and signs with the debug key. `DEV_FAKE_CARD` remains a
  compile-time false, so the stand-in card still cannot enter a release build.
- **Checked:** `pytest -m "not live"` 164 passed (13 new payout-rail/ambiguous-outcome tests, and
  three environment tests updated now that the rail is implemented), `flutter analyze` no errors or
  warnings, `flutter test` 11/11, `flutter build apk --debug` and `--release` both succeed.
- **Still not proven:** a real RazorpayX payout (needs the current account and live keys), a
  physical card tap on an NFC phone (the POCO has none), and push notifications — the sender's
  phone still polls for approvals.

## USB (ADB reverse) is the phone-to-backend path; `CHAINS` in `.env` now works (2026-11-14)

Checked the whole project over USB with the POCO M2 Pro (no NFC, so no card tap).

- **USB tethering is not the mechanism.** With the phone connected, the Mac has only `lo0` and `en0`
  (Wi-Fi) — no RNDIS/tether interface. Android USB tethering makes the *phone* the gateway, so the
  phone cannot reach the Mac through it. For phone → backend the supported path is
  `adb reverse tcp:8787 tcp:8787` (relayer), `tcp:8788` (GlobalPay API) and `tcp:8545` (chain).
- **The tunnels were verified with the phone's real HTTP stack**, not with `toybox nc`: a browser
  intent to a throwaway `python -m http.server` logged `/probe-from-phone` in the Mac's access log,
  and the same intent to `127.0.0.1:8788/health` appeared in the API's uvicorn log. Plain `nc` from
  `adb shell` reported 0 bytes and is not a reliable probe here.
- **Reverses are per-connection.** Re-adding them is needed after an adb server restart or a
  replug; `adb reverse --list` is the thing to check when the app says it cannot reach the service.
- **Bug fixed: `CHAINS` from `.env` was ignored.** `Settings.enabled_chains` read only
  `os.environ["CHAINS"]`, so with `CHAINS=local` in `services/api-py/.env` the API still came up on
  the legacy EVM defaults while the relayer ran with `GLOBALPAY_CHAIN=local`; `/quote` answered
  `400 BAD_CHAIN`. `config._env_or_file` now uses the same precedence as the keys (exported env,
  else the env file, else the default), so a local run really is local. Covered by three tests.
- **Verified after the fix:** API on `chains=['local']`, `POST /quote` returns a signed intent
  (₹1 → 9877 base units at 101.253440), and `flutter build apk --debug` with
  `RELAYER_URL=http://127.0.0.1:8787` + `GLOBALPAY_URL=http://127.0.0.1:8788` installs and launches
  on the phone with no crash.
- **Safely:** the API was started `WORKERS=0 --no-workers` throughout, so no listener or settler ran
  and nothing could refund or complete a lock.

## Operator report, card revocation, durable pending approvals (2026-11-14)

The last three items on the "complete product" list that needed no external account or hardware.

- **`GET /admin/reconcile` (ADMIN_TOKEN) is the operator view.** `app/reconcile.py` reads — never
  writes — and buckets the payments a human has to settle: `ambiguous_payout` (the rail could not
  confirm; check the provider by the offramp id, which is also its idempotency key),
  `crashed_dispatch`, `refund_pending`, `completion_pending` (rail says paid, chain still LOCKED),
  `dispute_relaying`, `dispute_failed` and `onramp_stale`. Every row carries `refundable: false` for
  anything ambiguous, so the report cannot be mistaken for a "safe to refund" list. Nine tests.
- **Cards can be revoked from the wallet screen.** The relayer gained a `removeCard` action
  (`removeSigner(id, expiry, sigs)`); a remaining card approves and the phone confirms, so revoking
  a lost card never needs that card. The UI refuses to revoke the wallet's only card. `finishAction`
  now also sends `cardModulus`, so a two-card wallet names the card that actually signed instead of
  letting the relayer assume the first one.
- **Pending approvals survive a relayer restart.** `relayer/pending.js` keeps the `payments` and
  `actions` maps in `pending.v2.json` with a BigInt-safe codec, drops entries past a 15-minute TTL,
  polls the maps because routes mutate `p.status` in place rather than calling `set`, and swallows
  disk errors after one warning so a full disk cannot fail a payment. Six `node --test` cases
  (`relayer/test/pending.test.js`) cover the restart round-trip, TTL, deletion, in-place mutation and
  a corrupt file. `scanpay.js` requests are deliberately not persisted: their quote dies in 90 s and
  the real state is the onchain lock.
- **Checked:** `pytest -m "not live"` 175 passed, `node --test` 6/6, `flutter analyze` 0 errors and
  0 warnings, `flutter test` 11/11, `flutter build apk --debug` succeeds.
- **The running relayer still serves the older code.** It was started with `RELAYER_KEY` in its
  environment and there is no start script or `.env` for it, so restarting it here would mean reading
  the key. The new routes and the persistence module are in the files and syntax-checked, but the
  process on :8787 must be restarted before they take effect.
- **Still needs a person:** a real RazorpayX payout, an NFC card tap, a Firebase project for push
  notifications, Azure OpenAI credentials, and testnet deployment keys and gas.

## Replacing a lost phone, and wallet display names (2026-11-14)

Two more items off the "complete product" list; both are app + relayer only, no contract change.

- **"I lost my phone" is now a real flow** (`apps/mobile-flutter/lib/screens/recover.dart`), reached
  from the sign-up screen on the *new* phone. It creates a fresh P-256 key on that phone, taps one
  card to find which wallet it belongs to, then asks two *different* cards to sign the same 4-byte
  challenge while the new phone signs the full proposal hash. The wallet enforces its own
  `recoveryDelay()` before the change is accepted, so holding the cards is not enough on its own:
  there is a window in which the real owner can cancel from Wallet → Lost phone with only a
  fingerprint. The screen reports the wait honestly ("waits 1 day(s)") and offers to finish when
  the delay has passed. It uses the existing `/api/recover/start|:id|finish` routes — no new on-chain
  path, no seed phrase, no card number or PIN.
- **A wallet can register a display name** (`POST /api/profile`, `GET /api/profile/:wallet`), set from
  Wallet → Your name. Senders see it on the approval sheet in place of "GlobalPay wallet 0x1234…".
  **This is a label, not proof of identity**: it is not signed by the wallet (the contract has no
  arbitrary-signature entry point), so the app labels it "a name GlobalPay registered" and still
  shows the full address the fingerprint signs. Anyone treating it as a verified person would be
  wrong, which is why the wording says registered.
- **Still not done, and why:**
  - *Push notifications.* Needs a Firebase project, and the relayer's `package.json` must stay
    untouched, so neither `firebase-admin` nor `firebase_messaging` can be added here. Pending
    approvals do now survive a relayer restart, which removes the worst of the polling problem.
  - *Cryptographically bound recipient names.* The wallet contract can only validate a signature
    inside one transaction against a digest it computed itself; there is no ERC-1271 entry point to
    bind a name to a wallet, and `contracts/` only changes through Arc Studio.
  - *Azure OpenAI.* `agent-server` already accepts `openai_base`, and Azure needs an `api-key` header
    plus `?api-version`; that is a small change, but without a deployment it cannot be verified, so
    it stays unclaimed rather than half-done.
  - *Real-chain deployment, real payouts, NFC taps.* Keys, gas, an account and hardware.
- **Checked:** `flutter analyze` 0 errors / 0 warnings, `flutter test` 11/11,
  `flutter build apk --debug` succeeds, `node --check server.v2.js` clean.

## Receipts anchored on NEAR (2026-11-14)

The NEAR half of the record: every settled payment's receipt is hashed and the digest is anchored by a
relayer account, so a merchant or auditor can prove a receipt was recorded without any UPI ID, payee
name or UTR becoming public. `near-receipts/` holds the contract, `app/near_receipts.py` the backend
side.

- **The contract** (`globalpay-receipts`, near-sdk 5) keeps an owner-managed anchor allow-list and
  `payment_id -> Receipt`. `anchor` rejects a duplicate payment id, a digest already bound to another
  payment, a digest that is not 64 lowercase hex, a raw (unhashed) UTR and `paid_at = 0`, and emits
  NEP-297 `receipt_anchored`. A receipt is never replaced: the second call panics, so what was recorded
  first is what stays. 14 `cargo test` cases, including the ones asserting those rejections.
- **The digest** is `sha256` over a canonical JSON body (sorted keys, no whitespace) of payment id,
  offramp id, chain, amount, `inr_paise`, `utr_hash` and `paid_at`. The UTR is hashed on the way in, so
  it cannot be anchored by accident; an empty UTR anchors as `""`, not `null`.
- **The hook is optional and cannot hurt a payment.** `Settler(..., on_settled=…)` is wired from
  `context.py` only when both `NEAR_RECEIPTS_CONTRACT` and `NEAR_ANCHOR_ACCOUNT` are set. A failure is
  logged and nothing else: the escrow is already complete and the merchant has already been paid, which
  two tests pin down (`test_a_failing_anchor_does_not_undo_a_settlement`).
- **What it does not prove:** that the merchant's bank account was credited. The anchor records what
  this backend saw, exactly like `COMPLETED` — it is not a payment proof.
- **Checked:** `cargo test` 14/14, `cargo build --target wasm32-unknown-unknown --release` produces a
  239 KB wasm, `pytest -m "not live"` passes with the 20 new tests.
- **Needs a person:** `near login`, a testnet account with NEAR for storage, and running
  `near-receipts/scripts/deploy-testnet.sh`. Nothing in the repo holds that key.

### Deployed, and the two bugs that only a real chain found

`globalpay-receipts.testnet` (owner and anchor account the same) was created with
`near create-account --use-faucet`, deployed with `near-receipts/scripts/deploy-testnet.sh`, and
anchored a real receipt: `is_anchored` returns true, `receipt(0xcdcd…cdcd)` returns the record with
`utr_hash` intact and no UTR, and a copy with one changed amount fails.

Running it found two defects the unit tests could not, both of which would have failed *silently* in
production (`run_anchor` only warns, by design):

1. **The anchor command was the wrong CLI.** It emitted legacy `near call … --accountId`, but the CLI
   the NEAR docs install is near-cli-rs (`near contract call-function as-transaction … sign-as …
   network-config testnet sign-with-keychain send`). Anchoring would have warned on every payment and
   never landed. `test_the_command_is_the_cli_we_install` now pins the shape.
2. **`paid_at` was sent as a JSON string** where the contract takes `u64`, so every call aborted with
   a WebAssembly trap. It is now an int, asserted in `test_anchor_args_are_what_the_contract_expects`.

The deploy script also grew two fixes: it asks "does the account exist / is a contract on it / is it
initialised" as three separate questions (re-deploying with an init call would panic), and its anchor
check now matches only the quoted JSON, not the CLI's echo of the command line — which always contains
the account id and made the check pass vacuously.

`services/api-py/.env` now carries `NEAR_RECEIPTS_CONTRACT` and `NEAR_ANCHOR_ACCOUNT`, so a running
settler anchors on completion. Both are public identifiers, not secrets.

## The vault ported to NEAR (2026-11-14)

The project is now NEAR-based rather than NEAR-adjacent: the escrow money rules run in
`near-scanpay/`, ported from `contracts/src/ScanPayVault.sol`.

- **`near-scanpay/`** (Rust, near-sdk 5, 324 KB wasm) holds the state machine `Locked → Completed →
  Disputed → Reversed | Released`, plus `Refunded` from `refund`/`reclaim`. A lock is created by an
  NEP-141 `ft_transfer_call` callback, so the tokens are in the contract before the lock exists — the
  same guarantee the EVM vault got from `transferFrom` inside `offramp`. 21 `cargo test` cases cover the
  money rules: only the token may lock, only the settler may settle, completion is bounded below by
  `completable_at` and above by `reclaimable_at`, a settled payment cannot also be refunded, only the
  payer may dispute and only inside the window, a quiet arbiter refunds after `dispute_timeout`, and
  `reclaim` is callable by anyone so a dead backend cannot trap funds.
- **`app/near_vault.py`** is the backend half: RPC reads (no key), pure command builders so an operator
  can read what will be signed, and `NearChainClient`, which implements the five calls the settler
  already uses (`send`, `offramp_state`, `deadlines`, `chain_time`, `tx_url`) by mapping
  `completeOfframp → complete`, `refundOfframp → refund`, `reverseOfframp → resolve_dispute`,
  `reclaimOfframp → reclaim`. An EVM method with no NEAR equivalent raises instead of being guessed at.
  19 tests, including that a failed call raises instead of looking settled.
- **Receipts moved onto completion.** `complete(id, payout_ref, digest)` stores the digest the backend
  computed (UTR hashed), so the anchor and the settlement are the same record instead of two.
- **Still EVM:** `POST /quote` and `POST /offramp` build EVM payloads and the listener is EVM-log based,
  so a full NEAR quote→lock path still needs an endpoint issuing the `ft_transfer_call` message and a
  NEAR event reader. The Flutter app and the card wallet are unchanged: the card+phone scheme needs a
  NEAR signing path and a P-256 verifier, which NEAR does not provide natively.
- **Checked:** `cargo test` 21 + 14, wasm built for both contracts, `pytest -m "not live"` 215 passed,
  deploy script syntax-checked. Not deployed: the vault needs a NEP-141 test token that supports
  `ft_transfer_call`.
