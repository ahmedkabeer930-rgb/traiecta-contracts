// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AdapterNotSet,
    AmountNotRepresentable,
    FlowLimitExceeded,
    InvalidAmount,
    InvalidDestination,
    MuxedNotSupported,
    RefundFailed,
    RouteDisabled,
    RouteIsPaused,
    SlippageExceeded,
    TokenDisabled,
    TokenNotRegistered,
    UnknownChain
} from "../../src/TraiectaErrors.sol";
import {HyperionRouter} from "../../src/TraiectaRouter.sol";
import {ActionKind, AdminAction, OutboundRequest, RouteKind, TokenConfig} from "../../src/TraiectaTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";
import {Fixture} from "../Fixture.sol";
import {ReenteringToken, RefundRefuser} from "../mocks/HostileCallers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRailAdapter} from "../mocks/MockRailAdapter.sol";
import {Pausable} from "openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

/// @title Leaving this chain
/// @notice What the sender is charged, what crosses, and every reason a departure is refused.
/// @dev The order inside `bridgeOut` is fee, then floor, then hand off, and the two tests that
/// pin that order down are the reason this file exists. Flooring before the fee would charge
/// somebody for dust that never left the chain, which is a real bug that reads as a rounding
/// detail in a diff.
contract RouterOutboundTest is Fixture {
    function test_a_plain_transfer_charges_the_fee_and_sends_the_rest() public {
        uint256 amount = 1000e6;
        uint256 expectedFee = 1e6; // ten basis points
        uint256 expectedNet = 999e6;

        vm.prank(alice);
        uint64 nonce = router.bridgeOut(_usdcRequest(amount));

        assertEq(nonce, 1, "the first transfer is number one, not number zero");
        assertEq(usdc.balanceOf(treasury), expectedFee, "the fee went to the treasury");
        assertEq(usdc.balanceOf(address(cctpRail)), expectedNet, "the rest went to the rail");
        assertEq(usdc.balanceOf(address(router)), 0, "the router keeps nothing");
        assertEq(usdc.balanceOf(alice), 10_000_000e6 - amount, "the sender paid exactly the amount");
    }

    function test_the_rail_is_told_the_net_amount_not_the_gross() public {
        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));

        MockRailAdapter.Call memory call = cctpRail.lastCall();
        assertEq(call.token, address(usdc));
        assertEq(call.amount, 999e6, "the fee does not cross the bridge");
        assertEq(call.chain, STELLAR);
        assertEq(call.strkey, G_ADDR);
        assertEq(call.nonce, 1);
        assertEq(cctpRail.callCount(), 1);
    }

    function test_the_nonce_climbs_by_one_per_transfer() public {
        vm.startPrank(alice);
        assertEq(router.bridgeOut(_usdcRequest(100e6)), 1);
        assertEq(router.bridgeOut(_usdcRequest(100e6)), 2);
        assertEq(router.bridgeOut(_usdcRequest(100e6)), 3);
        vm.stopPrank();
        assertEq(router.outboundNonce(), 3);
    }

    function test_the_event_carries_everything_an_indexer_needs() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.BridgeOut(
            RouteKind.Cctp, alice, 1, address(usdc), 1000e6, 1e6, 999e6, STELLAR, G_ADDR, cctpRail.railRef()
        );
        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_a_zero_fee_skips_the_treasury_transfer_entirely() public {
        _setFeeBps(0);

        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(cctpRail)), 1000e6, "all of it crossed");
    }

    function test_the_fee_comes_off_before_the_floor_not_after() public {
        // Six decimals here, six decimals there, so there is no flooring to do and the whole
        // amount minus the fee crosses. This is the control for the test below it.
        MockERC20 sixToSix = new MockERC20("Six", "SIX", 6);
        _registerToken(address(sixToSix), 6, FLOW_LIMIT);
        sixToSix.mint(alice, 1000e6);
        vm.startPrank(alice);
        sixToSix.approve(address(router), type(uint256).max);

        OutboundRequest memory request = _usdcRequest(1000e6);
        request.token = address(sixToSix);
        request.destinationDecimals = 6;
        router.bridgeOut(request);
        vm.stopPrank();

        assertEq(sixToSix.balanceOf(treasury), 1e6);
        assertEq(sixToSix.balanceOf(address(cctpRail)), 999e6);
    }

    function test_an_amount_the_destination_cannot_represent_is_floored() public {
        // Eighteen decimals here, six there. The bottom twelve digits cannot cross, so they do
        // not leave the sender's wallet either.
        MockERC20 wide = new MockERC20("Wide", "WIDE", 18);
        _registerToken(address(wide), 18, type(uint256).max);
        wide.mint(alice, 100e18);
        vm.startPrank(alice);
        wide.approve(address(router), type(uint256).max);

        OutboundRequest memory request = _usdcRequest(1e18 + 999_999_999_999);
        request.token = address(wide);
        request.destinationDecimals = 6;
        router.bridgeOut(request);
        vm.stopPrank();

        uint256 handed = uint256(1e18) + 999_999_999_999;
        uint256 fee = handed / 1000;
        uint256 netRaw = handed - fee;
        // Losing the bottom twelve digits is the operation, not an accident of the order.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 floored = (netRaw / 1e12) * 1e12;
        assertEq(wide.balanceOf(address(cctpRail)), floored, "only what can land crossed");
        assertEq(wide.balanceOf(treasury), fee, "the fee was charged on what was handed over");
        assertEq(wide.balanceOf(alice), 100e18 - floored - fee, "the dust never left the sender");
    }

    function test_an_amount_that_floors_to_nothing_is_refused() public {
        MockERC20 wide = new MockERC20("Wide", "WIDE", 18);
        _registerToken(address(wide), 18, type(uint256).max);
        wide.mint(alice, 1e18);
        vm.startPrank(alice);
        wide.approve(address(router), type(uint256).max);

        OutboundRequest memory request = _usdcRequest(1000);
        request.token = address(wide);
        request.destinationDecimals = 6;
        vm.expectRevert(AmountNotRepresentable.selector);
        router.bridgeOut(request);
        vm.stopPrank();
    }

    function test_a_transfer_that_would_land_short_of_the_floor_is_refused() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        // Seven decimals on Stellar, so 999e6 here lands as 999e7 there. Ask for one unit more
        // than that and the transfer should not happen.
        request.minDestinationAmount = 999e7 + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SlippageExceeded.selector, 999e7 + 1, 999e7));
        router.bridgeOut(request);
    }

    function test_a_transfer_that_lands_exactly_on_the_floor_goes_through() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.minDestinationAmount = 999e7;
        vm.prank(alice);
        router.bridgeOut(request);
        assertEq(cctpRail.callCount(), 1);
    }

    // -------------------------------------------------------------------------------------
    // Refusals
    // -------------------------------------------------------------------------------------

    function test_zero_is_not_a_transfer() public {
        vm.prank(alice);
        vm.expectRevert(InvalidAmount.selector);
        router.bridgeOut(_usdcRequest(0));
    }

    function test_a_disabled_route_refuses_before_it_reads_anything_else() public {
        _enableRoute(RouteKind.Cctp, false);
        vm.prank(alice);
        vm.expectRevert(RouteDisabled.selector);
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_a_transfer_to_nowhere_in_particular_is_refused() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.destination.chain = "";
        vm.prank(alice);
        vm.expectRevert(UnknownChain.selector);
        router.bridgeOut(request);
    }

    function test_a_destination_that_does_not_check_out_is_refused() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.destination.strkey = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV";
        vm.prank(alice);
        vm.expectRevert(InvalidDestination.selector);
        router.bridgeOut(request);
    }

    function test_an_unregistered_token_is_refused() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 6);
        stray.mint(alice, 1000e6);
        vm.startPrank(alice);
        stray.approve(address(router), type(uint256).max);
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.token = address(stray);
        vm.expectRevert(TokenNotRegistered.selector);
        router.bridgeOut(request);
        vm.stopPrank();
    }

    function test_a_route_enabled_before_it_was_wired_up_is_refused() public {
        // A half configured deployment: the route is on, the token is known, and nobody has
        // pointed the route at an adapter yet. Better to fail here than to send the money to
        // the zero address and call it a dispatch.
        HyperionRouter bare = new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);

        AdminAction memory enable = _empty(ActionKind.EnableRoute);
        enable.route = RouteKind.Cctp;
        enable.amount = 1;
        _runOn(bare, enable);

        AdminAction memory register = _empty(ActionKind.RegisterToken);
        register.subject = address(usdc);
        register.amount = FLOW_LIMIT;
        register.decimals = USDC_DECIMALS;
        _runOn(bare, register);

        vm.startPrank(alice);
        usdc.approve(address(bare), type(uint256).max);
        vm.expectRevert(AdapterNotSet.selector);
        bare.bridgeOut(_usdcRequest(1000e6));
        vm.stopPrank();
    }

    function test_a_retired_token_is_refused() public {
        _setTokenEnabled(address(usdc), false);
        assertFalse(router.tokenConfig(address(usdc)).enabled);

        vm.prank(alice);
        vm.expectRevert(TokenDisabled.selector);
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_a_retired_token_can_come_back() public {
        _setTokenEnabled(address(usdc), false);
        _setTokenEnabled(address(usdc), true);

        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));
        assertEq(cctpRail.callCount(), 1);
    }

    function test_retiring_a_token_leaves_its_limit_and_decimals_alone() public {
        _setTokenEnabled(address(usdc), false);
        TokenConfig memory cfg = router.tokenConfig(address(usdc));
        assertTrue(cfg.registered);
        assertEq(cfg.decimals, USDC_DECIMALS);
        assertEq(cfg.flowLimit, FLOW_LIMIT);
    }

    function test_a_token_nobody_registered_cannot_be_retired() public {
        AdminAction memory action = _empty(ActionKind.SetTokenEnabled);
        action.subject = address(0xBEEF);
        action.amount = 0;

        vm.prank(admin);
        vm.expectRevert(TokenNotRegistered.selector);
        router.queueAction(action);
    }

    function test_a_muxed_destination_is_refused_on_the_rail_that_cannot_carry_one() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.route = RouteKind.Allbridge;
        request.destination.strkey = M_ADDR;

        vm.prank(alice);
        vm.expectRevert(MuxedNotSupported.selector);
        router.bridgeOut(request);
    }

    function test_a_muxed_destination_is_fine_on_a_rail_with_a_payload() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.route = RouteKind.AxelarIts;
        request.destination.strkey = M_ADDR;

        vm.prank(alice);
        router.bridgeOut(request);
        assertEq(itsRail.lastCall().strkey, M_ADDR);
    }

    function test_a_contract_destination_needs_no_special_handling() public {
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.destination.strkey = C_ADDR;
        vm.prank(alice);
        router.bridgeOut(request);
        assertEq(cctpRail.lastCall().strkey, C_ADDR);
    }

    function test_a_paused_router_sends_nothing() public {
        vm.prank(guardian);
        router.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_a_paused_route_is_refused_while_other_routes_work() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RouteIsPaused.selector, RouteKind.Cctp));
        router.bridgeOut(_usdcRequest(1000e6));

        // Other routes remain functional
        vm.prank(alice);
        uint64 nonce = router.bridgeOut(_itsRequest(1000e6));
        assertEq(nonce, 1);
    }

    function test_a_rail_that_reverts_takes_the_whole_transfer_with_it() public {
        cctpRail.setDispatchReverts(true);
        vm.prank(alice);
        vm.expectRevert(MockRailAdapter.Rejected.selector);
        router.bridgeOut(_usdcRequest(1000e6));

        assertEq(usdc.balanceOf(treasury), 0, "the fee was not kept");
        assertEq(usdc.balanceOf(alice), 10_000_000e6, "and nothing left the sender");
    }

    // -------------------------------------------------------------------------------------
    // Flow limits
    // -------------------------------------------------------------------------------------

    function test_the_flow_limit_is_charged_against_what_crosses() public {
        uint256 before = router.flowAvailable(address(usdc), RouteKind.Cctp);
        assertEq(before, FLOW_LIMIT);

        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));

        // The fee never leaves this chain, so it is not exposure and does not count.
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), FLOW_LIMIT - 999e6);
    }

    function test_a_transfer_past_the_limit_is_refused_with_the_headroom_named() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, 999e6, 500e6));
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_each_rail_keeps_its_own_ceiling() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 500e6);

        vm.prank(alice);
        router.bridgeOut(_itsRequest(1000e6));

        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), 500e6, "untouched");
        assertEq(
            router.flowAvailable(address(usdc), RouteKind.AxelarIts),
            FLOW_LIMIT - 999e6,
            "and the one that moved has its own counter"
        );
    }

    function test_the_window_refills_the_allowance() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 1000e6);

        vm.prank(alice);
        router.bridgeOut(_usdcRequest(1000e6));
        assertLt(router.flowAvailable(address(usdc), RouteKind.Cctp), 2e6);

        vm.warp(block.timestamp + FLOW_WINDOW * 2);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), 1000e6);
    }

    // -------------------------------------------------------------------------------------
    // Native currency
    // -------------------------------------------------------------------------------------

    function test_destination_gas_reaches_the_rail() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.bridgeOut{value: 0.5 ether}(_usdcRequest(1000e6));

        assertEq(cctpRail.lastCall().value, 0.5 ether);
        assertEq(address(cctpRail).balance, 0.5 ether);
        assertEq(alice.balance, 0.5 ether);
    }

    function test_whatever_the_rail_hands_back_goes_to_the_sender() public {
        cctpRail.setRefund(0.2 ether);
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        router.bridgeOut{value: 0.5 ether}(_usdcRequest(1000e6));

        assertEq(alice.balance, 0.7 ether, "the change came back");
        assertEq(address(router).balance, 0, "and the router kept none of it");
    }

    function test_a_sender_who_cannot_take_change_is_refused_rather_than_charged() public {
        // Keeping it quietly would be a second fee nobody agreed to, and one that moves with a
        // gas market the sender never looked at.
        RefundRefuser refuser = new RefundRefuser();
        usdc.mint(address(refuser), 10_000e6);
        refuser.approve(address(usdc), address(router), type(uint256).max);
        cctpRail.setRefund(0.1 ether);
        vm.deal(address(this), 1 ether);

        vm.expectRevert(RefundFailed.selector);
        refuser.bridge{value: 0.5 ether}(address(router), _usdcRequest(1000e6), 0.5 ether);
    }

    function test_a_sender_who_cannot_take_change_is_fine_when_there_is_none() public {
        RefundRefuser refuser = new RefundRefuser();
        usdc.mint(address(refuser), 10_000e6);
        refuser.approve(address(usdc), address(router), type(uint256).max);

        uint64 nonce = refuser.bridge(address(router), _usdcRequest(1000e6), 0);
        assertEq(nonce, 1);
    }

    function test_the_reentrancy_guard_is_live() public {
        ReenteringToken hostile = new ReenteringToken();
        _registerToken(address(hostile), 6, FLOW_LIMIT);
        hostile.mint(alice, 10_000e6);

        OutboundRequest memory request = _usdcRequest(1000e6);
        request.token = address(hostile);
        hostile.arm(address(router), request);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.bridgeOut(request);
    }

    function _itsRequest(uint256 amount) private view returns (OutboundRequest memory request) {
        request = _usdcRequest(amount);
        request.route = RouteKind.AxelarIts;
    }
}
