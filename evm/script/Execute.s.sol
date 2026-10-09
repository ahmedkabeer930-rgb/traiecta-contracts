// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {HyperionRouter} from "../src/TraiectaRouter.sol";
import {QueuedAction, RouteKind} from "../src/TraiectaTypes.sol";

import {DeployConfig} from "./DeployConfig.sol";

/// @title Phase two: execute what phase one queued, once it has matured
/// @author dotmantissa
/// @notice Reads the record phase one wrote, walks the queued actions in the order they were
/// queued, and executes the ones that are ready. Reports the ones that are not and stops rather
/// than skipping them, because these actions depend on each other: enabling a route before its
/// adapter is set leaves a rail that is on and unreachable.
///
/// Safe to run more than once. An action already executed is skipped with a note rather than
/// retried, so running this after a partial failure picks up where it left off. That matters
/// because the thing most likely to interrupt a run is a gas spike, and the recovery should not
/// require anybody to work out by hand which of nine actions landed.
///
/// Usage:
///   forge script script/Execute.s.sol --rpc-url $RPC --broadcast
contract Execute is DeployConfig {
    using stdJson for string;

    function run() external {
        string memory path = vm.envOr(
            "HYPERION_RECORD", string.concat("deployments/evm-", vm.toString(block.chainid), "-phase1.json")
        );
        string memory record = vm.readFile(path);

        address routerAddress = record.readAddress(".router");
        uint256[] memory ids = record.readUintArray(".queuedActionIds");
        string[] memory whats = record.readStringArray(".queuedActions");

        HyperionRouter router = HyperionRouter(payable(routerAddress));

        console.log("record              ", path);
        console.log("router              ", routerAddress);
        console.log("actions             ", ids.length);
        console.log("now                 ", block.timestamp);
        console.log("");

        uint256 executed;
        uint256 alreadyDone;

        vm.startBroadcast();
        for (uint256 i = 0; i < ids.length; ++i) {
            uint64 id = uint64(ids[i]);
            string memory what = i < whats.length ? whats[i] : "unnamed";
            QueuedAction memory action = router.queuedAction(id);

            if (action.id == 0) {
                // Cancelled, or a record pointing at a different router. Either way, stopping is
                // the only honest move: carrying on would configure half a router from a list
                // that does not describe it.
                console.log("MISSING", id, what);
                revert("queued action is not on this router; wrong record or it was cancelled");
            }
            if (action.executed) {
                console.log("done already", id, what);
                alreadyDone += 1;
                continue;
            }
            if (block.timestamp < action.eta) {
                console.log("NOT READY", id, what);
                console.log("  ready at          ", action.eta);
                console.log("  seconds remaining ", action.eta - block.timestamp);
                revert("timelock has not matured; wait and run again");
            }
            if (block.timestamp > action.expiresAt) {
                console.log("EXPIRED", id, what);
                console.log("  expired at        ", action.expiresAt);
                revert("queued action expired; requeue it before executing");
            }

            router.executeAction(id);
            executed += 1;
            console.log("executed", id, what);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("executed this run   ", executed);
        console.log("already done        ", alreadyDone);

        _verify(router);
    }

    /// @dev Read the router back rather than trusting that the transactions above did what they
    /// said. The actions were validated on the way in and again on the way out, so this is not
    /// looking for a contract bug; it is looking for a record that described a different router,
    /// or a run that somebody interrupted and restarted against the wrong file.
    function _verify(HyperionRouter router) private view {
        TokenParams memory token = tokenParams();

        console.log("");
        console.log("Reading the router back:");
        console.log("  treasury          ", router.treasury());
        console.log("  fee bps           ", router.feeBps());
        console.log("  paused            ", router.paused());
        console.log("  cctp adapter      ", router.adapter(RouteKind.Cctp));
        console.log("  cctp receiver     ", router.railReceiver(RouteKind.Cctp));
        console.log("  cctp enabled      ", router.routeEnabled(RouteKind.Cctp));

        if (wiresAxelar()) {
            console.log("  axelar adapter    ", router.adapter(RouteKind.AxelarIts));
            console.log("  axelar receiver   ", router.railReceiver(RouteKind.AxelarIts));
            console.log("  axelar enabled    ", router.routeEnabled(RouteKind.AxelarIts));
        }

        console.log("  token registered  ", router.tokenConfig(token.token).registered);
        console.log("  token enabled     ", router.tokenConfig(token.token).enabled);
        console.log("  token decimals    ", router.tokenConfig(token.token).decimals);
        console.log("  token flow limit  ", router.tokenConfig(token.token).flowLimit);
        console.log("  flow available    ", router.flowAvailable(token.token, RouteKind.Cctp));

        bool live = router.routeEnabled(RouteKind.Cctp) && router.tokenConfig(token.token).enabled
            && router.adapter(RouteKind.Cctp) != address(0) && !router.paused();
        console.log("");
        console.log(live ? "CCTP is routable." : "CCTP is NOT routable. Something above is wrong.");
    }
}
