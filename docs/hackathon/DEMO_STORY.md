# GlobalPay phone demo story

This is the start-to-finish screenshot order for the physical Android demo. Every screenshot comes
from the real app. Do not substitute a mock balance, card number, merchant payout or transaction.

The POCO M2 Pro has no NFC. Build with `DEV_FAKE_CARD=1` only for this story: it replaces the physical
card field with a local RSA test card, but the card challenge verification, Android biometric,
Keystore encryption, Ed25519 signing, NEAR RPC, token balance and escrow remain real. Use the separate
`globalpay-near-nfc-debug.apk` on an NFC phone.

## Story

| # | Phone screen | What to say | Suggested file |
|---:|---|---|---|
| 1 | Exact GlobalPay splash/logo | Original supplied artwork; not a redraw | `01-brand.png` |
| 2 | First-run wallet setup | A compatible card is the possession factor; no PAN/name is read | `02-card-onboarding.png` |
| 3 | Android biometric prompt | Fingerprint creates and encrypts the Ed25519 key in Android Keystore | `03-biometric-create.png` |
| 4 | Public-key provisioning state | Only the public key leaves the phone; demo operator adds it to the testnet account | `04-key-provisioning.png` |
| 5 | Home | Real USDC.e + NEAR balances and exact GlobalPay theme | `05-wallet-home.png` |
| 6 | Receive | Receiver can enter an amount for the existing card-to-phone P2P rail, show a NEAR crypto QR, or use an ordinary UPI QR for INR | `06-receive-choice.png` |
| 7 | Send | Scan account QR, review exact stablecoin amount, approve biometrically | `07-send-review.png` |
| 8 | Cards | Safe card fingerprint/public-key role; no PAN or cardholder identity | `08-card-security.png` |
| 9 | Card authentication prompt | Debug card only bypasses NFC on the POCO; biometric remains real | `09-card-auth.png` |
| 10 | UPI scanner/review | Merchant gets INR amount; payer spends the shown USDC.e amount | `10-upi-review.png` |
| 11 | Escrow result | Lock hash and separate escrow / payout / treasury states | `11-upi-locked.png` |
| 12 | Activity | UPI history is a separate tab; tap a row for details | `12-activity.png` |
| 13 | Payment details | Cancel appears only while payout is `NOT_STARTED` | `13-payment-details.png` |
| 14 | Refunded or settled terminal state | Show the real callback transaction; never call `Locked` “paid” | `14-terminal.png` |

Capture the visible screen into both the repository and phone gallery:

```sh
cd apps/mobile-flutter
./scripts/capture-demo-screen.sh 05-wallet-home
```

The phone copy is written to `Pictures/GlobalPayDemo/`.

## INR payout timing and cancellation

- This local demo currently reports `merchantPayoutConfigured: false`. Therefore **no INR is sent**,
  a lock remains `Locked`, and payer cancellation is intentionally valid.
- In an explicitly enabled production deployment, `/near/track` immediately claims the payment as
  `STARTING` in the same HTTP request; the worker calls on-chain `start_payout` before handing private
  UPI data to RazorpayX.
  Once on-chain status is `PayoutPending`, payer cancellation is impossible.
- The default outer provider decision timeout is 30 seconds; the RazorpayX script normally polls for
  at most 25 seconds so it can return a classified result before that deadline.
- `processed` + payout ID + UTR → escrow settles to crypto treasury.
- definitive `failed/rejected/cancelled/reversed` → callback-safe payer refund.
- timeout/network/unknown → escrow remains frozen for operator review. It is never auto-refunded,
  because the merchant may already have received INR.

This means RazorpayX uncertainty can temporarily lock treasury collateral, but it cannot both pay the
merchant and let the sender cancel. A live payout still requires authorized RazorpayX credentials and
fiat liquidity; none was used in this repository session.

## NFC claims

- **Working product rail:** compatible bank card → GlobalPay phone/custom reader → payer phone
  approval (existing EVM/local card wallet).
- **Working NEAR rail:** biometric direct transfer and UPI escrow.
- **Not implemented:** phone emulation at an arbitrary bank POS and smartwatch-to-POS. Those require
  HCE, issuer/acquirer and payment-network integration and remain visibly labelled roadmap.
