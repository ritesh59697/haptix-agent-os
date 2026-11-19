// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {HaptixRegistry, IAgentId} from "../src/agentid/HaptixRegistry.sol";

/// @notice Deploys HaptixRegistry against the Agent ID contract named in env.
///
/// @dev Nothing chain-specific is baked in. Set in `.env`:
///        AGENT_ID_NFT          Agent ID contract on the target chain
///        REGISTRY_APPLY_WINDOW_SECONDS  how long a ready queued change stays applicable
///        REGISTRY_MAX_PENDING           most queued changes per guard
///        EXPECTED_CHAIN_ID     chain you mean to deploy to (guards against a wrong RPC)
///        BSC_RPC_URL           RPC for that chain
///        ETHERSCAN_API_KEY     Etherscan v2 key (covers BscScan) for --verify
///
///      Run with a Foundry keystore, never a raw key:
///        source .env && FOUNDRY_PROFILE=bsc forge script script/DeployRegistry.s.sol:DeployRegistry \
///          --rpc-url $BSC_RPC_URL --account <keystore-name> --broadcast --verify
contract DeployRegistry is Script {
    function run() external returns (HaptixRegistry reg) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "RPC is on the wrong chain");

        IAgentId agentId = IAgentId(vm.envAddress("AGENT_ID_NFT"));
        require(address(agentId).code.length > 0, "AGENT_ID_NFT has no code on this chain");
        // Fails loudly if the address doesn't speak balanceOf(address).
        agentId.balanceOf(msg.sender);

        uint256 applyWindow = vm.envUint("REGISTRY_APPLY_WINDOW_SECONDS");
        uint256 maxPending = vm.envUint("REGISTRY_MAX_PENDING");

        vm.startBroadcast();
        reg = new HaptixRegistry(agentId, applyWindow, maxPending);
        vm.stopBroadcast();

        console.log("HaptixRegistry:", address(reg));
        console.log("Agent ID NFT:  ", address(agentId));
        console.log("Chain ID:      ", block.chainid);
        console.log("Apply window:  ", applyWindow);
        console.log("Max pending:   ", maxPending);
    }
}
