// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AdapterNotSet,
    ClaimAlreadySettled,
    ClaimNotFound,
    InvalidAmount,
    NotRailReceiver,
    RecipientNotReady,
    ReplayedMessage,
    ZeroAddress
} from "../../src/TraiectaErrors.sol";
import {Origin, PendingClaim, RouteKind} from "../../src/TraiectaTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";
import {Fixture} from "../Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VoidReturnToken} from "../mocks/VoidReturnToken.sol";

/// @title Arriving on this chain
/// @notice Who may deliver, what happens when the recipient cannot be paid, and why nothing here
/// ever reverts on the money's behalf.
/// @dev The thing to hold onto while reading this file: by the time `bridgeIn` runs, the rail has
/// already burned or locked the counterpart on the far side. Reverting does not send the money
/// back, it destroys it. So the failures that would be a revert anywhere else are a parked claim
/// here, and the ones that really are reverts are all about the caller being wrong rather than
/// the recipient being awkward.
contract RouterInboundTest is Fixture {
    uint64 internal constant SOURCE_NONCE = 42;
    bytes32 internal constant MESSAGE_ID = keccak256("circle.attested.this.one");

    uint256 internal constant DELIVERY = 500e6;

    function setUp() public override {
        super.setUp();
        // The receiver holds the funds and approves the router, which is what a real adapter does
        // in the same transaction it calls in.
        usdc.mint(railReceiver, 1_000_000e6);
        vm.prank(railReceiver);
        usdc.approve(address(router), type(uint256).max);
    }

    // -------------------------------------------------------------------------------------
    // The ordinary case
    // -------------------------------------------------------------------------------------

    function test_a_delivery_pays_the_recipient_straight_away() public {
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));

        assertEq(claimId, 0, "nothing was parked");
        assertEq(usdc.balanceOf(bob), DELIVERY);
        assertEq(usdc.balanceOf(address(router)), 0, "the router is not a vault");
    }

    function test_a_delivery_says_so_in_the_log() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.BridgeIn(
            RouteKind.Cctp, bob, address(usdc), DELIVERY, STELLAR, SOURCE_NONCE, MESSAGE_ID
        );
        vm.prank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
    }

    function test_a_paused_router_still_accepts_arrivals() public {
        // The single most important test in this file. Pausing stops departures. An arrival is
        // money that has already left somewhere else, and refusing it would strand it.
        vm.prank(guardian);
        router.pause();

        vm.prank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        assertEq(usdc.balanceOf(bob), DELIVERY);
    }

    function test_a_delivery_ignores_the_flow_ceiling() public {
        // Same reasoning. A ceiling refuses, and a refusal here would not undo the burn that
        // paid for the delivery, it would only hold somebody's money hostage to an admin.
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 1);

        vm.prank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        assertEq(usdc.balanceOf(bob), DELIVERY);
    }

    function test_a_token_that_returns_nothing_counts_as_paid() public {
        // The old ERC20s return no data at all. Reading that as a failure would park a claim on
        // every delivery of an asset like this, which is a bug that looks like caution.
        VoidReturnToken quiet = new VoidReturnToken();
        _registerToken(address(quiet), 6, FLOW_LIMIT);
        quiet.mint(railReceiver, 1000e6);
        vm.prank(railReceiver);
        quiet.approve(address(router), type(uint256).max);

        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(quiet), DELIVERY, bob, _origin(MESSAGE_ID));

        assertEq(claimId, 0, "no claim, because the transfer worked");
        assertEq(quiet.balanceOf(bob), DELIVERY);
    }

    // -------------------------------------------------------------------------------------
    // Who is allowed to deliver
    // -------------------------------------------------------------------------------------

    function test_only_the_registered_receiver_may_deliver() public {
        vm.prank(stranger);
        vm.expectRevert(NotRailReceiver.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
    }

    function test_the_adapter_for_a_rail_cannot_deliver_for_a_different_one() public {
        // One right answer per rail, checked with an equality rather than a role. Anything
        // looser than one right answer is a mint function with extra steps.
        _setRailReceiver(RouteKind.AxelarIts, bob);

        vm.prank(railReceiver);
        vm.expectRevert(NotRailReceiver.selector);
        router.bridgeIn(RouteKind.AxelarIts, address(usdc), DELIVERY, alice, _origin(MESSAGE_ID));
    }

    function test_a_rail_with_no_receiver_accepts_nothing() public {
        vm.prank(stranger);
        vm.expectRevert(AdapterNotSet.selector);
        router.bridgeIn(RouteKind.Allbridge, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
    }

    function test_the_router_itself_cannot_deliver() public {
        vm.prank(address(router));
        vm.expectRevert(NotRailReceiver.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
    }

    function test_an_empty_delivery_is_refused() public {
        vm.prank(railReceiver);
        vm.expectRevert(InvalidAmount.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), 0, bob, _origin(MESSAGE_ID));
    }

    function test_a_delivery_for_nobody_is_refused() public {
        vm.prank(railReceiver);
        vm.expectRevert(ZeroAddress.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, address(0), _origin(MESSAGE_ID));
    }

    // -------------------------------------------------------------------------------------
    // Replay
    // -------------------------------------------------------------------------------------

    function test_the_same_message_cannot_be_delivered_twice() public {
        vm.startPrank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        vm.expectRevert(ReplayedMessage.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), DELIVERY, "paid once");
    }

    function test_changing_the_amount_does_not_make_it_a_new_message() public {
        vm.startPrank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        vm.expectRevert(ReplayedMessage.selector);
        router.bridgeIn(RouteKind.Cctp, address(usdc), 1, bob, _origin(MESSAGE_ID));
        vm.stopPrank();
    }

    function test_the_replay_guard_is_kept_per_rail() public {
        // Two rails can legitimately hand out the same identifier, because neither knows the
        // other exists. Sharing one key across all four would let the first arrival block a real
        // second one.
        _setRailReceiver(RouteKind.AxelarIts, railReceiver);

        vm.startPrank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        router.bridgeIn(RouteKind.AxelarIts, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), DELIVERY * 2);
    }

    function test_two_different_messages_both_land() public {
        vm.startPrank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(keccak256("another one")));
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), DELIVERY * 2);
    }

    function test_the_replay_guard_is_written_before_the_payout() public {
        vm.prank(railReceiver);
        router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        assertTrue(router.processed(keccak256(abi.encode(RouteKind.Cctp, MESSAGE_ID))));
    }

    // -------------------------------------------------------------------------------------
    // When the recipient cannot be paid
    // -------------------------------------------------------------------------------------

    function test_a_frozen_recipient_gets_a_claim_rather_than_a_revert() public {
        usdc.setBlocked(bob, true);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ClaimParked(
            1, bob, address(usdc), DELIVERY, RouteKind.Cctp, STELLAR, SOURCE_NONCE
        );
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));

        assertEq(claimId, 1);
        assertEq(usdc.balanceOf(bob), 0, "not paid yet");
        assertEq(usdc.balanceOf(address(router)), DELIVERY, "but the money is here and it is theirs");
    }

    function test_a_parked_claim_records_everything_needed_to_settle_it() public {
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));

        PendingClaim memory claim = router.pendingClaim(claimId);
        assertEq(claim.id, claimId);
        assertEq(claim.recipient, bob);
        assertEq(claim.token, address(usdc));
        assertEq(claim.amount, DELIVERY);
        assertEq(uint8(claim.route), uint8(RouteKind.Cctp));
        assertEq(claim.sourceChain, STELLAR);
        assertEq(claim.sourceNonce, SOURCE_NONCE);
        assertEq(claim.createdAt, uint64(block.timestamp));
        assertFalse(claim.settled);
    }

    function test_a_token_that_declines_quietly_also_parks_a_claim() public {
        // Some tokens return false instead of reverting. Both have to reach the same branch,
        // because the difference is a style choice by whoever wrote the token.
        usdc.setSilentRefusal(true);

        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        assertEq(claimId, 1);
    }

    function test_a_claim_can_be_settled_once_the_recipient_is_unfrozen() public {
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));

        usdc.setBlocked(bob, false);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ClaimSettled(claimId, bob, address(usdc), DELIVERY, stranger);
        vm.prank(stranger);
        router.settleClaim(claimId);

        assertEq(usdc.balanceOf(bob), DELIVERY);
        assertTrue(router.pendingClaim(claimId).settled);
    }

    function test_anybody_may_settle_somebody_elses_claim() public {
        // There is nothing to gain by it. The recipient was fixed when the rail signed the
        // message, so the only thing a settler can do is clear a stuck transfer, which is
        // exactly what somebody watching for stuck transfers should be able to do.
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        usdc.setBlocked(bob, false);

        vm.prank(alice);
        router.settleClaim(claimId);
        assertEq(usdc.balanceOf(bob), DELIVERY);
        assertEq(usdc.balanceOf(alice), 10_000_000e6, "and the settler got nothing for it");
    }

    function test_settling_twice_is_refused() public {
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        usdc.setBlocked(bob, false);

        router.settleClaim(claimId);
        vm.expectRevert(ClaimAlreadySettled.selector);
        router.settleClaim(claimId);
    }

    function test_settling_a_claim_that_does_not_exist_is_refused() public {
        vm.expectRevert(ClaimNotFound.selector);
        router.settleClaim(1);

        vm.expectRevert(ClaimNotFound.selector);
        router.settleClaim(0);
    }

    function test_settling_while_still_frozen_leaves_the_claim_alone() public {
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));

        vm.expectRevert(RecipientNotReady.selector);
        router.settleClaim(claimId);

        // The revert rolled the settled flag back, so this can be retried later rather than
        // being burned by one early attempt.
        assertFalse(router.pendingClaim(claimId).settled);
        assertEq(usdc.balanceOf(address(router)), DELIVERY);
    }

    function test_claims_are_numbered_in_order() public {
        usdc.setBlocked(bob, true);
        vm.startPrank(railReceiver);
        assertEq(router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID)), 1);
        assertEq(router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(keccak256("b"))), 2);
        vm.stopPrank();
        assertEq(router.claimCount(), 2);
    }

    function test_a_claim_is_still_parked_even_while_paused() public {
        usdc.setBlocked(bob, true);
        vm.prank(guardian);
        router.pause();

        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY, bob, _origin(MESSAGE_ID));
        usdc.setBlocked(bob, false);

        router.settleClaim(claimId);
        assertEq(usdc.balanceOf(bob), DELIVERY);
    }

    function test_a_receiver_that_did_not_approve_the_router_fails_loudly() public {
        // Pull rather than trust. If the funds are not actually here, the delivery reverts now
        // instead of writing down a claim against money nobody holds.
        MockERC20 other = new MockERC20("Other", "OTHR", 6);
        _registerToken(address(other), 6, FLOW_LIMIT);
        other.mint(railReceiver, 1000e6);

        vm.prank(railReceiver);
        vm.expectRevert();
        router.bridgeIn(RouteKind.Cctp, address(other), DELIVERY, bob, _origin(MESSAGE_ID));
    }

    function _origin(bytes32 messageId) internal pure returns (Origin memory) {
        return Origin({
            chain: STELLAR,
            nonce: SOURCE_NONCE,
            messageId: messageId,
            sender: keccak256(abi.encodePacked(C_ADDR))
        });
    }
}
