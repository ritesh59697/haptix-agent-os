#!/usr/bin/env bash
# Regenerates skills/haptix/abi.json from the compiled contracts so the
# skill's selectors can never drift from them.
set -euo pipefail
cd "$(dirname "$0")/.."
ins() { FOUNDRY_PROFILE=bsc forge inspect "$1" "$2" --json; }
R=src/agentid/HaptixRegistry.sol:HaptixRegistry
V=src/agentid/HaptixVault.sol:HaptixVault
B=src/agentid/HaptixBadge.sol:HaptixBadge
python3 - "$(ins $R methodIdentifiers)" "$(ins $R errors)" "$(ins $V methodIdentifiers)" "$(ins $V errors)" \
  "$(cast sig 'decimals()')" "$(cast sig 'symbol()')" "$(cast sig 'approve(address,uint256)')" \
  "$(cast sig 'allowance(address,address)')" "$(cast sig 'balanceOf(address)')" \
  "$(ins $B methodIdentifiers)" "$(ins $B errors)" <<'PY' > skills/haptix/abi.json
import json, sys
rm, re_, vm, ve = (json.loads(x) for x in sys.argv[1:5])
sel = lambda m: {sig.split("(")[0]: "0x" + s for sig, s in m.items()}
bm, be = (json.loads(x) for x in sys.argv[10:12])
errors = {"0x" + s: sig for sig, s in {**re_, **ve, **be}.items()}
print(json.dumps({
  "registry": sel(rm),
  "vault": sel(vm),
  "badge": sel(bm),
  "errors": errors,
  "erc20": {"decimals": sys.argv[5], "symbol": sys.argv[6], "approve": sys.argv[7],
            "allowance": sys.argv[8], "balanceOf": sys.argv[9]},
}, indent=2))
PY
cp skills/haptix/abi.json web/haptix-abi.json
echo "wrote skills/haptix/abi.json and web/haptix-abi.json"
