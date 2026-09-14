"""Multicurve builder: supply shares over contiguous FDV bands.

A *spec* is a list of ``(share, Fa, Fb)`` triples: ``share`` of the token supply
is parked between fully-diluted valuations ``Fa`` and ``Fb`` (parent units).
Shares sum to 1 and the bands must be contiguous and ascending, so the whole
supply is on sale exactly once, with no gaps and no overlap -- the same shape
Doppler's Multicurve uses and the shape the Locker will encode on-chain.

The economics fall straight out of the closed form in :mod:`sim.clmm`: buying
out band ``i`` costs ``s_i * sqrt(Fa_i * Fb_i)`` parent, so the total cost to
lift a curve from its floor to full absorption is
``sum_i s_i * sqrt(Fa_i * Fb_i)`` -- independent of path and of trade sizing.
"""

from __future__ import annotations

import math

import pandas as pd

from .clmm import Pool, Range, sqrt_price_from_fdv

__all__ = [
    "Spec",
    "build_curve",
    "build_pool",
    "SINGLE",
    "INFINITE_LIKE",
    "WALL",
    "GENTLE",
    "single",
    "infinite_like",
    "wall",
    "gentle",
    "self_similar",
    "LADDER",
    "self_similar_ladder",
    "MID",
    "self_similar_mid",
    "assert_threshold_below_max_absorption",
    "cost_table",
    "buy_impact",
    "snap_fdv_to_tick",
    "TICK_BASE",
]

Spec = list[tuple[float, float, float]]

TICK_BASE = 1.0001

# Reference presets (FDV bounds in parent units, supply shares summing to 1).
SINGLE: Spec = [(1.0, 5e3, 5e6)]
INFINITE_LIKE: Spec = [(0.991, 5e3, 5e6), (0.009, 5e6, 5e9)]
WALL: Spec = [(0.30, 5e3, 2.5e5), (0.50, 2.5e5, 1e6), (0.20, 1e6, 1e7)]
GENTLE: Spec = [
    (0.25, 5e3, 5e4),
    (0.25, 5e4, 5e5),
    (0.25, 5e5, 5e6),
    (0.25, 5e6, 5e7),
]

# Default relative spec for :func:`self_similar`: bounds are multiples of the
# starting FDV (which is itself ``start_ratio`` of the parent's supply-value).
SELF_SIMILAR_RELATIVE: Spec = [(0.991, 1.0, 1e3), (0.009, 1e3, 1e6)]

# A wider, more gradual standard-curve calibration: bounds are fractions of the
# *parent supply* directly (i.e. FDV / parent_supply), not multiples of a
# start ratio -- see :func:`self_similar_ladder`.  10%/15%/35%/40% of supply
# sit over four decades from 0.1% to 100x the parent's own FDV, so a winner
# absorbing several multiples of a thin threshold is not forced to exhaust the
# curve the way :data:`SELF_SIMILAR_RELATIVE` is (Sim 1 finding).
LADDER: Spec = [
    (0.10, 1e-3, 1e-2),
    (0.15, 1e-2, 1e-1),
    (0.35, 1e-1, 1.0),
    (0.40, 1.0, 100.0),
]

# A body-heavier variant of LADDER: the same four decades of FDV/parent-supply
# bands, but 20%/25%/35%/20% of supply instead of 10%/15%/35%/40% -- 80% of
# supply now sits at or below 1x the parent's own FDV (vs 60% under LADDER),
# while trimming the top-decade tail from 40% to 20% so winners have more
# body to sell into before exhausting the curve.
MID: Spec = [
    (0.20, 1e-3, 1e-2),
    (0.25, 1e-2, 1e-1),
    (0.35, 1e-1, 1.0),
    (0.20, 1.0, 100.0),
]


def single() -> Spec:
    """One range, 5e3 -> 5e6 FDV."""
    return list(SINGLE)


def infinite_like() -> Spec:
    """Infinite-style: 99.1% in the body, 0.9% in a very long tail."""
    return list(INFINITE_LIKE)


def wall() -> Spec:
    """A thick mid wall: half the supply concentrated in 2.5e5 -> 1e6."""
    return list(WALL)


def gentle() -> Spec:
    """Four equal quarters across four decades."""
    return list(GENTLE)


def self_similar(
    parent_supply: float,
    start_ratio: float = 1e-3,
    spec_relative: Spec | None = None,
) -> Spec:
    """Scale a relative spec to absolute parent units.

    ``spec_relative`` bounds are expressed as multiples of the starting FDV,
    which is ``start_ratio * parent_supply`` parent units.  The result is a
    normal spec usable with :func:`build_curve`, so every link in the chain runs
    the same curve shape denominated in its own parent -- the self-similar
    property the family design depends on.
    """
    rel = SELF_SIMILAR_RELATIVE if spec_relative is None else spec_relative
    scale = start_ratio * parent_supply
    return [(s, a * scale, b * scale) for (s, a, b) in rel]


def self_similar_ladder(
    parent_supply: float,
    spec_relative: Spec | None = None,
) -> Spec:
    """Scale :data:`LADDER` to absolute parent units.

    Unlike :func:`self_similar`, ``LADDER``'s bounds are already fractions of
    the parent supply (FDV / parent_supply), so no ``start_ratio`` scale
    factor is needed -- multiplying straight through by ``parent_supply``
    gives a normal spec usable with :func:`build_curve`.
    """
    rel = LADDER if spec_relative is None else spec_relative
    return [(s, a * parent_supply, b * parent_supply) for (s, a, b) in rel]


def self_similar_mid(
    parent_supply: float,
    spec_relative: Spec | None = None,
) -> Spec:
    """Scale :data:`MID` to absolute parent units.

    Same convention as :func:`self_similar_ladder`: ``MID``'s bounds are
    already fractions of the parent supply, so multiplying straight through
    by ``parent_supply`` gives a normal spec usable with :func:`build_curve`.
    """
    rel = MID if spec_relative is None else spec_relative
    return [(s, a * parent_supply, b * parent_supply) for (s, a, b) in rel]


def snap_fdv_to_tick(fdv: float, supply: float, tick_spacing: int = 60) -> float:
    """Snap an FDV to the nearest usable tick price ``1.0001**i``, ``i % spacing == 0``.

    Price is ``P = FDV / supply``; the tick is ``i = log(P) / log(1.0001)``
    rounded to the nearest multiple of ``tick_spacing``.  The move is bounded by
    half a tick spacing in log-price, i.e. ``|ln(P'/P)| <= 0.5 * spacing * ln(1.0001)``.
    """
    price = fdv / supply
    tick = math.log(price) / math.log(TICK_BASE)
    snapped = round(tick / tick_spacing) * tick_spacing
    return TICK_BASE**snapped * supply


def _validate(spec: Spec) -> None:
    if not spec:
        raise ValueError("spec must not be empty")
    total = math.fsum(s for (s, _a, _b) in spec)
    assert abs(total - 1.0) <= 1e-12, f"shares must sum to 1, got {total!r}"
    for share, Fa, Fb in spec:
        assert share > 0.0, f"share must be positive, got {share!r}"
        assert 0.0 < Fa < Fb, f"need 0 < Fa < Fb, got ({Fa!r}, {Fb!r})"
    for (_s0, _a0, b0), (_s1, a1, _b1) in zip(spec, spec[1:]):
        assert math.isclose(b0, a1, rel_tol=1e-12), (
            f"ranges must be contiguous and ascending, got {b0!r} then {a1!r}"
        )


def build_curve(
    spec: Spec,
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
) -> list[Range]:
    """Turn a spec into the list of :class:`~sim.clmm.Range` positions.

    Shares must sum to 1 (within 1e-12) and the FDV bands must be contiguous and
    ascending.  With ``snap_ticks`` every *boundary* is snapped once (so
    contiguity survives) to the nearest tick price that is a multiple of
    ``tick_spacing``, mirroring what a real v4 position must do.
    """
    _validate(spec)
    bounds = [spec[0][1]] + [b for (_s, _a, b) in spec]
    if snap_ticks:
        bounds = [snap_fdv_to_tick(f, supply, tick_spacing) for f in bounds]
    return [
        Range.from_fdv(bounds[i], bounds[i + 1], share * supply, supply)
        for i, (share, _a, _b) in enumerate(spec)
    ]


def build_pool(
    spec: Spec,
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
    hop_fee_bps: float = 0.0,
    start_fdv: float | None = None,
    fee_on: str = "input",
) -> Pool:
    """Build a pool from a spec, priced at the curve floor unless told otherwise."""
    ranges = build_curve(spec, supply, snap_ticks, tick_spacing)
    sqrtP = (
        ranges[0].lower
        if start_fdv is None
        else sqrt_price_from_fdv(start_fdv, supply)
    )
    return Pool(ranges, supply, sqrtP, hop_fee_bps, fee_on)


def assert_threshold_below_max_absorption(
    spec: Spec,
    threshold: float,
    frac: float = 0.25,
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
) -> float:
    """Deploy-time invariant: threshold <= ``frac`` x the curve's max absorption.

    If a round's win threshold were anywhere near the total parent the curve can
    absorb, no candidate could ever win.  Returns the max absorption.
    """
    pool = build_pool(spec, supply, snap_ticks, tick_spacing)
    cap = pool.max_absorption()
    assert threshold <= frac * cap, (
        f"threshold {threshold!r} exceeds {frac!r} x max absorption {cap!r}"
    )
    return cap


def cost_table(
    spec: Spec,
    targets: list[float],
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
) -> pd.DataFrame:
    """Cost of lifting a fresh curve from its floor to each target FDV.

    Columns
    -------
    target_fdv:          the FDV to reach
    cost_parent:         parent required (exact closed form, fee-free)
    cost_over_fdv:       ``cost_parent / target_fdv`` -- capital efficiency of the pump
    supply_sold_frac:    fraction of supply the pool has handed out at that FDV
    buyer_mtm_at_target: mark-to-market value of all tokens sold, at the target price
    """
    pool = build_pool(spec, supply, snap_ticks, tick_spacing)
    rows = []
    for target in targets:
        sqrtP = sqrt_price_from_fdv(target, supply)
        sold_frac = pool.tokens_sold(sqrtP) / supply
        cost = pool.quote_cost_to_fdv(target)
        rows.append(
            {
                "target_fdv": target,
                "cost_parent": cost,
                "cost_over_fdv": cost / target,
                "supply_sold_frac": sold_frac,
                "buyer_mtm_at_target": sold_frac * target,
            }
        )
    return pd.DataFrame(rows)


def buy_impact(
    spec: Spec,
    F0: float,
    q: float,
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
    hop_fee_bps: float = 0.0,
) -> float:
    """FDV after buying ``q`` parent out of a curve currently sitting at FDV ``F0``."""
    pool = build_pool(
        spec,
        supply,
        snap_ticks,
        tick_spacing,
        hop_fee_bps=hop_fee_bps,
        start_fdv=F0,
    )
    pool.swap_exact_in(q, parent_in=True)
    return pool.fdv()
