// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RouteKind} from "../TraiectaTypes.sol";

/// @title What each rail is actually like
/// @notice Three questions the app and the router both need answered about a rail, kept here
/// rather than spread through the code that asks them.
///
/// Hyperion owns none of these rails. Each one is live, audited by somebody else, and already
/// carrying real volume, and the differences between them are the entire reason a router is
/// worth building. The mirror of the `impl RouteKind` block in `hyperion_core::route`.
library RouteMeta {
    /// @notice Whether the second leg waits on an attestation somebody has to go and fetch.
    /// @dev The difference between "about fifteen minutes" and "about fifteen seconds", which is
    /// the first thing anybody wants to know and the last thing most bridges tell them.
    function waitsOnAttestation(RouteKind route) internal pure returns (bool) {
        return route != RouteKind.Allbridge;
    }

    /// @notice Whether the rail moves the asset itself rather than a pooled or wrapped stand in.
    /// @dev A canonical route cannot slip, because there is no pool to run thin. What arrives is
    /// what left, minus fees that were known before anybody signed.
    function isCanonical(RouteKind route) internal pure returns (bool) {
        return route == RouteKind.Cctp || route == RouteKind.AxelarIts;
    }

    /// @notice Whether the rail can carry a payload alongside the money.
    /// @dev Allbridge cannot. It pays a plain address and its attested hash covers the amount,
    /// the recipient, both chain ids, the token and a nonce, with no field left for anything
    /// else. That is not a gap in the integration, it is what the rail is, and it means a muxed
    /// destination has nowhere to put its sixty four bit id.
    function carriesPayload(RouteKind route) internal pure returns (bool) {
        return route != RouteKind.Allbridge;
    }
}
