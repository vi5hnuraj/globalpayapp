# GlobalPay — NEAR hackathon submission draft

## Project description

GlobalPay is a card-linked crypto wallet where a recipient can choose crypto or INR. A user can send
USDC.e directly to a NEAR account, or scan an ordinary Indian UPI QR and escrow the corresponding
stablecoin while a production-gated fiat treasury pays through RazorpayX. The Android experience
combines contactless-card possession checks, biometric key protection, private UPI parsing and a
callback-safe NEP-141 vault.

## Problem

UPI merchants receive INR and should not need a crypto wallet. Crypto holders need a familiar payment
experience without giving a backend custody of their blockchain key. Existing card and QR products do
not combine local physical-card authentication, an internal wallet and public escrow state.

## Solution

- A compatible bank card is read as a local possession factor for onboarding/NFC flows; it is not
  debited and routine UPI approval uses biometric only.
- A biometric unlocks an Ed25519 key encrypted by Android Keystore.
- The existing backend validates the QR and calculates an integer USDC/INR quote.
- The internal wallet signs a native NEAR transaction.
- `usdc.fakes.testnet.ft_transfer_call` creates an on-chain lock.
- The backend independently verifies every receipt and the resulting vault state.
- The payer can cancel only before payout starts. Definitive payout failure refunds; unknown payout
  stays frozen; verified-paid escrow settles to crypto treasury.

## NEAR integration

- Network ID: `testnet`
- NEP-141 token: `usdc.fakes.testnet` (`USDC.e`, test asset, 6 decimals)
- Rust escrow: `vault.globalpay-receipts.testnet`
- Crypto treasury: `treasury.globalpay-receipts.testnet`
- Native account IDs, Borsh transactions, Ed25519 signatures and base58 hashes
- NEP-141 `ft_transfer_call` and NEP-145 storage registration
- Cross-contract promise callback with real failure-path verification

No EVM chain ID, EIP-712, ERC-20 permit or EVM relayer is used in the NEAR execution path.

## Working evidence

- Deployed contract: `HrE6Ai9zL4HpEJC1kVKpzXMyLE6jidKgKAn4FobnXyy1`
- Lock: `73W2bhLAyD28getf1XWVUcmBZ6632uriwnVjXuF12S7a`
- Refund: `2WHh1PxWyFouUeqhw1tTkLZJRLVit5nsUzNmWqPatK4n`
- Failed refund safely restored: `574Q444RCD1oNeYVmDzHV7rN3WCqqeLkV2Kv6YGp2KfV`
- Successful retry: `6UnQ8ssJGkw8v2661Tvp4dfoBXZMrCpkzd4BaVEsTfvC`
- Flutter-signed lock/refund: `D7ULnQkgMtCrNi3Br3mda2fnwyR5PZNhkt4gyJGZFqRp` /
  `BRAkBMCQ1uA3ri7cb77KnPsbZEYR4W288vigqVYXyPAW`
- Vault upgrade/migration: `A7MRst1Es4Whit141hg2ZbqGSBec9uy5Zw75BrU5kVmp` /
  `H1tjXKJNyFWuagM2aZDrskKhUrhNk71VRERmheErzUyE`
- Synthetic no-INR treasury settlement: `29hecU8F96d476ZuRrcNdZCGVZ7BQZGHHaSZJonjqsys`

## Known limitations

- RazorpayX orchestration exists, but no real INR payout was authorized or proven. The synthetic
  settlement is crypto-treasury evidence only.
- The Flutter secure key completed an app-signed hardware run, but the available POCO has no NFC; its
  compile-time debug card stand-in is not physical-card evidence.
- Contract-level card/biometric verification and a complete payout board are excluded. Existing EVM
  agents/P2P/onramp remain preserved and are not falsely presented as NEAR-native.
- `USDC.e` is a permissionless testnet asset, not production Circle USDC.

## Team

- [@vi5hnuraj](https://github.com/vi5hnuraj)
- [@aagneye](https://github.com/aagneye)
