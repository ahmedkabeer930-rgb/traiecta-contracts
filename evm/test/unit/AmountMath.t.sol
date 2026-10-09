// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    AmountNotRepresentable,
    DecimalOverflow,
    FeeTooHigh,
    InvalidAmount,
    InvalidDecimals
} from "../../src/TraiectaErrors.sol";
import {AmountMathHarness} from "../harness/LibHarness.sol";

/// @title The arithmetic everything else rests on
/// @notice Decimals, dust, and the fee split.
/// @dev The bug this file exists to catch is not a revert, it is a factor of ten. USDC has six
/// decimals on every EVM chain and seven on Stellar, so every single transfer crosses a decimal
/// boundary, and an off by one exponent delivers ten times too much or a tenth of what somebody
/// asked for. Neither of those reverts anywhere. They just arrive.
contract AmountMathTest is Test {
    AmountMathHarness internal math;

    function setUp() public {
        math = new AmountMathHarness();
    }

    // -------------------------------------------------------------------------------------
    // pow10
    // -------------------------------------------------------------------------------------

    function test_pow10_matches_exponentiation() public view {
        assertEq(math.pow10(0), 1);
        assertEq(math.pow10(6), 1e6);
        assertEq(math.pow10(7), 1e7);
        assertEq(math.pow10(18), 1e18);
        assertEq(math.pow10(38), 1e38);
    }

    function test_pow10_refuses_to_saturate() public {
        vm.expectRevert(DecimalOverflow.selector);
        math.pow10(39);
    }

    // -------------------------------------------------------------------------------------
    // convertDecimals
    // -------------------------------------------------------------------------------------

    function test_six_to_seven_is_the_stellar_direction() public view {
        (uint256 converted, uint256 dust) = math.convertDecimals(1000e6, 6, 7);
        assertEq(converted, 1000e7);
        assertEq(dust, 0);
    }

    function test_seven_to_six_leaves_the_last_digit_behind() public view {
        (uint256 converted, uint256 dust) = math.convertDecimals(12_345_678, 7, 6);
        assertEq(converted, 1_234_567);
        assertEq(dust, 8);
    }

    function test_equal_decimals_are_a_passthrough() public view {
        (uint256 converted, uint256 dust) = math.convertDecimals(123_456, 6, 6);
        assertEq(converted, 123_456);
        assertEq(dust, 0);
    }

    function test_conversion_that_would_wrap_is_named_rather_than_panicking() public {
        vm.expectRevert(DecimalOverflow.selector);
        math.convertDecimals(type(uint256).max, 6, 7);
    }

    function test_decimals_past_the_ceiling_are_refused_on_either_side() public {
        vm.expectRevert(InvalidDecimals.selector);
        math.convertDecimals(1, 39, 6);

        vm.expectRevert(InvalidDecimals.selector);
        math.convertDecimals(1, 6, 39);
    }

    function test_exact_conversion_refuses_to_drop_a_tail() public {
        vm.expectRevert(AmountNotRepresentable.selector);
        math.convertDecimalsExact(12_345_678, 7, 6);
    }

    function test_exact_conversion_is_happy_when_nothing_is_lost() public view {
        assertEq(math.convertDecimalsExact(12_345_670, 7, 6), 1_234_567);
    }

    // -------------------------------------------------------------------------------------
    // floorToRepresentable
    // -------------------------------------------------------------------------------------

    function test_flooring_rounds_down_to_what_survives_the_trip() public view {
        assertEq(math.floorToRepresentable(12_345_678, 7, 6), 12_345_670);
        assertEq(math.floorToRepresentable(9, 7, 6), 0);
    }

    function test_flooring_upward_changes_nothing() public view {
        assertEq(math.floorToRepresentable(12_345_678, 6, 7), 12_345_678);
        assertEq(math.floorToRepresentable(12_345_678, 6, 6), 12_345_678);
    }

    function test_an_eighteen_decimal_token_into_six_is_a_wide_floor() public view {
        // A wei sized remainder on an eighteen decimal token cannot cross into six decimals at
        // all, and this is the case that turns "send my whole balance" into a refused transfer
        // unless the caller floors first.
        assertEq(math.floorToRepresentable(1e18 + 999_999_999_999, 18, 6), 1e18);
    }

    // -------------------------------------------------------------------------------------
    // applyFee
    // -------------------------------------------------------------------------------------

    function test_the_fee_split_returns_net_first() public view {
        // Transposing these two would charge a ninety nine point nine percent fee and still
        // compile, which is exactly why the order is asserted rather than assumed.
        (uint256 net, uint256 fee) = math.applyFee(1000e6, 10);
        assertEq(net, 999e6);
        assertEq(fee, 1e6);
        assertGt(net, fee);
    }

    function test_a_zero_fee_hands_everything_over() public view {
        (uint256 net, uint256 fee) = math.applyFee(1000e6, 0);
        assertEq(net, 1000e6);
        assertEq(fee, 0);
    }

    function test_the_fee_ceiling_is_one_percent() public view {
        (uint256 net, uint256 fee) = math.applyFee(1000e6, 100);
        assertEq(fee, 10e6);
        assertEq(net, 990e6);
    }

    function test_a_fee_past_the_ceiling_is_refused() public {
        vm.expectRevert(FeeTooHigh.selector);
        math.applyFee(1000e6, 101);
    }

    function test_nothing_is_not_an_amount() public {
        vm.expectRevert(InvalidAmount.selector);
        math.applyFee(0, 10);
    }

    function test_a_dust_amount_pays_no_fee_rather_than_vanishing() public view {
        // One unit at ten basis points rounds the fee to zero. The alternative would be taking
        // the whole thing, which is a fee of one hundred percent on the smallest transfer.
        (uint256 net, uint256 fee) = math.applyFee(1, 10);
        assertEq(net, 1);
        assertEq(fee, 0);
    }
}
