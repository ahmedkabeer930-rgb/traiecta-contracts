// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Destination, RouteKind} from "../../src/TraiectaTypes.sol";
import {IRailAdapter} from "../../src/interfaces/IRailAdapter.sol";

/// @title A rail that does whatever the test needs
/// @notice Records what the router handed it, and can be told to behave badly.
/// @dev The router's job on the way out is to get the arithmetic right, take the fee, and hand
/// the remainder to the right contract. Proving that does not need a real rail, it needs a rail
/// that remembers its arguments and can refund native currency, revert, or quote a chain it does
/// not support, on demand.
contract MockRailAdapter is IRailAdapter {
    error Rejected();

    struct Call {
        address token;
        uint256 amount;
        string chain;
        string strkey;
        uint64 nonce;
        uint256 value;
    }

    RouteKind private immutable ROUTE;
    address private immutable ROUTER;

    Call private _lastCall;
    uint256 public callCount;

    mapping(string chain => bool ok) private _supported;
    bool private _supportsReverts;
    bool private _dispatchReverts;
    uint256 private _refundAmount;
    bytes32 private _railRef;

    constructor(RouteKind route_, address router) {
        ROUTE = route_;
        ROUTER = router;
        _railRef = keccak256("mock.rail.ref");
    }

    receive() external payable {}

    function route() external view override returns (RouteKind) {
        return ROUTE;
    }

    function supportsChain(string calldata chain) external view override returns (bool) {
        if (_supportsReverts) revert Rejected();
        return _supported[chain];
    }

    function quoteFee(string calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function dispatch(address token, uint256 amount, Destination calldata destination, uint64 nonce)
        external
        payable
        override
        returns (bytes32)
    {
        if (_dispatchReverts) revert Rejected();
        _lastCall = Call({
            token: token,
            amount: amount,
            chain: destination.chain,
            strkey: destination.strkey,
            nonce: nonce,
            value: msg.value
        });
        ++callCount;

        if (_refundAmount != 0) {
            (bool sent,) = payable(ROUTER).call{value: _refundAmount}("");
            require(sent, "refund");
        }
        return _railRef;
    }

    /// @dev Written out rather than left to a public struct, because the generated getter for a
    /// struct drops its string members and the two strings are half of what these tests read.
    function lastCall() external view returns (Call memory) {
        return _lastCall;
    }

    function setSupported(string calldata chain, bool ok) external {
        _supported[chain] = ok;
    }

    function setSupportsReverts(bool on) external {
        _supportsReverts = on;
    }

    function setDispatchReverts(bool on) external {
        _dispatchReverts = on;
    }

    /// @dev How much native currency to hand back, the way a real rail refunds unused gas.
    function setRefund(uint256 amount) external {
        _refundAmount = amount;
    }

    function railRef() external view returns (bytes32) {
        return _railRef;
    }
}
