// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AmountNotRepresentable,
    DecimalOverflow,
    FeeTooHigh,
    InvalidAmount,
    InvalidDecimals
} from "../TraiectaErrors.sol";

/// @title The only place in this codebase allowed to move an amount between decimal bases
/// @notice USDC is six decimals on every EVM chain and seven on Stellar, and most Stellar issued
/// assets follow seven by convention. Forwarding a raw integer across that boundary is off by
/// exactly ten, every time, in whichever direction hurts more. So no call site does the
/// arithmetic inline. It comes here, where it is named, bounded and fuzzed.
///
/// The twin of `hyperion_core::amount` on the Stellar side, deliberately so. The two have to
/// agree on every input, including the ones nobody would send on purpose, because a transfer one
/// side floors and the other side rounds is a transfer that arrives short and stays short.
library AmountMath {
    /// @dev Largest exponent this library will scale by.
    ///
    /// Thirty eight, which is where `i128` runs out on the Stellar side. This chain could carry
    /// more, and that is exactly why the ceiling is mirrored rather than raised: an amount the
    /// far side cannot represent has to be refused here, while the funds are still in the
    /// sender's wallet, rather than there, after a burn.
    uint8 internal constant MAX_DECIMALS = 38;

    /// @dev One hundred basis points. A router that could quietly charge more than one percent
    /// is a router that can be quietly turned into a toll booth, so the ceiling is compiled in
    /// and no administrative path anywhere raises it.
    uint16 internal constant MAX_FEE_BPS = 100;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Ten to the power of `exp`.
    /// @dev Reverts past `MAX_DECIMALS` rather than saturating, because a silently clamped
    /// exponent is a silently wrong amount.
    function pow10(uint8 exp) internal pure returns (uint256) {
        if (exp > MAX_DECIMALS) revert DecimalOverflow();
        return 10 ** uint256(exp);
    }

    /// @notice Move `amount` from a `from` decimal base into a `to` decimal base.
    /// @return converted The amount in the destination's base.
    /// @return dust What could not be represented there.
    /// @dev Dust is returned rather than swallowed. Hyperion never keeps it and never rounds it
    /// away silently: the router refuses an outbound transfer that would produce any, and the SDK
    /// quotes a number that divides cleanly, so nobody watches a balance shrink in transit.
    function convertDecimals(uint256 amount, uint8 from, uint8 to)
        internal
        pure
        returns (uint256 converted, uint256 dust)
    {
        if (from > MAX_DECIMALS || to > MAX_DECIMALS) revert InvalidDecimals();
        if (from == to) return (amount, 0);

        if (to > from) {
            uint256 factor = pow10(to - from);
            // Checked arithmetic would revert here anyway. Naming the reason is worth the branch,
            // because "DecimalOverflow" tells an operator which number was too big and a panic
            // tells them to go and read the bytecode.
            unchecked {
                if (amount != 0 && factor > type(uint256).max / amount) revert DecimalOverflow();
            }
            return (amount * factor, 0);
        }

        uint256 divisor = pow10(from - to);
        return (amount / divisor, amount % divisor);
    }

    /// @notice As `convertDecimals`, but refuses to lose anything at all.
    /// @dev What the router uses on the way out. An amount whose tail digits cannot cross the
    /// boundary is a quoting bug upstream, and it should fail loudly here rather than quietly
    /// deliver less than the sender was shown.
    function convertDecimalsExact(uint256 amount, uint8 from, uint8 to) internal pure returns (uint256) {
        (uint256 converted, uint256 dust) = convertDecimals(amount, from, to);
        if (dust != 0) revert AmountNotRepresentable();
        return converted;
    }

    /// @notice Round `amount` down to the nearest value that survives the trip intact.
    /// @dev This is what turns "send everything I have" into a number the router will accept.
    function floorToRepresentable(uint256 amount, uint8 from, uint8 to) internal pure returns (uint256) {
        if (from > MAX_DECIMALS || to > MAX_DECIMALS) revert InvalidDecimals();
        if (to >= from) return amount;
        uint256 divisor = pow10(from - to);
        return amount - (amount % divisor);
    }

    /// @notice Split `amount` into what crosses and what the protocol keeps.
    /// @return net What crosses.
    /// @return fee What the protocol keeps.
    /// @dev Two return values of the same type is one careless swap away from charging a ninety
    /// nine percent fee, so they are named and the order is asserted by a test that would fail if
    /// anybody ever transposed them.
    ///
    /// The fee is charged on the outbound leg only and denominated in the asset being bridged, so
    /// the number a user was shown does not drift with a gas market they never looked at.
    function applyFee(uint256 amount, uint16 feeBps) internal pure returns (uint256 net, uint256 fee) {
        if (amount == 0) revert InvalidAmount();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        fee = (amount * feeBps) / BPS_DENOMINATOR;
        net = amount - fee;
        // Only reachable if the ceiling above were ever raised to ten thousand. Left in because
        // the invariant worth stating is "a transfer always delivers something", not "the current
        // constants happen to make that true".
        if (net == 0) revert InvalidAmount();
    }
}
