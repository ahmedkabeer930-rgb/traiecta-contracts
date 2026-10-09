// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AddressKind} from "../../src/TraiectaTypes.sol";
import {StellarAddressHarness} from "../harness/LibHarness.sol";

/// @title Property fuzz testing for StellarAddress StrKey checksum mutations
/// @notice Stellar addresses encode a 32-byte key or contract ID alongside a CRC16-XMODEM
/// checksum in RFC 4648 base32 without padding. These fuzz tests prove that any single-bit
/// or byte-level corruption of valid G... (account) or C... (contract) StrKeys cannot bypass
/// validation and is strictly rejected on-chain.
contract StellarAddressFuzzTest is Test {
    uint256 internal constant STRKEY_LEN_PLAIN = 56;
    uint256 internal constant BODY_LEN_PLAIN = 33;
    uint256 internal constant RAW_LEN_PLAIN = 35;

    StellarAddressHarness internal strkey;

    function setUp() public {
        strkey = new StellarAddressHarness();
    }

    /// @notice Primary property test requested in Issue #12.
    /// Exhaustively mutates any random bit in any character of valid G... and C... StrKeys
    /// and verifies that `StellarAddress.parse` strictly reverts.
    function testFuzz_corruptedStrKey_alwaysReverts(
        bytes32 rawKey,
        uint8 mutateByteIndex,
        uint8 mutateBitIndex
    ) public {
        vm.assume(rawKey != bytes32(0));

        // Test classic G... account address
        _verifyCorruptedStrKeyReverts(AddressKind.Account, rawKey, mutateByteIndex, mutateBitIndex);

        // Test C... contract ID address
        _verifyCorruptedStrKeyReverts(AddressKind.Contract, rawKey, mutateByteIndex, mutateBitIndex);
    }

    /// @notice Corrupts any byte/bit within the raw decoded payload (1..32) or checksum (33..34)
    /// without recomputing the CRC, encodes to base32, and proves the CRC16 check strictly fails.
    function testFuzz_corruptedPayloadOrChecksum_alwaysReverts(
        bytes32 rawKey,
        uint8 mutateByteIndex,
        uint8 mutateBitIndex
    ) public {
        vm.assume(rawKey != bytes32(0));

        // Test mutating raw account payload/checksum
        _verifyCorruptedRawBytesReverts(AddressKind.Account, rawKey, mutateByteIndex, mutateBitIndex);

        // Test mutating raw contract payload/checksum
        _verifyCorruptedRawBytesReverts(AddressKind.Contract, rawKey, mutateByteIndex, mutateBitIndex);
    }

    /// @notice Verifies that valid uncorrupted G... and C... keys always parse cleanly.
    function testFuzz_validStrKey_neverReverts(bytes32 rawKey) public view {
        vm.assume(rawKey != bytes32(0));

        string memory gStr = strkey.encode(AddressKind.Account, rawKey, 0);
        (AddressKind gKind, bytes32 gKey, uint64 gMuxed) = strkey.parse(gStr);
        assertEq(uint8(gKind), uint8(AddressKind.Account));
        assertEq(gKey, rawKey);
        assertEq(gMuxed, 0);

        string memory cStr = strkey.encode(AddressKind.Contract, rawKey, 0);
        (AddressKind cKind, bytes32 cKey, uint64 cMuxed) = strkey.parse(cStr);
        assertEq(uint8(cKind), uint8(AddressKind.Contract));
        assertEq(cKey, rawKey);
        assertEq(cMuxed, 0);
    }

    // -------------------------------------------------------------------------------------
    // Internal test helpers
    // -------------------------------------------------------------------------------------

    function _verifyCorruptedStrKeyReverts(
        AddressKind kind,
        bytes32 rawKey,
        uint8 mutateByteIndex,
        uint8 mutateBitIndex
    ) internal {
        string memory valid = strkey.encode(kind, rawKey, 0);
        bytes memory chars = bytes(valid);
        assertEq(chars.length, STRKEY_LEN_PLAIN);

        uint256 bytePos = bound(mutateByteIndex, 0, STRKEY_LEN_PLAIN - 1);
        uint8 bitPos = uint8(bound(mutateBitIndex, 0, 7));

        // Flip exactly one bit in the chosen character
        chars[bytePos] ^= bytes1(uint8(2 ** bitPos));

        string memory corrupted = string(chars);

        // Corrupted StrKey must strictly revert
        vm.expectRevert();
        strkey.parse(corrupted);
    }

    function _verifyCorruptedRawBytesReverts(
        AddressKind kind,
        bytes32 rawKey,
        uint8 mutateByteIndex,
        uint8 mutateBitIndex
    ) internal {
        // Build raw 35-byte binary: [version (1 byte)][key (32 bytes)][crc16 (2 bytes little-endian)]
        bytes memory raw = new bytes(RAW_LEN_PLAIN);
        raw[0] = kind == AddressKind.Account ? bytes1(uint8(6 * 8)) : bytes1(uint8(2 * 8));

        for (uint256 i = 0; i < 32; ++i) {
            raw[1 + i] = rawKey[i];
        }

        uint16 crc = strkey.checksum(raw, BODY_LEN_PLAIN);
        // casting to 'uint8' is safe because crc is 16 bits and we extract the low byte
        // forge-lint: disable-next-line(unsafe-typecast)
        raw[33] = bytes1(uint8(crc));
        // casting to 'uint8' is safe because crc is 16 bits and we extract the high byte
        // forge-lint: disable-next-line(unsafe-typecast)
        raw[34] = bytes1(uint8(crc >> 8));

        // Corrupt any byte from index 1 to 34 (payload or checksum), flipping 1 bit
        uint256 bytePos = bound(mutateByteIndex, 1, RAW_LEN_PLAIN - 1);
        uint8 bitPos = uint8(bound(mutateBitIndex, 0, 7));
        raw[bytePos] ^= bytes1(uint8(2 ** bitPos));

        // If the corrupted key became all zeros, it should revert with ZeroAddressKey
        // Otherwise it should revert with InvalidDestination (CRC mismatch)
        string memory corrupted = _base32Encode(raw);

        vm.expectRevert();
        strkey.parse(corrupted);
    }

    function _base32Encode(bytes memory raw) internal pure returns (string memory) {
        bytes memory alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        uint256 charsLen = (raw.length * 8 + 4) / 5;
        bytes memory out = new bytes(charsLen);
        uint256 accumulator;
        uint256 pending;
        uint256 written;

        for (uint256 i = 0; i < raw.length; ++i) {
            accumulator = (accumulator << 8) | uint8(raw[i]);
            pending += 8;
            while (pending >= 5) {
                pending -= 5;
                out[written++] = alphabet[(accumulator >> pending) & 0x1F];
            }
            accumulator &= (2 ** pending) - 1;
        }
        if (pending > 0) {
            out[written++] = alphabet[(accumulator << (5 - pending)) & 0x1F];
        }
        return string(out);
    }
}
