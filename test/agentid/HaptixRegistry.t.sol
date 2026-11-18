// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {HaptixRegistry, IAgentId} from "../../src/agentid/HaptixRegistry.sol";

contract MockAgentId is IAgentId {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 n) external {
        balanceOf[who] = n;
    }
}

contract HaptixRegistryTest is Test {
    MockAgentId nft;
    HaptixRegistry reg;

    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");
    address token = makeAddr("token");
    address payee = makeAddr("payee");
    uint32 constant DELAY = 1 days;

    function setUp() public {
        nft = new MockAgentId();
        reg = new HaptixRegistry(nft);
        nft.set(holder, 1);
    }

    function _rules(uint128 cap, uint128 ceil, uint128 pk)
        internal
        view
        returns (HaptixRegistry.TokenRule[] memory r)
    {
        r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(token, HaptixRegistry.Rule(cap, ceil, pk));
    }

    function _open() internal {
        vm.prank(holder);
        reg.open(_rules(100, 50, 10), DELAY, HaptixRegistry.Passkey(bytes32(uint256(1)), bytes32(uint256(2))));
    }

    // --- gating -----------------------------------------------------------

    function test_open_requiresAgentId() public {
        vm.prank(stranger);
        vm.expectRevert(HaptixRegistry.NotAgentIdHolder.selector);
        reg.open(_rules(100, 50, 10), DELAY, HaptixRegistry.Passkey(0, 0));
    }

    function test_open_recordsEverything() public {
        _open();
        HaptixRegistry.Guard memory g = reg.guardOf(holder);
        assertTrue(g.open);
        assertEq(g.changeDelay, DELAY);
        assertEq(g.passkey.x, bytes32(uint256(1)));
        HaptixRegistry.Rule memory r = reg.ruleOf(holder, token);
        assertEq(r.dailyCap, 100);
        assertEq(r.ceiling, 50);
        assertEq(r.passkeyAbove, 10);
    }

    function test_open_twiceReverts() public {
        _open();
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.AlreadyOpen.selector);
        reg.open(_rules(1, 1, 1), 0, HaptixRegistry.Passkey(0, 0));
    }

    function test_open_rejectsInconsistentRule() public {
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.BadRule.selector);
        reg.open(_rules(100, 50, 60), DELAY, HaptixRegistry.Passkey(0, 0)); // passkeyAbove > ceiling
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.BadRule.selector);
        reg.open(_rules(40, 50, 10), DELAY, HaptixRegistry.Passkey(0, 0)); // ceiling > dailyCap
    }

    // --- tightening is instant, loosening is not -----------------------------

    function test_tighten_instant() public {
        _open();
        vm.prank(holder);
        reg.tightenRule(token, HaptixRegistry.Rule(80, 40, 5));
        assertEq(reg.ruleOf(holder, token).dailyCap, 80);
    }

    function test_tighten_rejectsAnyLooserField() public {
        _open();
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.BadRule.selector);
        reg.tightenRule(token, HaptixRegistry.Rule(80, 40, 20)); // passkeyAbove up = looser
    }

    function test_tighten_worksAfterLosingAgentId() public {
        _open();
        nft.set(holder, 0);
        vm.prank(holder);
        reg.tightenRule(token, HaptixRegistry.Rule(0, 0, 0));
        assertEq(reg.ruleOf(holder, token).dailyCap, 0);
    }

    function test_loosen_waitsForDelay() public {
        _open();
        bytes memory data = abi.encode(token, HaptixRegistry.Rule(1000, 500, 100));
        vm.prank(holder);
        reg.queue(HaptixRegistry.Kind.Rule, data);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(HaptixRegistry.TooEarly.selector, block.timestamp + DELAY));
        reg.applyChange(HaptixRegistry.Kind.Rule, data);

        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        reg.applyChange(HaptixRegistry.Kind.Rule, data);
        assertEq(reg.ruleOf(holder, token).dailyCap, 1000);
    }

    function test_queue_rejectsTightening() public {
        _open();
        bytes memory data = abi.encode(token, HaptixRegistry.Rule(10, 5, 1));
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.NotLoosening.selector);
        reg.queue(HaptixRegistry.Kind.Rule, data);
    }

    function test_cancel_stopsQueuedChange() public {
        _open();
        bytes memory data = abi.encode(token, HaptixRegistry.Rule(1000, 500, 100));
        vm.prank(holder);
        bytes32 id = reg.queue(HaptixRegistry.Kind.Rule, data);
        vm.prank(holder);
        reg.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vm.expectRevert(HaptixRegistry.NotQueued.selector);
        reg.applyChange(HaptixRegistry.Kind.Rule, data);
    }

    function test_passkeyChange_isQueued() public {
        _open();
        bytes memory data = abi.encode(HaptixRegistry.Passkey(bytes32(uint256(9)), bytes32(uint256(9))));
        vm.prank(holder);
        reg.queue(HaptixRegistry.Kind.Passkey, data);
        assertEq(reg.guardOf(holder).passkey.x, bytes32(uint256(1)));
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        reg.applyChange(HaptixRegistry.Kind.Passkey, data);
        assertEq(reg.guardOf(holder).passkey.x, bytes32(uint256(9)));
    }

    function test_shorterDelay_isQueued_longerIsInstant() public {
        _open();
        vm.prank(holder);
        reg.lengthenDelay(2 days);
        assertEq(reg.guardOf(holder).changeDelay, 2 days);

        bytes memory data = abi.encode(uint32(0));
        vm.prank(holder);
        reg.queue(HaptixRegistry.Kind.Delay, data);
        assertEq(reg.guardOf(holder).changeDelay, 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(holder);
        reg.applyChange(HaptixRegistry.Kind.Delay, data);
        assertEq(reg.guardOf(holder).changeDelay, 0);
    }

    function test_allowance_loosenQueued_tightenInstant() public {
        _open();
        bytes memory data = abi.encode(payee, token, uint128(25));
        vm.prank(holder);
        reg.queue(HaptixRegistry.Kind.Allowance, data);
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        reg.applyChange(HaptixRegistry.Kind.Allowance, data);
        assertEq(reg.allowanceOf(holder, payee, token), 25);

        vm.prank(holder);
        reg.tightenAllowance(payee, token, 0);
        assertEq(reg.allowanceOf(holder, payee, token), 0);
    }

    function test_guardsAreIsolated() public {
        _open();
        nft.set(stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(HaptixRegistry.NotOpen.selector);
        reg.tightenRule(token, HaptixRegistry.Rule(0, 0, 0));
        assertEq(reg.ruleOf(holder, token).dailyCap, 100);
    }

    // --- against the real Agent ID contract (skipped without a BSC RPC) ------

    /// Run: BSC_RPC_URL=... AGENT_ID_NFT=... AGENT_ID_SAMPLE_HOLDER=... forge test --mt test_fork
    function test_fork_realAgentIdHolderCanOpen() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        IAgentId real = IAgentId(vm.envAddress("AGENT_ID_NFT"));
        address sample = vm.envAddress("AGENT_ID_SAMPLE_HOLDER");
        assertGt(real.balanceOf(sample), 0, "sample address holds no Agent ID");

        HaptixRegistry live = new HaptixRegistry(real);
        vm.prank(sample);
        live.open(_rules(100, 50, 10), DELAY, HaptixRegistry.Passkey(0, 0));
        assertTrue(live.guardOf(sample).open);

        vm.prank(stranger);
        vm.expectRevert(HaptixRegistry.NotAgentIdHolder.selector);
        live.open(_rules(100, 50, 10), DELAY, HaptixRegistry.Passkey(0, 0));
    }
}
