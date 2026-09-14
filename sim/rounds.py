"""Discrete-time succession engine: one round of the family chain.

Implements DESIGN_BRIEF_v2 sections 2-3 exactly.

    Registration (``registration_s``) -- anyone registers a candidate, each
        paying a fixed ETH bond.  Every candidate gets the *identical* standard
        curve (``curve_spec``) quoted in the current head token.
    Trading (``trading_s``, all candidates share ``trading_start``) -- swaps are
        gated before ``trading_start``; the first ``snipe_s`` seconds carry the
        snipe tax (99% -> 1%), taken on the parent side; every swap updates the
        score accumulator ``acc += R * (t - t_last); R += netParentIn``.
    Submission (``submit_window_s``) -- ``submit(cid, t)`` snapshots
        ``avg = (acc + R * (T_end - t_last)) / trading_s`` (tail extension) and
        ``t_first_attained``; the best is tracked under the brief's tie rule.
    Finalize -- after the window.  ``best_avg >= H`` -> winner (bond refunded,
        losers' bonds forfeited as an ETH bid under genesis) and, with
        ``reset_on_win`` (default True), ``H`` snaps back to ``H0`` for the
        next round -- decay only compounds across *consecutive* failures, not
        across a win.  Otherwise (``reset_on_win=False``) a win carries over
        whatever ``H`` was just cleared.  No winner -> ``H = max(decay * H,
        h_floor_frac * H0)``.

Units.  ``R`` and ``H`` are *parent tokens*.  ``H = h_threshold_frac *
head_supply`` is an **average** absorption over the whole trading window, so it
is directly comparable with ``score / trading_s``.

Fees.  Candidate pools are family<->family, so the 1% protocol fee (which the
hook charges only when native ETH is on one side of the swap) is exactly zero
here -- see :data:`CANDIDATE_PROTOCOL_FEE_BPS`.  The only fee is the per-hop
pool fee ``hop_fee_bps``, charged on the parent side (``fee_on="parent"``), so
an untouched buy/sell round trip returns exactly ``q * (1 - f)**2``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .clmm import Pool
from .curves import Spec, build_pool, self_similar

__all__ = [
    "CANDIDATE_PROTOCOL_FEE_BPS",
    "Phase",
    "RoundError",
    "RoundConfig",
    "Candidate",
    "SwapExec",
    "Submission",
    "RoundOutcome",
    "Round",
    "assert_reachable",
    "wall_fdv",
]

# The protocol fee is levied by the hook only on the ETH edge (the genesis
# pool).  Candidate pools trade head-token against candidate-token, so the rate
# is zero by construction (brief sec.4, attack-log finding 2).
CANDIDATE_PROTOCOL_FEE_BPS = 0.0

_EPS = 1e-12


class RoundError(RuntimeError):
    """A call that the on-chain state machine would revert."""


class Phase:
    REGISTRATION = "registration"
    TRADING = "trading"
    SUBMISSION = "submission"
    FINALIZED = "finalized"


@dataclass
class RoundConfig:
    """Deploy constants for one round.

    ``curve_spec`` defaults to the self-similar standard curve scaled to
    ``parent_supply``; every candidate is built from it identically.  The
    candidate token's own fixed supply is also ``parent_supply`` (1e9 for every
    link -- ``FamilyToken`` mints once).
    """

    registration_s: float = 180.0
    trading_s: float = 900.0
    submit_window_s: float = 300.0
    snipe_s: float = 3.0
    snipe_start: float = 0.99
    snipe_end: float = 0.01
    bond_eth: float = 0.005
    h_threshold_frac: float = 0.005
    h_floor_frac: float = 0.25
    decay: float = 0.9
    curve_spec: Spec | None = None
    parent_supply: float = 1e9
    hop_fee_bps: float = 7.5
    snipe_decay: str = "linear"  # or "exponential"
    snap_ticks: bool = True
    tick_spacing: int = 60
    reset_on_win: bool = True

    def __post_init__(self) -> None:
        if self.curve_spec is None:
            self.curve_spec = self_similar(self.parent_supply)
        if self.snipe_decay not in ("linear", "exponential"):
            raise ValueError("snipe_decay must be 'linear' or 'exponential'")
        if not 0.0 <= self.snipe_end <= self.snipe_start < 1.0:
            raise ValueError("need 0 <= snipe_end <= snipe_start < 1")

    # -- snipe tax -------------------------------------------------------------
    def snipe_tax(self, dt: float) -> float:
        """Tax multiplier ``dt`` seconds into trading (the brief's curve).

        Linear: ``end + (start - end) * max(0, 1 - dt / snipe_s)``.
        Exponential: geometric interpolation ``start * (end/start)**(dt/snipe_s)``
        clamped to the window, which hits the same two endpoints.
        """
        if dt < 0.0:
            raise ValueError("dt must be non-negative")
        u = min(max(dt / self.snipe_s, 0.0), 1.0) if self.snipe_s > 0.0 else 1.0
        if self.snipe_decay == "linear":
            return self.snipe_end + (self.snipe_start - self.snipe_end) * (1.0 - u)
        if self.snipe_start <= 0.0:
            return 0.0
        return self.snipe_start * (self.snipe_end / self.snipe_start) ** u

    def applied_snipe_tax(self, dt: float) -> float:
        """Tax actually levied: the curve inside the window, zero after it.

        The hook only taxes ``[tradingStart, tradingStart + snipe_s)``; past the
        window there is no snipe tax at all, which is what makes a slot capture
        cost fees only (brief sec.3).
        """
        return 0.0 if dt >= self.snipe_s else self.snipe_tax(dt)

    @property
    def hop_fee_rate(self) -> float:
        return self.hop_fee_bps / 1e4


@dataclass
class Candidate:
    """One registered candidate and its (gated) pool, plus its accumulator."""

    id: int
    pool: Pool
    creator: str
    registered_at: float
    acc: float = 0.0
    R: float = 0.0
    t_last: float = 0.0
    history: list[tuple[float, float]] = field(default_factory=list)

    def running_avg(self, t_end: float, trading_s: float) -> float:
        """Tail-extended average absorption if the window closed now."""
        return (self.acc + self.R * (t_end - self.t_last)) / trading_s

    def r_series(self, t0: float, t_end: float, dt: float = 1.0) -> list[tuple[float, float]]:
        """Per-second (or ``dt``) sample of ``R(t)`` over ``[t0, t_end]``."""
        out: list[tuple[float, float]] = []
        n = int(round((t_end - t0) / dt))
        k = 0
        r = 0.0
        for i in range(n + 1):
            t = t0 + i * dt
            while k < len(self.history) and self.history[k][0] <= t + _EPS:
                r = self.history[k][1]
                k += 1
            out.append((t, r))
        return out


@dataclass
class SwapExec:
    """Exact outcome of one gated, taxed candidate swap (all parent units)."""

    candidate_id: int
    t: float
    trader: str
    parent_in: bool
    amount_requested: float
    snipe_tax_rate: float
    snipe_fee: float
    hop_fee: float
    protocol_fee: float
    parent_spent: float      # buys: gross parent out of the trader's pocket
    parent_received: float   # sells: parent net of hop fee and snipe tax
    tokens_bought: float
    tokens_sold: float
    net_parent_in: float     # parent delta of the locked liquidity (= score input)
    scored: bool
    fdv_after: float
    exhausted: bool


@dataclass
class Submission:
    candidate_id: int
    avg: float
    t_first_attained: float
    submitted_at: float

    @property
    def key(self) -> tuple[float, float, int]:
        """Brief tie rule: higher avg, then earlier attainment, then lower id."""
        return (-self.avg, self.t_first_attained, self.candidate_id)


@dataclass
class RoundOutcome:
    winner: int | None
    best_avg: float
    h_used: float
    h_next: float
    refunded_bond_eth: float
    forfeited_bond_eth: float
    submissions: dict[int, Submission]


class Round:
    """One succession round: registration -> trading -> submission -> finalize."""

    def __init__(
        self,
        config: RoundConfig,
        head_supply: float | None = None,
        t_open: float = 0.0,
        h_current: float | None = None,
    ) -> None:
        self.config = config
        self.head_supply = float(config.parent_supply if head_supply is None else head_supply)
        self.t_open = float(t_open)
        self.registration_end = self.t_open + config.registration_s
        self.trading_start = self.registration_end
        self.t_end = self.trading_start + config.trading_s
        self.submit_end = self.t_end + config.submit_window_s
        # H is an average absorption in parent tokens (brief sec.3).
        self.h0 = config.h_threshold_frac * self.head_supply
        self.h_current = self.h0 if h_current is None else float(h_current)
        self.h_floor = config.h_floor_frac * self.h0

        self.candidates: dict[int, Candidate] = {}
        self.submissions: dict[int, Submission] = {}
        self.best: Submission | None = None
        self.swaps: list[SwapExec] = []
        self.bonds_eth: dict[int, float] = {}
        self.genesis_bid_eth = 0.0
        self.outcome: RoundOutcome | None = None
        self._next_id = 0

    # -- phase -----------------------------------------------------------------
    def phase(self, t: float) -> str:
        if self.outcome is not None:
            return Phase.FINALIZED
        if t < self.registration_end:
            return Phase.REGISTRATION
        if t < self.t_end:
            return Phase.TRADING
        if t < self.submit_end:
            return Phase.SUBMISSION
        return Phase.FINALIZED

    # -- registration ----------------------------------------------------------
    def register(self, creator: str, t: float, candidate_id: int | None = None) -> Candidate:
        """Register a candidate; reverts outside the registration window."""
        if not self.t_open <= t < self.registration_end:
            raise RoundError(
                f"registration closed at t={t} "
                f"(window [{self.t_open}, {self.registration_end}))"
            )
        cid = self._next_id if candidate_id is None else candidate_id
        if cid in self.candidates:
            raise RoundError(f"candidate id {cid} already registered")
        self._next_id = max(self._next_id, cid) + 1
        cfg = self.config
        pool = build_pool(
            cfg.curve_spec,
            supply=cfg.parent_supply,
            snap_ticks=cfg.snap_ticks,
            tick_spacing=cfg.tick_spacing,
            hop_fee_bps=cfg.hop_fee_bps,
            fee_on="parent",
        )
        cand = Candidate(
            id=cid, pool=pool, creator=creator, registered_at=t, t_last=self.trading_start
        )
        self.candidates[cid] = cand
        self.bonds_eth[cid] = cfg.bond_eth
        return cand

    # -- trading ---------------------------------------------------------------
    def swap(
        self,
        candidate_id: int,
        amount_in: float,
        parent_in: bool,
        t: float,
        trader: str = "anon",
    ) -> SwapExec:
        """Gated, snipe-taxed swap against a candidate pool.

        ``amount_in`` is parent when ``parent_in`` else candidate tokens.  The
        snipe tax is taken on the parent side (off the input on a buy, off the
        output on a sell) before the pool leg; the score accumulator is updated
        after it, with the parent delta of the locked liquidity.
        """
        cand = self.candidates.get(candidate_id)
        if cand is None:
            raise RoundError(f"unknown candidate {candidate_id}")
        if t < self.trading_start:
            raise RoundError(f"pool gated: t={t} < tradingStart={self.trading_start}")
        if amount_in < 0.0:
            raise RoundError("amount_in must be non-negative")

        tax = self.config.applied_snipe_tax(t - self.trading_start)
        pool = cand.pool
        if parent_in:
            to_pool = amount_in * (1.0 - tax)
            res = pool.swap_exact_in(to_pool, parent_in=True)
            # the tax is charged only on the part of the input the pool could use
            gross_used = res.amount_in_used / (1.0 - tax) if tax else res.amount_in_used
            snipe_fee = gross_used - res.amount_in_used
            ex = SwapExec(
                candidate_id=candidate_id, t=t, trader=trader, parent_in=True,
                amount_requested=amount_in, snipe_tax_rate=tax, snipe_fee=snipe_fee,
                hop_fee=res.fee_paid, protocol_fee=0.0,
                parent_spent=gross_used, parent_received=0.0,
                tokens_bought=res.amount_out, tokens_sold=0.0,
                net_parent_in=res.amount_in_used - res.fee_paid,
                scored=t <= self.t_end, fdv_after=pool.fdv(), exhausted=res.exhausted,
            )
        else:
            res = pool.swap_exact_in(amount_in, parent_in=False)
            snipe_fee = res.amount_out * tax
            # fee_on="parent": amount_out is already net of the hop fee, so the
            # parent leaving the liquidity is amount_out + fee_paid.
            ex = SwapExec(
                candidate_id=candidate_id, t=t, trader=trader, parent_in=False,
                amount_requested=amount_in, snipe_tax_rate=tax, snipe_fee=snipe_fee,
                hop_fee=res.fee_paid, protocol_fee=0.0,
                parent_spent=0.0, parent_received=res.amount_out - snipe_fee,
                tokens_bought=0.0, tokens_sold=res.amount_in_used,
                net_parent_in=-(res.amount_out + res.fee_paid),
                scored=t <= self.t_end, fdv_after=pool.fdv(), exhausted=res.exhausted,
            )

        self._accumulate(cand, t, ex.net_parent_in)
        self.swaps.append(ex)
        return ex

    def _accumulate(self, cand: Candidate, t: float, net_parent_in: float) -> None:
        """``acc += R * (t - t_last); R += netParentIn``, clamped at ``T_end``."""
        if t > self.t_end:
            return  # accumulators clamp at T_end (brief sec.5)
        if t < cand.t_last - _EPS:
            raise RoundError("time must be non-decreasing")
        t = max(t, cand.t_last)
        cand.acc += cand.R * (t - cand.t_last)
        cand.t_last = t
        cand.R += net_parent_in
        cand.history.append((t, cand.R))

    # -- submission ------------------------------------------------------------
    def submit(self, candidate_id: int, t: float) -> Submission:
        """Snapshot a candidate's tail-extended average; update the best."""
        cand = self.candidates.get(candidate_id)
        if cand is None:
            raise RoundError(f"unknown candidate {candidate_id}")
        if not self.t_end <= t < self.submit_end:
            raise RoundError(
                f"submitScore outside [{self.t_end}, {self.submit_end}), got t={t}"
            )
        prev = self.submissions.get(candidate_id)
        if prev is not None:
            return prev  # idempotent: the score is snapshotted at T_end
        sub = Submission(candidate_id, cand.running_avg(self.t_end, self.config.trading_s),
                         cand.t_last, t)
        self.submissions[candidate_id] = sub
        if self.best is None or sub.key < self.best.key:
            self.best = sub
        return sub

    # -- finalize --------------------------------------------------------------
    def finalize(self, t: float) -> RoundOutcome:
        """Permissionless, deterministic, idempotent close after the window."""
        if self.outcome is not None:
            return self.outcome
        if t < self.submit_end:
            raise RoundError(f"finalize before window end ({t} < {self.submit_end})")
        h_used = self.h_current
        best = self.best
        if best is not None and best.avg >= h_used:
            winner = best.candidate_id
            refunded = self.bonds_eth.get(winner, 0.0)
            forfeited = math.fsum(b for c, b in self.bonds_eth.items() if c != winner)
            # A win clears the succession bar; with reset_on_win (default) the
            # threshold snaps back to H0 for the next round instead of
            # carrying over any decay accumulated by *prior* failed rounds --
            # decay should only compound across consecutive failures.
            h_next = self.h0 if self.config.reset_on_win else h_used
        else:
            winner = None
            refunded = 0.0
            forfeited = math.fsum(self.bonds_eth.values())
            h_next = max(self.config.decay * h_used, self.h_floor)
        self.genesis_bid_eth += forfeited
        self.h_current = h_next
        self.outcome = RoundOutcome(
            winner=winner,
            best_avg=0.0 if best is None else best.avg,
            h_used=h_used,
            h_next=h_next,
            refunded_bond_eth=refunded,
            forfeited_bond_eth=forfeited,
            submissions=dict(self.submissions),
        )
        return self.outcome


# --------------------------------------------------------------------------
# deploy-time reachability invariant
# --------------------------------------------------------------------------
def wall_fdv(spec: Spec) -> float:
    """The curve's *wall* FDV: the upper bound of the second-to-last range.

    That is where the standard curve stops being cheap (the last range is the
    long tail); a threshold needing more than a slice of the parent absorbed by
    then could never be met.
    """
    return spec[-2][2] if len(spec) >= 2 else spec[-1][2]


def assert_reachable(
    curve_spec: Spec,
    H: float,
    frac: float = 0.25,
    supply: float = 1e9,
    snap_ticks: bool = True,
    tick_spacing: int = 60,
) -> float:
    """Invariant: ``H <= frac x absorption(curve, wallFDV)`` (brief sec.3).

    Returns the absorption at the wall FDV -- the parent needed to lift a fresh
    curve from its floor to the wall.
    """
    pool = build_pool(curve_spec, supply, snap_ticks, tick_spacing)
    absorption = pool.quote_cost_to_fdv(wall_fdv(curve_spec))
    assert H <= frac * absorption, (
        f"threshold {H!r} exceeds {frac!r} x wall absorption {absorption!r}"
    )
    return absorption
