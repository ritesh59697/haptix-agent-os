#!/usr/bin/env bash
# Deploys HaptixBadge against an existing HaptixRegistry with `forge create`, then verifies it.
# Usage (from the repo root):  scripts/deploy-badge.sh <keystore-name>
# Settings from .env: BSC_RPC_URL, EXPECTED_CHAIN_ID, HAPTIX_REGISTRY, AGENT_ID_NFT, ETHERSCAN_API_KEY.
# DEPLOY_RPC_URL (env or CLI prefix) overrides BSC_RPC_URL for this run.
set -euo pipefail
cd "$(dirname "$0")/.."
ACCOUNT="${1:?usage: scripts/deploy-badge.sh <keystore-name>}"
OVERRIDE_RPC="${DEPLOY_RPC_URL:-}"
set -a; source .env; set +a
[ -z "$OVERRIDE_RPC" ] || BSC_RPC_URL="$OVERRIDE_RPC"
export FOUNDRY_PROFILE=bsc

for v in BSC_RPC_URL EXPECTED_CHAIN_ID HAPTIX_REGISTRY AGENT_ID_NFT ETHERSCAN_API_KEY; do
  [ -n "${!v:-}" ] || { echo "Missing $v in .env" >&2; exit 1; }
done
CHAIN=$(cast chain-id --rpc-url "$BSC_RPC_URL")
[ "$CHAIN" = "$EXPECTED_CHAIN_ID" ] || { echo "RPC is on chain $CHAIN, expected $EXPECTED_CHAIN_ID" >&2; exit 1; }
ON=$(cast call "$HAPTIX_REGISTRY" "agentId()(address)" --rpc-url "$BSC_RPC_URL")
[ "$(echo "$ON" | tr A-F a-f)" = "$(echo "$AGENT_ID_NFT" | tr A-F a-f)" ] \
  || { echo "$HAPTIX_REGISTRY is not a HaptixRegistry for $AGENT_ID_NFT (agentId=$ON)" >&2; exit 1; }

echo "== HaptixBadge (registry $HAPTIX_REGISTRY)"
BADGE=$(forge create src/agentid/HaptixBadge.sol:HaptixBadge --rpc-url "$BSC_RPC_URL" --account "$ACCOUNT" \
  --broadcast --legacy --constructor-args "$HAPTIX_REGISTRY" | tee /dev/stderr \
  | sed -n 's/^Deployed to: *\(0x[0-9a-fA-F]\{40\}\).*/\1/p')
[ -n "$BADGE" ] || { echo "Badge deploy did not report an address. Check the deployer's nonce before re-running." >&2; exit 1; }

echo "== Verifying on BscScan (the deploy is done; a failure here can be retried)"
forge verify-contract "$BADGE" src/agentid/HaptixBadge.sol:HaptixBadge --chain "$EXPECTED_CHAIN_ID" --watch \
  --constructor-args "$(cast abi-encode 'f(address)' "$HAPTIX_REGISTRY")" || true

echo
echo "HaptixBadge: $BADGE"
