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
///      owner time to see it and cancel it.
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

    /// @notice holder => change id => earliest time it may apply (0 = not queued).
    mapping(address holder => mapping(bytes32 id => uint256)) public queuedAt;

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
    event ChangeQueued(address indexed holder, bytes32 indexed id, Kind kind, bytes data, uint256 applyAfter);
    event ChangeCancelled(address indexed holder, bytes32 indexed id);

    error NotAgentIdHolder();
    error AlreadyOpen();
    error NotOpen();
    error BadRule();
    error NotLoosening();
    error NotQueued();
    error TooEarly(uint256 applyAfter);
    error ZeroAddress();

    constructor(IAgentId agentId_) {
        if (address(agentId_) == address(0)) revert ZeroAddress();
        agentId = agentId_;
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
        if (queuedAt[msg.sender][id] == 0) revert NotQueued();
        delete queuedAt[msg.sender][id];
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
        uint256 applyAfter = block.timestamp + _guards[msg.sender].changeDelay;
        queuedAt[msg.sender][id] = applyAfter;
        emit ChangeQueued(msg.sender, id, kind, data, applyAfter);
    }

    /// @notice Apply a queued change once its delay has passed.
    function applyChange(Kind kind, bytes calldata data) external onlyHolder onlyOpen {
        bytes32 id = changeId(kind, data);
        uint256 applyAfter = queuedAt[msg.sender][id];
        if (applyAfter == 0) revert NotQueued();
        if (block.timestamp < applyAfter) revert TooEarly(applyAfter);
        delete queuedAt[msg.sender][id];

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

    function _hasPasskey(Passkey calldata p) private pure returns (bool) {
        return p.x != bytes32(0) || p.y != bytes32(0);
    }
}
