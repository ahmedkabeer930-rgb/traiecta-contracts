// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HyperionRouter} from "../../src/TraiectaRouter.sol";
import {
    ActionKind,
    AdminAction,
    Destination,
    QuoteBlocker,
    RouteKind,
    RouteQuote
} from "../../src/TraiectaTypes.sol";
import {Fixture} from "../Fixture.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title Asking without doing
/// @notice Every reason a route can turn a transfer down, and the promise that asking never
/// reverts.
/// @dev `quote` exists because an app has to put something on the screen. A bare revert gives it
/// nothing to say, so every refusal comes back as a `QuoteBlocker` instead, and the interesting
/// property is that the list is exhaustive: there is a test here for each value anything can
/// reach, because an arm nothing exercises is an arm that says the wrong thing the day it
/// becomes reachable.
///
/// The other half of the file is agreement. What a quote promises and what `bridgeOut` charges
/// have to be the same numbers, or the quote is a decoration.
contract RouterQuoteTest is Fixture {
    uint256 internal constant AMOUNT = 1000e6;

    /// @dev A real address with one character changed at the end, so the base32 decodes and the
    /// CRC16 does not. Inventing a wrong address is easy; inventing a wrong address that fails
    /// for the reason a test claims is not, which is why this one is derived from a good one.
    string internal constant BROKEN_ADDR = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV";

    // -------------------------------------------------------------------------------------
    // The happy answer
    // -------------------------------------------------------------------------------------

    function test_a_quote_reports_the_fee_the_net_and_what_lands() public view {
        RouteQuote memory q =
            router.quote(RouteKind.Cctp, address(usdc), AMOUNT, _dest(G_ADDR), STELLAR_DECIMALS);

        assertTrue(q.available);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.None));
        assertEq(uint8(q.route), uint8(RouteKind.Cctp));
        assertEq(q.fee, 1e6, "ten basis points of a thousand");
        assertEq(q.netAmount, 999e6);
        assertEq(q.grossAmount, AMOUNT);
        assertEq(q.destinationAmount, 999e7, "six decimals here, seven there");
        assertEq(q.flowAvailable, FLOW_LIMIT);
    }

    function test_a_quote_says_whether_the_rail_waits_on_an_attestation() public view {
        // Three of the four do, and an app that shows a progress bar has to know which before
        // the user commits rather than after.
        assertTrue(_q(RouteKind.Cctp, G_ADDR).waitsOnAttestation);
        assertTrue(_q(RouteKind.AxelarIts, G_ADDR).waitsOnAttestation);
        assertTrue(_q(RouteKind.AxelarGmp, G_ADDR).waitsOnAttestation);
        assertFalse(_q(RouteKind.Allbridge, G_ADDR).waitsOnAttestation);
    }

    function test_a_quote_says_whether_the_asset_arrives_as_itself() public view {
        assertTrue(_q(RouteKind.Cctp, G_ADDR).isCanonical);
        assertTrue(_q(RouteKind.AxelarIts, G_ADDR).isCanonical);
        assertFalse(_q(RouteKind.AxelarGmp, G_ADDR).isCanonical);
        assertFalse(_q(RouteKind.Allbridge, G_ADDR).isCanonical);
    }

    function test_the_route_and_the_gross_come_back_even_on_a_refusal() public {
        // A refused quote is still an answer, and an app rendering four rows needs to know which
        // row this one is.
        _enableRoute(RouteKind.Allbridge, false);
        RouteQuote memory q = _q(RouteKind.Allbridge, G_ADDR);

        assertFalse(q.available);
        assertEq(uint8(q.route), uint8(RouteKind.Allbridge));
        assertEq(q.grossAmount, AMOUNT);
        assertEq(q.netAmount, 0, "and nothing is promised");
        assertEq(q.destinationAmount, 0);
    }

    function test_quoting_all_four_returns_them_in_route_order() public view {
        RouteQuote[] memory quotes = router.quoteAll(address(usdc), AMOUNT, _dest(G_ADDR), STELLAR_DECIMALS);

        assertEq(quotes.length, 4);
        for (uint8 i = 0; i < 4; ++i) {
            assertEq(uint8(quotes[i].route), i, "index is the route, so a caller can trust it");
            assertTrue(quotes[i].available);
        }
    }

    function test_quoting_all_four_mixes_answers_without_reverting() public {
        // The reason `quoteAll` is worth having: one bad rail must not take the other three down,
        // because a mixed answer is the normal state of a router.
        _enableRoute(RouteKind.AxelarGmp, false);
        RouteQuote[] memory quotes = router.quoteAll(address(usdc), AMOUNT, _dest(M_ADDR), 7);

        assertTrue(quotes[0].available, "CCTP carries a hook, so a muxed id has somewhere to sit");
        assertTrue(quotes[1].available);
        assertFalse(quotes[2].available);
        assertEq(uint8(quotes[2].reason), uint8(QuoteBlocker.RouteDisabled));
        assertFalse(quotes[3].available, "Allbridge has no field for it");
        assertEq(uint8(quotes[3].reason), uint8(QuoteBlocker.MuxedNotSupported));
    }

    // -------------------------------------------------------------------------------------
    // Every refusal anything can reach, once each
    // -------------------------------------------------------------------------------------

    function test_blocker_paused() public {
        vm.prank(guardian);
        router.pause();
        _refused(QuoteBlocker.Paused, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 7);
    }

    function test_blocker_route_paused() public {
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);
        _refused(QuoteBlocker.Paused, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 7);

        // Other routes remain unaffected in quoteAll
        RouteQuote[] memory quotes = router.quoteAll(address(usdc), AMOUNT, _dest(G_ADDR), 7);
        assertFalse(quotes[0].available);
        assertEq(uint8(quotes[0].reason), uint8(QuoteBlocker.Paused));
        assertTrue(quotes[1].available);
    }

    function test_blocker_route_disabled() public {
        _enableRoute(RouteKind.Cctp, false);
        _refused(QuoteBlocker.RouteDisabled, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 7);
    }

    function test_blocker_adapter_not_set() public {
        // Needs a router the fixture has not finished wiring, because `SetAdapter` refuses the
        // zero address on the way in and there is no path back to unset. The route is turned on
        // first, since a fresh deployment has every rail off and that refusal comes earlier.
        HyperionRouter fresh = _freshRouter();
        AdminAction memory action = _empty(ActionKind.EnableRoute);
        action.route = RouteKind.Cctp;
        action.amount = 1;
        _runOn(fresh, action);

        RouteQuote memory q = fresh.quote(RouteKind.Cctp, address(usdc), AMOUNT, _dest(G_ADDR), 7);
        assertFalse(q.available);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.AdapterNotSet));
    }

    function test_blocker_invalid_destination() public view {
        _refused(QuoteBlocker.InvalidDestination, RouteKind.Cctp, address(usdc), AMOUNT, BROKEN_ADDR, 7);
    }

    function test_blocker_muxed_not_supported() public view {
        _refused(QuoteBlocker.MuxedNotSupported, RouteKind.Allbridge, address(usdc), AMOUNT, M_ADDR, 7);
    }

    function test_blocker_chain_not_supported() public view {
        RouteQuote memory q = router.quote(
            RouteKind.Cctp, address(usdc), AMOUNT, Destination({chain: "solana", strkey: G_ADDR}), 7
        );
        assertFalse(q.available);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.ChainNotSupported));
    }

    function test_a_rail_that_throws_when_asked_counts_as_not_supporting_the_chain() public {
        // Adapters are contracts somebody else wrote. One of them throwing on a view call must
        // not turn a quote into a revert, because the app has four rows to render and this is
        // only one of them.
        cctpRail.setSupportsReverts(true);
        _refused(QuoteBlocker.ChainNotSupported, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 7);
    }

    function test_blocker_token_not_registered() public {
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 6);
        _refused(QuoteBlocker.TokenNotRegistered, RouteKind.Cctp, address(unknown), AMOUNT, G_ADDR, 7);
    }

    function test_blocker_token_disabled() public {
        // Registered, retired, still on the books. Deliberately a different answer from a flow
        // ceiling of zero, and this is the arm that says so.
        _setTokenEnabled(address(usdc), false);
        _refused(QuoteBlocker.TokenDisabled, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 7);
    }

    function test_blocker_amount_too_small() public view {
        _refused(QuoteBlocker.AmountTooSmall, RouteKind.Cctp, address(usdc), 0, G_ADDR, 7);
    }

    function test_blocker_not_representable() public view {
        // One millionth of a USDC, landing somewhere with no decimal places at all. There is
        // nothing left to send.
        _refused(QuoteBlocker.NotRepresentable, RouteKind.Cctp, address(usdc), 1, G_ADDR, 0);
    }

    function test_blocker_not_representable_for_decimals_the_far_side_cannot_hold() public view {
        _refused(QuoteBlocker.NotRepresentable, RouteKind.Cctp, address(usdc), AMOUNT, G_ADDR, 39);
    }

    function test_an_absurd_amount_is_refused_rather_than_reverting() public view {
        // The fee multiply would overflow long before anybody held this much of anything. A
        // panic here would break the one promise this function makes.
        _refused(QuoteBlocker.NotRepresentable, RouteKind.Cctp, address(usdc), type(uint256).max, G_ADDR, 7);
        _refused(
            QuoteBlocker.NotRepresentable,
            RouteKind.Cctp,
            address(usdc),
            uint256(type(uint128).max) + 1,
            G_ADDR,
            7
        );
    }

    function test_the_largest_amount_the_quote_will_price_still_prices() public view {
        // And the boundary itself is a real answer rather than a refusal, so the bound above is
        // a bound and not an off by one.
        uint256 ceiling = type(uint128).max;
        RouteQuote memory q = router.quote(RouteKind.Cctp, address(usdc), ceiling, _dest(G_ADDR), 7);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.FlowLimitExceeded), "far past the ceiling");
    }

    function test_blocker_flow_limit_exceeded() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 500e6);
        RouteQuote memory q = _q(RouteKind.Cctp, G_ADDR);

        assertFalse(q.available);
        assertEq(uint8(q.reason), uint8(QuoteBlocker.FlowLimitExceeded));
        assertEq(q.flowAvailable, 500e6, "and it says how much room is left");
    }

    function test_a_quote_sees_the_headroom_a_transfer_already_used() public {
        _setRouteFlowLimit(address(usdc), RouteKind.Cctp, 2000e6);
        vm.prank(alice);
        router.bridgeOut(_usdcRequest(AMOUNT));

        RouteQuote memory q = _q(RouteKind.Cctp, G_ADDR);
        assertEq(q.flowAvailable, 2000e6 - 999e6, "the net was charged, not the gross");
        assertTrue(q.available);
    }

    // -------------------------------------------------------------------------------------
    // Agreement with what actually happens
    // -------------------------------------------------------------------------------------

    function test_what_the_quote_promised_is_what_the_transfer_did() public {
        RouteQuote memory q = _q(RouteKind.Cctp, G_ADDR);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        router.bridgeOut(_usdcRequest(AMOUNT));

        assertEq(before - usdc.balanceOf(alice), q.grossAmount, "charged what it said");
        assertEq(usdc.balanceOf(treasury), q.fee, "fee is what it said");
        assertEq(cctpRail.lastCall().amount, q.netAmount, "and the rail got the net it said");
    }

    function test_the_quote_agrees_with_the_transfer_on_a_dusty_amount() public {
        // Eighteen decimals down to six, with an amount that does not divide cleanly. If the
        // quote and the transfer disagree anywhere, it is here.
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        _registerToken(address(dai), 18, type(uint256).max);
        dai.mint(alice, 100e18);
        vm.prank(alice);
        dai.approve(address(router), type(uint256).max);

        uint256 handed = uint256(7e18) + 123_456_789_012_345;
        RouteQuote memory q = router.quote(RouteKind.Cctp, address(dai), handed, _dest(G_ADDR), 6);

        uint256 before = dai.balanceOf(alice);
        vm.prank(alice);
        router.bridgeOut(_tokenRequest(address(dai), handed, 6));

        assertEq(before - dai.balanceOf(alice), q.grossAmount);
        assertEq(dai.balanceOf(treasury), q.fee);
        assertEq(cctpRail.lastCall().amount, q.netAmount);
        assertLt(q.grossAmount, handed, "and the dust never left the sender");
    }

    function test_a_quote_never_reverts_however_silly_the_question() public view {
        // Four nonsensical questions, all of which have to come back as answers. An app that has
        // to wrap every quote in a try is an app that will not.
        router.quote(RouteKind.Cctp, address(0), 0, Destination({chain: "", strkey: ""}), 255);
        router.quote(RouteKind.Allbridge, address(usdc), type(uint256).max, _dest(M_ADDR), 255);
        router.quote(RouteKind.AxelarGmp, address(usdc), 1, _dest("not an address at all"), 0);
        router.quote(RouteKind.AxelarIts, address(usdc), type(uint128).max, _dest(C_ADDR), 7);
    }

    function testFuzz_a_quote_never_reverts(uint8 route, uint256 amount, uint8 destinationDecimals)
        public
        view
    {
        RouteQuote memory q = router.quote(
            RouteKind(route % 4), address(usdc), amount, _dest(G_ADDR), destinationDecimals
        );

        // And when it does say yes, the numbers agree with each other rather than having been
        // filled in one at a time.
        if (q.available) {
            assertEq(q.grossAmount, q.fee + q.netAmount);
            assertLe(q.netAmount, q.flowAvailable);
            assertGt(q.destinationAmount, 0);
        } else {
            assertEq(q.netAmount, 0);
            assertEq(q.destinationAmount, 0);
        }
    }

    function testFuzz_a_refused_quote_and_a_refused_transfer_agree(uint256 amount) public {
        amount = bound(amount, 1, 20_000_000e6);
        bool quoted = router.quote(RouteKind.Cctp, address(usdc), amount, _dest(G_ADDR), 7).available;

        vm.prank(alice);
        (bool sent,) = address(router).call(abi.encodeCall(router.bridgeOut, (_usdcRequest(amount))));

        // Not an exact match in both directions: a quote knows nothing about the sender's
        // balance, so a priced transfer can still fail for want of funds. The direction that
        // matters is the other one, and it has to hold absolutely.
        if (!quoted) assertFalse(sent, "a refused quote must never become a working transfer");
    }

    // -------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------

    function _q(RouteKind route, string memory strkey) internal view returns (RouteQuote memory) {
        return router.quote(route, address(usdc), AMOUNT, _dest(strkey), STELLAR_DECIMALS);
    }

    function _refused(
        QuoteBlocker reason,
        RouteKind route,
        address token,
        uint256 amount,
        string memory strkey,
        uint8 decimals_
    ) internal view {
        RouteQuote memory q = router.quote(route, token, amount, _dest(strkey), decimals_);
        assertFalse(q.available, "should have been refused");
        assertEq(uint8(q.reason), uint8(reason));
    }
}
