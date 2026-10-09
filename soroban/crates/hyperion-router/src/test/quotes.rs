//! The quote view, which is the only thing standing between a user and a surprise.
//!
//! `quote_routes` answers for every rail at once, including the ones that would refuse, and says
//! why. That is deliberate: a planner that silently drops the unavailable options leaves the user
//! guessing why the rail they wanted vanished, and "Allbridge is over its hourly limit, here is
//! how much headroom is left" is a far better answer than an empty list.

use hyperion_core::{HyperionError, RouteKind};
use soroban_sdk::testutils::Address as _;
use soroban_sdk::Address;

use super::doubles::evm_destination;
use super::setup::{World, EVM_DECIMALS, FEE_BPS, FLOW_LIMIT, HUNDRED};
use crate::types::{AdminAction, Destination, OutboundRequest, RouteQuote};

fn quote_for(quotes: &soroban_sdk::Vec<RouteQuote>, route: RouteKind) -> RouteQuote {
    quotes
        .iter()
        .find(|q| q.route == route)
        .expect("every rail is always quoted")
}

#[test]
fn every_rail_is_quoted_even_the_ones_that_would_say_no() {
    let w = World::new();
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    assert_eq!(quotes.len(), 4);
    for route in super::doubles::all_routes() {
        let q = quote_for(&quotes, route);
        assert!(q.available, "{route:?} should be open on a fresh world");
        assert_eq!(q.reason, 0);
    }
}

#[test]
fn the_numbers_in_a_quote_are_the_numbers_the_transfer_actually_uses() {
    let w = World::new();
    let quote = quote_for(
        &w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );

    let before = w.token().balance(&w.user);
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: Destination {
                chain: w.ethereum(),
                address: evm_destination(&w.env, 0x11),
            },
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );

    // A quote that does not match the settlement is worse than no quote at all.
    assert_eq!(before - w.token().balance(&w.user), quote.gross_amount);
    assert_eq!(w.token().balance(&w.treasury), quote.fee);
    assert_eq!(w.token().balance(&w.rail_id), quote.net_amount);
    assert_eq!(w.rail().last_dispatch().amount, quote.net_amount);

    let record = w.router().get_transfer(&1);
    assert_eq!(record.gross_amount, quote.gross_amount);
    assert_eq!(record.fee, quote.fee);
    assert_eq!(record.net_amount, quote.net_amount);
}

#[test]
fn the_fee_is_the_documented_share_and_the_rest_crosses() {
    let w = World::new();
    let quote = quote_for(
        &w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );
    assert_eq!(quote.fee, HUNDRED * FEE_BPS as i128 / 10_000);
    assert_eq!(quote.gross_amount, quote.fee + quote.net_amount);
    // Seven decimals here, six on the far side, so the visible amount is ten times smaller.
    assert_eq!(quote.destination_amount, quote.net_amount / 10);
}

#[test]
fn a_quote_for_an_amount_the_far_side_cannot_represent_says_so_rather_than_rounding() {
    let w = World::new();
    // Nine stroops is less than one unit of a six decimal asset, so there is nothing to send.
    let quotes = w.router().quote_routes(&w.token_id, &9, &EVM_DECIMALS);
    for route in super::doubles::all_routes() {
        let q = quote_for(&quotes, route);
        assert!(!q.available);
        assert_eq!(q.reason, HyperionError::AmountNotRepresentable as u32);
    }
}

#[test]
fn a_quote_for_nothing_at_all_is_refused() {
    let w = World::new();
    for amount in [0i128, -HUNDRED] {
        let quotes = w.router().quote_routes(&w.token_id, &amount, &EVM_DECIMALS);
        for route in super::doubles::all_routes() {
            assert_eq!(
                quote_for(&quotes, route).reason,
                HyperionError::InvalidAmount as u32
            );
        }
    }
}

#[test]
fn a_closed_lane_shows_up_closed_while_its_neighbours_stay_open() {
    let w = World::new();
    w.router().disable_route(&w.guardian, &RouteKind::AxelarGmp);
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);

    let closed = quote_for(&quotes, RouteKind::AxelarGmp);
    assert!(!closed.available);
    assert_eq!(closed.reason, HyperionError::RouteDisabled as u32);
    assert!(quote_for(&quotes, RouteKind::Cctp).available);
    assert!(quote_for(&quotes, RouteKind::AxelarIts).available);
    assert!(quote_for(&quotes, RouteKind::Allbridge).available);
}

#[test]
fn a_rail_with_nothing_wired_behind_it_is_not_offered() {
    let w = World::bare();
    w.register_token(w.token_id.clone(), 7, FLOW_LIMIT);
    w.run_action(AdminAction::EnableRoute(RouteKind::Cctp));
    // Open for business, but no adapter address was ever set, so there is nowhere to send funds.
    let q = quote_for(
        &w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );
    assert!(!q.available);
    assert_eq!(q.reason, HyperionError::AdapterNotSet as u32);
}

#[test]
fn a_paused_bridge_quotes_nothing_but_still_explains_itself() {
    let w = World::new();
    w.router().pause(&w.guardian);
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    for route in super::doubles::all_routes() {
        let q = quote_for(&quotes, route);
        assert!(!q.available);
        assert_eq!(q.reason, HyperionError::Paused as u32);
    }
}

#[test]
fn an_unknown_token_is_refused_on_every_rail() {
    let w = World::new();
    let stranger = Address::generate(&w.env);
    let quotes = w.router().quote_routes(&stranger, &HUNDRED, &EVM_DECIMALS);
    for route in super::doubles::all_routes() {
        assert_eq!(
            quote_for(&quotes, route).reason,
            HyperionError::TokenNotRegistered as u32
        );
    }
}

#[test]
fn a_token_that_was_switched_off_is_refused_even_though_it_is_still_registered() {
    let w = World::new();
    w.router().disable_token(&w.guardian, &w.token_id);
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    for route in super::doubles::all_routes() {
        // Switched off, not unknown. Saying `TokenNotRegistered` here would send somebody
        // looking for a registration that is already there, and it is the tag this test has to
        // keep apart from `an_unknown_token_is_refused_on_every_rail` above.
        assert_eq!(
            quote_for(&quotes, route).reason,
            HyperionError::TokenDisabled as u32
        );
    }
}

#[test]
fn an_uninitialised_router_quotes_four_refusals_rather_than_panicking() {
    let w = World::uninitialised();
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    assert_eq!(quotes.len(), 4);
    for route in super::doubles::all_routes() {
        assert_eq!(
            quote_for(&quotes, route).reason,
            HyperionError::NotInitialized as u32
        );
    }
}

#[test]
fn a_rail_that_is_out_of_headroom_reports_how_much_is_left() {
    let w = World::new();
    w.router()
        .lower_token_flow_limit(&w.guardian, &w.token_id, &(HUNDRED / 2));

    let q = quote_for(
        &w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );
    assert!(!q.available);
    assert_eq!(q.reason, HyperionError::FlowLimitExceeded as u32);
    // The amounts stay populated on this branch precisely so the interface can say "try again
    // with 49.9 instead" rather than shrugging.
    assert_eq!(q.flow_available, HUNDRED / 2);
    assert!(q.net_amount > 0);
    assert!(q.destination_amount > 0);
}

#[test]
fn headroom_in_a_quote_shrinks_as_the_window_fills_up() {
    let w = World::new();
    let before = quote_for(
        &w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );
    assert_eq!(before.flow_available, FLOW_LIMIT);

    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: Destination {
                chain: w.ethereum(),
                address: evm_destination(&w.env, 0x12),
            },
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );

    let after = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    assert_eq!(
        quote_for(&after, RouteKind::Cctp).flow_available,
        FLOW_LIMIT - before.net_amount
    );
    // Limits are counted per rail, so the others have not moved.
    assert_eq!(
        quote_for(&after, RouteKind::Allbridge).flow_available,
        FLOW_LIMIT
    );
}

#[test]
fn a_per_rail_limit_shows_through_in_the_quote() {
    let w = World::new();
    w.run_action(AdminAction::SetRouteFlowLimit(
        w.token_id.clone(),
        RouteKind::Allbridge,
        HUNDRED * 2,
    ));
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    assert_eq!(
        quote_for(&quotes, RouteKind::Allbridge).flow_available,
        HUNDRED * 2
    );
    assert_eq!(
        quote_for(&quotes, RouteKind::Cctp).flow_available,
        FLOW_LIMIT
    );
}

#[test]
fn the_quote_says_which_rails_make_you_wait_and_which_ones_keep_the_real_asset() {
    let w = World::new();
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);

    // Allbridge settles from a pool on arrival, so there is no attestation to sit through. The
    // other three all wait on somebody else's signature, and the interface should say so before
    // the user commits rather than after.
    assert!(!quote_for(&quotes, RouteKind::Allbridge).waits_on_attestation);
    for route in [RouteKind::Cctp, RouteKind::AxelarIts, RouteKind::AxelarGmp] {
        assert!(quote_for(&quotes, route).waits_on_attestation);
    }

    // Canonical means the recipient ends up holding the real asset rather than a wrapper or a
    // pool share, which is the difference between "USDC" and "something worth about a dollar".
    assert!(quote_for(&quotes, RouteKind::Cctp).is_canonical);
    assert!(quote_for(&quotes, RouteKind::AxelarIts).is_canonical);
    assert!(!quote_for(&quotes, RouteKind::AxelarGmp).is_canonical);
    assert!(!quote_for(&quotes, RouteKind::Allbridge).is_canonical);
}

#[test]
fn the_flags_survive_a_refusal_so_the_interface_can_still_rank_the_losers() {
    let w = World::new();
    w.router().pause(&w.admin);
    let quotes = w
        .router()
        .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    assert!(!quote_for(&quotes, RouteKind::Allbridge).waits_on_attestation);
    assert!(quote_for(&quotes, RouteKind::Cctp).is_canonical);
    assert_eq!(quote_for(&quotes, RouteKind::Cctp).gross_amount, HUNDRED);
}

#[test]
fn a_token_with_a_different_decimal_base_quotes_the_right_far_side_amount() {
    let w = World::bare();
    let six = w.with_failable_token_with_decimals(6);
    w.register_token(six.clone(), 6, FLOW_LIMIT);
    w.enable_every_route();

    // Six to six, so nothing is lost and the far side sees exactly the net.
    let q = quote_for(
        &w.router().quote_routes(&six, &HUNDRED, &EVM_DECIMALS),
        RouteKind::Cctp,
    );
    assert!(q.available);
    assert_eq!(q.destination_amount, q.net_amount);
}

#[test]
fn quoting_is_free_and_changes_nothing() {
    let w = World::new();
    let before = w.token().balance(&w.user);
    for _ in 0..5 {
        w.router()
            .quote_routes(&w.token_id, &HUNDRED, &EVM_DECIMALS);
    }
    assert_eq!(w.token().balance(&w.user), before);
    assert_eq!(w.router().last_out_nonce(), 0);
    assert_eq!(
        w.router().flow_available(&w.token_id, &RouteKind::Cctp),
        FLOW_LIMIT
    );
}
