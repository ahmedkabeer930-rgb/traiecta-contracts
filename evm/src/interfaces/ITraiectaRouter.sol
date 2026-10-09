// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ActionKind,
    AdminAction,
    Destination,
    Origin,
    OutboundRequest,
    PendingClaim,
    QueuedAction,
    RouteKind,
    RouteQuote,
    TokenConfig
} from "../TraiectaTypes.sol";

/// @title The router, as everything outside it sees it
/// @notice Two entry points carry every transfer. `bridgeOut` is what a person calls, and
/// `bridgeIn` is what a rail's own receiving contract calls once its verifier has already decided
/// the message is real. Hyperion never decides that itself, on either chain, which is the single
/// design decision the rest of this repository is downstream of.
///
/// Everything else here is either a question you can ask before committing money, or an admin
/// action that has to sit in a timelock first.
interface IHyperionRouter {
    /// @notice A transfer left for another chain.
    /// @dev The Soroban router writes a `TransferRecord` to storage as well as emitting, because
    /// Soroban events age out after about a week and an indexer that fell behind has nowhere else
    /// to look. A log on this chain is permanent, so this is the only record and that is enough.
    /// @param route Which rail carried it.
    /// @param sender Who paid.
    /// @param nonce This router's counter for the transfer, and what the far side reads back.
    /// @param token The ERC20 that left.
    /// @param grossAmount What the sender was charged, which is the fee plus the net and can be
    /// less than the amount they asked to send when flooring gave them dust back.
    /// @param fee What Hyperion kept.
    /// @param netAmount What went onto the rail.
    /// @param destinationChain Hyperion's name for where it is headed.
    /// @param destinationAddress The recipient's strkey, as a string, so an indexer never has to
    /// re-encode one to show it.
    /// @param railRef Whatever the rail calls this transfer, or zero if it names it nothing.
    event BridgeOut(
        RouteKind indexed route,
        address indexed sender,
        uint64 indexed nonce,
        address token,
        uint256 grossAmount,
        uint256 fee,
        uint256 netAmount,
        string destinationChain,
        string destinationAddress,
        bytes32 railRef
    );

    /// @notice A transfer arrived and was paid straight through.
    /// @param route Which rail delivered it.
    /// @param recipient Who was paid.
    /// @param token The ERC20 they were paid in.
    /// @param amount How much landed.
    /// @param sourceChain Hyperion's name for where it came from.
    /// @param sourceNonce The far side's counter, which is what joins this to its departure.
    /// @param messageId The rail's own identifier, and the replay key.
    event BridgeIn(
        RouteKind indexed route,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        string sourceChain,
        uint64 sourceNonce,
        bytes32 messageId
    );

    /// @notice A transfer arrived and could not be paid out yet, so the router is holding it.
    /// @dev The money is here and it is theirs. Emitted rather than reverted, because reverting
    /// would send the message back to a rail that has already burned the tokens on the far side.
    /// @param id The claim's id, which is what `settleClaim` takes.
    /// @param recipient Who the money belongs to.
    /// @param token The ERC20 being held.
    /// @param amount How much is being held.
    /// @param route Which rail delivered it.
    /// @param sourceChain Hyperion's name for where it came from.
    /// @param sourceNonce The far side's counter for the departure.
    event ClaimParked(
        uint64 indexed id,
        address indexed recipient,
        address indexed token,
        uint256 amount,
        RouteKind route,
        string sourceChain,
        uint64 sourceNonce
    );

    /// @notice A parked transfer was paid out.
    /// @dev `settledBy` is whoever pressed the button, which does not have to be the recipient.
    /// Anybody can settle somebody else's claim; the money only ever goes to the recipient, so
    /// there is nothing to gain by it and someone watching for stuck transfers can just clear
    /// them.
    /// @param id The claim that was cleared.
    /// @param recipient Who was paid.
    /// @param token The ERC20 they were paid in.
    /// @param amount How much they were paid.
    /// @param settledBy Whoever sent the transaction.
    event ClaimSettled(
        uint64 indexed id, address indexed recipient, address token, uint256 amount, address settledBy
    );

    /// @notice A privileged change was proposed, and the clock started.
    /// @param id The action's id.
    /// @param kind What sort of change it is.
    /// @param eta The earliest timestamp it can be executed at.
    /// @param expiresAt When it stops being executable and has to be queued again.
    event ActionQueued(uint64 indexed id, ActionKind indexed kind, uint64 eta, uint64 expiresAt);

    /// @notice A privileged change waited out its delay and took effect.
    /// @param id The action that was applied.
    /// @param kind What sort of change it was.
    event ActionExecuted(uint64 indexed id, ActionKind indexed kind);

    /// @notice A queued change was dropped before it took effect.
    /// @param id The action that was dropped.
    /// @param by Who dropped it.
    event ActionCancelled(uint64 indexed id, address indexed by);

    /// @notice A token's flow limit was tightened without waiting.
    /// @dev Allowed to skip the timelock precisely because it only ever narrows what the bridge
    /// will do. Raising one is a queued action; lowering one is something you want available at
    /// three in the morning.
    /// @param token The token whose ceiling moved.
    /// @param by Who moved it.
    /// @param limit The new ceiling, which is always lower than the old one.
    event FlowLimitLowered(address indexed token, address indexed by, uint256 limit);

    /// @notice A token became routable, or its parameters changed.
    /// @param token The ERC20.
    /// @param config Its decimals, its ceiling, and whether it is currently enabled.
    event TokenRegistered(address indexed token, TokenConfig config);

    /// @notice A rail was turned on or off for everybody.
    /// @param route The rail.
    /// @param enabled Whether it now accepts departures. Arrivals are never affected.
    event RouteConfigured(RouteKind indexed route, bool enabled);

    /// @notice A rail was paused individually.
    /// @param route Which rail was paused.
    /// @param caller Who paused it.
    event RoutePaused(RouteKind indexed route, address indexed caller);

    /// @notice A rail was unpaused individually.
    /// @param route Which rail was unpaused.
    /// @param caller Who unpaused it.
    event RouteUnpaused(RouteKind indexed route, address indexed caller);

    /// @notice The adapter that speaks for a rail was pointed somewhere else.
    /// @param route The rail.
    /// @param adapter Its new adapter, or zero when the rail was unwired.
    event AdapterSet(RouteKind indexed route, address indexed adapter);

    /// @notice The contract allowed to call `bridgeIn` for a rail was changed.
    /// @param route The rail.
    /// @param receiver The only address that rail's arrivals may come from.
    event RailReceiverSet(RouteKind indexed route, address indexed receiver);

    /// @notice Where the fee goes, or how much of it there is, changed.
    /// @param treasury Where the fee lands.
    /// @param feeBps The fee in basis points, capped at one percent by a constant.
    /// @param timelockDelay How long a queued change now waits, in seconds.
    /// @param flowWindow How long a flow window now runs, in seconds.
    event ConfigChanged(address treasury, uint16 feeBps, uint64 timelockDelay, uint64 flowWindow);

    /// @notice Send `request.amount` of a token to another chain.
    /// @dev Pull, then fee, then floor, then hand off. The fee comes off the raw amount and the
    /// remainder is floored to what the destination can actually represent, in that order, so the
    /// number somebody is quoted is the number that arrives.
    ///
    /// Payable because some rails bill for destination gas at send time. Anything left over is
    /// refunded in the same transaction.
    /// @param request The token, the amount, the rail, the destination, and the least the sender
    /// is willing to see land on the far side.
    /// @return nonce This router's own counter for the transfer, which is also what appears in the
    /// note the far side reads.
    function bridgeOut(OutboundRequest calldata request) external payable returns (uint64 nonce);

    /// @notice Pay out a transfer that arrived over a rail.
    /// @dev Callable only by the contract registered as that rail's receiver, and only after the
    /// rail's own verifier has accepted the message. Hyperion adds a replay guard on top of that
    /// and nothing else: the question of whether the message is genuine was already answered by
    /// somebody with an audit.
    ///
    /// No flow ceiling on this side, deliberately. A limit works by refusing, and refusing an
    /// arrival cannot undo the burn that paid for it, so all a ceiling here would do is strand
    /// somebody's money until an admin raised it. Ceilings belong on departures, where the funds
    /// are still in the sender's wallet and a refusal costs nobody anything.
    /// @param route Which rail this arrival came over.
    /// @param token The ERC20 to pay out.
    /// @param amount How much to pay out, in this chain's decimals for the token.
    /// @param recipient Who to pay.
    /// @param origin The source chain, the far side's nonce, and the rail's message id.
    /// @return claimId Zero when the recipient was paid, or the id of a parked claim when they
    /// could not be.
    function bridgeIn(
        RouteKind route,
        address token,
        uint256 amount,
        address recipient,
        Origin calldata origin
    ) external returns (uint64 claimId);

    /// @notice Pay out a claim the router has been holding.
    /// @dev Permissionless. The funds go to the claim's recipient no matter who calls.
    /// @param claimId The claim to clear.
    function settleClaim(uint64 claimId) external;

    /// @notice What a transfer would cost and whether it would go through, without sending it.
    /// @dev Never reverts for a blocked route. It returns a reason instead, because the app has
    /// to explain the blockage to somebody, and a bare revert gives it nothing to say.
    /// @param route Which rail to price.
    /// @param token The ERC20 being sent.
    /// @param amount The gross amount the sender has in mind.
    /// @param destination Chain name plus the recipient's strkey.
    /// @param destinationDecimals How many decimals the token has on the far side, which the
    /// caller supplies because this chain has no way to read another chain's token.
    /// @return The fee, the net, what lands, the current headroom, and a reason if it is blocked.
    function quote(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuote memory);

    /// @notice Every route's answer for the same transfer, for the side by side view.
    /// @param token The ERC20 being sent.
    /// @param amount The gross amount the sender has in mind.
    /// @param destination Chain name plus the recipient's strkey.
    /// @param destinationDecimals How many decimals the token has on the far side.
    /// @return One quote per rail, in `RouteKind` order, so the index is the route.
    function quoteAll(
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuote[] memory);

    /// @notice Propose a privileged change and start its clock.
    /// @param action What to change, and to what.
    /// @return id The action's id, which `executeAction` and `cancelAction` take.
    function queueAction(AdminAction calldata action) external returns (uint64 id);

    /// @notice Apply a proposed change that has waited long enough and has not expired.
    /// @param id The action to apply.
    function executeAction(uint64 id) external;

    /// @notice Drop a proposed change.
    /// @param id The action to drop.
    function cancelAction(uint64 id) external;

    /// @notice Tighten a token's flow limit immediately.
    /// @param token The token to tighten.
    /// @param limit The new ceiling, which has to be below the one in force.
    function lowerTokenFlowLimit(address token, uint256 limit) external;

    /// @notice Pause departures for a single rail without affecting other rails.
    /// @param route The rail to pause.
    function pauseRoute(RouteKind route) external;

    /// @notice Resume departures for an individually paused rail.
    /// @param route The rail to unpause.
    function unpauseRoute(RouteKind route) external;

    /// @notice Read a queued change.
    /// @param id The action to read.
    /// @return The action, its timestamps, and whether it has already been executed.
    function queuedAction(uint64 id) external view returns (QueuedAction memory);

    /// @notice Read a parked claim.
    /// @param id The claim to read.
    /// @return The recipient, the token, the amount, and where it came from.
    function pendingClaim(uint64 id) external view returns (PendingClaim memory);

    /// @notice Read a token's parameters.
    /// @param token The ERC20 to read.
    /// @return Its decimals, its ceiling, and whether it is registered and enabled.
    function tokenConfig(address token) external view returns (TokenConfig memory);

    /// @notice How much more of a token may move over a rail in this window.
    /// @param token The ERC20 to read.
    /// @param route The rail to read it for, since each rail has its own ceiling.
    /// @return The remaining headroom, which decays as the window slides rather than resetting.
    function flowAvailable(address token, RouteKind route) external view returns (uint256);

    /// @notice The adapter registered for a rail, or zero.
    /// @param route The rail to read.
    /// @return Its adapter, or the zero address when the rail has not been wired up.
    function adapter(RouteKind route) external view returns (address);

    /// @notice Whether an individual rail is currently paused for departures.
    /// @param route The rail to check.
    /// @return True if the rail is paused.
    function routePaused(RouteKind route) external view returns (bool);
}
