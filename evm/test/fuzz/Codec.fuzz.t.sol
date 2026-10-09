// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    InvalidDestination,
    MalformedMessage,
    NotEvmAddress,
    UnsupportedHookVersion,
    ZeroAddressKey
} from "../../src/TraiectaErrors.sol";
import {AddressKind} from "../../src/TraiectaTypes.sol";
import {NotesHarness, StellarAddressHarness} from "../harness/LibHarness.sol";

/// @title The address and note codecs, against arbitrary bytes
/// @notice Everything Hyperion knows about where a transfer is going, it learned by reading a
/// string somebody pasted. That makes these two libraries the widest input surface in the
/// codebase and the one place where being approximately right is indistinguishable from being
/// wrong: an address off by one character belongs to nobody, and a transfer to nobody is gone.
/// @dev The test that matters most here is the single character mutation. A strkey carries a CRC16
/// over its own contents, and the reason Hyperion verifies that on chain rather than trusting an
/// app to have done it is precisely so that a bit flipped between a clipboard and a contract gets
/// caught while the money is still in the sender's wallet. That is a claim about every possible
/// mutation, which is not something a handful of chosen cases can support.
contract CodecFuzzTest is Test {
    /// @dev RFC 4648 base32, the same thirty two characters the library encodes with. Held as a
    /// word rather than as bytes so it can be indexed.
    bytes32 internal constant ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// @dev Held as constants rather than cast at the point of use. A string literal converts to
    /// a single byte on its own here, and an explicit cast would be a cast that never needed to
    /// exist.
    bytes1 internal constant CHAR_A = "A";
    bytes1 internal constant CHAR_C = "C";
    bytes1 internal constant CHAR_G = "G";
    bytes1 internal constant CHAR_M = "M";

    uint256 internal constant STRKEY_LEN_PLAIN = 56;
    uint256 internal constant STRKEY_LEN_MUXED = 69;
    uint256 internal constant OUTBOUND_NOTE_LEN = 29;

    StellarAddressHarness internal strkey;
    NotesHarness internal notes;

    function setUp() public {
        strkey = new StellarAddressHarness();
        notes = new NotesHarness();
    }

    // -------------------------------------------------------------------------------------
    // Strkeys, taken apart and put back together
    // -------------------------------------------------------------------------------------

    function testFuzz_a_strkey_round_trips_for_any_key(bytes32 key, uint64 muxedId, uint8 kindSeed)
        public
        view
    {
        vm.assume(key != bytes32(0));
        AddressKind kind = _kind(kindSeed);

        string memory encoded = strkey.encode(kind, key, muxedId);
        (AddressKind parsedKind, bytes32 parsedKey, uint64 parsedMuxedId) = strkey.parse(encoded);

        assertEq(uint8(parsedKind), uint8(kind), "came back as a different kind of address");
        assertEq(parsedKey, key, "the key did not survive the trip");
        // A muxed address is a base account plus an integer, and the integer is the part a codec
        // silently drops without anything looking wrong.
        assertEq(
            parsedMuxedId,
            kind == AddressKind.MuxedAccount ? muxedId : 0,
            "the sub account id did not survive the trip"
        );
    }

    function testFuzz_a_strkey_always_comes_out_the_right_shape(bytes32 key, uint64 muxedId, uint8 kindSeed)
        public
        view
    {
        vm.assume(key != bytes32(0));
        AddressKind kind = _kind(kindSeed);

        bytes memory chars = bytes(strkey.encode(kind, key, muxedId));

        // The first character is fixed by the version byte, which is why every Stellar account
        // anybody has ever seen starts with a G.
        if (kind == AddressKind.Account) {
            assertEq(chars.length, STRKEY_LEN_PLAIN);
            assertEq(chars[0], CHAR_G);
        } else if (kind == AddressKind.Contract) {
            assertEq(chars.length, STRKEY_LEN_PLAIN);
            assertEq(chars[0], CHAR_C);
        } else {
            assertEq(chars.length, STRKEY_LEN_MUXED, "a muxed strkey is thirteen characters longer");
            assertEq(chars[0], CHAR_M);
        }
    }

    function testFuzz_one_wrong_character_is_always_caught(
        bytes32 key,
        uint64 muxedId,
        uint8 kindSeed,
        uint256 at,
        uint8 pick
    ) public {
        vm.assume(key != bytes32(0));
        bytes memory chars = bytes(strkey.encode(_kind(kindSeed), key, muxedId));

        at = bound(at, 0, chars.length - 1);
        bytes1 replacement = ALPHABET[bound(pick, 0, 31)];
        vm.assume(replacement != chars[at]);
        chars[at] = replacement;

        // This is the claim the on chain checksum exists to support, and it holds for a reason
        // rather than by luck: one base32 character is five bits, a five bit error is a burst of
        // five, and a degree sixteen generator polynomial with a nonzero constant term catches
        // every burst up to sixteen. No exceptions, no probability attached.
        //
        // Which refusal comes back depends on what the mutation landed on. A version byte nobody
        // defines, a length that no longer matches the kind, a spare bit that is no longer zero,
        // a key of zero, or the checksum itself. All five are a refusal, and a refusal is the
        // entire requirement.
        vm.expectRevert();
        strkey.parse(string(chars));
    }

    function testFuzz_a_character_outside_the_alphabet_is_always_caught(
        bytes32 key,
        uint64 muxedId,
        uint8 kindSeed,
        uint256 at,
        uint8 raw
    ) public {
        vm.assume(key != bytes32(0));
        vm.assume(!_inAlphabet(raw));

        bytes memory chars = bytes(strkey.encode(_kind(kindSeed), key, muxedId));
        at = bound(at, 0, chars.length - 1);
        chars[at] = bytes1(raw);

        // Base32 has no lower case and no zero, one, eight or nine, which is deliberate on
        // Stellar's part: the characters people transcribe wrongly are not in the set. A decoder
        // that quietly mapped an unknown character to zero would turn a typo into an address.
        vm.expectRevert(InvalidDestination.selector);
        strkey.parse(string(chars));
    }

    function testFuzz_any_other_length_is_refused(uint256 len) public {
        len = bound(len, 0, 200);
        vm.assume(len != STRKEY_LEN_PLAIN && len != STRKEY_LEN_MUXED);

        bytes memory chars = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            chars[i] = CHAR_A;
        }

        vm.expectRevert(InvalidDestination.selector);
        strkey.parse(string(chars));
    }

    function testFuzz_the_tagged_form_is_a_tag_and_then_a_key(bytes32 key, uint64 muxedId, uint8 kindSeed)
        public
        view
    {
        AddressKind kind = _kind(kindSeed);
        bytes memory tagged = strkey.tagged(kind, key, muxedId);

        bytes memory expected = kind == AddressKind.MuxedAccount
            ? abi.encodePacked(uint8(kind), key, muxedId)
            : abi.encodePacked(uint8(kind), key);

        // Built by hand rather than by calling the thing under test. A tagged destination is what
        // goes into a CCTP hook, where the far side reads it by fixed offset, so the layout is the
        // contract between the two chains and not an implementation detail.
        assertEq(tagged, expected);
        assertEq(tagged.length, kind == AddressKind.MuxedAccount ? 41 : 33);
    }

    function testFuzz_the_strkey_form_carries_its_own_length(bytes32 key, uint64 muxedId, uint8 kindSeed)
        public
        view
    {
        vm.assume(key != bytes32(0));
        AddressKind kind = _kind(kindSeed);

        string memory encoded = strkey.encode(kind, key, muxedId);
        bytes memory destination = strkey.strkeyDestination(kind, encoded);

        assertEq(destination, abi.encodePacked(uint8(kind), uint8(bytes(encoded).length), encoded));
        assertEq(destination.length, 2 + bytes(encoded).length);
    }

    function testFuzz_only_a_contract_can_be_paid_without_asking_first(uint8 kindSeed) public view {
        AddressKind kind = _kind(kindSeed);

        // Stellar's trustline rule, and the reason a quote into Stellar is not simply yes. A
        // contract holds any asset the moment it is sent one; a classic account holds nothing it
        // has not opened a trustline for, and a transfer into one that has not opened it fails.
        assertEq(strkey.needsTrustline(kind), kind != AddressKind.Contract);
    }

    function testFuzz_the_checksum_reads_only_as_far_as_it_was_told_to(
        bytes32 bodySeed,
        bytes32 tailSeed,
        uint256 bodyLen,
        uint256 tailLen
    ) public view {
        // Lengths are derived rather than assumed, so the run never spends its budget rejecting
        // arrays the fuzzer happened to make too long.
        bytes memory body = _slice(bodySeed, bound(bodyLen, 0, 32));
        bytes memory tail = _slice(tailSeed, bound(tailLen, 1, 32));

        // The checksum covers the body and stops before the two bytes holding itself, so an off
        // by one here would either read its own checksum back into the calculation or miss the
        // last byte of the key. Both verify happily against themselves and disagree with Stellar.
        assertEq(
            strkey.checksum(abi.encodePacked(body, tail), body.length),
            strkey.checksum(body, body.length),
            "the checksum looked past the length it was given"
        );
    }

    // -------------------------------------------------------------------------------------
    // Notes, which is what Hyperion says to itself across a rail
    // -------------------------------------------------------------------------------------

    function testFuzz_an_outbound_note_round_trips(address recipient, uint64 nonce) public view {
        vm.assume(recipient != address(0));

        // Built by hand, because a round trip through one library only ever proves that the
        // library agrees with itself. This is the layout `hyperion_core::axelar` writes.
        bytes memory note = abi.encodePacked(uint8(1), bytes20(recipient), nonce);
        assertEq(note.length, OUTBOUND_NOTE_LEN, "version, address, nonce");

        (address decoded, uint64 decodedNonce) = notes.decodeOutboundNote(note);
        assertEq(decoded, recipient);
        assertEq(decodedNonce, nonce, "the nonce is how an indexer joins the two halves of a hop");
    }

    function testFuzz_an_outbound_note_of_any_other_length_is_refused(uint256 len) public {
        len = bound(len, 0, 120);
        vm.assume(len != OUTBOUND_NOTE_LEN);

        // Reading the first twenty nine bytes of something longer is how a parser turns into an
        // attack surface. A note with anything appended is a note somebody else built.
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeOutboundNote(new bytes(len));
    }

    function testFuzz_an_outbound_note_of_any_other_version_is_refused(
        uint8 version,
        address recipient,
        uint64 nonce
    ) public {
        vm.assume(version != 1);

        vm.expectRevert(UnsupportedHookVersion.selector);
        notes.decodeOutboundNote(abi.encodePacked(version, bytes20(recipient), nonce));
    }

    function testFuzz_an_outbound_note_naming_nobody_is_refused(uint64 nonce) public {
        vm.expectRevert(ZeroAddressKey.selector);
        notes.decodeOutboundNote(abi.encodePacked(uint8(1), bytes20(address(0)), nonce));
    }

    function testFuzz_an_inbound_note_round_trips(bytes32 key, uint64 muxedId, uint64 nonce, uint8 kindSeed)
        public
        view
    {
        vm.assume(key != bytes32(0));
        AddressKind kind = _kind(kindSeed);

        string memory encoded = strkey.encode(kind, key, muxedId);
        bytes memory note = notes.encodeInboundNote(kind, encoded, nonce);

        (AddressKind decodedKind, string memory decodedStrkey, uint64 decodedNonce) =
            notes.decodeInboundNote(note);

        assertEq(uint8(decodedKind), uint8(kind));
        assertEq(decodedStrkey, encoded, "the address came back changed");
        assertEq(decodedNonce, nonce);
        assertEq(note.length, 3 + bytes(encoded).length + 8, "version, tag, length, strkey, nonce");

        // And the whole way back to the key, because the far side parses the string rather than
        // trusting the tag that travelled beside it.
        (, bytes32 parsedKey,) = strkey.parse(decodedStrkey);
        assertEq(parsedKey, key);
    }

    function testFuzz_an_inbound_note_that_lies_about_its_length_is_refused(
        bytes32 key,
        uint64 nonce,
        uint8 claimed
    ) public {
        vm.assume(key != bytes32(0));
        bytes memory note =
            notes.encodeInboundNote(AddressKind.Account, strkey.encode(AddressKind.Account, key, 0), nonce);
        vm.assume(claimed != uint8(bytes(note)[2]));

        note[2] = bytes1(claimed);

        // The far side reads the nonce from the end of the note and the address by the length
        // byte, so a length that does not match the note it arrived in has to be refused rather
        // than trusted enough to slice with.
        vm.expectRevert(MalformedMessage.selector);
        notes.decodeInboundNote(note);
    }

    function testFuzz_an_inbound_note_with_an_unknown_tag_is_refused(bytes32 key, uint64 nonce, uint8 tag)
        public
    {
        vm.assume(key != bytes32(0));
        vm.assume(tag > uint8(AddressKind.MuxedAccount));

        bytes memory note =
            notes.encodeInboundNote(AddressKind.Account, strkey.encode(AddressKind.Account, key, 0), nonce);
        note[1] = bytes1(tag);

        vm.expectRevert(MalformedMessage.selector);
        notes.decodeInboundNote(note);
    }

    function testFuzz_a_cctp_hook_is_a_version_and_then_a_destination(
        bytes32 key,
        uint64 muxedId,
        uint8 kindSeed
    ) public view {
        AddressKind kind = _kind(kindSeed);
        bytes memory hook = notes.encodeCctpHook(kind, key, muxedId);

        assertEq(hook, abi.encodePacked(uint8(1), strkey.tagged(kind, key, muxedId)));
        assertEq(hook.length, kind == AddressKind.MuxedAccount ? 42 : 34);
    }

    // -------------------------------------------------------------------------------------
    // Words and addresses
    // -------------------------------------------------------------------------------------

    function testFuzz_an_address_round_trips_through_a_word(address value) public view {
        vm.assume(value != address(0));
        assertEq(notes.toEvmAddress(notes.toWord(value)), value);
    }

    function testFuzz_a_word_with_anything_in_the_high_bytes_is_refused(bytes32 word) public {
        vm.assume(uint256(word) >> 160 != 0);

        // Truncating a full width word to its last twenty bytes produces an address that looks
        // entirely ordinary and belongs to nobody. That is the failure this refusal exists to
        // prevent rather than to tidy up after.
        vm.expectRevert(NotEvmAddress.selector);
        notes.toEvmAddress(word);
    }

    function testFuzz_a_word_naming_nobody_is_refused() public {
        vm.expectRevert(ZeroAddressKey.selector);
        notes.toEvmAddress(bytes32(0));
    }

    // -------------------------------------------------------------------------------------

    function _kind(uint8 seed) internal pure returns (AddressKind) {
        return AddressKind(uint8(bound(seed, 0, 2)));
    }

    function _slice(bytes32 seed, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = seed[i];
        }
    }

    function _inAlphabet(uint8 c) internal pure returns (bool) {
        if (c >= 0x41 && c <= 0x5A) return true;
        return c >= 0x32 && c <= 0x37;
    }
}
