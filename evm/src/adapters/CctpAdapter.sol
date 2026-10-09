// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin/access/Ownable2Step.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {
    AlreadyConfigured,
    InvalidAmount,
    RailNotConfigured,
    RefundFailed,
    TokenNotMapped,
    Unauthorized,
    UnknownChain,
    ZeroAddress
} from "../TraiectaErrors.sol";
import {AddressKind, Destination, RouteKind} from "../TraiectaTypes.sol";
import {ITokenMessengerV2} from "../interfaces/ICctpV2.sol";
import {IRailAdapter} from "../interfaces/IRailAdapter.sol";
import {StellarAddress} from "../libraries/StellarAddress.sol";
import {HyperionNotes} from "../libraries/TraiectaNotes.sol";

/// @title Hyperion over Circle's CCTP V2
/// @author dotmantissa
/// @notice The rail people actually want when they are moving dollars. USDC is burned here and
/// minted there, natively, with no pool to run thin and no wrapper to unwrap. The cost is the
/// wait: Circle's attestation service has to sign the burn before anything can mint, and asking
/// for finalized rather than fast means waiting for the source chain to finalize too.
///
/// This adapter only sends. That is not a gap, it is the shape of the integration. Going the
/// other way, Stellar to here, the Soroban side sets CCTP's mint recipient to the user's own EVM
/// address and attaches no hook at all, so USDC mints straight into their wallet and Hyperion is
/// not in the path. There is nothing for a contract on this chain to do, so there is no contract.
///
/// Going this way the mint recipient has to be Hyperion's adapter on Stellar instead, because
/// CCTP's recipient field is thirty two flat bytes with nowhere to record whether they name a
/// classic account or a Soroban contract, and on Stellar those are two completely different kinds
/// of delivery. So the recipient names Hyperion over there and the real destination travels in
/// the hook, where there is room to say which of the three kinds it is.
contract CctpAdapter is IRailAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The confirmation level every burn asks Circle for.
    /// @dev Finalized rather than fast. Fast confirmation trades reorg risk for about fifteen
    /// minutes, and it is not this contract's fifteen minutes or its risk.
    uint32 public constant FINALITY_THRESHOLD_FINALIZED = 2000;

    /// @notice The router, and the only address allowed to push anything onto this rail.
    address public immutable ROUTER;

    /// @notice Circle's TokenMessenger on this chain.
    ITokenMessengerV2 public immutable TOKEN_MESSENGER;

    /// @notice The only token CCTP carries.
    address public immutable USDC;

    /// @notice One configured destination.
    struct Lane {
        /// Circle's domain number for the far side. Stellar is 27.
        uint32 domain;
        /// Hyperion's own adapter over there, in CCTP's thirty two byte form.
        bytes32 mintRecipient;
        bool configured;
        bool enabled;
    }

    mapping(string chain => Lane lane) private _lanes;

    /// @notice A destination became reachable.
    event LaneConfigured(string chain, uint32 domain, bytes32 mintRecipient);

    /// @notice A destination was turned on or off.
    event LaneEnabled(string chain, bool enabled);

    /// @notice A burn was handed to Circle.
    event BurnSubmitted(
        string chain, uint32 domain, uint256 amount, bytes32 mintRecipient, uint64 nonce, bytes hookData
    );

    constructor(address router, address tokenMessenger, address usdc, address owner_) Ownable(owner_) {
        if (router == address(0) || tokenMessenger == address(0) || usdc == address(0)) {
            revert ZeroAddress();
        }
        ROUTER = router;
        TOKEN_MESSENGER = ITokenMessengerV2(tokenMessenger);
        USDC = usdc;
    }

    /// @inheritdoc IRailAdapter
    function route() external pure override returns (RouteKind) {
        return RouteKind.Cctp;
    }

    /// @inheritdoc IRailAdapter
    function supportsChain(string calldata chain) external view override returns (bool) {
        Lane storage lane = _lanes[chain];
        return lane.configured && lane.enabled;
    }

    /// @inheritdoc IRailAdapter
    /// @dev Zero, and it will stay zero. CCTP bills nothing at send time and takes its cut, when
    /// there is one, out of the transferred amount on the far side. Asking for finalized puts this
    /// in the tier where there is not one.
    function quoteFee(string calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc IRailAdapter
    function dispatch(address token, uint256 amount, Destination calldata destination, uint64 nonce)
        external
        payable
        override
        returns (bytes32)
    {
        if (msg.sender != ROUTER) revert Unauthorized();
        if (token != USDC) revert TokenNotMapped();
        if (amount == 0) revert InvalidAmount();

        Lane memory lane = _lanes[destination.chain];
        if (!lane.configured) revert UnknownChain();
        if (!lane.enabled) revert RailNotConfigured();

        (AddressKind kind, bytes32 key, uint64 muxedId) = StellarAddress.parse(destination.strkey);
        bytes memory hookData = HyperionNotes.encodeCctpHook(kind, key, muxedId);

        emit BurnSubmitted(destination.chain, lane.domain, amount, lane.mintRecipient, nonce, hookData);

        IERC20(USDC).forceApprove(address(TOKEN_MESSENGER), amount);
        TOKEN_MESSENGER.depositForBurnWithHook(
            amount,
            lane.domain,
            lane.mintRecipient,
            USDC,
            // Left open on purpose. Naming a destination caller would mean a transfer only
            // completes when Hyperion's own key is awake, and a transfer that depends on its
            // operator being awake is not a transfer anybody should rely on.
            bytes32(0),
            // Nothing, because the finalized tier does not charge a transfer fee. A nonzero value
            // here would be money the sender never agreed to spend.
            0,
            FINALITY_THRESHOLD_FINALIZED,
            hookData
        );

        // CCTP wanted no native currency, so none of it is this contract's to keep.
        _refund();

        // Circle does not hand back a handle. The burn is identified by its log on this chain and
        // by the nonce inside the message Circle signs, neither of which is available here, so
        // returning a made up value would be worse than returning none.
        return bytes32(0);
    }

    /// @notice Make a destination reachable.
    /// @dev A lane can be configured once and after that only switched off. Repointing a live
    /// lane's mint recipient would move every future burn on it to a different contract, which is
    /// the same blast radius as swapping the adapter itself, so it is done the same way: deploy
    /// another adapter and let the router's timelock point at it.
    function setLane(string calldata chain, uint32 domain, bytes32 mintRecipient) external onlyOwner {
        if (bytes(chain).length == 0) revert UnknownChain();
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        Lane storage lane = _lanes[chain];
        if (lane.configured) revert AlreadyConfigured();
        lane.domain = domain;
        lane.mintRecipient = mintRecipient;
        lane.configured = true;
        lane.enabled = true;
        emit LaneConfigured(chain, domain, mintRecipient);
        emit LaneEnabled(chain, true);
    }

    /// @notice Turn a configured destination on or off.
    function setLaneEnabled(string calldata chain, bool enabled) external onlyOwner {
        Lane storage lane = _lanes[chain];
        if (!lane.configured) revert RailNotConfigured();
        lane.enabled = enabled;
        emit LaneEnabled(chain, enabled);
    }

    /// @notice Read a configured destination.
    function laneOf(string calldata chain) external view returns (Lane memory) {
        return _lanes[chain];
    }

    /// @dev Adapters hold nothing. Anything sent here goes straight back to the router, which
    /// gives it back to whoever sent the transfer.
    function _refund() private {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        (bool sent,) = payable(ROUTER).call{value: balance}("");
        if (!sent) revert RefundFailed();
    }
}
