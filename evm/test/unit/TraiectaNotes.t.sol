// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    MalformedMessage,
    NotEvmAddress,
    UnsupportedHookVersion,
    ZeroAddressKey
} from "../../src/TraiectaErrors.sol";
import {AddressKind} from "../../src/TraiectaTypes.sol";
import {HyperionNotes} from "../../src/libraries/TraiectaNotes.sol";
import {NotesHarness} from "../harness/LibHarness.sol";

/// @title The two notes Hyperion sends itself, byte by byte
/// @notice Outbound notes are read here, inbound notes are written here, and both are checked
/// against the wire format rather than against each other.
/// @dev The outbound tests build their payload with `abi.encodePacked` instead of calling an
/// encoder, deliberately. This chain has no outbound encoder, and even if it had one, a decoder
/// checked only against its own encoder proves the pair agree and nothing about whether either
/// matches what the Soroban side writes. The layout in these tests is the layout in
/// `hyperion_core::axelar`, typed out by hand so a change on either side breaks a test.
contract HyperionNotesTest is Test {
    string internal constant G_ADDR = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNR";
    string internal constant C_ADDR = "CAGR5KFYMZYI7WWQ6TWYYZ346T7GNZLKER4DOJTAG3SOB46QLR5RAPSN";
    string internal constant M_ADDR = "MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKABAAAAAAAAAAFLXQ";

    bytes32 internal constant G_KEY = 0x3b9c2115c0efd344ba0a8901eb1cfe44f36cf7dbe946beb0ee4820f7ec49bf15;
    bytes32 internal constant C_KEY = 0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10;
    uint64 internal constant MUXED_ID = 9_007_199_254_740_993;

    address internal constant RECIPIENT = 0x00000000000000000000000000000000000bEEf1;
    uint64 internal constant NONCE = 0x0102030405060708;

    NotesHarness internal notes;

    function setUp() public {
        notes = new NotesHarness();
    }

    // -------------------------------------------------------------------------------------
    // Stellar to here
    // -------------------------------------------------------------------------------------

    function test_an_outbound_note_is_a_version_an_address_and_a_counter() public view {
        bytes memory payload = abi.encodePacked(uint8(1), RECIPIENT, NONCE);
        assertEq(payload.length, HyperionNotes.OUTBOUND_NOTE_LEN);

        (address recipient, uint64 nonce) = notes.decodeOutboundNote(payload);
        assertEq(recipient, RECIPIENT);
        assertEq(nonce, NONCE);
    }

    function test_the_nonce_is_read_big_endian() public view {
        // One byte in the wrong place here turns transfer number one into transfer number
        // seventy two quadrillion, and the indexer stops being able to pair the two sides of a
        // hop. Worth an explicit case rather than trusting the type.
        bytes memory payload = abi.encodePacked(uint8(1), RECIPIENT, hex"0000000000000001");
        (, uint64 nonce) = notes.decodeOutboundNote(payload);
        assertEq(nonce, 1);
    }

    function test_the_largest_nonce_survives_the_trip() public view {
        bytes memory payload = abi.encodePacked(uint8(1), RECIPIENT, type(uint64).max);
        (, uint64 nonce) = notes.decodeOutboundNote(payload);
        assertEq(nonce, type(uint64).max);
    }

    function test_a_note_of_the_wrong_length_is_refused() public {
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(1), RECIPIENT, uint32(0)));

        // Twenty nine bytes of note with a byte glued on the end. Reading the first twenty nine
        // anyway is how a parser becomes somebody's way in.
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(1), RECIPIENT, NONCE, uint8(0)));

        vm.expectRevert(MalformedMessage.selector);
        notes.decodeOutboundNote("");
    }

    function test_a_version_this_build_does_not_know_is_refused() public {
        vm.expectRevert(UnsupportedHookVersion.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(2), RECIPIENT, NONCE));

        vm.expectRevert(UnsupportedHookVersion.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(0), RECIPIENT, NONCE));
    }

    function test_a_note_naming_nobody_is_refused() public {
        vm.expectRevert(ZeroAddressKey.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(1), address(0), NONCE));
    }

    // -------------------------------------------------------------------------------------
    // Here to Stellar
    // -------------------------------------------------------------------------------------

    function test_an_inbound_note_carries_the_strkey_itself() public view {
        bytes memory note = notes.encodeInboundNote(AddressKind.Account, G_ADDR, NONCE);

        assertEq(note.length, 1 + 2 + 56 + 8);
        assertEq(uint8(note[0]), 1, "version");
        assertEq(uint8(note[1]), uint8(AddressKind.Account), "kind");
        assertEq(uint8(note[2]), 56, "length of the strkey");
        assertEq(note, abi.encodePacked(uint8(1), uint8(0), uint8(56), bytes(G_ADDR), NONCE));
    }

    function test_a_muxed_destination_makes_the_note_thirteen_bytes_longer() public view {
        bytes memory note = notes.encodeInboundNote(AddressKind.MuxedAccount, M_ADDR, NONCE);
        assertEq(note.length, 1 + 2 + 69 + 8);
        assertEq(uint8(note[2]), 69);
    }

    function test_every_kind_of_destination_round_trips() public view {
        _roundTrip(AddressKind.Account, G_ADDR);
        _roundTrip(AddressKind.Contract, C_ADDR);
        _roundTrip(AddressKind.MuxedAccount, M_ADDR);
    }

    function test_the_nonce_sits_at_the_very_end() public view {
        // The Soroban decoder reads the nonce from the end of the payload rather than from a
        // fixed offset, because the strkey in front of it changes length. Anything appended
        // after the nonce would be read as the nonce.
        bytes memory note = notes.encodeInboundNote(AddressKind.Account, G_ADDR, NONCE);
        bytes memory tail = new bytes(8);
        for (uint256 i = 0; i < 8; ++i) {
            tail[i] = note[note.length - 8 + i];
        }
        assertEq(tail, abi.encodePacked(NONCE));
    }

    function test_a_note_for_something_that_is_not_an_address_is_never_written() public {
        vm.expectRevert();
        notes.encodeInboundNote(AddressKind.Account, "GIVE ME ALL THE MONEY", NONCE);
    }

    function test_an_inbound_note_with_a_lying_length_byte_is_refused() public {
        bytes memory note = notes.encodeInboundNote(AddressKind.Account, G_ADDR, NONCE);
        note[2] = bytes1(uint8(55));
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeInboundNote(note);
    }

    function test_an_inbound_note_with_an_unknown_kind_is_refused() public {
        bytes memory note = notes.encodeInboundNote(AddressKind.Account, G_ADDR, NONCE);
        note[1] = bytes1(uint8(3));
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeInboundNote(note);
    }

    function test_an_inbound_note_too_short_to_hold_anything_is_refused() public {
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeInboundNote(abi.encodePacked(uint8(1), uint8(0), uint8(0)));
    }

    function test_an_inbound_note_from_a_future_version_is_refused() public {
        bytes memory note = notes.encodeInboundNote(AddressKind.Account, G_ADDR, NONCE);
        note[0] = bytes1(uint8(9));
        vm.expectRevert(UnsupportedHookVersion.selector);
        notes.decodeInboundNote(note);
    }

    // -------------------------------------------------------------------------------------
    // The CCTP hook
    // -------------------------------------------------------------------------------------

    function test_the_hook_is_a_version_and_a_tagged_destination() public view {
        bytes memory hook = notes.encodeCctpHook(AddressKind.Account, G_KEY, 0);
        assertEq(hook.length, 34);
        assertEq(hook, abi.encodePacked(uint8(1), uint8(0), G_KEY));

        bytes memory toContract = notes.encodeCctpHook(AddressKind.Contract, C_KEY, 0);
        assertEq(toContract.length, 34);
        assertEq(uint8(toContract[1]), uint8(AddressKind.Contract));
    }

    function test_a_muxed_hook_is_eight_bytes_wider() public view {
        bytes memory hook = notes.encodeCctpHook(AddressKind.MuxedAccount, G_KEY, MUXED_ID);
        assertEq(hook.length, 42);
        assertEq(hook, abi.encodePacked(uint8(1), uint8(2), G_KEY, MUXED_ID));
    }

    function test_the_hook_version_is_the_note_version() public pure {
        // Deliberately the same number on both rails. If these ever drift apart, whoever is
        // debugging a stuck transfer has to remember which rail counts its payloads differently,
        // and at three in the morning they will not.
        assertEq(HyperionNotes.NOTE_VERSION, 1);
    }

    // -------------------------------------------------------------------------------------
    // Words and addresses
    // -------------------------------------------------------------------------------------

    function test_a_clean_word_becomes_an_address() public view {
        assertEq(notes.toEvmAddress(bytes32(uint256(uint160(RECIPIENT)))), RECIPIENT);
    }

    function test_a_word_with_anything_above_twenty_bytes_is_refused() public {
        // This is the one that matters. Truncating silently yields an address that looks entirely
        // normal and belongs to nobody, so the funds go somewhere real and unreachable.
        bytes32 dirty = bytes32(uint256(uint160(RECIPIENT)) | (uint256(1) << 160));
        vm.expectRevert(NotEvmAddress.selector);
        notes.toEvmAddress(dirty);

        vm.expectRevert(NotEvmAddress.selector);
        notes.toEvmAddress(bytes32(type(uint256).max));
    }

    function test_a_word_of_zeroes_is_refused() public {
        vm.expectRevert(ZeroAddressKey.selector);
        notes.toEvmAddress(bytes32(0));
    }

    function test_widening_and_narrowing_are_inverses() public view {
        address[3] memory samples = [RECIPIENT, address(this), address(0xdEaD)];
        for (uint256 i = 0; i < samples.length; ++i) {
            assertEq(notes.toEvmAddress(notes.toWord(samples[i])), samples[i]);
        }
    }

    function testFuzz_widening_and_narrowing_are_inverses(address value) public view {
        vm.assume(value != address(0));
        assertEq(notes.toEvmAddress(notes.toWord(value)), value);
    }

    function testFuzz_a_dirty_word_is_always_refused(address value, uint96 high) public {
        vm.assume(high != 0);
        bytes32 dirty = bytes32(uint256(uint160(value)) | (uint256(high) << 160));
        vm.expectRevert(NotEvmAddress.selector);
        notes.toEvmAddress(dirty);
    }

    function testFuzz_an_outbound_note_reads_back_what_was_packed(address recipient, uint64 nonce)
        public
        view
    {
        vm.assume(recipient != address(0));
        (address decoded, uint64 decodedNonce) =
            notes.decodeOutboundNote(abi.encodePacked(uint8(1), recipient, nonce));
        assertEq(decoded, recipient);
        assertEq(decodedNonce, nonce);
    }

    function _roundTrip(AddressKind kind, string memory strkey) private view {
        bytes memory note = notes.encodeInboundNote(kind, strkey, NONCE);
        (AddressKind decodedKind, string memory decoded, uint64 nonce) = notes.decodeInboundNote(note);
        assertEq(uint8(decodedKind), uint8(kind));
        assertEq(decoded, strkey);
        assertEq(nonce, NONCE);
    }
}
