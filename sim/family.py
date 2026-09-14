"""The canonical chain graph: links, routing, arbitrage and fee allocation.

A :class:`FamilyChain` is the trunk GENESIS -> #1 -> #2 -> ... of the design
brief.  Link ``0`` is genesis (its parent is native ETH); every later link's
parent is the link before it, so ``links[i].pool`` quotes token ``i`` in token
``i-1``.  Losing candidates stay tradable as :attr:`FamilyChain.side_pools`,
parented at whatever the head was during their round.

Prices
------
``spot(i)`` is the pool price of link ``i`` in its parent.  ``price_in_eth(i)``
is the telescoping product ``spot(i) * spot(i-1) * ... * spot(0)`` -- the whole
reason a deep link is expensive to reach and fragile on the way down.

Routing
-------
A :class:`Route` is an ordered list of legs.  Four modes:

``FULL_LINE``       every hop stays inside the family.
``PARENT_SOURCED``  may enter/exit through an external ETH market at the
                    deepest link that has one, skipping the hops below it
                    (and, per brief S6, the 1% edge fee -- a disclosed risk).
``DEPTH_CAPPED(k)`` external markets only when the family route is longer
                    than ``k`` hops.
``BEST``            quote every candidate and keep the best fill.

Fees
----
The 1% protocol fee is charged *only* on the ETH side of a genesis-pool leg
(brief S4): on the input when ETH enters the family, on the output when it
leaves.  The per-hop fee ``f_hop`` is charged by the pools themselves
(``Pool(hop_fee_bps=...)``), never by the router.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace
from typing import NamedTuple, Union

from .clmm import ParentEthMarket, Pool, SwapResult

__all__ = [
    "ETH",
    "Link",
    "FamilyChain",
    "RouteMode",
    "FULL_LINE",
    "PARENT_SOURCED",
    "BEST",
    "DEPTH_CAPPED",
    "Leg",
    "Route",
    "RouteResult",
    "ArbResult",
    "FeeAllocator",
    "FenwickRangeAdd",
    "ancestor_weight",
    "ancestor_norm",
]

ETH = "ETH"
Endpoint = Union[str, int]  # "ETH" or a link index

_ETH_INDEX = -1


def _idx(endpoint: Endpoint) -> int:
    """``"ETH"`` -> -1, an int passes through."""
    if endpoint == ETH:
        return _ETH_INDEX
    return int(endpoint)


# ---------------------------------------------------------------------------
# links
# ---------------------------------------------------------------------------
@dataclass
class Link:
    """One token in the family: its pool, quoted in its parent."""

    index: int
    name: str
    pool: Pool
    parent_index: int  # -1 == ETH

    @property
    def is_genesis(self) -> bool:
        return self.parent_index == _ETH_INDEX


# ---------------------------------------------------------------------------
# route modes
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class RouteMode:
    """Routing policy.  ``k`` is only used by ``DEPTH_CAPPED``."""

    name: str
    k: int | None = None

    def __str__(self) -> str:  # pragma: no cover - cosmetic
        return self.name if self.k is None else f"{self.name}({self.k})"


FULL_LINE = RouteMode("FULL_LINE")
PARENT_SOURCED = RouteMode("PARENT_SOURCED")
BEST = RouteMode("BEST")


def DEPTH_CAPPED(k: int) -> RouteMode:
    """Route mode that only reaches for an external market past ``k`` hops."""
    return RouteMode("DEPTH_CAPPED", int(k))


class Leg(NamedTuple):
    """One hop: ``venue`` is the pool (or external market), ``buy`` the direction.

    ``buy=True`` means "parent/ETH in, token out" (price up).  ``index`` is the
    link the venue belongs to, so a leg can be re-resolved against a *clone* of
    the chain for non-mutating quotes.
    """

    venue: object
    buy: bool
    index: int
    external: bool = False


@dataclass
class Route:
    """An ordered list of legs plus the endpoints it was built for."""

    legs: list[Leg]
    src: int
    dst: int
    mode: RouteMode = FULL_LINE

    @property
    def hops(self) -> int:
        return len(self.legs)

    @property
    def uses_external(self) -> bool:
        return any(leg.external for leg in self.legs)

    def __len__(self) -> int:  # pragma: no cover - convenience
        return len(self.legs)


@dataclass
class RouteResult:
    """Outcome of executing a route.

    ``hop_fees`` is per-leg and denominated in that leg's fee asset (the pools
    decide; see :mod:`sim.clmm`).  ``effective_loss_frac`` compares the ETH
    value out against the ETH value in at *pre-trade* mid prices, so it bundles
    fees and price impact into the number the brief quotes.
    """

    amount_out: float
    legs: list[SwapResult]
    hop_fees: list[float]
    protocol_fee_eth: float
    effective_loss_frac: float
    amount_in: float = 0.0
    exhausted: bool = False

    @property
    def hop_fee_total(self) -> float:
        return math.fsum(self.hop_fees)


# ---------------------------------------------------------------------------
# arbitrage
# ---------------------------------------------------------------------------
@dataclass
class ArbResult:
    """One :meth:`FamilyChain.arbitrage_step` outcome (``volume_eth`` = ETH cycled)."""

    index: int
    direction: str  # "buy_family" | "buy_external" | "none"
    volume_eth: float
    profit_eth: float
    edge_before: float
    edge_after: float


# ---------------------------------------------------------------------------
# the chain
# ---------------------------------------------------------------------------
class FamilyChain:
    """Canonical trunk plus the routing / arbitrage / accounting it implies."""

    def __init__(
        self,
        genesis_pool: Pool,
        genesis_name: str = "GENESIS",
        protocol_fee_bps: float = 100.0,
    ) -> None:
        self.links: list[Link] = [
            Link(index=0, name=genesis_name, pool=genesis_pool, parent_index=_ETH_INDEX)
        ]
        self.side_pools: dict[str, Link] = {}
        self.external_markets: dict[int, ParentEthMarket] = {}
        self.protocol_fee_bps = float(protocol_fee_bps)

    # -- structure -------------------------------------------------------------
    @property
    def genesis_pool(self) -> Pool:
        return self.links[0].pool

    @property
    def head(self) -> Link:
        return self.links[-1]

    def __len__(self) -> int:
        return len(self.links)

    @property
    def protocol_fee_rate(self) -> float:
        return self.protocol_fee_bps / 1e4

    def promote(self, pool: Pool, name: str) -> Link:
        """Append the next canonical link.  Its parent is the current head."""
        link = Link(
            index=len(self.links), name=name, pool=pool, parent_index=self.head.index
        )
        self.links.append(link)
        return link

    def add_side_pool(
        self, name: str, pool: Pool, parent_index: int | None = None
    ) -> Link:
        """Register a losing candidate: tradable forever, parented at the head."""
        if name in self.side_pools:
            raise ValueError(f"side pool {name!r} already registered")
        parent = self.head.index if parent_index is None else int(parent_index)
        if not _ETH_INDEX <= parent < len(self.links):
            raise ValueError(f"bad parent index {parent}")
        link = Link(
            index=-2 - len(self.side_pools), name=name, pool=pool, parent_index=parent
        )
        self.side_pools[name] = link
        return link

    def add_external_market(self, index: int, market: ParentEthMarket) -> ParentEthMarket:
        """Attach an external ETH market quoting link ``index`` directly in ETH."""
        self._check_index(index)
        self.external_markets[index] = market
        return market

    def clone(self) -> "FamilyChain":
        """Copy: pools cloned, markets copied, structure preserved."""
        c = FamilyChain(
            self.links[0].pool.clone(), self.links[0].name, self.protocol_fee_bps
        )
        for link in self.links[1:]:
            c.links.append(replace(link, pool=link.pool.clone()))
        for name, link in self.side_pools.items():
            c.side_pools[name] = replace(link, pool=link.pool.clone())
        for i, m in self.external_markets.items():
            c.external_markets[i] = replace(m)
        return c

    def _check_index(self, i: int) -> None:
        if not 0 <= i < len(self.links):
            raise IndexError(f"link {i} does not exist (chain has {len(self.links)})")

    # -- prices ----------------------------------------------------------------
    def spot(self, i: int) -> float:
        """Price of link ``i`` in *its parent*."""
        self._check_index(i)
        return self.links[i].pool.price

    def price_in_eth(self, i: Endpoint) -> float:
        """Price of link ``i`` in ETH: the product of spots down to ETH."""
        j = _idx(i)
        if j == _ETH_INDEX:
            return 1.0
        self._check_index(j)
        p = 1.0
        while j != _ETH_INDEX:
            link = self.links[j]
            p *= link.pool.price
            j = link.parent_index
        return p

    def fdv_eth(self, i: int) -> float:
        """``price_in_eth(i) * supply``."""
        self._check_index(i)
        return self.price_in_eth(i) * self.links[i].pool.supply

    def fdv_parent(self, i: int) -> float:
        """FDV of link ``i`` in its own parent's units."""
        self._check_index(i)
        return self.links[i].pool.fdv()

    def side_price_in_eth(self, name: str) -> float:
        link = self.side_pools[name]
        return link.pool.price * self.price_in_eth(link.parent_index)

    # -- routing ---------------------------------------------------------------
    def _family_legs(self, src: int, dst: int) -> list[Leg]:
        """Pure-family legs between two indices (ETH is -1)."""
        legs: list[Leg] = []
        if dst > src:
            for i in range(src + 1, dst + 1):
                legs.append(Leg(self.links[i].pool, True, i, False))
        else:
            for i in range(src, dst, -1):
                legs.append(Leg(self.links[i].pool, False, i, False))
        return legs

    def _external_candidate(self, src: int, dst: int) -> list[Leg] | None:
        """Legs that enter/exit through the deepest usable external market."""
        if src != _ETH_INDEX and dst != _ETH_INDEX:
            return None  # family-internal trades never touch the ETH markets
        deep = max(src, dst)
        usable = [i for i in sorted(self.external_markets) if i <= deep]
        if not usable:
            return None
        e = usable[-1]
        market = self.external_markets[e]
        if dst == _ETH_INDEX:  # exit: family down to e, then out through the market
            return self._family_legs(src, e) + [Leg(market, False, e, True)]
        return [Leg(market, True, e, True)] + self._family_legs(e, dst)

    def route(
        self,
        src: Endpoint,
        dst: Endpoint,
        mode: RouteMode = FULL_LINE,
        probe: float | None = None,
    ) -> Route:
        """Build a route from ``src`` to ``dst`` under ``mode``.

        ``PARENT_SOURCED`` and ``BEST`` quote the family route against the
        external-market route with a small ``probe`` size and keep the cheaper
        one.  ``dst`` may be ``"ETH"`` as well as a link index, so exits use the
        same machinery as entries.
        """
        s, d = _idx(src), _idx(dst)
        if s == d:
            return Route([], s, d, mode)
        family = self._family_legs(s, d)
        if mode.name == "FULL_LINE":
            return Route(family, s, d, mode)
        if mode.name not in ("PARENT_SOURCED", "BEST", "DEPTH_CAPPED"):
            raise ValueError(f"unknown route mode {mode!r}")

        alt = self._external_candidate(s, d)
        if alt is None:
            return Route(family, s, d, mode)
        if mode.name == "DEPTH_CAPPED" and len(family) <= (mode.k or 0):
            return Route(family, s, d, mode)

        q = self._probe_size(s) if probe is None else probe
        best = max(
            (family, alt),
            key=lambda legs: self._quote_out(Route(legs, s, d, mode), q),
        )
        return Route(best, s, d, mode)

    def _probe_size(self, src: int) -> float:
        """A small notional in ``src`` units used to compare candidate routes."""
        if src == _ETH_INDEX:
            return max(self.links[0].pool.reserve_parent() * 1e-3, 1e-9)
        return max(self.links[src].pool.supply * 1e-9, 1e-9)

    def _quote_out(self, route: Route, amount_in: float) -> float:
        try:
            return self.quote_route(route, amount_in).amount_out
        except (ValueError, ZeroDivisionError):  # pragma: no cover - defensive
            return -math.inf

    # -- execution -------------------------------------------------------------
    def quote_route(
        self, route: Route, amount_in: float, exact_in: bool = True
    ) -> RouteResult:
        """Non-mutating :meth:`execute_route` (runs against a clone of the chain)."""
        return self.clone().execute_route(route, amount_in, exact_in)

    def execute_route(
        self, route: Route, amount_in: float, exact_in: bool = True
    ) -> RouteResult:
        """Run ``route``, mutating every venue it touches.

        ``exact_in=False`` treats ``amount_in`` as the desired *output* and
        walks the legs backwards with exact-output swaps; each pool appears at
        most once in a route, so the resulting state is identical to the
        equivalent exact-input execution.
        """
        legs = route.legs
        value_in_eth = self.price_in_eth(route.src)
        value_out_eth = self.price_in_eth(route.dst)
        if not legs:
            return RouteResult(amount_in, [], [], 0.0, 0.0, amount_in)

        results: list[SwapResult] = []
        fees: list[float] = []
        protocol_fee = 0.0
        exhausted = False
        rate = self.protocol_fee_rate

        if exact_in:
            amt = amount_in
            for leg in legs:
                venue = self._resolve(leg)
                eth_edge = (not leg.external) and self.links[leg.index].is_genesis
                if eth_edge and leg.buy:
                    fee = amt * rate
                    protocol_fee += fee
                    amt -= fee
                res = self._swap_in(venue, leg, amt)
                if eth_edge and not leg.buy:
                    fee = res.amount_out * rate
                    protocol_fee += fee
                    res = replace(res, amount_out=res.amount_out - fee)
                results.append(res)
                fees.append(res.fee_paid)
                exhausted = exhausted or res.exhausted
                amt = res.amount_out
            amount_out, used = amt, amount_in
        else:
            want = amount_in
            for leg in reversed(legs):
                venue = self._resolve(leg)
                eth_edge = (not leg.external) and self.links[leg.index].is_genesis
                if eth_edge and not leg.buy:  # the ETH we want is net of the fee
                    gross = want / (1.0 - rate) if rate else want
                    protocol_fee += gross - want
                    want = gross
                res = self._swap_out(venue, leg, want)
                need = res.amount_in_used
                if eth_edge and leg.buy:  # ETH in must gross up for the fee
                    gross = need / (1.0 - rate) if rate else need
                    protocol_fee += gross - need
                    need = gross
                    res = replace(res, amount_in_used=gross)
                results.append(res)
                fees.append(res.fee_paid)
                exhausted = exhausted or res.exhausted
                want = need
            results.reverse()
            fees.reverse()
            amount_out, used = amount_in, want

        gross_in_eth = used * value_in_eth
        loss = (
            1.0 - (amount_out * value_out_eth) / gross_in_eth
            if gross_in_eth > 0.0
            else 0.0
        )
        return RouteResult(
            amount_out=amount_out,
            legs=results,
            hop_fees=fees,
            protocol_fee_eth=protocol_fee,
            effective_loss_frac=loss,
            amount_in=used,
            exhausted=exhausted,
        )

    def _resolve(self, leg: Leg):
        """Re-bind a leg to *this* chain's venue (so clones can replay a route)."""
        if leg.external:
            return self.external_markets[leg.index]
        return self.links[leg.index].pool

    @staticmethod
    def _swap_in(venue, leg: Leg, amount: float) -> SwapResult:
        if not leg.external:
            return venue.swap_exact_in(amount, parent_in=leg.buy)
        market: ParentEthMarket = venue
        before = market.fees_accrued_eth + market.fees_accrued_token
        out = market.swap_exact_in(amount, eth_in=leg.buy)
        fee = (market.fees_accrued_eth + market.fees_accrued_token) - before
        return SwapResult(out, amount, math.sqrt(market.price), fee, 0, False)

    @staticmethod
    def _swap_out(venue, leg: Leg, amount_out: float) -> SwapResult:
        if not leg.external:
            return venue.swap_exact_out(amount_out, parent_in=leg.buy)
        market: ParentEthMarket = venue
        need = _market_exact_out(market, amount_out, eth_in=leg.buy)
        before = market.fees_accrued_eth + market.fees_accrued_token
        got = market.swap_exact_in(need, eth_in=leg.buy)
        fee = (market.fees_accrued_eth + market.fees_accrued_token) - before
        return SwapResult(got, need, math.sqrt(market.price), fee, 0, False)

    # -- arbitrage -------------------------------------------------------------
    def external_edge(self, i: int) -> float:
        """``external_price / family_price - 1`` for link ``i`` (0 with no market)."""
        market = self.external_markets.get(i)
        if market is None:
            return 0.0
        fam = self.price_in_eth(i)
        return market.price / fam - 1.0 if fam > 0.0 else 0.0

    def arbitrage_step(
        self,
        i: int,
        gas_cost_eth: float = 0.0,
        min_edge: float = 0.0,
        max_iters: int = 60,
    ) -> ArbResult:
        """Close the gap between link ``i``'s family price and its external market.

        Direction follows the sign of the edge: if the external market pays more
        than the family line, buy token ``i`` through the family (ETH in at the
        genesis edge, so the 1% fee is paid) and sell it externally; otherwise
        buy externally and sell down the family line.

        Size is found by bisecting the sign of the marginal profit.  The cycle's
        profit is concave in size, so the bisection lands on the profit-maximising
        trade rather than on naive price parity -- which would overshoot into a
        loss as soon as the edge fee is paid.
        """
        edge0 = self.external_edge(i)
        none = ArbResult(i, "none", 0.0, 0.0, edge0, edge0)
        if i not in self.external_markets or abs(edge0) <= min_edge:
            return none
        direction = "buy_family" if edge0 > 0.0 else "buy_external"
        qmax = self._arb_qmax(i, direction)
        if qmax <= 0.0:
            return none

        def profit(q: float) -> float:
            if q <= 0.0:
                return 0.0
            return self.clone()._arb_cycle(i, direction, q) - q - gas_cost_eth

        h = qmax * 1e-6
        lo, hi = 0.0, qmax
        if profit(2.0 * h) - profit(h) <= 0.0:
            return none
        for _ in range(max_iters):
            mid = 0.5 * (lo + hi)
            if profit(mid + h) - profit(mid) > 0.0:
                lo = mid
            else:
                hi = mid
        q = 0.5 * (lo + hi)
        if profit(q) <= 0.0:
            return none
        got = self._arb_cycle(i, direction, q)  # for real, on self
        return ArbResult(
            i, direction, q, got - q - gas_cost_eth, edge0, self.external_edge(i)
        )

    def _arb_qmax(self, i: int, direction: str) -> float:
        """Upper bound on the ETH the cycle can usefully push through."""
        market = self.external_markets[i]
        if direction == "buy_external":
            return market.depth_eth
        cap = self.links[i].pool.max_absorption() * self.price_in_eth(i - 1) if i else (
            self.links[0].pool.max_absorption()
        )
        return min(cap, market.depth_eth)

    def _arb_cycle(self, i: int, direction: str, eth_in: float) -> float:
        """Run one ETH -> ... -> ETH cycle of size ``eth_in``; return the ETH out."""
        market = self.external_markets[i]
        if direction == "buy_family":
            buy = self.execute_route(self.route(ETH, i, FULL_LINE), eth_in)
            return market.swap_exact_in(buy.amount_out, eth_in=False)
        tokens = market.swap_exact_in(eth_in, eth_in=True)
        return self.execute_route(self.route(i, ETH, FULL_LINE), tokens).amount_out

    def propagate_arbitrage(
        self,
        from_index: int,
        gas_cost_eth: float = 0.0,
        min_edge: float = 0.0,
        rounds: int = 2,
    ) -> dict[int, ArbResult]:
        """Walk up and down from ``from_index``, arbing every link with a market.

        Each step moves the whole family line below the link it trades, so the
        walk is repeated ``rounds`` times to let the perturbation settle.
        """
        self._check_index(from_index)
        order = sorted(self.external_markets, key=lambda i: (abs(i - from_index), i))
        out: dict[int, ArbResult] = {}
        for _ in range(rounds):
            for i in order:
                res = self.arbitrage_step(i, gas_cost_eth, min_edge)
                prev = out.get(i)
                if prev is None:
                    out[i] = res
                else:
                    out[i] = ArbResult(
                        i,
                        res.direction if res.direction != "none" else prev.direction,
                        prev.volume_eth + res.volume_eth,
                        prev.profit_eth + res.profit_eth,
                        prev.edge_before,
                        res.edge_after,
                    )
        return out


def _market_exact_out(market: ParentEthMarket, amount_out: float, eth_in: bool) -> float:
    """Input a constant-product market needs to deliver ``amount_out`` (fee on input)."""
    x, y = (
        (market.depth_eth, market.depth_token)
        if eth_in
        else (market.depth_token, market.depth_eth)
    )
    if amount_out >= y:
        raise ValueError("external market cannot deliver that output")
    net = x * amount_out / (y - amount_out)
    f = market.fee_rate
    return net / (1.0 - f) if f else net


# ---------------------------------------------------------------------------
# ancestor sleeve
# ---------------------------------------------------------------------------
def ancestor_weight(r: float) -> float:
    """``w(r) = 2 - 5r + 4r^2``: OG-heavy, minimum 7/16 at r = 5/8, w(1) = 1."""
    return 2.0 - 5.0 * r + 4.0 * r * r


def ancestor_norm(M: int) -> float:
    """``Z(M) = sum_{j=0..M} w(j/M) = (M+1)(5M+4)/(6M)``, ``M >= 1``."""
    if M < 1:
        raise ValueError("Z(M) is only defined for M >= 1; M = 0 is genesis-only")
    return (M + 1) * (5 * M + 4) / (6.0 * M)


class FenwickRangeAdd:
    """Range-add / point-query of ``c0 + c1*j + c2*j^2`` over ``[0, M]``.

    Three Fenwick trees hold the *coefficients*: adding the polynomial over
    ``[l, r]`` is ``+c_k`` at ``l`` and ``-c_k`` at ``r+1`` in tree ``k``, so a
    prefix sum at ``j`` recovers the accumulated coefficients and

        ``query(j) = C0(j) + C1(j)*j + C2(j)*j^2``.

    Everything is integer (wei-scaled) to mimic the Solidity ledger.  ``c1`` is
    negative for this weight family, so the trees *must* be signed: the
    intermediate prefix sums of tree 1 legitimately go below zero even though
    every point query is non-negative.
    """

    def __init__(self, n: int) -> None:
        if n < 1:
            raise ValueError("need at least one index")
        self.n = int(n)  # usable indices 0 .. n-1
        self._t = [[0] * (self.n + 2) for _ in range(3)]

    def _add(self, k: int, i: int, v: int) -> None:
        i += 1  # 1-based
        t = self._t[k]
        while i <= self.n + 1:
            t[i] += v
            i += i & (-i)

    def _prefix(self, k: int, i: int) -> int:
        i += 1
        t = self._t[k]
        s = 0
        while i > 0:
            s += t[i]
            i -= i & (-i)
        return s

    def range_add(self, l: int, r: int, c0: int, c1: int, c2: int) -> None:
        """Add ``c0 + c1*j + c2*j^2`` to every ``j`` in ``[l, r]``."""
        if not 0 <= l <= r < self.n:
            raise IndexError(f"bad range [{l}, {r}] for n = {self.n}")
        for k, c in enumerate((c0, c1, c2)):
            if c:
                self._add(k, l, c)
                self._add(k, r + 1, -c)

    def query(self, j: int) -> int:
        """Point query at ``j``."""
        if not 0 <= j < self.n:
            raise IndexError(f"index {j} out of range")
        return (
            self._prefix(0, j) + self._prefix(1, j) * j + self._prefix(2, j) * j * j
        )

    def coefficient_prefix(self, k: int, j: int) -> int:
        """Accumulated coefficient ``k`` at ``j``.

        Exposed so tests can show the signed intermediates really do go
        negative -- an unsigned Solidity port would underflow here.
        """
        return self._prefix(k, j)


@dataclass
class FeeAllocator:
    """Split of the 1% ETH protocol fee (brief S4).

    Developer 20%, creator of the attributed terminal token, an immediate-parent
    reinforcement sleeve, and the all-ancestor sleeve weighted by
    ``w(r) = 2 - 5r + 4r^2`` over ancestors ``0..M`` with ``M`` the terminal
    token's *parent* index.  ``M = 0`` (and the genesis terminal itself) is the
    genesis-only case -- ``Z(M)`` divides by ``M`` and must never be evaluated
    there.
    """

    dev_share: float = 0.20
    creator_share: float = 0.10
    reinforce_share: float = 0.20
    ancestor_share: float = 0.50

    def __post_init__(self) -> None:
        shares = (
            self.dev_share,
            self.creator_share,
            self.reinforce_share,
            self.ancestor_share,
        )
        total = math.fsum(shares)
        if abs(total - 1.0) > 1e-12:
            raise ValueError(f"shares must sum to 1, got {total!r}")
        if any(s < 0.0 for s in shares):
            raise ValueError("shares must be non-negative")

    def parent_index(self, terminal_index: int) -> int:
        """``M``: the terminal's immediate parent, clamped at genesis."""
        return max(int(terminal_index) - 1, 0)

    def ancestor_weights(self, terminal_index: int) -> dict[int, float]:
        """Normalised ancestor weights over ``0..M`` (sum to 1)."""
        M = self.parent_index(terminal_index)
        if M == 0:
            return {0: 1.0}
        Z = ancestor_norm(M)
        return {j: ancestor_weight(j / M) / Z for j in range(M + 1)}

    def ancestor_coefficients(
        self, sleeve: float, terminal_index: int
    ) -> tuple[float, float, float]:
        """``(c0, c1, c2)`` with ancestor ``j``'s share ``= c0 + c1*j + c2*j^2``."""
        M = self.parent_index(terminal_index)
        if M == 0:
            return (sleeve, 0.0, 0.0)
        a = sleeve / ancestor_norm(M)
        return (2.0 * a, -5.0 * a / M, 4.0 * a / (M * M))

    def allocate(self, protocol_fee_eth: float, terminal_index: int) -> dict[str, float]:
        """Split a collected ETH fee.

        Keys: ``dev``, ``creator:<terminal>``, ``reinforce:<M>``,
        ``ancestor:<j>``.  The sum is exactly the input -- the last ancestor
        absorbs the float residual, mirroring the Solidity remainder convention.
        """
        if protocol_fee_eth < 0.0:
            raise ValueError("fee must be non-negative")
        t = int(terminal_index)
        M = self.parent_index(t)
        out: dict[str, float] = {
            "dev": protocol_fee_eth * self.dev_share,
            f"creator:{t}": protocol_fee_eth * self.creator_share,
            f"reinforce:{M}": protocol_fee_eth * self.reinforce_share,
        }
        sleeve = protocol_fee_eth * self.ancestor_share
        for j, w in self.ancestor_weights(t).items():
            out[f"ancestor:{j}"] = out.get(f"ancestor:{j}", 0.0) + sleeve * w
        out[f"ancestor:{M}"] += protocol_fee_eth - math.fsum(out.values())
        return out
