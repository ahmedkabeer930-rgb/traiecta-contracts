// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Destination, RouteKind} from "../TraiectaTypes.sol";

/// @title What the router expects from every rail adapter
/// @notice The seam the whole design rests on. The router knows about fees, limits, claims and
/// bookkeeping. An adapter knows about Circle's burn call or Axelar's gateway. Neither knows
/// about the other's problems, and retiring a rail means pointing one storage slot somewhere
/// else rather than redeploying the thing that holds the money.
///
/// The Soroban trait of the same name has the same shape with one deliberate difference: a
/// destination arrives here as the string a person copied out of their wallet rather than a
/// thirty two byte key. Stellar has three kinds of address and the difference matters to whoever
/// has to deliver, so the adapter gets the whole strkey and checks it itself.
interface IRailAdapter {
    /// @notice Push `amount` of `token`, already sitting in this adapter's balance, onto the rail.
    /// @dev The router transfers first and calls second, so an adapter should read its own balance
    /// rather than trusting the number, and must refuse any caller that is not the router.
    ///
    /// Payable because some rails bill for destination gas in native currency at send time. What
    /// is not spent has to come back: an adapter that keeps the change is an adapter quietly
    /// accumulating other people's money.
    /// @param token The ERC20 being moved.
    /// @param amount The net amount, after Hyperion's fee.
    /// @param destination Chain name plus the recipient's strkey.
    /// @param nonce The router's own counter for this transfer, carried so the two halves of a
    /// hop can be matched up by something other than guesswork.
    /// @return railRef Whatever the rail calls this transfer, if it names it at all. Zero when the
    /// rail hands back nothing, which several of them do.
    function dispatch(address token, uint256 amount, Destination calldata destination, uint64 nonce)
        external
        payable
        returns (bytes32 railRef);

    /// @notice Which rail this adapter speaks for.
    function route() external view returns (RouteKind);

    /// @notice Whether this adapter can deliver to a chain by that name.
    /// @dev Asked before a quote is shown, so somebody finds out a route is unavailable while
    /// they are still reading rather than after they have signed.
    /// @param chain Hyperion's name for the destination chain, which each adapter translates into
    /// whatever its own rail calls the place.
    /// @return Whether this rail can reach that chain right now.
    function supportsChain(string calldata chain) external view returns (bool);

    /// @notice What the rail will charge in native currency to deliver to `chain`.
    /// @dev Zero means the rail bills nothing at send time. It does not mean delivery is free;
    /// CCTP takes its cut out of the transferred amount instead.
    /// @param chain Hyperion's name for the destination chain.
    /// @param amount The net amount being sent, since some rails price by size.
    /// @return What to attach as `msg.value`, in this chain's native currency.
    function quoteFee(string calldata chain, uint256 amount) external view returns (uint256);
}
