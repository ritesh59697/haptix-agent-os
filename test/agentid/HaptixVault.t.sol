// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {HaptixRegistry, IAgentId} from "../../src/agentid/HaptixRegistry.sol";
import {HaptixVault} from "../../src/agentid/HaptixVault.sol";
import {WebAuthn} from "../../src/WebAuthn.sol";

contract MockAgentId is IAgentId {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 n) external {
        balanceOf[who] = n;
    }
}

/// Plain ERC-20 that returns bool.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external virtual returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external virtual returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal virtual {
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// Takes a 1% fee on every move.
contract FeeToken is MockToken {
    function _move(address f, address to, uint256 a) internal override {
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
    }
}

/// Re-enters the vault from inside transfer() and records how it was refused.
/// It holds an Agent ID, a guard and a deposit of its own, so the inner pay
/// would succeed if the vault had no reentrancy lock.
contract ReentrantToken is MockToken {
    HaptixVault public vault;
    address public payee;
    bytes public innerError;
    bool public innerSucceeded;

    function arm(HaptixVault v, address p) external {
        vault = v;
        payee = p;
    }

    function transfer(address to, uint256 a) external override returns (bool) {
        _move(msg.sender, to, a);
        if (address(vault) != address(0)) {
            HaptixVault v = vault;
            vault = HaptixVault(address(0)); // re-enter once
            try v.pay(address(this), payee, 1, "") {
                innerSucceeded = true;
            } catch (bytes memory e) {
                innerError = e;
            }
        }
        return true;
    }
}

contract HaptixVaultTest is Test {
    MockAgentId nft;
    HaptixRegistry reg;
    HaptixVault vault;
    MockToken usd;

    uint256 constant WINDOW = 1 days;
    uint32 constant DELAY = 1 days;
    uint256 constant APPLY_WINDOW = 7 days;
    uint256 constant MAX_PENDING = 8;
    uint256 constant WITHDRAW_WINDOW = 3 days;
    uint256 constant PK = 0xA11CE5EC2E7;
    uint256 constant N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

    address holder = makeAddr("holder");
    address friend = makeAddr("friend"); // holds an Agent ID
    address shop = makeAddr("shop"); // no Agent ID
    address stranger = makeAddr("stranger");

    function setUp() public {
        nft = new MockAgentId();
        reg = new HaptixRegistry(nft, APPLY_WINDOW, MAX_PENDING);
        vault = new HaptixVault(reg, WINDOW, WITHDRAW_WINDOW);
        usd = new MockToken();
        nft.set(holder, 1);
        nft.set(friend, 1);
        _open(holder, address(usd), true);
        _fund(holder, usd, 100e18);
    }

    // --- helpers ------------------------------------------------------------

    function _open(address who, address token, bool withPasskey) internal {
        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(token, HaptixRegistry.Rule(10e18, 5e18, 1e18));
        HaptixRegistry.Passkey memory p;
        if (withPasskey) {
            (uint256 x, uint256 y) = vm.publicKeyP256(PK);
            p = HaptixRegistry.Passkey(bytes32(x), bytes32(y));
        }
        vm.prank(who);
        reg.open(r, DELAY, p);
    }

    function _fund(address who, MockToken t, uint256 amount) internal {
        t.mint(who, amount);
        vm.startPrank(who);
        t.approve(address(vault), amount);
        vault.deposit(address(t), amount);
        vm.stopPrank();
    }

    function _b64url(bytes memory data) internal pure returns (string memory) {
        bytes memory tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        bytes memory out = new bytes((data.length * 4 + 2) / 3);
        uint256 j;
        for (uint256 i; i < data.length; i += 3) {
            uint256 c = uint256(uint8(data[i])) << 16;
            if (i + 1 < data.length) c |= uint256(uint8(data[i + 1])) << 8;
            if (i + 2 < data.length) c |= uint256(uint8(data[i + 2]));
            out[j++] = tbl[(c >> 18) & 63];
            if (j < out.length) out[j++] = tbl[(c >> 12) & 63];
            if (j < out.length) out[j++] = tbl[(c >> 6) & 63];
            if (j < out.length) out[j++] = tbl[c & 63];
        }
        return string(out);
    }

    /// A real WebAuthn assertion, built the way a browser builds one.
    function _sign(uint256 key, bytes32 challenge, bytes1 flags) internal returns (bytes memory) {
        bytes memory authData = abi.encodePacked(keccak256("rpId"), flags, uint32(1));
        string memory cd = string.concat(
            '{"type":"webauthn.get","challenge":"',
            _b64url(abi.encodePacked(challenge)),
            '","origin":"https://haptix-agent-os.vercel.app","crossOrigin":false}'
        );
        bytes32 message = sha256(abi.encodePacked(authData, sha256(bytes(cd))));
        (bytes32 r, bytes32 s) = vm.signP256(key, message);
        uint256 sv = uint256(s);
        if (sv > N / 2) sv = N - sv;
        return abi.encode(WebAuthn.Signature(authData, cd, 23, 1, uint256(r), sv));
    }

    function _signPay(address to, uint256 amount) internal returns (bytes memory) {
        return _sign(PK, vault.payChallenge(holder, address(usd), to, amount), 0x05);
    }

    function _pay(address to, uint256 amount, bytes memory auth) internal {
        vm.prank(holder);
        vault.pay(address(usd), to, amount, auth);
    }

    // --- deposit ------------------------------------------------------------

    function test_deposit_credits() public view {
        assertEq(vault.balanceOf(holder, address(usd)), 100e18);
        assertEq(usd.balanceOf(address(vault)), 100e18);
    }

    function test_deposit_requiresAgentId() public {
        usd.mint(stranger, 1e18);
        vm.startPrank(stranger);
        usd.approve(address(vault), 1e18);
        vm.expectRevert(HaptixVault.NotAgentIdHolder.selector);
        vault.deposit(address(usd), 1e18);
        vm.stopPrank();
    }

    function test_deposit_requiresGuard() public {
        usd.mint(friend, 1e18);
        vm.startPrank(friend);
        usd.approve(address(vault), 1e18);
        vm.expectRevert(HaptixVault.GuardNotOpen.selector);
        vault.deposit(address(usd), 1e18);
        vm.stopPrank();
    }

    function test_deposit_requiresRuleForToken() public {
        MockToken other = new MockToken();
        other.mint(holder, 1e18);
        vm.startPrank(holder);
        other.approve(address(vault), 1e18);
        vm.expectRevert(HaptixVault.NoRuleForToken.selector);
        vault.deposit(address(other), 1e18);
        vm.stopPrank();
    }

    function test_deposit_feeTokenCreditsWhatArrived() public {
        FeeToken fee = new FeeToken();
        nft.set(friend, 1);
        _open(friend, address(fee), false);
        fee.mint(friend, 100e18);
        vm.startPrank(friend);
        fee.approve(address(vault), 100e18);
        vault.deposit(address(fee), 100e18);
        vm.stopPrank();
        assertEq(vault.balanceOf(friend, address(fee)), 99e18);
    }

    // --- pay: limits ----------------------------------------------------------

    function test_pay_toHolderWithinLimits() public {
        _pay(friend, 1e18, "");
        assertEq(usd.balanceOf(friend), 1e18);
        assertEq(vault.balanceOf(holder, address(usd)), 99e18);
        (uint256 spent,) = vault.spentInWindow(holder, address(usd));
        assertEq(spent, 1e18);
    }

    function test_pay_overCeiling() public {
        bytes memory auth = _signPay(friend, 6e18);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.OverCeiling.selector);
        vault.pay(address(usd), friend, 6e18, auth);
    }

    function test_pay_overDailyCap_thenResets() public {
        for (uint256 i; i < 10; i++) _pay(friend, 1e18, "");
        vm.prank(holder);
        vm.expectRevert(HaptixVault.OverDailyCap.selector);
        vault.pay(address(usd), friend, 1e18, "");

        vm.warp(block.timestamp + WINDOW);
        _pay(friend, 1e18, "");
        assertEq(usd.balanceOf(friend), 11e18);
    }

    function test_pay_respectsTightenedRuleMidWindow() public {
        _pay(friend, 1e18, "");
        vm.prank(holder);
        reg.tightenRule(address(usd), HaptixRegistry.Rule(1e18, 1e18, 1e18));
        vm.prank(holder);
        vm.expectRevert(HaptixVault.OverDailyCap.selector);
        vault.pay(address(usd), friend, 1e18, "");
    }

    function test_pay_insufficientBalance() public {
        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(address(usd), HaptixRegistry.Rule(10e18, 5e18, 5e18));
        vm.prank(friend);
        reg.open(r, DELAY, HaptixRegistry.Passkey(0, 0));
        vm.prank(friend);
        vm.expectRevert(HaptixVault.InsufficientBalance.selector);
        vault.pay(address(usd), holder, 1e18, "");
    }

    function test_pay_requiresAgentId() public {
        nft.set(holder, 0);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.NotAgentIdHolder.selector);
        vault.pay(address(usd), friend, 1e18, "");
    }

    // --- pay: recipients ----------------------------------------------------

    function test_pay_refusesSelfVaultZero() public {
        vm.startPrank(holder);
        vm.expectRevert(HaptixVault.BadRecipient.selector);
        vault.pay(address(usd), holder, 1e18, "");
        vm.expectRevert(HaptixVault.BadRecipient.selector);
        vault.pay(address(usd), address(vault), 1e18, "");
        vm.expectRevert(HaptixVault.BadRecipient.selector);
        vault.pay(address(usd), address(0), 1e18, "");
        vm.stopPrank();
    }

    function test_pay_nonHolderNeedsAllowance() public {
        vm.prank(holder);
        vm.expectRevert(HaptixVault.RecipientNotAllowed.selector);
        vault.pay(address(usd), shop, 1e18, "");
    }

    function _allow(address to, uint128 daily) internal {
        bytes memory data = abi.encode(to, address(usd), daily);
        vm.prank(holder);
        reg.queue(HaptixRegistry.Kind.Allowance, data);
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        reg.applyChange(HaptixRegistry.Kind.Allowance, data);
    }

    function test_pay_nonHolderWithinAllowance() public {
        _allow(shop, 2e18);
        _pay(shop, 1e18, "");
        _pay(shop, 1e18, "");
        vm.prank(holder);
        vm.expectRevert(HaptixVault.OverRecipientAllowance.selector);
        vault.pay(address(usd), shop, 1e18, "");
        assertEq(usd.balanceOf(shop), 2e18);
    }

    function test_pay_tighteningAllowanceToZeroBlocks() public {
        _allow(shop, 2e18);
        vm.prank(holder);
        reg.tightenAllowance(shop, address(usd), 0);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.RecipientNotAllowed.selector);
        vault.pay(address(usd), shop, 1e18, "");
    }

    /// Invariant 1: an allowance never caps (or un-caps) an Agent ID holder.
    function test_allowanceNeverAffectsHolderRecipients() public {
        _allow(friend, 1e18); // ignored for holders
        _pay(friend, 1e18, "");
        _pay(friend, 1e18, ""); // beyond the "allowance", still fine under dailyCap
        vm.prank(holder);
        reg.tightenAllowance(friend, address(usd), 0);
        _pay(friend, 1e18, "");
        assertEq(usd.balanceOf(friend), 3e18);
    }

    // --- pay: passkey -------------------------------------------------------

    function test_pay_abovePasskeyThreshold_needsSignature() public {
        vm.prank(holder);
        vm.expectRevert(HaptixVault.PasskeyRequired.selector);
        vault.pay(address(usd), friend, 2e18, "");
    }

    function test_pay_withValidPasskey() public {
        bytes memory auth = _signPay(friend, 2e18);
        _pay(friend, 2e18, auth);
        assertEq(usd.balanceOf(friend), 2e18);
        assertEq(vault.nonce(holder), 1);
    }

    function test_pay_passkeyReplayFails() public {
        bytes memory auth = _signPay(friend, 2e18);
        _pay(friend, 2e18, auth);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 2e18, auth);
    }

    function test_pay_passkeyBoundToAmountAndRecipient() public {
        nft.set(shop, 1);
        bytes memory auth = _signPay(friend, 2e18);
        vm.startPrank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 3e18, auth);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), shop, 2e18, auth);
        vm.stopPrank();
    }

    function test_pay_wrongKeyFails() public {
        bytes memory auth = _sign(0xBADBAD, vault.payChallenge(holder, address(usd), friend, 2e18), 0x05);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 2e18, auth);
    }

    function test_pay_requiresUserVerification() public {
        bytes memory auth = _sign(PK, vault.payChallenge(holder, address(usd), friend, 2e18), 0x01); // UP only
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 2e18, auth);
    }

    function test_pay_noPasskeyConfigured() public {
        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(address(usd), HaptixRegistry.Rule(10e18, 5e18, 1e18));
        vm.prank(friend);
        reg.open(r, DELAY, HaptixRegistry.Passkey(0, 0));
        _fund(friend, usd, 10e18);
        vm.prank(friend);
        vm.expectRevert(HaptixVault.NoPasskey.selector);
        vault.pay(address(usd), holder, 2e18, "0x01");
    }

    function test_pay_signatureForOtherVaultFails() public {
        HaptixVault other = new HaptixVault(reg, WINDOW, WITHDRAW_WINDOW);
        bytes memory auth = _sign(PK, other.payChallenge(holder, address(usd), friend, 2e18), 0x05);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 2e18, auth);
    }

    // --- withdraw -------------------------------------------------------------

    function test_withdraw_waitsForDelay() public {
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 40e18);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(HaptixVault.NotReady.selector, block.timestamp + DELAY));
        vault.finalizeWithdraw(address(usd));

        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vault.finalizeWithdraw(address(usd));
        assertEq(usd.balanceOf(holder), 40e18);
        assertEq(vault.balanceOf(holder, address(usd)), 60e18);
    }

    function test_withdraw_cancel() public {
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 40e18);
        vm.prank(holder);
        vault.cancelWithdraw(address(usd));
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.NothingPending.selector);
        vault.finalizeWithdraw(address(usd));
    }

    function test_withdraw_cappedToBalanceAfterPayments() public {
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 100e18);
        _pay(friend, 1e18, "");
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vault.finalizeWithdraw(address(usd));
        assertEq(usd.balanceOf(holder), 99e18);
        assertEq(vault.balanceOf(holder, address(usd)), 0);
    }

    /// Invariant 3: losing the Agent ID must not lock funds.
    function test_withdraw_worksWithoutAgentId() public {
        nft.set(holder, 0);
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 100e18);
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vault.finalizeWithdraw(address(usd));
        assertEq(usd.balanceOf(holder), 100e18);
    }

    function test_withdraw_readyTimeFixedAtRequest() public {
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 10e18);
        vm.prank(holder);
        reg.lengthenDelay(30 days);
        vm.warp(block.timestamp + DELAY);
        vm.prank(holder);
        vault.finalizeWithdraw(address(usd));
        assertEq(usd.balanceOf(holder), 10e18);
    }

    function test_withdraw_expires() public {
        vm.prank(holder);
        vault.requestWithdraw(address(usd), 10e18);
        uint256 exp = block.timestamp + DELAY + WITHDRAW_WINDOW;
        vm.warp(exp);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(HaptixVault.Expired.selector, exp));
        vault.finalizeWithdraw(address(usd));
    }

    function test_withdrawWithPasskey_instant() public {
        bytes memory auth = _sign(PK, vault.withdrawChallenge(holder, address(usd), 30e18), 0x05);
        vm.prank(holder);
        vault.withdrawWithPasskey(address(usd), 30e18, auth);
        assertEq(usd.balanceOf(holder), 30e18);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.withdrawWithPasskey(address(usd), 30e18, auth);
    }

    function test_withdrawSignatureCantPay() public {
        bytes memory auth = _sign(PK, vault.withdrawChallenge(holder, address(usd), 2e18), 0x05);
        vm.prank(holder);
        vm.expectRevert(HaptixVault.BadPasskey.selector);
        vault.pay(address(usd), friend, 2e18, auth);
    }

    function test_strangerCantTouchOthersFunds() public {
        vm.prank(stranger);
        vault.requestWithdraw(address(usd), 100e18);
        vm.warp(block.timestamp + DELAY);
        vm.prank(stranger);
        vault.finalizeWithdraw(address(usd));
        assertEq(usd.balanceOf(stranger), 0);
        assertEq(vault.balanceOf(holder, address(usd)), 100e18);
    }

    // --- token edge cases ---------------------------------------------------

    function test_reentrancyBlocked() public {
        ReentrantToken bad = new ReentrantToken();
        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(address(bad), HaptixRegistry.Rule(10e18, 5e18, 5e18));
        // The token itself is a fully set-up holder, so only the lock can stop it.
        nft.set(address(bad), 1);
        for (uint256 k; k < 2; k++) {
            address who = k == 0 ? friend : address(bad);
            vm.prank(who);
            reg.open(r, DELAY, HaptixRegistry.Passkey(0, 0));
            bad.mint(who, 10e18);
            vm.startPrank(who);
            bad.approve(address(vault), 10e18);
            vault.deposit(address(bad), 10e18);
            vm.stopPrank();
        }
        bad.arm(vault, holder);

        vm.prank(friend);
        vault.pay(address(bad), holder, 1e18, "");
        assertFalse(bad.innerSucceeded(), "re-entered pay went through");
        assertEq(bytes4(bad.innerError()), HaptixVault.Reentrancy.selector);
    }

    function test_eoaTokenRejected() public {
        address fake = makeAddr("fake");
        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(fake, HaptixRegistry.Rule(10e18, 5e18, 5e18));
        vm.prank(friend);
        reg.open(r, DELAY, HaptixRegistry.Passkey(0, 0));
        vm.prank(friend);
        vm.expectRevert(HaptixVault.NotAContract.selector);
        vault.deposit(fake, 1e18);
    }

    // --- fuzz ------------------------------------------------------------------

    /// Whatever sequence of payments and time jumps, no window ever pays out
    /// more than dailyCap, and the vault always holds exactly what it owes.
    function testFuzz_neverExceedsCapAndBooksBalance(uint256[8] memory amounts, uint256[8] memory gaps) public {
        uint256 inWindow;
        for (uint256 i; i < 8; i++) {
            vm.warp(block.timestamp + bound(gaps[i], 0, WINDOW / 2));
            uint256 amt = bound(amounts[i], 1, 1e18); // at or below passkeyAbove
            (uint256 spentBefore, uint256 resetsAt) = vault.spentInWindow(holder, address(usd));
            if (resetsAt == 0) {
                inWindow = 0;
            }
            assertEq(spentBefore, inWindow);
            vm.prank(holder);
            try vault.pay(address(usd), friend, amt, "") {
                inWindow += amt;
            } catch {}
            assertLe(inWindow, 10e18, "window paid out more than dailyCap");
            assertEq(usd.balanceOf(address(vault)), vault.balanceOf(holder, address(usd)), "books out of sync");
        }
    }

    // --- against BNB Chain mainnet state (skipped without a BSC RPC) ----------

    /// Run: BSC_RPC_URL=... AGENT_ID_NFT=... AGENT_ID_SAMPLE_HOLDER=... AGENT_ID_SAMPLE_HOLDER_2=... BSC_USDT=... forge test --mt test_fork
    function test_fork_realUsdtAndAgentIds() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        IAgentId real = IAgentId(vm.envAddress("AGENT_ID_NFT"));
        address a = vm.envAddress("AGENT_ID_SAMPLE_HOLDER");
        address b = vm.envAddress("AGENT_ID_SAMPLE_HOLDER_2");
        MockToken usdt = MockToken(vm.envAddress("BSC_USDT"));

        HaptixRegistry r2 = new HaptixRegistry(real, APPLY_WINDOW, MAX_PENDING);
        HaptixVault v2 = new HaptixVault(r2, WINDOW, WITHDRAW_WINDOW);

        HaptixRegistry.TokenRule[] memory r = new HaptixRegistry.TokenRule[](1);
        r[0] = HaptixRegistry.TokenRule(address(usdt), HaptixRegistry.Rule(5e18, 2e18, 1e18));
        (uint256 x, uint256 y) = vm.publicKeyP256(PK);
        vm.prank(a);
        r2.open(r, DELAY, HaptixRegistry.Passkey(bytes32(x), bytes32(y)));

        deal(address(usdt), a, 10e18);
        vm.startPrank(a);
        usdt.approve(address(v2), 5e18);
        v2.deposit(address(usdt), 5e18);
        v2.pay(address(usdt), b, 1e18, "");
        vm.stopPrank();

        bytes memory auth = _sign(PK, v2.payChallenge(a, address(usdt), b, 2e18), 0x05);
        uint256 before = usdt.balanceOf(b);
        vm.prank(a);
        v2.pay(address(usdt), b, 2e18, auth);
        assertEq(usdt.balanceOf(b) - before, 2e18);
        assertEq(v2.balanceOf(a, address(usdt)), 2e18);
    }
}
