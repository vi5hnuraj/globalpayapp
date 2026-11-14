# ADR 002: NEAR payment intent and local authentication

- **Status:** Accepted for the hackathon MVP
- **Date:** 2026-11-14

## Context

The existing product uses EIP-712, ERC-20 permit and EVM smart-wallet signature checks. Those formats
must not be copied into the NEAR execution path.

The hackathon contract intentionally does not verify EMV RSA or biometric P-256 proofs. The physical
card and fingerprint are local authentication factors for the internal wallet key; the NEAR account's
Ed25519 signature is the blockchain authorization.

## Decision

The backend creates a private NEAR quote containing:

- a unique lock ID;
- NEAR account ID;
- token and vault account IDs;
- token base-unit amount;
- INR paise and integer exchange rate;
- private UPI QR/payee data stored only in SQLite;
- a short expiry and random view token.

The payer sends one native NEAR transaction to `usdc.fakes.testnet.ft_transfer_call`:

```json
{
  "receiver_id": "vault.globalpay-receipts.testnet",
  "amount": "<base units>",
  "memo": "GlobalPay NEAR MVP lock",
  "msg": "{\"id\":\"<quote id>\"}"
}
```

The internal Flutter wallet:

1. Reads and validates the UPI QR.
2. Receives the quote from the existing backend.
3. Has the EMV card sign four bytes derived from the exact quote and verifies that DDA signature
   locally against the card key recovered from its certificate chain.
4. Uses a strong biometric prompt to decrypt the Ed25519 seed with Android Keystore AES-GCM.
5. Borsh-serializes and signs the native NEAR transaction.
6. Sends the signed transaction to NEAR RPC.

The backend then fetches the finalized transaction independently and checks:

- signer account;
- token receiver;
- exactly one `ft_transfer_call` action;
- one yoctoNEAR deposit;
- vault receiver, amount and lock ID;
- top-level and every receipt outcome;
- the resulting lock read directly from the vault.

Only after all checks pass is the quote mapped idempotently to the transaction hash.

## Security boundaries

- The card is not debited and its payment private key is never extracted.
- The Ed25519 seed is never sent to the backend.
- Flutter preferences contain ciphertext, IV, public key and account ID only.
- The backend quote is not an on-chain authorization signature in this MVP. The payer controls their
  own test tokens, and there is no merchant payout or settlement-complete method.
- `Locked` means tokens are in escrow. It does not mean the merchant received INR.

## Deferred

- Contract-level EMV or biometric verification.
- Gas sponsorship/meta-transactions.
- Production account recovery.
- Signed backend quote authorization for a settlement-capable vault.
