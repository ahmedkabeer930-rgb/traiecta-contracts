// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlowLimitExceeded, InvalidWindow} from "../../src/TraiectaErrors.sol";
import {FlowWindow} from "../../src/libraries/FlowGuard.sol";
import {FlowGuardHarness} from "../harness/LibHarness.sol";

/// @title The limit that slides
/// @notice Proves the boundary is not a hole.
/// @dev The test that matters here is `test_the_boundary_is_not_a_free_refill`. A fixed calendar
/// window lets somebody spend the whole allowance at 10:59 and the whole allowance again at
/// 11:00, which is two windows of exposure in two minutes and the reason this library is not
/// four lines long.
contract FlowGuardTest is Test {
    uint64 internal constant WINDOW = 3600;
    uint256 internal constant LIMIT = 1000e6;

    FlowGuardHarness internal flow;

    function setUp() public {
        flow = new FlowGuardHarness();
    }

    function test_the_epoch_is_the_timestamp_over_the_window() public view {
        assertEq(flow.epochOf(0, WINDOW), 0);
        assertEq(flow.epochOf(WINDOW - 1, WINDOW), 0);
        assertEq(flow.epochOf(WINDOW, WINDOW), 1);
        assertEq(flow.epochOf(WINDOW * 5 + 17, WINDOW), 5);
    }

    function test_a_zero_length_window_is_not_a_window() public {
        vm.expectRevert(InvalidWindow.selector);
        flow.epochOf(1, 0);
    }

    function test_a_fresh_record_has_the_whole_limit() public view {
        assertEq(flow.available(LIMIT, 0, WINDOW), LIMIT);
        assertEq(flow.effectiveConsumed(0, WINDOW), 0);
    }

    function test_spending_inside_one_window_adds_up() public {
        flow.consume(LIMIT, 400e6, WINDOW, WINDOW);
        flow.consume(LIMIT, 100e6, WINDOW + 30, WINDOW);
        assertEq(flow.effectiveConsumed(WINDOW + 60, WINDOW), 500e6);
        assertEq(flow.available(LIMIT, WINDOW + 60, WINDOW), 500e6);
    }

    function test_going_over_is_refused_with_the_headroom_named() public {
        flow.consume(LIMIT, 900e6, WINDOW, WINDOW);
        vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, 200e6, 100e6));
        flow.consume(LIMIT, 200e6, WINDOW + 1, WINDOW);
    }

    function test_the_boundary_is_not_a_free_refill() public {
        // Fill the window right at the end of it.
        uint64 lateInTheWindow = WINDOW * 10 + (WINDOW - 1);
        flow.consume(LIMIT, LIMIT, lateInTheWindow, WINDOW);

        // One second later a new epoch has started. A calendar window would hand back the entire
        // allowance here. This one hands back one window's worth of a second, which is nothing.
        uint64 justAfter = lateInTheWindow + 1;
        assertEq(flow.available(LIMIT, justAfter, WINDOW), 0);

        vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, 1e6, 0));
        flow.consume(LIMIT, 1e6, justAfter, WINDOW);
    }

    function test_the_old_window_drains_out_in_proportion() public {
        uint64 start = WINDOW * 4;
        flow.consume(LIMIT, LIMIT, start, WINDOW);

        // Halfway through the following window, half the old total still counts.
        uint64 halfway = start + WINDOW + WINDOW / 2;
        assertEq(flow.effectiveConsumed(halfway, WINDOW), LIMIT / 2);
        assertEq(flow.available(LIMIT, halfway, WINDOW), LIMIT / 2);

        // And at the very end of it, essentially none of it does.
        uint64 nearlyGone = start + WINDOW * 2 - 1;
        assertEq(flow.effectiveConsumed(nearlyGone, WINDOW), LIMIT / WINDOW);
    }

    function test_a_gap_of_two_windows_clears_the_slate() public {
        flow.consume(LIMIT, LIMIT, WINDOW, WINDOW);
        uint64 muchLater = WINDOW * 4;
        assertEq(flow.effectiveConsumed(muchLater, WINDOW), 0);
        assertEq(flow.available(LIMIT, muchLater, WINDOW), LIMIT);

        FlowWindow memory rolled = flow.rollForward(muchLater, WINDOW);
        assertEq(rolled.epoch, 4);
        assertEq(rolled.consumed, 0);
        assertEq(rolled.prevConsumed, 0);
    }

    function test_rolling_one_window_forward_keeps_the_tail() public {
        flow.consume(LIMIT, 300e6, WINDOW, WINDOW);
        FlowWindow memory rolled = flow.rollForward(WINDOW * 2, WINDOW);
        assertEq(rolled.epoch, 2);
        assertEq(rolled.consumed, 0);
        assertEq(rolled.prevConsumed, 300e6);
    }

    function test_available_never_goes_below_zero() public {
        flow.consume(LIMIT, LIMIT, WINDOW, WINDOW);
        // A limit lowered underneath a window that is already full would underflow a naive
        // subtraction. Guardians lower limits in a hurry, so this is a real sequence.
        assertEq(flow.available(LIMIT / 2, WINDOW + 1, WINDOW), 0);
    }

    function test_spending_the_whole_limit_exactly_is_allowed() public {
        flow.consume(LIMIT, LIMIT, WINDOW, WINDOW);
        assertEq(flow.available(LIMIT, WINDOW, WINDOW), 0);
    }
}
