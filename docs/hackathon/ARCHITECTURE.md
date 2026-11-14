# GlobalPay NEAR MVP architecture

```mermaid
flowchart LR
    Card[Compatible contactless EMV card] -->|onboarding / custom NFC possession factor| Flutter
    Bio[Android biometric] -->|unlocks Android Keystore AES key| Flutter
    Flutter[Existing GlobalPay Flutter app\ninternal Ed25519 wallet] -->|UPI QR + INR| API
    API[Existing FastAPI backend\nQR + FX + private payee data] -->|amount + ft_transfer_call args| Flutter
    Flutter -->|signed native transaction| RPC[NEAR testnet RPC]
    RPC --> Token[usdc.fakes.testnet\nUSDC.e test asset]
    Token -->|ft_transfer_call| Vault[vault.globalpay-receipts.testnet\ncallback-safe Rust escrow]
    API -->|independent tx + receipt verification| RPC
    API -->|get_lock| Vault
    Vault -->|definitive failure refund| Token
    API -->|production-only RazorpayX| UPI[Merchant UPI / INR]
    API -->|paid evidence commitment| Vault
    Vault -->|callback-safe ft_transfer| Treasury[treasury.globalpay-receipts.testnet]
```

## Trust model

- NEAR authenticates the internal Ed25519 account key.
- Android Keystore and biometrics protect that key locally.
- The EMV card is a local possession factor for onboarding/card-reader flows. UPI and direct NEAR
  transfers use biometric approval; the vault does not verify a biometric or card.
- The backend cannot spend from the internal wallet and receives no private key.
- The backend verifies finalized chain data before recording a lock.
- Before provider hand-off the vault removes payer refund authority. Only verified paid evidence can
  move escrow to treasury; unknown payout outcome stays frozen and definitive failure may refund.
- RazorpayX, not the vault, reports bank payout state. A `Settled` crypto transfer is not independently
  generated bank-credit proof.

## Preserved systems

The EVM vaults, card smart-wallet contracts, Circle agent wallets, Pi terminal, Razorpay rails and
existing web payment path remain in the repository unchanged. They are the prior product baseline,
not disguised as NEAR functionality.
