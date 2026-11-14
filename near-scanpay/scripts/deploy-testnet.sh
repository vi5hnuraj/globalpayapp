#!/usr/bin/env bash
# Deploy the GlobalPay vault to NEAR testnet with near-cli-rs.
#
# Needs a NEP-141 token that supports ft_transfer_call (the vault locks funds through that callback),
# and an account for the vault. Nothing here holds a key: near-cli-rs keeps it in its own keychain.
#
# Fresh install:
#   CONTRACT_ID=vault.you.testnet TOKEN_ACCOUNT=some-token.testnet \
#   TREASURY_ACCOUNT=treasury.you.testnet ./scripts/deploy-testnet.sh
#
# Explicit upgrade of the legacy lock/refund deployment:
#   MODE=upgrade CONTRACT_ID=... TOKEN_ACCOUNT=... TREASURY_ACCOUNT=... ./scripts/deploy-testnet.sh
set -euo pipefail

CONTRACT_ID="${CONTRACT_ID:?set CONTRACT_ID, e.g. vault.yourname.testnet}"
TOKEN_ACCOUNT="${TOKEN_ACCOUNT:?set TOKEN_ACCOUNT, a verified NEP-141 token with ft_transfer_call}"
NETWORK="${NETWORK:-testnet}"
OWNER_ACCOUNT="${OWNER_ACCOUNT:-$CONTRACT_ID}"
SETTLER_ACCOUNT="${SETTLER_ACCOUNT:-$OWNER_ACCOUNT}"
TREASURY_ACCOUNT="${TREASURY_ACCOUNT:?set TREASURY_ACCOUNT, the registered NEP-141 treasury}"
MODE="${MODE:-auto}" # auto (fresh only) | upgrade | migrate
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM="$HERE/target/wasm32-unknown-unknown/release/globalpay_vault.wasm"

case "$MODE" in
  auto|upgrade|migrate) ;;
  *) echo "MODE must be auto, upgrade, or migrate" >&2; exit 1 ;;
esac

command -v near >/dev/null || {
  echo "near-cli-rs is required:" >&2
  echo "  curl --proto '=https' --tlsv1.2 -LsSf https://github.com/near/near-cli-rs/releases/latest/download/near-cli-rs-installer.sh | sh" >&2
  exit 1
}

view() {  # view <method> [json]
  local args="${2:-}"
  [ -n "$args" ] || args='{}'
  near contract call-function as-read-only "$CONTRACT_ID" "$1" json-args "$args" \
    network-config "$NETWORK" now
}

echo "==> building the vault for wasm32"
( cd "$HERE" && cargo build --target wasm32-unknown-unknown --release )
test -f "$WASM" || { echo "no wasm at $WASM" >&2; exit 1; }

ACCOUNT_EXISTS=0
if near account view-account-summary "$CONTRACT_ID" network-config "$NETWORK" now >/dev/null 2>&1; then
  ACCOUNT_EXISTS=1
  echo "==> $CONTRACT_ID already exists; keeping it"
else
  if [ "$MODE" != auto ]; then
    echo "cannot $MODE: $CONTRACT_ID does not exist" >&2
    exit 1
  fi
  echo "==> creating $CONTRACT_ID with faucet funds"
  near create-account "$CONTRACT_ID" --use-faucet --network-id "$NETWORK"
  ACCOUNT_EXISTS=1
fi

INITIALIZED=0
HAS_TREASURY=0
if view owner >/dev/null 2>&1; then
  INITIALIZED=1
  if view treasury >/dev/null 2>&1; then
    HAS_TREASURY=1
  fi
fi

if [ "$MODE" = migrate ]; then
  echo "==> running migration only (use this after an interrupted code deployment)"
  near contract call-function as-transaction "$CONTRACT_ID" migrate json-args \
    "{\"treasury\":\"$TREASURY_ACCOUNT\"}" prepaid-gas '50 TeraGas' attached-deposit '0 NEAR' \
    sign-as "$OWNER_ACCOUNT" network-config "$NETWORK" sign-with-keychain send
elif [ "$INITIALIZED" -eq 0 ]; then
  if [ "$ACCOUNT_EXISTS" -eq 1 ] && [ "$MODE" = upgrade ]; then
    echo "cannot identify existing contract state; use MODE=migrate only if new code is already deployed" >&2
    exit 1
  fi
  echo "==> deploying and initialising"
  near contract deploy "$CONTRACT_ID" use-file "$WASM" \
    with-init-call new json-args \
      "{\"owner\":\"$OWNER_ACCOUNT\",\"token\":\"$TOKEN_ACCOUNT\",\"settler\":\"$SETTLER_ACCOUNT\",\"treasury\":\"$TREASURY_ACCOUNT\"}" \
    prepaid-gas '100 TeraGas' attached-deposit '0 NEAR' \
    network-config "$NETWORK" sign-with-keychain send
elif [ "$MODE" = auto ]; then
  echo "==> $CONTRACT_ID is already initialised; refusing to modify it without MODE=upgrade"
elif [ "$MODE" = upgrade ]; then
  LEGACY=$((1 - HAS_TREASURY))
  echo "==> deploying upgraded code (legacy_state=$LEGACY)"
  near contract deploy "$CONTRACT_ID" use-file "$WASM" without-init-call \
    network-config "$NETWORK" sign-with-keychain send
  if [ "$LEGACY" -eq 1 ]; then
    echo "==> migrating legacy state and preserving every lock"
    near contract call-function as-transaction "$CONTRACT_ID" migrate json-args \
      "{\"treasury\":\"$TREASURY_ACCOUNT\"}" prepaid-gas '50 TeraGas' attached-deposit '0 NEAR' \
      sign-as "$OWNER_ACCOUNT" network-config "$NETWORK" sign-with-keychain send
  fi
fi

echo "==> configuration"
view owner
view token
view settler
view treasury
view total_locked
echo
echo "Point the backend at it with:"
echo "  NEAR_VAULT_CONTRACT=$CONTRACT_ID"
echo "  NEAR_VAULT_TOKEN=$TOKEN_ACCOUNT"
echo "  NEAR_NETWORK_ID=$NETWORK"
