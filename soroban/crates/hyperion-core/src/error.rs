use soroban_sdk::contracterror;

/// Every failure mode Hyperion contracts can return.
///
/// These are stable numbers. The SDK maps them to human sentences, the indexer stores them
/// against a transfer record, and the web app shows them. Renumbering one is a breaking
/// change, so append rather than reorder.
#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum HyperionError {
    // Lifecycle
    AlreadyInitialized = 1,
    NotInitialized = 2,

    // Authorization
    Unauthorized = 3,
    NotRailReceiver = 4,

    // Circuit breakers
    Paused = 5,
    RouteDisabled = 6,
    AdapterNotSet = 7,
    FlowLimitExceeded = 8,

    // Amounts and decimals
    InvalidAmount = 9,
    AmountNotRepresentable = 10,
    DecimalOverflow = 11,
    InvalidDecimals = 12,
    SlippageExceeded = 13,
    FeeTooHigh = 14,

    // Destinations and address encoding
    InvalidDestination = 15,
    ZeroAddressKey = 16,
    MuxedNotSupported = 17,
    NotEvmAddress = 18,
    UnknownChain = 19,

    // Message handling
    ReplayedMessage = 20,
    UnknownNonce = 21,

    // Timelocked admin
    TimelockNotQueued = 22,
    TimelockNotReady = 23,
    TimelockExpired = 24,
    TimelockDelayOutOfRange = 25,

    // Parked deliveries
    ClaimNotFound = 26,
    ClaimAlreadySettled = 27,
    RecipientNotReady = 28,

    // Configuration
    InvalidLimit = 29,
    InvalidWindow = 30,
    TokenNotRegistered = 31,

    // Rail adapters. Everything from here down is raised by an adapter rather than the router,
    // and the numbering carries straight on so a caller only ever has one table to look at.
    /// The bytes handed over do not parse as the message they claim to be.
    MalformedMessage = 32,
    /// A hook payload written by a version of Hyperion this contract does not know how to read.
    UnsupportedHookVersion = 33,
    /// The adapter has not been pointed at the rail contract it needs yet.
    RailNotConfigured = 34,
    /// A message addressed to some other chain's CCTP domain.
    WrongDomain = 35,
    /// The mint recipient in the message is not this adapter, so the funds are not ours to move.
    NotMintRecipient = 36,
    /// The message is addressed to something other than the token messenger we were told about.
    UnexpectedRailContract = 37,
    /// The rail's verifier accepted the message but nothing actually arrived.
    NothingMinted = 38,
    /// No local asset has been mapped to this source domain and remote token.
    TokenNotMapped = 39,
    /// A one-time setting that has already been written.
    AlreadyConfigured = 40,
    /// A pooled route asked for more than the pool holds.
    InsufficientLiquidity = 41,
    /// The message version on the wire is not the one this adapter speaks.
    UnsupportedMessageVersion = 42,
    /// The caller is not the rail whose delivery this claims to be.
    NotTheRail = 43,
    /// This adapter instance was wired for a route it cannot serve.
    ///
    /// One WASM can back more than one route, but an instance of it is set up for exactly
    /// one, and being asked to be a different one is a deployment mistake rather than a
    /// runtime condition.
    UnsupportedRoute = 44,
    /// A rail that charges for relaying was asked to relay and the float could not cover it.
    ///
    /// Distinct from a fee problem. The transfer is fine and the configuration is fine; the
    /// contract simply does not hold enough of the gas asset to buy the next hop right now,
    /// and anybody can fix that by topping it up.
    GasFloatTooLow = 45,
    /// Somebody tried to move an asset the contract holds on purpose.
    ProtectedAsset = 46,
    /// A registered token that an operator has switched off for new transfers.
    ///
    /// Distinct from `TokenNotRegistered`: the asset is known and mapped, and it was retired
    /// rather than never carried. The two are different answers for the app to give.
    TokenDisabled = 47,
}
