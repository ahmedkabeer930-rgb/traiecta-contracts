// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {HyperionRouter} from "../src/TraiectaRouter.sol";
import {RouteKind} from "../src/TraiectaTypes.sol";
import {AxelarItsAdapter} from "../src/adapters/AxelarItsAdapter.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";

import {DeployConfig} from "./DeployConfig.sol";

/// @title Read a live deployment back and check it against the record
/// @author dotmantissa
/// @notice Signs nothing and sends nothing. Every value below is read off the chain and compared
/// against the file, and the script fails if any of them disagree.
///
/// Worth having as its own script rather than a tail on the deploy, because the question "is the
/// thing on chain still what we wrote down" is one somebody asks weeks later, during an incident,
/// from a laptop that never ran the deployment. It should not require reading nine `cast call`
/// invocations off a wiki.
///
/// Usage:
///   forge script script/Verify.s.sol --rpc-url $RPC
contract Verify is DeployConfig {
    using stdJson for string;

    uint256 internal problems;

    function run() external {
        string memory path = vm.envOr(
            "HYPERION_RECORD", string.concat("deployments/evm-", vm.toString(block.chainid), "-phase1.json")
        );
        string memory record = vm.readFile(path);

        HyperionRouter router = HyperionRouter(payable(record.readAddress(".router")));
        CctpAdapter cctp = CctpAdapter(payable(record.readAddress(".cctpAdapter")));

        console.log("record              ", path);
        console.log("router              ", address(router));
        console.log("");

        _expectUint("chain id", block.chainid, record.readUint(".chainId"));
        _expectAddress("treasury", router.treasury(), record.readAddress(".treasury"));
        _expectUint("fee bps", router.feeBps(), record.readUint(".feeBps"));
        _expectUint("timelock delay", router.timelockDelay(), record.readUint(".timelockDelay"));
        _expectUint("flow window", router.flowWindow(), record.readUint(".flowWindow"));

        _expectAddress("cctp adapter", router.adapter(RouteKind.Cctp), address(cctp));
        _expectAddress("cctp receiver", router.railReceiver(RouteKind.Cctp), address(cctp));
        _expectTrue("cctp route enabled", router.routeEnabled(RouteKind.Cctp));
        _expectAddress("cctp adapter router", cctp.ROUTER(), address(router));
        _expectAddress(
            "cctp token messenger", address(cctp.TOKEN_MESSENGER()), record.readAddress(".cctpTokenMessenger")
        );

        // The lane is the value a wrong entry costs the most: it decides who Circle credits.
        CctpAdapter.Lane memory lane = cctp.laneOf(record.readString(".stellarChain"));
        _expectTrue("cctp lane configured", lane.configured);
        _expectTrue("cctp lane enabled", lane.enabled);
        _expectUint("cctp lane domain", lane.domain, STELLAR_CCTP_DOMAIN);
        _expectBytes32("cctp mint recipient", lane.mintRecipient, record.readBytes32(".stellarRailRecipient"));

        address token = record.readAddress(".token");
        _expectTrue("token registered", router.tokenConfig(token).registered);
        _expectTrue("token enabled", router.tokenConfig(token).enabled);
        _expectUint("token decimals", router.tokenConfig(token).decimals, record.readUint(".tokenDecimals"));
        _expectUint(
            "token flow limit", router.tokenConfig(token).flowLimit, record.readUint(".tokenFlowLimit")
        );

        _expectFalse("router paused", router.paused());

        if (vm.keyExistsJson(record, ".axelarAdapter")) {
            AxelarItsAdapter axelar = AxelarItsAdapter(payable(record.readAddress(".axelarAdapter")));
            _expectAddress("axelar adapter", router.adapter(RouteKind.AxelarIts), address(axelar));
            _expectAddress("axelar receiver", router.railReceiver(RouteKind.AxelarIts), address(axelar));
            _expectTrue("axelar route enabled", router.routeEnabled(RouteKind.AxelarIts));
            _expectAddress("axelar adapter router", axelar.ROUTER(), address(router));
            _expectBytes32("axelar token id", axelar.tokenIdOf(token), record.readBytes32(".axelarTokenId"));

            AxelarItsAdapter.Peer memory peer = axelar.peerOf(record.readString(".stellarChain"));
            _expectTrue("axelar peer configured", peer.configured);
            _expectTrue("axelar peer enabled", peer.enabled);
            _expectBytes("axelar peer address", peer.peer, vm.envBytes("STELLAR_AXELAR_PEER"));
        }

        // The admin handover is the one thing that cannot be checked by equality alone, because a
        // record written before the handover matured names the deployer.
        address recordedAdmin = record.readAddress(".admin");
        bool adminHolds = router.hasRole(router.DEFAULT_ADMIN_ROLE(), recordedAdmin);
        console.log(
            adminHolds
                ? "  ok   admin role held by the recorded admin"
                : "  WARN admin role not yet handed over"
        );
        if (!adminHolds) {
            console.log("       recorded admin    ", recordedAdmin);
            console.log("       deployer          ", record.readAddress(".deployer"));
            console.log("       run Execute.s.sol if the handover action is still queued");
        }

        console.log("");
        if (problems == 0) {
            console.log("Everything on chain matches the record.");
        } else {
            console.log("Mismatches          ", problems);
            revert("the chain and the record disagree");
        }
    }

    function _expectAddress(string memory what, address found, address want) private {
        if (found == want) {
            console.log("  ok  ", what, found);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", found);
            console.log("        want ", want);
        }
    }

    function _expectUint(string memory what, uint256 found, uint256 want) private {
        if (found == want) {
            console.log("  ok  ", what, found);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", found);
            console.log("        want ", want);
        }
    }

    function _expectBytes32(string memory what, bytes32 found, bytes32 want) private {
        if (found == want) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", vm.toString(found));
            console.log("        want ", vm.toString(want));
        }
    }

    function _expectBytes(string memory what, bytes memory found, bytes memory want) private {
        if (keccak256(found) == keccak256(want)) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", vm.toString(found));
            console.log("        want ", vm.toString(want));
        }
    }

    function _expectTrue(string memory what, bool found) private {
        if (found) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what, "is false and should be true");
        }
    }

    function _expectFalse(string memory what, bool found) private {
        if (!found) {
            console.log("  ok  ", what, "is false");
        } else {
            problems += 1;
            console.log("  BAD ", what, "is true and should be false");
        }
    }
}
