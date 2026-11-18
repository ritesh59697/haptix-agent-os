#!/usr/bin/env bash
# Builds the `baw contract-call preview` command that opens a Haptix guard
# from an Agentic Wallet. Prints the command; runs nothing on-chain.
#
# Usage:
#   scripts/agentid-open.sh <agentic-wallet-address> <token> <dailyCap> <ceiling> <passkeyAbove> <changeDelaySeconds>
# Amounts are human units (e.g. 5 = 5 tokens); decimals are read from the token on-chain.
#
# Needs in env (or .env): BSC_RPC_URL, HAPTIX_REGISTRY, EXPECTED_CHAIN_ID
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && . ./.env && set +a

if [ $# -ne 6 ]; then
  sed -n '2,8p' "$0"; exit 1
fi
FROM=$1 TOKEN=$2 CAP=$3 CEIL=$4 PK=$5 DELAY=$6
: "${BSC_RPC_URL:?set BSC_RPC_URL}" "${HAPTIX_REGISTRY:?set HAPTIX_REGISTRY}" "${EXPECTED_CHAIN_ID:?set EXPECTED_CHAIN_ID}"

CHAIN=$(cast chain-id --rpc-url "$BSC_RPC_URL")
[ "$CHAIN" = "$EXPECTED_CHAIN_ID" ] || { echo "RPC is on chain $CHAIN, expected $EXPECTED_CHAIN_ID" >&2; exit 1; }

DEC=$(cast call "$TOKEN" "decimals()(uint8)" --rpc-url "$BSC_RPC_URL")
to_units() { cast to-unit "$(cast parse-units "$1" "$DEC")" wei; }
CAP_U=$(to_units "$CAP"); CEIL_U=$(to_units "$CEIL"); PK_U=$(to_units "$PK")

AGENT_ID=$(cast call "$HAPTIX_REGISTRY" "agentId()(address)" --rpc-url "$BSC_RPC_URL")
HELD=$(cast call "$AGENT_ID" "balanceOf(address)(uint256)" "$FROM" --rpc-url "$BSC_RPC_URL")
[ "$HELD" != "0" ] || echo "WARNING: $FROM holds no Agent ID -- open() will revert." >&2

DATA=$(cast calldata "open((address,(uint128,uint128,uint128))[],uint32,(bytes32,bytes32))" \
  "[($TOKEN,($CAP_U,$CEIL_U,$PK_U))]" "$DELAY" \
  "(0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)")

# Simulate as the wallet before handing the command over.
cast call "$HAPTIX_REGISTRY" "$DATA" --from "$FROM" --rpc-url "$BSC_RPC_URL" >/dev/null \
  && echo "Simulation: OK" >&2 || { echo "Simulation reverted -- don't send." >&2; exit 1; }

echo "token decimals: $DEC | dailyCap=$CAP_U ceiling=$CEIL_U passkeyAbove=$PK_U delay=${DELAY}s" >&2
echo
echo "baw contract-call preview --binanceChainId $EXPECTED_CHAIN_ID --from $FROM --to $HAPTIX_REGISTRY --value 0 --inputData $DATA --json"
