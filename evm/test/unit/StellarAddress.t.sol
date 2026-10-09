// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {InvalidDestination, ZeroAddressKey} from "../../src/TraiectaErrors.sol";
import {AddressKind} from "../../src/TraiectaTypes.sol";
import {StellarAddress} from "../../src/libraries/StellarAddress.sol";
import {StellarAddressHarness} from "../harness/LibHarness.sol";

/// @title SEP-23 strkeys, decoded on an EVM chain
/// @notice Reference addresses, every shape of malformed input, and the round trip.
/// @dev Every address in here is real. They carry genuine CRC16 checksums, which matters because
/// the whole reason Hyperion moves a strkey across a rail instead of a bare thirty two byte key
/// is that the string checks itself. An invented test vector would fail the checksum and prove
/// nothing except that the checksum works.
///
/// The three reference strings are the same ones the Rust side is tested against, so a
/// disagreement between the two implementations shows up as a failing test on one of them rather
/// than as a transfer landing at an address nobody holds.
contract StellarAddressTest is Test {
    string internal constant G_ADDR = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNR";
    string internal constant C_ADDR = "CAGR5KFYMZYI7WWQ6TWYYZ346T7GNZLKER4DOJTAG3SOB46QLR5RAPSN";
    string internal constant M_ADDR = "MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKABAAAAAAAAAAFLXQ";

    bytes32 internal constant G_KEY = 0x3b9c2115c0efd344ba0a8901eb1cfe44f36cf7dbe946beb0ee4820f7ec49bf15;
    bytes32 internal constant C_KEY = 0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10;
    uint64 internal constant MUXED_ID = 9_007_199_254_740_993;

    StellarAddressHarness internal addr;

    function setUp() public {
        addr = new StellarAddressHarness();
    }

    // -------------------------------------------------------------------------------------
    // The happy shapes
    // -------------------------------------------------------------------------------------

    function test_a_classic_account_decodes_to_its_key() public view {
        (AddressKind kind, bytes32 key, uint64 muxedId) = addr.parse(G_ADDR);
        assertEq(uint8(kind), uint8(AddressKind.Account));
        assertEq(key, G_KEY);
        assertEq(muxedId, 0);
    }

    function test_a_contract_id_decodes_to_its_key() public view {
        (AddressKind kind, bytes32 key, uint64 muxedId) = addr.parse(C_ADDR);
        assertEq(uint8(kind), uint8(AddressKind.Contract));
        assertEq(key, C_KEY);
        assertEq(muxedId, 0);
    }

    function test_a_muxed_account_carries_its_base_account_and_its_id() public view {
        // The id here is two to the fifty three plus one, which is the first integer a double
        // cannot hold. Anything that round trips this through a float loses the plus one, and
        // then every sub account on the exchange resolves to the wrong customer.
        (AddressKind kind, bytes32 key, uint64 muxedId) = addr.parse(M_ADDR);
        assertEq(uint8(kind), uint8(AddressKind.MuxedAccount));
        assertEq(key, G_KEY, "a muxed address is its base account plus an integer");
        assertEq(muxedId, MUXED_ID);
    }

    function test_encoding_is_the_exact_inverse_of_decoding() public view {
        assertEq(addr.encode(AddressKind.Account, G_KEY, 0), G_ADDR);
        assertEq(addr.encode(AddressKind.Contract, C_KEY, 0), C_ADDR);
        assertEq(addr.encode(AddressKind.MuxedAccount, G_KEY, MUXED_ID), M_ADDR);
    }

    function test_a_muxed_id_of_zero_is_still_a_muxed_address() public view {
        string memory encoded = addr.encode(AddressKind.MuxedAccount, G_KEY, 0);
        assertEq(bytes(encoded).length, 69);
        (AddressKind kind, bytes32 key, uint64 muxedId) = addr.parse(encoded);
        assertEq(uint8(kind), uint8(AddressKind.MuxedAccount));
        assertEq(key, G_KEY);
        assertEq(muxedId, 0);
    }

    // -------------------------------------------------------------------------------------
    // Everything a typo can do
    // -------------------------------------------------------------------------------------

    function test_the_wrong_length_is_refused_before_anything_else() public {
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVN");

        vm.expectRevert(InvalidDestination.selector);
        addr.parse("");

        vm.expectRevert(InvalidDestination.selector);
        addr.parse("GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNRR");
    }

    function test_a_character_outside_the_alphabet_is_refused() public {
        // Base32 as Stellar uses it has no 0, 1, 8 or 9, and no lowercase. A wallet that lets
        // somebody paste a lowercase address should fix it before it gets here, and if it does
        // not, this is where the transfer stops.
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVN1");

        vm.expectRevert(InvalidDestination.selector);
        addr.parse("ga5zyiivydx5grf2bkeqd2y47zcpg3hx3puunpvq5zecb57mjg7rlvnr");
    }

    function test_a_broken_checksum_is_refused() public {
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV");
    }

    function test_an_unknown_version_byte_is_refused() public {
        // Checksum is correct on this one. The version byte is three, which SEP-23 does not
        // assign, so it is refused for being unknown rather than for being corrupt.
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("DA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKIJG");
    }

    function test_a_muxed_version_byte_on_a_short_string_is_refused() public {
        // Also correctly checksummed. It decodes to a version byte that promises a sub account id
        // and a string with no room for one, which is a different address from either reading.
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKHEO");
    }

    function test_an_account_version_byte_on_a_long_string_is_refused() public {
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKAAAAAAAAAAAAFTNI");
    }

    function test_the_spare_bit_in_a_muxed_address_has_to_be_zero() public {
        // Sixty nine base32 characters carry three hundred and forty five bits and a muxed
        // address needs three hundred and forty four. If the leftover bit were ignored, two
        // different strings would name the same account and only one of them is the one the
        // sender read.
        vm.expectRevert(InvalidDestination.selector);
        addr.parse("MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKABAAAAAAAAAAFLXR");
    }

    function test_the_all_zero_account_is_refused() public {
        // A perfectly valid strkey for a key nobody has ever held. Funds sent there are gone, so
        // it is worth the extra branch.
        vm.expectRevert(ZeroAddressKey.selector);
        addr.parse("GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF");
    }

    // -------------------------------------------------------------------------------------
    // The wire forms
    // -------------------------------------------------------------------------------------

    function test_the_tagged_form_is_a_kind_and_a_key() public view {
        bytes memory account = addr.tagged(AddressKind.Account, G_KEY, 0);
        assertEq(account.length, StellarAddress.TAGGED_LEN_PLAIN);
        assertEq(account, abi.encodePacked(uint8(0), G_KEY));

        bytes memory contractId = addr.tagged(AddressKind.Contract, C_KEY, 0);
        assertEq(contractId.length, StellarAddress.TAGGED_LEN_PLAIN);
        assertEq(contractId, abi.encodePacked(uint8(1), C_KEY));
    }

    function test_the_tagged_form_grows_by_eight_for_a_muxed_address() public view {
        bytes memory muxed = addr.tagged(AddressKind.MuxedAccount, G_KEY, MUXED_ID);
        assertEq(muxed.length, StellarAddress.TAGGED_LEN_MUXED);
        assertEq(muxed, abi.encodePacked(uint8(2), G_KEY, MUXED_ID));
    }

    function test_a_muxed_id_on_a_plain_kind_is_dropped_rather_than_smuggled() public view {
        // The kind decides the shape. Passing an id alongside an account kind cannot make the
        // payload longer, because the far side reads the length to decide what it is looking at.
        bytes memory account = addr.tagged(AddressKind.Account, G_KEY, MUXED_ID);
        assertEq(account.length, StellarAddress.TAGGED_LEN_PLAIN);
    }

    function test_the_strkey_form_carries_its_own_length() public view {
        bytes memory wire = addr.strkeyDestination(AddressKind.Account, G_ADDR);
        assertEq(wire.length, 2 + 56);
        assertEq(uint8(wire[0]), uint8(AddressKind.Account));
        assertEq(uint8(wire[1]), 56);
        assertEq(wire, abi.encodePacked(uint8(0), uint8(56), bytes(G_ADDR)));

        bytes memory muxed = addr.strkeyDestination(AddressKind.MuxedAccount, M_ADDR);
        assertEq(muxed.length, 2 + 69);
        assertEq(uint8(muxed[1]), 69);
    }

    function test_the_strkey_form_refuses_a_string_that_is_not_an_address() public {
        vm.expectRevert(InvalidDestination.selector);
        addr.strkeyDestination(AddressKind.Account, "not an address");
    }

    function test_only_a_contract_can_be_paid_without_a_trustline() public view {
        assertTrue(addr.needsTrustline(AddressKind.Account));
        assertTrue(addr.needsTrustline(AddressKind.MuxedAccount));
        assertFalse(addr.needsTrustline(AddressKind.Contract));
    }

    function test_the_checksum_is_crc16_xmodem() public view {
        // Computed independently rather than by this library, because a checksum that only
        // agrees with itself is not a checksum.
        bytes memory body = abi.encodePacked(uint8(6 << 3), G_KEY);
        assertEq(addr.checksum(body, 33), 0xB1D5);
    }
}
