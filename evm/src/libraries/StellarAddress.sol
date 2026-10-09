// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidDestination, ZeroAddressKey} from "../TraiectaErrors.sol";
import {AddressKind} from "../TraiectaTypes.sol";

/// @title Stellar destinations, read and checked on this side of the bridge
/// @notice A Stellar address arrives here the way a person copies it out of their wallet: fifty
/// six characters starting with G or C, or sixty nine starting with M. This library takes that
/// string apart and refuses it unless every part agrees.
///
/// The reason it happens on chain rather than in the app is narrow and worth stating. A strkey
/// carries a CRC16 over its own contents, so a single flipped bit between somebody's clipboard
/// and this contract is detectable, and a bridge is the one place where an undetected flipped bit
/// means funds delivered to an address nobody on earth holds the secret for. Handing the contract
/// a pre-split key and trusting the splitter would throw that checksum away, so the checksum is
/// verified here, before anything moves, while the money is still in the sender's wallet.
///
/// The mirror of `hyperion_core::strkey` and `hyperion_core::codec` on the Stellar side. Same
/// version bytes, same polynomial, same surprising little endian checksum.
library StellarAddress {
    /// @dev RFC 4648 base32, and strkeys carry no padding.
    bytes32 private constant ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// @dev SEP-23 version bytes. Each one is a five bit value sitting in the top of a byte, which
    /// is why the first base32 character of a strkey is always the same letter for its kind.
    uint8 internal constant VERSION_ACCOUNT = 6 << 3;
    uint8 internal constant VERSION_CONTRACT = 2 << 3;
    uint8 internal constant VERSION_MUXED = 12 << 3;

    /// @dev Character counts. A muxed strkey is thirteen longer because it folds in an eight byte
    /// sub account id.
    uint256 internal constant STRKEY_LEN_PLAIN = 56;
    uint256 internal constant STRKEY_LEN_MUXED = 69;

    /// @dev Decoded byte counts, checksum included.
    uint256 private constant RAW_LEN_PLAIN = 35;
    uint256 private constant RAW_LEN_MUXED = 43;

    /// @dev Version byte plus payload, checksum excluded.
    uint256 private constant BODY_LEN_PLAIN = 33;
    uint256 private constant BODY_LEN_MUXED = 41;

    /// @dev Byte counts of the tagged binary form, for the rails that give us a bare slot rather
    /// than a payload.
    uint256 internal constant TAGGED_LEN_PLAIN = 33;
    uint256 internal constant TAGGED_LEN_MUXED = 41;

    /// @notice Take a strkey apart, refusing anything that does not add up.
    /// @param value The strkey, exactly as a wallet displays it.
    /// @return kind Which of G, C or M this is.
    /// @return key The raw ed25519 public key, or the contract id.
    /// @return muxedId The sub account id for a muxed address, and zero for the other two.
    function parse(string memory value)
        internal
        pure
        returns (AddressKind kind, bytes32 key, uint64 muxedId)
    {
        bytes memory chars = bytes(value);
        uint256 rawLen;
        uint256 bodyLen;

        if (chars.length == STRKEY_LEN_PLAIN) {
            rawLen = RAW_LEN_PLAIN;
            bodyLen = BODY_LEN_PLAIN;
        } else if (chars.length == STRKEY_LEN_MUXED) {
            rawLen = RAW_LEN_MUXED;
            bodyLen = BODY_LEN_MUXED;
        } else {
            revert InvalidDestination();
        }

        bytes memory raw = _base32Decode(chars, rawLen);

        uint8 version = uint8(raw[0]);
        if (version == VERSION_ACCOUNT) {
            kind = AddressKind.Account;
        } else if (version == VERSION_CONTRACT) {
            kind = AddressKind.Contract;
        } else if (version == VERSION_MUXED) {
            kind = AddressKind.MuxedAccount;
        } else {
            revert InvalidDestination();
        }

        // A muxed version byte on a fifty six character string, or an account version byte on a
        // sixty nine character one. Both decode to something that looks like an address, and
        // neither is the address anybody meant.
        bool wantsMuxed = kind == AddressKind.MuxedAccount;
        if (wantsMuxed != (chars.length == STRKEY_LEN_MUXED)) revert InvalidDestination();

        _verifyChecksum(raw, bodyLen);

        uint256 word;
        for (uint256 i = 0; i < 32; ++i) {
            word = (word << 8) | uint8(raw[1 + i]);
        }
        key = bytes32(word);
        if (key == bytes32(0)) revert ZeroAddressKey();

        if (wantsMuxed) {
            uint64 id;
            for (uint256 i = 0; i < 8; ++i) {
                id = (id << 8) | uint64(uint8(raw[33 + i]));
            }
            muxedId = id;
        }
    }

    /// @notice Build a strkey from its parts.
    /// @dev Nothing on the outbound path needs this: a transfer arrives carrying the string
    /// already and the string is what travels on. It exists so the test suite can prove the
    /// decoder above is the exact inverse of the encoder the Stellar side runs, using the same
    /// published addresses both sides are checked against.
    function encode(AddressKind kind, bytes32 key, uint64 muxedId) internal pure returns (string memory) {
        uint256 bodyLen = kind == AddressKind.MuxedAccount ? BODY_LEN_MUXED : BODY_LEN_PLAIN;
        bytes memory raw = new bytes(bodyLen + 2);

        if (kind == AddressKind.Account) {
            raw[0] = bytes1(VERSION_ACCOUNT);
        } else if (kind == AddressKind.Contract) {
            raw[0] = bytes1(VERSION_CONTRACT);
        } else {
            raw[0] = bytes1(VERSION_MUXED);
        }
        for (uint256 i = 0; i < 32; ++i) {
            raw[1 + i] = key[i];
        }
        if (kind == AddressKind.MuxedAccount) {
            for (uint256 i = 0; i < 8; ++i) {
                // Truncation is the operation. Each pass wants one byte of a sixty four bit id,
                // most significant first, which is what big endian means.
                // forge-lint: disable-next-line(unsafe-typecast)
                raw[33 + i] = bytes1(uint8(muxedId >> (8 * (7 - i))));
            }
        }

        uint16 crc = checksum(raw, bodyLen);
        // Low byte then high byte, because the checksum goes on the wire little endian. Both
        // casts drop the half of the word the line is not asking for, on purpose.
        // forge-lint: disable-next-line(unsafe-typecast)
        raw[bodyLen] = bytes1(uint8(crc));
        // forge-lint: disable-next-line(unsafe-typecast)
        raw[bodyLen + 1] = bytes1(uint8(crc >> 8));

        return string(_base32Encode(raw));
    }

    /// @notice The tagged binary form, for a rail that gives us a fixed slot and no payload.
    /// @dev `[kind][32 byte key]`, with eight big endian bytes of muxed id appended when there is
    /// one. Thirty three bytes or forty one. CCTP's mint recipient is thirty two bytes with no
    /// room for a tag at all, which is why that rail carries this inside its hook instead.
    function tagged(AddressKind kind, bytes32 key, uint64 muxedId) internal pure returns (bytes memory) {
        if (kind == AddressKind.MuxedAccount) {
            return abi.encodePacked(uint8(kind), key, muxedId);
        }
        return abi.encodePacked(uint8(kind), key);
    }

    /// @notice The strkey form, for a rail that gives us a payload to fill.
    /// @dev `[kind][length][ascii strkey]`. One byte of length is enough forever, because the
    /// longest strkey Stellar defines is sixty nine characters and `parse` refuses anything else.
    function strkeyDestination(AddressKind kind, string memory value) internal pure returns (bytes memory) {
        bytes memory chars = bytes(value);
        if (chars.length != STRKEY_LEN_PLAIN && chars.length != STRKEY_LEN_MUXED) {
            revert InvalidDestination();
        }
        return abi.encodePacked(uint8(kind), uint8(chars.length), chars);
    }

    /// @notice Whether this kind of address has to opt into an asset before it can be paid.
    /// @dev Stellar's trustline rule, and the reason an EVM to Stellar quote is not simply "yes".
    /// A contract holds any asset without asking; a classic account holds nothing it has not
    /// opened a trustline for, and a mint into one that has not is a transfer that fails.
    function needsTrustline(AddressKind kind) internal pure returns (bool) {
        return kind != AddressKind.Contract;
    }

    /// @notice CRC16 XModem over the first `length` bytes of `data`.
    /// @dev Polynomial 0x1021, zero initial value, no reflection, no final xor. The shifts stay
    /// inside sixteen bits on their own because the accumulator is a `uint16`.
    function checksum(bytes memory data, uint256 length) internal pure returns (uint16 crc) {
        for (uint256 i = 0; i < length; ++i) {
            crc ^= uint16(uint8(data[i])) << 8;
            for (uint256 bit = 0; bit < 8; ++bit) {
                if (crc & 0x8000 != 0) {
                    crc = uint16(crc << 1) ^ 0x1021;
                } else {
                    crc = uint16(crc << 1);
                }
            }
        }
    }

    function _verifyChecksum(bytes memory raw, uint256 bodyLen) private pure {
        uint16 expected = checksum(raw, bodyLen);
        // Little endian on the wire, which is the one part of the format that surprises everybody
        // who implements it from the spec for the first time.
        uint16 found = uint16(uint8(raw[bodyLen])) | (uint16(uint8(raw[bodyLen + 1])) << 8);
        if (expected != found) revert InvalidDestination();
    }

    function _base32Decode(bytes memory chars, uint256 rawLen) private pure returns (bytes memory raw) {
        raw = new bytes(rawLen);
        uint256 accumulator;
        uint256 pending;
        uint256 written;

        for (uint256 i = 0; i < chars.length; ++i) {
            accumulator = (accumulator << 5) | _charValue(uint8(chars[i]));
            pending += 5;
            if (pending >= 8) {
                pending -= 8;
                // Eight bits have accumulated and this takes exactly those eight. The cast
                // discarding everything above them is how the byte gets peeled off.
                // forge-lint: disable-next-line(unsafe-typecast)
                raw[written++] = bytes1(uint8(accumulator >> pending));
                // One shifted left by the bits still waiting, minus one, is a mask over them.
                // forge-lint: disable-next-line(incorrect-shift)
                accumulator &= (1 << pending) - 1;
            }
        }

        // Sixty nine characters carry three hundred and forty five bits and a muxed address needs
        // three hundred and forty four, so the last character has one spare bit. It has to be
        // zero. If it were not checked, two different strings would decode to the same address,
        // and only one of them is the one the sender looked at.
        if (accumulator != 0) revert InvalidDestination();
        if (written != rawLen) revert InvalidDestination();
    }

    function _base32Encode(bytes memory raw) private pure returns (bytes memory out) {
        uint256 chars = (raw.length * 8 + 4) / 5;
        out = new bytes(chars);
        uint256 accumulator;
        uint256 pending;
        uint256 written;

        for (uint256 i = 0; i < raw.length; ++i) {
            accumulator = (accumulator << 8) | uint8(raw[i]);
            pending += 8;
            while (pending >= 5) {
                pending -= 5;
                out[written++] = ALPHABET[(accumulator >> pending) & 0x1F];
            }
            // Same mask as the decoder, keeping whatever did not fill a whole character yet.
            // forge-lint: disable-next-line(incorrect-shift)
            accumulator &= (1 << pending) - 1;
        }
        if (pending > 0) {
            out[written++] = ALPHABET[(accumulator << (5 - pending)) & 0x1F];
        }
    }

    function _charValue(uint8 c) private pure returns (uint256) {
        if (c >= 0x41 && c <= 0x5A) return c - 0x41;
        if (c >= 0x32 && c <= 0x37) return uint256(c) - 0x32 + 26;
        revert InvalidDestination();
    }
}
