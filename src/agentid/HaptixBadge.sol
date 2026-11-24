// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {HaptixRegistry, IAgentId} from "./HaptixRegistry.sol";

/// @title HaptixBadge
/// @notice A soulbound "Guarded Agent" badge. An Agent ID holder can claim one, once, after
///         opening a Haptix guard. The artwork is drawn on-chain from the holder's live guard,
///         so it always shows the current spending delay and whether a passkey is set.
/// @dev    No owner, no admin, no funds, no transfers. `claim()` takes no arguments, so every
///         holder sends identical calldata. Holders are enumerable on-chain (`holderAt`).
contract HaptixBadge {
    HaptixRegistry public immutable registry;
    IAgentId public immutable agentId;

    string public constant name = "Haptix Guarded Agent";
    string public constant symbol = "HXGUARD";

    uint256 public totalSupply;
    mapping(address holder => uint256 tokenId) public tokenOf;
    mapping(uint256 tokenId => address holder) private _ownerOf;
    mapping(uint256 tokenId => uint64 claimedAt) public claimedAt;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Claimed(address indexed holder, uint256 indexed tokenId);

    error NotAgentIdHolder();
    error GuardNotOpen();
    error AlreadyClaimed();
    error Soulbound();
    error NoSuchToken();
    error ZeroAddress();

    constructor(HaptixRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        agentId = registry_.agentId();
    }

    /// @notice Claim your badge. Requires an Agent ID and an open Haptix guard.
    function claim() external returns (uint256 tokenId) {
        if (agentId.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        if (!registry.guardOf(msg.sender).open) revert GuardNotOpen();
        if (tokenOf[msg.sender] != 0) revert AlreadyClaimed();
        tokenId = ++totalSupply;
        tokenOf[msg.sender] = tokenId;
        _ownerOf[tokenId] = msg.sender;
        claimedAt[tokenId] = uint64(block.timestamp);
        emit Transfer(address(0), msg.sender, tokenId);
        emit Claimed(msg.sender, tokenId);
    }

    // ---------------------------------------------------------------- views

    /// @notice The holder of badge number `index + 1` (claim order).
    function holderAt(uint256 index) external view returns (address) {
        return _ownerOf[index + 1];
    }

    /// @notice Whether `holder` can claim right now.
    function canClaim(address holder) external view returns (bool) {
        return tokenOf[holder] == 0 && agentId.balanceOf(holder) > 0 && registry.guardOf(holder).open;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return tokenOf[owner] == 0 ? 0 : 1;
    }

    function ownerOf(uint256 tokenId) public view returns (address o) {
        o = _ownerOf[tokenId];
        if (o == address(0)) revert NoSuchToken();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 // ERC-165
            || id == 0x80ac58cd // ERC-721
            || id == 0x5b5e139f; // ERC-721 Metadata
    }

    // ------------------------------------------------------------ soulbound

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    // ------------------------------------------------------------- metadata

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        address holder = ownerOf(tokenId);
        HaptixRegistry.Guard memory g = registry.guardOf(holder);
        bool passkey = g.passkey.x != bytes32(0) || g.passkey.y != bytes32(0);
        string memory delay = string.concat(_u(g.changeDelay / 3600), "h");
        string memory num = _u(tokenId);

        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400'>",
            "<rect width='400' height='400' rx='32' fill='#0d1117'/>",
            "<rect x='20' y='20' width='360' height='360' rx='24' fill='none' stroke='",
            g.open ? "#3fb950" : "#8b949e",
            "' stroke-width='3'/>",
            "<text x='40' y='84' font-family='monospace' font-size='22' fill='#e6edf3'>HAPTIX</text>",
            "<text x='40' y='150' font-family='sans-serif' font-size='34' font-weight='700' fill='#e6edf3'>Guarded Agent</text>",
            "<text x='40' y='196' font-family='monospace' font-size='22' fill='#8b949e'>#",
            num,
            "</text>",
            string.concat(
                "<text x='40' y='270' font-family='monospace' font-size='18' fill='#e6edf3'>Guard: ",
                g.open ? "open" : "closed",
                "</text><text x='40' y='302' font-family='monospace' font-size='18' fill='#e6edf3'>Raise limits: waits ",
                delay,
                "</text><text x='40' y='334' font-family='monospace' font-size='18' fill='#e6edf3'>Passkey: ",
                passkey ? "on" : "off",
                "</text></svg>"
            )
        );

        string memory json = string.concat(
            '{"name":"Haptix Guarded Agent #',
            num,
            '","description":"This Agent ID holder runs their agent inside a Haptix guard: on-chain spending limits, a delay before limits can be raised, and an optional passkey for larger payments. Soulbound.",',
            '"attributes":[{"trait_type":"Guard","value":"',
            g.open ? "open" : "closed",
            '"},{"trait_type":"Raise delay (hours)","display_type":"number","value":',
            _u(g.changeDelay / 3600),
            '},{"trait_type":"Passkey","value":"',
            passkey ? "on" : "off",
            '"}],"image":"data:image/svg+xml;base64,',
            _b64(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", _b64(bytes(json)));
    }

    // -------------------------------------------------------------- helpers

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) b[--len] = bytes1(uint8(48 + v % 10));
        return string(b);
    }

    function _b64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory out = new bytes(4 * ((data.length + 2) / 3));
        uint256 j;
        for (uint256 i = 0; i < data.length; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = i + 1 < data.length ? uint8(data[i + 1]) : 0;
            uint256 c = i + 2 < data.length ? uint8(data[i + 2]) : 0;
            uint256 n = (a << 16) | (b << 8) | c;
            out[j++] = table[(n >> 18) & 63];
            out[j++] = table[(n >> 12) & 63];
            out[j++] = i + 1 < data.length ? table[(n >> 6) & 63] : bytes1("=");
            out[j++] = i + 2 < data.length ? table[n & 63] : bytes1("=");
        }
        return string(out);
    }
}
