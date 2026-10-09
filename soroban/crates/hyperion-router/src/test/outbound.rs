//! The outbound leg: money leaving Stellar.

use hyperion_core::{HyperionError, RouteKind};
use soroban_sdk::{testutils::Address as _, Address, String};

use super::doubles::{evm_destination, not_an_evm_address};
use super::setup::{World, EVM_DECIMALS, HUNDRED};
use crate::types::{AdminAction, Destination, OutboundRequest};

fn dest(world: &World) -> Destination {
    Destination {
        chain: world.ethereum(),
        address: evm_destination(&world.env, 0x11),
    }
}

#[test]
fn a_transfer_lands_on_the_rail_with_the_fee_taken_out() {
    let w = World::new();
    let before = w.token().balance(&w.user);

    let nonce = w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );

    // Ten basis points of a hundred units is a tenth of a unit, and the rest goes onto the rail.
    let fee = HUNDRED / 1_000;
    let net = HUNDRED - fee;

    assert_eq!(nonce, 1);
    assert_eq!(w.token().balance(&w.treasury), fee);
    assert_eq!(w.token().balance(&w.rail_id), net);
    assert_eq!(w.token().balance(&w.user), before - HUNDRED);
    // The router keeps nothing for itself.
    assert_eq!(w.token().balance(&w.router_id), 0);

    let dispatched = w.rail().last_dispatch();
    assert_eq!(dispatched.amount, net);
    assert_eq!(dispatched.nonce, 1);
    assert_eq!(dispatched.caller, w.router_id);
    assert_eq!(dispatched.token, w.token_id);

    let record = w.router().get_transfer(&1);
    assert_eq!(record.gross_amount, HUNDRED);
    assert_eq!(record.fee, fee);
    assert_eq!(record.net_amount, net);
    assert_eq!(record.route, RouteKind::Cctp);
    assert_eq!(record.sender, w.user);
}

#[test]
fn the_seventh_decimal_never_leaves_the_sender_because_the_far_side_cannot_hold_it() {
    let w = World::new();
    let before = w.token().balance(&w.user);

    // A hundred units and five stroops. USDC on the far side stops one decimal place short of
    // those five, so taking them would mean owing change nobody can pay.
    let amount = HUNDRED + 5;
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );

    let record = w.router().get_transfer(&1);
    assert_eq!(record.gross_amount, HUNDRED);
    assert_eq!(before - w.token().balance(&w.user), HUNDRED);
    assert_eq!(record.net_amount % 10, 0);
    // Ninety nine point nine units, in the six decimal base the recipient actually uses.
    assert_eq!(record.net_amount / 10, 99_900_000);
}

#[test]
fn an_amount_too_small_for_the_far_side_to_represent_is_refused_rather_than_rounded_to_nothing() {
    let w = World::new();
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: 5,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::AmountNotRepresentable))
    );
}

#[test]
fn a_destination_that_is_not_a_left_padded_evm_word_is_refused() {
    let w = World::new();
    let bad = Destination {
        chain: w.ethereum(),
        address: not_an_evm_address(&w.env),
    };
    // Truncating this would produce twenty bytes that look like a perfectly ordinary address,
    // and the funds would be gone with nothing on chain to suggest anything went wrong.
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: bad,
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::NotEvmAddress))
    );
}

#[test]
fn a_nameless_destination_chain_is_refused() {
    let w = World::new();
    let nowhere = Destination {
        chain: String::from_str(&w.env, ""),
        address: evm_destination(&w.env, 0x11),
    };
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: nowhere,
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::UnknownChain))
    );
}

#[test]
fn a_route_nobody_turned_on_refuses_to_carry_anything() {
    let w = World::bare();
    w.register_token(w.token_id.clone(), 7, super::setup::FLOW_LIMIT);
    w.fund_user(HUNDRED);
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::RouteDisabled))
    );
}

#[test]
fn an_unregistered_token_cannot_move_at_all() {
    let w = World::bare();
    w.enable_every_route();
    w.fund_user(HUNDRED);
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::TokenNotRegistered))
    );
}

#[test]
fn a_token_that_was_switched_off_is_refused_as_switched_off_rather_than_unknown() {
    let w = World::new();
    // Registered, mapped and deliberately retired. Reporting this as "does not carry that token"
    // would send somebody looking for a registration that is already there, and the EVM router
    // has always called this case TokenDisabled.
    w.router().disable_token(&w.guardian, &w.token_id);
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::TokenDisabled))
    );
}

#[test]
fn zero_and_negative_amounts_are_refused() {
    let w = World::new();
    for amount in [0i128, -1, -HUNDRED] {
        assert_eq!(
            w.router().try_bridge_out(
                &w.user,
                &OutboundRequest {
                    token: w.token_id.clone(),
                    amount,
                    route: RouteKind::Cctp,
                    destination: dest(&w),
                    destination_decimals: EVM_DECIMALS,
                    min_destination_amount: 0
                }
            ),
            Err(Ok(HyperionError::InvalidAmount))
        );
    }
}

#[test]
fn pausing_stops_new_departures() {
    let w = World::new();
    w.router().pause(&w.guardian);
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::Paused))
    );

    w.router().unpause(&w.admin);
    assert_eq!(
        w.router().bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        1
    );
}

#[test]
fn asking_for_more_than_the_rate_can_give_refuses_instead_of_settling_for_less() {
    let w = World::new();
    // A hundred units minus ten basis points cannot possibly arrive as a full hundred.
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 100_000_000
            }
        ),
        Err(Ok(HyperionError::SlippageExceeded))
    );
}

#[test]
fn a_single_transfer_over_the_flow_limit_is_refused() {
    let w = World::bare();
    w.enable_every_route();
    // Half a unit an hour, across every route.
    w.register_token(w.token_id.clone(), 7, 5_000_000);
    w.fund_user(HUNDRED);

    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::FlowLimitExceeded))
    );
}

#[test]
fn a_run_of_small_transfers_cannot_add_up_past_the_flow_limit() {
    let w = World::bare();
    w.enable_every_route();
    // Room for roughly three and a bit of the transfers below.
    w.register_token(w.token_id.clone(), 7, 3_500_000);
    w.fund_user(HUNDRED);

    let mut sent = 0;
    for _ in 0..10 {
        let ok = w
            .router()
            .try_bridge_out(
                &w.user,
                &OutboundRequest {
                    token: w.token_id.clone(),
                    amount: 1_000_000,
                    route: RouteKind::Cctp,
                    destination: dest(&w),
                    destination_decimals: EVM_DECIMALS,
                    min_destination_amount: 0,
                },
            )
            .is_ok();
        if ok {
            sent += 1;
        }
    }
    // Each transfer puts 999_000 across after the fee, so three fit under three and a half
    // million and the fourth does not.
    assert_eq!(sent, 3);
    assert_eq!(
        w.router().flow_available(&w.token_id, &RouteKind::Cctp),
        503_000
    );
}

#[test]
fn the_flow_limit_is_counted_per_route_so_one_busy_rail_does_not_close_the_others() {
    let w = World::bare();
    w.enable_every_route();
    w.register_token(w.token_id.clone(), 7, 1_000_000);
    w.fund_user(HUNDRED);

    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: 1_000_000,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    assert_eq!(
        w.router().flow_available(&w.token_id, &RouteKind::Cctp),
        1_000
    );
    // Axelar has not been touched, so it still has its whole allowance.
    assert_eq!(
        w.router()
            .flow_available(&w.token_id, &RouteKind::AxelarIts),
        1_000_000
    );
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: 1_000_000,
            route: RouteKind::AxelarIts,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    assert_eq!(w.rail().dispatch_count(), 2);
}

#[test]
fn a_per_route_limit_overrides_the_token_wide_one() {
    let w = World::new();
    w.run_action(AdminAction::SetRouteFlowLimit(
        w.token_id.clone(),
        RouteKind::Allbridge,
        1_000_000,
    ));
    // Allbridge is pooled liquidity rather than a burn and mint, so it is the rail you would
    // want to keep on a shorter leash than the canonical ones.
    assert_eq!(
        w.router()
            .flow_available(&w.token_id, &RouteKind::Allbridge),
        1_000_000
    );
    assert_eq!(
        w.router().flow_available(&w.token_id, &RouteKind::Cctp),
        super::setup::FLOW_LIMIT
    );
}

#[test]
fn the_window_decays_so_yesterdays_volume_does_not_block_today() {
    let w = World::bare();
    w.enable_every_route();
    w.register_token(w.token_id.clone(), 7, 1_000_000);
    w.fund_user(HUNDRED);

    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: 1_000_000,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    assert!(w.router().flow_available(&w.token_id, &RouteKind::Cctp) < 10_000);

    // Two full windows later the counter has genuinely cleared rather than merely decayed.
    w.advance_ledgers(1_500);
    assert_eq!(
        w.router().flow_available(&w.token_id, &RouteKind::Cctp),
        1_000_000
    );
}

#[test]
fn nonces_count_up_one_at_a_time_and_each_transfer_can_be_found_again() {
    let w = World::new();
    for expected in 1..=3u64 {
        let nonce = w.router().bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::AxelarGmp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0,
            },
        );
        assert_eq!(nonce, expected);
    }
    assert_eq!(w.router().last_out_nonce(), 3);
    assert_eq!(w.router().get_transfer(&2).nonce, 2);
    assert_eq!(
        w.router().try_get_transfer(&99),
        Err(Ok(HyperionError::UnknownNonce))
    );
}

#[test]
fn a_rail_with_no_adapter_configured_cannot_be_used() {
    let w = World::bare();
    w.register_token(w.token_id.clone(), 7, super::setup::FLOW_LIMIT);
    w.fund_user(HUNDRED);
    // Enabled, but pointing at nothing.
    w.run_action(AdminAction::EnableRoute(RouteKind::Cctp));
    assert_eq!(
        w.router().try_bridge_out(
            &w.user,
            &OutboundRequest {
                token: w.token_id.clone(),
                amount: HUNDRED,
                route: RouteKind::Cctp,
                destination: dest(&w),
                destination_decimals: EVM_DECIMALS,
                min_destination_amount: 0
            }
        ),
        Err(Ok(HyperionError::AdapterNotSet))
    );
}

#[test]
#[should_panic(expected = "Unauthorized")]
fn nobody_can_spend_somebody_elses_balance() {
    let w = World::new();
    // Drop the blanket mock and hand over no signatures at all.
    w.env.set_auths(&[]);
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
}

#[test]
fn a_token_registered_with_a_different_decimal_base_still_converts_correctly() {
    let w = World::bare();
    w.enable_every_route();
    let six_decimal = w.with_failable_token_with_decimals(6);
    w.failable(&six_decimal).mint(&w.user, &HUNDRED);

    // Six on both sides means no scaling at all, and no dust to worry about.
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: six_decimal.clone(),
            amount: 1_000_000,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    let record = w.router().get_transfer(&1);
    assert_eq!(record.net_amount, 999_000);
    assert_eq!(record.fee, 1_000);
}

#[test]
fn the_asset_issuer_is_not_a_party_to_any_of_this() {
    let w = World::new();
    // The router holds no privileged position over the asset it moves. It cannot mint, it is not
    // the issuer, and the issuer sees nothing when a transfer goes out. Worth pinning down,
    // because a bridge that quietly needs issuer rights is a very different trust story.
    assert_eq!(w.token().balance(&w.issuer), 0);
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: Destination {
                chain: w.ethereum(),
                address: evm_destination(&w.env, 0x44),
            },
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    assert_eq!(w.token().balance(&w.issuer), 0);
    assert_eq!(w.token().balance(&w.router_id), 0);
}

#[test]
fn the_treasury_is_the_only_place_fees_go() {
    let w = World::new();
    let stranger = Address::generate(&w.env);
    w.router().bridge_out(
        &w.user,
        &OutboundRequest {
            token: w.token_id.clone(),
            amount: HUNDRED,
            route: RouteKind::Cctp,
            destination: dest(&w),
            destination_decimals: EVM_DECIMALS,
            min_destination_amount: 0,
        },
    );
    assert_eq!(w.token().balance(&w.treasury), HUNDRED / 1_000);
    assert_eq!(w.token().balance(&stranger), 0);
    assert_eq!(w.token().balance(&w.router_id), 0);
}
