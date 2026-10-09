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

/// @title What the arithmetic has to hold for every input, not just the interesting ones
/// @notice The unit file beside this one picks the inputs that are known to be sharp. This one
/// hands the same five functions a few hundred thousand inputs nobody would think to pick.
/// @dev Worth saying why a library this small earns a fuzz file of its own. Every transfer
/// Hyperion routes crosses a decimal boundary, because USDC is six decimals here and seven on
/// Stellar, and the failure mode of getting that wrong is not a revert. It is an arrival.
/// Somebody receives a tenth of what they sent, or ten times it, and nothing anywhere in the
/// stack would have said a word about it.
///
/// So every assertion below is a conservation statement. Not "this returns 1e7", which is a fact
/// about one input, but "what crossed plus what was kept plus what was handed back equals what
/// was paid in", which is a fact about all of them.
contract AmountMathFuzzTest is Test {
    /// @dev Written out here rather than imported from the library, so that raising a ceiling
    /// over there shows up as a failure over here instead of being quietly adopted by the tests
    /// whose job is to police it.
    uint8 internal constant MAX_DECIMALS = 38;
    uint16 internal constant MAX_FEE_BPS = 100;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev The largest amount that survives being scaled by the largest factor the library
    /// allows. Past this the library reverts `DecimalOverflow` on purpose and there is a test
    /// below that says so; bounding the conservation tests keeps them about conservation rather
    /// than about the ceiling.
    uint256 internal constant WIDEST = type(uint256).max / 1e38;

    AmountMathHarness internal math;

    function setUp() public {
        math = new AmountMathHarness();
    }

    // -------------------------------------------------------------------------------------
    // The fee split
    // -------------------------------------------------------------------------------------

    function testFuzz_a_fee_split_hands_back_exactly_what_it_was_given(uint256 amount, uint16 feeBps)
        public
        view
    {
        // The multiply inside is `amount * feeBps`, so this ceiling is the one above which
        // checked arithmetic reverts of its own accord. No token in existence has a supply
        // within thirty orders of magnitude of it.
        amount = bound(amount, 1, type(uint256).max / MAX_FEE_BPS);
        feeBps = uint16(bound(feeBps, 0, MAX_FEE_BPS));

        (uint256 net, uint256 fee) = math.applyFee(amount, feeBps);

        assertEq(net + fee, amount, "the split lost or invented a unit");
        assertEq(fee, (amount * feeBps) / BPS_DENOMINATOR, "not the fee that was asked for");
        assertGt(net, 0, "a transfer that delivers nothing");
    }

    function testFuzz_the_fee_never_reaches_one_percent_of_anything(uint256 amount, uint16 feeBps)
        public
        view
    {
        amount = bound(amount, 1, type(uint256).max / MAX_FEE_BPS);
        feeBps = uint16(bound(feeBps, 0, MAX_FEE_BPS));

        (uint256 net, uint256 fee) = math.applyFee(amount, feeBps);

        assertLe(fee, amount / 100, "more than one percent came out of it");
        // Two return values of the same type, one careless swap away from a ninety nine percent
        // fee. This line is what a transposition would break.
        assertGe(net, fee, "the returns came back the wrong way round");
    }

    function testFuzz_a_fee_over_the_ceiling_is_always_refused(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, type(uint256).max);
        feeBps = uint16(bound(feeBps, uint256(MAX_FEE_BPS) + 1, type(uint16).max));

        vm.expectRevert(FeeTooHigh.selector);
        math.applyFee(amount, feeBps);
    }

    function testFuzz_an_empty_amount_is_refused_before_the_fee_is_read(uint16 feeBps) public {
        // Ordering, not just rejection. A zero amount carrying an absurd fee should complain
        // about the amount, because the amount is the part the caller can fix.
        vm.expectRevert(InvalidAmount.selector);
        math.applyFee(0, feeBps);
    }

    // -------------------------------------------------------------------------------------
    // Crossing a decimal boundary
    // -------------------------------------------------------------------------------------

    function testFuzz_narrowing_loses_only_the_dust_it_admits_to(uint256 amount, uint8 from, uint8 to)
        public
        view
    {
        from = uint8(bound(from, 1, MAX_DECIMALS));
        to = uint8(bound(to, 0, uint256(from) - 1));

        (uint256 converted, uint256 dust) = math.convertDecimals(amount, from, to);
        uint256 divisor = math.pow10(from - to);

        assertEq(converted * divisor + dust, amount, "a unit went missing on the way down");
        assertLt(dust, divisor, "dust that large is a whole unit of the destination");
        assertLe(converted, amount, "narrowing made the number bigger");
    }

    function testFuzz_widening_is_lossless_or_it_says_no(uint256 amount, uint8 from, uint8 to) public {
        from = uint8(bound(from, 0, uint256(MAX_DECIMALS) - 1));
        to = uint8(bound(to, uint256(from) + 1, MAX_DECIMALS));
        uint256 factor = math.pow10(to - from);

        if (amount != 0 && factor > type(uint256).max / amount) {
            vm.expectRevert(DecimalOverflow.selector);
            math.convertDecimals(amount, from, to);
            return;
        }

        (uint256 converted, uint256 dust) = math.convertDecimals(amount, from, to);
        assertEq(converted, amount * factor, "the scale came out wrong");
        assertEq(dust, 0, "widening cannot produce dust and claimed it did");
    }

    function testFuzz_the_same_base_changes_nothing_at_all(uint256 amount, uint8 decimals) public view {
        decimals = uint8(bound(decimals, 0, MAX_DECIMALS));

        (uint256 converted, uint256 dust) = math.convertDecimals(amount, decimals, decimals);

        assertEq(converted, amount);
        assertEq(dust, 0);
    }

    function testFuzz_a_base_past_the_ceiling_is_refused(
        uint256 amount,
        uint8 from,
        uint8 to,
        bool onDestination
    ) public {
        if (onDestination) {
            from = uint8(bound(from, 0, MAX_DECIMALS));
            to = uint8(bound(to, uint256(MAX_DECIMALS) + 1, type(uint8).max));
        } else {
            from = uint8(bound(from, uint256(MAX_DECIMALS) + 1, type(uint8).max));
            to = uint8(bound(to, 0, type(uint8).max));
        }

        // Both doors, because the router calls one of them and the SDK quotes off the other, and
        // a ceiling enforced on only one of the two is a ceiling.
        vm.expectRevert(InvalidDecimals.selector);
        math.convertDecimals(amount, from, to);

        vm.expectRevert(InvalidDecimals.selector);
        math.floorToRepresentable(amount, from, to);
    }

    function testFuzz_the_exact_conversion_refuses_precisely_when_there_is_something_to_lose(
        uint256 amount,
        uint8 from,
        uint8 to
    ) public {
        amount = bound(amount, 0, WIDEST);
        from = uint8(bound(from, 0, MAX_DECIMALS));
        to = uint8(bound(to, 0, MAX_DECIMALS));

        (uint256 converted, uint256 dust) = math.convertDecimals(amount, from, to);

        // One function is the other plus a refusal. If these two ever disagreed about whether an
        // amount is clean, the router would either move dust it promised not to or refuse a
        // transfer the quote had already approved.
        if (dust == 0) {
            assertEq(math.convertDecimalsExact(amount, from, to), converted);
        } else {
            vm.expectRevert(AmountNotRepresentable.selector);
            math.convertDecimalsExact(amount, from, to);
        }
    }

    // -------------------------------------------------------------------------------------
    // Flooring
    // -------------------------------------------------------------------------------------

    function testFuzz_flooring_always_produces_something_that_crosses_intact(
        uint256 amount,
        uint8 from,
        uint8 to
    ) public view {
        amount = bound(amount, 0, WIDEST);
        from = uint8(bound(from, 0, MAX_DECIMALS));
        to = uint8(bound(to, 0, MAX_DECIMALS));

        uint256 floored = math.floorToRepresentable(amount, from, to);

        assertLe(floored, amount, "flooring rounded up");
        assertEq(math.floorToRepresentable(floored, from, to), floored, "a second pass moved it again");

        // The reason the function exists. Whatever comes out of it is something the exact
        // conversion will take, which is the very next thing the router calls.
        (, uint256 dust) = math.convertDecimals(floored, from, to);
        assertEq(dust, 0, "floored and still not representable");

        if (to >= from) {
            assertEq(floored, amount, "nothing to give up when the destination is wider");
        } else {
            assertLt(amount - floored, math.pow10(from - to), "gave up more than a single unit");
        }
    }

    // -------------------------------------------------------------------------------------
    // The three of them in the order the router calls them
    // -------------------------------------------------------------------------------------

    function testFuzz_the_outbound_pipeline_never_creates_value(
        uint256 amount,
        uint16 feeBps,
        uint8 from,
        uint8 to
    ) public view {
        amount = bound(amount, 1, WIDEST);
        feeBps = uint16(bound(feeBps, 0, MAX_FEE_BPS));
        from = uint8(bound(from, 0, MAX_DECIMALS));
        to = uint8(bound(to, 0, MAX_DECIMALS));

        // `_planOutbound`, in its own order. Take the fee, floor what is left, then refuse to
        // move anything that would not survive the conversion.
        (uint256 netRaw, uint256 fee) = math.applyFee(amount, feeBps);
        uint256 net = math.floorToRepresentable(netRaw, from, to);
        vm.assume(net != 0);
        uint256 landing = math.convertDecimalsExact(net, from, to);

        // The router charges `fee + net`, not the amount it was asked for. Somebody sending an
        // odd number to a narrower chain keeps the remainder instead of donating it, and this is
        // the line that says so.
        assertLe(fee + net, amount, "the router charged more than it was handed");
        assertEq(amount - (fee + net), netRaw - net, "the difference is not the dust");

        if (to >= from) {
            assertEq(fee + net, amount, "nothing is lost here, so nothing should be handed back");
        }

        // And what lands is the same money, read in the destination's own base.
        if (to < from) {
            assertEq(landing * math.pow10(from - to), net, "the landing figure is off by a factor");
        } else {
            assertEq(landing, net * math.pow10(to - from), "the landing figure is off by a factor");
        }
    }

    // -------------------------------------------------------------------------------------
    // pow10
    // -------------------------------------------------------------------------------------

    function testFuzz_pow10_agrees_with_the_exponent_it_was_given(uint8 exp) public view {
        exp = uint8(bound(exp, 0, MAX_DECIMALS));
        assertEq(math.pow10(exp), 10 ** uint256(exp));
    }

    function testFuzz_pow10_refuses_every_exponent_past_the_ceiling(uint8 exp) public {
        exp = uint8(bound(exp, uint256(MAX_DECIMALS) + 1, type(uint8).max));

        vm.expectRevert(DecimalOverflow.selector);
        math.pow10(exp);
    }
}
