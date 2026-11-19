// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {HaptixRegistry, IAgentId} from "./HaptixRegistry.sol";
import {WebAuthn} from "../WebAuthn.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title HaptixVault -- payments an agent can make, inside the limits its owner set.
///
/// @notice An Agent ID holder deposits tokens here. Their agent (the same
///         Agentic Wallet) can then pay out only within the rules recorded in
///         HaptixRegistry:
///           - no single payment above the guard's `ceiling`
///           - no more than `dailyCap` per window
///           - above `passkeyAbove`, only with a fresh passkey signature
///           - only to Agent ID holders, or to recipients the owner gave an
///             allowance (each capped per window by that allowance)
///
///         Money comes back to the holder through a withdrawal that waits the
///         guard's `changeDelay`, or instantly with a passkey signature.
///
/// @dev Invariants this contract is built around:
///      1. No instant registry change can let MORE money out. Allowances only
///         grant access to non-holders; they never cap (and so can never
///         un-cap) payments to Agent ID holders. Lowering one to 0 blocks that
///         recipient, which is tightening.
///      2. `pay` can never be a disguised withdrawal: paying yourself or the
///         vault is refused.
///      3. Withdrawals pay only `msg.sender`, from their own balance, and
///         never depend on Agent ID or guard state -- losing an Agent ID must
///         not lock funds. The ready time is fixed when requested.
///      4. Every passkey signature binds action, chain, vault, holder, token,
///         recipient, amount and a per-holder nonce, and is single-use.
///
///      Known limits, stated plainly: Agent IDs are free to claim, so "the
///      recipient holds an Agent ID" is an identity check, not a security
///      boundary -- the daily cap is. Payments split below the passkey
///      threshold are bounded only by the daily cap. A fixed window allows up
///      to twice the cap across a window boundary.
///
///      No owner, no admin, no upgrade path.
contract HaptixVault {
    struct Window {
        uint256 spent;
        uint256 resetsAt; // the window is fresh once block.timestamp >= resetsAt
    }

    struct Withdrawal {
        uint256 amount;
        uint256 readyAt;
    }

    HaptixRegistry public immutable registry;
    IAgentId public immutable agentId;
    uint256 public immutable windowSeconds;

    bytes32 public constant PAY = keccak256("HAPTIX_PAY");
    bytes32 public constant WITHDRAW = keccak256("HAPTIX_WITHDRAW");

    mapping(address holder => mapping(address token => uint256)) public balanceOf;
    mapping(address holder => mapping(address token => Window)) private _spent;
    mapping(address holder => mapping(address to => mapping(address token => Window))) private _spentTo;
    mapping(address holder => mapping(address token => Withdrawal)) public pendingWithdrawal;
    mapping(address holder => uint256) public nonce;

    uint256 private _lock = 1;

    event Deposited(address indexed holder, address indexed token, uint256 amount);
    event Paid(address indexed holder, address indexed to, address indexed token, uint256 amount, bool withPasskey);
    event WithdrawalRequested(address indexed holder, address indexed token, uint256 amount, uint256 readyAt);
    event WithdrawalCancelled(address indexed holder, address indexed token);
    event Withdrawn(address indexed holder, address indexed token, uint256 amount, bool withPasskey);

    error NotAgentIdHolder();
    error GuardNotOpen();
    error NoRuleForToken();
    error ZeroAmount();
    error ZeroAddress();
    error NotAContract();
    error BadRecipient();
    error RecipientNotAllowed();
    error OverCeiling();
    error OverDailyCap();
    error OverRecipientAllowance();
    error NoPasskey();
    error PasskeyRequired();
    error BadPasskey();
    error InsufficientBalance();
    error NothingPending();
    error NotReady(uint256 readyAt);
    error TransferFailed();
    error Reentrancy();

    constructor(HaptixRegistry registry_, uint256 windowSeconds_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        if (windowSeconds_ == 0) revert ZeroAmount();
        registry = registry_;
        agentId = registry_.agentId();
        windowSeconds = windowSeconds_;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyHolder() {
        if (agentId.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        _;
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    /// @notice Move `amount` of `token` into your vault balance. Approve this
    ///         contract for exactly `amount` first. Credits what actually
    ///         arrived, so fee-on-transfer tokens can't inflate a balance.
    function deposit(address token, uint256 amount) external nonReentrant onlyHolder {
        if (amount == 0) revert ZeroAmount();
        if (!registry.guardOf(msg.sender).open) revert GuardNotOpen();
        if (registry.ruleOf(msg.sender, token).dailyCap == 0) revert NoRuleForToken();
        if (token.code.length == 0) revert NotAContract();

        uint256 before = IERC20Min(token).balanceOf(address(this));
        _call(token, abi.encodeCall(IERC20Min.transferFrom, (msg.sender, address(this), amount)));
        uint256 received = IERC20Min(token).balanceOf(address(this)) - before;

        balanceOf[msg.sender][token] += received;
        emit Deposited(msg.sender, token, received);
    }

    // ------------------------------------------------------------------
    // Pay
    // ------------------------------------------------------------------

    /// @notice Pay `amount` of `token` to `to` from your vault balance, within
    ///         your guard. Pass an empty `passkeyAuth` unless `amount` is above
    ///         your passkey threshold; then pass abi.encode(WebAuthn.Signature)
    ///         over `payChallenge(msg.sender, token, to, amount)`.
    function pay(address token, address to, uint256 amount, bytes calldata passkeyAuth)
        external
        nonReentrant
        onlyHolder
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0) || to == msg.sender || to == address(this)) revert BadRecipient();
        if (!registry.guardOf(msg.sender).open) revert GuardNotOpen();

        HaptixRegistry.Rule memory rule = registry.ruleOf(msg.sender, token);
        if (rule.dailyCap == 0) revert NoRuleForToken();
        if (amount > rule.ceiling) revert OverCeiling();

        // Who may be paid. Agent ID holders: yes, bounded by the guard's caps.
        // Anyone else: only with an allowance, and only up to it per window.
        if (agentId.balanceOf(to) == 0) {
            uint128 allowance = registry.allowanceOf(msg.sender, to, token);
            if (allowance == 0) revert RecipientNotAllowed();
            if (!_use(_spentTo[msg.sender][to][token], amount, allowance)) revert OverRecipientAllowance();
        }
        if (!_use(_spent[msg.sender][token], amount, rule.dailyCap)) revert OverDailyCap();

        bool withPasskey = amount > rule.passkeyAbove;
        if (withPasskey) _checkPasskey(msg.sender, PAY, token, to, amount, passkeyAuth);

        uint256 bal = balanceOf[msg.sender][token];
        if (amount > bal) revert InsufficientBalance();
        balanceOf[msg.sender][token] = bal - amount;

        emit Paid(msg.sender, to, token, amount, withPasskey);
        _call(token, abi.encodeCall(IERC20Min.transfer, (to, amount)));
    }

    // ------------------------------------------------------------------
    // Withdraw (never gated by Agent ID or guard state)
    // ------------------------------------------------------------------

    /// @notice Start a withdrawal back to yourself. It can be finalized after
    ///         your guard's change delay, counted from now. Replaces any
    ///         pending request for the same token.
    function requestWithdraw(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 readyAt = block.timestamp + registry.guardOf(msg.sender).changeDelay;
        pendingWithdrawal[msg.sender][token] = Withdrawal(amount, readyAt);
        emit WithdrawalRequested(msg.sender, token, amount, readyAt);
    }

    function cancelWithdraw(address token) external {
        if (pendingWithdrawal[msg.sender][token].amount == 0) revert NothingPending();
        delete pendingWithdrawal[msg.sender][token];
        emit WithdrawalCancelled(msg.sender, token);
    }

    /// @notice Complete a pending withdrawal. Pays the requested amount, or
    ///         your whole balance if payments since have left less.
    function finalizeWithdraw(address token) external nonReentrant {
        Withdrawal memory w = pendingWithdrawal[msg.sender][token];
        if (w.amount == 0) revert NothingPending();
        if (block.timestamp < w.readyAt) revert NotReady(w.readyAt);
        delete pendingWithdrawal[msg.sender][token];

        uint256 bal = balanceOf[msg.sender][token];
        uint256 amount = w.amount < bal ? w.amount : bal;
        balanceOf[msg.sender][token] = bal - amount;

        emit Withdrawn(msg.sender, token, amount, false);
        if (amount > 0) _call(token, abi.encodeCall(IERC20Min.transfer, (msg.sender, amount)));
    }

    /// @notice Withdraw to yourself immediately, approved by your passkey over
    ///         `withdrawChallenge(msg.sender, token, amount)`.
    function withdrawWithPasskey(address token, uint256 amount, bytes calldata passkeyAuth) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkPasskey(msg.sender, WITHDRAW, token, msg.sender, amount, passkeyAuth);

        uint256 bal = balanceOf[msg.sender][token];
        if (amount > bal) revert InsufficientBalance();
        balanceOf[msg.sender][token] = bal - amount;

        emit Withdrawn(msg.sender, token, amount, true);
        _call(token, abi.encodeCall(IERC20Min.transfer, (msg.sender, amount)));
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    /// @notice The 32 bytes the passkey must sign to approve this payment.
    function payChallenge(address holder, address token, address to, uint256 amount) external view returns (bytes32) {
        return _challenge(PAY, holder, token, to, amount);
    }

    /// @notice The 32 bytes the passkey must sign to approve this withdrawal.
    function withdrawChallenge(address holder, address token, uint256 amount) external view returns (bytes32) {
        return _challenge(WITHDRAW, holder, token, holder, amount);
    }

    /// @notice Spent so far in the current window (0 once it has reset).
    function spentInWindow(address holder, address token) external view returns (uint256 spent, uint256 resetsAt) {
        Window memory w = _spent[holder][token];
        if (block.timestamp >= w.resetsAt) return (0, 0);
        return (w.spent, w.resetsAt);
    }

    function spentToInWindow(address holder, address to, address token)
        external
        view
        returns (uint256 spent, uint256 resetsAt)
    {
        Window memory w = _spentTo[holder][to][token];
        if (block.timestamp >= w.resetsAt) return (0, 0);
        return (w.spent, w.resetsAt);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Adds `amount` to the window if it fits under `cap`. A window starts
    ///      at the first spend after the previous one ended.
    function _use(Window storage w, uint256 amount, uint256 cap) private returns (bool) {
        if (block.timestamp >= w.resetsAt) {
            w.spent = 0;
            w.resetsAt = block.timestamp + windowSeconds;
        }
        uint256 next = w.spent + amount;
        if (next > cap) return false;
        w.spent = next;
        return true;
    }

    function _challenge(bytes32 action, address holder, address token, address to, uint256 amount)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(action, block.chainid, address(this), holder, token, to, amount, nonce[holder]));
    }

    function _checkPasskey(
        address holder,
        bytes32 action,
        address token,
        address to,
        uint256 amount,
        bytes calldata passkeyAuth
    ) private {
        HaptixRegistry.Passkey memory pk = registry.guardOf(holder).passkey;
        if (pk.x == bytes32(0) && pk.y == bytes32(0)) revert NoPasskey();
        if (passkeyAuth.length == 0) revert PasskeyRequired();

        WebAuthn.Signature memory sig = abi.decode(passkeyAuth, (WebAuthn.Signature));
        bytes32 challenge = _challenge(action, holder, token, to, amount);
        if (!WebAuthn.verify(abi.encodePacked(challenge), true, sig, uint256(pk.x), uint256(pk.y))) {
            revert BadPasskey();
        }
        unchecked {
            ++nonce[holder];
        }
    }

    /// @dev ERC-20 call that accepts both bool-returning and no-return tokens.
    function _call(address token, bytes memory data) private {
        if (token.code.length == 0) revert NotAContract();
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
