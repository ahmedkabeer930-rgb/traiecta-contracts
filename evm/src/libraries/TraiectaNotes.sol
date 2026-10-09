// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MalformedMessage, NotEvmAddress, UnsupportedHookVersion, ZeroAddressKey} from "../TraiectaErrors.sol";
import {AddressKind} from "../TraiectaTypes.sol";
import {StellarAddress} from "./StellarAddress.sol";

/// @title What Hyperion says to itself across a rail
/// @notice Every rail Hyperion routes over delivers to a contract address, not to a person. That
/// is the whole reason these exist: the address on the envelope is Hyperion's own contract on the
/// far side, so who the money is actually for has to be written inside.
///
/// Two shapes, one per direction, because the two directions describe different things. Arriving
/// here from Stellar the note names an EVM address, which is twenty flat bytes read with a slice.
/// Leaving for Stellar it names a Stellar destination, and there it carries the strkey rather than
/// a raw key, because the checksum comes free with the format and catches a flipped bit before
/// anybody gets paid.
///
/// Both carry the originating router's nonce. No contract needs it. The person watching a transfer
/// in the app does, because it is the one value that appears on both sides of the hop, and it is
/// what lets an indexer say "this delivery is that transfer" instead of guessing from amounts and
/// timestamps.
///
/// The mirror of `hyperion_core::axelar` and the hook half of `hyperion_core::cctp`. Packed rather
/// than ABI encoded, because the Soroban side has no ABI encoder and three fixed slices are
/// cheaper to read than a decode.
library HyperionNotes {
    /// @dev One envelope version across both rails, so nobody has to remember which rail numbers
    /// its payloads differently from the other.
    uint8 internal constant NOTE_VERSION = 1;

    /// @dev Version, twenty byte address, eight byte nonce.
    uint256 internal constant OUTBOUND_NOTE_LEN = 29;

    /// @dev The shortest an inbound note can be: version, kind, length, a strkey, a nonce.
    uint256 private constant INBOUND_NOTE_MIN = 1 + 3 + 8;

    /// @notice Read the note that came with a transfer out of Stellar.
    /// @dev Wire form is `[version][20 byte recipient][8 byte big endian nonce]`, written by
    /// `hyperion_core::axelar::OutboundNote::encode`. Exactly twenty nine bytes, refused otherwise:
    /// a note with something appended is a note somebody else built, and reading the first twenty
    /// nine bytes of it anyway is how a parser becomes an attack surface.
    function decodeOutboundNote(bytes calldata payload)
        internal
        pure
        returns (address recipient, uint64 nonce)
    {
        if (payload.length != OUTBOUND_NOTE_LEN) revert MalformedMessage();
        if (uint8(payload[0]) != NOTE_VERSION) revert UnsupportedHookVersion();

        recipient = address(bytes20(payload[1:21]));
        if (recipient == address(0)) revert ZeroAddressKey();
        nonce = uint64(bytes8(payload[21:29]));
    }

    /// @notice Write the note that goes with a transfer into Stellar.
    /// @dev Wire form is `[version][kind][length][ascii strkey][8 byte big endian nonce]`, which
    /// is what `hyperion_core::axelar::InboundNote::decode` expects. Variable length, because a
    /// muxed strkey is thirteen characters longer, and the length byte inside is what says which.
    ///
    /// The far side reads the nonce from the end rather than a fixed offset for that reason, so
    /// nothing here may append anything after it.
    function encodeInboundNote(AddressKind kind, string memory strkey, uint64 nonce)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(NOTE_VERSION, StellarAddress.strkeyDestination(kind, strkey), nonce);
    }

    /// @notice Read an inbound note back.
    /// @dev Nothing on this chain consumes one: this direction is written here and read on Stellar.
    /// It exists so the suite can prove the writer round trips, because a format with no decoder
    /// is a format nobody can show agrees with the reader on the other side.
    function decodeInboundNote(bytes memory payload)
        internal
        pure
        returns (AddressKind kind, string memory strkey, uint64 nonce)
    {
        if (payload.length < INBOUND_NOTE_MIN) revert MalformedMessage();
        if (uint8(payload[0]) != NOTE_VERSION) revert UnsupportedHookVersion();

        uint8 tag = uint8(payload[1]);
        if (tag > uint8(AddressKind.MuxedAccount)) revert MalformedMessage();
        kind = AddressKind(tag);

        uint256 len = uint8(payload[2]);
        if (payload.length != 3 + len + 8) revert MalformedMessage();

        bytes memory chars = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            chars[i] = payload[3 + i];
        }
        strkey = string(chars);

        uint64 value;
        for (uint256 i = 0; i < 8; ++i) {
            value = (value << 8) | uint64(uint8(payload[3 + len + i]));
        }
        nonce = value;
    }

    /// @notice The hook a CCTP burn carries so the far side knows who the USDC is for.
    /// @dev Wire form is `[version][tagged destination]`, which is what
    /// `hyperion_core::cctp::HyperionHook::decode` reads. Thirty four bytes, or forty two for a
    /// muxed destination.
    ///
    /// CCTP's mint recipient is a bare thirty two byte slot with no room for a type tag, and a
    /// bridge cannot tell a contract id from an account key by looking at it. So the mint
    /// recipient names Hyperion's own adapter on the far side and the real destination rides in
    /// here, where there is room to say which of the three kinds it is.
    function encodeCctpHook(AddressKind kind, bytes32 key, uint64 muxedId)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(NOTE_VERSION, StellarAddress.tagged(kind, key, muxedId));
    }

    /// @notice Read a thirty two byte word as an EVM address, or refuse to.
    /// @dev The mirror of `hyperion_core::address::bytes32_to_evm`. The twelve high bytes have to
    /// be zero: truncating a full width word to its last twenty bytes produces an address that
    /// looks completely ordinary and belongs to nobody, and that is the failure this exists to
    /// prevent rather than tidy up.
    function toEvmAddress(bytes32 word) internal pure returns (address) {
        if (uint256(word) >> 160 != 0) revert NotEvmAddress();
        address out = address(uint160(uint256(word)));
        if (out == address(0)) revert ZeroAddressKey();
        return out;
    }

    /// @notice Widen an EVM address into the thirty two byte slot a rail carries it in.
    function toWord(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
