// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Hyperion's refusals, in one place.
//
// Every name here is the name the Stellar side uses for the same refusal. `hyperion_core`
// numbers its errors because Soroban puts an integer in the transaction result; Solidity gets a
// selector instead, and the shared vocabulary is the point rather than the shared integer. An
// operator reading "MuxedNotSupported" off an EVM revert and off a Soroban transaction result
// should not have to look up which one means what.

import {RouteKind} from "./TraiectaTypes.sol";

// Lifecycle and roles.
error AlreadyInitialized();
error NotInitialized();
error Unauthorized();
error NotRailReceiver();
error RouteDisabled();
error RouteIsPaused(RouteKind route);
error AdapterNotSet();

// Amounts, decimals and fees.
error InvalidAmount();
error AmountNotRepresentable();
error DecimalOverflow();
error InvalidDecimals();
error SlippageExceeded(uint256 wanted, uint256 got);
error FeeTooHigh();
error AmountBelowMinimum();

// Flow control.
error FlowLimitExceeded(uint256 requested, uint256 available);
error InvalidLimit();
error InvalidWindow();
error LimitNotRaised();

// Destinations.
error InvalidDestination();
error ZeroAddressKey();
error MuxedNotSupported();
error NotEvmAddress();
error UnknownChain();

// Messages.
error ReplayedMessage();
error MalformedMessage();
error UnsupportedHookVersion();
error UnsupportedMessageVersion();
error WrongDomain();
error NotMintRecipient();
error UnexpectedRailContract();
error NothingMinted();
error UnsupportedRoute();

// The timelock.
error TimelockNotQueued();
error TimelockNotReady(uint64 eta);
error TimelockExpired(uint64 expiredAt);
error TimelockDelayOutOfRange();
error TimelockAlreadyExecuted();
error ActionFieldNotEmpty();

// Claims.
error ClaimNotFound();
error ClaimAlreadySettled();
error RecipientNotReady();

// Tokens and wiring.
error TokenNotRegistered();
error TokenDisabled();
error TokenNotMapped();
error RailNotConfigured();
error AlreadyConfigured();
error ProtectedAsset();
error ZeroAddress();

// Native currency, on the way back out.
//
// Rails quote destination gas high and refund the difference, so a `bridgeOut` usually ends by
// sending change to the sender. A sender who cannot accept it is refused rather than tipped,
// because silently keeping the difference is a second fee nobody agreed to.
error RefundFailed();
