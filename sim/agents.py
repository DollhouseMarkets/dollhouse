"""Agent framework and round simulator.

An :class:`Agent` sees a live :class:`~sim.rounds.Round` and returns
:class:`Order` objects; :func:`simulate_round` drives the clock, executes the
orders through ``Round.swap`` (so every gate, snipe tax and fee is the real
one), feeds each :class:`~sim.rounds.SwapExec` back to its agent and reports
per-agent P&L decomposed **exactly** from the swap results.

Order amounts follow the pool convention: parent tokens when ``parent_in`` is
true, candidate tokens otherwise.

P&L identity (parent units, all terms taken from ``SwapExec`` fields)::

    round_trip_loss   = capital - sold_back - mark_to_market
    price_impact_loss = round_trip_loss - (snipe + hop + protocol fees)

``capital`` is gross parent out of pocket, ``sold_back`` is parent received net
of hop fee and snipe tax, and ``mark_to_market`` values leftover tokens at the
pool's closing spot.  A lone round trip on a static curve moves the price back
to where it started, so ``price_impact_loss`` is 0 and the whole loss is fees.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field

from .rounds import Round, RoundConfig, RoundOutcome, Submission, SwapExec

__all__ = [
    "Order",
    "PnL",
    "Agent",
    "NoiseTrader",
    "MomentumTrader",
    "Creator",
    "PanicSeller",
    "Attacker",
    "RoundResult",
    "simulate_round",
]

EXIT_EPS = 1.0  # seconds after T_end at which "sell back immediately" lands


@dataclass(frozen=True)
class Order:
    candidate_id: int
    amount: float
    parent_in: bool


@dataclass
class PnL:
    """Exact decomposition of an agent's round (parent units)."""

    agent: str
    capital: float = 0.0
    sold_back: float = 0.0
    snipe_fees: float = 0.0
    hop_fees: float = 0.0
    protocol_fees: float = 0.0
    mark_to_market: float = 0.0
    tokens_held: dict[int, float] = field(default_factory=dict)

    @property
    def fees_paid(self) -> float:
        return self.snipe_fees + self.hop_fees + self.protocol_fees

    @property
    def round_trip_loss(self) -> float:
        return self.capital - self.sold_back - self.mark_to_market

    @property
    def price_impact_loss(self) -> float:
        return self.round_trip_loss - self.fees_paid

    @property
    def net_pnl(self) -> float:
        return -self.round_trip_loss


class Agent:
    """Base agent.  Subclasses override :meth:`act` (and optionally the hooks)."""

    #: only called on the fixed ``dt`` grid when true; scheduled agents set False
    grid_only = True

    def __init__(self, name: str) -> None:
        self.name = name
        self.step_dt = 1.0
        self.holdings: dict[int, float] = {}
        self.fills: list[SwapExec] = []
        self.candidate_id: int | None = None

    # -- hooks -----------------------------------------------------------------
    def register(self, rnd: Round, t: float, rng: random.Random) -> None:
        """Registration phase hook (default: register nothing)."""

    def event_times(self, rnd: Round) -> list[float]:
        """Extra, off-grid timestamps at which this agent must be polled."""
        return []

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        return []

    def on_fill(self, ex: SwapExec) -> None:
        cid = ex.candidate_id
        self.holdings[cid] = self.holdings.get(cid, 0.0) + ex.tokens_bought - ex.tokens_sold
        self.fills.append(ex)

    # -- accounting ------------------------------------------------------------
    def pnl(self, rnd: Round) -> PnL:
        p = PnL(agent=self.name)
        p.capital = math.fsum(f.parent_spent for f in self.fills)
        p.sold_back = math.fsum(f.parent_received for f in self.fills)
        p.snipe_fees = math.fsum(f.snipe_fee for f in self.fills)
        p.hop_fees = math.fsum(f.hop_fee for f in self.fills)
        p.protocol_fees = math.fsum(f.protocol_fee for f in self.fills)
        p.tokens_held = {c: q for c, q in self.holdings.items() if q != 0.0}
        p.mark_to_market = math.fsum(
            q * rnd.candidates[c].pool.price for c, q in p.tokens_held.items()
        )
        return p

    # -- helpers ---------------------------------------------------------------
    def _sell_all(self, cid: int) -> list[Order]:
        q = self.holdings.get(cid, 0.0)
        return [Order(cid, q, False)] if q > 0.0 else []


def _poisson(rng: random.Random, lam: float) -> int:
    """Knuth's sampler; ``lam`` is small here (arrivals per ``dt``)."""
    if lam <= 0.0:
        return 0
    target = math.exp(-lam)
    k, p = 0, 1.0
    while True:
        p *= rng.random()
        if p <= target:
            return k
        k += 1


# --------------------------------------------------------------------------
# population
# --------------------------------------------------------------------------
class NoiseTrader(Agent):
    """Poisson arrivals, lognormal sizes, buy with probability ``buy_prob``.

    Sizes are drawn in parent units; a sell converts at spot and is capped by
    the trader's own holdings (it cannot short).
    """

    def __init__(
        self,
        arrival_rate_per_s: float,
        mu: float,
        sigma: float,
        buy_prob: float = 0.5,
        candidate_ids: list[int] | None = None,
        name: str = "noise",
    ) -> None:
        super().__init__(name)
        self.arrival_rate_per_s = arrival_rate_per_s
        self.mu = mu
        self.sigma = sigma
        self.buy_prob = buy_prob
        self.candidate_ids = candidate_ids

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        if not rnd.trading_start <= t <= rnd.t_end:
            return []
        ids = self.candidate_ids or list(rnd.candidates)
        if not ids:
            return []
        orders: list[Order] = []
        for _ in range(_poisson(rng, self.arrival_rate_per_s * self.step_dt)):
            cid = rng.choice(ids)
            size = rng.lognormvariate(self.mu, self.sigma)
            if rng.random() < self.buy_prob:
                orders.append(Order(cid, size, True))
            else:
                held = self.holdings.get(cid, 0.0)
                qty = min(size / rnd.candidates[cid].pool.price, held)
                if qty > 0.0:
                    orders.append(Order(cid, qty, False))
        return orders


class MomentumTrader(Agent):
    """Buys ``size`` parent when a candidate's price rose >= ``threshold``.

    The comparison is against the price this agent observed ``lookback_s``
    seconds ago (its own tape, so it works off-grid too).
    """

    def __init__(
        self,
        lookback_s: float,
        threshold: float,
        size: float,
        candidate_ids: list[int] | None = None,
        name: str = "momentum",
    ) -> None:
        super().__init__(name)
        self.lookback_s = lookback_s
        self.threshold = threshold
        self.size = size
        self.candidate_ids = candidate_ids
        self.tape: dict[int, list[tuple[float, float]]] = {}

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        if not rnd.trading_start <= t <= rnd.t_end:
            return []
        ids = self.candidate_ids or list(rnd.candidates)
        orders: list[Order] = []
        for cid in ids:
            price = rnd.candidates[cid].pool.price
            tape = self.tape.setdefault(cid, [])
            ref = None
            for (ts, p) in tape:
                if ts <= t - self.lookback_s:
                    ref = p
            tape.append((t, price))
            if ref is not None and ref > 0.0 and price / ref - 1.0 >= self.threshold:
                orders.append(Order(cid, self.size, True))
        return orders


class Creator(Agent):
    """Registers a candidate (unless given one) and self-buys once.

    ``timing`` is seconds after ``trading_start``.
    """

    grid_only = False

    def __init__(
        self,
        candidate_id: int | None = None,
        self_buy_eth_equiv: float = 0.0,
        timing: float = 5.0,
        name: str = "creator",
    ) -> None:
        super().__init__(name)
        self.candidate_id = candidate_id
        self.self_buy_eth_equiv = self_buy_eth_equiv
        self.timing = timing
        self._done = False

    def register(self, rnd: Round, t: float, rng: random.Random) -> None:
        if self.candidate_id is None:
            self.candidate_id = rnd.register(self.name, t).id

    def event_times(self, rnd: Round) -> list[float]:
        return [rnd.trading_start + self.timing] if self.self_buy_eth_equiv > 0.0 else []

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        if self._done or self.self_buy_eth_equiv <= 0.0:
            return []
        if t + 1e-9 < rnd.trading_start + self.timing:
            return []
        self._done = True
        return [Order(self.candidate_id, self.self_buy_eth_equiv, True)]


class PanicSeller(Agent):
    """Dumps ``exit_frac`` of its holdings once price falls ``trigger_drawdown``
    below the peak it has seen.  Re-arms only after a new peak."""

    def __init__(
        self,
        trigger_drawdown: float,
        exit_frac: float,
        candidate_id: int | None = None,
        seed_buy: float = 0.0,
        seed_at: float = 1.0,
        name: str = "panic",
    ) -> None:
        super().__init__(name)
        self.trigger_drawdown = trigger_drawdown
        self.exit_frac = exit_frac
        self.candidate_id = candidate_id
        self.seed_buy = seed_buy
        self.seed_at = seed_at
        self.peak: dict[int, float] = {}
        self._armed: dict[int, bool] = {}
        self._seeded = False

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        if not rnd.trading_start <= t <= rnd.t_end:
            return []
        ids = [self.candidate_id] if self.candidate_id is not None else list(rnd.candidates)
        orders: list[Order] = []
        if self.seed_buy > 0.0 and not self._seeded and t >= rnd.trading_start + self.seed_at:
            self._seeded = True
            return [Order(cid, self.seed_buy / len(ids), True) for cid in ids]
        for cid in ids:
            price = rnd.candidates[cid].pool.price
            peak = self.peak.get(cid, 0.0)
            if price > peak:
                self.peak[cid] = price
                self._armed[cid] = True
                continue
            held = self.holdings.get(cid, 0.0)
            drawdown = 1.0 - price / peak if peak > 0.0 else 0.0
            if held > 0.0 and self._armed.get(cid, False) and drawdown >= self.trigger_drawdown:
                self._armed[cid] = False
                orders.append(Order(cid, held * self.exit_frac, False))
        return orders


class Attacker(Agent):
    """Slot-capture strategies (brief sec.6, attack-log finding 5).

    ``self_fund_win``  buy own candidate right after the snipe window, hold to
        ``T_end``, sell back at ``T_end + EXIT_EPS``.
    ``late_spike``     buy at ``t_spike`` (default ``T_end - 1``) and exit right
        after the bell -- the cheap way to move an average.
    ``dynastic``       same as ``self_fund_win`` but the capital is parent
        inherited from a previous round and the position is *kept*.
    ``block1_sweep``   ``capital_per_candidate`` into every candidate at
        ``trading_start + 0.1 s`` -- straight into the snipe tax.
    """

    grid_only = False

    def __init__(
        self,
        strategy: str = "self_fund_win",
        capital: float = 0.0,
        t_enter: float = 3.1,
        t_spike: float | None = None,
        candidate_id: int | None = None,
        capital_per_candidate: float = 0.0,
        exit_after: bool | None = None,
        name: str | None = None,
    ) -> None:
        super().__init__(name or f"attacker:{strategy}")
        if strategy not in ("self_fund_win", "late_spike", "dynastic", "block1_sweep"):
            raise ValueError(f"unknown strategy {strategy!r}")
        self.strategy = strategy
        self.capital = capital
        self.t_enter = t_enter
        self.t_spike = t_spike
        self.candidate_id = candidate_id
        self.capital_per_candidate = capital_per_candidate
        self.exit_after = (strategy != "dynastic") if exit_after is None else exit_after
        self.parent_inherited = capital if strategy == "dynastic" else 0.0
        self._entered = False
        self._exited = False

    # -- classmethod sugar -----------------------------------------------------
    @classmethod
    def self_fund_win(cls, capital: float, t_enter: float = 3.1, **kw) -> "Attacker":
        return cls("self_fund_win", capital=capital, t_enter=t_enter, **kw)

    @classmethod
    def late_spike(cls, capital: float, t_spike: float | None = None, **kw) -> "Attacker":
        return cls("late_spike", capital=capital, t_spike=t_spike, **kw)

    @classmethod
    def dynastic(cls, capital: float, t_enter: float = 3.1, **kw) -> "Attacker":
        return cls("dynastic", capital=capital, t_enter=t_enter, **kw)

    @classmethod
    def block1_sweep(cls, capital_per_candidate: float, **kw) -> "Attacker":
        return cls("block1_sweep", capital_per_candidate=capital_per_candidate, **kw)

    # -- schedule --------------------------------------------------------------
    def _entry_time(self, rnd: Round) -> float:
        if self.strategy == "late_spike":
            return rnd.t_end - 1.0 if self.t_spike is None else self.t_spike
        if self.strategy == "block1_sweep":
            return rnd.trading_start + 0.1
        return rnd.trading_start + self.t_enter

    def register(self, rnd: Round, t: float, rng: random.Random) -> None:
        if self.strategy == "block1_sweep":
            return  # sweeps whatever others registered
        if self.candidate_id is None:
            self.candidate_id = rnd.register(self.name, t).id

    def event_times(self, rnd: Round) -> list[float]:
        times = [self._entry_time(rnd)]
        if self.exit_after:
            times.append(rnd.t_end + EXIT_EPS)
        return times

    def act(self, rnd: Round, t: float, rng: random.Random) -> list[Order]:
        entry = self._entry_time(rnd)
        if not self._entered and t + 1e-9 >= entry:
            self._entered = True
            if self.strategy == "block1_sweep":
                return [
                    Order(cid, self.capital_per_candidate, True) for cid in sorted(rnd.candidates)
                ]
            return [Order(self.candidate_id, self.capital, True)]
        if self.exit_after and not self._exited and t + 1e-9 >= rnd.t_end + EXIT_EPS:
            self._exited = True
            orders: list[Order] = []
            for cid in sorted(self.holdings):
                orders += self._sell_all(cid)
            return orders
        return []


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
@dataclass
class RoundResult:
    round: Round
    outcome: RoundOutcome
    winner: int | None
    scores: dict[int, float]
    submissions: dict[int, Submission]
    reserve_paths: dict[int, list[tuple[float, float]]]
    r_paths: dict[int, list[tuple[float, float]]]
    fdv_paths: dict[int, list[tuple[float, float]]]
    pnl: dict[str, PnL]
    attacker_pnl: dict[str, PnL]


def simulate_round(
    config: RoundConfig,
    agents: list[Agent],
    rng: random.Random,
    dt: float = 1.0,
    head_supply: float | None = None,
    h_current: float | None = None,
) -> RoundResult:
    """Run one full round: register, trade, submit every candidate, finalize.

    The clock is the ``dt`` grid over ``[trading_start, submit_end]`` merged with
    every agent's :meth:`Agent.event_times` (so ``t = trading_start + 0.1`` and
    ``T_end - 1`` land exactly).  Agents are polled in list order; grid-only
    agents are skipped at off-grid stamps.
    """
    rnd = Round(config, head_supply=head_supply, t_open=0.0, h_current=h_current)
    t_reg = rnd.t_open
    for a in agents:
        a.step_dt = dt
        a.register(rnd, t_reg, rng)
    if not rnd.candidates:
        rnd.register("default", t_reg)

    grid = [rnd.trading_start + i * dt for i in range(int(round((rnd.submit_end - rnd.trading_start) / dt)) + 1)]
    stamps = {round(t, 9): True for t in grid}
    events: set[float] = set()
    for a in agents:
        for t in a.event_times(rnd):
            if rnd.trading_start <= t <= rnd.submit_end:
                events.add(round(t, 9))
    timeline = sorted(set(stamps) | events)

    reserve_paths: dict[int, list[tuple[float, float]]] = {c: [] for c in rnd.candidates}
    fdv_paths: dict[int, list[tuple[float, float]]] = {c: [] for c in rnd.candidates}

    for t in timeline:
        on_grid = t in stamps
        for a in agents:
            if a.grid_only and not on_grid:
                continue
            for o in a.act(rnd, t, rng):
                if o.amount <= 0.0:
                    continue
                a.on_fill(rnd.swap(o.candidate_id, o.amount, o.parent_in, t, trader=a.name))
        if on_grid:
            for cid, cand in rnd.candidates.items():
                reserve_paths[cid].append((t, cand.pool.reserve_parent()))
                fdv_paths[cid].append((t, cand.pool.fdv()))

    t_submit = rnd.t_end + min(EXIT_EPS, config.submit_window_s / 2.0)
    for cid in sorted(rnd.candidates):
        rnd.submit(cid, t_submit)
    outcome = rnd.finalize(rnd.submit_end)

    pnl = {a.name: a.pnl(rnd) for a in agents}
    return RoundResult(
        round=rnd,
        outcome=outcome,
        winner=outcome.winner,
        scores={c: s.avg for c, s in rnd.submissions.items()},
        submissions=dict(rnd.submissions),
        reserve_paths=reserve_paths,
        r_paths={
            c: cand.r_series(rnd.trading_start, rnd.t_end, dt)
            for c, cand in rnd.candidates.items()
        },
        fdv_paths=fdv_paths,
        pnl=pnl,
        attacker_pnl={a.name: pnl[a.name] for a in agents if isinstance(a, Attacker)},
    )
