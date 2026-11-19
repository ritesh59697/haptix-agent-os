// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {HaptixRegistry} from "../src/agentid/HaptixRegistry.sol";
import {HaptixVault} from "../src/agentid/HaptixVault.sol";

/// @notice Deploys HaptixVault on top of an already-deployed HaptixRegistry.
///
/// @dev Set in `.env`: EXPECTED_CHAIN_ID, HAPTIX_REGISTRY, VAULT_WINDOW_SECONDS,
///      BSC_RPC_URL, ETHERSCAN_API_KEY. Then:
///        set -a; source .env; set +a; FOUNDRY_PROFILE=bsc forge script script/DeployVault.s.sol:DeployVault \
///          --rpc-url $BSC_RPC_URL --account <keystore-name> --broadcast --verify
contract DeployVault is Script {
    function run() external returns (HaptixVault vault) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC is on the wrong chain");

        HaptixRegistry registry = HaptixRegistry(vm.envAddress("HAPTIX_REGISTRY"));
        require(address(registry).code.length > 0, "HAPTIX_REGISTRY has no code on this chain");
        address agentId = address(registry.agentId());
        require(agentId.code.length > 0, "registry's Agent ID contract has no code");

        uint256 window = vm.envUint("VAULT_WINDOW_SECONDS");

        vm.startBroadcast();
        vault = new HaptixVault(registry, window);
        vm.stopBroadcast();

        console.log("HaptixVault:  ", address(vault));
        console.log("Registry:     ", address(registry));
        console.log("Agent ID NFT: ", agentId);
        console.log("Window (s):   ", window);
    }
}
