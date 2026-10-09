// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {RouteKind} from "../src/TraiectaTypes.sol";

/// @title Everything a deployment needs to know that is not in the source tree
/// @notice Read from the environment, never from a constant in here, with one exception noted
/// below. A deploy script with addresses baked in is a deploy script that works on one chain and
/// quietly does the wrong thing on the next one, and the wrong thing on a bridge is funds sent to
/// a contract that is not the one anybody meant.
///
/// Every variable is read by name and the read fails loudly when it is missing. Foundry's
/// `envAddress` reverts on an unset key, which is the behaviour this wants: a missing
/// `CCTP_TOKEN_MESSENGER` should stop the deployment, not deploy an adapter pointed at the zero
/// address that reverts on first use.
abstract contract DeployConfig is Script {
    /// @dev The one hard coded value, and only because Circle assigned it rather than deployed it.
    /// Stellar is domain twenty seven on CCTP. It is not a chain id, not derived from one, and not
    /// configurable, so putting it in the environment would only create a way to get it wrong.
    uint32 internal constant STELLAR_CCTP_DOMAIN = 27;

    /// @dev Hyperion's own name for the Stellar network, which is what the adapters key lanes and
    /// peers on. Lowercase and stable, matching the `ChainKey` union in the protocol package.
    string internal constant STELLAR_CHAIN = "stellar";
    string internal constant STELLAR_TESTNET_CHAIN = "stellar-testnet";

    struct RouterParams {
        address admin;
        address guardian;
        address treasury;
        uint16 feeBps;
        uint64 timelockDelay;
        uint64 flowWindow;
    }

    struct RailParams {
        /// Circle's TokenMessengerV2 on this chain. Burns on the way out, mints on the way in.
        address cctpTokenMessenger;
        /// Circle's MessageTransmitterV2. The contract whose signature check is the trust root.
        address cctpMessageTransmitter;
        /// Axelar's Interchain Token Service, or zero to skip the Axelar adapter entirely.
        address axelarIts;
        /// Axelar's gas service. Required when `axelarIts` is set.
        address axelarGasService;
    }

    struct TokenParams {
        address token;
        uint8 decimals;
        uint256 flowLimit;
        string symbol;
    }

    /// @notice Who holds which key, and the three numbers that shape the router's behaviour.
    /// @dev `DEPLOYER_ADDRESS` is deliberately separate from the admin. On a real deployment the
    /// admin is a multisig that cannot run a script, and the deployer is a hot key that should
    /// hold nothing afterwards. On a local chain they are the same account and that is fine.
    function routerParams() internal view returns (RouterParams memory params) {
        params = RouterParams({
            admin: vm.envAddress("HYPERION_ADMIN"),
            guardian: vm.envOr("HYPERION_GUARDIAN", address(0)),
            treasury: vm.envAddress("HYPERION_TREASURY"),
            // Thirty basis points unless told otherwise. The ceiling in `AmountMath` is a
            // hundred, and the constructor checks it, so a fat finger here fails at deploy.
            feeBps: uint16(vm.envOr("HYPERION_FEE_BPS", uint256(30))),
            // Twenty four hours. Long enough that somebody reading the chain has a working day to
            // object, short enough that a genuine fix is not a week away. The contract floor is
            // one hour.
            timelockDelay: uint64(vm.envOr("HYPERION_TIMELOCK_DELAY", uint256(24 hours))),
            // One hour of flow accounting. Sliding, not calendar, so this is a window length
            // rather than a reset time.
            flowWindow: uint64(vm.envOr("HYPERION_FLOW_WINDOW", uint256(1 hours)))
        });
    }

    function railParams() internal view returns (RailParams memory params) {
        params = RailParams({
            cctpTokenMessenger: vm.envAddress("CCTP_TOKEN_MESSENGER"),
            cctpMessageTransmitter: vm.envAddress("CCTP_MESSAGE_TRANSMITTER"),
            axelarIts: vm.envOr("AXELAR_ITS", address(0)),
            axelarGasService: vm.envOr("AXELAR_GAS_SERVICE", address(0))
        });
    }

    /// @notice The asset this deployment routes, and the ceiling it routes under.
    /// @dev One token per run on purpose. Registering a second is a queued action against a live
    /// router, which is a different operation with a different review, and pretending otherwise
    /// by looping here would hide that.
    function tokenParams() internal view returns (TokenParams memory params) {
        params = TokenParams({
            token: vm.envAddress("HYPERION_TOKEN"),
            decimals: uint8(vm.envUint("HYPERION_TOKEN_DECIMALS")),
            flowLimit: vm.envUint("HYPERION_TOKEN_FLOW_LIMIT"),
            symbol: vm.envOr("HYPERION_TOKEN_SYMBOL", string("USDC"))
        });
    }

    /// @notice Hyperion's name for the Stellar network this chain is paired with.
    function stellarChain() internal view returns (string memory) {
        return vm.envOr("HYPERION_STELLAR_CHAIN", string(STELLAR_TESTNET_CHAIN));
    }

    /// @notice Axelar's own name for the Stellar network, which is not always Hyperion's name.
    /// @dev No default. The adapter stores whatever string it is given and compares inbound
    /// deliveries against it, so a plausible guess here is a peer check that passes for the wrong
    /// contract. If Axelar is being wired up, this has to be stated.
    function axelarStellarChain() internal view returns (string memory) {
        return vm.envString("AXELAR_STELLAR_CHAIN");
    }

    /// @notice Hyperion's router on Stellar, as the thirty two bytes a rail puts on the wire.
    /// @dev A Soroban contract id. CCTP's mint recipient slot is thirty two bytes with no room for
    /// a kind tag, which is why the destination the recipient actually wanted travels in the hook
    /// instead and this slot names the adapter.
    function stellarRailRecipient() internal view returns (bytes32) {
        return vm.envBytes32("STELLAR_RAIL_RECIPIENT");
    }

    /// @notice Hyperion's Axelar adapter on Stellar, in the form that chain's ITS puts on the wire.
    function stellarAxelarPeer() internal view returns (bytes memory) {
        return vm.envBytes("STELLAR_AXELAR_PEER");
    }

    /// @notice The ITS token id this chain's asset is registered under.
    /// @dev The same value on every chain ITS connects, which is the whole point of an id. The
    /// adapter asks ITS whether the id really does belong to this token before storing it, so a
    /// typo fails at configuration rather than at delivery.
    function axelarTokenId() internal view returns (bytes32) {
        return vm.envBytes32("AXELAR_TOKEN_ID");
    }

    /// @notice Which rails this run wires up.
    function wiresAxelar() internal view returns (bool) {
        RailParams memory rails = railParams();
        return rails.axelarIts != address(0) && rails.axelarGasService != address(0);
    }

    /// @dev `RouteKind` as the integer that goes in a filename or a JSON key.
    function routeSlug(RouteKind route) internal pure returns (string memory) {
        if (route == RouteKind.Cctp) return "cctp";
        if (route == RouteKind.AxelarIts) return "axelar-its";
        if (route == RouteKind.AxelarGmp) return "axelar-gmp";
        return "allbridge";
    }
}
