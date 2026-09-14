"""Chain graph, routing, arbitrage and fee-allocation tests."""

from __future__ import annotations

import math
import random

import pytest

from sim.clmm import ParentEthMarket
from sim.family import (
    BEST,
    DEPTH_CAPPED,
    ETH,
    FULL_LINE,
    PARENT_SOURCED,
    FeeAllocator,
    FenwickRangeAdd,
    ancestor_norm,
    ancestor_weight,
)
from sim.tests.helpers import build_chain, cpmm_pool, parity_market, scaled_pool

REL = 1e-9
WEI = 10**18


# --------------------------------------------------------------------------
# structure
# --------------------------------------------------------------------------
def test_chain_structure_and_promotion() -> None:
    chain = build_chain(4)
    assert len(chain) == 4
    assert chain.links[0].is_genesis
    assert chain.links[0].parent_index == -1
    assert chain.head.index == 3
    for i in range(1, 4):
        assert chain.links[i].parent_index == i - 1
        assert not chain.links[i].is_genesis
    assert chain.genesis_pool is chain.links[0].pool


def test_price_in_eth_is_the_product_of_spots() -> None:
    chain = build_chain(6)
    assert chain.price_in_eth(ETH) == 1.0
    expected = 1.0
    for i in range(6):
        expected *= chain.spot(i)
        assert chain.price_in_eth(i) == pytest.approx(expected, rel=REL)
        assert chain.fdv_eth(i) == pytest.approx(
            expected * chain.links[i].pool.supply, rel=REL
        )


def test_side_pools_are_parented_at_the_head_of_their_round() -> None:
    chain = build_chain(3)
    loser = chain.add_side_pool("LOSER-A", scaled_pool(1e4))
    assert loser.parent_index == 2
    assert chain.side_pools["LOSER-A"] is loser
    assert chain.side_price_in_eth("LOSER-A") == pytest.approx(
        loser.pool.price * chain.price_in_eth(2), rel=REL
    )
    # a later promotion does not re-parent an existing side pool
    chain.promote(scaled_pool(1e4 / chain.price_in_eth(2)), "#3")
    assert chain.side_pools["LOSER-A"].parent_index == 2
    with pytest.raises(ValueError):
        chain.add_side_pool("LOSER-A", scaled_pool(1e4))


def test_clone_is_independent() -> None:
    chain = build_chain(3)
    twin = chain.clone()
    chain.execute_route(chain.route(ETH, 2, FULL_LINE), 1e4)
    assert twin.price_in_eth(2) != pytest.approx(chain.price_in_eth(2), rel=1e-6)


# --------------------------------------------------------------------------
# routing
# --------------------------------------------------------------------------
def test_full_line_route_shapes() -> None:
    chain = build_chain(6)
    up = chain.route(ETH, 5, FULL_LINE)
    assert up.hops == 6
    assert [leg.index for leg in up.legs] == [0, 1, 2, 3, 4, 5]
    assert all(leg.buy for leg in up.legs)

    down = chain.route(5, ETH, FULL_LINE)
    assert [leg.index for leg in down.legs] == [5, 4, 3, 2, 1, 0]
    assert not any(leg.buy for leg in down.legs)

    across = chain.route(4, 1, FULL_LINE)
    assert [leg.index for leg in across.legs] == [4, 3, 2]
    assert chain.route(3, 3, FULL_LINE).hops == 0


def test_modes_pick_the_external_market_at_the_deepest_link() -> None:
    chain = build_chain(10)
    parity_market(chain, 9)

    assert not chain.route(ETH, 9, FULL_LINE).uses_external
    assert chain.route(ETH, 9, PARENT_SOURCED).uses_external
    assert chain.route(ETH, 9, BEST).uses_external
    # depth cap: 10 family hops, so a cap of 12 stays in the family
    assert not chain.route(ETH, 9, DEPTH_CAPPED(12)).uses_external
    assert chain.route(ETH, 9, DEPTH_CAPPED(3)).uses_external
    # exits use the same market
    assert chain.route(9, ETH, PARENT_SOURCED).uses_external
    # family-internal trades never touch it
    assert not chain.route(8, 2, BEST).uses_external


def test_best_ignores_an_uncompetitive_external_market() -> None:
    chain = build_chain(5, hop_fee_bps=5.0)
    # a shallow, badly priced market: entering through it is worse than 5 hops
    chain.add_external_market(
        4,
        ParentEthMarket(
            depth_eth=1.0, depth_token=1.0 / (chain.price_in_eth(4) * 3.0), fee_bps=100.0
        ),
    )
    assert not chain.route(ETH, 4, BEST).uses_external


def test_parent_sourced_beats_full_line_when_a_market_exists_at_link_9() -> None:
    chain = build_chain(10)
    parity_market(chain, 9)
    size = 5e3
    full = chain.quote_route(chain.route(ETH, 9, FULL_LINE), size)
    sourced = chain.quote_route(chain.route(ETH, 9, PARENT_SOURCED), size)
    assert full.effective_loss_frac > sourced.effective_loss_frac
    assert sourced.amount_out > full.amount_out
    # and the shortcut skips the edge fee entirely -- brief S6's disclosed risk
    assert full.protocol_fee_eth == pytest.approx(size * 0.01, rel=REL)
    assert sourced.protocol_fee_eth == 0.0


# --------------------------------------------------------------------------
# fees on a route
# --------------------------------------------------------------------------
def test_protocol_fee_is_charged_only_on_the_eth_edge() -> None:
    chain = build_chain(5)
    entry = chain.quote_route(chain.route(ETH, 4, FULL_LINE), 1e3)
    assert entry.protocol_fee_eth == pytest.approx(10.0, rel=REL)

    internal = chain.quote_route(chain.route(4, 1, FULL_LINE), 1e5)
    assert internal.protocol_fee_eth == 0.0

    # on the way out the fee is skimmed off the ETH the pool produced
    work = chain.clone()
    bought = work.execute_route(work.route(ETH, 4, FULL_LINE), 1e3)
    exit_ = work.execute_route(work.route(4, ETH, FULL_LINE), bought.amount_out)
    gross_eth = exit_.amount_out + exit_.protocol_fee_eth
    assert exit_.protocol_fee_eth == pytest.approx(gross_eth * 0.01, rel=1e-9)


def test_hop_fees_are_reported_per_leg() -> None:
    chain = build_chain(4, hop_fee_bps=10.0)
    res = chain.quote_route(chain.route(ETH, 3, FULL_LINE), 1e3)
    assert len(res.hop_fees) == len(res.legs) == 4
    assert all(f > 0.0 for f in res.hop_fees)
    assert res.hop_fee_total == pytest.approx(math.fsum(res.hop_fees), rel=REL)
    # the first leg's fee is 10 bps of the post-protocol-fee ETH input
    assert res.hop_fees[0] == pytest.approx(1e3 * 0.99 * 1e-3, rel=1e-6)


def test_exact_out_agrees_with_exact_in() -> None:
    chain = build_chain(5, hop_fee_bps=10.0)
    want = 1e5
    quoted = chain.quote_route(chain.route(ETH, 4, FULL_LINE), want, exact_in=False)
    assert quoted.amount_out == pytest.approx(want, rel=REL)
    replay = chain.quote_route(chain.route(ETH, 4, FULL_LINE), quoted.amount_in)
    assert replay.amount_out == pytest.approx(want, rel=1e-6)
    assert replay.protocol_fee_eth == pytest.approx(quoted.protocol_fee_eth, rel=1e-6)


# --------------------------------------------------------------------------
# the brief's first-order routing numbers
# --------------------------------------------------------------------------
def test_ten_hop_loss_matches_the_brief_within_25_percent() -> None:
    """$5k over ten 1%-fee hops: the brief quotes ~10% (``1 - 0.99**10``)."""
    chain = build_chain(10, reserve_eth=5e5, hop_fee_bps=100.0)
    route = chain.route(ETH, 9, FULL_LINE)
    assert route.hops == 10
    res = chain.quote_route(route, 5e3)
    expected = 1.0 - 0.99**10
    assert res.effective_loss_frac == pytest.approx(expected, rel=0.25)
    # fees dominate: price impact of $5k on $500k pools is a small extra
    fee_only = 1.0 - 0.99**11  # ten hops plus the 1% edge fee
    assert fee_only < res.effective_loss_frac < fee_only + 0.03


def test_loss_grows_with_depth_and_with_size() -> None:
    chain = build_chain(10)
    small = chain.quote_route(chain.route(ETH, 9, FULL_LINE), 1e2).effective_loss_frac
    big = chain.quote_route(chain.route(ETH, 9, FULL_LINE), 5e4).effective_loss_frac
    shallow = chain.quote_route(chain.route(ETH, 2, FULL_LINE), 1e2).effective_loss_frac
    assert big > small > shallow > 0.0


# --------------------------------------------------------------------------
# arbitrage
# --------------------------------------------------------------------------
def test_arbitrage_step_closes_a_rich_external_market() -> None:
    chain = build_chain(6, hop_fee_bps=10.0)
    fam = chain.price_in_eth(5)
    chain.add_external_market(
        5, ParentEthMarket(depth_eth=2e5, depth_token=2e5 / (fam * 1.20))
    )
    assert chain.external_edge(5) == pytest.approx(0.20, rel=1e-6)

    res = chain.arbitrage_step(5)
    assert res.direction == "buy_family"
    assert res.volume_eth > 0.0
    assert res.profit_eth > 0.0
    assert abs(res.edge_after) < abs(res.edge_before)


def test_arbitrage_step_handles_a_cheap_external_market_and_a_dead_edge() -> None:
    chain = build_chain(6, hop_fee_bps=10.0)
    fam = chain.price_in_eth(5)
    chain.add_external_market(
        5, ParentEthMarket(depth_eth=2e5, depth_token=2e5 / (fam * 0.80))
    )
    res = chain.arbitrage_step(5)
    assert res.direction == "buy_external"
    assert res.profit_eth > 0.0
    assert abs(res.edge_after) < abs(res.edge_before)

    # at parity there is nothing to do, and gas alone can kill a thin edge
    chain2 = build_chain(4)
    parity_market(chain2, 3)
    assert chain2.arbitrage_step(3).direction == "none"
    chain3 = build_chain(4, hop_fee_bps=10.0)
    fam3 = chain3.price_in_eth(3)
    chain3.add_external_market(
        3, ParentEthMarket(depth_eth=1e4, depth_token=1e4 / (fam3 * 1.001))
    )
    assert chain3.arbitrage_step(3, gas_cost_eth=1e9).direction == "none"


def test_propagate_arbitrage_visits_every_market() -> None:
    chain = build_chain(6, hop_fee_bps=10.0)
    for i in (2, 5):
        fam = chain.price_in_eth(i)
        chain.add_external_market(
            i, ParentEthMarket(depth_eth=2e5, depth_token=2e5 / (fam * 1.15))
        )
    out = chain.propagate_arbitrage(5)
    assert set(out) == {2, 5}
    assert all(r.profit_eth >= 0.0 for r in out.values())
    assert all(abs(chain.external_edge(i)) < 0.15 for i in (2, 5))


def test_cpmm_helper_reproduces_the_audit_arithmetic() -> None:
    """Sanity check on the (100, 100) segment used by the sandwich test."""
    pool = cpmm_pool(100.0, 100.0)
    assert pool.price == pytest.approx(1.0, rel=REL)
    assert pool.swap_exact_in(100.0, parent_in=True).amount_out == pytest.approx(
        50.0, rel=1e-5
    )
    assert pool.swap_exact_in(100.0, parent_in=True).amount_out == pytest.approx(
        100.0 / 6.0, rel=1e-5
    )


# --------------------------------------------------------------------------
# fee allocation
# --------------------------------------------------------------------------
def test_weight_function_and_normaliser() -> None:
    assert ancestor_weight(0.0) == 2.0
    assert ancestor_weight(1.0) == 1.0
    assert ancestor_weight(0.625) == pytest.approx(7.0 / 16.0, rel=REL)
    for M in (1, 2, 7, 50, 1000):
        brute = math.fsum(ancestor_weight(j / M) for j in range(M + 1))
        assert ancestor_norm(M) == pytest.approx(brute, rel=1e-12)
    with pytest.raises(ValueError):
        ancestor_norm(0)


@pytest.mark.parametrize("terminal", [0, 1, 2, 3, 9, 40])
def test_allocation_sums_to_exactly_the_fee(terminal: int) -> None:
    alloc = FeeAllocator()
    fee = 3.7
    split = alloc.allocate(fee, terminal)
    assert math.fsum(split.values()) == pytest.approx(fee, rel=0.0, abs=1e-15)
    assert split["dev"] == pytest.approx(fee * 0.20, rel=REL)
    assert split[f"creator:{terminal}"] == pytest.approx(fee * 0.10, rel=REL)
    M = max(terminal - 1, 0)
    assert f"reinforce:{M}" in split
    ancestors = {k: v for k, v in split.items() if k.startswith("ancestor:")}
    assert len(ancestors) == M + 1
    assert all(v >= 0.0 for v in ancestors.values())
    assert math.fsum(ancestors.values()) == pytest.approx(fee * 0.50, rel=1e-12)


def test_genesis_only_case_and_u_shape() -> None:
    alloc = FeeAllocator()
    for terminal in (0, 1):  # M = 0 both times: everything goes to genesis
        split = alloc.allocate(1.0, terminal)
        assert split["ancestor:0"] == pytest.approx(0.50, rel=1e-12)
        assert [k for k in split if k.startswith("ancestor:")] == ["ancestor:0"]

    w = alloc.ancestor_weights(9)  # M = 8
    assert len(w) == 9
    assert w[0] > w[8] > w[5]  # OG-heavy, U-shaped, minimum near r = 5/8
    assert min(w, key=w.get) == 5
    assert math.fsum(w.values()) == pytest.approx(1.0, rel=1e-12)


def test_share_validation() -> None:
    with pytest.raises(ValueError):
        FeeAllocator(dev_share=0.5, creator_share=0.5, reinforce_share=0.5,
                     ancestor_share=0.5)
    with pytest.raises(ValueError):
        FeeAllocator(dev_share=-0.1, creator_share=0.4, reinforce_share=0.3,
                     ancestor_share=0.4)
    with pytest.raises(ValueError):
        FeeAllocator().allocate(-1.0, 3)


# --------------------------------------------------------------------------
# Fenwick range-add vs a brute-force per-ancestor ledger
# --------------------------------------------------------------------------
def integer_coefficients(sleeve_wei: int, M: int) -> tuple[int, int, int]:
    """Exact integer form of ``sleeve * w(j/M) / Z(M)``.

    ``w(j/M)/Z(M) = 6 * (2M^2 - 5jM + 4j^2) / (M(M+1)(5M+4))``, so with
    ``D = M(M+1)(5M+4)`` the polynomial coefficients are floor divisions -- the
    same truncation a Solidity implementation would take.  ``c1`` is negative,
    which is the whole reason the trees have to be signed.
    """
    if M == 0:
        return (sleeve_wei, 0, 0)
    D = M * (M + 1) * (5 * M + 4)
    return (
        12 * sleeve_wei * M * M // D,
        -(30 * sleeve_wei * M) // D,
        24 * sleeve_wei // D,
    )


def test_fenwick_point_query_matches_a_brute_force_ledger() -> None:
    rng = random.Random(20260910)
    n = 256
    fen = FenwickRangeAdd(n)
    brute = [0] * n
    saw_negative_coefficient = False

    for _ in range(400):
        terminal = rng.randrange(0, n)
        M = max(terminal - 1, 0)
        fee_wei = rng.randrange(1, 10_000) * WEI  # 1 .. 10k ETH in wei
        sleeve = fee_wei // 2  # the 50% ancestor sleeve
        c0, c1, c2 = integer_coefficients(sleeve, M)
        fen.range_add(0, M, c0, c1, c2)
        for j in range(M + 1):
            brute[j] += c0 + c1 * j + c2 * j * j
        if c1 < 0:
            saw_negative_coefficient = True

    assert saw_negative_coefficient
    for j in range(n):
        assert fen.query(j) == brute[j]
        assert fen.query(j) >= 0  # every claim is non-negative...

    # ...even though the signed intermediates are not: an unsigned port of the
    # linear tree would underflow here.
    assert any(fen.coefficient_prefix(1, j) < 0 for j in range(n))


def test_fenwick_matches_the_float_allocator() -> None:
    """The integer ledger tracks :meth:`FeeAllocator.allocate` to ~1e-12."""
    alloc = FeeAllocator()
    fen = FenwickRangeAdd(64)
    fee = 1.0
    terminal = 20
    sleeve_wei = int(fee * alloc.ancestor_share * WEI)
    fen.range_add(0, alloc.parent_index(terminal),
                  *integer_coefficients(sleeve_wei, alloc.parent_index(terminal)))
    split = alloc.allocate(fee, terminal)
    for j in range(alloc.parent_index(terminal) + 1):
        assert fen.query(j) / WEI == pytest.approx(split[f"ancestor:{j}"], abs=1e-12)


def test_fenwick_bounds_checks() -> None:
    fen = FenwickRangeAdd(8)
    with pytest.raises(IndexError):
        fen.range_add(0, 8, 1, 0, 0)
    with pytest.raises(IndexError):
        fen.query(8)
    with pytest.raises(ValueError):
        FenwickRangeAdd(0)


def test_unknown_route_mode_rejected() -> None:
    from sim.family import RouteMode

    chain = build_chain(3)
    with pytest.raises(ValueError):
        chain.route(ETH, 2, RouteMode("NONSENSE"))
