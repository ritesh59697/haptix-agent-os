// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice The one call Haptix needs from the Agent ID contract.
interface IAgentId {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title HaptixRegistry -- on-chain spending rules for Agentic Wallets, keyed to Agent ID.
///
/// @notice An Agent ID holder opens a guard and records how much their agent may
///         spend: a daily cap, a per-payment ceiling, the amount above which a
///         passkey must co-sign, and per-recipient daily allowances. The Haptix
///         vault (v2) reads these rules before it lets any payment out.
///
/// @dev Threat model: the caller IS the agent's wallet. A prompt-injected agent
///      can send any call the wallet can send, including calls to this contract.
///      So rules may only get stricter instantly. Anything that loosens them --
///      a higher cap, a new or changed passkey, a shorter delay -- is queued and
///      only applies after the holder's own `changeDelay`, which leaves the
///      owner time to see it and cancel it. Queued changes are listed on-chain
///      (`pendingOf`) so they can't hide, and expire `applyWindow` after they
///      become applicable, so a forgotten one can't be applied months later.
///
///      No owner, no admin, no upgrade path. Nothing here can be changed by
///      anyone except each holder, for their own guard.
contract HaptixRegistry {
    /// @notice Limits for one token. All amounts are in the token's own base
    ///         units (read `decimals()` off-chain; never assume 6 or 18).
    struct Rule {
        uint128 dailyCap;      // total the agent may pay out per rolling day
        uint128 ceiling;       // no single payment may exceed this, passkey or not
        uint128 passkeyAbove;  // payments above this need a passkey co-signature
    }

    struct TokenRule {
        address token;
        Rule rule;
    }

    struct Passkey {
        bytes32 x;
        bytes32 y;
    }

    struct Guard {
        bool open;
        uint32 changeDelay; // seconds a loosening change waits before it applies
        Passkey passkey;    // zero = none; payments above `passkeyAbove` then revert
    }

    IAgentId public immutable agentId;

    mapping(address holder => Guard) private _guards;
    mapping(address holder => mapping(address token => Rule)) private _rules;
    mapping(address holder => mapping(address recipient => mapping(address token => uint128))) private
        _allowances;

    /// @notice A queued loosening change. Listed on-chain so the owner (and
    ///         their tools) can always see what is waiting to apply.
    struct Pending {
        bytes32 id;
        Kind kind;
        bytes data;
        uint64 applyAfter; // earliest time it may apply
        uint64 expiresAt;  // after this it can no longer apply and must be re-queued
    }

    /// @notice How long a queued change stays applicable once its delay has passed.
    uint256 public immutable applyWindow;
    /// @notice Most changes one guard may have queued at once, so reads stay bounded.
    uint256 public immutable maxPending;

    mapping(address holder => Pending[]) private _pending;

    enum Kind {
        Rule,
        Allowance,
        Passkey,
        Delay
    }

    event GuardOpened(address indexed holder, uint32 changeDelay, bool hasPasskey);
    event RuleSet(address indexed holder, address indexed token, Rule rule);
    event AllowanceSet(address indexed holder, address indexed recipient, address indexed token, uint128 daily);
    event PasskeySet(address indexed holder, bytes32 x, bytes32 y);
    event DelaySet(address indexed holder, uint32 changeDelay);
    event ChangeQueued(
        address indexed holder, bytes32 indexed id, Kind kind, bytes data, uint256 applyAfter, uint256 expiresAt
    );
    event ChangeCancelled(address indexed holder, bytes32 indexed id);

    error NotAgentIdHolder();
    error AlreadyOpen();
    error NotOpen();
    error BadRule();
    error NotLoosening();
    error NotQueued();
    error TooEarly(uint256 applyAfter);
    error ZeroAddress();
    error Expired(uint256 expiresAt);
    error TooManyPending();
    error BadConfig();

    constructor(IAgentId agentId_, uint256 applyWindow_, uint256 maxPending_) {
        if (address(agentId_) == address(0)) revert ZeroAddress();
        if (applyWindow_ == 0 || maxPending_ == 0) revert BadConfig();
        agentId = agentId_;
        applyWindow = applyWindow_;
        maxPending = maxPending_;
    }

    modifier onlyHolder() {
        if (agentId.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        _;
    }

    modifier onlyOpen() {
        if (!_guards[msg.sender].open) revert NotOpen();
        _;
    }

    // ------------------------------------------------------------------
    // Opening
    // ------------------------------------------------------------------

    /// @notice Open a guard. No funds move; this only records rules.
    ///         Everything set here applies immediately, because there is
    ///         nothing to protect yet.
    function open(TokenRule[] calldata rules, uint32 changeDelay, Passkey calldata passkey) external onlyHolder {
        Guard storage g = _guards[msg.sender];
        if (g.open) revert AlreadyOpen();

        g.open = true;
        g.changeDelay = changeDelay;
        g.passkey = passkey;

        for (uint256 i; i < rules.length; ++i) {
            _setRule(msg.sender, rules[i].token, rules[i].rule);
        }
        emit GuardOpened(msg.sender, changeDelay, _hasPasskey(passkey));
    }

    // ------------------------------------------------------------------
    // Tightening: instant
    // ------------------------------------------------------------------
    // These skip the Agent ID check on purpose: if a holder ever loses their
    // Agent ID, they must still be able to lock things down and cancel a
    // queued change.

    /// @notice Lower a token's limits. Reverts if any field would go up.
    function tightenRule(address token, Rule calldata rule) external onlyOpen {
        if (_isLooser(_rules[msg.sender][token], rule)) revert BadRule();
        _setRule(msg.sender, token, rule);
    }

    /// @notice Lower (or remove, with 0) a recipient's daily allowance.
    function tightenAllowance(address recipient, address token, uint128 daily) external onlyOpen {
        if (daily > _allowances[msg.sender][recipient][token]) revert BadRule();
        _setAllowance(msg.sender, recipient, token, daily);
    }

    /// @notice Make loosening changes wait longer.
    function lengthenDelay(uint32 changeDelay) external onlyOpen {
        if (changeDelay < _guards[msg.sender].changeDelay) revert BadRule();
        _guards[msg.sender].changeDelay = changeDelay;
        emit DelaySet(msg.sender, changeDelay);
    }

    /// @notice Drop a queued loosening change before it applies.
    function cancel(bytes32 id) external {
        (bool found, uint256 i) = _find(msg.sender, id);
        if (!found) revert NotQueued();
        _remove(msg.sender, i);
        emit ChangeCancelled(msg.sender, id);
    }

    // ------------------------------------------------------------------
    // Loosening: queued for `changeDelay`
    // ------------------------------------------------------------------

    /// @notice Queue a change that loosens the guard. `data` is the ABI-encoded
    ///         argument for `kind`:
    ///           Rule      -> (address token, Rule rule)
    ///           Allowance -> (address recipient, address token, uint128 daily)
    ///           Passkey   -> (Passkey passkey)
    ///           Delay     -> (uint32 changeDelay)
    function queue(Kind kind, bytes calldata data) external onlyHolder onlyOpen returns (bytes32 id) {
        if (!_loosens(msg.sender, kind, data)) revert NotLoosening();
        id = changeId(kind, data);
        uint64 applyAfter = uint64(block.timestamp + _guards[msg.sender].changeDelay);
        uint64 expiresAt = uint64(applyAfter + applyWindow);

        (bool found, uint256 i) = _find(msg.sender, id);
        if (found) {
            // Re-queueing the same change restarts its clock; it never shortens it.
            Pending storage p = _pending[msg.sender][i];
            p.applyAfter = applyAfter;
            p.expiresAt = expiresAt;
        } else {
            _pruneExpired(msg.sender);
            if (_pending[msg.sender].length >= maxPending) revert TooManyPending();
            _pending[msg.sender].push(Pending(id, kind, data, applyAfter, expiresAt));
        }
        emit ChangeQueued(msg.sender, id, kind, data, applyAfter, expiresAt);
    }

    /// @notice Apply a queued change once its delay has passed.
    function applyChange(Kind kind, bytes calldata data) external onlyHolder onlyOpen {
        bytes32 id = changeId(kind, data);
        (bool found, uint256 i) = _find(msg.sender, id);
        if (!found) revert NotQueued();
        Pending storage p = _pending[msg.sender][i];
        if (block.timestamp < p.applyAfter) revert TooEarly(p.applyAfter);
        if (block.timestamp >= p.expiresAt) revert Expired(p.expiresAt);
        _remove(msg.sender, i);

        if (kind == Kind.Rule) {
            (address token, Rule memory rule) = abi.decode(data, (address, Rule));
            _setRule(msg.sender, token, rule);
        } else if (kind == Kind.Allowance) {
            (address recipient, address token, uint128 daily) = abi.decode(data, (address, address, uint128));
            _setAllowance(msg.sender, recipient, token, daily);
        } else if (kind == Kind.Passkey) {
            Passkey memory p = abi.decode(data, (Passkey));
            _guards[msg.sender].passkey = p;
            emit PasskeySet(msg.sender, p.x, p.y);
        } else {
            uint32 d = abi.decode(data, (uint32));
            _guards[msg.sender].changeDelay = d;
            emit DelaySet(msg.sender, d);
        }
    }

    function changeId(Kind kind, bytes calldata data) public pure returns (bytes32) {
        return keccak256(abi.encode(kind, data));
    }

    // ------------------------------------------------------------------
    // Reads (for the vault, the skill and the site)
    // ------------------------------------------------------------------

    /// @notice Every change queued on `holder`'s guard, including expired ones
    ///         not yet pruned (check `expiresAt`).
    function pendingOf(address holder) external view returns (Pending[] memory) {
        return _pending[holder];
    }

    function guardOf(address holder) external view returns (Guard memory) {
        return _guards[holder];
    }

    function ruleOf(address holder, address token) external view returns (Rule memory) {
        return _rules[holder][token];
    }

    function allowanceOf(address holder, address recipient, address token) external view returns (uint128) {
        return _allowances[holder][recipient][token];
    }

    function isHolder(address account) external view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _setRule(address holder, address token, Rule memory rule) private {
        if (token == address(0)) revert ZeroAddress();
        if (rule.passkeyAbove > rule.ceiling || rule.ceiling > rule.dailyCap) revert BadRule();
        _rules[holder][token] = rule;
        emit RuleSet(holder, token, rule);
    }

    function _setAllowance(address holder, address recipient, address token, uint128 daily) private {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        _allowances[holder][recipient][token] = daily;
        emit AllowanceSet(holder, recipient, token, daily);
    }

    /// @dev True when ANY field of `next` lets more money out than `cur`.
    ///      A higher passkeyAbove is looser: fewer payments need the passkey.
    function _isLooser(Rule memory cur, Rule memory next) private pure returns (bool) {
        return next.dailyCap > cur.dailyCap || next.ceiling > cur.ceiling || next.passkeyAbove > cur.passkeyAbove;
    }

    /// @dev Queueing is only for changes that loosen. A pure tightening must use
    ///      the instant path, so the queue can't be used to hide intent.
    ///      Any passkey change counts as loosening: a new key is a new signer.
    function _loosens(address holder, Kind kind, bytes calldata data) private view returns (bool) {
        if (kind == Kind.Rule) {
            (address token, Rule memory rule) = abi.decode(data, (address, Rule));
            return _isLooser(_rules[holder][token], rule);
        }
        if (kind == Kind.Allowance) {
            (address recipient, address token, uint128 daily) = abi.decode(data, (address, address, uint128));
            return daily > _allowances[holder][recipient][token];
        }
        if (kind == Kind.Passkey) {
            Passkey memory p = abi.decode(data, (Passkey));
            Passkey memory cur = _guards[holder].passkey;
            return p.x != cur.x || p.y != cur.y;
        }
        uint32 d = abi.decode(data, (uint32));
        return d < _guards[holder].changeDelay;
    }

    function _find(address holder, bytes32 id) private view returns (bool, uint256) {
        Pending[] storage list = _pending[holder];
        for (uint256 i; i < list.length; ++i) {
            if (list[i].id == id) return (true, i);
        }
        return (false, 0);
    }

    function _remove(address holder, uint256 i) private {
        Pending[] storage list = _pending[holder];
        uint256 last = list.length - 1;
        if (i != last) list[i] = list[last];
        list.pop();
    }

    function _pruneExpired(address holder) private {
        Pending[] storage list = _pending[holder];
        uint256 i;
        while (i < list.length) {
            if (block.timestamp >= list[i].expiresAt) _remove(holder, i);
            else ++i;
        }
    }

    function _hasPasskey(Passkey calldata p) private pure returns (bool) {
        return p.x != bytes32(0) || p.y != bytes32(0);
    }
}
