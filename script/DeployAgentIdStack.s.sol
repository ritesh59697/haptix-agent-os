// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {HaptixRegistry, IAgentId} from "../src/agentid/HaptixRegistry.sol";
import {HaptixVault} from "../src/agentid/HaptixVault.sol";

/// @notice Deploys HaptixRegistry and HaptixVault together. All settings from env:
///         EXPECTED_CHAIN_ID, AGENT_ID_NFT, REGISTRY_APPLY_WINDOW_SECONDS,
///         REGISTRY_MAX_PENDING, VAULT_WINDOW_SECONDS, VAULT_WITHDRAW_WINDOW_SECONDS.
///
///   set -a; source .env; set +a; FOUNDRY_PROFILE=bsc forge script script/DeployAgentIdStack.s.sol:DeployAgentIdStack \
///     --rpc-url $BSC_RPC_URL --account <keystore-name> --broadcast --verify
contract DeployAgentIdStack is Script {
    function run() external returns (HaptixRegistry reg, HaptixVault vault) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC is on the wrong chain");
        IAgentId agentId = IAgentId(vm.envAddress("AGENT_ID_NFT"));
        require(address(agentId).code.length > 0, "AGENT_ID_NFT has no code on this chain");
        agentId.balanceOf(msg.sender); // must speak balanceOf(address)

        vm.startBroadcast();
        reg = new HaptixRegistry(
            agentId, vm.envUint("REGISTRY_APPLY_WINDOW_SECONDS"), vm.envUint("REGISTRY_MAX_PENDING")
        );
        vault = new HaptixVault(reg, vm.envUint("VAULT_WINDOW_SECONDS"), vm.envUint("VAULT_WITHDRAW_WINDOW_SECONDS"));
        vm.stopBroadcast();

        console.log("HaptixRegistry:", address(reg));
        console.log("HaptixVault:   ", address(vault));
    }
}
