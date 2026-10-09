// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {HyperionRouter} from "../src/TraiectaRouter.sol";
import {ActionKind, AdminAction, RouteKind} from "../src/TraiectaTypes.sol";
import {AxelarItsAdapter} from "../src/adapters/AxelarItsAdapter.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";

import {DeployConfig} from "./DeployConfig.sol";

/// @title Phase one of a Hyperion deployment: put the contracts on chain and start the clock
/// @author dotmantissa
/// @notice Deploys the router and its adapters, configures the parts that are not timelocked, and
/// queues the parts that are. It does not finish the job, because it cannot.
///
/// The router's timelock has no bootstrap exemption, and that is a decision rather than an
/// oversight. An exemption would be a second code path that sets adapters without waiting, which
/// is precisely the path an attacker wants and precisely the path nobody tests after week one. So
/// a fresh router is configured the same way a two year old one is: queue, wait, execute. The
/// floor is one hour and the default here is a day.
///
/// What that means in practice is that this script leaves a router that is deployed, owns nothing
/// yet, and has a list of pending changes with timestamps on them. `Execute.s.sol` finishes it
/// once they mature. In between, the deployment record on disk is the handover, and anybody can
/// read the queued actions off the chain and check them against it.
///
/// The adapters are configured here and now, because they are `Ownable` rather than timelocked and
/// because an adapter with no lanes cannot do anything at all. Their lane and peer setters are
/// once only, so this is the only chance to get them right.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --verify
contract Deploy is DeployConfig {
    /// @dev Written to disk so phase two, and any reviewer, works from the same list.
    struct Queued {
        uint64 id;
        string what;
    }

    HyperionRouter internal router;
    CctpAdapter internal cctp;
    AxelarItsAdapter internal axelar;

    Queued[] internal queued;

    function run() external {
        RouterParams memory params = routerParams();
        RailParams memory rails = railParams();
        TokenParams memory token = tokenParams();
        bool axelarToo = wiresAxelar();

        // The deployer signs, the admin governs. On a real network those are different keys and
        // the deployer should hold nothing by the end of phase two.
        address deployer = msg.sender;

        console.log("chain id            ", block.chainid);
        console.log("deployer            ", deployer);
        console.log("admin               ", params.admin);
        console.log("guardian            ", params.guardian);
        console.log("treasury            ", params.treasury);
        console.log("fee bps             ", params.feeBps);
        console.log("timelock delay (s)  ", params.timelockDelay);
        console.log("flow window (s)     ", params.flowWindow);
        console.log("asset               ", token.token);
        console.log("wiring axelar       ", axelarToo);

        vm.startBroadcast();

        // The deployer is admin for the length of the deployment and nothing longer. Handing the
        // real admin straight to a multisig would mean every queued action below needs that
        // multisig to sign, in a script, which it cannot do. So the deployer queues and executes,
        // and the last queued action hands the role over.
        router = new HyperionRouter(
            deployer, params.guardian, params.treasury, params.feeBps, params.timelockDelay, params.flowWindow
        );
        console.log("router              ", address(router));

        cctp = new CctpAdapter(address(router), rails.cctpTokenMessenger, token.token, deployer);
        console.log("cctp adapter        ", address(cctp));

        // Once only, and the one that matters most. The mint recipient is who Circle credits on
        // the far side, so a wrong value here is a burn on this chain against a mint nobody owns.
        cctp.setLane(stellarChain(), STELLAR_CCTP_DOMAIN, stellarRailRecipient());
        console.log("cctp lane           ", stellarChain());

        if (axelarToo) {
            axelar = new AxelarItsAdapter(address(router), rails.axelarIts, rails.axelarGasService, deployer);
            console.log("axelar adapter      ", address(axelar));

            // The peer check on inbound deliveries compares against this exact byte string.
            // Arriving through ITS proves a message was delivered, not who sent it.
            axelar.setPeer(stellarChain(), axelarStellarChain(), stellarAxelarPeer());
            // Asks ITS whether the id really belongs to this token, so a typo fails here.
            axelar.linkToken(token.token, axelarTokenId());
            console.log("axelar peer         ", axelarStellarChain());
        }

        _queueRouterSetup(token, axelarToo, params.admin, deployer);

        vm.stopBroadcast();

        _writeRecord(params, rails, token, axelarToo, deployer);
        _report(params);
    }

    /// @dev Order matters here in one place only: the handover is last, because an admin change
    /// that landed first would leave every action after it queued by an account that can no longer
    /// execute anything.
    function _queueRouterSetup(TokenParams memory token, bool axelarToo, address admin, address deployer)
        private
    {
        _queue(
            AdminAction({
                kind: ActionKind.RegisterToken,
                route: RouteKind.Cctp,
                subject: token.token,
                amount: token.flowLimit,
                decimals: token.decimals
            }),
            string.concat("register ", token.symbol)
        );

        _queue(_routeAction(ActionKind.SetAdapter, RouteKind.Cctp, address(cctp), 0), "set cctp adapter");
        _queue(
            _routeAction(ActionKind.SetRailReceiver, RouteKind.Cctp, address(cctp), 0), "set cctp receiver"
        );
        _queue(_routeAction(ActionKind.EnableRoute, RouteKind.Cctp, address(0), 1), "enable cctp");

        if (axelarToo) {
            _queue(
                _routeAction(ActionKind.SetAdapter, RouteKind.AxelarIts, address(axelar), 0),
                "set axelar adapter"
            );
            _queue(
                _routeAction(ActionKind.SetRailReceiver, RouteKind.AxelarIts, address(axelar), 0),
                "set axelar receiver"
            );
            _queue(
                _routeAction(ActionKind.EnableRoute, RouteKind.AxelarIts, address(0), 1), "enable axelar its"
            );
        }

        // Last, and only when the admin is somebody else. Skipped on a local chain where the
        // deployer is the admin, because queueing a handover to yourself is a no op that still
        // has to wait out a timelock.
        if (admin != deployer) {
            _queue(
                AdminAction({
                    kind: ActionKind.SetAdmin, route: RouteKind.Cctp, subject: admin, amount: 0, decimals: 0
                }),
                "hand admin to the real holder"
            );
        }
    }

    /// @dev `RouteKind.Cctp` is zero, so it doubles as the empty value for the kinds that have
    /// nothing to do with a rail. The router validates every unused field is empty, which is why
    /// this helper exists rather than four struct literals per call site.
    function _routeAction(ActionKind kind, RouteKind route, address subject, uint256 amount)
        private
        pure
        returns (AdminAction memory)
    {
        return AdminAction({kind: kind, route: route, subject: subject, amount: amount, decimals: 0});
    }

    function _queue(AdminAction memory action, string memory what) private {
        uint64 id = router.queueAction(action);
        queued.push(Queued({id: id, what: what}));
        console.log("queued", id, what);
    }

    /// @dev Written as JSON because the Stellar half, the backend and the frontend all read it,
    /// and because a deployment nobody wrote down is a deployment nobody can audit. Keys are
    /// built one at a time rather than through a struct, since `vm.serializeJson` on a struct
    /// gives field order nobody chose.
    function _writeRecord(
        RouterParams memory params,
        RailParams memory rails,
        TokenParams memory token,
        bool axelarToo,
        address deployer
    ) private {
        string memory key = "hyperion";

        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "router", address(router));
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "admin", params.admin);
        vm.serializeAddress(key, "guardian", params.guardian);
        vm.serializeAddress(key, "treasury", params.treasury);
        vm.serializeUint(key, "feeBps", params.feeBps);
        vm.serializeUint(key, "timelockDelay", params.timelockDelay);
        vm.serializeUint(key, "flowWindow", params.flowWindow);
        vm.serializeUint(key, "deployedAtBlock", block.number);
        vm.serializeUint(key, "deployedAtTimestamp", block.timestamp);
        vm.serializeString(key, "stellarChain", stellarChain());

        vm.serializeAddress(key, "cctpAdapter", address(cctp));
        vm.serializeAddress(key, "cctpTokenMessenger", rails.cctpTokenMessenger);
        vm.serializeAddress(key, "cctpMessageTransmitter", rails.cctpMessageTransmitter);
        vm.serializeBytes32(key, "stellarRailRecipient", stellarRailRecipient());

        if (axelarToo) {
            vm.serializeAddress(key, "axelarAdapter", address(axelar));
            vm.serializeAddress(key, "axelarIts", rails.axelarIts);
            vm.serializeAddress(key, "axelarGasService", rails.axelarGasService);
            vm.serializeString(key, "axelarStellarChain", axelarStellarChain());
            vm.serializeBytes32(key, "axelarTokenId", axelarTokenId());
        }

        vm.serializeString(key, "tokenSymbol", token.symbol);
        vm.serializeAddress(key, "token", token.token);
        vm.serializeUint(key, "tokenDecimals", token.decimals);
        vm.serializeUint(key, "tokenFlowLimit", token.flowLimit);

        uint256[] memory ids = new uint256[](queued.length);
        string[] memory whats = new string[](queued.length);
        for (uint256 i = 0; i < queued.length; ++i) {
            ids[i] = queued[i].id;
            whats[i] = queued[i].what;
        }
        vm.serializeUint(key, "queuedActionIds", ids);
        // The earliest any of them can run. They were all queued in one transaction, so they all
        // mature together.
        vm.serializeUint(key, "queuedEta", block.timestamp + params.timelockDelay);
        string memory out = vm.serializeString(key, "queuedActions", whats);

        string memory path = string.concat("deployments/evm-", vm.toString(block.chainid), "-phase1.json");
        vm.writeJson(out, path);
        console.log("record              ", path);
    }

    function _report(RouterParams memory params) private view {
        console.log("");
        console.log("Phase one done. Nothing is routable yet, which is expected.");
        console.log("Queued actions      ", queued.length);
        console.log("Executable after    ", block.timestamp + params.timelockDelay);
        console.log("");
        console.log("Read the queued actions off the chain before you execute them:");
        console.log("  cast call <router> 'queuedAction(uint64)' <id>");
        console.log("");
        console.log("Then run phase two:");
        console.log("  forge script script/Execute.s.sol --rpc-url $RPC --broadcast");
    }
}
