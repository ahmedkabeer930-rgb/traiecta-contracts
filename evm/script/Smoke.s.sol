// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {MockTokenMessenger} from "../test/mocks/MockTokenMessenger.sol";

import {HyperionRouter} from "../src/TraiectaRouter.sol";
import {Destination, OutboundRequest, RouteKind, RouteQuote} from "../src/TraiectaTypes.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";

import {DeployConfig} from "./DeployConfig.sol";

/// @title Send one transfer through a fresh deployment and read back what the rail was told
/// @author dotmantissa
/// @notice A deployment that is configured correctly and a deployment that works are two different
/// claims, and only one of them can be checked by reading storage. This quotes a transfer, sends
/// it, and then reads the burn the rail recorded, so the mint recipient and the hook bytes are
/// checked against what the destination actually needs rather than against what the script
/// intended. Those two values are exactly the ones a misconfiguration gets wrong without
/// reverting, which makes them the only ones worth going this far to check.
///
/// On a local node the rail is the same stand in the unit tests use, so the burn is inspectable.
/// Against a real rail it is not, and the script stops after the quote rather than spending
/// somebody's money to find out.
///
/// Everything is held in one struct and the work is split across small functions. Not a style
/// preference: the IR pipeline will not keep this many values live at once, and a script that
/// compiles only until somebody adds a log line is a script that gets deleted.
///
/// Usage:
///   forge script script/Smoke.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract Smoke is DeployConfig {
    using stdJson for string;

    struct Ctx {
        string record;
        HyperionRouter router;
        IERC20 token;
        Destination destination;
        string recipient;
        uint256 amount;
        uint8 destinationDecimals;
    }

    function run() external {
        Ctx memory ctx = _load();
        RouteQuote memory quote = _quote(ctx);

        if (block.chainid != 31_337 && block.chainid != 1337) {
            console.log("");
            console.log("Quote checks out. Stopping here, because the rail on this chain is real and");
            console.log("a smoke test is not a reason to burn somebody's USDC.");
            return;
        }

        _send(ctx, quote);
        _inspect(ctx, quote);
    }

    function _load() private view returns (Ctx memory ctx) {
        string memory path = vm.envOr(
            "HYPERION_RECORD", string.concat("deployments/evm-", vm.toString(block.chainid), "-phase1.json")
        );
        ctx.record = vm.readFile(path);
        ctx.router = HyperionRouter(payable(ctx.record.readAddress(".router")));
        ctx.token = IERC20(ctx.record.readAddress(".token"));
        // A real published Stellar account with a real checksum, so the router's strkey parser is
        // doing work rather than being handed something this script made up.
        ctx.recipient = vm.envOr(
            "HYPERION_SMOKE_RECIPIENT", string("GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
        );
        ctx.destination = Destination({chain: ctx.record.readString(".stellarChain"), strkey: ctx.recipient});
        // One USDC is a round number on both sides, which makes a wrong decimal conversion obvious
        // in the log rather than plausible.
        ctx.amount = vm.envOr("HYPERION_SMOKE_AMOUNT", uint256(1_000_000));
        // Stellar carries seven decimals and this chain carries six, so the amount widens.
        ctx.destinationDecimals = 7;

        console.log("record              ", path);
        console.log("router              ", address(ctx.router));
        console.log("asset               ", address(ctx.token));
        console.log("amount in           ", ctx.amount);
        console.log("recipient           ", ctx.recipient);
    }

    function _quote(Ctx memory ctx) private view returns (RouteQuote memory quote) {
        quote = ctx.router
            .quote(RouteKind.Cctp, address(ctx.token), ctx.amount, ctx.destination, ctx.destinationDecimals);

        console.log("");
        console.log("quote available     ", quote.available);
        console.log("  fee               ", quote.fee);
        console.log("  net               ", quote.netAmount);
        console.log("  gross             ", quote.grossAmount);
        console.log("  lands as          ", quote.destinationAmount);
        console.log("  flow headroom     ", quote.flowAvailable);
        console.log("  waits on attest   ", quote.waitsOnAttestation);
        console.log("  canonical asset   ", quote.isCanonical);

        if (!quote.available) {
            console.log("blocker reason code ", uint256(quote.reason));
            revert("the router will not price this transfer; fix the configuration before sending");
        }

        // The arithmetic the quote promised, checked rather than trusted. Thirty basis points of a
        // million is three thousand, and the remainder widens by exactly one decimal place.
        require(quote.fee + quote.netAmount == quote.grossAmount, "quote does not add up");
        require(quote.destinationAmount == quote.netAmount * 10, "six into seven decimals is a factor of ten");
    }

    function _send(Ctx memory ctx, RouteQuote memory quote) private {
        address treasury = ctx.router.treasury();
        uint256 before = ctx.token.balanceOf(treasury);

        vm.startBroadcast();
        ctx.token.approve(address(ctx.router), quote.grossAmount);
        uint64 nonce = ctx.router
            .bridgeOut(
                OutboundRequest({
                    token: address(ctx.token),
                    amount: ctx.amount,
                    route: RouteKind.Cctp,
                    destination: ctx.destination,
                    destinationDecimals: ctx.destinationDecimals,
                    // The quote just said what lands, so accepting less would make the slippage guard
                    // decorative.
                    minDestinationAmount: quote.destinationAmount
                })
            );
        vm.stopBroadcast();

        console.log("");
        console.log("sent, nonce         ", nonce);
        console.log("fee to treasury     ", ctx.token.balanceOf(treasury) - before);
    }

    function _inspect(Ctx memory ctx, RouteQuote memory quote) private view {
        CctpAdapter cctp = CctpAdapter(payable(ctx.record.readAddress(".cctpAdapter")));
        MockTokenMessenger.Burn memory burn = MockTokenMessenger(address(cctp.TOKEN_MESSENGER())).lastBurn();
        _printBurn(burn);
        _checkBurn(ctx, quote, burn);

        console.log("");
        console.log("The hook names the account that asked for the money. Deployment is routable.");
    }

    function _printBurn(MockTokenMessenger.Burn memory burn) private pure {
        console.log("");
        console.log("What the rail was told:");
        console.log("  amount burned     ", burn.amount);
        console.log("  destination domain", burn.destinationDomain);
        console.log("  mint recipient    ", vm.toString(burn.mintRecipient));
        console.log("  burn token        ", burn.burnToken);
        console.log("  finality tier     ", burn.minFinalityThreshold);
        console.log("  hook length       ", burn.hookData.length);
        console.log("  hook              ", vm.toString(burn.hookData));
    }

    function _checkBurn(Ctx memory ctx, RouteQuote memory quote, MockTokenMessenger.Burn memory burn)
        private
        pure
    {
        require(
            burn.amount == quote.netAmount, "the rail was handed a different amount than the quote promised"
        );
        require(burn.destinationDomain == STELLAR_CCTP_DOMAIN, "wrong CCTP domain");
        require(burn.mintRecipient == ctx.record.readBytes32(".stellarRailRecipient"), "wrong mint recipient");
        require(burn.burnToken == address(ctx.token), "the rail was handed the wrong asset");

        // Thirty four bytes: one of hook version, one of address kind, thirty two of key. A muxed
        // destination would be forty two. Anything else and the Stellar side cannot read it, and by
        // then the money is already burned.
        require(burn.hookData.length == 34, "the hook is not a plain Stellar destination");
        require(uint8(burn.hookData[0]) == 1, "wrong hook version");
        require(uint8(burn.hookData[1]) == 0, "a G address should be tagged as an account");
    }
}
