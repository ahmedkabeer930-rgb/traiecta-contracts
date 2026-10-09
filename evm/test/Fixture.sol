// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {HyperionRouter} from "../src/TraiectaRouter.sol";
import {ActionKind, AdminAction, Destination, OutboundRequest, RouteKind} from "../src/TraiectaTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRailAdapter} from "./mocks/MockRailAdapter.sol";

/// @title The world every router test starts from
/// @notice One router, one token, one adapter per rail, and a set of real Stellar addresses.
/// @dev Two things here are worth knowing before reading any test that inherits it.
///
/// The strkeys are real. They carry genuine CRC16 checksums, and they were generated rather than
/// typed, because a made up one fails the checksum and every test that touched it would fail for
/// a reason that has nothing to do with what it was testing. `G_KEY` and `MUXED_KEY` are the same
/// thirty two bytes on purpose: a muxed address is a base account plus an integer, and a codec
/// that quietly loses the integer would otherwise look correct.
///
/// Every privileged change goes through the timelock, so `_run` exists. Writing the queue, the
/// warp and the execute out longhand in forty tests would bury the one line each test is actually
/// about.
contract Fixture is Test {
    // Real addresses, checksums and all. The muxed one wraps the account one with id 2^53 + 1,
    // which is past what a double can count to, so a codec that ever round trips through a float
    // fails here rather than in production.
    string internal constant G_ADDR = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNR";
    string internal constant C_ADDR = "CAGR5KFYMZYI7WWQ6TWYYZ346T7GNZLKER4DOJTAG3SOB46QLR5RAPSN";
    string internal constant M_ADDR = "MA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RKABAAAAAAAAAAFLXQ";

    bytes32 internal constant G_KEY = 0x3b9c2115c0efd344ba0a8901eb1cfe44f36cf7dbe946beb0ee4820f7ec49bf15;
    bytes32 internal constant C_KEY = 0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10;
    uint64 internal constant MUXED_ID = 9_007_199_254_740_993;

    string internal constant STELLAR = "stellar";

    uint16 internal constant FEE_BPS = 10;
    uint64 internal constant TIMELOCK = 2 days;
    uint64 internal constant FLOW_WINDOW = 1 hours;

    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant STELLAR_DECIMALS = 7;
    uint256 internal constant FLOW_LIMIT = 1_000_000e6;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal railReceiver = makeAddr("railReceiver");

    HyperionRouter internal router;
    MockERC20 internal usdc;

    /// @dev Read once, here, rather than in each test that names a role. `expectRevert` watches
    /// the next external call, and `router.DEFAULT_ADMIN_ROLE()` sitting inside the arguments of
    /// an expected error is an external call, so it quietly becomes the call being watched and
    /// the test passes for the wrong reason.
    bytes32 internal adminRole;
    bytes32 internal guardianRole;
    MockRailAdapter internal cctpRail;
    MockRailAdapter internal itsRail;
    MockRailAdapter internal gmpRail;
    MockRailAdapter internal allbridgeRail;

    function setUp() public virtual {
        router = new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);
        usdc = new MockERC20("USD Coin", "USDC", USDC_DECIMALS);

        adminRole = router.DEFAULT_ADMIN_ROLE();
        guardianRole = router.GUARDIAN_ROLE();

        cctpRail = new MockRailAdapter(RouteKind.Cctp, address(router));
        itsRail = new MockRailAdapter(RouteKind.AxelarIts, address(router));
        gmpRail = new MockRailAdapter(RouteKind.AxelarGmp, address(router));
        allbridgeRail = new MockRailAdapter(RouteKind.Allbridge, address(router));

        cctpRail.setSupported(STELLAR, true);
        itsRail.setSupported(STELLAR, true);
        gmpRail.setSupported(STELLAR, true);
        allbridgeRail.setSupported(STELLAR, true);

        _setAdapter(RouteKind.Cctp, address(cctpRail));
        _setAdapter(RouteKind.AxelarIts, address(itsRail));
        _setAdapter(RouteKind.AxelarGmp, address(gmpRail));
        _setAdapter(RouteKind.Allbridge, address(allbridgeRail));

        _enableRoute(RouteKind.Cctp, true);
        _enableRoute(RouteKind.AxelarIts, true);
        _enableRoute(RouteKind.AxelarGmp, true);
        _enableRoute(RouteKind.Allbridge, true);

        _registerToken(address(usdc), USDC_DECIMALS, FLOW_LIMIT);
        _setRailReceiver(RouteKind.Cctp, railReceiver);

        usdc.mint(alice, 10_000_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);
    }

    // -------------------------------------------------------------------------------------
    // Timelock shorthand
    // -------------------------------------------------------------------------------------

    /// @dev Queue a change, wait it out, execute it. Returns the id in case a test wants it.
    function _run(AdminAction memory action) internal returns (uint64 id) {
        return _runOn(router, action);
    }

    /// @dev The same, against some other router. A test that wants a half configured deployment
    /// needs one the fixture has not already finished wiring.
    function _runOn(HyperionRouter target, AdminAction memory action) internal returns (uint64 id) {
        vm.prank(admin);
        id = target.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(admin);
        target.executeAction(id);
    }

    /// @dev Queue a change and let the clock run out, without executing it. For a test that
    /// wants to watch what the execution emits, which `_run` would bury under the queue event.
    function _mature(AdminAction memory action) internal returns (uint64 id) {
        vm.prank(admin);
        id = router.queueAction(action);
        vm.warp(block.timestamp + TIMELOCK + 1);
    }

    function _empty(ActionKind kind) internal pure returns (AdminAction memory) {
        return AdminAction({kind: kind, route: RouteKind.Cctp, subject: address(0), amount: 0, decimals: 0});
    }

    function _setAdapter(RouteKind route, address adapterAddress) internal {
        AdminAction memory action = _empty(ActionKind.SetAdapter);
        action.route = route;
        action.subject = adapterAddress;
        _run(action);
    }

    function _setRailReceiver(RouteKind route, address receiver) internal {
        AdminAction memory action = _empty(ActionKind.SetRailReceiver);
        action.route = route;
        action.subject = receiver;
        _run(action);
    }

    function _enableRoute(RouteKind route, bool on) internal {
        AdminAction memory action = _empty(ActionKind.EnableRoute);
        action.route = route;
        action.amount = on ? 1 : 0;
        _run(action);
    }

    function _registerToken(address token, uint8 decimals_, uint256 flowLimit) internal {
        AdminAction memory action = _empty(ActionKind.RegisterToken);
        action.subject = token;
        action.amount = flowLimit;
        action.decimals = decimals_;
        _run(action);
    }

    function _setRouteFlowLimit(address token, RouteKind route, uint256 limit) internal {
        AdminAction memory action = _empty(ActionKind.SetRouteFlowLimit);
        action.route = route;
        action.subject = token;
        action.amount = limit;
        _run(action);
    }

    function _setTokenEnabled(address token, bool on) internal {
        AdminAction memory action = _empty(ActionKind.SetTokenEnabled);
        action.subject = token;
        action.amount = on ? 1 : 0;
        _run(action);
    }

    function _setFeeBps(uint16 bps) internal {
        AdminAction memory action = _empty(ActionKind.SetFeeBps);
        action.amount = bps;
        _run(action);
    }

    // -------------------------------------------------------------------------------------
    // Request shorthand
    // -------------------------------------------------------------------------------------

    function _dest(string memory strkey) internal pure returns (Destination memory) {
        return Destination({chain: STELLAR, strkey: strkey});
    }

    function _request(uint256 amount, RouteKind route) internal pure returns (OutboundRequest memory) {
        return OutboundRequest({
            token: address(0),
            amount: amount,
            route: route,
            destination: _dest(G_ADDR),
            destinationDecimals: STELLAR_DECIMALS,
            minDestinationAmount: 0
        });
    }

    /// @dev A router with nothing wired to it. For tests about a half finished deployment,
    /// which the fixture's own `setUp` has already moved past.
    function _freshRouter() internal returns (HyperionRouter) {
        return new HyperionRouter(admin, guardian, treasury, FEE_BPS, TIMELOCK, FLOW_WINDOW);
    }

    /// @dev Some other asset, over CCTP, to a classic account. For the decimal pairs USDC does
    /// not exercise.
    function _tokenRequest(address token, uint256 amount, uint8 destinationDecimals)
        internal
        pure
        returns (OutboundRequest memory request)
    {
        request = _request(amount, RouteKind.Cctp);
        request.token = token;
        request.destinationDecimals = destinationDecimals;
    }

    /// @dev The common case: USDC, over CCTP, to a classic account, no slippage floor.
    function _usdcRequest(uint256 amount) internal view returns (OutboundRequest memory request) {
        request = _request(amount, RouteKind.Cctp);
        request.token = address(usdc);
    }
}
