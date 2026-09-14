"""Exactness tests for the constant-liquidity engine."""

from __future__ import annotations

import math

import pytest

from sim.clmm import (
    ParentEthMarket,
    Pool,
    Range,
    fdv_from_sqrt_price,
    sqrt_price_from_fdv,
)

S = 1e9
REL = 1e-9


def single_range_pool(share: float, Fa: float, Fb: float, **kw) -> Pool:
    """Pool with one range holding ``share * S`` tokens between Fa and Fb, priced at Fa."""
    r = Range.from_fdv(Fa, Fb, share * S, S)
    return Pool([r], S, sqrt_price_from_fdv(Fa, S), **kw)


# --------------------------------------------------------------------------
# 1. buying out a range costs s * sqrt(Fa * Fb)
# --------------------------------------------------------------------------
@pytest.mark.parametrize(
    "share,Fa,Fb",
    [
        (1.0, 5e3, 5e6),
        (0.30, 5e3, 2.5e5),
        (0.50, 2.5e5, 1e6),
        (0.009, 5e6, 5e9),
        (0.25, 5e4, 5e5),
    ],
)
def test_range_buyout_cost_is_geometric_mean(share: float, Fa: float, Fb: float) -> None:
    expected = share * math.sqrt(Fa * Fb)
    pool = single_range_pool(share, Fa, Fb)

    assert pool.quote_cost_to_fdv(Fb) == pytest.approx(expected, rel=REL)
    assert pool.max_absorption() == pytest.approx(expected, rel=REL)

    # and the swap engine agrees: an oversized buy consumes exactly that much
    res = pool.swap_exact_in(expected * 10.0, parent_in=True)
    assert res.exhausted
    assert res.amount_in_used == pytest.approx(expected, rel=REL)
    assert res.amount_out == pytest.approx(share * S, rel=REL)
    assert pool.fdv() == pytest.approx(Fb, rel=REL)
    assert pool.tokens_remaining() == pytest.approx(0.0, abs=1e-3)


# --------------------------------------------------------------------------
# 2. reversibility
# --------------------------------------------------------------------------
def test_round_trip_is_exact_without_fee() -> None:
    pool = single_range_pool(1.0, 5e3, 5e6)
    pool.set_fdv(5e4)
    q = 5e3

    bought = pool.swap_exact_in(q, parent_in=True)
    back = pool.swap_exact_in(bought.amount_out, parent_in=False)

    assert back.amount_out == pytest.approx(q, rel=REL)
    assert pool.fdv() == pytest.approx(5e4, rel=REL)
    assert pool.fees_accrued_parent == 0.0
    assert pool.fees_accrued_token == 0.0


def test_round_trip_with_parent_denominated_fee_is_exactly_one_minus_f_squared() -> None:
    """``fee_on='parent'`` reverses the pool leg exactly, so q -> q*(1-f)**2."""
    bps = 30.0
    f = bps / 1e4
    pool = single_range_pool(1.0, 5e3, 5e6, hop_fee_bps=bps, fee_on="parent")
    pool.set_fdv(5e4)
    q = 5e3

    bought = pool.swap_exact_in(q, parent_in=True)
    back = pool.swap_exact_in(bought.amount_out, parent_in=False)

    assert back.amount_out == pytest.approx(q * (1.0 - f) ** 2, rel=REL)
    assert pool.fees_accrued_parent == pytest.approx(
        q * f + q * (1.0 - f) * f, rel=REL
    )
    assert pool.fees_accrued_token == 0.0


def test_round_trip_with_input_fee_approximates_one_minus_f_squared() -> None:
    """Uniswap's convention: the sell leg feeds back fewer tokens than came out."""
    bps = 30.0
    f = bps / 1e4
    pool = single_range_pool(1.0, 5e3, 5e6, hop_fee_bps=bps)
    pool.set_fdv(5e4)
    q = 5e3

    bought = pool.swap_exact_in(q, parent_in=True)
    back = pool.swap_exact_in(bought.amount_out, parent_in=False)

    # close to (1-f)**2 but not exactly it; the gap scales with the price impact
    assert back.amount_out == pytest.approx(q * (1.0 - f) ** 2, rel=2e-3)
    assert back.amount_out < q
    assert pool.fees_accrued_parent == pytest.approx(q * f, rel=REL)
    assert pool.fees_accrued_token > 0.0


# --------------------------------------------------------------------------
# 3. multi-range crossing
# --------------------------------------------------------------------------
def three_range_pool(**kw) -> Pool:
    spec = [(0.30, 5e3, 2.5e5), (0.50, 2.5e5, 1e6), (0.20, 1e6, 1e7)]
    ranges = [Range.from_fdv(a, b, s * S, S) for (s, a, b) in spec]
    return Pool(ranges, S, ranges[0].lower, **kw)


def test_exact_in_across_three_ranges_matches_per_range_closed_forms() -> None:
    pool = three_range_pool()
    # enough to clear the first two bands and land mid-way up the third
    q = 0.30 * math.sqrt(5e3 * 2.5e5) + 0.50 * math.sqrt(2.5e5 * 1e6) + 1.0e5

    res = pool.swap_exact_in(q, parent_in=True)

    assert not res.exhausted
    assert res.ranges_crossed == 2

    # independent reconstruction: walk the ranges with dy = L*dsp, dx = L*d(1/sp)
    remaining = q
    expected_out = 0.0
    sp = sqrt_price_from_fdv(5e3, S)
    for r in pool.ranges:
        if remaining <= 0.0:
            break
        start = max(sp, r.lower)
        cap = r.L * (r.upper - start)
        end = r.upper if remaining >= cap else start + remaining / r.L
        expected_out += r.L * (1.0 / start - 1.0 / end)
        remaining -= r.L * (end - start)
        sp = end

    assert res.amount_out == pytest.approx(expected_out, rel=REL)
    assert res.sqrtP_after == pytest.approx(sp, rel=REL)
    assert pool.reserve_parent() == pytest.approx(q, rel=REL)


def test_exact_out_then_exact_in_symmetry() -> None:
    target_tokens = 0.62 * S  # spans the first two bands and into the third

    a = three_range_pool()
    out_leg = a.swap_exact_out(target_tokens, parent_in=True)
    assert not out_leg.exhausted
    assert out_leg.amount_out == pytest.approx(target_tokens, rel=REL)

    b = three_range_pool()
    in_leg = b.swap_exact_in(out_leg.amount_in_used, parent_in=True)

    assert in_leg.amount_out == pytest.approx(target_tokens, rel=REL)
    assert in_leg.sqrtP_after == pytest.approx(out_leg.sqrtP_after, rel=REL)
    assert in_leg.ranges_crossed == out_leg.ranges_crossed

    # and the reverse direction: sell for an exact parent amount, then replay it
    c = three_range_pool()
    c.swap_exact_in(3.0e5, parent_in=True)
    d = c.clone()
    want_parent = 1.0e5
    sell_out = c.swap_exact_out(want_parent, parent_in=False)
    assert sell_out.amount_out == pytest.approx(want_parent, rel=REL)
    sell_in = d.swap_exact_in(sell_out.amount_in_used, parent_in=False)
    assert sell_in.amount_out == pytest.approx(want_parent, rel=REL)
    assert sell_in.sqrtP_after == pytest.approx(sell_out.sqrtP_after, rel=REL)


# --------------------------------------------------------------------------
# 4. partial fills
# --------------------------------------------------------------------------
def test_partial_fill_on_exhausting_the_last_range_conserves_value() -> None:
    pool = three_range_pool()
    cap = pool.max_absorption()
    tokens_before = pool.tokens_remaining()

    res = pool.swap_exact_in(cap * 2.0, parent_in=True)

    assert res.exhausted
    assert res.amount_in_used == pytest.approx(cap, rel=REL)
    assert res.amount_out == pytest.approx(tokens_before, rel=REL)
    assert res.sqrtP_after == pytest.approx(pool.ranges[-1].upper, rel=REL)
    # value conservation: everything paid in is sitting in the pool as parent
    assert pool.reserve_parent() == pytest.approx(cap, rel=REL)
    assert pool.tokens_remaining() == pytest.approx(0.0, abs=1e-3)


def test_partial_fill_on_exact_out_and_on_the_sell_side() -> None:
    pool = three_range_pool()
    tokens_before = pool.tokens_remaining()

    res = pool.swap_exact_out(tokens_before * 1.5, parent_in=True)
    assert res.exhausted
    assert res.amount_out == pytest.approx(tokens_before, rel=REL)

    # selling more token back than the pool has parent for
    parent_in_pool = pool.reserve_parent()
    sell = pool.swap_exact_in(tokens_before * 10.0, parent_in=False)
    assert sell.exhausted
    assert sell.amount_out == pytest.approx(parent_in_pool, rel=REL)
    assert pool.sqrtP == pytest.approx(pool.ranges[0].lower, rel=REL)


def test_partial_fill_with_fee_bills_only_the_usable_input() -> None:
    bps = 30.0
    f = bps / 1e4
    pool = three_range_pool(hop_fee_bps=bps)
    cap = pool.max_absorption()

    res = pool.swap_exact_in(cap * 5.0, parent_in=True)

    assert res.exhausted
    assert res.amount_in_used == pytest.approx(cap / (1.0 - f), rel=REL)
    assert res.fee_paid == pytest.approx(res.amount_in_used * f, rel=REL)
    assert pool.reserve_parent() == pytest.approx(cap, rel=REL)


# --------------------------------------------------------------------------
# 5. analytics: reserves, path independence, inversion
# --------------------------------------------------------------------------
def test_reserve_parent_equals_parent_paid_in_and_is_path_independent() -> None:
    one = three_range_pool()
    one.swap_exact_in(4.0e5, parent_in=True)
    assert one.reserve_parent() == pytest.approx(4.0e5, rel=REL)

    many = three_range_pool()
    for _ in range(40):
        many.swap_exact_in(1.0e4, parent_in=True)
    assert many.reserve_parent() == pytest.approx(4.0e5, rel=REL)
    assert many.sqrtP == pytest.approx(one.sqrtP, rel=REL)
    assert many.tokens_sold() == pytest.approx(one.tokens_sold(), rel=REL)


def test_invert_reserve_to_fdv_round_trips() -> None:
    pool = three_range_pool()
    for q in (1.0e4, 1.0e5, 3.0e5):
        pool.swap_exact_in(q, parent_in=True)
        assert pool.invert_reserve_to_fdv(pool.reserve_parent()) == pytest.approx(
            pool.fdv(), rel=REL
        )


def test_tokens_sold_and_fdv_bookkeeping() -> None:
    pool = single_range_pool(1.0, 5e3, 5e6)
    assert pool.tokens_sold() == pytest.approx(0.0, abs=1e-3)
    assert pool.fdv() == pytest.approx(5e3, rel=REL)

    res = pool.swap_exact_in(6.7857e4, parent_in=True)
    assert pool.fdv() == pytest.approx(1e6, rel=1e-4)
    assert pool.tokens_sold() == pytest.approx(res.amount_out, rel=REL)
    assert pool.tokens_remaining() + pool.tokens_sold() == pytest.approx(S, rel=REL)


# --------------------------------------------------------------------------
# 6. gaps, added positions, external market
# --------------------------------------------------------------------------
def test_gap_between_ranges_is_traversed_for_free() -> None:
    lo = Range.from_fdv(5e3, 5e4, 0.5 * S, S)
    hi = Range.from_fdv(5e5, 5e6, 0.5 * S, S)
    pool = Pool([lo, hi], S, lo.lower)

    cost_low = 0.5 * math.sqrt(5e3 * 5e4)
    res = pool.swap_exact_in(cost_low, parent_in=True)

    assert res.amount_out == pytest.approx(0.5 * S, rel=REL)
    assert pool.fdv() == pytest.approx(5e4, rel=REL)

    # the very next unit of parent jumps the price to the bottom of the tail
    pool.swap_exact_in(1.0, parent_in=True)
    assert pool.fdv() > 5e5
    assert pool.quote_cost_to_fdv(5e6) == pytest.approx(
        0.5 * math.sqrt(5e5 * 5e6) - 1.0, rel=1e-6
    )


def test_add_locked_bid_position_deepens_the_floor() -> None:
    pool = single_range_pool(1.0, 5e3, 5e6)
    pool.swap_exact_in(1.0e5, parent_in=True)
    tokens_out = pool.tokens_sold()
    reserve_before = pool.reserve_parent()

    pool.add_locked_position(1e3, 5e3, parent_amount=2.5e4)
    assert pool.reserve_parent() == pytest.approx(reserve_before + 2.5e4, rel=REL)

    # dumping the whole float now returns more than the original curve could pay,
    # because the bid range keeps buying below the old floor
    sell = pool.swap_exact_in(tokens_out * 5.0, parent_in=False)
    assert sell.amount_out > reserve_before
    assert sell.amount_out <= reserve_before + 2.5e4
    assert pool.fdv() < 5e3  # price pushed under the original curve floor


def test_add_locked_position_rejects_wrong_side() -> None:
    pool = single_range_pool(1.0, 5e3, 5e6)
    pool.set_fdv(5e4)
    with pytest.raises(ValueError):
        pool.add_locked_position(1e5, 2e5, parent_amount=1.0)  # bid above spot
    with pytest.raises(ValueError):
        pool.add_locked_position(1e3, 2e3, token_amount=1.0)  # ask below spot
    with pytest.raises(ValueError):
        pool.add_locked_position(1e3, 2e3)  # neither side


def test_sqrt_price_fdv_helpers_are_inverse() -> None:
    for fdv in (5e3, 1e6, 5e9):
        sp = sqrt_price_from_fdv(fdv, S)
        assert fdv_from_sqrt_price(sp, S) == pytest.approx(fdv, rel=REL)


def test_parent_eth_market_is_constant_product() -> None:
    m = ParentEthMarket(depth_eth=100.0, depth_token=1e6, fee_bps=30.0)
    k = m.depth_eth * m.depth_token
    out = m.swap_exact_in(10.0, eth_in=True)

    assert out > 0.0
    assert m.depth_eth * m.depth_token >= k  # fee is skimmed before the invariant
    assert m.fees_accrued_eth == pytest.approx(10.0 * 0.003, rel=REL)
    assert m.price == pytest.approx(m.depth_eth / m.depth_token, rel=REL)
