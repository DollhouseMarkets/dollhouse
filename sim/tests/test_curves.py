"""Curve-builder tests, including the reference cost/impact table."""

from __future__ import annotations

import math

import pandas as pd
import pytest

from sim.clmm import Pool, sqrt_price_from_fdv
from sim.curves import (
    GENTLE,
    INFINITE_LIKE,
    LADDER,
    MID,
    SINGLE,
    TICK_BASE,
    WALL,
    assert_threshold_below_max_absorption,
    build_curve,
    build_pool,
    buy_impact,
    cost_table,
    gentle,
    infinite_like,
    self_similar,
    self_similar_ladder,
    self_similar_mid,
    single,
    snap_fdv_to_tick,
    wall,
)

S = 1e9
REL = 1e-9
PRESETS = [SINGLE, INFINITE_LIKE, WALL, GENTLE]


# --------------------------------------------------------------------------
# structure
# --------------------------------------------------------------------------
@pytest.mark.parametrize("spec", PRESETS)
def test_presets_are_well_formed(spec) -> None:
    assert math.fsum(s for (s, _a, _b) in spec) == pytest.approx(1.0, abs=1e-12)
    for (_s0, _a0, b0), (_s1, a1, _b1) in zip(spec, spec[1:]):
        assert b0 == a1


def test_preset_functions_return_equal_but_independent_specs() -> None:
    for fn, const in ((single, SINGLE), (infinite_like, INFINITE_LIKE), (wall, WALL), (gentle, GENTLE)):
        spec = fn()
        assert spec == const
        spec.append((0.0, 1.0, 2.0))
        assert len(const) != len(spec)


@pytest.mark.parametrize("spec", PRESETS)
def test_build_curve_places_the_whole_supply_once(spec) -> None:
    pool = build_pool(spec, snap_ticks=False)
    assert pool.tokens_remaining() == pytest.approx(S, rel=REL)
    for share, rng in zip((s for (s, _a, _b) in spec), pool.ranges):
        assert rng.token_at(pool.ranges[0].lower) == pytest.approx(share * S, rel=REL)


def test_build_curve_rejects_bad_specs() -> None:
    with pytest.raises(AssertionError):
        build_curve([(0.5, 5e3, 5e6)])  # shares do not sum to 1
    with pytest.raises(AssertionError):
        build_curve([(0.5, 5e3, 5e5), (0.5, 1e6, 5e6)])  # gap, not contiguous
    with pytest.raises(AssertionError):
        build_curve([(0.5, 5e5, 5e6), (0.5, 5e3, 5e5)])  # not ascending
    with pytest.raises(ValueError):
        build_curve([])


# --------------------------------------------------------------------------
# reference table (snap_ticks=False)
# --------------------------------------------------------------------------
def test_reference_costs_for_single() -> None:
    pool = build_pool(SINGLE, snap_ticks=False)
    assert pool.quote_cost_to_fdv(1e6) == pytest.approx(67.9e3, rel=5e-3)
    assert pool.quote_cost_to_fdv(5e6) == pytest.approx(158.1e3, rel=5e-3)
    # full buyout is exactly the geometric mean of the bounds
    assert pool.max_absorption() == pytest.approx(math.sqrt(5e3 * 5e6), rel=REL)


def test_reference_cost_for_wall() -> None:
    pool = build_pool(WALL, snap_ticks=False)
    assert pool.quote_cost_to_fdv(1e6) == pytest.approx(260.6e3, rel=5e-3)
    # which is exactly the sum of the two lower bands' closed forms
    expected = 0.30 * math.sqrt(5e3 * 2.5e5) + 0.50 * math.sqrt(2.5e5 * 1e6)
    assert pool.quote_cost_to_fdv(1e6) == pytest.approx(expected, rel=REL)


def test_reference_buy_impacts() -> None:
    assert buy_impact(SINGLE, 5e4, 5e3, snap_ticks=False) == pytest.approx(8.5e4, rel=1e-2)
    assert buy_impact(WALL, 5e4, 5e3, snap_ticks=False) == pytest.approx(1.81e5, rel=2e-2)


def test_wall_is_harder_to_pump_through_but_cheaper_at_the_bottom() -> None:
    """Sanity on the shape: a wall amplifies small buys, then absorbs hard."""
    assert buy_impact(WALL, 5e4, 5e3, snap_ticks=False) > buy_impact(
        SINGLE, 5e4, 5e3, snap_ticks=False
    )
    single_pool = build_pool(SINGLE, snap_ticks=False)
    wall_pool = build_pool(WALL, snap_ticks=False)
    assert wall_pool.quote_cost_to_fdv(1e6) > single_pool.quote_cost_to_fdv(1e6)


def test_buy_impact_matches_a_manual_swap() -> None:
    F0, q = 5e4, 5e3
    pool = build_pool(WALL, snap_ticks=False, start_fdv=F0)
    pool.swap_exact_in(q, parent_in=True)
    assert buy_impact(WALL, F0, q, snap_ticks=False) == pytest.approx(pool.fdv(), rel=REL)


# --------------------------------------------------------------------------
# cost table
# --------------------------------------------------------------------------
def test_cost_table_shape_and_content() -> None:
    targets = [1e5, 1e6, 5e6]
    df = cost_table(SINGLE, targets, snap_ticks=False)

    assert isinstance(df, pd.DataFrame)
    assert list(df.columns) == [
        "target_fdv",
        "cost_parent",
        "cost_over_fdv",
        "supply_sold_frac",
        "buyer_mtm_at_target",
    ]
    assert list(df["target_fdv"]) == targets
    assert df["cost_parent"].is_monotonic_increasing
    assert df["supply_sold_frac"].between(0.0, 1.0).all()

    row = df.iloc[1]
    assert row["cost_parent"] == pytest.approx(67.9e3, rel=5e-3)
    assert row["cost_over_fdv"] == pytest.approx(row["cost_parent"] / 1e6, rel=REL)
    assert row["buyer_mtm_at_target"] == pytest.approx(
        row["supply_sold_frac"] * 1e6, rel=REL
    )
    # buyers are always up on paper against what they paid, inside the curve
    assert row["buyer_mtm_at_target"] > row["cost_parent"]


def test_cost_table_last_target_matches_max_absorption() -> None:
    df = cost_table(WALL, [1e7], snap_ticks=False)
    pool = build_pool(WALL, snap_ticks=False)
    assert df.iloc[0]["cost_parent"] == pytest.approx(pool.max_absorption(), rel=REL)
    assert df.iloc[0]["supply_sold_frac"] == pytest.approx(1.0, rel=1e-9)


# --------------------------------------------------------------------------
# threshold validator
# --------------------------------------------------------------------------
def test_assert_threshold_below_max_absorption() -> None:
    cap = assert_threshold_below_max_absorption(WALL, 1.0e5, snap_ticks=False)
    assert cap == pytest.approx(
        0.30 * math.sqrt(5e3 * 2.5e5)
        + 0.50 * math.sqrt(2.5e5 * 1e6)
        + 0.20 * math.sqrt(1e6 * 1e7),
        rel=REL,
    )
    with pytest.raises(AssertionError):
        assert_threshold_below_max_absorption(WALL, 0.9 * cap, snap_ticks=False)


# --------------------------------------------------------------------------
# tick snapping
# --------------------------------------------------------------------------
@pytest.mark.parametrize("spec", PRESETS)
@pytest.mark.parametrize("tick_spacing", [10, 60, 200])
def test_tick_snapping_moves_boundaries_by_less_than_half_a_spacing(spec, tick_spacing) -> None:
    """Bound is half a tick spacing in log-price: |ln(P'/P)| <= 0.5*spacing*ln(1.0001)."""
    bound = 0.5 * tick_spacing * math.log(TICK_BASE)
    for _share, Fa, Fb in spec:
        for F in (Fa, Fb):
            snapped = snap_fdv_to_tick(F, S, tick_spacing)
            assert abs(math.log(snapped / F)) <= bound
            # equivalently, well inside 0.5 * spacing * 1e-4 in relative price
            assert abs(snapped / F - 1.0) <= 0.5 * tick_spacing * 1e-4 * 1.001


def test_snapped_boundaries_land_on_usable_ticks_and_stay_contiguous() -> None:
    tick_spacing = 60
    ranges = build_curve(WALL, snap_ticks=True, tick_spacing=tick_spacing)
    for a, b in zip(ranges, ranges[1:]):
        assert a.upper == b.lower  # contiguity survives snapping
    for r in ranges:
        for sp in (r.lower, r.upper):
            tick = math.log(sp * sp) / math.log(TICK_BASE)
            assert abs(tick / tick_spacing - round(tick / tick_spacing)) < 1e-6


def test_snapping_barely_moves_the_economics() -> None:
    snapped = build_pool(WALL, snap_ticks=True)
    raw = build_pool(WALL, snap_ticks=False)
    assert snapped.max_absorption() == pytest.approx(raw.max_absorption(), rel=1e-2)
    assert snapped.tokens_remaining() == pytest.approx(S, rel=REL)


# --------------------------------------------------------------------------
# self-similar scaling
# --------------------------------------------------------------------------
def test_self_similar_scales_bounds_into_parent_units() -> None:
    parent_supply = 1e9
    spec = self_similar(parent_supply, start_ratio=1e-3)

    assert math.fsum(s for (s, _a, _b) in spec) == pytest.approx(1.0, abs=1e-12)
    assert spec[0][1] == pytest.approx(1e-3 * parent_supply, rel=REL)
    assert spec[-1][2] == pytest.approx(1e6 * 1e-3 * parent_supply, rel=REL)
    build_curve(spec, snap_ticks=False)  # must validate


def test_self_similar_is_scale_invariant_in_relative_terms() -> None:
    small = build_pool(self_similar(1e6), snap_ticks=False)
    big = build_pool(self_similar(1e9), snap_ticks=False)
    # 1000x the parent supply -> 1000x the absorption, same shape
    assert big.max_absorption() == pytest.approx(1e3 * small.max_absorption(), rel=REL)
    # and the same fraction of supply is sold at the same *relative* FDV
    for mult in (2.0, 10.0, 100.0):
        small_sold = small.tokens_sold(
            sqrt_price_from_fdv(mult * small.fdv(), small.supply)
        )
        big_sold = big.tokens_sold(sqrt_price_from_fdv(mult * big.fdv(), big.supply))
        assert big_sold == pytest.approx(small_sold, rel=REL)


def test_self_similar_accepts_a_custom_relative_spec() -> None:
    rel_spec = [(0.5, 1.0, 10.0), (0.5, 10.0, 100.0)]
    spec = self_similar(2e9, start_ratio=1e-2, spec_relative=rel_spec)
    assert spec == [(0.5, 2e7, 2e8), (0.5, 2e8, 2e9)]
    pool: Pool = build_pool(spec, snap_ticks=False)
    assert pool.max_absorption() == pytest.approx(
        0.5 * math.sqrt(2e7 * 2e8) + 0.5 * math.sqrt(2e8 * 2e9), rel=REL
    )


# --------------------------------------------------------------------------
# LADDER preset
# --------------------------------------------------------------------------
def test_ladder_shares_sum_to_one_and_bands_are_contiguous() -> None:
    assert math.fsum(s for (s, _a, _b) in LADDER) == pytest.approx(1.0, abs=1e-12)
    assert [s for (s, _a, _b) in LADDER] == pytest.approx([0.10, 0.15, 0.35, 0.40])
    for (_s0, _a0, b0), (_s1, a1, _b1) in zip(LADDER, LADDER[1:]):
        assert b0 == a1
    assert LADDER[0][1] == pytest.approx(1e-3)
    assert LADDER[-1][2] == pytest.approx(100.0)
    build_curve(self_similar_ladder(1e9), snap_ticks=False)  # must validate


def test_self_similar_ladder_scales_bounds_directly_by_parent_supply() -> None:
    parent_supply = 1e9
    spec = self_similar_ladder(parent_supply)
    assert spec == [
        (s, a * parent_supply, b * parent_supply) for (s, a, b) in LADDER
    ]
    assert spec[0][1] == pytest.approx(1e-3 * parent_supply, rel=REL)
    assert spec[-1][2] == pytest.approx(100.0 * parent_supply, rel=REL)


# --------------------------------------------------------------------------
# MID preset
# --------------------------------------------------------------------------
def test_mid_shares_sum_to_one_and_bands_are_contiguous() -> None:
    assert math.fsum(s for (s, _a, _b) in MID) == pytest.approx(1.0, abs=1e-12)
    assert [s for (s, _a, _b) in MID] == pytest.approx([0.20, 0.25, 0.35, 0.20])
    for (_s0, _a0, b0), (_s1, a1, _b1) in zip(MID, MID[1:]):
        assert b0 == a1
    assert MID[0][1] == pytest.approx(1e-3)
    assert MID[-1][2] == pytest.approx(100.0)
    build_curve(self_similar_mid(1e9), snap_ticks=False)  # must validate


def test_self_similar_mid_scales_bounds_directly_by_parent_supply() -> None:
    parent_supply = 1e9
    spec = self_similar_mid(parent_supply)
    assert spec == [
        (s, a * parent_supply, b * parent_supply) for (s, a, b) in MID
    ]
    assert spec[0][1] == pytest.approx(1e-3 * parent_supply, rel=REL)
    assert spec[-1][2] == pytest.approx(100.0 * parent_supply, rel=REL)
