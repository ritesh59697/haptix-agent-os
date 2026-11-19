// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {HaptixRegistry, IAgentId} from "../../src/agentid/HaptixRegistry.sol";
import {HaptixVault} from "../../src/agentid/HaptixVault.sol";

/// Local-chain fixture for exercising the skill end to end (anvil, no fork).
contract FixtureAgentId is IAgentId {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 n) external {
        balanceOf[who] = n;
    }
}

contract FixtureToken {
    string public symbol = "tUSD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Env: FIXTURE_HOLDER, FIXTURE_FRIEND, plus the deploy settings used in production.
contract LocalFixture is Script {
    function run() external {
        address holder = vm.envAddress("FIXTURE_HOLDER");
        address friend = vm.envAddress("FIXTURE_FRIEND");
        vm.startBroadcast();
        FixtureAgentId nft = new FixtureAgentId();
        FixtureToken usd = new FixtureToken();
        nft.set(holder, 1);
        nft.set(friend, 1);
        usd.mint(holder, 10e18);
        HaptixRegistry reg = new HaptixRegistry(
            nft, vm.envUint("REGISTRY_APPLY_WINDOW_SECONDS"), vm.envUint("REGISTRY_MAX_PENDING")
        );
        HaptixVault vault =
            new HaptixVault(reg, vm.envUint("VAULT_WINDOW_SECONDS"), vm.envUint("VAULT_WITHDRAW_WINDOW_SECONDS"));
        vm.stopBroadcast();
        console.log("TOKEN", address(usd));
        console.log("REGISTRY", address(reg));
        console.log("VAULT", address(vault));
    }
}
