"""Keeper deployment of the fee sleeves as protocol-owned buy support.

Brief S4: ancestor and reinforcement balances are never paid out as ETH.  The
keeper ``deploy(j)`` spends them by *buying up the chain* to token ``j-1`` (ETH
for ``j = 0``) and depositing the proceeds through the Locker as a single-sided
bid just under link ``j``'s spot -- protocol-owned liquidity that can never be
removed.  The caller earns a 1% bounty on a verified deposit.

Three policies are modelled:

``SINGLE_SIDED_BID``  the brief's design: buy the parent, park it as a bid.
``BUY_AND_BURN``      buy token ``j`` and take it out of circulation (the
                      variant the design review told us to delete from v1;
                      kept here so the sim can price the difference).
``TWO_SIDED``         split the budget and add a symmetric range around spot.

Execution bounds
----------------
Design review finding 9: a permissionless deployment with no execution bound sells the
vault's buy to a sandwicher.  ``twap`` supplies the 30-minute observation and
``twap_tol`` (default +/-3%, per brief S4) the band; every pool leg on the
route is checked *before* anything executes, so a failed check reverts the whole
deployment (``deploy`` returns ``None``) with no state change.  A scalar
``twap`` applies to every pool leg of the route; pass a ``dict`` keyed by link
index for a multi-hop route (a key for ``j`` itself also bounds the pool the
bid lands in).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .clmm import Pool
from .family import ETH, FULL_LINE, FamilyChain, RouteMode, RouteResult

__all__ = [
    "SINGLE_SIDED_BID",
    "BUY_AND_BURN",
    "TWO_SIDED",
    "POLICIES",
    "DeployResult",
    "deploy",
]

SINGLE_SIDED_BID = "SINGLE_SIDED_BID"
BUY_AND_BURN = "BUY_AND_BURN"
TWO_SIDED = "TWO_SIDED"
POLICIES = (SINGLE_SIDED_BID, BUY_AND_BURN, TWO_SIDED)


@dataclass
class DeployResult:
    """Outcome of one keeper deployment.

    ``price_impact_on_route`` is the fractional move in the deepest pool the
    route touched -- the number a sandwicher is trying to inflate.
    ``parent_undeployed`` is budget that hit the per-call size cap (brief S4:
    at most 2% of ``j``'s parent reserve per call) and stays in the vault.
    """

    parent_deposited: float
    price_impact_on_route: float
    bounty: float
    policy: str = SINGLE_SIDED_BID
    generation: int = 0
    tokens_burned: float = 0.0
    token_deposited: float = 0.0
    parent_undeployed: float = 0.0
    route_result: RouteResult | None = None
    ranges_added: list = field(default_factory=list)


def _twap_for(twap, index: int) -> float | None:
    if twap is None:
        return None
    if isinstance(twap, dict):
        return twap.get(index)
    return float(twap)


def _within_band(chain: FamilyChain, route, twap, tol: float, j: int) -> bool:
    """Every pool leg (and, if quoted, pool ``j``) must sit inside the TWAP band."""
    if twap is None:
        return True
    checks = [(leg.index, chain.links[leg.index].pool.price)
              for leg in route.legs if not leg.external]
    ref_j = _twap_for(twap, j) if isinstance(twap, dict) else None
    if ref_j is not None:
        checks.append((j, chain.links[j].pool.price))
    for index, price in checks:
        ref = _twap_for(twap, index)
        if ref is None or ref <= 0.0:
            continue
        if abs(price / ref - 1.0) > tol:
            return False
    return True


def _deepest_pool(chain: FamilyChain, route) -> Pool | None:
    pool_legs = [leg for leg in route.legs if not leg.external]
    if not pool_legs:
        return None
    return chain.links[pool_legs[-1].index].pool


def _buy(chain: FamilyChain, dst, budget: float, mode: RouteMode):
    """Execute a buy and report (result, fractional impact on the deepest pool)."""
    route = chain.route(ETH, dst, mode)
    pool = _deepest_pool(chain, route)
    before = pool.price if pool is not None else 0.0
    res = chain.execute_route(route, budget)
    impact = (pool.price / before - 1.0) if pool is not None and before > 0.0 else 0.0
    return res, impact


def deploy(
    chain: FamilyChain,
    generation_j: int,
    eth_amount: float,
    policy: str = SINGLE_SIDED_BID,
    bid_width: float = 0.10,
    twap: float | dict[int, float] | None = None,
    twap_tol: float = 0.03,
    max_frac_of_reserve: float = 0.02,
    bounty_frac: float = 0.01,
    mode: RouteMode = FULL_LINE,
) -> DeployResult | None:
    """Spend ``eth_amount`` of vault ETH as buy support for link ``generation_j``.

    Returns ``None`` -- the on-chain revert -- when a supplied TWAP bound is
    violated; nothing is executed in that case.
    """
    if policy not in POLICIES:
        raise ValueError(f"unknown policy {policy!r}")
    if eth_amount < 0.0:
        raise ValueError("eth_amount must be non-negative")
    j = int(generation_j)
    chain._check_index(j)
    pool_j = chain.links[j].pool
    parent_endpoint = ETH if chain.links[j].is_genesis else chain.links[j].parent_index

    bounty = eth_amount * bounty_frac
    budget = eth_amount - bounty

    # --- execution bounds first: a failed check must not touch any pool -------
    if policy == BUY_AND_BURN:
        probe_routes = [chain.route(ETH, j, mode)]
    elif policy == TWO_SIDED:
        probe_routes = [chain.route(ETH, parent_endpoint, mode), chain.route(ETH, j, mode)]
    else:
        probe_routes = [chain.route(ETH, parent_endpoint, mode)]
    for route in probe_routes:
        if not _within_band(chain, route, twap, twap_tol, j):
            return None

    if policy == BUY_AND_BURN:
        res, impact = _buy(chain, j, budget, mode)
        # the tokens leave the pool and are never seen again: no liquidity added
        return DeployResult(
            parent_deposited=0.0,
            price_impact_on_route=impact,
            bounty=bounty,
            policy=policy,
            generation=j,
            tokens_burned=res.amount_out,
            route_result=res,
        )

    if policy == TWO_SIDED:
        half = 0.5 * budget
        res_p, impact_p = _buy(chain, parent_endpoint, half, mode)
        res_t, impact_t = _buy(chain, j, half, mode)
        F = pool_j.fdv()
        cap = max_frac_of_reserve * pool_j.reserve_parent()
        parent_amt = min(res_p.amount_out, cap) if cap > 0.0 else 0.0
        token_amt = res_t.amount_out
        added = []
        if parent_amt > 0.0:
            added.append(pool_j.add_locked_position(F / (1.0 + bid_width), F,
                                                    parent_amount=parent_amt))
        if token_amt > 0.0:
            added.append(pool_j.add_locked_position(F, F * (1.0 + bid_width),
                                                    token_amount=token_amt))
        return DeployResult(
            parent_deposited=parent_amt,
            price_impact_on_route=max(impact_p, impact_t),
            bounty=bounty,
            policy=policy,
            generation=j,
            token_deposited=token_amt,
            parent_undeployed=res_p.amount_out - parent_amt,
            route_result=res_p,
            ranges_added=added,
        )

    # SINGLE_SIDED_BID
    res, impact = _buy(chain, parent_endpoint, budget, mode)
    parent = res.amount_out
    cap = max_frac_of_reserve * pool_j.reserve_parent()
    deposited = min(parent, cap) if cap > 0.0 else 0.0
    added = []
    if deposited > 0.0:
        F = pool_j.fdv()
        added.append(
            pool_j.add_locked_position(F * (1.0 - bid_width), F, parent_amount=deposited)
        )
    return DeployResult(
        parent_deposited=deposited,
        price_impact_on_route=impact,
        bounty=bounty,
        policy=policy,
        generation=j,
        parent_undeployed=parent - deposited,
        route_result=res,
        ranges_added=added,
    )
