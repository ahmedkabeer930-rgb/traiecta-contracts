// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AddressKind} from "../../src/TraiectaTypes.sol";
import {AmountMath} from "../../src/libraries/AmountMath.sol";
import {FlowGuard, FlowWindow} from "../../src/libraries/FlowGuard.sol";
import {StellarAddress} from "../../src/libraries/StellarAddress.sol";
import {HyperionNotes} from "../../src/libraries/TraiectaNotes.sol";

/// @title An external door onto the internal libraries
/// @notice Every library function, callable from outside.
/// @dev Two reasons this has to exist. `expectRevert` watches the next external call, so an
/// internal function that reverts takes the test down with it rather than being caught. And the
/// codec takes `bytes calldata`, which a test cannot synthesise without a real call boundary to
/// put it behind.
contract AmountMathHarness {
    function pow10(uint8 exp) external pure returns (uint256) {
        return AmountMath.pow10(exp);
    }

    function convertDecimals(uint256 amount, uint8 from, uint8 to) external pure returns (uint256, uint256) {
        return AmountMath.convertDecimals(amount, from, to);
    }

    function convertDecimalsExact(uint256 amount, uint8 from, uint8 to) external pure returns (uint256) {
        return AmountMath.convertDecimalsExact(amount, from, to);
    }

    function floorToRepresentable(uint256 amount, uint8 from, uint8 to) external pure returns (uint256) {
        return AmountMath.floorToRepresentable(amount, from, to);
    }

    function applyFee(uint256 amount, uint16 feeBps) external pure returns (uint256, uint256) {
        return AmountMath.applyFee(amount, feeBps);
    }
}

contract StellarAddressHarness {
    function parse(string calldata value)
        external
        pure
        returns (AddressKind kind, bytes32 key, uint64 muxedId)
    {
        return StellarAddress.parse(value);
    }

    function encode(AddressKind kind, bytes32 key, uint64 muxedId) external pure returns (string memory) {
        return StellarAddress.encode(kind, key, muxedId);
    }

    function tagged(AddressKind kind, bytes32 key, uint64 muxedId) external pure returns (bytes memory) {
        return StellarAddress.tagged(kind, key, muxedId);
    }

    function strkeyDestination(AddressKind kind, string calldata value) external pure returns (bytes memory) {
        return StellarAddress.strkeyDestination(kind, value);
    }

    function needsTrustline(AddressKind kind) external pure returns (bool) {
        return StellarAddress.needsTrustline(kind);
    }

    function checksum(bytes calldata data, uint256 length) external pure returns (uint16) {
        return StellarAddress.checksum(data, length);
    }
}

contract FlowGuardHarness {
    using FlowGuard for FlowWindow;

    FlowWindow private _window;

    function state() external view returns (FlowWindow memory) {
        return _window;
    }

    function epochOf(uint64 timestamp, uint64 window) external pure returns (uint64) {
        return FlowGuard.epochOf(timestamp, window);
    }

    function rollForward(uint64 timestamp, uint64 window) external view returns (FlowWindow memory) {
        return _window.rollForward(timestamp, window);
    }

    function effectiveConsumed(uint64 timestamp, uint64 window) external view returns (uint256) {
        return _window.effectiveConsumed(timestamp, window);
    }

    function available(uint256 limit, uint64 timestamp, uint64 window) external view returns (uint256) {
        return _window.available(limit, timestamp, window);
    }

    function consume(uint256 limit, uint256 amount, uint64 timestamp, uint64 window) external {
        _window = _window.consume(limit, amount, timestamp, window);
    }
}

contract NotesHarness {
    function decodeOutboundNote(bytes calldata payload)
        external
        pure
        returns (address recipient, uint64 nonce)
    {
        return HyperionNotes.decodeOutboundNote(payload);
    }

    function encodeInboundNote(AddressKind kind, string calldata strkey, uint64 nonce)
        external
        pure
        returns (bytes memory)
    {
        return HyperionNotes.encodeInboundNote(kind, strkey, nonce);
    }

    function decodeInboundNote(bytes calldata payload)
        external
        pure
        returns (AddressKind kind, string memory strkey, uint64 nonce)
    {
        return HyperionNotes.decodeInboundNote(payload);
    }

    function encodeCctpHook(AddressKind kind, bytes32 key, uint64 muxedId)
        external
        pure
        returns (bytes memory)
    {
        return HyperionNotes.encodeCctpHook(kind, key, muxedId);
    }

    function toEvmAddress(bytes32 word) external pure returns (address) {
        return HyperionNotes.toEvmAddress(word);
    }

    function toWord(address value) external pure returns (bytes32) {
        return HyperionNotes.toWord(value);
    }
}
