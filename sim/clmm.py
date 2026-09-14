"""Exact constant-liquidity (Uniswap v3/v4 style) pool engine.

The pool holds ``token`` -- the launched asset, fixed supply ``S`` -- against
``parent``, the numeraire.  Price is quoted as ``P = parent per token`` and the
fully-diluted valuation is ``FDV = P * S``.  All state is float64 and the
sqrt-price moves continuously inside a range (no tick bitmap): ticks only ever
show up as an optional *boundary snapping* convenience in :mod:`sim.curves`.

All liquidity is protocol-owned and static.  Nothing is ever removed; the only
way the position set grows is :meth:`Pool.add_locked_position`.

Closed forms (per range, with liquidity ``L`` constant inside the range)
-----------------------------------------------------------------------
Let ``sp = sqrt(P)``.  Moving the sqrt-price from ``sp0`` to ``sp1`` inside one
range exchanges

    parent:  dy = L * (sp1 - sp0)                     (positive when buying)
    token:   dx = L * (1/sp0 - 1/sp1)                 (positive when buying)

A range sized to hold ``token_amount = s * S`` tokens between the FDV bounds
``Fa < Fb`` has

    L = token_amount / (1/sqrt(Pa) - 1/sqrt(Pb)),   Pa = Fa / S, Pb = Fb / S

and buying it out entirely therefore costs

    dy = L * (sqrt(Pb) - sqrt(Pa)) = s * S * sqrt(Pa * Pb) = s * sqrt(Fa * Fb)

parent -- the geometric mean of the FDV bounds, scaled by the supply share.
That identity is the backbone of the whole multicurve design and is asserted in
``sim/tests/test_clmm.py``.

Fees
----
``hop_fee_bps`` is the per-hop pool fee.  It is *retained* (booked into
``fees_accrued_parent`` / ``fees_accrued_token``) and never folded back into
liquidity, so the curve geometry stays static and reproducible.

Two fee conventions are supported:

``fee_on="input"`` (default, matches Uniswap v4)
    The fee is skimmed off the swap input, in whichever asset is coming in.

``fee_on="parent"``
    The fee is always charged in the numeraire: off the input when buying
    token, off the output when selling token.  This makes a buy/sell round trip
    return exactly ``q * (1 - f)**2`` because the pool leg is exactly reversed.
    Under ``fee_on="input"`` the sell leg feeds back fewer tokens than the pool
    handed out, so the round trip only approximates ``q * (1 - f)**2``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

__all__ = [
    "Range",
    "SwapResult",
    "Pool",
    "ParentEthMarket",
    "sqrt_price_from_fdv",
    "fdv_from_sqrt_price",
]

_EPS = 1e-15


def sqrt_price_from_fdv(fdv: float, supply: float) -> float:
    """sqrt(P) for a given FDV, with ``P = FDV / supply``."""
    return math.sqrt(fdv / supply)


def fdv_from_sqrt_price(sqrtP: float, supply: float) -> float:
    """FDV implied by a sqrt-price: ``FDV = sqrtP**2 * supply``."""
    return sqrtP * sqrtP * supply


@dataclass
class Range:
    """One constant-liquidity position.

    Attributes
    ----------
    lower, upper:
        sqrt-price bounds (``sqrt(parent per token)``), ``lower < upper``.
    L:
        liquidity, constant inside the range.
    """

    lower: float
    upper: float
    L: float

    def __post_init__(self) -> None:
        if not self.lower < self.upper:
            raise ValueError(f"range bounds must ascend, got {self.lower} >= {self.upper}")
        if self.L < 0.0:
            raise ValueError("liquidity must be non-negative")

    @classmethod
    def from_fdv(cls, Fa: float, Fb: float, token_amount: float, S: float) -> "Range":
        """Range holding exactly ``token_amount`` tokens between FDV ``Fa`` and ``Fb``.

        ``L = token_amount / (1/sqrt(Pa) - 1/sqrt(Pb))`` with ``Pa = Fa/S`` and
        ``Pb = Fb/S``; the tokens all sit in the range while the price is at or
        below ``Fa``.
        """
        if not 0.0 < Fa < Fb:
            raise ValueError(f"need 0 < Fa < Fb, got Fa={Fa}, Fb={Fb}")
        lower = sqrt_price_from_fdv(Fa, S)
        upper = sqrt_price_from_fdv(Fb, S)
        L = token_amount / (1.0 / lower - 1.0 / upper)
        return cls(lower=lower, upper=upper, L=L)

    # -- per-range closed forms ------------------------------------------------
    def parent_at(self, sqrtP: float) -> float:
        """Parent held by this range at ``sqrtP``: ``L * (clamp - lower)``."""
        return self.L * (self._clamp(sqrtP) - self.lower)

    def token_at(self, sqrtP: float) -> float:
        """Token held by this range at ``sqrtP``: ``L * (1/clamp - 1/upper)``."""
        return self.L * (1.0 / self._clamp(sqrtP) - 1.0 / self.upper)

    def fdv_lower(self, supply: float) -> float:
        return fdv_from_sqrt_price(self.lower, supply)

    def fdv_upper(self, supply: float) -> float:
        return fdv_from_sqrt_price(self.upper, supply)

    def _clamp(self, sqrtP: float) -> float:
        return min(max(sqrtP, self.lower), self.upper)


@dataclass
class SwapResult:
    """Outcome of a swap.

    ``amount_in_used`` is gross of fee; ``fee_paid`` is the retained part of it
    (or, under ``fee_on="parent"`` on a sell, the parent skimmed off the
    output).  ``exhausted`` flags a partial fill: the pool ran out of liquidity
    on that side before the request could be satisfied.
    """

    amount_out: float
    amount_in_used: float
    sqrtP_after: float
    fee_paid: float
    ranges_crossed: int
    exhausted: bool = False


class Pool:
    """Static, protocol-owned multicurve pool.

    Parameters
    ----------
    ranges:
        positions; sorted internally by ``lower``.  Contiguity is allowed but
        not required -- a gap is traversed for free (there is nothing to buy).
    supply:
        token supply ``S`` used for the FDV conversion.
    sqrtP:
        current sqrt-price (defaults to the bottom of the curve).
    hop_fee_bps:
        per-hop pool fee in basis points.
    fee_on:
        ``"input"`` (default) or ``"parent"``; see the module docstring.
    allow_overlap:
        skip the no-overlap check.  Deposited bids (see
        :meth:`add_locked_position`) legitimately sit inside a curve range, so
        :meth:`clone` re-creates such a pool with this set; construction from a
        spec keeps the check.
    """

    def __init__(
        self,
        ranges: list[Range],
        supply: float = 1e9,
        sqrtP: float | None = None,
        hop_fee_bps: float = 0.0,
        fee_on: str = "input",
        allow_overlap: bool = False,
    ) -> None:
        if not ranges:
            raise ValueError("pool needs at least one range")
        if fee_on not in ("input", "parent"):
            raise ValueError("fee_on must be 'input' or 'parent'")
        self.ranges: list[Range] = sorted(ranges, key=lambda r: r.lower)
        self.allow_overlap = bool(allow_overlap)
        if not self.allow_overlap:
            for a, b in zip(self.ranges, self.ranges[1:]):
                if b.lower < a.upper - _EPS:
                    raise ValueError("ranges must not overlap")
        self.supply = float(supply)
        self.sqrtP = float(self.ranges[0].lower if sqrtP is None else sqrtP)
        self.hop_fee_bps = float(hop_fee_bps)
        self.fee_on = fee_on
        self.fees_accrued_parent = 0.0
        self.fees_accrued_token = 0.0

    # -- basics ----------------------------------------------------------------
    @property
    def fee_rate(self) -> float:
        return self.hop_fee_bps / 1e4

    @property
    def price(self) -> float:
        """Parent per token."""
        return self.sqrtP * self.sqrtP

    def fdv(self) -> float:
        """``price * supply``."""
        return fdv_from_sqrt_price(self.sqrtP, self.supply)

    def set_fdv(self, fdv: float) -> None:
        """Teleport the price (no swap, no fee) -- scenario setup only."""
        self.sqrtP = sqrt_price_from_fdv(fdv, self.supply)

    def clone(self) -> "Pool":
        """Copy of the pool (ranges duplicated, fee counters carried over)."""
        p = Pool(
            [Range(r.lower, r.upper, r.L) for r in self.ranges],
            self.supply,
            self.sqrtP,
            self.hop_fee_bps,
            self.fee_on,
            allow_overlap=True,
        )
        p.fees_accrued_parent = self.fees_accrued_parent
        p.fees_accrued_token = self.fees_accrued_token
        return p

    # -- analytics -------------------------------------------------------------
    def reserve_parent(self, sqrtP: float | None = None) -> float:
        """Parent sitting in the pool: ``sum L*(clamp(sqrtP) - lower)`` over ranges."""
        sp = self.sqrtP if sqrtP is None else sqrtP
        return math.fsum(r.parent_at(sp) for r in self.ranges)

    def tokens_remaining(self, sqrtP: float | None = None) -> float:
        """Token sitting in the pool: ``sum L*(1/clamp(sqrtP) - 1/upper)``."""
        sp = self.sqrtP if sqrtP is None else sqrtP
        return math.fsum(r.token_at(sp) for r in self.ranges)

    def tokens_sold(self, sqrtP: float | None = None) -> float:
        """``supply - tokens_remaining`` (negative if ask positions were added)."""
        return self.supply - self.tokens_remaining(sqrtP)

    def quote_cost_to_fdv(self, target_fdv: float) -> float:
        """Parent needed, from the current state, to lift the FDV to ``target_fdv``.

        Exact, per range: ``dy = L * (clamp(sp_target) - clamp(sp_now))``.  A
        target below the current FDV returns a negative number -- the parent a
        sell down to that FDV would release (fees excluded).
        """
        target = sqrt_price_from_fdv(target_fdv, self.supply)
        return math.fsum(
            r.L * (r._clamp(target) - r._clamp(self.sqrtP)) for r in self.ranges
        )

    def max_absorption(self) -> float:
        """Parent needed to buy every token still in the pool (fees excluded)."""
        return math.fsum(r.L * (r.upper - r._clamp(self.sqrtP)) for r in self.ranges)

    def invert_reserve_to_fdv(self, reserve: float, iters: int = 200) -> float:
        """FDV at which :meth:`reserve_parent` equals ``reserve`` (bisection).

        ``reserve_parent`` is non-decreasing in price, so bisection on the
        sqrt-price is safe.  Out-of-range inputs clamp to the curve's ends; in a
        gap between ranges the reserve is flat, so the lower edge is returned.
        """
        lo, hi = self.ranges[0].lower, self.ranges[-1].upper
        if reserve <= 0.0:
            return fdv_from_sqrt_price(lo, self.supply)
        if reserve >= self.reserve_parent(hi):
            return fdv_from_sqrt_price(hi, self.supply)
        for _ in range(iters):
            mid = 0.5 * (lo + hi)
            if self.reserve_parent(mid) < reserve:
                lo = mid
            else:
                hi = mid
        return fdv_from_sqrt_price(0.5 * (lo + hi), self.supply)

    def add_locked_position(
        self,
        Fa: float,
        Fb: float,
        parent_amount: float = 0.0,
        token_amount: float = 0.0,
    ) -> Range:
        """Add a permanent single-sided position between FDV ``Fa`` and ``Fb``.

        ``parent_amount`` -> a *bid* range, which must sit at or below spot:
        ``L = parent_amount / (sqrt(Pb) - sqrt(Pa))``.
        ``token_amount`` -> an *ask* range, which must sit at or above spot:
        ``L = token_amount / (1/sqrt(Pa) - 1/sqrt(Pb))``.
        """
        if (parent_amount > 0.0) == (token_amount > 0.0):
            raise ValueError("supply exactly one of parent_amount / token_amount")
        lower = sqrt_price_from_fdv(Fa, self.supply)
        upper = sqrt_price_from_fdv(Fb, self.supply)
        if parent_amount > 0.0:
            if upper > self.sqrtP + _EPS:
                raise ValueError("bid (parent-only) position must lie at or below spot")
            rng = Range(lower, upper, parent_amount / (upper - lower))
        else:
            if lower < self.sqrtP - _EPS:
                raise ValueError("ask (token-only) position must lie at or above spot")
            rng = Range.from_fdv(Fa, Fb, token_amount, self.supply)
        self.ranges.append(rng)
        self.ranges.sort(key=lambda r: r.lower)
        self.allow_overlap = True  # a deposited bid legitimately overlaps the curve
        return rng

    # -- swaps -----------------------------------------------------------------
    def swap_exact_in(self, amount_in: float, parent_in: bool) -> SwapResult:
        """Swap an exact input amount.

        ``parent_in=True`` buys token with parent (price up); ``False`` sells
        token for parent (price down).  Partial fills set ``exhausted`` and
        report only the part of the input that was actually usable.
        """
        if amount_in < 0.0:
            raise ValueError("amount_in must be non-negative")
        f = self.fee_rate
        if parent_in:
            net_in = amount_in * (1.0 - f)
            out, sp_after, used, crossed, exhausted = self._buy_exact_in(net_in)
            gross_used = used / (1.0 - f) if f else used
            fee = gross_used - used
            self.sqrtP = sp_after
            self.fees_accrued_parent += fee
            return SwapResult(out, gross_used, sp_after, fee, crossed, exhausted)

        if self.fee_on == "parent":
            out_gross, sp_after, used, crossed, exhausted = self._sell_exact_in(amount_in)
            fee = out_gross * f
            self.sqrtP = sp_after
            self.fees_accrued_parent += fee
            return SwapResult(out_gross - fee, used, sp_after, fee, crossed, exhausted)

        net_in = amount_in * (1.0 - f)
        out, sp_after, used, crossed, exhausted = self._sell_exact_in(net_in)
        gross_used = used / (1.0 - f) if f else used
        fee = gross_used - used
        self.sqrtP = sp_after
        self.fees_accrued_token += fee
        return SwapResult(out, gross_used, sp_after, fee, crossed, exhausted)

    def swap_exact_out(self, amount_out: float, parent_in: bool) -> SwapResult:
        """Swap for an exact output amount.

        ``parent_in=True``: ``amount_out`` is token bought with parent.
        ``parent_in=False``: ``amount_out`` is parent obtained by selling token.
        If the pool cannot deliver, the swap fills as far as possible and
        ``exhausted`` is set.
        """
        if amount_out < 0.0:
            raise ValueError("amount_out must be non-negative")
        f = self.fee_rate
        if parent_in:
            net_in, sp_after, out, crossed, exhausted = self._buy_exact_out(amount_out)
            gross_in = net_in / (1.0 - f) if f else net_in
            fee = gross_in - net_in
            self.sqrtP = sp_after
            self.fees_accrued_parent += fee
            return SwapResult(out, gross_in, sp_after, fee, crossed, exhausted)

        if self.fee_on == "parent":
            # amount_out is net of the parent-side fee; gross it up first.
            gross_out = amount_out / (1.0 - f) if f else amount_out
            tok_in, sp_after, out_gross, crossed, exhausted = self._sell_exact_out(gross_out)
            fee = out_gross * f
            self.sqrtP = sp_after
            self.fees_accrued_parent += fee
            return SwapResult(out_gross - fee, tok_in, sp_after, fee, crossed, exhausted)

        tok_in, sp_after, out, crossed, exhausted = self._sell_exact_out(amount_out)
        gross_in = tok_in / (1.0 - f) if f else tok_in
        fee = gross_in - tok_in
        self.sqrtP = sp_after
        self.fees_accrued_token += fee
        return SwapResult(out, gross_in, sp_after, fee, crossed, exhausted)

    # -- swap kernels (fee-free, pure geometry) --------------------------------
    def _buy_exact_in(self, net_in: float) -> tuple[float, float, float, int, bool]:
        """Parent in -> token out; returns (out, sqrtP_after, net_used, crossed, exhausted)."""
        remaining = net_in
        sp = self.sqrtP
        out = 0.0
        crossed = 0
        for r in self.ranges:
            if r.upper <= sp:
                continue
            start = max(sp, r.lower)  # gaps are traversed for free
            cap = r.L * (r.upper - start)
            if remaining >= cap:
                out += r.L * (1.0 / start - 1.0 / r.upper)
                remaining -= cap
                sp = r.upper
                crossed += 1
            else:
                new = start + remaining / r.L
                out += r.L * (1.0 / start - 1.0 / new)
                remaining = 0.0
                sp = new
                break
        return out, sp, net_in - remaining, crossed, remaining > 0.0

    def _sell_exact_in(self, net_in: float) -> tuple[float, float, float, int, bool]:
        """Token in -> parent out; returns (out, sqrtP_after, net_used, crossed, exhausted)."""
        remaining = net_in
        sp = self.sqrtP
        out = 0.0
        crossed = 0
        for r in reversed(self.ranges):
            if r.lower >= sp:
                continue
            start = min(sp, r.upper)
            cap = r.L * (1.0 / r.lower - 1.0 / start)
            if remaining >= cap:
                out += r.L * (start - r.lower)
                remaining -= cap
                sp = r.lower
                crossed += 1
            else:
                new = 1.0 / (1.0 / start + remaining / r.L)
                out += r.L * (start - new)
                remaining = 0.0
                sp = new
                break
        return out, sp, net_in - remaining, crossed, remaining > 0.0

    def _buy_exact_out(self, amount_out: float) -> tuple[float, float, float, int, bool]:
        """Token out -> parent in; returns (net_in, sqrtP_after, filled, crossed, exhausted)."""
        remaining = amount_out
        sp = self.sqrtP
        net_in = 0.0
        crossed = 0
        for r in self.ranges:
            if r.upper <= sp:
                continue
            start = max(sp, r.lower)
            cap = r.L * (1.0 / start - 1.0 / r.upper)
            if remaining >= cap:
                net_in += r.L * (r.upper - start)
                remaining -= cap
                sp = r.upper
                crossed += 1
            else:
                new = 1.0 / (1.0 / start - remaining / r.L)
                net_in += r.L * (new - start)
                remaining = 0.0
                sp = new
                break
        return net_in, sp, amount_out - remaining, crossed, remaining > 0.0

    def _sell_exact_out(self, amount_out: float) -> tuple[float, float, float, int, bool]:
        """Parent out -> token in; returns (net_in, sqrtP_after, filled, crossed, exhausted)."""
        remaining = amount_out
        sp = self.sqrtP
        net_in = 0.0
        crossed = 0
        for r in reversed(self.ranges):
            if r.lower >= sp:
                continue
            start = min(sp, r.upper)
            cap = r.L * (start - r.lower)
            if remaining >= cap:
                net_in += r.L * (1.0 / r.lower - 1.0 / start)
                remaining -= cap
                sp = r.lower
                crossed += 1
            else:
                new = start - remaining / r.L
                net_in += r.L * (1.0 / new - 1.0 / start)
                remaining = 0.0
                sp = new
                break
        return net_in, sp, amount_out - remaining, crossed, remaining > 0.0


@dataclass
class ParentEthMarket:
    """Toy external market for the parent asset: constant product ``x * y = k``.

    ``depth_eth`` / ``depth_token`` are the ETH and parent-token reserves.  Used
    only when a scenario needs to price the parent leg against ETH; the launch
    pools themselves never touch it.
    """

    depth_eth: float
    depth_token: float
    fee_bps: float = 0.0
    fees_accrued_eth: float = 0.0
    fees_accrued_token: float = 0.0

    @property
    def fee_rate(self) -> float:
        return self.fee_bps / 1e4

    @property
    def price(self) -> float:
        """ETH per parent token."""
        return self.depth_eth / self.depth_token

    def swap_exact_in(self, amount_in: float, eth_in: bool) -> float:
        """Constant-product swap, fee taken on the input.  Returns the output."""
        f = self.fee_rate
        net = amount_in * (1.0 - f)
        if eth_in:
            out = self.depth_token * net / (self.depth_eth + net)
            self.depth_eth += net
            self.depth_token -= out
            self.fees_accrued_eth += amount_in - net
        else:
            out = self.depth_eth * net / (self.depth_token + net)
            self.depth_token += net
            self.depth_eth -= out
            self.fees_accrued_token += amount_in - net
        return out
