// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {HaptixRegistry, IAgentId} from "../../src/agentid/HaptixRegistry.sol";
import {HaptixBadge} from "../../src/agentid/HaptixBadge.sol";

contract BadgeMockAgentId is IAgentId {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 n) external {
        balanceOf[who] = n;
    }
}

contract HaptixBadgeTest is Test {
    BadgeMockAgentId nft;
    HaptixRegistry reg;
    HaptixBadge badge;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");
    address token = makeAddr("token");

    function setUp() public {
        nft = new BadgeMockAgentId();
        reg = new HaptixRegistry(nft, 7 days, 4);
        badge = new HaptixBadge(reg);
        nft.set(alice, 1);
        nft.set(bob, 1);
    }

    function _open(address who, uint32 delay, bytes32 px, bytes32 py) internal {
        HaptixRegistry.TokenRule[] memory rules = new HaptixRegistry.TokenRule[](1);
        rules[0] = HaptixRegistry.TokenRule(token, HaptixRegistry.Rule(5e18, 2e18, 2e18));
        vm.prank(who);
        reg.open(rules, delay, HaptixRegistry.Passkey(px, py));
    }

    function test_claimRequiresAgentId() public {
        vm.prank(stranger);
        vm.expectRevert(HaptixBadge.NotAgentIdHolder.selector);
        badge.claim();
    }

    function test_claimRequiresOpenGuard() public {
        vm.prank(alice);
        vm.expectRevert(HaptixBadge.GuardNotOpen.selector);
        badge.claim();
        assertFalse(badge.canClaim(alice));
    }

    function test_claimOnceAndEnumerate() public {
        _open(alice, 1 days, 0, 0);
        _open(bob, 2 days, 0, 0);
        assertTrue(badge.canClaim(alice));

        vm.expectEmit(true, true, true, true);
        emit HaptixBadge.Transfer(address(0), alice, 1);
        vm.prank(alice);
        assertEq(badge.claim(), 1);
        vm.prank(bob);
        assertEq(badge.claim(), 2);

        assertEq(badge.totalSupply(), 2);
        assertEq(badge.holderAt(0), alice);
        assertEq(badge.holderAt(1), bob);
        assertEq(badge.holderAt(2), address(0));
        assertEq(badge.ownerOf(1), alice);
        assertEq(badge.tokenOf(bob), 2);
        assertEq(badge.balanceOf(alice), 1);
        assertEq(badge.balanceOf(stranger), 0);
        assertEq(badge.claimedAt(1), block.timestamp);
        assertFalse(badge.canClaim(alice));

        vm.prank(alice);
        vm.expectRevert(HaptixBadge.AlreadyClaimed.selector);
        badge.claim();
    }

    function test_calldataIsTheSameForEveryone() public pure {
        assertEq(abi.encodeCall(HaptixBadge.claim, ()), abi.encodePacked(HaptixBadge.claim.selector));
    }

    function test_soulbound() public {
        _open(alice, 1 days, 0, 0);
        vm.startPrank(alice);
        badge.claim();
        vm.expectRevert(HaptixBadge.Soulbound.selector);
        badge.transferFrom(alice, bob, 1);
        vm.expectRevert(HaptixBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, 1);
        vm.expectRevert(HaptixBadge.Soulbound.selector);
        badge.safeTransferFrom(alice, bob, 1, "");
        vm.expectRevert(HaptixBadge.Soulbound.selector);
        badge.approve(bob, 1);
        vm.expectRevert(HaptixBadge.Soulbound.selector);
        badge.setApprovalForAll(bob, true);
        vm.stopPrank();
        assertEq(badge.getApproved(1), address(0));
        assertFalse(badge.isApprovedForAll(alice, bob));
        assertEq(badge.ownerOf(1), alice);
    }

    function test_unknownTokenReverts() public {
        vm.expectRevert(HaptixBadge.NoSuchToken.selector);
        badge.ownerOf(1);
        vm.expectRevert(HaptixBadge.NoSuchToken.selector);
        badge.tokenURI(1);
        vm.expectRevert(HaptixBadge.ZeroAddress.selector);
        badge.balanceOf(address(0));
    }

    function test_interfaces() public view {
        assertTrue(badge.supportsInterface(0x01ffc9a7));
        assertTrue(badge.supportsInterface(0x80ac58cd));
        assertTrue(badge.supportsInterface(0x5b5e139f));
        assertFalse(badge.supportsInterface(0xffffffff));
    }

    function test_tokenURIIsLiveAndValid() public {
        _open(alice, 1 days, 0, 0);
        vm.prank(alice);
        badge.claim();

        string memory before = badge.tokenURI(1);
        _assertPrefix(before, "data:application/json;base64,");
        string memory json = _decodeJson(before);
        // the image is itself base64 SVG; check it starts right
        assertTrue(bytes(vm.parseJsonString(json, ".image")).length > 100);
        assertEq(vm.parseJsonString(json, ".name"), "Haptix Guarded Agent #1");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "open");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 24);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "off");

        // Lengthening the delay is instant; the badge follows it.
        vm.prank(alice);
        reg.lengthenDelay(3 days);
        json = _decodeJson(badge.tokenURI(1));
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 72);
    }

    function test_tokenURIShowsPasskey() public {
        _open(alice, 1 days, bytes32(uint256(1)), bytes32(uint256(2)));
        vm.prank(alice);
        badge.claim();
        assertEq(vm.parseJsonString(_decodeJson(badge.tokenURI(1)), ".attributes[2].value"), "on");
    }

    function testFuzz_base64MatchesReference(bytes memory data) public {
        vm.assume(data.length < 300);
        // Round-trip through the badge's encoder via a harness.
        B64Harness h = new B64Harness(reg);
        assertEq(h.enc(data), vm.toBase64(data));
    }

    // -------------------------------------------------------------- helpers

    function _assertPrefix(string memory s, string memory p) internal pure {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        require(a.length >= b.length, "short");
        for (uint256 i; i < b.length; i++) {
            require(a[i] == b[i], "prefix");
        }
    }

    function _decodeJson(string memory uri) internal pure returns (string memory) {
        bytes memory u = bytes(uri);
        uint256 skip = bytes("data:application/json;base64,").length;
        bytes memory out = new bytes(((u.length - skip) / 4) * 3);
        uint256 o;
        for (uint256 i = skip; i < u.length; i += 4) {
            uint256 n;
            uint256 pad;
            for (uint256 k; k < 4; k++) {
                bytes1 c = u[i + k];
                uint256 v;
                if (c >= "A" && c <= "Z") v = uint8(c) - 65;
                else if (c >= "a" && c <= "z") v = uint8(c) - 71;
                else if (c >= "0" && c <= "9") v = uint8(c) + 4;
                else if (c == "+") v = 62;
                else if (c == "/") v = 63;
                else pad++;
                n = (n << 6) | v;
            }
            out[o++] = bytes1(uint8(n >> 16));
            if (pad < 2) out[o++] = bytes1(uint8(n >> 8));
            if (pad < 1) out[o++] = bytes1(uint8(n));
        }
        assembly {
            mstore(out, o)
        }
        return string(out);
    }
}

/// Exposes the badge's internal base64 encoder.
contract B64Harness is HaptixBadge {
    constructor(HaptixRegistry r) HaptixBadge(r) {}

    function enc(bytes memory data) external pure returns (string memory) {
        return _b64(data);
    }
}

/// Fork test against the live registry and the real Agent ID contract.
/// Env: BSC_RPC_URL, HAPTIX_REGISTRY, AGENT_ID_GUARDED_HOLDER, AGENT_ID_SAMPLE_HOLDER_2.
contract HaptixBadgeForkTest is Test {
    function test_fork_liveRegistry() public {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        HaptixRegistry reg = HaptixRegistry(vm.envAddress("HAPTIX_REGISTRY"));
        HaptixBadge badge = new HaptixBadge(reg);
        address guarded = vm.envAddress("AGENT_ID_GUARDED_HOLDER");
        address unguarded = vm.envAddress("AGENT_ID_SAMPLE_HOLDER_2");
        assertEq(address(badge.agentId()), address(reg.agentId()));

        assertTrue(badge.canClaim(guarded));
        vm.prank(guarded);
        assertEq(badge.claim(), 1);
        assertEq(badge.holderAt(0), guarded);

        vm.prank(unguarded);
        vm.expectRevert(HaptixBadge.GuardNotOpen.selector);
        badge.claim();

        vm.writeFile("out/badge-fork-tokenuri.txt", badge.tokenURI(1));
    }
}
