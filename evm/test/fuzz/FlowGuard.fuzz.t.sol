// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {FlowLimitExceeded, InvalidWindow} from "../../src/TraiectaErrors.sol";
import {FlowWindow} from "../../src/libraries/FlowGuard.sol";
import {FlowGuardHarness} from "../harness/LibHarness.sol";

/// @title The rate limiter, against every clock reading rather than the tidy ones
/// @notice A ceiling is only worth having if it holds at the awkward second. The awkward second
/// for a rate limiter is the boundary, and the whole reason this library slides instead of
/// stepping is that a calendar window leaves a hole there wide enough to walk two full days of
/// allowance through in two seconds.
/// @dev The tests to read first are the boundary pair. Everything else here is bookkeeping that
/// has to add up, but those two are the claim the design is making, and a version of this library
/// that reset on the hour would pass every other test in this file.
contract FlowGuardFuzzTest is Test {
    uint64 internal constant MIN_WINDOW = 1;

    /// @dev A year at the top. Longer than any operator would set, and short enough that the
    /// decay multiply stays far away from the ceiling.
    uint64 internal constant MAX_WINDOW = 365 days;

    /// @dev Limits and spends stay inside a hundred and twenty eight bits. A real one is a token
    /// balance, the arithmetic inside adds two of them together, and leaving that much room above
    /// the largest realistic figure means an arithmetic panic here would be a real finding rather
    /// than a test feeding the library a number that cannot exist.
    uint256 internal constant MAX_LIMIT = type(uint128).max;

    FlowGuardHarness internal flow;

    function setUp() public {
        flow = new FlowGuardHarness();
    }

    // -------------------------------------------------------------------------------------
    // The boundary, which is the point of the whole file
    // -------------------------------------------------------------------------------------

    function testFuzz_a_full_allowance_cannot_be_spent_twice_across_a_boundary(
        uint256 limit,
        uint64 window,
        uint64 epoch
    ) public {
        window = uint64(bound(window, 2, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);
        epoch = uint64(bound(epoch, 1, 1_000_000));

        // The last second of one window, then the first second of the next. On a calendar window
        // this is where two full allowances leave in the space of two seconds, and everybody who
        // wants to find that hole will find it.
        uint64 last = epoch * window + (window - 1);
        uint64 next = (epoch + 1) * window;

        flow.consume(limit, limit, last, window);

        assertEq(flow.available(limit, next, window), 0, "the boundary handed out a second allowance");

        vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, 1, 0));
        flow.consume(limit, 1, next, window);
    }

    function testFuzz_the_old_window_drains_instead_of_resetting(
        uint256 limit,
        uint64 window,
        uint64 epoch,
        uint64 offset
    ) public {
        window = uint64(bound(window, 2, MAX_WINDOW));
        limit = bound(limit, 1000, MAX_LIMIT);
        epoch = uint64(bound(epoch, 1, 1_000_000));
        offset = uint64(bound(offset, 0, uint256(window) - 1));

        flow.consume(limit, limit, epoch * window, window);
        uint256 free = flow.available(limit, (epoch + 1) * window + offset, window);

        // How much is free is how far into the new window the clock has run, give or take the one
        // unit integer division rounds off in the sender's favour. Proportional, not stepped: a
        // calendar window would have handed the entire limit back at offset zero.
        uint256 elapsedShare = (limit * offset) / window;
        assertGe(free, elapsedShare, "less came back than the clock had earned");
        assertLe(free, elapsedShare + 1, "more came back than the clock had earned");
    }

    // -------------------------------------------------------------------------------------
    // The ceiling itself
    // -------------------------------------------------------------------------------------

    function testFuzz_a_spend_over_the_ceiling_is_always_refused(
        uint256 limit,
        uint256 first,
        uint256 second,
        uint64 timestamp,
        uint64 window
    ) public {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);
        first = bound(first, 0, limit);
        second = bound(second, 0, MAX_LIMIT);

        flow.consume(limit, first, timestamp, window);

        if (first + second > limit) {
            // The error carries what was asked for and what was actually left, because an
            // operator reading a refused transfer wants both numbers and neither one can be
            // worked out from the other.
            vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, second, limit - first));
            flow.consume(limit, second, timestamp, window);
            return;
        }

        flow.consume(limit, second, timestamp, window);

        uint256 used = flow.effectiveConsumed(timestamp, window);
        assertEq(used, first + second, "the two spends did not add up");
        assertLe(used, limit, "the ceiling let something through");
    }

    function testFuzz_headroom_and_spend_always_add_up_to_the_limit(
        uint256 limit,
        uint256 spend,
        uint64 timestamp,
        uint64 window
    ) public {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);
        spend = bound(spend, 0, limit);

        flow.consume(limit, spend, timestamp, window);

        assertEq(flow.effectiveConsumed(timestamp, window), spend, "the spend was not counted");
        assertEq(flow.available(limit, timestamp, window), limit - spend, "the books do not balance");
    }

    function testFuzz_spending_the_whole_limit_leaves_nothing(uint256 limit, uint64 timestamp, uint64 window)
        public
    {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);

        flow.consume(limit, limit, timestamp, window);

        assertEq(flow.available(limit, timestamp, window), 0);

        vm.expectRevert(abi.encodeWithSelector(FlowLimitExceeded.selector, 1, 0));
        flow.consume(limit, 1, timestamp, window);
    }

    function testFuzz_headroom_reads_as_nothing_when_a_limit_is_cut_below_it(
        uint256 limit,
        uint256 lowered,
        uint64 timestamp,
        uint64 window
    ) public {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 2, MAX_LIMIT);

        flow.consume(limit, limit, timestamp, window);
        lowered = bound(lowered, 0, limit - 1);

        // An operator tightening a limit mid window is a normal thing to do, and it leaves more
        // already spent than the new ceiling allows. That has to read as no headroom rather than
        // as a subtraction going the wrong way.
        assertEq(flow.available(lowered, timestamp, window), 0, "a tightened limit underflowed");
    }

    // -------------------------------------------------------------------------------------
    // The clock
    // -------------------------------------------------------------------------------------

    function testFuzz_a_window_of_zero_is_always_refused(uint64 timestamp) public {
        // Division by it, so it cannot be allowed to reach the divide. Named rather than left to
        // a panic, because an operator who typed a zero deserves to be told which field.
        vm.expectRevert(InvalidWindow.selector);
        flow.epochOf(timestamp, 0);

        vm.expectRevert(InvalidWindow.selector);
        flow.available(1, timestamp, 0);
    }

    function testFuzz_an_epoch_is_only_a_division(uint64 timestamp, uint64 window) public view {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));

        // Thin on its own. It is here because every boundary in this file is defined by this one
        // division, so an off by one here would move all of them at once.
        assertEq(flow.epochOf(timestamp, window), timestamp / window);
    }

    function testFuzz_headroom_only_grows_while_nothing_is_spent(
        uint256 limit,
        uint256 spend,
        uint64 timestamp,
        uint64 later,
        uint64 window
    ) public {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);
        spend = bound(spend, 0, limit);
        timestamp = uint64(bound(timestamp, 0, type(uint64).max / 2));
        later = uint64(bound(later, timestamp, type(uint64).max));

        flow.consume(limit, spend, timestamp, window);

        // Waiting can only ever help. Anything else would mean a transfer that is refused now and
        // refused harder in an hour, with nothing in between to explain it.
        assertGe(
            flow.available(limit, later, window),
            flow.available(limit, timestamp, window),
            "waiting made less room rather than more"
        );
    }

    function testFuzz_two_quiet_windows_forget_everything(
        uint256 limit,
        uint256 spend,
        uint64 timestamp,
        uint64 window
    ) public {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        limit = bound(limit, 1, MAX_LIMIT);
        spend = bound(spend, 0, limit);
        timestamp = uint64(bound(timestamp, 0, type(uint64).max - 3 * MAX_WINDOW));

        flow.consume(limit, spend, timestamp, window);
        uint64 later = timestamp + 2 * window;

        assertEq(flow.effectiveConsumed(later, window), 0, "something survived two empty windows");
        assertEq(flow.available(limit, later, window), limit, "the limit did not come back");

        FlowWindow memory rolled = flow.rollForward(later, window);
        assertEq(rolled.epoch, flow.epochOf(later, window), "rolled to the wrong window");
        assertEq(rolled.consumed, 0);
        assertEq(rolled.prevConsumed, 0, "kept a tail there was nothing to decay from");
    }

    function testFuzz_one_quiet_window_keeps_exactly_one_tail(uint256 spend, uint64 timestamp, uint64 window)
        public
    {
        window = uint64(bound(window, MIN_WINDOW, MAX_WINDOW));
        spend = bound(spend, 0, MAX_LIMIT);
        timestamp = uint64(bound(timestamp, 0, type(uint64).max - 2 * MAX_WINDOW));

        flow.consume(MAX_LIMIT, spend, timestamp, window);
        uint64 later = timestamp + window;

        FlowWindow memory rolled = flow.rollForward(later, window);
        assertEq(rolled.epoch, flow.epochOf(later, window), "rolled to the wrong window");
        assertEq(rolled.consumed, 0, "the new window did not start empty");
        assertEq(rolled.prevConsumed, spend, "the tail is not what was actually spent");
    }

    function testFuzz_rolling_forward_inside_a_window_changes_nothing(
        uint256 spend,
        uint64 timestamp,
        uint64 offset,
        uint64 window
    ) public {
        window = uint64(bound(window, 2, MAX_WINDOW));
        spend = bound(spend, 0, MAX_LIMIT);
        timestamp = uint64(bound(timestamp, 0, type(uint64).max - 2 * MAX_WINDOW));

        // Somewhere else inside the same window, which is to say the epoch division has to land
        // on the same answer for both readings.
        uint64 later = timestamp - (timestamp % window) + uint64(bound(offset, 0, uint256(window) - 1));

        flow.consume(MAX_LIMIT, spend, timestamp, window);
        FlowWindow memory before = flow.state();
        FlowWindow memory rolled = flow.rollForward(later, window);

        assertEq(rolled.epoch, before.epoch);
        assertEq(rolled.consumed, before.consumed, "a roll inside one window moved the counter");
        assertEq(rolled.prevConsumed, before.prevConsumed, "a roll inside one window moved the tail");
    }
}
