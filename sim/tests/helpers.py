"""Shared scenario builders for the family-chain tests.

The reference chain is self-similar: every link runs the same SINGLE-shaped
curve (one range spanning three decades of FDV) denominated in its own parent,
scaled so that each pool holds the same *ETH-equivalent* reserve, and priced a
little above its floor.  Fixing the dollar depth fixes the dollar FDV, so every
link ends up with the same ETH price -- which is exactly the self-similar
property the design leans on.
"""

from __future__ import annotations

from sim.clmm import ParentEthMarket, Pool, Range
from sim.curves import build_pool
from sim.family import FamilyChain

SUPPLY = 1e9
RANGE_RATIO = 1000.0  # SINGLE spans 5e3 -> 5e6, i.e. three decades
FLOOR_MULT = 1.35  # pools trade 35% above their floor FDV


def scaled_pool(
    reserve_parent: float,
    floor_mult: float = FLOOR_MULT,
    hop_fee_bps: float = 100.0,
    supply: float = SUPPLY,
) -> Pool:
    """SINGLE-shaped pool holding exactly ``reserve_parent`` of its numeraire.

    The reserve of a single-range curve is linear in the FDV bounds, so one
    unit-scale build is enough to solve for the scale exactly.
    """
    unit = build_pool(
        [(1.0, 1.0, RANGE_RATIO)], supply, snap_ticks=False, start_fdv=floor_mult
    ).reserve_parent()
    F_lo = reserve_parent / unit
    return build_pool(
        [(1.0, F_lo, RANGE_RATIO * F_lo)],
        supply,
        snap_ticks=True,
        hop_fee_bps=hop_fee_bps,
        start_fdv=floor_mult * F_lo,
    )


def build_chain(
    n_links: int = 10,
    reserve_eth: float = 5e5,
    hop_fee_bps: float = 100.0,
    floor_mult: float = FLOOR_MULT,
    protocol_fee_bps: float = 100.0,
) -> FamilyChain:
    """A trunk of ``n_links`` links (indices 0..n-1) each ~``reserve_eth`` deep."""
    chain = FamilyChain(
        scaled_pool(reserve_eth, floor_mult, hop_fee_bps),
        protocol_fee_bps=protocol_fee_bps,
    )
    for i in range(1, n_links):
        parent_px = chain.price_in_eth(i - 1)
        chain.promote(
            scaled_pool(reserve_eth / parent_px, floor_mult, hop_fee_bps), f"#{i}"
        )
    return chain


def parity_market(
    chain: FamilyChain, index: int, depth_eth: float = 5e6, fee_bps: float = 30.0
) -> ParentEthMarket:
    """External ETH market for link ``index``, priced at the family's own price."""
    market = ParentEthMarket(
        depth_eth=depth_eth,
        depth_token=depth_eth / chain.price_in_eth(index),
        fee_bps=fee_bps,
    )
    return chain.add_external_market(index, market)


def cpmm_pool(parent: float, token: float, supply: float = 1.0) -> Pool:
    """A constant-product segment as a single very wide concentrated range.

    A range with ``L`` behaves exactly like a CPMM with virtual reserves
    ``(L/sqrtP, L*sqrtP)``; with bounds far outside the region traded, the
    virtual and real reserves agree to 1e-6.  ``supply=1`` makes FDV == price,
    which keeps the audit's ``(100 parent, 100 child)`` arithmetic readable.
    """
    sqrtP = (parent / token) ** 0.5
    L = (parent * token) ** 0.5
    return Pool([Range(1e-6 * sqrtP, 1e6 * sqrtP, L)], supply, sqrtP)
