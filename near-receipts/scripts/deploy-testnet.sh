#!/usr/bin/env bash
# Deploy the receipt anchor to NEAR testnet with near-cli-rs, and let one account write receipts.
#
# No wallet and no prior account are needed: `--use-faucet` creates the contract account and funds it.
# Nothing here is a secret — the CLI keeps the key in its own config, not in this repo.
#
#   CONTRACT_ID=receipts.<you>.testnet ./scripts/deploy-testnet.sh
#   CONTRACT_ID=receipts.<you>.testnet ANCHOR_ACCOUNT=<you>.testnet ./scripts/deploy-testnet.sh
#
# ANCHOR_ACCOUNT defaults to the contract account itself, which is fine for a demo: the backend then
# signs with the key the CLI already holds.
set -euo pipefail

CONTRACT_ID="${CONTRACT_ID:?set CONTRACT_ID, e.g. receipts.yourname.testnet (must end in .testnet)}"
NETWORK="${NETWORK:-testnet}"
ANCHOR_ACCOUNT="${ANCHOR_ACCOUNT:-$CONTRACT_ID}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$HERE/target/wasm32-unknown-unknown/release/globalpay_receipts.wasm"

command -v near >/dev/null || {
  echo "near-cli-rs is required:" >&2
  echo "  curl --proto '=https' --tlsv1.2 -LsSf https://github.com/near/near-cli-rs/releases/latest/download/near-cli-rs-installer.sh | sh" >&2
  exit 1
}

view() {  # view <method> [json] — read a method, or fail if the account is not deployed yet
  local args="${2:-}"
  [ -n "$args" ] || args='{}'
  near contract call-function as-read-only "$CONTRACT_ID" "$1" json-args "$args" \
    network-config "$NETWORK" now
}

echo "==> building the contract for wasm32"
( cd "$HERE" && cargo build --target wasm32-unknown-unknown --release )
test -f "$WASM" || { echo "no wasm at $WASM" >&2; exit 1; }

# Three separate questions: does the account exist, is a contract on it, and is that contract
# initialised? Deploying over an initialised contract with an init call would panic, and creating an
# account that already exists would fail, so ask each one before acting.
if near account view-account-summary "$CONTRACT_ID" network-config "$NETWORK" now >/dev/null 2>&1; then
  echo "==> $CONTRACT_ID already exists; keeping it and its 10 NEAR"
else
  echo "==> creating $CONTRACT_ID with faucet funds"
  near create-account "$CONTRACT_ID" --use-faucet --network-id "$NETWORK"
fi

if view owner >/dev/null 2>&1; then
  echo "==> $CONTRACT_ID is already initialised; not re-deploying (a re-init would panic)"
else
  echo "==> deploying and initialising (owner = $CONTRACT_ID)"
  near contract deploy "$CONTRACT_ID" use-file "$WASM" \
    with-init-call new json-args "{\"owner\":\"$CONTRACT_ID\"}" \
    prepaid-gas '100 TeraGas' attached-deposit '0 NEAR' \
    network-config "$NETWORK" sign-with-keychain send
fi

if view anchors 2>/dev/null | grep -q "\"$ANCHOR_ACCOUNT\""; then
  echo "==> $ANCHOR_ACCOUNT can already anchor"
else
  echo "==> allowing $ANCHOR_ACCOUNT to anchor receipts"
  # An open anchor method would let anyone claim a payment id first, so the writer list is explicit.
  near contract call-function as-transaction "$CONTRACT_ID" add_anchor \
    json-args "{\"account\":\"$ANCHOR_ACCOUNT\"}" \
    prepaid-gas '30 TeraGas' attached-deposit '0 NEAR' \
    sign-as "$CONTRACT_ID" network-config "$NETWORK" sign-with-keychain send
fi

echo "==> done. Anchors:"
view anchors
echo
echo "Point the backend at it with:"
echo "  NEAR_RECEIPTS_CONTRACT=$CONTRACT_ID"
echo "  NEAR_ANCHOR_ACCOUNT=$ANCHOR_ACCOUNT"
