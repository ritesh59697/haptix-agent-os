#!/usr/bin/env bash
# Regenerates skills/haptix/abi.json from the compiled HaptixRegistry so the
# skill's selectors can never drift from the contract.
set -euo pipefail
cd "$(dirname "$0")/.."
C=src/agentid/HaptixRegistry.sol:HaptixRegistry
M=$(FOUNDRY_PROFILE=bsc forge inspect $C methodIdentifiers --json)
E=$(FOUNDRY_PROFILE=bsc forge inspect $C errors --json)
python3 - "$M" "$E" "$(cast sig 'decimals()')" "$(cast sig 'symbol()')" <<'PY' > skills/haptix/abi.json
import json, sys
m, e = json.loads(sys.argv[1]), json.loads(sys.argv[2])
out = {
  "registry": {sig.split("(")[0]: "0x" + sel for sig, sel in m.items()},
  "errors": {"0x" + sel: sig for sig, sel in e.items()},
  "erc20": {"decimals": sys.argv[3], "symbol": sys.argv[4]},
}
print(json.dumps(out, indent=2))
PY
echo "wrote skills/haptix/abi.json"
