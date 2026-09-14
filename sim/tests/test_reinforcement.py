"""Keeper deployment tests, including the audit's sandwich scenario."""

from __future__ import annotations

import pytest

from sim.family import FamilyChain
from sim.metrics import attack_pnl
from sim.reinforcement import (
    BUY_AND_BURN,
    SINGLE_SIDED_BID,
    TWO_SIDED,
    deploy,
)
from sim.tests.helpers import build_chain, cpmm_pool, scaled_pool

REL = 1e-9


# --------------------------------------------------------------------------
# policies
# --------------------------------------------------------------------------
def test_single_sided_bid_buys_the_parent_and_parks_it_below_spot() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    pool = chain.links[3].pool
    ranges_before = len(pool.ranges)
    spot_before = pool.price
    reserve_before = pool.reserve_parent()

    res = deploy(chain, 3, 1e3, SINGLE_SIDED_BID, bid_width=0.10)
    assert res is not None
    assert res.bounty == pytest.approx(10.0, rel=REL)
    assert res.parent_deposited > 0.0
    assert res.parent_undeployed == pytest.approx(0.0, abs=1e-9)
    assert len(pool.ranges) == ranges_before + 1

    added = res.ranges_added[0]
    assert added.upper <= pool.sqrtP + 1e-12  # a bid, strictly at or below spot
    assert added.fdv_lower(pool.supply) == pytest.approx(
        0.90 * added.fdv_upper(pool.supply), rel=1e-6
    )
    # the bid is real depth: the reserve grew and spot did not move
    assert pool.reserve_parent() == pytest.approx(
        reserve_before + res.parent_deposited, rel=1e-9
    )
    assert pool.price == pytest.approx(spot_before, rel=REL)
    # buying the parent up the chain lifted link 2's price
    assert res.price_impact_on_route > 0.0


def test_generation_zero_bids_with_eth_directly() -> None:
    chain = build_chain(3)
    genesis = chain.genesis_pool
    res = deploy(chain, 0, 1e3, SINGLE_SIDED_BID)
    assert res is not None
    assert res.route_result.amount_out == pytest.approx(990.0, rel=REL)  # no route
    assert res.price_impact_on_route == 0.0
    assert res.parent_deposited == pytest.approx(990.0, rel=REL)
    assert genesis.reserve_parent() > 0.0


def test_size_cap_is_two_percent_of_the_parent_reserve() -> None:
    chain = build_chain(3, hop_fee_bps=0.0)
    pool = chain.links[2].pool
    cap = 0.02 * pool.reserve_parent()
    res = deploy(chain, 2, 5e5, SINGLE_SIDED_BID)
    assert res is not None
    assert res.parent_deposited == pytest.approx(cap, rel=1e-9)
    assert res.parent_undeployed > 0.0


def test_buy_and_burn_removes_tokens_and_adds_no_liquidity() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    pool = chain.links[3].pool
    ranges_before = len(pool.ranges)
    remaining_before = pool.tokens_remaining()

    res = deploy(chain, 3, 1e3, BUY_AND_BURN)
    assert res is not None
    assert res.parent_deposited == 0.0
    assert res.tokens_burned > 0.0
    assert len(pool.ranges) == ranges_before
    assert pool.tokens_remaining() == pytest.approx(
        remaining_before - res.tokens_burned, rel=1e-9
    )
    assert pool.price > 0.0


def test_two_sided_adds_a_symmetric_range() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    pool = chain.links[3].pool
    ranges_before = len(pool.ranges)

    res = deploy(chain, 3, 1e3, TWO_SIDED, bid_width=0.10)
    assert res is not None
    assert res.parent_deposited > 0.0
    assert res.token_deposited > 0.0
    assert len(pool.ranges) == ranges_before + 2

    bid, ask = res.ranges_added
    assert bid.upper <= pool.sqrtP + 1e-12
    assert ask.lower >= pool.sqrtP - 1e-12
    F = pool.fdv()
    assert bid.fdv_lower(pool.supply) == pytest.approx(F / 1.10, rel=1e-6)
    assert ask.fdv_upper(pool.supply) == pytest.approx(F * 1.10, rel=1e-6)


def test_policy_validation() -> None:
    chain = build_chain(2)
    with pytest.raises(ValueError):
        deploy(chain, 1, 1.0, "MOON")
    with pytest.raises(ValueError):
        deploy(chain, 1, -1.0, SINGLE_SIDED_BID)
    with pytest.raises(IndexError):
        deploy(chain, 5, 1.0, SINGLE_SIDED_BID)


# --------------------------------------------------------------------------
# execution bounds (design review finding 9)
# --------------------------------------------------------------------------
def sandwich_chain() -> FamilyChain:
    """Genesis is the audit's ``(100 parent, 100 child)`` constant-product segment.

    Fees are switched off so the arithmetic is the audit's own "gross profit,
    before fees" figure.
    """
    chain = FamilyChain(cpmm_pool(100.0, 100.0), protocol_fee_bps=0.0)
    chain.promote(scaled_pool(5e4, hop_fee_bps=0.0), "#1")
    return chain


def test_unbounded_deployment_is_sandwiched_for_eighty_parent() -> None:
    chain = sandwich_chain()
    pool = chain.genesis_pool

    front = pool.swap_exact_in(100.0, parent_in=True)  # attacker buys first
    assert front.amount_out == pytest.approx(50.0, rel=1e-5)

    res = deploy(chain, 1, 100.0, SINGLE_SIDED_BID, bounty_frac=0.0)
    assert res is not None
    assert res.route_result.amount_out == pytest.approx(100.0 / 6.0, rel=1e-4)  # 16.67

    back = pool.swap_exact_in(front.amount_out, parent_in=False)
    pnl = attack_pnl("sandwich", cost_eth=100.0, proceeds_eth=back.amount_out)
    assert back.amount_out == pytest.approx(180.0, rel=1e-4)
    assert pnl.profit_eth == pytest.approx(80.0, rel=1e-3)
    assert pnl.profitable


def test_twap_bound_reverts_the_deployment_and_kills_the_profit() -> None:
    chain = sandwich_chain()
    pool = chain.genesis_pool
    twap = pool.price  # the pre-attack 30-minute observation

    front = pool.swap_exact_in(100.0, parent_in=True)
    assert pool.price == pytest.approx(4.0, rel=1e-5)  # 4x, far outside +/-3%

    res = deploy(chain, 1, 100.0, SINGLE_SIDED_BID, twap=twap, twap_tol=0.03,
                 bounty_frac=0.0)
    assert res is None  # reverted: no vault buy for the attacker to capture

    back = pool.swap_exact_in(front.amount_out, parent_in=False)
    pnl = attack_pnl("sandwich", cost_eth=100.0, proceeds_eth=back.amount_out)
    assert not pnl.profitable
    assert pnl.profit_eth == pytest.approx(0.0, abs=1e-3)


def test_twap_bound_lets_an_honest_deployment_through() -> None:
    chain = sandwich_chain()
    twap = chain.genesis_pool.price
    res = deploy(chain, 1, 100.0, SINGLE_SIDED_BID, twap=twap, twap_tol=0.03,
                 bounty_frac=0.0)
    assert res is not None
    assert res.route_result.amount_out == pytest.approx(50.0, rel=1e-4)


def test_twap_dict_bounds_every_hop_and_the_target_pool() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    honest = {i: chain.links[i].pool.price for i in range(4)}
    assert deploy(chain.clone(), 3, 1e3, SINGLE_SIDED_BID, twap=honest) is not None

    # a stale observation for one mid-chain hop is enough to revert
    stale = dict(honest)
    stale[1] = honest[1] * 1.5
    assert deploy(chain.clone(), 3, 1e3, SINGLE_SIDED_BID, twap=stale) is None

    # so is a manipulated target pool, even though it is not on the route
    off_target = dict(honest)
    off_target[3] = honest[3] * 0.5
    assert deploy(chain.clone(), 3, 1e3, SINGLE_SIDED_BID, twap=off_target) is None


def test_reverted_deployment_leaves_no_trace() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    before = [(len(link.pool.ranges), link.pool.price) for link in chain.links]
    twap = {i: chain.links[i].pool.price * 2.0 for i in range(4)}
    assert deploy(chain, 3, 1e3, BUY_AND_BURN, twap=twap) is None
    assert deploy(chain, 3, 1e3, TWO_SIDED, twap=twap) is None
    assert [(len(link.pool.ranges), link.pool.price) for link in chain.links] == before
