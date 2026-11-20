#!/usr/bin/env bash
# Deploys HaptixRegistry then HaptixVault with `forge create` (no fork simulation,
# so it survives flaky or load-balanced public RPCs). Asks for the keystore
# password once per contract.
#
# Usage (from the repo root):  scripts/deploy-agentid.sh <keystore-name> [existing-registry]
# Pass an already-deployed registry to deploy only the vault against it.
# Settings come from .env: BSC_RPC_URL, EXPECTED_CHAIN_ID, AGENT_ID_NFT,
# REGISTRY_APPLY_WINDOW_SECONDS, REGISTRY_MAX_PENDING, VAULT_WINDOW_SECONDS,
# VAULT_WITHDRAW_WINDOW_SECONDS, ETHERSCAN_API_KEY.
# DEPLOY_RPC_URL (env or CLI prefix) overrides BSC_RPC_URL for this run.
set -euo pipefail
cd "$(dirname "$0")/.."
ACCOUNT="${1:?usage: scripts/deploy-agentid.sh <keystore-name> [existing-registry]}"
REG="${2:-}"
OVERRIDE_RPC="${DEPLOY_RPC_URL:-}"
set -a; source .env; set +a
[ -z "$OVERRIDE_RPC" ] || BSC_RPC_URL="$OVERRIDE_RPC"
export FOUNDRY_PROFILE=bsc

for v in BSC_RPC_URL EXPECTED_CHAIN_ID AGENT_ID_NFT REGISTRY_APPLY_WINDOW_SECONDS REGISTRY_MAX_PENDING \
         VAULT_WINDOW_SECONDS VAULT_WITHDRAW_WINDOW_SECONDS ETHERSCAN_API_KEY; do
  [ -n "${!v:-}" ] || { echo "Missing $v in .env" >&2; exit 1; }
done

CHAIN=$(cast chain-id --rpc-url "$BSC_RPC_URL")
[ "$CHAIN" = "$EXPECTED_CHAIN_ID" ] || { echo "RPC is on chain $CHAIN, expected $EXPECTED_CHAIN_ID" >&2; exit 1; }
[ "$(cast code "$AGENT_ID_NFT" --rpc-url "$BSC_RPC_URL")" != "0x" ] || { echo "AGENT_ID_NFT has no code" >&2; exit 1; }
cast call "$AGENT_ID_NFT" "balanceOf(address)(uint256)" 0x0000000000000000000000000000000000000001 \
  --rpc-url "$BSC_RPC_URL" >/dev/null

create() { # <contract> <args...>
  local target="$1"; shift
  forge create "$target" --rpc-url "$BSC_RPC_URL" --account "$ACCOUNT" --broadcast --legacy \
    --constructor-args "$@" | tee /dev/stderr \
    | sed -n 's/^Deployed to: *\(0x[0-9a-fA-F]\{40\}\).*/\1/p'
}

if [ -n "$REG" ]; then
  echo "== Reusing HaptixRegistry $REG"
  ON=$(cast call "$REG" "agentId()(address)" --rpc-url "$BSC_RPC_URL")
  [ "$(echo "$ON" | tr A-F a-f)" = "$(echo "$AGENT_ID_NFT" | tr A-F a-f)" ] \
    || { echo "$REG is not a HaptixRegistry for $AGENT_ID_NFT (agentId=$ON)" >&2; exit 1; }
else
  echo "== HaptixRegistry"
  REG=$(create src/agentid/HaptixRegistry.sol:HaptixRegistry \
    "$AGENT_ID_NFT" "$REGISTRY_APPLY_WINDOW_SECONDS" "$REGISTRY_MAX_PENDING")
  [ -n "$REG" ] || { echo "Registry deploy did not report an address. Check the deployer's nonce before re-running." >&2; exit 1; }
fi

echo "== HaptixVault (registry $REG)"
VAULT=$(create src/agentid/HaptixVault.sol:HaptixVault \
  "$REG" "$VAULT_WINDOW_SECONDS" "$VAULT_WITHDRAW_WINDOW_SECONDS")
[ -n "$VAULT" ] || { echo "Vault deploy did not report an address (registry is live at $REG). Check the deployer's nonce before re-running." >&2; exit 1; }

echo "== Verifying on BscScan (deploys are done; a failure here can be retried)"
forge verify-contract "$REG" src/agentid/HaptixRegistry.sol:HaptixRegistry --chain "$EXPECTED_CHAIN_ID" --watch \
  --constructor-args "$(cast abi-encode 'f(address,uint256,uint256)' "$AGENT_ID_NFT" "$REGISTRY_APPLY_WINDOW_SECONDS" "$REGISTRY_MAX_PENDING")" || true
forge verify-contract "$VAULT" src/agentid/HaptixVault.sol:HaptixVault --chain "$EXPECTED_CHAIN_ID" --watch \
  --constructor-args "$(cast abi-encode 'f(address,uint256,uint256)' "$REG" "$VAULT_WINDOW_SECONDS" "$VAULT_WITHDRAW_WINDOW_SECONDS")" || true

echo
echo "HaptixRegistry: $REG"
echo "HaptixVault:    $VAULT"
