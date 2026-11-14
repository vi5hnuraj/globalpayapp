# GlobalPay

## NEAR hackathon build

`--dart-define=NEAR_MVP=true` opens the modular NEAR testnet wallet while leaving the existing EVM
wallet build unchanged. It generates an Ed25519 seed locally, encrypts it with a biometric-bound
Android Keystore AES-GCM key, reads real `USDC.e` metadata/balances, serializes native NEAR Borsh
transactions, submits native NEP-141 transfers and pays UPI QRs through the escrow/treasury vault.
The showcase build uses the exact supplied `NEW LOGO.png` artwork: its full lockup is preserved
byte-for-byte in `assets/branding/globalpay-logo-original.png`, while launcher/header marks are crops
of those same pixels rather than a redraw. The dark wallet UI has real holdings, Receive, Send,
wallet/card details, UPI Scan, and separate Activity/Cards bottom tabs.

```sh
flutter build apk --debug \
  --dart-define=NEAR_MVP=true \
  --dart-define=NEAR_ACCOUNT_ID=demo.globalpay-receipts.testnet \
  --dart-define=GLOBALPAY_URL=http://127.0.0.1:8788
```

The app shows its public key for one-time provisioning with
`near-scanpay/scripts/provision-demo-key.sh`; its private seed never leaves the phone. See
`docs/hackathon/DEMO.md`. The biometric/Keystore wallet has signed a real testnet lock and refund on a
POCO M2 Pro. That phone has no NFC, so a physical combined card demonstration still needs another
device; `DEV_FAKE_CARD=1` is a visibly labelled debug-only stand-in, never a production claim.

The existing application is a stablecoin wallet on Android that pays Indian UPI QR codes. The payer holds USDC or USDT and
signs with a card tap plus a fingerprint; the merchant receives ordinary rupees and never touches
crypto. Every payment is escrowed on chain between the two, with a dispute window the payer controls,
and each settled payment's receipt digest is recorded on NEAR so it can be proven later without
publishing the UPI ID or the bank reference.

This repository contains the mobile app, the settlement backend, the NEAR contracts and the EVM
contracts the product started on.

## What the app does

| Flow | What happens |
|---|---|
| **Pay by QR** | Scan UPI → review exact INR/stablecoin amounts → approve with biometric only → escrow → RazorpayX outcome → refund or settle to treasury |
| **Pay by tap** | The receiver enters an amount on their phone; the payer taps a contactless card on it, sees the exact amount and recipient, and confirms with a fingerprint |
| **Add money** | Pay rupees through a payment link; the wallet receives stablecoin |
| **Activity** | Every payment with its escrow state, payout reference and dispute deadline — and "report merchant not paid" while the window is open |
| **Wallet** | Per-payment and daily limits, small card-only payments, card list with revocation, lost-phone replacement, recovery cancellation |

Card-wallet/NFC payments use the contactless card possession factor plus the phone biometric. NEAR UPI
QR and direct wallet transfers use the biometric-protected Ed25519 key; they do not ask for a redundant
card tap. The card never supplies a wallet seed or bank-customer identity.

The NEAR build is hard-gated: before card verification, fingerprint key creation and public-key
activation it exposes no balance, UPI control or bottom navigation. Receive offers both a NEAR account
QR and the preserved card-to-phone P2P request: receiver enters an amount, sender taps their registered
card on the receiver phone, then approves recipient + amount on the sender phone with a fingerprint.

## Architecture

```
lib/
  main.dart                  entry point, wallet gating, navigation
  api.dart                   the backend client: relayer + settlement API
  card.dart                  NFC card reader (EMV: AID selection, GPO, CDOL, 4-byte challenge)
  phone_key.dart             the phone's P-256 key in the Android keystore, WebAuthn assertions
  eip712.dart                EIP-712 hashing for the escrow intents
  store.dart                 local wallet address + key alias
  theme.dart, ui.dart        design system: type scale, spacing, panels, buttons
  screens/                   one file per screen
assets/capk.json             certificate authorities a card may chain to
```

The app deliberately has **no state-management package**: each screen owns its state with
`StatefulWidget`, the only shared state is the wallet address in `SharedPreferences`, and the backend
returns everything else. Adding a store or a code-generation layer here would be more machinery than
the app has behaviour.

Every balance and status shown is fetched from the backend. Nothing about a payment is decided on the
phone: the phone signs, the backend settles, the chain enforces.

## Backend

Two services, both HTTP/JSON, configured with `--dart-define` at build time:

| Define | Default | What it is |
|---|---|---|
| `RELAYER_URL` | `http://10.0.2.2:8787` | wallet service: signup, payments, approvals, card and phone recovery |
| `GLOBALPAY_URL` | `http://10.0.2.2:8788` | settlement service: quotes, onramp, offramp, disputes |

```sh
flutter run --dart-define=RELAYER_URL=http://127.0.0.1:8787 \
            --dart-define=GLOBALPAY_URL=http://127.0.0.1:8788
```

On a USB device, `adb reverse tcp:8787 tcp:8787` and the same for `8788` makes those loopback URLs
resolve to the laptop.

## Requirements

- Flutter 3.3+ and the Android SDK (this project builds Android only; there is no `ios/` directory)
- Android 8+ with NFC for the tap flow; the QR flow needs only a camera
- A running relayer and settlement backend for anything beyond the sign-up screen

## Build and test

```sh
flutter pub get
dart format .
flutter analyze          # expected: no errors, no warnings
flutter test             # 18 tests
flutter build apk --debug \
  --dart-define=RELAYER_URL=http://127.0.0.1:8787 \
  --dart-define=GLOBALPAY_URL=http://127.0.0.1:8788
```

The installed application id is `com.globalpay.app` and the launcher name is **GlobalPay**.

## Payments and escrow

The money rules do not live in the app. On NEAR, `near-scanpay/` enforces `Locked → PayoutPending →
SettlementPending → Settled`, or callback-safe refund before payout / after a definitive provider
failure. An unknown payout remains frozen for review. The app shows cancellation only while the
contract still reports `Locked`; paid escrow can never be shown as refundable.

**`COMPLETED` is not proof the merchant was paid.** The app therefore shows "payment processed" and
keeps the dispute action available; it never claims money reached a bank account it did not confirm.

## Security notes

- The phone key is generated in the Android keystore and requires biometrics; it is never exported.
- Card data never leaves the phone: only a signature over a 4-byte challenge and the card's public
  certificate are used, and only for the wallet that card belongs to.
- No private key, API key or backend secret is stored in this repository. The Android manifest sets
  `usesCleartextTraffic="false"`; a debug-only manifest allows plain HTTP for local development.
- Release builds require `android/keystore.properties`, which is git-ignored.

## Licence

MIT — see [LICENSE](../../LICENSE).
