"""Diagnostics: reserve/depth tables, route loss, drawdown propagation, fee flow."""

from __future__ import annotations

import math

import pytest

from sim.clmm import ParentEthMarket
from sim.family import BEST, FULL_LINE, PARENT_SOURCED, FeeAllocator
from sim.metrics import (
    attack_pnl,
    depth_by_generation,
    drawdown_propagation,
    fee_flow_by_recipient,
    parent_released_per_pct_decline,
    reserve_by_generation,
    route_loss_table,
)
from sim.tests.helpers import build_chain, parity_market

REL = 1e-9


# --------------------------------------------------------------------------
# tables
# --------------------------------------------------------------------------
def test_reserve_by_generation() -> None:
    chain = build_chain(6, reserve_eth=5e5)
    df = reserve_by_generation(chain)
    assert list(df["index"]) == list(range(6))
    assert df["reserve_eth"].min() == pytest.approx(5e5, rel=0.02)
    assert df["reserve_eth"].max() == pytest.approx(5e5, rel=0.02)
    for i in range(6):
        row = df.iloc[i]
        assert row["price_in_eth"] == pytest.approx(chain.price_in_eth(i), rel=REL)
        assert row["fdv_eth"] == pytest.approx(chain.fdv_eth(i), rel=REL)
        assert 0.0 < row["tokens_sold_frac"] < 1.0
        assert row["max_absorption_parent"] > row["reserve_parent"]


def test_depth_by_generation() -> None:
    chain = build_chain(4)
    df = depth_by_generation(chain, pct=0.01)
    assert len(df) == 4
    assert (df["parent_to_lift"] > 0.0).all()
    assert (df["parent_released_on_decline"] > 0.0).all()
    # concentrated liquidity is not symmetric: a 1% fall gives back a little
    # more than a 1% rise costs
    assert (df["parent_released_on_decline"] < df["parent_to_lift"] * 1.01).all()
    with pytest.raises(ValueError):
        depth_by_generation(chain, pct=0.0)


def test_route_loss_table_grows_with_size_and_does_not_mutate() -> None:
    chain = build_chain(10)
    parity_market(chain, 9)
    snapshot = [link.pool.price for link in chain.links]

    df = route_loss_table(
        chain, sizes=[1e2, 5e3, 5e4], modes=[FULL_LINE, PARENT_SOURCED, BEST]
    )
    assert len(df) == 9
    assert [link.pool.price for link in chain.links] == snapshot

    full = df[df["mode"] == "FULL_LINE"].sort_values("size_in")
    assert list(full["effective_loss_frac"]) == sorted(full["effective_loss_frac"])
    assert (full["hops"] == 10).all()
    assert not full["uses_external"].any()

    sourced = df[df["mode"] == "PARENT_SOURCED"].sort_values("size_in")
    assert sourced["uses_external"].all()
    assert (sourced["protocol_fee_eth"] == 0.0).all()
    assert list(sourced["effective_loss_frac"]) < list(full["effective_loss_frac"])


def test_parent_released_per_pct_decline_matches_the_closed_form() -> None:
    chain = build_chain(2)
    pool = chain.links[1].pool
    released = parent_released_per_pct_decline(pool, 0.20)
    rng = pool.ranges[0]
    target = math.sqrt(pool.fdv() * 0.80 / pool.supply)
    assert released == pytest.approx(rng.L * (pool.sqrtP - target), rel=1e-9)
    assert 0.0 < released < pool.reserve_parent()
    with pytest.raises(ValueError):
        parent_released_per_pct_decline(pool, 1.0)


# --------------------------------------------------------------------------
# drawdown propagation
# --------------------------------------------------------------------------
def test_drawdown_is_monotone_away_from_the_shock_without_external_markets() -> None:
    chain = build_chain(8)
    shock = 4
    dd = drawdown_propagation(chain, shock, 0.25)
    assert set(dd) == set(range(8))
    assert dd[shock] > 0.0

    for k in range(shock + 1, 8):  # walking up the line
        assert dd[k] <= dd[k - 1] + 1e-12
    for k in range(shock - 1, -1, -1):  # and down it
        assert dd[k] <= dd[k + 1] + 1e-12
        assert dd[k] == pytest.approx(0.0, abs=1e-12)  # ancestors never learn

    # descendants inherit the shock exactly, through the telescoping product
    for k in range(shock, 8):
        assert dd[k] == pytest.approx(dd[shock], rel=1e-9)


def test_bigger_shocks_hurt_more_and_a_zero_shock_does_nothing() -> None:
    chain = build_chain(5)
    small = drawdown_propagation(chain, 2, 0.05)
    big = drawdown_propagation(chain, 2, 0.40)
    assert big[2] > small[2] > 0.0
    assert drawdown_propagation(chain, 2, 0.0)[2] == pytest.approx(0.0, abs=1e-12)
    with pytest.raises(ValueError):
        drawdown_propagation(chain, 2, 1.5)


def test_an_external_market_lets_the_shock_reach_the_ancestors() -> None:
    """The disclosed leak: an outside ETH pool re-transmits the shock downward."""
    chain = build_chain(6, hop_fee_bps=10.0)
    chain.add_external_market(
        5,
        ParentEthMarket(depth_eth=2e5, depth_token=2e5 / chain.price_in_eth(5)),
    )
    dd = drawdown_propagation(chain, 5, 0.30)
    assert dd[5] > 0.0
    assert any(abs(dd[k]) > 1e-9 for k in range(5))  # ancestors moved


# --------------------------------------------------------------------------
# fee flow and attack bookkeeping
# --------------------------------------------------------------------------
def test_fee_flow_by_recipient() -> None:
    alloc = FeeAllocator()
    ledger = [alloc.allocate(1.0, t) for t in (1, 5, 5, 12)]
    df = fee_flow_by_recipient(ledger)

    assert df["amount"].sum() == pytest.approx(4.0, rel=1e-12)
    assert df["share"].sum() == pytest.approx(1.0, rel=1e-12)
    dev = df[df["kind"] == "dev"]
    assert len(dev) == 1
    assert dev["amount"].iloc[0] == pytest.approx(0.80, rel=1e-12)
    creators = df[df["kind"] == "creator"]
    assert set(creators["target"]) == {1, 5, 12}
    assert creators["amount"].sum() == pytest.approx(0.40, rel=1e-12)
    ancestors = df[df["kind"] == "ancestor"]
    assert ancestors["amount"].sum() == pytest.approx(2.0, rel=1e-12)
    # genesis is in every sleeve, so it out-earns any single later ancestor
    genesis = ancestors[ancestors["target"] == 0]["amount"].iloc[0]
    assert genesis == ancestors["amount"].max()
    assert fee_flow_by_recipient([]).empty


def test_attack_pnl_struct() -> None:
    pnl = attack_pnl("sandwich", cost_eth=100.0, proceeds_eth=180.0, gas_eth=0.5,
                     victim_loss_eth=33.3)
    assert pnl.profit_eth == pytest.approx(79.5, rel=REL)
    assert pnl.roi == pytest.approx(0.795, rel=REL)
    assert pnl.profitable
    assert not attack_pnl("dud", 100.0, 90.0).profitable
    assert attack_pnl("free", 0.0, 0.0).roi == 0.0


def test_route_loss_table_defaults_to_the_head() -> None:
    chain = build_chain(4)
    df = route_loss_table(chain, sizes=[1e3])
    assert df["dst"].iloc[0] == chain.head.index
    assert df["mode"].iloc[0] == "FULL_LINE"
    assert 0.0 < df["effective_loss_frac"].iloc[0] < 1.0
