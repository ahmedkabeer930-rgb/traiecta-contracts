// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";

import {
    AlreadyConfigured,
    InvalidAmount,
    InvalidDestination,
    RailNotConfigured,
    RefundFailed,
    TokenNotMapped,
    Unauthorized,
    UnknownChain,
    ZeroAddress
} from "../../src/TraiectaErrors.sol";
import {AddressKind, Destination, RouteKind} from "../../src/TraiectaTypes.sol";
import {CctpAdapter} from "../../src/adapters/CctpAdapter.sol";
import {Fixture} from "../Fixture.sol";
import {DeafRouter} from "../mocks/HostileCallers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTokenMessenger} from "../mocks/MockTokenMessenger.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Handing USDC to Circle
/// @notice What the adapter tells CCTP, and everything it refuses to tell it.
/// @dev There is no attestation to assert on here and no burn to watch, because both of those
/// happen off this chain in software nobody in this repository wrote. What is worth asserting is
/// the part Hyperion is answerable for: the domain, the mint recipient, the finality tier, and
/// the hook bytes that are the only thing standing between a delivery and a pile of USDC sitting
/// at an adapter with no idea who it belongs to.
///
/// That last one is why three of these tests do nothing but compare byte strings. CCTP's mint
/// recipient is a bare thirty two byte slot, so the real destination rides in the hook, and a
/// hook that encodes the right key under the wrong tag is a transfer that completes successfully
/// into the wrong place.
contract CctpAdapterTest is Fixture {
    /// @dev Circle's own number for Stellar.
    uint32 internal constant STELLAR_DOMAIN = 27;

    /// @dev Hyperion's Soroban adapter, which is where every burn on this lane lands. A real
    /// contract id rather than a pattern, because a mint recipient is exactly the value nobody
    /// gets a second look at.
    bytes32 internal constant MINT_RECIPIENT = C_KEY;

    uint256 internal constant AMOUNT = 1000e6;
    uint64 internal constant NONCE = 7;

    CctpAdapter internal adapter;
    MockTokenMessenger internal messenger;

    event LaneConfigured(string chain, uint32 domain, bytes32 mintRecipient);
    event LaneEnabled(string chain, bool enabled);
    event BurnSubmitted(
        string chain, uint32 domain, uint256 amount, bytes32 mintRecipient, uint64 nonce, bytes hookData
    );

    function setUp() public override {
        super.setUp();
        messenger = new MockTokenMessenger();
        adapter = new CctpAdapter(address(router), address(messenger), address(usdc), admin);

        vm.prank(admin);
        adapter.setLane(STELLAR, STELLAR_DOMAIN, MINT_RECIPIENT);
    }

    // -------------------------------------------------------------------------------------
    // What the deployment fixes forever
    // -------------------------------------------------------------------------------------

    function test_constructor_wires_the_three_addresses_it_can_never_change() public view {
        assertEq(adapter.ROUTER(), address(router));
        assertEq(address(adapter.TOKEN_MESSENGER()), address(messenger));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.owner(), admin);
    }

    function test_constructor_refuses_a_zero_router() public {
        vm.expectRevert(ZeroAddress.selector);
        new CctpAdapter(address(0), address(messenger), address(usdc), admin);
    }

    function test_constructor_refuses_a_zero_token_messenger() public {
        vm.expectRevert(ZeroAddress.selector);
        new CctpAdapter(address(router), address(0), address(usdc), admin);
    }

    function test_constructor_refuses_a_zero_usdc() public {
        vm.expectRevert(ZeroAddress.selector);
        new CctpAdapter(address(router), address(messenger), address(0), admin);
    }

    function test_route_is_cctp() public view {
        assertEq(uint256(adapter.route()), uint256(RouteKind.Cctp));
    }

    /// @dev Finalized, not fast. The fast tier charges a fee out of the transferred amount, and a
    /// sender who was quoted a fee of zero would find one had appeared by the time it landed.
    function test_the_finality_tier_is_the_one_that_costs_nothing() public view {
        assertEq(adapter.FINALITY_THRESHOLD_FINALIZED(), 2000);
    }

    /// @dev Not "zero for now". CCTP bills nothing at send time on this tier, so there is no
    /// number this could return that would be more honest than none.
    function testFuzz_quote_fee_is_zero_for_anything_anybody_asks(string calldata chain, uint256 amount)
        public
        view
    {
        assertEq(adapter.quoteFee(chain, amount), 0);
    }

    // -------------------------------------------------------------------------------------
    // Lanes
    // -------------------------------------------------------------------------------------

    function test_set_lane_configures_and_enables_in_one_go() public view {
        CctpAdapter.Lane memory lane = adapter.laneOf(STELLAR);
        assertEq(lane.domain, STELLAR_DOMAIN);
        assertEq(lane.mintRecipient, MINT_RECIPIENT);
        assertTrue(lane.configured);
        assertTrue(lane.enabled);
        assertTrue(adapter.supportsChain(STELLAR));
    }

    function test_set_lane_says_so_twice_because_two_things_happened() public {
        CctpAdapter fresh = new CctpAdapter(address(router), address(messenger), address(usdc), admin);

        vm.expectEmit(true, true, true, true, address(fresh));
        emit LaneConfigured("solana", 5, MINT_RECIPIENT);
        vm.expectEmit(true, true, true, true, address(fresh));
        emit LaneEnabled("solana", true);

        vm.prank(admin);
        fresh.setLane("solana", 5, MINT_RECIPIENT);
    }

    function test_set_lane_refuses_a_chain_with_no_name() public {
        vm.prank(admin);
        vm.expectRevert(UnknownChain.selector);
        adapter.setLane("", STELLAR_DOMAIN, MINT_RECIPIENT);
    }

    /// @dev A zero mint recipient is a burn into a hole. Circle would accept it.
    function test_set_lane_refuses_a_zero_mint_recipient() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        adapter.setLane("solana", 5, bytes32(0));
    }

    /// @dev Once only, and this is the test that keeps it that way. Repointing a live lane moves
    /// every future burn on it to a different contract without anybody watching the router's
    /// timelock seeing a thing.
    function test_set_lane_refuses_a_second_configuration() public {
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        adapter.setLane(STELLAR, STELLAR_DOMAIN, MINT_RECIPIENT);
    }

    function test_set_lane_refuses_a_second_configuration_even_with_new_values() public {
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        adapter.setLane(STELLAR, 99, G_KEY);
    }

    function test_set_lane_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setLane("solana", 5, MINT_RECIPIENT);
    }

    function test_set_lane_enabled_needs_a_lane_to_enable() public {
        vm.prank(admin);
        vm.expectRevert(RailNotConfigured.selector);
        adapter.setLaneEnabled("solana", true);
    }

    function test_set_lane_enabled_closes_and_reopens_a_lane() public {
        vm.prank(admin);
        adapter.setLaneEnabled(STELLAR, false);
        assertFalse(adapter.supportsChain(STELLAR));
        assertTrue(adapter.laneOf(STELLAR).configured, "off is not the same as gone");

        vm.prank(admin);
        adapter.setLaneEnabled(STELLAR, true);
        assertTrue(adapter.supportsChain(STELLAR));
    }

    function test_set_lane_enabled_emits() public {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit LaneEnabled(STELLAR, false);
        vm.prank(admin);
        adapter.setLaneEnabled(STELLAR, false);
    }

    function test_set_lane_enabled_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setLaneEnabled(STELLAR, false);
    }

    function test_a_chain_nobody_configured_is_not_supported() public view {
        assertFalse(adapter.supportsChain("solana"));
        CctpAdapter.Lane memory lane = adapter.laneOf("solana");
        assertFalse(lane.configured);
        assertEq(lane.domain, 0);
        assertEq(lane.mintRecipient, bytes32(0));
    }

    // -------------------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------------------

    /// @dev Two steps rather than one, because handing a lane registry to a mistyped address is
    /// not a transaction anybody notices until the first transfer on a new chain has nowhere to
    /// go. The old owner keeps working until the new one proves it exists.
    function test_ownership_takes_two_steps() public {
        vm.prank(admin);
        adapter.transferOwnership(bob);

        assertEq(adapter.owner(), admin, "still the old owner");
        assertEq(adapter.pendingOwner(), bob);

        vm.prank(admin);
        adapter.setLane("solana", 5, MINT_RECIPIENT);

        vm.prank(bob);
        adapter.acceptOwnership();
        assertEq(adapter.owner(), bob);
        assertEq(adapter.pendingOwner(), address(0));
    }

    function test_a_pending_owner_cannot_act_before_accepting() public {
        vm.prank(admin);
        adapter.transferOwnership(bob);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        adapter.setLane("solana", 5, MINT_RECIPIENT);
    }

    // -------------------------------------------------------------------------------------
    // Dispatch, and everything it turns down
    // -------------------------------------------------------------------------------------

    function test_dispatch_refuses_a_caller_that_is_not_the_router() public {
        _fund(AMOUNT);
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    /// @dev One asset, decided at deployment. An adapter that took whatever it was handed would
    /// be an adapter that burns a token Circle has never heard of and loses it.
    function test_dispatch_refuses_a_token_that_is_not_usdc() public {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        vm.prank(address(router));
        vm.expectRevert(TokenNotMapped.selector);
        adapter.dispatch(address(other), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_zero_amount() public {
        vm.prank(address(router));
        vm.expectRevert(InvalidAmount.selector);
        adapter.dispatch(address(usdc), 0, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_refuses_a_chain_with_no_lane() public {
        _fund(AMOUNT);
        Destination memory destination = Destination({chain: "solana", strkey: G_ADDR});
        vm.prank(address(router));
        vm.expectRevert(UnknownChain.selector);
        adapter.dispatch(address(usdc), AMOUNT, destination, NONCE);
    }

    /// @dev A different refusal from the one above, and the difference matters to whoever is
    /// reading the failure: one says "Hyperion does not go there", the other says "not right now".
    function test_dispatch_refuses_a_lane_that_was_switched_off() public {
        _fund(AMOUNT);
        vm.prank(admin);
        adapter.setLaneEnabled(STELLAR, false);

        vm.prank(address(router));
        vm.expectRevert(RailNotConfigured.selector);
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    /// @dev The router already parsed this address once. Parsing it again here costs a few
    /// thousand gas and means an adapter reached directly, or reached through a future router
    /// that trusts its caller more than this one does, still cannot burn into a typo.
    function test_dispatch_refuses_a_destination_that_fails_its_checksum() public {
        _fund(AMOUNT);
        Destination memory destination =
            Destination({chain: STELLAR, strkey: "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV"});
        vm.prank(address(router));
        vm.expectRevert(InvalidDestination.selector);
        adapter.dispatch(address(usdc), AMOUNT, destination, NONCE);
    }

    function test_dispatch_fails_loudly_when_nobody_funded_the_adapter() public {
        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, AMOUNT
            )
        );
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    // -------------------------------------------------------------------------------------
    // Dispatch, the part that works
    // -------------------------------------------------------------------------------------

    function test_dispatch_burns_on_the_terms_the_lane_was_configured_with() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        MockTokenMessenger.Burn memory burn = messenger.lastBurn();
        assertEq(messenger.burnCount(), 1);
        assertEq(burn.amount, AMOUNT);
        assertEq(burn.destinationDomain, STELLAR_DOMAIN);
        assertEq(burn.mintRecipient, MINT_RECIPIENT);
        assertEq(burn.burnToken, address(usdc));
        assertEq(burn.minFinalityThreshold, 2000);
    }

    /// @dev Both of these are zero on purpose and neither is an oversight. A destination caller
    /// would make every transfer wait on Hyperion's own key being awake; a max fee would be money
    /// the sender was never quoted.
    function test_dispatch_names_no_destination_caller_and_agrees_to_no_fee() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        MockTokenMessenger.Burn memory burn = messenger.lastBurn();
        assertEq(burn.destinationCaller, bytes32(0));
        assertEq(burn.maxFee, 0);
    }

    function test_dispatch_moves_the_tokens_to_circle() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        assertEq(usdc.balanceOf(address(adapter)), 0, "an adapter holds nothing afterwards");
        assertEq(usdc.balanceOf(address(messenger)), AMOUNT);
    }

    function test_dispatch_hands_circle_a_hook_naming_a_classic_account() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        bytes memory hookData = messenger.lastBurn().hookData;
        assertEq(hookData.length, 34);
        assertEq(hookData, _hook(AddressKind.Account, G_KEY, 0));
    }

    function test_dispatch_hands_circle_a_hook_naming_a_contract() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(C_ADDR), NONCE);

        bytes memory hookData = messenger.lastBurn().hookData;
        assertEq(hookData.length, 34);
        assertEq(hookData, _hook(AddressKind.Contract, C_KEY, 0));
    }

    /// @dev Eight bytes longer, and the eight bytes are the whole point: an exchange routes by
    /// the muxed id, so a hook that dropped it would deliver everybody's money into one account
    /// with nothing to say whose it was.
    function test_dispatch_hands_circle_a_hook_naming_a_muxed_account() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(M_ADDR), NONCE);

        bytes memory hookData = messenger.lastBurn().hookData;
        assertEq(hookData.length, 42);
        assertEq(hookData, _hook(AddressKind.MuxedAccount, G_KEY, MUXED_ID));
    }

    function test_dispatch_says_what_it_sent_and_where() public {
        _fund(AMOUNT);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit BurnSubmitted(
            STELLAR, STELLAR_DOMAIN, AMOUNT, MINT_RECIPIENT, NONCE, _hook(AddressKind.Account, G_KEY, 0)
        );
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    function test_dispatch_emits_event_before_external_calls() public {
        _fund(AMOUNT);
        vm.recordLogs();
        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertTrue(entries.length > 0);
        assertEq(entries[0].emitter, address(adapter));
        bytes32 expectedTopic = keccak256("BurnSubmitted(string,uint32,uint256,bytes32,uint64,bytes)");
        assertEq(entries[0].topics[0], expectedTopic);
    }

    /// @dev Zero, because Circle hands back nothing at burn time. A made up handle would resolve
    /// to nothing anywhere, which is worse than an obvious absence.
    function test_dispatch_returns_no_handle_because_there_is_none() public {
        _fund(AMOUNT);
        vm.prank(address(router));
        bytes32 ref = adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
        assertEq(ref, bytes32(0));
    }

    // -------------------------------------------------------------------------------------
    // Native currency, which this adapter never wanted
    // -------------------------------------------------------------------------------------

    /// @dev CCTP charges no destination gas, so anything sent along with the call is the router
    /// being cautious and all of it goes straight back.
    function test_dispatch_keeps_none_of_the_native_currency_it_was_sent() public {
        _fund(AMOUNT);
        vm.deal(address(router), 1 ether);

        vm.prank(address(router));
        adapter.dispatch{value: 0.1 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        assertEq(address(adapter).balance, 0);
        assertEq(address(router).balance, 1 ether, "out and back, net nothing");
    }

    /// @dev Somebody will eventually send ether to an adapter by mistake. There is no rescue
    /// function because there does not need to be one: the next transfer sweeps it to the router,
    /// which is where the refund path can reach it.
    function test_dispatch_sweeps_a_stray_balance_back_to_the_router() public {
        _fund(AMOUNT);
        vm.deal(address(adapter), 3 ether);
        uint256 before = address(router).balance;

        vm.prank(address(router));
        adapter.dispatch(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);

        assertEq(address(adapter).balance, 0);
        assertEq(address(router).balance, before + 3 ether);
    }

    function test_dispatch_reverts_rather_than_stranding_change_it_cannot_return() public {
        DeafRouter deaf = new DeafRouter();
        CctpAdapter orphan = new CctpAdapter(address(deaf), address(messenger), address(usdc), admin);
        vm.prank(admin);
        orphan.setLane(STELLAR, STELLAR_DOMAIN, MINT_RECIPIENT);

        usdc.mint(address(orphan), AMOUNT);
        vm.deal(address(deaf), 1 ether);

        vm.prank(address(deaf));
        vm.expectRevert(RefundFailed.selector);
        orphan.dispatch{value: 0.1 ether}(address(usdc), AMOUNT, _dest(G_ADDR), NONCE);
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    /// @dev The router pushes the tokens before it calls, so the adapter never pulls. Minting
    /// straight in is the same end state and keeps the test about the adapter.
    function _fund(uint256 amount) internal {
        usdc.mint(address(adapter), amount);
    }

    /// @dev Built by hand rather than by calling the library the adapter calls, because a test
    /// that asks the encoder what the encoder produces proves only that it is deterministic.
    /// Version one, then the kind tag, then the key, then the muxed id if there is one.
    function _hook(AddressKind kind, bytes32 key, uint64 muxedId) internal pure returns (bytes memory) {
        if (kind == AddressKind.MuxedAccount) {
            return abi.encodePacked(uint8(1), uint8(kind), key, muxedId);
        }
        return abi.encodePacked(uint8(1), uint8(kind), key);
    }
}
