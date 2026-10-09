// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FlowLimitExceeded, InvalidWindow} from "../TraiectaErrors.sol";

/// @notice Rolling record of how much of a flow limit has been spent.
/// @dev Two numbers and an epoch. No array of timestamps, because the list would grow with
/// traffic and the gas to walk it would grow with it, which is the wrong direction for something
/// that runs on every single transfer.
struct FlowWindow {
    /// Which window this record is anchored to, as timestamp divided by window length.
    uint64 epoch;
    /// Spent inside the current window.
    uint256 consumed;
    /// Spent inside the window immediately before this one, decaying as the current one fills.
    uint256 prevConsumed;
}

/// @title A limit that slides instead of stepping
/// @notice A fixed calendar window is the obvious way to rate limit and also the wrong one. Fill
/// the hour's allowance in the last minute of one hour, then fill it again in the first minute of
/// the next, and two hours of limit left in two minutes. Every boundary is a hole, and everybody
/// who wants to find one will.
///
/// So the previous window's total stays on the books and is weighted out in proportion to how far
/// the current window has run. Ten minutes into an hour, fifty out of sixty parts of the old total
/// still count against you. The limit never resets at a boundary; it drains across one.
///
/// The mirror of `hyperion_core::flow`, down to the arithmetic, so the same transfer refused on
/// one side is refused on the other for the same reason. The only deliberate difference is what
/// time means: Soroban counts ledgers, this counts seconds, because a chain that produces blocks
/// on demand has no reliable block rate to divide by.
library FlowGuard {
    /// @notice Which window a timestamp falls into.
    function epochOf(uint64 timestamp, uint64 window) internal pure returns (uint64) {
        if (window == 0) revert InvalidWindow();
        return timestamp / window;
    }

    /// @notice Advance a record to `timestamp` without spending anything.
    /// @dev One window forward keeps the old total as the decaying tail. Two or more means nothing
    /// recent happened at all, so both counters go to zero: there is nothing to decay out.
    function rollForward(FlowWindow memory self, uint64 timestamp, uint64 window)
        internal
        pure
        returns (FlowWindow memory)
    {
        uint64 epoch = epochOf(timestamp, window);
        if (epoch == self.epoch) return self;
        if (epoch == self.epoch + 1) {
            return FlowWindow({epoch: epoch, consumed: 0, prevConsumed: self.consumed});
        }
        return FlowWindow({epoch: epoch, consumed: 0, prevConsumed: 0});
    }

    /// @notice How much of the limit counts as spent right now.
    /// @dev The previous window contributes in proportion to how much of the current one is left
    /// to run. Integer division rounds the tail down, which rounds in the sender's favour by at
    /// most one unit of the token's smallest denomination, and that is the right direction to be
    /// wrong in for something whose failure mode is refusing an honest transfer.
    function effectiveConsumed(FlowWindow memory self, uint64 timestamp, uint64 window)
        internal
        pure
        returns (uint256)
    {
        FlowWindow memory rolled = rollForward(self, timestamp, window);
        uint256 remaining = window - (timestamp % window);
        return (rolled.prevConsumed * remaining) / window + rolled.consumed;
    }

    /// @notice Headroom left under `limit`. Never negative, and zero once the limit is met.
    function available(FlowWindow memory self, uint256 limit, uint64 timestamp, uint64 window)
        internal
        pure
        returns (uint256)
    {
        uint256 used = effectiveConsumed(self, timestamp, window);
        return used >= limit ? 0 : limit - used;
    }

    /// @notice Charge `amount` against the limit, or refuse.
    /// @dev Refusing is the entire point of this library, so it reverts rather than saturating.
    /// A flow limit that silently clamps a transfer to whatever was left would deliver the wrong
    /// amount, and the wrong amount arriving is worse than nothing arriving.
    function consume(FlowWindow memory self, uint256 limit, uint256 amount, uint64 timestamp, uint64 window)
        internal
        pure
        returns (FlowWindow memory)
    {
        FlowWindow memory rolled = rollForward(self, timestamp, window);
        uint256 used = effectiveConsumed(self, timestamp, window);
        if (used + amount > limit) revert FlowLimitExceeded(amount, limit - (used >= limit ? limit : used));
        rolled.consumed += amount;
        return rolled;
    }
}
