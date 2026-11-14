# NEAR hackathon demo

For the complete card → biometric → wallet → crypto/UPI → activity screenshot sequence, use
[`DEMO_STORY.md`](DEMO_STORY.md).

## Already reproducible without a phone

1. Inspect `deployments/near-testnet.json`.
2. Open the deployed vault:
   `https://explorer.testnet.near.org/accounts/vault.globalpay-receipts.testnet`.
3. Open lock transaction `73W2bhLAyD28getf1XWVUcmBZ6632uriwnVjXuF12S7a`.
4. Observe the `escrow_locked` event and token transfer.
5. Open refund transaction `2WHh1PxWyFouUeqhw1tTkLZJRLVit5nsUzNmWqPatK4n`.
6. Observe `refund_pending`, token transfer, then `escrow_refunded`.
7. Open failure transaction `574Q444RCD1oNeYVmDzHV7rN3WCqqeLkV2Kv6YGp2KfV`.
8. Observe the failed token receipt and `refund_failed`; the lock returned to `Locked`.
9. Open retry `6UnQ8ssJGkw8v2661Tvp4dfoBXZMrCpkzd4BaVEsTfvC`.
10. Open migration `H1tjXKJNyFWuagM2aZDrskKhUrhNk71VRERmheErzUyE`.
11. Open synthetic settlement `29hecU8F96d476ZuRrcNdZCGVZ7BQZGHHaSZJonjqsys` and show the
    vault-to-treasury test-token transfer. Say explicitly: **no INR payout was made**.

## Internal-wallet phone demo

Requirements: Android 8+, strong biometric enrolled, USB debugging, and NFC for the real-card step.

```sh
cd apps/mobile-flutter
flutter build apk --debug \
  --dart-define=NEAR_MVP=true \
  --dart-define=NEAR_ACCOUNT_ID=demo.globalpay-receipts.testnet \
  --dart-define=GLOBALPAY_URL=http://127.0.0.1:8788
adb reverse tcp:8788 tcp:8788
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Start the API without EVM workers:

```sh
cd services/api-py
CHAINS=near WORKERS=0 FX=1 uv run uvicorn app.main:app --host 127.0.0.1 --port 8788
```

In the app:

1. Create the biometric NEAR key.
2. Copy only its `ed25519:...` public key.
3. On the operator machine:

   ```sh
   cd near-scanpay
   PUBLIC_KEY='ed25519:...' ./scripts/provision-demo-key.sh
   ```

4. Refresh until the wallet shows **Active** and the real on-chain holdings.
5. Demonstrate **Receive** (network-bound account QR) and **Send** (NEP-141 `ft_transfer`) if desired.
6. Scan a UPI QR, enter INR, and review exact merchant INR + user USDC.e amounts.
7. Tap **Pay with fingerprint**. There is no card tap in the UPI flow.
8. Show the base58 transaction hash and `Locked` state. With payouts disabled, the app honestly says
   INR payout is disabled and offers **Cancel before payout starts**.
9. Approve cancellation biometrically and show `Refunded`.
10. Show **Cards**: card role/public fingerprint only, with PAN and bank identity absent. On a phone
    without NFC, the screen labels the compile-time stand-in as a debug test—not physical proof.

Never expose the seed or near-cli key. Do not use `DEV_FAKE_CARD` in a claimed physical-card demo.

## Honest fallback if NFC hardware is unavailable

Show the existing real-card evidence/code separately, then show the real NEAR lock/refund evidence.
State clearly that the combined physical-card-to-NEAR run was not performed on the available device.
