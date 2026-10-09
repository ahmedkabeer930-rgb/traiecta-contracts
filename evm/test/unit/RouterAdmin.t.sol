// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "openzeppelin/access/IAccessControl.sol";
import {Pausable} from "openzeppelin/utils/Pausable.sol";

import {
    ActionFieldNotEmpty,
    FeeTooHigh,
    InvalidDecimals,
    InvalidLimit,
    InvalidWindow,
    LimitNotRaised,
    TimelockAlreadyExecuted,
    TimelockDelayOutOfRange,
    TimelockExpired,
    TimelockNotQueued,
    TimelockNotReady,
    TokenNotRegistered,
    Unauthorized,
    ZeroAddress
} from "../../src/TraiectaErrors.sol";
import {HyperionRouter} from "../../src/TraiectaRouter.sol";
import {ActionKind, AdminAction, QueuedAction, RouteKind, TokenConfig} from "../../src/TraiectaTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/ITraiectaRouter.sol";
import {Fixture} from "../Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title Who may change what, and how long they have to wait
/// @notice The timelock, the guardian, the field validation, and the two overrides that stop
/// `AccessControl` handing out roles behind the clock's back.
/// @dev A timelock is worth exactly as much as the smallest hole in it. So most of this file is
/// about holes: a role granted directly, a field carrying a value nothing reads, an action
/// executed twice, an action that matured in March and got run in November, a limit raise
/// measured against a ceiling that moved while it waited.
contract RouterAdminTest is Fixture {
    // -------------------------------------------------------------------------------------
    // Deployment
    // -------------------------------------------------------------------------------------

    function test_the_constructor_wrote_down_what_it_was_given() public view {
        assertEq(router.treasury(), treasury);
        assertEq(router.feeBps(), FEE_BPS);
        assertEq(router.timelockDelay(), TIMELOCK);
        assertEq(router.flowWindow(), FLOW_WINDOW);
        assertTrue(router.hasRole(adminRole, admin));
        assertTrue(router.hasRole(guardianRole, guardian));
        assertEq(router.outboundNonce(), 0);
    }

    function test_a_deployment_needs_an_admin_and_a_treasury() public {
        vm.expectRevert(ZeroAddress.selector);
        new HyperionRouter(address(0), guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);

        vm.expectRevert(ZeroAddress.selector);
        new HyperionRouter(admin, guardian, address(0), FEE_BPS, TIMELOCK, FLOW_WINDOW);
    }

    function test_a_deployment_can_skip_the_guardian() public {
        // Not everybody wants a second key on day one, and a zero address here means nobody
        // holds the role rather than everybody holding it.
        HyperionRouter bare = new HyperionRouter(admin, address(0), treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);
        assertFalse(bare.hasRole(bare.GUARDIAN_ROLE(), address(0)));
    }

    function test_a_deployment_cannot_start_outside_the_bounds() public {
        vm.expectRevert(FeeTooHigh.selector);
        new HyperionRouter(admin, guardian, treasury, 101, TIMELOCK, FLOW_WINDOW);

        vm.expectRevert(TimelockDelayOutOfRange.selector);
        new HyperionRouter(admin, guardian, treasury, FEE_BPS, 1 hours - 1, FLOW_WINDOW);

        vm.expectRevert(TimelockDelayOutOfRange.selector);
        new HyperionRouter(admin, guardian, treasury, FEE_BPS, 30 days + 1, FLOW_WINDOW);

        vm.expectRevert(InvalidWindow.selector);
        new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, 5 minutes - 1);

        vm.expectRevert(InvalidWindow.selector);
        new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, 7 days + 1);
    }

    function test_the_fee_cap_is_one_percent_and_no_path_raises_it() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 101;
        vm.prank(admin);
        vm.expectRevert(FeeTooHigh.selector);
        router.queueAction(action);

        // And the boundary itself is allowed, so the cap is a cap and not an off by one.
        _setFeeBps(100);
        assertEq(router.feeBps(), 100);
    }

    // -------------------------------------------------------------------------------------
    // Only an admin queues, only an admin executes
    // -------------------------------------------------------------------------------------

    function test_a_stranger_cannot_queue_anything() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole
            )
        );
        router.queueAction(action);
    }

    function test_the_guardian_cannot_queue_anything_either() public {
        // The guardian's whole design is that every power it holds makes the bridge do less.
        // Queueing a change is not one of those.
        AdminAction memory action = _empty(ActionKind.SetTreasury);
        action.subject = stranger;

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole
            )
        );
        router.queueAction(action);
    }

    function test_a_stranger_cannot_execute_a_matured_action() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole
            )
        );
        router.executeAction(id);
    }

    // -------------------------------------------------------------------------------------
    // The clock
    // -------------------------------------------------------------------------------------

    function test_a_queued_action_records_its_own_deadline() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;

        uint64 queuedAt = uint64(block.timestamp);
        uint64 eta = queuedAt + TIMELOCK;
        uint64 expected = router.actionCount() + 1;

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ActionQueued(expected, ActionKind.SetFeeBps, eta, eta + 7 days);
        vm.prank(admin);
        uint64 id = router.queueAction(action);

        QueuedAction memory queued = router.queuedAction(id);
        assertEq(queued.id, expected);
        assertEq(queued.queuedAt, queuedAt);
        assertEq(queued.eta, eta);
        assertEq(queued.expiresAt, eta + 7 days);
        assertFalse(queued.executed);
        assertEq(uint8(queued.action.kind), uint8(ActionKind.SetFeeBps));
        assertEq(queued.action.amount, 20);
        assertEq(router.actionCount(), expected);
    }

    function test_an_action_cannot_be_executed_early() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        uint64 eta = router.queuedAction(id).eta;

        vm.warp(eta - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockNotReady.selector, eta));
        router.executeAction(id);

        // And the very second it matures, it goes through.
        vm.warp(eta);
        vm.prank(admin);
        router.executeAction(id);
        assertEq(router.feeBps(), 20);
    }

    function test_an_action_nobody_ran_stops_being_runnable() public {
        // Seven days after it matures. A change approved in March and executed in November is a
        // change nobody reviewed.
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        uint64 expiresAt = router.queuedAction(id).expiresAt;

        vm.warp(expiresAt + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockExpired.selector, expiresAt));
        router.executeAction(id);

        assertEq(router.feeBps(), FEE_BPS, "nothing happened");
    }

    function test_the_last_second_of_the_grace_period_still_works() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);

        vm.warp(router.queuedAction(id).expiresAt);
        vm.prank(admin);
        router.executeAction(id);
        assertEq(router.feeBps(), 20);
    }

    function test_an_action_runs_once() public {
        AdminAction memory action = _empty(ActionKind.RaiseTokenFlowLimit);
        action.subject = address(usdc);
        action.amount = FLOW_LIMIT * 2;

        vm.prank(admin);
        uint64 id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.startPrank(admin);
        router.executeAction(id);
        vm.expectRevert(TimelockAlreadyExecuted.selector);
        router.executeAction(id);
        vm.stopPrank();
    }

    function test_an_action_that_was_never_queued_cannot_be_executed() public {
        vm.startPrank(admin);
        vm.expectRevert(TimelockNotQueued.selector);
        router.executeAction(999);
        vm.expectRevert(TimelockNotQueued.selector);
        router.executeAction(0);
        vm.stopPrank();
    }

    function test_executing_says_so_in_the_log() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ActionExecuted(id, ActionKind.SetFeeBps);
        vm.prank(admin);
        router.executeAction(id);
    }

    function test_an_action_is_checked_again_on_the_way_out() public {
        // The reason this matters: a flow limit raise is validated against the ceiling at queue
        // time, and the guardian can lower that ceiling while the action waits. Without the
        // second check, a raise queued against a limit of a million would still land after the
        // guardian had cut it to nothing during an incident.
        AdminAction memory action = _empty(ActionKind.RaiseTokenFlowLimit);
        action.subject = address(usdc);
        action.amount = FLOW_LIMIT + 1;

        vm.prank(admin);
        uint64 id = router.queueAction(action);

        // Somebody raises it higher by another route while this one waits.
        AdminAction memory bigger = _empty(ActionKind.RaiseTokenFlowLimit);
        bigger.subject = address(usdc);
        bigger.amount = FLOW_LIMIT * 10;
        _run(bigger);

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(admin);
        vm.expectRevert(LimitNotRaised.selector);
        router.executeAction(id);
    }

    // -------------------------------------------------------------------------------------
    // Cancelling
    // -------------------------------------------------------------------------------------

    function test_the_guardian_can_cancel_a_queued_change() public {
        AdminAction memory action = _empty(ActionKind.SetTreasury);
        action.subject = stranger;
        vm.prank(admin);
        uint64 id = router.queueAction(action);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ActionCancelled(id, guardian);
        vm.prank(guardian);
        router.cancelAction(id);

        assertEq(router.queuedAction(id).id, 0, "the slot is gone");

        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(admin);
        vm.expectRevert(TimelockNotQueued.selector);
        router.executeAction(id);
        assertEq(router.treasury(), treasury);
    }

    function test_the_admin_can_cancel_too() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);

        vm.prank(admin);
        router.cancelAction(id);
        assertEq(router.queuedAction(id).id, 0);
    }

    function test_a_stranger_cannot_cancel() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.cancelAction(id);
    }

    function test_cancelling_nothing_is_refused() public {
        vm.prank(guardian);
        vm.expectRevert(TimelockNotQueued.selector);
        router.cancelAction(999);
    }

    function test_a_change_that_already_landed_cannot_be_cancelled() public {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(admin);
        router.executeAction(id);

        vm.prank(guardian);
        vm.expectRevert(TimelockAlreadyExecuted.selector);
        router.cancelAction(id);
    }

    // -------------------------------------------------------------------------------------
    // Field validation
    // -------------------------------------------------------------------------------------

    function test_a_field_the_kind_does_not_use_has_to_be_empty() public {
        // Four separate refusals, one per field, because the whole point of a flat action struct
        // is that a reviewer reading a pending change sees everything it will do.
        vm.startPrank(admin);

        AdminAction memory withRoute = _empty(ActionKind.SetFeeBps);
        withRoute.route = RouteKind.Allbridge;
        withRoute.amount = 20;
        vm.expectRevert(ActionFieldNotEmpty.selector);
        router.queueAction(withRoute);

        AdminAction memory withSubject = _empty(ActionKind.SetFeeBps);
        withSubject.subject = stranger;
        withSubject.amount = 20;
        vm.expectRevert(ActionFieldNotEmpty.selector);
        router.queueAction(withSubject);

        AdminAction memory withAmount = _empty(ActionKind.SetTreasury);
        withAmount.subject = stranger;
        withAmount.amount = 1;
        vm.expectRevert(ActionFieldNotEmpty.selector);
        router.queueAction(withAmount);

        AdminAction memory withDecimals = _empty(ActionKind.SetFeeBps);
        withDecimals.amount = 20;
        withDecimals.decimals = 6;
        vm.expectRevert(ActionFieldNotEmpty.selector);
        router.queueAction(withDecimals);

        vm.stopPrank();
    }

    function test_a_kind_that_needs_an_address_will_not_take_the_zero_one() public {
        vm.startPrank(admin);
        vm.expectRevert(ZeroAddress.selector);
        router.queueAction(_empty(ActionKind.SetTreasury));
        vm.expectRevert(ZeroAddress.selector);
        router.queueAction(_empty(ActionKind.SetAdmin));
        vm.expectRevert(ZeroAddress.selector);
        router.queueAction(_empty(ActionKind.SetGuardian));
        vm.expectRevert(ZeroAddress.selector);
        router.queueAction(_empty(ActionKind.SetAdapter));
        vm.stopPrank();
    }

    function test_enabling_a_route_takes_a_boolean_not_a_number() public {
        AdminAction memory action = _empty(ActionKind.EnableRoute);
        action.amount = 2;
        vm.prank(admin);
        vm.expectRevert(InvalidLimit.selector);
        router.queueAction(action);
    }

    function test_a_token_cannot_be_registered_with_impossible_decimals() public {
        AdminAction memory action = _empty(ActionKind.RegisterToken);
        action.subject = address(usdc);
        action.amount = FLOW_LIMIT;
        action.decimals = 39;
        vm.prank(admin);
        vm.expectRevert(InvalidDecimals.selector);
        router.queueAction(action);
    }

    function test_a_flow_limit_raise_has_to_actually_raise_it() public {
        AdminAction memory action = _empty(ActionKind.RaiseTokenFlowLimit);
        action.subject = address(usdc);
        action.amount = FLOW_LIMIT;

        vm.prank(admin);
        vm.expectRevert(LimitNotRaised.selector);
        router.queueAction(action);
    }

    function test_a_flow_limit_raise_needs_a_registered_token() public {
        AdminAction memory action = _empty(ActionKind.RaiseTokenFlowLimit);
        action.subject = stranger;
        action.amount = 1;

        vm.prank(admin);
        vm.expectRevert(TokenNotRegistered.selector);
        router.queueAction(action);
    }

    function test_retiring_an_unregistered_token_is_refused() public {
        AdminAction memory action = _empty(ActionKind.SetTokenEnabled);
        action.subject = stranger;
        action.amount = 0;

        vm.prank(admin);
        vm.expectRevert(TokenNotRegistered.selector);
        router.queueAction(action);
    }

    function test_the_timelock_delay_stays_inside_its_own_bounds() public {
        vm.startPrank(admin);

        AdminAction memory tooShort = _empty(ActionKind.SetTimelockDelay);
        tooShort.amount = 1 hours - 1;
        vm.expectRevert(TimelockDelayOutOfRange.selector);
        router.queueAction(tooShort);

        AdminAction memory tooLong = _empty(ActionKind.SetTimelockDelay);
        tooLong.amount = 30 days + 1;
        vm.expectRevert(TimelockDelayOutOfRange.selector);
        router.queueAction(tooLong);

        vm.stopPrank();
    }

    function test_the_flow_window_stays_inside_its_own_bounds() public {
        vm.startPrank(admin);

        AdminAction memory tooShort = _empty(ActionKind.SetFlowWindow);
        tooShort.amount = 5 minutes - 1;
        vm.expectRevert(InvalidWindow.selector);
        router.queueAction(tooShort);

        AdminAction memory tooLong = _empty(ActionKind.SetFlowWindow);
        tooLong.amount = 7 days + 1;
        vm.expectRevert(InvalidWindow.selector);
        router.queueAction(tooLong);

        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------
    // What the changes actually do
    // -------------------------------------------------------------------------------------

    function test_the_treasury_can_move() public {
        AdminAction memory action = _empty(ActionKind.SetTreasury);
        action.subject = stranger;
        _run(action);
        assertEq(router.treasury(), stranger);
    }

    function test_a_second_admin_can_be_added_on_the_clock() public {
        AdminAction memory action = _empty(ActionKind.SetAdmin);
        action.subject = alice;
        _run(action);
        assertTrue(router.hasRole(adminRole, alice));
        assertTrue(router.hasRole(adminRole, admin), "and the first one stays");
    }

    function test_a_second_guardian_can_be_added_on_the_clock() public {
        AdminAction memory action = _empty(ActionKind.SetGuardian);
        action.subject = alice;
        _run(action);
        assertTrue(router.hasRole(guardianRole, alice));

        vm.prank(alice);
        router.pause();
        assertTrue(router.paused());
    }

    function test_an_adapter_can_be_repointed() public {
        AdminAction memory action = _empty(ActionKind.SetAdapter);
        action.route = RouteKind.Cctp;
        action.subject = stranger;
        uint64 id = _mature(action);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.AdapterSet(RouteKind.Cctp, stranger);
        vm.prank(admin);
        router.executeAction(id);

        assertEq(router.adapter(RouteKind.Cctp), stranger);
    }

    function test_a_rail_receiver_can_be_repointed() public {
        AdminAction memory action = _empty(ActionKind.SetRailReceiver);
        action.route = RouteKind.AxelarGmp;
        action.subject = alice;
        uint64 id = _mature(action);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RailReceiverSet(RouteKind.AxelarGmp, alice);
        vm.prank(admin);
        router.executeAction(id);

        assertEq(router.railReceiver(RouteKind.AxelarGmp), alice);
    }

    function test_a_route_can_be_turned_off_and_on() public {
        AdminAction memory action = _empty(ActionKind.EnableRoute);
        action.route = RouteKind.Allbridge;
        action.amount = 0;
        uint64 id = _mature(action);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RouteConfigured(RouteKind.Allbridge, false);
        vm.prank(admin);
        router.executeAction(id);
        assertFalse(router.routeEnabled(RouteKind.Allbridge));

        _enableRoute(RouteKind.Allbridge, true);
        assertTrue(router.routeEnabled(RouteKind.Allbridge));
    }

    function test_registering_a_token_fills_in_the_whole_config() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        _registerToken(address(dai), 18, 5000e18);

        TokenConfig memory cfg = router.tokenConfig(address(dai));
        assertTrue(cfg.registered);
        assertTrue(cfg.enabled, "registering means willing to route it");
        assertEq(cfg.decimals, 18);
        assertEq(cfg.flowLimit, 5000e18);
    }

    function test_a_raised_flow_limit_shows_up_in_what_is_available() public {
        AdminAction memory action = _empty(ActionKind.RaiseTokenFlowLimit);
        action.subject = address(usdc);
        action.amount = FLOW_LIMIT * 3;
        _run(action);

        assertEq(router.tokenConfig(address(usdc)).flowLimit, FLOW_LIMIT * 3);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), FLOW_LIMIT * 3);
    }

    function test_a_per_route_limit_overrides_the_token_one() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Allbridge, 1000e6);

        assertEq(router.flowAvailable(address(usdc), RouteKind.Allbridge), 1000e6);
        assertEq(
            router.flowAvailable(address(usdc), RouteKind.Cctp),
            FLOW_LIMIT,
            "and the other rails are untouched"
        );
    }

    function test_a_per_route_limit_of_zero_is_a_real_limit_not_an_unset_one() public {
        // The pair of mappings behind this exists for exactly this case. A single mapping would
        // read zero as "nobody said" and quietly fall back to the token wide ceiling, which is
        // the opposite of what an operator typing zero meant.
        _setRouteFlowLimit(address(usdc), RouteKind.Allbridge, 0);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Allbridge), 0);
    }

    function test_the_delay_can_be_changed_and_the_new_one_applies_next_time() public {
        AdminAction memory action = _empty(ActionKind.SetTimelockDelay);
        action.amount = 3 days;
        _run(action);
        assertEq(router.timelockDelay(), 3 days);

        AdminAction memory next = _empty(ActionKind.SetFeeBps);
        next.amount = 20;
        vm.prank(admin);
        uint64 id = router.queueAction(next);
        assertEq(router.queuedAction(id).eta, uint64(block.timestamp) + 3 days);
    }

    function test_the_flow_window_can_be_changed() public {
        AdminAction memory action = _empty(ActionKind.SetFlowWindow);
        action.amount = 30 minutes;
        _run(action);
        assertEq(router.flowWindow(), 30 minutes);
    }

    function test_a_config_change_announces_the_whole_config() public {
        // One event carrying all four, so an indexer never has to hold three of them from
        // earlier logs to know what the router looks like now.
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = 25;
        vm.prank(admin);
        uint64 id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.ConfigChanged(treasury, 25, TIMELOCK, FLOW_WINDOW);
        vm.prank(admin);
        router.executeAction(id);
    }

    // -------------------------------------------------------------------------------------
    // The two powers that do not wait
    // -------------------------------------------------------------------------------------

    function test_the_guardian_can_pause_and_cannot_unpause() public {
        // Stopping should be easy and starting again should not, because one of those decisions
        // is reversible and the other is the one made at four in the morning by somebody who
        // wants the alert to go away.
        vm.prank(guardian);
        router.pause();
        assertTrue(router.paused());

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, adminRole
            )
        );
        router.unpause();

        vm.prank(admin);
        router.unpause();
        assertFalse(router.paused());
    }

    function test_the_admin_can_pause_as_well() public {
        vm.prank(admin);
        router.pause();
        assertTrue(router.paused());
    }

    function test_a_stranger_can_do_neither() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.pause();

        vm.prank(guardian);
        router.pause();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole
            )
        );
        router.unpause();
    }

    function test_pausing_twice_is_refused() public {
        vm.startPrank(guardian);
        router.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.pause();
        vm.stopPrank();
    }

    function test_the_guardian_can_pause_and_unpause_a_route() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RoutePaused(RouteKind.Cctp, guardian);
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);
        assertTrue(router.routePaused(RouteKind.Cctp));
        assertFalse(router.routePaused(RouteKind.AxelarIts));

        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.RouteUnpaused(RouteKind.Cctp, guardian);
        vm.prank(guardian);
        router.unpauseRoute(RouteKind.Cctp);
        assertFalse(router.routePaused(RouteKind.Cctp));
    }

    function test_the_admin_can_pause_and_unpause_a_route() public {
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

    function test_a_stranger_cannot_pause_or_unpause_a_route() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.unpauseRoute(RouteKind.Cctp);
    }

    function test_the_guardian_can_tighten_a_flow_limit_without_waiting() public {
        vm.expectEmit(true, true, true, true, address(router));
        emit IHyperionRouter.FlowLimitLowered(address(usdc), guardian, 1000e6);
        vm.prank(guardian);
        router.lowerTokenFlowLimit(address(usdc), 1000e6);

        assertEq(router.tokenConfig(address(usdc)).flowLimit, 1000e6);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), 1000e6);
    }

    function test_the_guardian_can_tighten_a_limit_all_the_way_to_nothing() public {
        vm.prank(guardian);
        router.lowerTokenFlowLimit(address(usdc), 0);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), 0);
    }

    function test_the_emergency_brake_cannot_be_used_to_raise_a_limit() public {
        // Without this, the one power that skips the timelock would be the one that lets an admin
        // raise a ceiling instantly, and the clock would be decorative.
        vm.startPrank(guardian);
        vm.expectRevert(LimitNotRaised.selector);
        router.lowerTokenFlowLimit(address(usdc), FLOW_LIMIT + 1);
        vm.expectRevert(LimitNotRaised.selector);
        router.lowerTokenFlowLimit(address(usdc), FLOW_LIMIT);
        vm.stopPrank();
    }

    function test_tightening_a_limit_needs_a_registered_token() public {
        vm.prank(guardian);
        vm.expectRevert(TokenNotRegistered.selector);
        router.lowerTokenFlowLimit(stranger, 1);
    }

    function test_a_stranger_cannot_tighten_a_limit() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.lowerTokenFlowLimit(address(usdc), 1);
    }

    // -------------------------------------------------------------------------------------
    // The two overrides
    // -------------------------------------------------------------------------------------

    function test_roles_cannot_be_handed_out_directly() public {
        // `AccessControl` as it comes would leave an admin able to grant a second admin in one
        // transaction, and a timelock somebody can walk around is a comment rather than a control.
        vm.startPrank(admin);
        vm.expectRevert(Unauthorized.selector);
        router.grantRole(adminRole, stranger);
        vm.expectRevert(Unauthorized.selector);
        router.grantRole(guardianRole, stranger);
        vm.stopPrank();
    }

    function test_roles_cannot_be_taken_away_directly_either() public {
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector);
        router.revokeRole(guardianRole, guardian);
        assertTrue(router.hasRole(guardianRole, guardian));
    }

    function test_the_overrides_refuse_a_stranger_too() public {
        // Same revert either way, on purpose. The function does not exist as far as anybody is
        // concerned, so there is nothing for a caller to learn from which error came back.
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        router.grantRole(adminRole, stranger);
    }

    function test_renouncing_a_role_still_works() public {
        // Not overridden, and should not be. Giving up a key you hold is not a privilege
        // escalation, and an operator rotating away from a compromised guardian key needs it.
        vm.prank(guardian);
        router.renounceRole(guardianRole, guardian);
        assertFalse(router.hasRole(guardianRole, guardian));
    }
}
