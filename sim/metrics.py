"""Read-only diagnostics over a :class:`~sim.family.FamilyChain`.

Everything here is non-mutating: anything that has to trade does it on
``chain.clone()``.  The tables are the ones the README quotes -- depth per
generation, routing loss versus size and mode, how far a shock travels, and how
much embedded parent a decline hands back to sellers (brief S6).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from collections.abc import Iterable, Sequence

import pandas as pd

from .clmm import Pool
from .family import ETH, FULL_LINE, FamilyChain, RouteMode

__all__ = [
    "reserve_by_generation",
    "depth_by_generation",
    "route_loss_table",
    "drawdown_propagation",
    "parent_released_per_pct_decline",
    "fee_flow_by_recipient",
    "AttackPnL",
    "attack_pnl",
]


def reserve_by_generation(chain: FamilyChain) -> pd.DataFrame:
    """Per-link reserves, prices and FDV, in both parent and ETH units.

    ``reserve_eth`` is the reserve marked at the *parent's* ETH price, i.e. what
    the embedded liquidity is actually worth at the top of the line.
    """
    rows = []
    for link in chain.links:
        pool = link.pool
        parent_px = chain.price_in_eth(link.parent_index)
        reserve = pool.reserve_parent()
        rows.append(
            {
                "index": link.index,
                "name": link.name,
                "spot_in_parent": pool.price,
                "price_in_eth": chain.price_in_eth(link.index),
                "fdv_parent": pool.fdv(),
                "fdv_eth": chain.fdv_eth(link.index),
                "reserve_parent": reserve,
                "reserve_eth": reserve * parent_px,
                "tokens_sold_frac": pool.tokens_sold() / pool.supply,
                "max_absorption_parent": pool.max_absorption(),
            }
        )
    return pd.DataFrame(rows)


def depth_by_generation(chain: FamilyChain, pct: float = 0.01) -> pd.DataFrame:
    """Parent (and ETH) needed to move each link's price by ``+/- pct``.

    The two sides are not symmetric on a concentrated curve, and the sell side
    is the one that matters: it is the parent a decline releases to sellers.
    """
    if not 0.0 < pct < 1.0:
        raise ValueError("pct must be in (0, 1)")
    rows = []
    for link in chain.links:
        pool = link.pool
        parent_px = chain.price_in_eth(link.parent_index)
        F = pool.fdv()
        up = pool.quote_cost_to_fdv(F * (1.0 + pct))
        down = -pool.quote_cost_to_fdv(F * (1.0 - pct))
        rows.append(
            {
                "index": link.index,
                "name": link.name,
                "pct": pct,
                "parent_to_lift": up,
                "parent_released_on_decline": down,
                "eth_to_lift": up * parent_px,
                "eth_released_on_decline": down * parent_px,
            }
        )
    return pd.DataFrame(rows)


def route_loss_table(
    chain: FamilyChain,
    sizes: Sequence[float],
    modes: Sequence[RouteMode] = (FULL_LINE,),
    dst: int | None = None,
    src=ETH,
) -> pd.DataFrame:
    """Effective loss of an ETH -> ``dst`` buy, per size and per routing mode.

    Every row is quoted against a fresh clone, so the table is order-independent
    and the chain is untouched.
    """
    target = chain.head.index if dst is None else int(dst)
    rows = []
    for mode in modes:
        for size in sizes:
            work = chain.clone()
            route = work.route(src, target, mode, probe=size)
            res = work.execute_route(route, size)
            rows.append(
                {
                    "size_in": size,
                    "mode": str(mode),
                    "dst": target,
                    "hops": route.hops,
                    "uses_external": route.uses_external,
                    "amount_out": res.amount_out,
                    "protocol_fee_eth": res.protocol_fee_eth,
                    "hop_fee_total": res.hop_fee_total,
                    "effective_loss_frac": res.effective_loss_frac,
                }
            )
    return pd.DataFrame(rows)


def drawdown_propagation(
    chain: FamilyChain,
    shock_index: int,
    shock_frac: float,
    gas_cost_eth: float = 0.0,
    min_edge: float = 0.0,
) -> dict[int, float]:
    """Sell ``shock_frac`` of link ``i``'s float into its pool, then let arbs run.

    Returns the fractional drawdown of every link's ETH price.  With no external
    markets the only price that moves is the shocked pool's, so every descendant
    inherits exactly the same drawdown through the telescoping product and every
    ancestor is untouched -- the drawdown is monotone non-increasing as you walk
    away from the shock in either direction.  External markets break that: they
    let the shock feed back down the line.
    """
    chain._check_index(shock_index)
    if not 0.0 <= shock_frac <= 1.0:
        raise ValueError("shock_frac must be in [0, 1]")
    before = {link.index: chain.price_in_eth(link.index) for link in chain.links}

    work = chain.clone()
    pool = work.links[shock_index].pool
    float_tokens = max(pool.tokens_sold(), 0.0)
    if float_tokens > 0.0 and shock_frac > 0.0:
        pool.swap_exact_in(float_tokens * shock_frac, parent_in=False)
    work.propagate_arbitrage(shock_index, gas_cost_eth=gas_cost_eth, min_edge=min_edge)

    return {
        i: 1.0 - work.price_in_eth(i) / before[i] if before[i] > 0.0 else 0.0
        for i in before
    }


def parent_released_per_pct_decline(pool: Pool, pct: float) -> float:
    """Parent handed back to sellers by a ``pct`` decline in ``pool``'s price.

    Exact closed form (fees excluded): the negative of
    :meth:`~sim.clmm.Pool.quote_cost_to_fdv` at the lower FDV.  This is brief
    S6's "embedded parent released on the way down".
    """
    if not 0.0 < pct < 1.0:
        raise ValueError("pct must be in (0, 1)")
    return -pool.quote_cost_to_fdv(pool.fdv() * (1.0 - pct))


def fee_flow_by_recipient(ledger: Iterable[dict[str, float]]) -> pd.DataFrame:
    """Aggregate a sequence of :meth:`~sim.family.FeeAllocator.allocate` splits.

    Columns: ``recipient``, ``kind`` (``dev`` / ``creator`` / ``reinforce`` /
    ``ancestor``), ``target`` (link index, ``-1`` for the developer),
    ``amount``, ``share``.
    """
    columns = ["recipient", "kind", "target", "amount", "share"]
    totals: dict[str, float] = {}
    for entry in ledger:
        for recipient, amount in entry.items():
            totals[recipient] = totals.get(recipient, 0.0) + amount
    grand = math.fsum(totals.values())
    rows = []
    for recipient, amount in totals.items():
        kind, _, target = recipient.partition(":")
        rows.append(
            {
                "recipient": recipient,
                "kind": kind,
                "target": int(target) if target else -1,
                "amount": amount,
                "share": amount / grand if grand else 0.0,
            }
        )
    if not rows:
        return pd.DataFrame(columns=columns)
    return pd.DataFrame(rows, columns=columns).sort_values(
        ["kind", "target"]
    ).reset_index(drop=True)


@dataclass
class AttackPnL:
    """Book of one attack: what it cost, what it got back, what it netted."""

    name: str
    cost_eth: float
    proceeds_eth: float
    gas_eth: float = 0.0
    victim_loss_eth: float = 0.0

    @property
    def profit_eth(self) -> float:
        return self.proceeds_eth - self.cost_eth - self.gas_eth

    @property
    def roi(self) -> float:
        return self.profit_eth / self.cost_eth if self.cost_eth > 0.0 else 0.0

    @property
    def profitable(self) -> bool:
        return self.profit_eth > 0.0


def attack_pnl(
    name: str,
    cost_eth: float,
    proceeds_eth: float,
    gas_eth: float = 0.0,
    victim_loss_eth: float = 0.0,
) -> AttackPnL:
    """Build an :class:`AttackPnL` (kept as a function so scenarios read as prose)."""
    return AttackPnL(name, cost_eth, proceeds_eth, gas_eth, victim_loss_eth)
