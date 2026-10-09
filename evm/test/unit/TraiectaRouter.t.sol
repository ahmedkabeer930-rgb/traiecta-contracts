// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RouteIsPaused, Unauthorized} from "../../src/TraiectaErrors.sol";
import {OutboundRequest, QuoteBlocker, RouteKind, RouteQuote} from "../../src/TraiectaTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";
import {Fixture} from "../Fixture.sol";

/// @title Granular per-route emergency pause and unpause
/// @notice Verifies guardian and admin permissions, state transitions, event emissions,
/// outbound route blocking, and quoting behavior for individual routes.
contract HyperionRouterTest is Fixture {
    function test_guardian_can_pause_and_unpause_individual_routes() public {
        assertFalse(router.routePaused(RouteKind.Cctp));
        assertFalse(router.routePaused(RouteKind.AxelarIts));

        // Guardian pauses CCTP
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RoutePaused(RouteKind.Cctp, guardian);
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        assertTrue(router.routePaused(RouteKind.Cctp));
        assertFalse(router.routePaused(RouteKind.AxelarIts), "other rails remain unpaused");

        // Guardian unpauses CCTP
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RouteUnpaused(RouteKind.Cctp, guardian);
        vm.prank(guardian);
        router.unpauseRoute(RouteKind.Cctp);

        assertFalse(router.routePaused(RouteKind.Cctp));
    }

    function test_admin_can_pause_and_unpause_individual_routes() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RoutePaused(RouteKind.AxelarIts, admin);
        vm.prank(admin);
        router.pauseRoute(RouteKind.AxelarIts);

        assertTrue(router.routePaused(RouteKind.AxelarIts));

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RouteUnpaused(RouteKind.AxelarIts, admin);
        vm.prank(admin);
        router.unpauseRoute(RouteKind.AxelarIts);

        assertFalse(router.routePaused(RouteKind.AxelarIts));
    }

    function test_stranger_cannot_pause_or_unpause_routes() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.unpauseRoute(RouteKind.Cctp);
    }

    function test_bridgeOut_reverts_with_custom_error_when_route_is_paused() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RouteIsPaused.selector, RouteKind.Cctp));
        router.bridgeOut(_usdcRequest(1000e6));
    }

    function test_bridgeOut_succeeds_on_unpaused_route_while_another_is_paused() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        // AxelarIts remains unpaused and can process transfers
        OutboundRequest memory request = _usdcRequest(1000e6);
        request.route = RouteKind.AxelarIts;

        vm.prank(alice);
        uint64 nonce = router.bridgeOut(request);
        assertEq(nonce, 1);
    }

    function test_quote_marks_paused_route_as_unavailable() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        RouteQuote memory q = router.quote(RouteKind.Cctp, address(usdc), 1000e6, _dest(G_ADDR), 7);
        assertFalse(q.available);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.Paused));

        // Unpause restores availability
        vm.prank(guardian);
        router.unpauseRoute(RouteKind.Cctp);

        RouteQuote memory restored = router.quote(RouteKind.Cctp, address(usdc), 1000e6, _dest(G_ADDR), 7);
        assertTrue(restored.available);
        assertEq(uint8(restored.reason), uint8(QuoteBlocker.None));
    }

    function test_quoteAll_marks_paused_route_as_unavailable_while_others_remain_available() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        RouteQuote[] memory quotes = router.quoteAll(address(usdc), 1000e6, _dest(G_ADDR), 7);
        assertFalse(quotes[0].available);
        assertEq(uint8(quotes[0].reason), uint8(QuoteBlocker.Paused));
        assertTrue(quotes[1].available, "AxelarIts is available");
    }
}
