// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "openzeppelin/access/Ownable.sol";

import {
    AlreadyConfigured,
    InvalidAmount,
    InvalidDestination,
    MalformedMessage,
    RailNotConfigured,
    RefundFailed,
    ReplayedMessage,
    TokenNotMapped,
    Unauthorized,
    UnexpectedRailContract,
    UnknownChain,
    UnsupportedHookVersion,
    ZeroAddress,
    ZeroAddressKey
} from "../../src/TraiectaErrors.sol";
import {AddressKind, Destination, RouteKind} from "../../src/TraiectaTypes.sol";
import {AxelarItsAdapter} from "../../src/adapters/AxelarItsAdapter.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";
import {Fixture} from "../Fixture.sol";
import {DeafRouter} from "../mocks/HostileCallers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockGasService} from "../mocks/MockGasService.sol";
import {MockIts} from "../mocks/MockIts.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title The rail that goes both ways
/// @notice Sending over ITS, receiving over ITS, and the one comparison that separates a delivery
/// from somebody helping themselves.
/// @dev Half of this file is about `executeWithInterchainToken` and most of that half is about a
/// single line. ITS will carry a payload from any contract on any connected chain and deliver it
/// here without complaint, so the fact that a call arrived through ITS says nothing whatsoever
/// about who sent it. The peer comparison is what turns "a transfer arrived" into "Hyperion sent
/// this", and an adapter that skipped it would let anybody anywhere mint themselves a delivery.
///
/// The other thing worth knowing: ITS moves the tokens first and calls second. The mock does it
/// in that order for that reason, so an adapter that tried to pull funds it had already been
/// given would fail here rather than in production.
contract AxelarItsAdapterTest is Fixture {
    bytes32 internal constant TOKEN_ID = keccak256("hyperion.its.usdc");

    /// @dev Two base32 characters, used to bend a valid strkey by exactly one place.
    bytes1 internal constant CHAR_A = "A";
    bytes1 internal constant CHAR_B = "B";

    /// @dev Axelar's own name for Stellar happens to match Hyperion's. `BNB_CHAIN` exists so the
    /// tests can prove the translation table does real work rather than being an identity map
    /// nobody would notice was broken.
    string internal constant AXELAR_STELLAR = "stellar";
    string internal constant BNB_CHAIN = "bnb";
    string internal constant AXELAR_BNB = "binance";

    uint256 internal constant AMOUNT = 1000e6;
    uint256 internal constant DELIVERY = 500e6;
    uint64 internal constant NONCE = 7;
    uint64 internal constant SOURCE_NONCE = 4242;
    bytes32 internal constant COMMAND_ID = keccak256("axelar.delivered.this.one");

    AxelarItsAdapter internal adapter;
    MockIts internal its;
    MockGasService internal gasService;

    /// @dev Hyperion's own contract on Stellar, as ITS puts it on the wire: the ascii of a
    /// contract strkey, because Soroban addresses are not twenty bytes and Axelar does not
    /// pretend otherwise.
    bytes internal peerAddress;

    event PeerConfigured(string chain, string axelarChain, bytes peer);
    event PeerEnabled(string chain, bool enabled);
    event TokenLinked(address indexed token, bytes32 tokenId);
    event TransferSubmitted(
        string chain, bytes32 tokenId, uint256 amount, uint64 nonce, uint256 gasValue, bytes note
    );
    event DeliveryAccepted(
        string sourceChain,
        bytes32 indexed commandId,
        address indexed recipient,
        uint256 amount,
        uint64 sourceNonce
    );

    function setUp() public override {
        super.setUp();
        peerAddress = bytes(C_ADDR);

        its = new MockIts();
        gasService = new MockGasService();
        adapter = new AxelarItsAdapter(address(router), address(its), address(gasService), admin);

        its.setRegistered(TOKEN_ID, address(usdc));

        vm.startPrank(admin);
        adapter.setPeer(STELLAR, AXELAR_STELLAR, peerAddress);
        adapter.linkToken(address(usdc), TOKEN_ID);
        vm.stopPrank();

        // The router only takes an arrival from the contract it was told speaks for this rail.
        _setRailReceiver(RouteKind.AxelarIts, address(adapter));

        // ITS holds a float so a delivery can move real tokens, rather than the test minting
        // straight into the adapter and hiding a receiver that reads its balance instead of its
        // arguments.
        usdc.mint(address(its), 10_000_000e6);
    }

    // -------------------------------------------------------------------------------------
    // What the deployment fixes forever
    // -------------------------------------------------------------------------------------

    function test_constructor_wires_what_it_can_never_change() public view {
        assertEq(adapter.ROUTER(), address(router));
        assertEq(address(adapter.ITS()), address(its));
        assertEq(address(adapter.GAS_SERVICE()), address(gasService));
        assertEq(adapter.owner(), admin);
    }

    function test_constructor_refuses_a_zero_router() public {
        vm.expectRevert(ZeroAddress.selector);
        new AxelarItsAdapter(address(0), address(its), address(gasService), admin);
    }

    function test_constructor_refuses_a_zero_its() public {
        vm.expectRevert(ZeroAddress.selector);
        new AxelarItsAdapter(address(router), address(0), address(gasService), admin);
    }

    function test_constructor_refuses_a_zero_gas_service() public {
        vm.expectRevert(ZeroAddress.selector);
        new AxelarItsAdapter(address(router), address(its), address(0), admin);
    }

    function test_route_is_axelar_its() public view {
        assertEq(uint256(adapter.route()), uint256(RouteKind.AxelarIts));
    }

    /// @dev Axelar checks the return value rather than just the absence of a revert, so that a
    /// contract with a permissive fallback cannot accidentally swallow a delivery.
    function test_execute_success_is_the_value_axelar_checks_for() public view {
        assertEq(adapter.EXECUTE_SUCCESS(), keccak256("its-execute-success"));
    }

    /// @dev Zero, and deliberately so. Destination gas is priced by a market on the other chain
    /// that this one cannot see, so the app asks Axelar's estimator and sends that. A number
    /// invented here would look authoritative and be wrong.
    function testFuzz_quote_fee_refuses_to_guess(string calldata chain, uint256 amount) public view {
        assertEq(adapter.quoteFee(chain, amount), 0);
    }

    // -------------------------------------------------------------------------------------
    // Peers
    // -------------------------------------------------------------------------------------

    function test_set_peer_configures_enables_and_registers_the_translation() public view {
        AxelarItsAdapter.Peer memory peer = adapter.peerOf(STELLAR);
        assertEq(peer.axelarChain, AXELAR_STELLAR);
        assertEq(peer.peer, peerAddress);
        assertTrue(peer.configured);
        assertTrue(peer.enabled);
        assertTrue(adapter.supportsChain(STELLAR));
        assertEq(adapter.chainForAxelarName(AXELAR_STELLAR), STELLAR);
    }

    /// @dev Axelar calls BNB Chain "binance". Hyperion's names are its own, and the whole reason
    /// a translation table exists is so a rail renaming a chain is a configuration change rather
    /// than a code change.
    function test_set_peer_keeps_hyperions_name_separate_from_axelars() public {
        vm.prank(admin);
        adapter.setPeer(BNB_CHAIN, AXELAR_BNB, hex"1234");

        assertEq(adapter.chainForAxelarName(AXELAR_BNB), BNB_CHAIN);
        assertEq(adapter.peerOf(BNB_CHAIN).axelarChain, AXELAR_BNB);
        assertTrue(adapter.supportsChain(BNB_CHAIN));
        assertFalse(adapter.supportsChain(AXELAR_BNB), "the axelar name is not a hyperion chain");
    }

    function test_set_peer_says_so_twice_because_two_things_happened() public {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PeerConfigured(BNB_CHAIN, AXELAR_BNB, hex"1234");
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PeerEnabled(BNB_CHAIN, true);

        vm.prank(admin);
        adapter.setPeer(BNB_CHAIN, AXELAR_BNB, hex"1234");
    }

    function test_set_peer_refuses_a_chain_with_no_hyperion_name() public {
        vm.prank(admin);
        vm.expectRevert(UnknownChain.selector);
        adapter.setPeer("", AXELAR_BNB, hex"1234");
    }

    function test_set_peer_refuses_a_chain_with_no_axelar_name() public {
        vm.prank(admin);
        vm.expectRevert(UnknownChain.selector);
        adapter.setPeer(BNB_CHAIN, "", hex"1234");
    }

    function test_set_peer_refuses_an_empty_peer() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        adapter.setPeer(BNB_CHAIN, AXELAR_BNB, "");
    }

    /// @dev Repointing a live peer is not a configuration change, it is a new trust assumption,
    /// and those go through the router's timelock by way of a whole new adapter.
    function test_set_peer_refuses_a_second_configuration() public {
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        adapter.setPeer(STELLAR, AXELAR_STELLAR, hex"1234");
    }

    /// @dev Two Hyperion names claiming one Axelar name would make the reverse lookup ambiguous,
    /// and the reverse lookup is what an inbound delivery uses to find out who is allowed to
    /// speak for the chain it says it came from.
    function test_set_peer_refuses_an_axelar_name_somebody_already_claimed() public {
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        adapter.setPeer("stellar-classic", AXELAR_STELLAR, hex"1234");
    }

    function test_set_peer_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setPeer(BNB_CHAIN, AXELAR_BNB, hex"1234");
    }

    function test_set_peer_enabled_needs_a_peer_to_enable() public {
        vm.prank(admin);
        vm.expectRevert(RailNotConfigured.selector);
        adapter.setPeerEnabled(BNB_CHAIN, true);
    }

    function test_set_peer_enabled_closes_and_reopens_a_chain() public {
        vm.prank(admin);
        adapter.setPeerEnabled(STELLAR, false);
        assertFalse(adapter.supportsChain(STELLAR));
        assertTrue(adapter.peerOf(STELLAR).configured, "off is not the same as gone");

        vm.prank(admin);
        adapter.setPeerEnabled(STELLAR, true);
        assertTrue(adapter.supportsChain(STELLAR));
    }

    function test_set_peer_enabled_emits() public {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PeerEnabled(STELLAR, false);
        vm.prank(admin);
        adapter.setPeerEnabled(STELLAR, false);
    }

    function test_set_peer_enabled_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setPeerEnabled(STELLAR, false);
    }

    function test_a_chain_nobody_configured_translates_to_nothing() public view {
        assertFalse(adapter.supportsChain(BNB_CHAIN));
        assertEq(bytes(adapter.chainForAxelarName(AXELAR_BNB)).length, 0);
        assertEq(adapter.peerOf(BNB_CHAIN).peer.length, 0);
    }

    // -------------------------------------------------------------------------------------
    // Token ids
    // -------------------------------------------------------------------------------------

    function test_link_token_records_the_id_and_says_so() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        bytes32 otherId = keccak256("hyperion.its.other");
        its.setRegistered(otherId, address(other));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit TokenLinked(address(other), otherId);
        vm.prank(admin);
        adapter.linkToken(address(other), otherId);

        assertEq(adapter.tokenIdOf(address(other)), otherId);
    }

    function test_link_token_refuses_a_zero_token() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        adapter.linkToken(address(0), keccak256("x"));
    }

    function test_link_token_refuses_a_zero_id() public {
        vm.prank(admin);
        vm.expectRevert(TokenNotMapped.selector);
        adapter.linkToken(makeAddr("token"), bytes32(0));
    }

    function test_link_token_refuses_a_second_link() public {
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        adapter.linkToken(address(usdc), TOKEN_ID);
    }

    /// @dev A token id is the same value on every chain, which makes it exactly the sort of
    /// constant that gets pasted in from the wrong row of a spreadsheet. ITS already knows the
    /// answer, so asking turns a typo into a failed transaction now rather than a delivery that
    /// arrives as some other asset later.
    function test_link_token_asks_its_rather_than_trusting_the_argument() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(admin);
        vm.expectRevert(TokenNotMapped.selector);
        adapter.linkToken(address(other), TOKEN_ID);
    }

    function test_link_token_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.linkToken(makeAddr("token"), keccak256("x"));
    }

    // -------------------------------------------------------------------------------------
    // Leaving
    // -------------------------------------------------------------------------------------

    function test_dispatch_refuses_a_caller_that_is_not_the_router() public {
        _fund(AMOUNT);
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_zero_amount() public {
        vm.prank(address(router));
        vm.expectRevert(InvalidAmount.selector);
        adapter.dispatch(address(usdc), 0, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_token_nobody_linked() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(address(router));
        vm.expectRevert(TokenNotMapped.selector);
        adapter.dispatch(address(other), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_chain_with_no_peer() public {
        _fund(AMOUNT);
        Destination memory destination = Destination({chain: BNB_CHAIN, strkey: G_ADDR});
        vm.prank(address(router));
        vm.expectRevert(UnknownChain.selector);
        adapter.dispatch(address(usdc), AMOUNT, destination, NONCE);
    }

    function test_dispatch_refuses_a_peer_that_was_switched_off() public {
        _fund(AMOUNT);
        vm.prank(admin);
        adapter.setPeerEnabled(STELLAR, false);

        vm.prank(address(router));
        vm.expectRevert(RailNotConfigured.selector);
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_destination_that_fails_its_checksum() public {
        _fund(AMOUNT);
        Destination memory destination =
            Destination({chain: STELLAR, strkey: "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV"});
        vm.prank(address(router));
        vm.expectRevert(InvalidDestination.selector);
        adapter.dispatch(address(usdc), AMOUNT, destination, NONCE);
    }

    function test_dispatch_hands_its_the_token_the_chain_and_the_peer() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        MockIts.Sent memory sent = its.lastSent();
        assertEq(its.sentCount(), 1);
        assertEq(sent.tokenId, TOKEN_ID);
        assertEq(sent.destinationChain, AXELAR_STELLAR, "axelar's name, not hyperion's");
        assertEq(sent.destinationAddress, peerAddress);
        assertEq(sent.amount, AMOUNT);
        assertEq(usdc.balanceOf(address(adapter)), 0, "an adapter holds nothing afterwards");
    }

    /// @dev Four bytes of envelope version and then the note. Empty metadata and "version zero
    /// followed by nothing" are different things to the receiving side, so the version goes on
    /// even though it is zero.
    function test_dispatch_wraps_the_note_in_axelars_envelope() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        bytes memory note = _inboundNote(AddressKind.Account, G_ADDR, NONCE);
        assertEq(its.lastSent().metadata, abi.encodePacked(uint32(0), note));
    }

    function test_dispatch_names_a_contract_destination() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(C_ADDR), NONCE);

        bytes memory note = _inboundNote(AddressKind.Contract, C_ADDR, NONCE);
        assertEq(its.lastSent().metadata, abi.encodePacked(uint32(0), note));
    }

    /// @dev Thirteen characters longer than the others, and the length byte inside the note is
    /// what tells the Stellar side which it is looking at. The far side reads the nonce from the
    /// end for exactly this reason.
    function test_dispatch_names_a_muxed_destination() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(M_ADDR), NONCE);

        bytes memory note = _inboundNote(AddressKind.MuxedAccount, M_ADDR, NONCE);
        assertEq(its.lastSent().metadata, abi.encodePacked(uint32(0), note));
        assertEq(note.length, 1 + 2 + 69 + 8, "version, tag, length byte, strkey, nonce");
    }

    function test_dispatch_says_what_it_sent_and_where() public {
        _fund(AMOUNT);
        vm.deal(address(router), 1 ether);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit TransferSubmitted(
            STELLAR, TOKEN_ID, AMOUNT, NONCE, 0.2 ether, _inboundNote(AddressKind.Account, G_ADDR, NONCE)
        );

        vm.prank(address(router));
        adapter.dispatch{value: 0.2 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_emits_event_before_external_calls() public {
        _fund(AMOUNT);
        vm.deal(address(router), 1 ether);
        vm.recordLogs();
        vm.prank(address(router));
        adapter.dispatch{value: 0.2 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertTrue(entries.length > 0);
        assertEq(entries[0].emitter, address(adapter));
        bytes32 expectedTopic = keccak256("TransferSubmitted(string,bytes32,uint256,uint64,uint256,bytes)");
        assertEq(entries[0].topics[0], expectedTopic);
    }

    /// @dev ITS writes the gateway log that identifies the delivery, in this same transaction.
    /// Inventing a handle here would hand somebody a value that resolves to nothing.
    function test_dispatch_returns_no_handle_because_there_is_none() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        bytes32 ref = adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
        assertEq(ref, bytes32(0));
    }

    function test_dispatch_forwards_the_whole_gas_payment() public {
        _fund(AMOUNT);
        vm.deal(address(router), 1 ether);

        vm.prank(address(router));
        adapter.dispatch{value: 0.3 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        MockIts.Sent memory sent = its.lastSent();
        assertEq(sent.value, 0.3 ether);
        assertEq(sent.gasValue, 0.3 ether, "the gas argument and the value have to agree");
        assertEq(address(adapter).balance, 0);
    }

    /// @dev The destination gas market takes what it takes. The rest belongs to whoever paid it,
    /// and it gets there by way of the router, which is the contract that knows who that was.
    function test_dispatch_sends_the_unspent_gas_back_to_the_router() public {
        _fund(AMOUNT);
        vm.deal(address(router), 1 ether);
        its.setRefundBps(4000);

        vm.prank(address(router));
        adapter.dispatch{value: 0.5 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        assertEq(address(adapter).balance, 0, "nothing sticks to the adapter");
        assertEq(address(router).balance, 0.7 ether, "half a coin out, forty percent of it back");
    }

    function test_dispatch_reverts_rather_than_stranding_change_it_cannot_return() public {
        DeafRouter deaf = new DeafRouter();
        AxelarItsAdapter orphan =
            new AxelarItsAdapter(address(deaf), address(its), address(gasService), admin);
        vm.startPrank(admin);
        orphan.setPeer(STELLAR, AXELAR_STELLAR, peerAddress);
        orphan.linkToken(address(usdc), TOKEN_ID);
        vm.stopPrank();

        usdc.mint(address(orphan), AMOUNT);
        vm.deal(address(deaf), 1 ether);
        its.setRefundBps(10_000);

        vm.prank(address(deaf));
        vm.expectRevert(RefundFailed.selector);
        orphan.dispatch{value: 0.1 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    // -------------------------------------------------------------------------------------
    // Arriving
    // -------------------------------------------------------------------------------------

    function test_a_delivery_from_the_peer_is_paid_straight_through() public {
        uint256 before = usdc.balanceOf(bob);
        bytes32 ok = _deliver(COMMAND_ID, bob, DELIVERY);

        assertEq(ok, adapter.EXECUTE_SUCCESS());
        assertEq(usdc.balanceOf(bob), before + DELIVERY);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function test_a_delivery_says_where_it_came_from_in_hyperions_own_words() public {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit DeliveryAccepted(STELLAR, COMMAND_ID, bob, DELIVERY, SOURCE_NONCE);
        _deliver(COMMAND_ID, bob, DELIVERY);
    }

    function test_a_delivery_reaches_the_router_as_an_axelar_arrival() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.BridgeIn(
            RouteKind.AxelarIts, bob, address(usdc), DELIVERY, STELLAR, SOURCE_NONCE, COMMAND_ID
        );
        _deliver(COMMAND_ID, bob, DELIVERY);
    }

    function test_a_delivery_from_anybody_but_its_is_refused() public {
        usdc.mint(address(adapter), DELIVERY);
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        adapter.executeWithInterchainToken(
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    /// @dev This is the line the whole rail rests on. ITS delivers a payload from any contract on
    /// any connected chain, so without this anybody could write a note naming themselves and walk
    /// off with whatever the adapter had been handed.
    function test_a_delivery_from_the_wrong_contract_is_refused() public {
        vm.expectRevert(UnexpectedRailContract.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            bytes(G_ADDR),
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    /// @dev Same bytes with one character changed. A prefix comparison, or a comparison that
    /// stopped at the shorter of the two, would let this through.
    function test_a_delivery_from_an_almost_right_contract_is_refused() public {
        bytes memory nearly = bytes(C_ADDR);
        nearly[10] = nearly[10] == CHAR_A ? CHAR_B : CHAR_A;

        vm.expectRevert(UnexpectedRailContract.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            nearly,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_naming_a_chain_with_no_peer_is_refused() public {
        vm.expectRevert(RailNotConfigured.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_BNB,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_on_a_chain_that_was_switched_off_is_refused() public {
        vm.prank(admin);
        adapter.setPeerEnabled(STELLAR, false);

        vm.expectRevert(RailNotConfigured.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_of_nothing_is_refused() public {
        vm.prank(address(its));
        vm.expectRevert(InvalidAmount.selector);
        adapter.executeWithInterchainToken(
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            0
        );
    }

    /// @dev The token and the id both arrive from ITS, and a mismatch means either ITS is
    /// confused or somebody is calling this directly with a pair that was never registered.
    function test_a_delivery_whose_id_does_not_match_its_token_is_refused() public {
        vm.expectRevert(TokenNotMapped.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            keccak256("some.other.id"),
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_with_a_note_of_the_wrong_length_is_refused() public {
        vm.expectRevert(MalformedMessage.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            abi.encodePacked(_outboundNote(bob, SOURCE_NONCE), uint8(0)),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_with_a_note_from_a_future_version_is_refused() public {
        vm.expectRevert(UnsupportedHookVersion.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            abi.encodePacked(uint8(2), bytes20(bob), SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_a_delivery_naming_nobody_is_refused() public {
        vm.expectRevert(ZeroAddressKey.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(address(0), SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    /// @dev An allowance that outlives the call it was granted for is an allowance somebody
    /// eventually finds. The adapter opens it, the router spends it, and the adapter closes it,
    /// all in one transaction.
    function test_a_delivery_leaves_no_standing_allowance_behind() public {
        _deliver(COMMAND_ID, bob, DELIVERY);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }

    /// @dev Axelar's command id is unique per delivery and is what its own replay protection is
    /// keyed on, so the router keys its guard on the same value rather than on a nonce the far
    /// side chose for itself.
    function test_the_same_command_id_cannot_land_twice() public {
        _deliver(COMMAND_ID, bob, DELIVERY);

        vm.expectRevert(ReplayedMessage.selector);
        its.deliver(
            address(adapter),
            COMMAND_ID,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(bob, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            DELIVERY
        );
    }

    function test_two_different_deliveries_both_land() public {
        uint256 before = usdc.balanceOf(bob);
        _deliver(COMMAND_ID, bob, DELIVERY);
        _deliver(keccak256("axelar.delivered.another"), bob, DELIVERY);
        assertEq(usdc.balanceOf(bob), before + DELIVERY * 2);
    }

    // -------------------------------------------------------------------------------------
    // Gas top ups
    // -------------------------------------------------------------------------------------

    /// @dev Permissionless on purpose. A stuck transfer is somebody's money, and the person most
    /// motivated to unstick it is not always whoever holds the operator keys.
    function test_anybody_can_pay_to_unstick_a_delivery() public {
        bytes32 txHash = keccak256("the.transaction.that.ran.short");
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        adapter.topUpGas{value: 0.25 ether}(txHash, 3, stranger);

        MockGasService.TopUp memory top = gasService.lastTopUp();
        assertEq(gasService.topUpCount(), 1);
        assertEq(top.txHash, txHash);
        assertEq(top.logIndex, 3);
        assertEq(top.refundAddress, stranger);
        assertEq(top.value, 0.25 ether, "all of it, with nothing held back");
        assertEq(address(adapter).balance, 0);
    }

    /// @dev Axelar's relayer pays the refund back in its own transaction, long after the one
    /// that sent the transfer. A contract that cannot be paid plainly would have that refund
    /// bounce, which is the quietest possible way to lose somebody's money.
    function test_a_late_gas_refund_can_land_at_all() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool sent,) = payable(address(adapter)).call{value: 0.05 ether}("");
        assertTrue(sent, "the door has to be open for an async refund");
        assertEq(address(adapter).balance, 0.05 ether);
    }

    /// @dev And then it leaves. The next transfer sweeps it to the router, which pays it out as
    /// change. Not to the person who overpaid, which is the honest cost of a rail that does not
    /// say which transfer a refund belongs to.
    function test_a_late_gas_refund_leaves_on_the_next_transfer() public {
        vm.deal(address(adapter), 0.05 ether);
        _fund(AMOUNT);
        uint256 before = address(router).balance;

        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        assertEq(address(adapter).balance, 0);
        assertEq(address(router).balance, before + 0.05 ether);
    }

    function test_a_top_up_of_nothing_is_refused() public {
        vm.prank(stranger);
        vm.expectRevert(InvalidAmount.selector);
        adapter.topUpGas(keccak256("x"), 0, stranger);
    }

    /// @dev Axelar sends the unspent remainder to the refund address, so a zero one is a way of
    /// burning the difference rather than a way of declining it.
    function test_a_top_up_with_nowhere_to_refund_is_refused() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(ZeroAddress.selector);
        adapter.topUpGas{value: 0.1 ether}(keccak256("x"), 0, address(0));
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    function _fund(uint256 amount) internal {
        usdc.mint(address(adapter), amount);
    }

    function _deliver(bytes32 commandId, address recipient, uint256 amount) internal returns (bytes32) {
        return its.deliver(
            address(adapter),
            commandId,
            AXELAR_STELLAR,
            peerAddress,
            _outboundNote(recipient, SOURCE_NONCE),
            TOKEN_ID,
            address(usdc),
            amount
        );
    }

    /// @dev What the Stellar router writes when it sends here. Built by hand rather than by
    /// calling the same encoder the adapter decodes with, because a round trip through one
    /// library proves only that the library agrees with itself.
    function _outboundNote(address recipient, uint64 nonce) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), bytes20(recipient), nonce);
    }

    /// @dev What this side writes when it sends to Stellar. Version, kind tag, one length byte,
    /// the strkey as ascii, and the nonce last so the far side can read it from the end.
    function _inboundNote(AddressKind kind, string memory strkey, uint64 nonce)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory chars = bytes(strkey);
        return abi.encodePacked(uint8(1), uint8(kind), uint8(chars.length), chars, nonce);
    }
}
