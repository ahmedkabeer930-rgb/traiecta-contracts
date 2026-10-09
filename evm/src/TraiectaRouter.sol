// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "openzeppelin/access/AccessControl.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

import {
    ActionFieldNotEmpty,
    AdapterNotSet,
    AmountNotRepresentable,
    ClaimAlreadySettled,
    ClaimNotFound,
    FeeTooHigh,
    InvalidAmount,
    InvalidDecimals,
    InvalidLimit,
    InvalidWindow,
    LimitNotRaised,
    MuxedNotSupported,
    NotRailReceiver,
    RecipientNotReady,
    RefundFailed,
    ReplayedMessage,
    RouteDisabled,
    RouteIsPaused,
    SlippageExceeded,
    TimelockAlreadyExecuted,
    TimelockDelayOutOfRange,
    TimelockExpired,
    TimelockNotQueued,
    TimelockNotReady,
    TokenDisabled,
    TokenNotRegistered,
    Unauthorized,
    UnknownChain,
    ZeroAddress
} from "./TraiectaErrors.sol";
import {
    ActionKind,
    AddressKind,
    AdminAction,
    Destination,
    Origin,
    OutboundRequest,
    PendingClaim,
    QueuedAction,
    QuoteBlocker,
    RouteKind,
    RouteQuote,
    TokenConfig
} from "./TraiectaTypes.sol";
import {IRailAdapter} from "./interfaces/IRailAdapter.sol";
import {IHyperionRouter} from "./interfaces/ITraiectaRouter.sol";
import {AmountMath} from "./libraries/AmountMath.sol";
import {FlowGuard, FlowWindow} from "./libraries/FlowGuard.sol";
import {RouteMeta} from "./libraries/RouteMeta.sol";
import {StellarAddress} from "./libraries/StellarAddress.sol";

/// @title Hyperion, the EVM side
/// @author dotmantissa
/// @notice Hyperion is a router, not a bridge, and the difference is the only thing that matters
/// about it. It never decides whether a cross-chain message is genuine. Circle's attestation
/// service decides that for CCTP, Axelar's validator set decides it for ITS, and Hyperion sits
/// downstream of whichever one is carrying a given transfer, doing the things a rail does not do
/// for you: quoting the four of them side by side, taking a fee it declared up front, keeping a
/// ceiling on how much can move in an hour, and catching funds that arrive for somebody who
/// cannot receive them yet.
///
/// `bridgeIn` is the whole argument in one function. It is callable by exactly one address per
/// rail, that address is the rail's own receiving contract, and it is checked with an equality
/// rather than a role, because there is one right answer per rail and anything looser than one
/// right answer is a mint function with extra steps.
///
/// Everything privileged waits out a timelock, and the two exceptions both only ever make the
/// bridge do less: pausing departures, and lowering a flow limit. Nobody should have to file a
/// change request to slow an exploit down.
contract HyperionRouter is IHyperionRouter, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FlowGuard for FlowWindow;

    /// @notice May pause departures and tighten flow limits, and nothing else.
    /// @dev Deliberately not an admin. The point of a guardian is that you can hand the key to a
    /// monitoring job or a second person without also handing them the treasury, so every power
    /// it has is one that narrows what the bridge will do.
    bytes32 public constant GUARDIAN_ROLE = keccak256("hyperion.guardian");

    /// @notice The shortest delay an admin change can be queued for.
    /// @dev An hour is long enough that somebody watching will see a change land, and short
    /// enough that a genuine incident response is not waiting out a weekend.
    uint64 public constant MIN_TIMELOCK_DELAY = 1 hours;

    /// @notice The longest delay an admin change can be queued for.
    uint64 public constant MAX_TIMELOCK_DELAY = 30 days;

    /// @notice How long a matured action stays executable before it expires.
    /// @dev A change approved in March and executed in November is a change nobody reviewed.
    uint64 public constant GRACE_PERIOD = 7 days;

    /// @notice The shortest flow window a limit can be measured over, in seconds.
    uint64 public constant MIN_FLOW_WINDOW = 5 minutes;

    /// @notice The longest flow window a limit can be measured over, in seconds.
    uint64 public constant MAX_FLOW_WINDOW = 7 days;

    /// @notice Where the fee goes.
    address public treasury;

    /// @notice The fee, in basis points, charged on the outbound leg only.
    uint16 public feeBps;

    /// @notice How long a privileged change has to wait before it may be applied.
    uint64 public timelockDelay;

    /// @notice How long a flow window runs, in seconds.
    uint64 public flowWindow;

    /// @notice This router's own counter for outbound transfers.
    uint64 public outboundNonce;

    uint64 private _claimCount;
    uint64 private _actionCount;

    mapping(RouteKind route => address adapterAddress) private _adapters;
    mapping(RouteKind route => address receiver) private _railReceivers;
    /// @notice Whether a rail is open for new transfers. Deliveries already in flight are not
    /// affected, because a transfer that has left is a transfer that has to be able to land.
    mapping(RouteKind route => bool enabled) public routeEnabled;
    /// @notice Whether an individual rail is currently paused for departures.
    mapping(RouteKind route => bool paused) public routePaused;
    mapping(address token => TokenConfig config) private _tokens;

    /// @dev Keyed on token and rail together, because a ceiling that makes sense for the rail
    /// carrying native USDC makes no sense for the one carrying a pooled representation of it.
    mapping(bytes32 tokenAndRoute => uint256 limit) private _routeFlowLimit;
    mapping(bytes32 tokenAndRoute => bool isSet) private _routeFlowLimitSet;
    mapping(bytes32 tokenAndRoute => FlowWindow window) private _flow;

    /// @notice Whether a rail message has already been delivered, keyed on rail and message id.
    /// @dev Keyed on the rail's own message id at full width. Squeezing a thirty two byte
    /// identifier into something smaller to save a slot is how two unrelated messages end up
    /// sharing a replay key, and the cheaper of those two deliveries is the one an attacker picks.
    mapping(bytes32 railAndMessage => bool seen) public processed;

    /// @dev What `bridgeOut` worked out before it moved anything, carried between the three
    /// halves of it in memory rather than on the stack.
    struct OutboundPlan {
        uint256 fee;
        uint256 net;
        uint256 gross;
        address adapterAddress;
    }

    mapping(uint64 claimId => PendingClaim claim) private _claims;
    mapping(uint64 actionId => QueuedAction queued) private _actions;

    /// @param admin Holds every privileged power, all of them behind the timelock.
    /// @notice Wires up the router with its roles, its treasury, and its fee and timing limits.
    /// @param admin Holds every role that can widen what the bridge will do.
    /// @param guardian_ Holds the two that only ever make the bridge do less.
    /// @param treasury_ Where the fee lands.
    /// @param feeBps_ The fee, capped at one percent by a constant no path can raise.
    /// @param timelockDelay_ How long changes wait.
    /// @param flowWindow_ How long a flow window runs, in seconds.
    constructor(
        address admin,
        address guardian_,
        address treasury_,
        uint16 feeBps_,
        uint64 timelockDelay_,
        uint64 flowWindow_
    ) {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > AmountMath.MAX_FEE_BPS) revert FeeTooHigh();
        if (timelockDelay_ < MIN_TIMELOCK_DELAY || timelockDelay_ > MAX_TIMELOCK_DELAY) {
            revert TimelockDelayOutOfRange();
        }
        if (flowWindow_ < MIN_FLOW_WINDOW || flowWindow_ > MAX_FLOW_WINDOW) revert InvalidWindow();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian_ != address(0)) _grantRole(GUARDIAN_ROLE, guardian_);

        treasury = treasury_;
        feeBps = feeBps_;
        timelockDelay = timelockDelay_;
        flowWindow = flowWindow_;
        emit ConfigChanged(treasury_, feeBps_, timelockDelay_, flowWindow_);
    }

    /// @notice Accepts the native currency an adapter did not spend.
    /// @dev Adapters hand back whatever native currency the rail did not want. Without this the
    /// refund at the end of `bridgeOut` would have nothing to refund.
    receive() external payable {}

    // -------------------------------------------------------------------------------------
    // Outbound
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    /// @dev The order is fee, then floor, then hand off, and it is not interchangeable. Taking
    /// the fee on the raw amount and flooring the remainder means the sender is charged for the
    /// amount that actually crosses plus the declared fee, and nothing else. Flooring first would
    /// quietly charge a fee on dust that never left.
    ///
    /// Split across three functions because the arithmetic and the money movement do not belong
    /// in the same twenty lines, and because the EVM only lets sixteen things be reachable on the
    /// stack at once and this function wants more than that.
    function bridgeOut(OutboundRequest calldata request)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (uint64 nonce)
    {
        OutboundPlan memory plan = _planOutbound(request);

        IERC20 token = IERC20(request.token);
        token.safeTransferFrom(msg.sender, address(this), plan.gross);
        if (plan.fee != 0) token.safeTransfer(treasury, plan.fee);
        token.safeTransfer(plan.adapterAddress, plan.net);

        nonce = ++outboundNonce;

        uint256 balanceBefore = address(this).balance - msg.value;
        bytes32 railRef = IRailAdapter(plan.adapterAddress).dispatch{value: msg.value}(
            request.token, plan.net, request.destination, nonce
        );

        _announceOutbound(request, plan, nonce, railRef);

        // Rails quote destination gas optimistically and refund the difference. Keeping it would
        // be a second, undeclared fee that moves with a gas market the sender never looked at.
        uint256 leftover = address(this).balance - balanceBefore;
        if (leftover != 0) {
            (bool sent,) = payable(msg.sender).call{value: leftover}("");
            if (!sent) revert RefundFailed();
        }
    }

    /// @dev Everything that has to be true before any money moves, and the numbers that come out
    /// of it. Charges the flow limit, because a check that does not write is a check two
    /// transactions in the same block both pass.
    function _planOutbound(OutboundRequest calldata request) private returns (OutboundPlan memory plan) {
        if (request.amount == 0) revert InvalidAmount();
        if (routePaused[request.route]) revert RouteIsPaused(request.route);
        if (!routeEnabled[request.route]) revert RouteDisabled();
        if (bytes(request.destination.chain).length == 0) revert UnknownChain();

        (AddressKind kind,,) = StellarAddress.parse(request.destination.strkey);
        if (kind == AddressKind.MuxedAccount && !RouteMeta.carriesPayload(request.route)) {
            revert MuxedNotSupported();
        }

        TokenConfig memory cfg = _tokens[request.token];
        if (!cfg.registered) revert TokenNotRegistered();
        if (!cfg.enabled) revert TokenDisabled();

        (uint256 netRaw, uint256 fee) = AmountMath.applyFee(request.amount, feeBps);
        uint256 net = AmountMath.floorToRepresentable(netRaw, cfg.decimals, request.destinationDecimals);
        if (net == 0) revert AmountNotRepresentable();

        uint256 landing = AmountMath.convertDecimalsExact(net, cfg.decimals, request.destinationDecimals);
        if (landing < request.minDestinationAmount) {
            revert SlippageExceeded(request.minDestinationAmount, landing);
        }

        // The flow limit is charged against what crosses, not against what the sender handed
        // over. The fee never leaves this chain, so it is not cross-chain exposure and counting
        // it would tighten the limit by a number nobody picked.
        _consumeFlow(request.token, request.route, net);

        address adapterAddress = _adapters[request.route];
        if (adapterAddress == address(0)) revert AdapterNotSet();

        plan = OutboundPlan({fee: fee, net: net, gross: fee + net, adapterAddress: adapterAddress});
    }

    /// @dev The log is the only record this chain keeps of a departure, so it carries every field
    /// an indexer would otherwise have to reconstruct from three separate calls.
    function _announceOutbound(
        OutboundRequest calldata request,
        OutboundPlan memory plan,
        uint64 nonce,
        bytes32 railRef
    ) private {
        emit BridgeOut(
            request.route,
            msg.sender,
            nonce,
            request.token,
            plan.gross,
            plan.fee,
            plan.net,
            request.destination.chain,
            request.destination.strkey,
            railRef
        );
    }

    // -------------------------------------------------------------------------------------
    // Inbound
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    /// @dev Pause does not appear here, and that is deliberate. Once a rail has attested a
    /// message the counterpart is already burned on the far side, so refusing it on this side
    /// does not undo anything, it only strands somebody's money. Pausing stops departures.
    function bridgeIn(
        RouteKind route,
        address token,
        uint256 amount,
        address recipient,
        Origin calldata origin
    ) external override nonReentrant returns (uint64 claimId) {
        address expected = _railReceivers[route];
        if (expected == address(0)) revert AdapterNotSet();
        if (msg.sender != expected) revert NotRailReceiver();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();

        bytes32 replayKey = keccak256(abi.encode(route, origin.messageId));
        if (processed[replayKey]) revert ReplayedMessage();
        processed[replayKey] = true;

        // Pull rather than trust. The receiver approves this transfer before calling in, so if
        // the funds are not actually here the delivery reverts now instead of writing down a
        // claim against money nobody holds.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        if (_tryPay(token, recipient, amount)) {
            emit BridgeIn(route, recipient, token, amount, origin.chain, origin.nonce, origin.messageId);
            return 0;
        }

        claimId = ++_claimCount;
        _claims[claimId] = PendingClaim({
            id: claimId,
            recipient: recipient,
            token: token,
            amount: amount,
            route: route,
            sourceChain: origin.chain,
            sourceNonce: origin.nonce,
            createdAt: uint64(block.timestamp),
            settled: false
        });
        emit ClaimParked(claimId, recipient, token, amount, route, origin.chain, origin.nonce);
        emit BridgeIn(route, recipient, token, amount, origin.chain, origin.nonce, origin.messageId);
    }

    /// @inheritdoc IHyperionRouter
    function settleClaim(uint64 claimId) external override nonReentrant {
        PendingClaim storage claim = _claims[claimId];
        if (claim.id == 0) revert ClaimNotFound();
        if (claim.settled) revert ClaimAlreadySettled();

        claim.settled = true;
        if (!_tryPay(claim.token, claim.recipient, claim.amount)) revert RecipientNotReady();
        emit ClaimSettled(claimId, claim.recipient, claim.token, claim.amount, msg.sender);
    }

    // -------------------------------------------------------------------------------------
    // Quoting
    // -------------------------------------------------------------------------------------

    /// @notice The half of a quote that the amount has nothing to do with: whether the rail is
    /// open, whether it recognises the chain, and whether it can deliver to this kind of address.
    /// @dev Split out from `quote` because the two halves fail for unrelated reasons, and a
    /// ladder read interleaved with arithmetic is a ladder somebody reorders without noticing.
    /// @param route The rail being priced.
    /// @param destination Where the transfer is headed.
    /// @return The first reason this rail cannot carry the transfer, or `None`.
    function _quoteRailBlocker(RouteKind route, Destination calldata destination)
        private
        view
        returns (QuoteBlocker)
    {
        if (paused() || routePaused[route]) return QuoteBlocker.Paused;
        if (!routeEnabled[route]) return QuoteBlocker.RouteDisabled;

        address adapterAddress = _adapters[route];
        if (adapterAddress == address(0)) return QuoteBlocker.AdapterNotSet;

        AddressKind kind;
        // A bad strkey is a typo, not an exception. The app has to put something on the screen,
        // and a bare revert gives it nothing to say.
        try this.checkDestination(destination.strkey) returns (AddressKind parsed, bytes32, uint64) {
            kind = parsed;
        } catch {
            return QuoteBlocker.InvalidDestination;
        }
        if (kind == AddressKind.MuxedAccount && !RouteMeta.carriesPayload(route)) {
            return QuoteBlocker.MuxedNotSupported;
        }

        try IRailAdapter(adapterAddress).supportsChain(destination.chain) returns (bool ok) {
            if (!ok) return QuoteBlocker.ChainNotSupported;
        } catch {
            return QuoteBlocker.ChainNotSupported;
        }

        return QuoteBlocker.None;
    }

    /// @inheritdoc IHyperionRouter
    function quote(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) public view override returns (RouteQuote memory) {
        RouteQuote memory q;
        q.route = route;
        q.grossAmount = amount;
        q.waitsOnAttestation = RouteMeta.waitsOnAttestation(route);
        q.isCanonical = RouteMeta.isCanonical(route);

        QuoteBlocker blocker = _quoteRailBlocker(route, destination);
        if (blocker != QuoteBlocker.None) return _blocked(q, blocker);

        TokenConfig memory cfg = _tokens[token];
        if (!cfg.registered) return _blocked(q, QuoteBlocker.TokenNotRegistered);
        if (!cfg.enabled) return _blocked(q, QuoteBlocker.TokenDisabled);

        if (amount == 0) return _blocked(q, QuoteBlocker.AmountTooSmall);

        // Nothing past this is a transfer anybody is attempting, and the arithmetic below would
        // panic rather than answer. Promising never to revert is the whole value of this
        // function: it is what lets an app render four rows without wrapping each one in a try,
        // so even the absurd question gets a reason back. The bound is chosen so that the fee
        // multiply and a widening of up to thirty eight decimal places both stay inside a word.
        if (amount > type(uint128).max) return _blocked(q, QuoteBlocker.NotRepresentable);

        uint256 fee = (amount * feeBps) / AmountMath.BPS_DENOMINATOR;
        uint256 netRaw = amount - fee;
        // Only reachable if `MAX_FEE_BPS` were ever raised to ten thousand, the same way the
        // matching guard in `AmountMath.applyFee` is. Kept for the same reason: the invariant
        // worth stating is "a transfer always delivers something", not "today's constants
        // happen to make that true".
        if (netRaw == 0) return _blocked(q, QuoteBlocker.AmountTooSmall);
        if (cfg.decimals > AmountMath.MAX_DECIMALS || destinationDecimals > AmountMath.MAX_DECIMALS) {
            return _blocked(q, QuoteBlocker.NotRepresentable);
        }

        uint256 net = AmountMath.floorToRepresentable(netRaw, cfg.decimals, destinationDecimals);
        if (net == 0) return _blocked(q, QuoteBlocker.NotRepresentable);

        uint256 headroom = flowAvailable(token, route);
        q.flowAvailable = headroom;
        if (net > headroom) return _blocked(q, QuoteBlocker.FlowLimitExceeded);

        (uint256 landing,) = AmountMath.convertDecimals(net, cfg.decimals, destinationDecimals);
        q.available = true;
        q.reason = QuoteBlocker.None;
        q.fee = fee;
        q.netAmount = net;
        q.grossAmount = fee + net;
        q.destinationAmount = landing;
        return q;
    }

    /// @inheritdoc IHyperionRouter
    function quoteAll(
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view override returns (RouteQuote[] memory quotes) {
        quotes = new RouteQuote[](4);
        for (uint256 i = 0; i < 4; ++i) {
            quotes[i] = quote(RouteKind(i), token, amount, destination, destinationDecimals);
        }
    }

    /// @notice Take a Stellar address apart and say whether it holds together.
    /// @dev External so `quote` can reach it inside a try, and public because an app that can ask
    /// this over `eth_call` never has to ship its own base32 decoder and hope it agrees with this
    /// one. Reverts on anything it does not like, which is the point.
    function checkDestination(string calldata strkey)
        external
        pure
        returns (AddressKind kind, bytes32 key, uint64 muxedId)
    {
        return StellarAddress.parse(strkey);
    }

    // -------------------------------------------------------------------------------------
    // The two powers that do not wait
    // -------------------------------------------------------------------------------------

    /// @notice Stop new departures.
    /// @dev Guardian or admin. Arrivals keep working, because the money for those is already
    /// committed elsewhere.
    function pause() external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _pause();
    }

    /// @notice Start them again.
    /// @dev Admin only. Stopping should be easy and starting again should not, because one of
    /// those two decisions is reversible and the other is the one that gets made at four in the
    /// morning by somebody who wants the alert to go away.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Guardian or admin. Other rails and arrivals keep working.
    function pauseRoute(RouteKind route) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        routePaused[route] = true;
        emit RoutePaused(route, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Guardian or admin.
    function unpauseRoute(RouteKind route) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        routePaused[route] = false;
        emit RouteUnpaused(route, msg.sender);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev No timelock, because it only ever narrows. Raising one is a queued action.
    function lowerTokenFlowLimit(address token, uint256 limit) external override {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        TokenConfig storage cfg = _tokens[token];
        if (!cfg.registered) revert TokenNotRegistered();
        if (limit >= cfg.flowLimit) revert LimitNotRaised();
        cfg.flowLimit = limit;
        emit FlowLimitLowered(token, msg.sender, limit);
        emit TokenRegistered(token, cfg);
    }

    // -------------------------------------------------------------------------------------
    // Everything else, on a clock
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    function queueAction(AdminAction calldata action)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (uint64 id)
    {
        _validateAction(action);
        id = ++_actionCount;
        uint64 eta = uint64(block.timestamp) + timelockDelay;
        uint64 expiresAt = eta + GRACE_PERIOD;
        _actions[id] = QueuedAction({
            id: id,
            action: action,
            queuedAt: uint64(block.timestamp),
            eta: eta,
            expiresAt: expiresAt,
            executed: false
        });
        emit ActionQueued(id, action.kind, eta, expiresAt);
    }

    /// @inheritdoc IHyperionRouter
    function executeAction(uint64 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        QueuedAction storage queued = _actions[id];
        if (queued.id == 0) revert TimelockNotQueued();
        if (queued.executed) revert TimelockAlreadyExecuted();
        if (block.timestamp < queued.eta) revert TimelockNotReady(queued.eta);
        if (block.timestamp > queued.expiresAt) revert TimelockExpired(queued.expiresAt);

        queued.executed = true;
        AdminAction memory action = queued.action;
        // Re-checked on the way out as well as the way in. The bounds a change was measured
        // against can move while it waits, and an action queued under one ceiling should not land
        // under another.
        _validateAction(action);
        _applyAction(action);
        emit ActionExecuted(id, action.kind);
    }

    /// @inheritdoc IHyperionRouter
    /// @dev Guardian can cancel as well as admin. Somebody who can only stop things should be
    /// able to stop a queued change they think is a mistake.
    function cancelAction(uint64 id) external override {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        QueuedAction storage queued = _actions[id];
        if (queued.id == 0) revert TimelockNotQueued();
        if (queued.executed) revert TimelockAlreadyExecuted();
        delete _actions[id];
        emit ActionCancelled(id, msg.sender);
    }

    /// @notice Role changes go through the timelock like everything else.
    /// @dev Overridden to revert, because inheriting `AccessControl` as it comes would leave an
    /// admin able to grant a second admin in one transaction and make the timelock decorative.
    function grantRole(bytes32, address) public pure override {
        revert Unauthorized();
    }

    /// @notice Role changes go through the timelock like everything else.
    function revokeRole(bytes32, address) public pure override {
        revert Unauthorized();
    }

    // -------------------------------------------------------------------------------------
    // Reading
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IHyperionRouter
    function queuedAction(uint64 id) external view override returns (QueuedAction memory) {
        return _actions[id];
    }

    /// @inheritdoc IHyperionRouter
    function pendingClaim(uint64 id) external view override returns (PendingClaim memory) {
        return _claims[id];
    }

    /// @inheritdoc IHyperionRouter
    function tokenConfig(address token) external view override returns (TokenConfig memory) {
        return _tokens[token];
    }

    /// @inheritdoc IHyperionRouter
    function adapter(RouteKind route) external view override returns (address) {
        return _adapters[route];
    }

    /// @notice The contract allowed to call `bridgeIn` for a rail.
    function railReceiver(RouteKind route) external view returns (address) {
        return _railReceivers[route];
    }

    /// @inheritdoc IHyperionRouter
    function flowAvailable(address token, RouteKind route) public view override returns (uint256) {
        bytes32 key = _flowKey(token, route);
        return _flow[key].available(_effectiveFlowLimit(token, route), uint64(block.timestamp), flowWindow);
    }

    /// @notice How many claims have been parked since deployment.
    function claimCount() external view returns (uint64) {
        return _claimCount;
    }

    /// @notice How many privileged changes have been queued since deployment.
    function actionCount() external view returns (uint64) {
        return _actionCount;
    }

    // -------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------

    function _flowKey(address token, RouteKind route) private pure returns (bytes32) {
        return keccak256(abi.encode(token, route));
    }

    function _effectiveFlowLimit(address token, RouteKind route) private view returns (uint256) {
        bytes32 key = _flowKey(token, route);
        if (_routeFlowLimitSet[key]) return _routeFlowLimit[key];
        return _tokens[token].flowLimit;
    }

    function _consumeFlow(address token, RouteKind route, uint256 amount) private {
        bytes32 key = _flowKey(token, route);
        _flow[key] = _flow[key].consume(
            _effectiveFlowLimit(token, route), amount, uint64(block.timestamp), flowWindow
        );
    }

    /// @dev Pay out without letting a refusal take the whole delivery down with it.
    ///
    /// A token can decline a transfer for reasons that have nothing to do with Hyperion: USDC
    /// freezes accounts, and a frozen recipient must not be able to wedge a message the rail has
    /// already attested. So the result is a boolean and the caller decides what to do with it.
    ///
    /// Tokens are registered by an admin, so a deliberately hostile one is not in the threat
    /// model here, but a merely badly behaved one is: this tolerates the ones that return nothing
    /// at all as well as the ones that return a bool.
    function _tryPay(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return true;
        if (ret.length < 32) return false;
        return abi.decode(ret, (bool));
    }

    function _blocked(RouteQuote memory q, QuoteBlocker reason) private pure returns (RouteQuote memory) {
        q.available = false;
        q.reason = reason;
        return q;
    }

    /// @dev Every field a kind does not use has to be empty.
    ///
    /// A timelock only does its job if somebody can read a pending change and understand it. A
    /// struct with a spare field carrying a value nothing validates is a change that reads one
    /// way to a reviewer and another way to the code, so the unused fields are checked rather
    /// than ignored. `RouteKind` has no unset value, so `Cctp` doubles as one where a kind has
    /// nothing to do with a rail.
    function _validateAction(AdminAction memory action) private view {
        ActionKind kind = action.kind;

        bool usesRoute = kind == ActionKind.SetAdapter || kind == ActionKind.SetRailReceiver
            || kind == ActionKind.EnableRoute || kind == ActionKind.SetRouteFlowLimit;
        bool usesSubject = kind == ActionKind.SetTreasury || kind == ActionKind.SetAdmin
            || kind == ActionKind.SetGuardian || kind == ActionKind.SetAdapter
            || kind == ActionKind.SetRailReceiver || kind == ActionKind.RegisterToken
            || kind == ActionKind.RaiseTokenFlowLimit || kind == ActionKind.SetRouteFlowLimit
            || kind == ActionKind.SetTokenEnabled;
        bool usesAmount = kind == ActionKind.SetFeeBps || kind == ActionKind.EnableRoute
            || kind == ActionKind.RegisterToken || kind == ActionKind.RaiseTokenFlowLimit
            || kind == ActionKind.SetRouteFlowLimit || kind == ActionKind.SetTimelockDelay
            || kind == ActionKind.SetFlowWindow || kind == ActionKind.SetTokenEnabled;
        bool usesDecimals = kind == ActionKind.RegisterToken;

        if (!usesRoute && action.route != RouteKind.Cctp) revert ActionFieldNotEmpty();
        if (!usesSubject && action.subject != address(0)) revert ActionFieldNotEmpty();
        if (!usesAmount && action.amount != 0) revert ActionFieldNotEmpty();
        if (!usesDecimals && action.decimals != 0) revert ActionFieldNotEmpty();
        if (usesSubject && action.subject == address(0)) revert ZeroAddress();

        if (kind == ActionKind.SetFeeBps && action.amount > AmountMath.MAX_FEE_BPS) revert FeeTooHigh();
        if (kind == ActionKind.EnableRoute && action.amount > 1) revert InvalidLimit();
        if (kind == ActionKind.SetTokenEnabled) {
            if (action.amount > 1) revert InvalidLimit();
            if (!_tokens[action.subject].registered) revert TokenNotRegistered();
        }
        if (kind == ActionKind.RegisterToken && action.decimals > AmountMath.MAX_DECIMALS) {
            revert InvalidDecimals();
        }
        if (kind == ActionKind.RaiseTokenFlowLimit) {
            TokenConfig memory cfg = _tokens[action.subject];
            if (!cfg.registered) revert TokenNotRegistered();
            if (action.amount <= cfg.flowLimit) revert LimitNotRaised();
        }
        if (kind == ActionKind.SetTimelockDelay) {
            if (action.amount < MIN_TIMELOCK_DELAY || action.amount > MAX_TIMELOCK_DELAY) {
                revert TimelockDelayOutOfRange();
            }
        }
        if (kind == ActionKind.SetFlowWindow) {
            if (action.amount < MIN_FLOW_WINDOW || action.amount > MAX_FLOW_WINDOW) revert InvalidWindow();
        }
    }

    function _applyAction(AdminAction memory action) private {
        ActionKind kind = action.kind;

        if (kind == ActionKind.SetFeeBps) {
            feeBps = uint16(action.amount);
        } else if (kind == ActionKind.SetTreasury) {
            treasury = action.subject;
        } else if (kind == ActionKind.SetAdmin) {
            _grantRole(DEFAULT_ADMIN_ROLE, action.subject);
        } else if (kind == ActionKind.SetGuardian) {
            _grantRole(GUARDIAN_ROLE, action.subject);
        } else if (kind == ActionKind.SetAdapter) {
            _adapters[action.route] = action.subject;
            emit AdapterSet(action.route, action.subject);
        } else if (kind == ActionKind.SetRailReceiver) {
            _railReceivers[action.route] = action.subject;
            emit RailReceiverSet(action.route, action.subject);
        } else if (kind == ActionKind.EnableRoute) {
            bool on = action.amount == 1;
            routeEnabled[action.route] = on;
            emit RouteConfigured(action.route, on);
            return;
        } else if (kind == ActionKind.RegisterToken) {
            TokenConfig storage cfg = _tokens[action.subject];
            cfg.registered = true;
            cfg.enabled = true;
            cfg.decimals = action.decimals;
            cfg.flowLimit = action.amount;
            emit TokenRegistered(action.subject, cfg);
            return;
        } else if (kind == ActionKind.RaiseTokenFlowLimit) {
            TokenConfig storage cfg = _tokens[action.subject];
            cfg.flowLimit = action.amount;
            emit TokenRegistered(action.subject, cfg);
            return;
        } else if (kind == ActionKind.SetRouteFlowLimit) {
            bytes32 key = _flowKey(action.subject, action.route);
            _routeFlowLimit[key] = action.amount;
            _routeFlowLimitSet[key] = true;
            return;
        } else if (kind == ActionKind.SetTokenEnabled) {
            TokenConfig storage cfg = _tokens[action.subject];
            cfg.enabled = action.amount == 1;
            emit TokenRegistered(action.subject, cfg);
            return;
        } else if (kind == ActionKind.SetTimelockDelay) {
            timelockDelay = uint64(action.amount);
        } else {
            flowWindow = uint64(action.amount);
        }

        emit ConfigChanged(treasury, feeBps, timelockDelay, flowWindow);
    }
}
