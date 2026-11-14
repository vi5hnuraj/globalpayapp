# GlobalPay feature status

Last verified: 2026-11-15. “Working” means there is current code and test/evidence; it does not imply
production readiness.

| Payment method / feature | Status | Evidence and boundary |
|---|---|---|
| QR → crypto payment | **Working on EVM and NEAR testnet** | Flutter-generated biometric Ed25519 key signed a real NEAR lock and refund. Direct NEP-141 Send and account-QR Receive are implemented. |
| UPI QR → USDC/USDT → INR | **Integrated; live payout unproven/disabled** | QR, private payee handling, escrow, RazorpayX `PAID/FAILED/UNKNOWN` handling and treasury settlement are wired. No real RazorpayX payout was authorized or sent. |
| Rupees → USDC/USDT onramp | **Partial, EVM-only** | Razorpay Payment Link and EVM pool logic exist; not migrated to the minimal NEAR vault. |
| NEAR escrow lock | **Working on testnet** | Deployed vault, real `ft_transfer_call`, real lock query. |
| NEAR callback-safe refund | **Working on testnet** | Successful, failed and retried refunds verified with real receipts. |
| NEAR treasury settlement | **Working on testnet** | Callback-safe `PayoutPending → SettlementPending → Settled`; synthetic 0.001 test-USDC.e transfer reached `treasury.globalpay-receipts.testnet`. This is not INR evidence. |
| Internal NEAR Flutter wallet | **Working on Android hardware** | Biometric-bound encrypted Ed25519 seed signed real lock `D7UL…FqRp` and refund `BRAk…yPAW`; direct Send/Receive and full wallet home build. |
| Bank card → phone | **Code complete; physical proof blocked on current phone** | EMV read, certificate validation and DDA signing exist. POCO M2 Pro has no NFC; debug APK uses an explicitly labelled compile-time stand-in only. |
| Phone → phone NFC | **Not implemented as phone-to-phone NFC** | Existing P2P uses a bank card at the receiver phone and sender-phone approval; QR fallback exists. |
| Phone → dedicated NFC reader | **Working on EVM/local path** | Pi/M5 reader and phone approval exist; not connected to NEAR MVP. |
| Phone → regular POS | **Not implemented** | Requires HCE/payment-network/acquirer integration; NFC reader mode is not regular POS acceptance. |
| Smartwatch → POS | **Concept only** | No implementation. |
| NEAR receipt anchor | **Prototype deployed** | One receipt digest exists; it is not bank-credit proof or a complete payout board. |
| RazorpayX outcome safety | **Unit-tested, not live-proven** | Paid settles; definitive failure refunds; timeout/unknown stays frozen for review; the dev stub cannot release NEAR escrow. |
| AI agents on NEAR | **Excluded** | Existing agents remain EVM-based and untouched. |

## Terminology shown to users

- **Payment initiated:** quote created, no chain result yet.
- **Tokens locked:** finalized NEAR receipts plus matching vault lock.
- **Refund pending:** token transfer receipt has not completed.
- **Refunded:** callback confirmed transfer and accounting was reduced.
- **Payout processing:** refund is frozen before provider hand-off.
- **Review required:** provider outcome is ambiguous; never refund automatically.
- **Merchant payout verified:** RazorpayX reported `processed` with payout ID and UTR; raw values remain private.
- **Settled:** the verified-paid escrow transfer to crypto treasury succeeded.
