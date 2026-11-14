#!/usr/bin/env bash
# Add the Flutter-generated Ed25519 public key to the existing NEAR demo account.
# The private key stays encrypted on the Android device and is never passed to this script.
set -euo pipefail

ACCOUNT_ID="${ACCOUNT_ID:-demo.globalpay-receipts.testnet}"
PUBLIC_KEY="${PUBLIC_KEY:?set PUBLIC_KEY to the ed25519:... key shown by the Flutter app}"
NETWORK="${NETWORK:-testnet}"

case "$PUBLIC_KEY" in
  ed25519:*) ;;
  *) echo "PUBLIC_KEY must start with ed25519:" >&2; exit 1 ;;
esac

command -v near >/dev/null || { echo "near-cli-rs is required" >&2; exit 1; }

if near account list-keys "$ACCOUNT_ID" network-config "$NETWORK" now | grep -Fq "$PUBLIC_KEY"; then
  echo "$PUBLIC_KEY is already active on $ACCOUNT_ID"
  exit 0
fi

echo "Adding the Flutter public key to $ACCOUNT_ID on $NETWORK."
echo "No private key is read from or written to this repository."
near account add-key "$ACCOUNT_ID" grant-full-access \
  use-manually-provided-public-key "$PUBLIC_KEY" \
  network-config "$NETWORK" sign-with-keychain send

echo
echo "Verify one app-signed transaction before removing the temporary near-cli bootstrap key."
