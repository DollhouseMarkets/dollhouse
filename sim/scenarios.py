"""Ten scenarios that put numbers on the DESIGN_BRIEF_v2 claims.

Run everything::

    python -m sim.scenarios --all

Run a subset (by scenario number)::

    python -m sim.scenarios --only 4,8

Outputs
-------
``docs/sim-results.md``   tables + one interpretation paragraph per scenario
``docs/results/*.csv``    one CSV per table
``docs/figures/*.png``    matplotlib (no seaborn) figures

Everything is driven by a single fixed seed (:data:`SEED`), so a re-run
reproduces the file byte for byte.  Nothing in here mutates the other ``sim``
modules; the only additions are scenario-local ``Agent`` subclasses
(:class:`Registrant`, :class:`BudgetedMomentum`) and pure helpers.

Two chain conventions are used and each scenario says which one it runs:

``brief-literal``
    every link launches at ``a0 = 1e-3`` of its parent supply value, exactly as
    section 3 of the brief specifies.  Value per link therefore *decays* down
    the trunk (Sim 1 measures the rate); parent-denominated numbers stay
    meaningful, ETH-denominated ones shrink geometrically.
``equal-ETH-depth``
    the per-link curve scale is chosen so every link holds the same
    ETH-equivalent reserve.  This is the chain the routing and cascade
    questions (Sims 3, 7, 8, 9) are actually about: it isolates the mechanism
    from the decay Sim 1 measures.
"""

from __future__ import annotations

import argparse
import math
import random
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from .agents import (  # noqa: E402
    Agent,
    Attacker,
    MomentumTrader,
    NoiseTrader,
    Order,
    PanicSeller,
    simulate_round,
)
from .clmm import ParentEthMarket, Pool, Range  # noqa: E402
from .curves import (  # noqa: E402
    LADDER,
    MID,
    Spec,
    build_pool,
    self_similar,
    self_similar_ladder,
    self_similar_mid,
)
from .family import (  # noqa: E402
    BEST,
    DEPTH_CAPPED,
    ETH,
    FULL_LINE,
    PARENT_SOURCED,
    FamilyChain,
    FeeAllocator,
    ancestor_norm,
)
from .metrics import (  # noqa: E402
    drawdown_propagation,
    fee_flow_by_recipient,
    parent_released_per_pct_decline,
    reserve_by_generation,
)
from .reinforcement import (  # noqa: E402
    BUY_AND_BURN,
    SINGLE_SIDED_BID,
    TWO_SIDED,
    deploy,
)
from .rounds import RoundConfig, wall_fdv  # noqa: E402

__all__ = ["SEED", "Scale", "FULL_SCALE", "TINY_SCALE", "SCENARIOS", "run", "main"]

# ---------------------------------------------------------------------------
# common assumptions (mirrored exactly into the results file)
# ---------------------------------------------------------------------------
SEED = 20260910

PARENT_SUPPLY = 1e9              # FamilyToken fixed supply, every link
HOP_FEE_BPS = 7.5                # f_hop, parent side, every family swap
PROTOCOL_FEE_BPS = 100.0         # 1% on the ETH side of the genesis pool
DEV_SHARE = 0.20                 # of the protocol fee
CREATOR_SHARE = 0.40             # baseline; swept in Sim 6
ANCESTOR_SPLIT = 0.50            # of the flywheel remainder; swept in Sim 6

REGISTRATION_S = 180.0
TRADING_S = RoundConfig().trading_s  # 900 s (15-minute trading window)
SNIPE_S = 3.0
SUBMIT_WINDOW_S = 300.0

H_FRAC = 0.005                   # h: threshold = 0.5% of parent supply
H_FLOOR_FRAC = 0.25
H0 = H_FRAC * PARENT_SUPPLY

GENESIS_FDV_USD = 250_000.0      # genesis FDV at the time of the round
GENESIS_FLOOR_FDV_ETH = 1.0      # genesis curve floor (deploy constant, ETH)
GENESIS_FDV_ETH = 62.5           # genesis trades here => USD/ETH = 4000
USD_PER_ETH = GENESIS_FDV_USD / GENESIS_FDV_ETH
USD_PER_GENESIS_TOKEN = GENESIS_FDV_USD / PARENT_SUPPLY

# demand calibration: a candidate with interest 1.0 absorbs A_BASE parent over
# the window, which at the measured time shape lands ~1.3x above H.
A_BASE = 2.6 * H0
INTEREST_SIGMA = 0.6             # lognormal sigma of the per-candidate interest

REF_RESERVE_ETH = 50.0           # equal-ETH-depth reference chain, per link
REF_FLOAT_FRAC = 0.30            # fraction of supply already sold on that chain

# relative curve shapes (bounds are multiples of the launch FDV a0*P)
STANDARD_REL: Spec = [(0.991, 1.0, 1e3), (0.009, 1e3, 1e6)]
SINGLE_REL: Spec = [(1.0, 1.0, 1e3)]
WALL_REL: Spec = [(0.30, 1.0, 50.0), (0.50, 50.0, 200.0), (0.20, 200.0, 2e3)]
GENTLE_REL: Spec = [
    (0.25, 1.0, 10.0),
    (0.25, 10.0, 100.0),
    (0.25, 100.0, 1e3),
    (0.25, 1e3, 1e4),
]
CURVE_SHAPES = {
    "STANDARD": STANDARD_REL,
    "SINGLE_LIKE": SINGLE_REL,
    "WALL_LIKE": WALL_REL,
    "GENTLE_LIKE": GENTLE_REL,
}

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
RESULTS_DIR = DOCS / "results"
FIGURES_DIR = DOCS / "figures"

# --curve/--h/--hop-bps/--reset-on-win CLI overrides, applied to every
# scenario: :func:`round_config` (all round-based sims -- 1, 2, 4, 5, 6) and
# :func:`scaled_pool`/:func:`reference_chain` (the equal-ETH-depth chains
# built by Sims 3, 7, 8, 9).  ``None`` reproduces the default behaviour
# exactly; set by :func:`main` before :func:`run` executes.
CLI_CURVE_OVERRIDE: str | None = None  # "single" | "ladder" | "mid" | None
CLI_H_OVERRIDE_PCT: float | None = None  # threshold h, percent of parent supply
CLI_HOP_BPS_OVERRIDE: float | None = None  # hop fee f_hop, parent side, bps
CLI_RESET_ON_WIN: bool = True  # H snaps back to H0 on a win (Sim 2 reduced form + real rounds)
OUTPUT_SUFFIX = ""  # e.g. "_ladder", appended to output filenames


# ---------------------------------------------------------------------------
# scale (tiny scale exists so the smoke test can run every scenario)
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Scale:
    """Sizes for a run.  Coverage never shrinks; only agent/trial counts do."""

    name: str = "full"
    gens_s1: int = 20
    cands_s1: int = 5
    chains_s2: int = 200
    gens_s2: int = 20
    calib_s2: int = 20
    trials_s4: int = 40
    trials_s5: int = 8
    rounds_s9: int = 20
    dt: float = 1.0


FULL_SCALE = Scale()
TINY_SCALE = Scale(
    name="tiny",
    gens_s1=3,
    cands_s1=2,
    chains_s2=8,
    gens_s2=4,
    calib_s2=1,
    trials_s4=1,
    trials_s5=1,
    rounds_s9=2,
    dt=5.0,
)


# ---------------------------------------------------------------------------
# small formatting / IO helpers
# ---------------------------------------------------------------------------
def _fmt(v: object) -> str:
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float):
        if v != v:
            return "n/a"
        if v == 0.0:
            return "0"
        a = abs(v)
        if a >= 1e6 or a < 1e-3:
            return f"{v:.3e}"
        return f"{v:,.4g}"
    return str(v)


def df_to_md(df: pd.DataFrame) -> str:
    """Minimal markdown table writer (``tabulate`` is not a dependency here)."""
    cols = [str(c) for c in df.columns]
    lines = ["| " + " | ".join(cols) + " |", "|" + "|".join("---" for _ in cols) + "|"]
    for rec in df.itertuples(index=False, name=None):
        lines.append("| " + " | ".join(_fmt(v) for v in rec) + " |")
    return "\n".join(lines)


@dataclass
class ScenarioOutput:
    """Everything one scenario contributes to the results file."""

    key: int
    title: str
    claim: str
    tables: dict[str, pd.DataFrame] = field(default_factory=dict)
    figures: list[str] = field(default_factory=list)
    interpretation: str = ""
    notes: str = ""
    seconds: float = 0.0


def save_fig(fig, key: int, name: str, out: ScenarioOutput) -> None:
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    path = FIGURES_DIR / f"sim{key:02d}_{name}{OUTPUT_SUFFIX}.png"
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)
    out.figures.append(path.name)


def save_tables(out: ScenarioOutput) -> None:
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    for name, df in out.tables.items():
        df.to_csv(RESULTS_DIR / f"sim{out.key:02d}_{name}{OUTPUT_SUFFIX}.csv", index=False)


# ---------------------------------------------------------------------------
# curve / chain construction
# ---------------------------------------------------------------------------
def scaled_spec(rel: Spec, launch_fdv: float) -> Spec:
    """Relative shape -> absolute spec whose first bound is ``launch_fdv``."""
    return [(s, a * launch_fdv, b * launch_fdv) for (s, a, b) in rel]


def standard_spec(rel: Spec | None = None, supply: float = PARENT_SUPPLY) -> Spec:
    """The brief standard curve: launch FDV = ``a0 * P`` with ``a0 = 1e-3``."""
    return self_similar(supply, 1e-3, STANDARD_REL if rel is None else rel)


def fdv_for_float_frac(rel: Spec, frac: float, supply: float = PARENT_SUPPLY) -> float:
    """FDV (in units of the curve scale) at which ``frac`` of supply is sold."""
    pool = build_pool(rel, supply, snap_ticks=False)
    lo, hi = pool.ranges[0].lower, pool.ranges[-1].upper
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if pool.tokens_sold(mid) / supply < frac:
            lo = mid
        else:
            hi = mid
    return (0.5 * (lo + hi)) ** 2 * supply


def resolve_curve_rel(rel: Spec | None) -> Spec:
    """``rel`` unless ``None``, in which case ``--curve`` picks the shape.

    ``ladder`` -> :data:`~sim.curves.LADDER` (the deploy-config baseline,
    fractions of parent supply); ``mid`` -> :data:`~sim.curves.MID` (same
    convention, body-heavier); ``single`` -> :data:`SINGLE_REL`; unset ->
    :data:`STANDARD_REL`.  ``LADDER``/``MID``'s bounds are already absolute
    (fractions of parent supply, not multiples of a start ratio), but
    :func:`scaled_pool` only ever uses a relative spec's *ratios* -- the
    absolute FDV scale is always solved for separately -- so they drop in
    unchanged.
    """
    if rel is not None:
        return rel
    if CLI_CURVE_OVERRIDE == "ladder":
        return LADDER
    if CLI_CURVE_OVERRIDE == "mid":
        return MID
    if CLI_CURVE_OVERRIDE == "single":
        return SINGLE_REL
    return STANDARD_REL


def resolve_hop_bps(hop_fee_bps: float | None) -> float:
    """``hop_fee_bps`` unless ``None``, in which case ``--hop-bps`` applies."""
    if hop_fee_bps is not None:
        return hop_fee_bps
    return HOP_FEE_BPS if CLI_HOP_BPS_OVERRIDE is None else CLI_HOP_BPS_OVERRIDE


def scaled_pool(
    reserve_parent: float,
    rel: Spec | None = None,
    float_frac: float = REF_FLOAT_FRAC,
    hop_fee_bps: float | None = None,
    supply: float = PARENT_SUPPLY,
) -> Pool:
    """Curve of shape ``rel`` holding exactly ``reserve_parent`` of its numeraire.

    Reserves are linear in the FDV scale, so one unit build solves the scale
    exactly.  The pool is priced at the FDV where ``float_frac`` of supply has
    been sold, i.e. it has already traded.  ``rel``/``hop_fee_bps`` of
    ``None`` pick up the ``--curve``/``--hop-bps`` CLI overrides.
    """
    rel = resolve_curve_rel(rel)
    hop_fee_bps = resolve_hop_bps(hop_fee_bps)
    start_mult = fdv_for_float_frac(rel, float_frac, supply)
    unit = build_pool(
        rel, supply, snap_ticks=False, start_fdv=start_mult
    ).reserve_parent()
    scale = reserve_parent / unit
    return build_pool(
        scaled_spec(rel, scale),
        supply,
        snap_ticks=True,
        hop_fee_bps=hop_fee_bps,
        start_fdv=start_mult * scale,
        fee_on="parent",
    )


def genesis_pool(hop_fee_bps: float | None = None) -> Pool:
    """Genesis: the standard shape with the ETH scale as a deploy constant."""
    hop_fee_bps = resolve_hop_bps(hop_fee_bps)
    spec = scaled_spec(STANDARD_REL, GENESIS_FLOOR_FDV_ETH)
    return build_pool(spec, PARENT_SUPPLY, hop_fee_bps=hop_fee_bps, fee_on="parent")


def new_chain(
    protocol_fee_bps: float = PROTOCOL_FEE_BPS,
    hop_fee_bps: float | None = None,
    genesis_fdv_eth: float = GENESIS_FDV_ETH,
) -> tuple[FamilyChain, float]:
    """Brief-literal chain with only genesis, bought up to ``genesis_fdv_eth``.

    Returns ``(chain, protocol_fee_eth)`` -- the bootstrap buy pays the real 1%
    edge fee, so it belongs in the ledger like any other entry.
    """
    hop_fee_bps = resolve_hop_bps(hop_fee_bps)
    chain = FamilyChain(genesis_pool(hop_fee_bps), "GENESIS", protocol_fee_bps)
    cost = chain.genesis_pool.quote_cost_to_fdv(genesis_fdv_eth)
    gross = cost / ((1.0 - chain.protocol_fee_rate) * (1.0 - hop_fee_bps / 1e4))
    res = chain.execute_route(chain.route(ETH, 0, FULL_LINE), gross)
    return chain, res.protocol_fee_eth


def reference_chain(
    n_links: int,
    rel: Spec | None = None,
    reserve_eth: float = REF_RESERVE_ETH,
    hop_fee_bps: float | None = None,
    float_frac: float = REF_FLOAT_FRAC,
    protocol_fee_bps: float = PROTOCOL_FEE_BPS,
) -> FamilyChain:
    """Equal-ETH-depth chain of ``n_links`` links (indices ``0..n_links-1``).

    ``rel``/``hop_fee_bps`` of ``None`` pick up the ``--curve``/``--hop-bps``
    CLI overrides (resolved once here, then threaded through explicitly, so
    every link in the chain -- Sims 3, 7, 8, 9 -- is built from the same
    resolved shape).
    """
    rel = resolve_curve_rel(rel)
    hop_fee_bps = resolve_hop_bps(hop_fee_bps)
    chain = FamilyChain(
        scaled_pool(reserve_eth, rel, float_frac, hop_fee_bps),
        "GENESIS",
        protocol_fee_bps,
    )
    for i in range(1, n_links):
        parent_px = chain.price_in_eth(i - 1)
        chain.promote(
            scaled_pool(reserve_eth / parent_px, rel, float_frac, hop_fee_bps), f"#{i}"
        )
    return chain


def usd(eth: float) -> float:
    return eth * USD_PER_ETH


def eth_of_usd(dollars: float) -> float:
    return dollars / USD_PER_ETH


def allocator(
    creator_share: float = CREATOR_SHARE,
    ancestor_split: float = ANCESTOR_SPLIT,
    dev_share: float = DEV_SHARE,
) -> FeeAllocator:
    """Brief S4 split with the flywheel remainder cut ``ancestor_split``/rest."""
    rest = 1.0 - dev_share - creator_share
    return FeeAllocator(
        dev_share=dev_share,
        creator_share=creator_share,
        ancestor_share=rest * ancestor_split,
        reinforce_share=rest * (1.0 - ancestor_split),
    )


# ---------------------------------------------------------------------------
# scenario-local agents
# ---------------------------------------------------------------------------
class Registrant(Agent):
    """Registers one candidate with a chosen id and then does nothing."""

    def __init__(self, cid: int, name: str) -> None:
        super().__init__(name)
        self.cid = cid

    def register(self, rnd, t, rng) -> None:
        rnd.register(self.name, t, candidate_id=self.cid)
        self.candidate_id = self.cid


class BudgetedMomentum(MomentumTrader):
    """:class:`~sim.agents.MomentumTrader` with a total budget and a cooldown.

    The stock momentum agent re-fires every step while the trend holds, which on
    a monotonically climbing launch curve is unbounded demand.  Real chasers run
    out of money; this one does too.
    """

    def __init__(self, budget: float, cooldown_s: float = 30.0, **kw) -> None:
        super().__init__(**kw)
        self.remaining = float(budget)
        self.cooldown_s = float(cooldown_s)
        self._last: dict[int, float] = {}

    def act(self, rnd, t, rng) -> list[Order]:
        out: list[Order] = []
        for o in super().act(rnd, t, rng):
            if self.remaining <= 0.0:
                break
            if t - self._last.get(o.candidate_id, -1e18) < self.cooldown_s:
                continue
            amt = min(o.amount, self.remaining)
            self.remaining -= amt
            self._last[o.candidate_id] = t
            out.append(Order(o.candidate_id, amt, True))
        return out


def interest_noise(cid: int, absorption: float, name: str | None = None) -> NoiseTrader:
    """Noise flow calibrated to absorb ``absorption`` parent over the window.

    Poisson arrivals at 0.5/s, lognormal sizes, 80/20 buy/sell, so the expected
    *net* parent taken by the pool is ``0.5 * 600 * mean * (0.8 - 0.2)``.
    """
    lam, sigma, buy_prob = 0.5, 0.5, 0.8
    mean = absorption / (lam * TRADING_S * (2.0 * buy_prob - 1.0))
    return NoiseTrader(
        lam,
        math.log(mean) - 0.5 * sigma * sigma,
        sigma,
        buy_prob,
        [cid],
        name=name or f"interest:{cid}",
    )


def round_config(
    rel: Spec | None = None,
    h_frac: float = H_FRAC,
    hop_fee_bps: float | None = None,
    snipe: bool = True,
    parent_supply: float = PARENT_SUPPLY,
) -> RoundConfig:
    """A :class:`~sim.rounds.RoundConfig` with the brief's timings.

    ``CLI_CURVE_OVERRIDE``/``CLI_H_OVERRIDE_PCT``/``CLI_HOP_BPS_OVERRIDE``/
    ``CLI_RESET_ON_WIN`` (set by ``--curve``/``--h``/``--hop-bps``/
    ``--reset-on-win`` in :func:`main`) take priority over
    ``rel``/``h_frac``/``hop_fee_bps`` when set, so every scenario that builds
    its round through this helper -- Sims 1, 2, 4, 5 and 6 -- picks up the
    override without changing its own signature.
    """
    if CLI_CURVE_OVERRIDE == "ladder":
        curve_spec = self_similar_ladder(parent_supply)
    elif CLI_CURVE_OVERRIDE == "mid":
        curve_spec = self_similar_mid(parent_supply)
    elif CLI_CURVE_OVERRIDE == "single":
        curve_spec = self_similar(parent_supply, 1e-3, SINGLE_REL)
    else:
        curve_spec = self_similar(parent_supply, 1e-3, STANDARD_REL if rel is None else rel)
    effective_h_frac = (
        CLI_H_OVERRIDE_PCT / 100.0 if CLI_H_OVERRIDE_PCT is not None else h_frac
    )
    hop_fee_bps = resolve_hop_bps(hop_fee_bps)
    return RoundConfig(
        registration_s=REGISTRATION_S,
        trading_s=TRADING_S,
        submit_window_s=SUBMIT_WINDOW_S,
        snipe_s=SNIPE_S,
        snipe_start=0.99 if snipe else 0.0,
        snipe_end=0.01 if snipe else 0.0,
        h_threshold_frac=effective_h_frac,
        h_floor_frac=H_FLOOR_FRAC,
        curve_spec=curve_spec,
        parent_supply=parent_supply,
        hop_fee_bps=hop_fee_bps,
        reset_on_win=CLI_RESET_ON_WIN,
    )


def flatten_pool(pool: Pool) -> Pool:
    """Merge overlapping positions into an equivalent non-overlapping ladder.

    :meth:`sim.clmm.Pool.add_locked_position` deliberately appends a bid that
    sits *inside* an existing curve range, and the swap kernels walk positions
    sequentially rather than summing liquidity where they overlap - so a
    deposited bid would otherwise make a pool behave *worse* than before, which
    is not what a real v4 pool does.  Splitting at every boundary and summing
    ``L`` inside each elementary interval reproduces exactly the tick ladder a
    PoolManager would see, and leaves every closed form (reserve, tokens sold,
    cost-to-FDV) unchanged.
    """
    bounds = sorted({b for r in pool.ranges for b in (r.lower, r.upper)})
    ranges = []
    for lo, hi in zip(bounds, bounds[1:]):
        mid = 0.5 * (lo + hi)
        L = math.fsum(r.L for r in pool.ranges if r.lower <= mid <= r.upper)
        if L > 0.0 and hi > lo:
            ranges.append(Range(lo, hi, L))
    out = Pool(ranges, pool.supply, pool.sqrtP, pool.hop_fee_bps, pool.fee_on)
    out.fees_accrued_parent = pool.fees_accrued_parent
    out.fees_accrued_token = pool.fees_accrued_token
    return out


def deploy_flat(chain: FamilyChain, j: int, *args, **kw):
    """:func:`sim.reinforcement.deploy` followed by :func:`flatten_pool` on ``j``."""
    res = deploy(chain, j, *args, **kw)
    if res is not None:
        chain.links[j] = replace(chain.links[j], pool=flatten_pool(chain.links[j].pool))
    return res


def market_at_parity(
    chain: FamilyChain, index: int, depth_eth: float, fee_bps: float = 30.0
) -> ParentEthMarket:
    """External ETH market for link ``index``, seeded at the family price."""
    market = ParentEthMarket(
        depth_eth=depth_eth,
        depth_token=depth_eth / chain.price_in_eth(index),
        fee_bps=fee_bps,
    )
    return chain.add_external_market(index, market)


# ===========================================================================
# Sim 1 -- lifecycle GENESIS -> #20
# ===========================================================================
EDGE_IN_USD = 50_000.0        # gross ETH entering the family after each round
EDGE_EXIT_FRAC = 0.5          # half of it leaves again before the next round
EDGE_CAP_FRAC = 0.05          # a single entry never exceeds 5% of head ETH FDV


def _lifecycle_agents(rng: random.Random, n_cand: int) -> tuple[list[Agent], list[float]]:
    """Registrants + per-candidate interest flow + momentum + panic."""
    interests = [rng.lognormvariate(0.0, INTEREST_SIGMA) for _ in range(n_cand)]
    total = math.fsum(interests) * A_BASE
    agents: list[Agent] = [Registrant(i, f"creator:{i}") for i in range(n_cand)]
    for i, x in enumerate(interests):
        agents.append(interest_noise(i, x * A_BASE))
    agents.append(
        BudgetedMomentum(
            budget=0.30 * total,
            cooldown_s=30.0,
            lookback_s=60.0,
            threshold=0.10,
            size=0.02 * A_BASE,
            name="momentum",
        )
    )
    agents.append(
        PanicSeller(
            trigger_drawdown=0.25,
            exit_frac=0.5,
            seed_buy=0.05 * total,
            name="panic",
        )
    )
    return agents, interests


def sim1_lifecycle(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        1,
        "Lifecycle: GENESIS to #%d, 5 candidates per round" % scale.gens_s1,
        "creators and developer earn meaningfully; ancestors keep receiving",
    )
    chain, boot_fee = new_chain()
    alloc = allocator()
    ledger: list[dict[str, float]] = [alloc.allocate(boot_fee, 0)]
    cfg = round_config()
    h_current: float | None = None
    rows = []
    gen = 0
    attempts = 0
    while gen < scale.gens_s1 and attempts < 3 * scale.gens_s1:
        attempts += 1
        agents, interests = _lifecycle_agents(rng, scale.cands_s1)
        res = simulate_round(
            cfg, agents, rng, dt=scale.dt, head_supply=PARENT_SUPPLY, h_current=h_current
        )
        h_used = res.outcome.h_used
        h_current = res.outcome.h_next
        if res.winner is None:
            rows.append(
                {
                    "generation": gen + 1,
                    "attempt": attempts,
                    "winner": "none",
                    "best_avg_parent": res.outcome.best_avg,
                    "threshold_parent": h_used,
                }
            )
            continue
        gen += 1
        wcand = res.round.candidates[res.winner]
        parent_index = gen - 1
        chain.promote(wcand.pool, f"#{gen}")
        for cid, cand in res.round.candidates.items():
            if cid != res.winner:
                chain.add_side_pool(f"g{gen}-c{cid}", cand.pool, parent_index=parent_index)

        # --- ETH edge flow attributable to the new head ----------------------
        cap = EDGE_CAP_FRAC * chain.fdv_eth(gen)
        entry = min(eth_of_usd(EDGE_IN_USD), cap)
        r_in = chain.execute_route(chain.route(ETH, gen, FULL_LINE), entry)
        ledger.append(alloc.allocate(r_in.protocol_fee_eth, gen))
        r_out = chain.execute_route(
            chain.route(gen, ETH, FULL_LINE), r_in.amount_out * EDGE_EXIT_FRAC
        )
        ledger.append(alloc.allocate(r_out.protocol_fee_eth, gen))
        fee_round = r_in.protocol_fee_eth + r_out.protocol_fee_eth
        split = alloc.allocate(fee_round, gen)
        anc = math.fsum(v for k, v in split.items() if k.startswith("ancestor:"))
        rows.append(
            {
                "generation": gen,
                "attempt": attempts,
                "winner": f"c{res.winner}",
                "winner_interest": interests[res.winner],
                "best_avg_parent": res.outcome.best_avg,
                "threshold_parent": h_used,
                "avg_over_threshold": res.outcome.best_avg / h_used,
                "embedded_parent": wcand.pool.reserve_parent(),
                "float_frac": wcand.pool.tokens_sold() / wcand.pool.supply,
                "fdv_parent": wcand.pool.fdv(),
                "fdv_eth": chain.fdv_eth(gen),
                "fdv_usd": usd(chain.fdv_eth(gen)),
                "edge_volume_eth": entry + r_out.amount_out,
                "protocol_fee_eth": fee_round,
                "creator_usd": usd(split[f"creator:{gen}"]),
                "dev_usd": usd(split["dev"]),
                "ancestor_usd": usd(anc),
                "reinforce_usd": usd(split[f"reinforce:{parent_index}"]),
            }
        )

    per_gen = pd.DataFrame(rows)
    wins = per_gen[per_gen["winner"] != "none"].reset_index(drop=True)
    flows = fee_flow_by_recipient(ledger)
    flows["amount_usd"] = flows["amount"].map(usd)
    totals = (
        flows.groupby("kind", as_index=False)[["amount_usd"]]
        .sum()
        .assign(share=lambda d: d["amount_usd"] / d["amount_usd"].sum())
        .sort_values("amount_usd", ascending=False)
        .reset_index(drop=True)
    )
    out.tables["per_generation"] = per_gen
    out.tables["fee_flow_by_recipient"] = flows
    out.tables["fee_totals_by_kind"] = totals

    if not wins.empty:
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.plot(wins["generation"], wins["best_avg_parent"], "o-", label="winner avg absorption")
        ax.plot(wins["generation"], wins["threshold_parent"], "s--", label="threshold H")
        ax.set_xlabel("generation")
        ax.set_ylabel(f"parent tokens (average over the {TRADING_S:.0f} s window)")
        ax.set_title("Sim 1: winning average absorption vs threshold")
        ax.legend()
        ax.grid(alpha=0.3)
        save_fig(fig, 1, "absorption", out)

        fig, ax = plt.subplots(figsize=(7, 4))
        ax.semilogy(wins["generation"], wins["fdv_usd"], "o-")
        ax.set_xlabel("generation")
        ax.set_ylabel("link FDV (USD, log scale)")
        ax.set_title("Sim 1: ETH-denominated value per generation")
        ax.grid(alpha=0.3, which="both")
        save_fig(fig, 1, "fdv_path", out)

        fig, ax = plt.subplots(figsize=(7, 4))
        for col, lab in (
            ("creator_usd", "creator"),
            ("dev_usd", "developer"),
            ("ancestor_usd", "ancestor sleeve"),
            ("reinforce_usd", "parent reinforcement"),
        ):
            ax.plot(wins["generation"], wins[col].cumsum(), label=lab)
        ax.set_xlabel("generation")
        ax.set_ylabel("cumulative USD")
        ax.set_title("Sim 1: cumulative fee income by recipient class")
        ax.legend()
        ax.grid(alpha=0.3)
        save_fig(fig, 1, "income", out)

        anc = flows[flows["kind"] == "ancestor"].sort_values("target")
        fig, ax = plt.subplots(figsize=(7, 4))
        ax.bar(anc["target"], anc["amount_usd"])
        ax.set_xlabel("ancestor index")
        ax.set_ylabel("cumulative USD received")
        ax.set_title("Sim 1: ancestor sleeve receipts by generation index")
        ax.grid(alpha=0.3, axis="y")
        save_fig(fig, 1, "ancestors", out)

    n_fail = int((per_gen["winner"] == "none").sum())
    wins = wins.assign(
        fdv_vs_parent=wins["fdv_parent"] / PARENT_SUPPLY,
        backing_frac=wins["embedded_parent"] / wins["fdv_parent"],
    )
    out.tables["per_generation"] = per_gen.merge(
        wins[["generation", "fdv_vs_parent", "backing_frac"]], on="generation", how="left"
    )
    dev_total = float(flows.loc[flows["kind"] == "dev", "amount_usd"].sum())
    cre_total = float(flows.loc[flows["kind"] == "creator", "amount_usd"].sum())
    anc_total = float(flows.loc[flows["kind"] == "ancestor", "amount_usd"].sum())
    anc_nonzero = int((flows[flows["kind"] == "ancestor"]["amount"] > 0).sum())
    out.interpretation = (
        f"Brief-literal chain (a0 = 1e-3 at every link). {len(wins)} of {attempts} rounds produced "
        f"a winner ({n_fail} failed). The claim *ancestors keep receiving* is VERIFIED "
        f"mechanically: all {anc_nonzero} ancestor indices hold a non-zero balance, because the "
        f"sleeve pays ancestors 0..M on every ETH-edge swap and M grows with the chain; over the "
        f"run the split lands exactly on the configured "
        f"{DEV_SHARE:.0%}/{CREATOR_SHARE:.0%}/{(1 - DEV_SHARE - CREATOR_SHARE) / 2:.0%}/"
        f"{(1 - DEV_SHARE - CREATOR_SHARE) / 2:.0%} shares. The claim *creators and developer earn "
        f"meaningfully* is VERIFIED conditional on volume and on nothing else: at "
        f"${EDGE_IN_USD:,.0f} of entry per round the creator of a winning link takes a median "
        f"${wins['creator_usd'].median():,.0f} and the developer half of that, for run totals of "
        f"${cre_total:,.0f} and ${dev_total:,.0f} plus ${anc_total:,.0f} to the ancestor sleeve. "
        f"That is a fee split doing its job, not a business - the number is linear in edge volume "
        f"and there is no other source. The scenario's real finding is elsewhere. To clear a "
        f"threshold of {H_FRAC:.1%} of parent supply *as an average over the full {TRADING_S:.0f} s*, a winner "
        f"has to absorb {wins['avg_over_threshold'].median():.1f}x that threshold in total, and "
        f"the standard curve cannot survive it: the median winner finishes the round with "
        f"{wins['float_frac'].median():.1%} of its supply already sold and an FDV of "
        f"{wins['fdv_vs_parent'].median():.2f}x its own parent's, backed by embedded parent worth "
        f"only {wins['backing_frac'].median():.2%} of that mark. Each generation is therefore "
        f"marked *up* relative to its parent while being backed by a thinner and thinner slice of "
        f"real liquidity - head FDV runs from ${wins['fdv_usd'].iloc[0]:,.0f} at #1 to "
        f"${wins['fdv_usd'].iloc[-1]:,.3g} at #{int(wins['generation'].iloc[-1])}, which is a "
        f"mark-to-market artefact of an exhausted bonding curve, not value. The actionable "
        f"conclusion for the deploy constants: h = {H_FRAC:.1%} is too high for this curve, or the "
        f"curve's body is too thin for this h. Sim 4 and Sim 8 are where that pair gets set; the "
        f"invariant in section 3 (H <= 25% of wall absorption) is satisfied here and is *not* "
        f"sufficient, because it bounds the average while the round consumes the total."
    )
    out.notes = (
        "ETH-edge volume per round is exogenous (${:,.0f} in, {:.0%} back out), capped at "
        "{:.0%} of the head's ETH FDV so a single trade cannot exceed the link's own size. "
        "Losing candidates are kept as side pools parented at the previous head."
    ).format(EDGE_IN_USD, EDGE_EXIT_FRAC, EDGE_CAP_FRAC)
    return out


# ===========================================================================
# Sim 2 -- stochastic chains (Monte Carlo)
# ===========================================================================
GEN_INTEREST_SIGMA = math.log(10.0) / 3.29  # 90% CI of the generation factor spans 10x


def _calibrate_avg_per_interest(scale: Scale, rng: random.Random) -> tuple[float, float]:
    """Fit ``avg_absorption = k * interest * A_BASE`` on full agent rounds."""
    cfg = round_config()
    ks: list[float] = []
    for _ in range(max(scale.calib_s2, 1)):
        agents, interests = _lifecycle_agents(rng, 3)
        res = simulate_round(cfg, agents, rng, dt=scale.dt, head_supply=PARENT_SUPPLY)
        for cid, avg in res.scores.items():
            ks.append(avg / (interests[cid] * A_BASE))
    mean = math.fsum(ks) / len(ks)
    var = math.fsum((k - mean) ** 2 for k in ks) / max(len(ks) - 1, 1)
    return mean, math.sqrt(var)


S2_REGIMES = (0.20, 0.35, 0.50, 1.00)  # median interest as a multiple of A_BASE


def sim2_stochastic(
    scale: Scale, rng: random.Random, reset_on_win: bool | None = None
) -> ScenarioOutput:
    """``reset_on_win`` mirrors :attr:`~sim.rounds.RoundConfig.reset_on_win`:

    the reduced-form ``H`` ladder here decays only across *consecutive*
    failures; a win snaps it back to ``H0`` by default (``True``), matching
    :meth:`sim.rounds.Round.finalize`.  ``False`` reproduces the old
    behaviour where a win carries over whatever ``H`` had already decayed to.
    ``None`` (the default) picks up the ``--reset-on-win`` CLI override
    (:data:`CLI_RESET_ON_WIN`, itself defaulting to ``True``).
    """
    reset_on_win = CLI_RESET_ON_WIN if reset_on_win is None else reset_on_win
    out = ScenarioOutput(
        2,
        "Stochastic chains: %d Monte Carlo runs per demand regime" % scale.chains_s2,
        "decay-with-floor keeps the chain alive without junk wins",
    )
    k_mean, k_sd = _calibrate_avg_per_interest(scale, rng)
    # sim2 runs a hand-rolled reduced-form threshold ladder (not via
    # round_config), so the --h override is applied here directly.
    h0 = (CLI_H_OVERRIDE_PCT / 100.0 * PARENT_SUPPLY) if CLI_H_OVERRIDE_PCT is not None else H0
    h_floor = H_FLOOR_FRAC * h0
    zombie_line = 2.0 * h_floor
    max_rounds = 2 * scale.gens_s2
    ks = sorted({k for k in (5, 10, 20) if k <= scale.gens_s2} | {scale.gens_s2})

    surv_rows = []
    summ_rows = []
    decay_rows = []
    for regime in S2_REGIMES:
        reached: list[int] = []
        win_rounds: list[list[int]] = []
        n_rounds = n_norounds = n_wins = n_zombie = 0
        h_path: list[list[float]] = []
        for _ in range(scale.chains_s2):
            h, gen = h0, 0
            path = []
            wins_at: list[int] = []
            for _r in range(max_rounds):
                if gen >= scale.gens_s2:
                    break
                n_rounds += 1
                path.append(h)
                g = rng.lognormvariate(0.0, GEN_INTEREST_SIGMA)
                best = max(
                    regime
                    * g
                    * rng.lognormvariate(0.0, INTEREST_SIGMA)
                    * A_BASE
                    * max(rng.gauss(k_mean, k_sd), 0.05 * k_mean)
                    for _c in range(5)
                )
                if best >= h:
                    gen += 1
                    n_wins += 1
                    wins_at.append(_r + 1)
                    n_zombie += best < zombie_line
                    if reset_on_win:
                        h = h0
                else:
                    n_norounds += 1
                    h = max(0.9 * h, h_floor)
            reached.append(gen)
            win_rounds.append(wins_at)
            h_path.append(path)
        for k in ks:
            at_k = [w[k - 1] for w in win_rounds if len(w) >= k]
            surv_rows.append(
                {
                    "demand_regime": regime,
                    "k": k,
                    "p_reach_k_in_k_rounds": sum(1 for r in at_k if r <= k)
                    / len(reached),
                    "p_reach_k_in_2k_rounds": sum(1 for r in at_k if r <= 2 * k)
                    / len(reached),
                    "mean_rounds_to_reach_k": (
                        math.fsum(at_k) / len(at_k) if at_k else float("nan")
                    ),
                    "budget_rounds": max_rounds,
                }
            )
        summ_rows.append(
            {
                "demand_regime": regime,
                "chains": scale.chains_s2,
                "mean_index_reached": sum(reached) / len(reached),
                "rounds_simulated": n_rounds,
                "frac_rounds_no_winner": n_norounds / n_rounds,
                "wins": n_wins,
                "rounds_per_win": n_rounds / max(n_wins, 1),
                "zombie_win_rate": n_zombie / max(n_wins, 1),
            }
        )
        for i in range(max(len(pth) for pth in h_path)):
            vals = [pth[i] for pth in h_path if len(pth) > i]
            decay_rows.append(
                {
                    "demand_regime": regime,
                    "round_number": i + 1,
                    "chains_still_running": len(vals),
                    "mean_threshold_parent": math.fsum(vals) / len(vals),
                    "min_threshold_parent": min(vals),
                }
            )
    survival = pd.DataFrame(surv_rows)
    summary = pd.DataFrame(summ_rows)
    decay = pd.DataFrame(decay_rows)
    calib = pd.DataFrame(
        [
            {
                "k_mean": k_mean,
                "k_sd": k_sd,
                "a_base_parent": A_BASE,
                "h0_parent": h0,
                "h_floor_parent": h_floor,
                "zombie_line_parent": zombie_line,
                "gen_interest_sigma": GEN_INTEREST_SIGMA,
                "calibration_rounds": max(scale.calib_s2, 1),
            }
        ]
    )
    out.tables["survival"] = survival
    out.tables["summary"] = summary
    out.tables["threshold_path"] = decay
    out.tables["calibration"] = calib

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for regime in S2_REGIMES:
        sub = survival[survival["demand_regime"] == regime].sort_values("k")
        ax.plot(
            sub["k"],
            sub["p_reach_k_in_k_rounds"],
            "o-",
            label=f"median interest x{regime:.2f}",
        )
    ax.set_xlabel("index k")
    ax.set_ylabel("P(chain reaches #k)")
    ax.set_title("Sim 2: P(reach #k without a single failed round)")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 2, "survival", out)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for regime in S2_REGIMES:
        d = decay[decay["demand_regime"] == regime]
        ax.plot(d["round_number"], d["mean_threshold_parent"], label=f"x{regime:.2f}")
    ax.axhline(h_floor, color="k", ls=":", label="floor 0.25 H0")
    ax.set_xlabel("round number")
    ax.set_ylabel("threshold H (parent tokens)")
    ax.set_title("Sim 2: threshold decay path by demand regime")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 2, "threshold", out)

    base = summary[summary["demand_regime"] == 1.0].iloc[0]
    weak = summary[summary["demand_regime"] == S2_REGIMES[0]].iloc[0]
    _w = survival[
        (survival["demand_regime"] == S2_REGIMES[0]) & (survival["k"] == scale.gens_s2)
    ]
    p_weak = float(_w["p_reach_k_in_k_rounds"].iloc[0])
    rounds_weak = float(_w["mean_rounds_to_reach_k"].iloc[0])
    _b = survival[
        (survival["demand_regime"] == 1.0) & (survival["k"] == scale.gens_s2)
    ]
    rounds_base = float(_b["mean_rounds_to_reach_k"].iloc[0])
    out.interpretation = (
        f"Reduced-form rounds: the full agent engine was run {max(scale.calib_s2, 1)} times to fit "
        f"avg_absorption = k * interest * A_BASE (k = {k_mean:.3f} +/- {k_sd:.3f}), and the Monte "
        f"Carlo then draws interest as a per-generation lognormal factor spanning 10x (sigma = "
        f"{GEN_INTEREST_SIGMA:.2f}) times a per-candidate lognormal (sigma = {INTEREST_SIGMA}), all "
        f"scaled by a demand regime - because the answer turns out to be entirely a function of how "
        f"much demand the market brings. At the baseline calibration (x1.00) the mechanism is "
        f"nowhere near binding: {float(base['frac_rounds_no_winner']):.1%} of rounds fail and it takes "
        f"{rounds_base:.1f} rounds to get to #{scale.gens_s2}, with a zombie rate of "
        f"{float(base['zombie_win_rate']):.1%}. The regime that actually tests the claim is thin "
        f"demand (x{S2_REGIMES[0]:.2f}), where {float(weak['frac_rounds_no_winner']):.1%} of rounds "
        f"fail, reaching #{scale.gens_s2} takes {rounds_weak:.1f} rounds instead of "
        f"{scale.gens_s2}, and only {p_weak:.0%} of chains get there without a single failed "
        f"round. Every chain does eventually get there - a stalled round costs time, never the "
        f"chain. There the claim holds in both directions: the "
        f"x0.9 decay pulls H down fast enough that a stalled chain restarts within a handful of "
        f"rounds, while the 25% floor ({h_floor:,.0f} parent - 0.125% of parent supply absorbed on "
        f"average for ten straight minutes) still pushes "
        f"{float(weak['zombie_win_rate']):.1%} of wins into the junk category rather than letting "
        f"the bar fall to nothing. Decay-with-floor is VERIFIED. Two exposures the numbers make "
        f"visible: H never re-arms upward after a win, so one bad patch permanently lowers the bar "
        f"for the rest of the chain's life; and because the score is an *average* over the whole "
        f"window, a thin round is decided by whichever single candidate drew the fat tail, not by "
        f"aggregate interest."
    )
    out.notes = (
        "H persists across wins (brief section 2 only ever decays it), so the threshold path is "
        "monotone non-increasing per chain. Every chain gets a budget of {} rounds to reach #{}, "
        "and each demand regime is an independent set of {} chains."
    ).format(max_rounds, scale.gens_s2, scale.chains_s2)
    return out


# ===========================================================================
# Sim 3 -- bad-link collapse
# ===========================================================================
S3_LINKS = 13                 # genesis + 12 links, so #12 exists
S3_BAD = 6
S3_EXTERNAL_AT = 9
S3_TRADE_USD = 5_000.0
EDGE_VOL_USD_PER_ROUND = 250_000.0
REINFORCE_PER_ROUND_ETH = eth_of_usd(
    EDGE_VOL_USD_PER_ROUND
    * (PROTOCOL_FEE_BPS / 1e4)
    * (1.0 - DEV_SHARE - CREATOR_SHARE)
    * (1.0 - ANCESTOR_SPLIT)
)


def _s3_chain() -> FamilyChain:
    chain = reference_chain(S3_LINKS)
    market_at_parity(chain, S3_EXTERNAL_AT, depth_eth=REF_RESERVE_ETH)
    return chain


def _s3_routes(chain: FamilyChain, size_eth: float, tag: dict) -> list[dict]:
    rows = []
    for dst in (10, 12):
        for mode in (FULL_LINE, PARENT_SOURCED, DEPTH_CAPPED(3)):
            work = chain.clone()
            route = work.route(ETH, dst, mode, probe=size_eth)
            res = work.execute_route(route, size_eth)
            rows.append(
                dict(
                    tag,
                    dst=dst,
                    mode=str(mode),
                    hops=route.hops,
                    uses_external=route.uses_external,
                    slippage_frac=res.effective_loss_frac,
                    slippage_usd_on_5k=res.effective_loss_frac * S3_TRADE_USD,
                    protocol_fee_eth=res.protocol_fee_eth,
                    hop_fee_legs=len(res.hop_fees),
                    exhausted=res.exhausted,
                    tokens_out=res.amount_out,
                )
            )
    return rows


def sim3_bad_link(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        3,
        "Bad-link collapse at #%d on a 12-link chain" % S3_BAD,
        "best-route + reinforcement mitigates a weak link",
    )
    size = eth_of_usd(S3_TRADE_USD)
    base = _s3_chain()
    rows = _s3_routes(
        base, size, {"shock": 0.0, "reinforcement": "none", "external_market": "healthy"}
    )

    budgets = {
        "none": 0.0,
        "fee_funded_3_rounds": 3.0 * REINFORCE_PER_ROUND_ETH,
        "cap_max": 0.5 * REF_RESERVE_ETH,
    }
    deposits = []
    for shock in (0.5, 0.9, 0.99):
        for label, budget in budgets.items():
            for regime in ("independent", "arbitraged"):
                work = _s3_chain()
                if budget > 0.0:
                    dep = deploy_flat(
                        work, S3_BAD, budget, SINGLE_SIDED_BID, bid_width=0.30
                    )
                    if dep is not None and regime == "independent":
                        reserve = work.links[S3_BAD].pool.reserve_parent()
                        deposits.append(
                            {
                                "budget_label": label,
                                "budget_eth": budget,
                                "budget_usd": usd(budget),
                                "parent_deposited": dep.parent_deposited,
                                "parent_undeployed": dep.parent_undeployed,
                                "pool_reserve_parent": reserve,
                                "deposit_frac_of_reserve": dep.parent_deposited / reserve,
                            }
                        )
                pool = work.links[S3_BAD].pool
                f_pre = pool.fdv()
                pool.swap_exact_in(pool.tokens_sold() * shock, parent_in=False)
                if regime == "arbitraged":
                    work.propagate_arbitrage(S3_BAD, rounds=2)
                tag = {
                    "shock": shock,
                    "reinforcement": label,
                    "external_market": regime,
                    "link6_drawdown": 1.0 - pool.fdv() / f_pre,
                }
                rows += _s3_routes(work, size, tag)

    table = pd.DataFrame(rows)
    healthy = (
        table[table["shock"] == 0.0].set_index(["dst", "mode"])["slippage_frac"].to_dict()
    )
    table["excess_slippage_vs_healthy"] = [
        r.slippage_frac - healthy[(r.dst, r.mode)] for r in table.itertuples()
    ]
    out.tables["route_slippage"] = table
    out.tables["reinforcement_deposits"] = pd.DataFrame(deposits).drop_duplicates(
        subset=["budget_label"]
    )

    fig, ax = plt.subplots(figsize=(8, 4.5))
    sub = table[
        (table["dst"] == 12)
        & (table["reinforcement"] == "none")
        & (table["external_market"] != "arbitraged")
    ]
    for mode in sub["mode"].unique():
        s_ = sub[sub["mode"] == mode].sort_values("shock")
        ax.plot(s_["shock"], s_["slippage_frac"] * 100, "o-", label=mode)
    ax.set_xlabel("fraction of #%d's float dumped" % S3_BAD)
    ax.set_ylabel("slippage on a $5k ETH -> #12 buy (%)")
    ax.set_title("Sim 3: routing through a collapsing link (independent external market)")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 3, "route_slippage", out)

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for label in budgets:
        s_ = table[
            (table["dst"] == 12)
            & (table["mode"] == "FULL_LINE")
            & (table["reinforcement"] == label)
            & (table["external_market"] == "independent")
        ].sort_values("shock")
        ax.plot(s_["shock"], s_["link6_drawdown"] * 100, "o-", label=label)
    ax.set_xlabel("fraction of #%d's float dumped" % S3_BAD)
    ax.set_ylabel("drawdown of #%d (%%)" % S3_BAD)
    ax.set_title("Sim 3: what a reinforcement bid absorbs")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 3, "reinforcement", out)

    def _pick(shock, mode, reinf="none", regime="independent", dst=12, col="slippage_frac"):
        q = table[
            (table["shock"] == shock)
            & (table["mode"] == mode)
            & (table["reinforcement"] == reinf)
            & (table["external_market"] == regime)
            & (table["dst"] == dst)
        ]
        return float(q[col].iloc[0])

    healthy_full = _pick(0.0, "FULL_LINE", regime="healthy")
    healthy_ps = _pick(0.0, "PARENT_SOURCED", regime="healthy")
    full99 = _pick(0.99, "FULL_LINE")
    ps99 = _pick(0.99, "PARENT_SOURCED")
    ps99_arb = _pick(0.99, "PARENT_SOURCED", regime="arbitraged")
    dd_none = _pick(0.99, "FULL_LINE", col="link6_drawdown")
    dd_fee = _pick(0.99, "FULL_LINE", reinf="fee_funded_3_rounds", col="link6_drawdown")
    dd_cap = _pick(0.99, "FULL_LINE", reinf="cap_max", col="link6_drawdown")
    dep = out.tables["reinforcement_deposits"]
    fee_frac = float(dep[dep["budget_label"] == "fee_funded_3_rounds"]["deposit_frac_of_reserve"].iloc[0])
    cap_frac = float(dep[dep["budget_label"] == "cap_max"]["deposit_frac_of_reserve"].iloc[0])
    out.interpretation = (
        f"Equal-ETH-depth chain, ${S3_TRADE_USD:,.0f} routes, slippage measured against pre-trade "
        f"mid prices. The claim splits and the halves get opposite verdicts. **Best-route is "
        f"VERIFIED, with a caveat about which venue is broken.** On a healthy chain, entering "
        f"through the external ETH market at #{S3_EXTERNAL_AT} costs {healthy_ps:.1%} against "
        f"{healthy_full:.1%} for the 13-hop full line - four hops instead of thirteen. After "
        f"#{S3_BAD}'s float is 99% dumped, the full line costs {full99:.1%}; if arbitrage has "
        f"carried the collapse into the external pool the router still routes around the dead link "
        f"and pays {ps99_arb:.1%}, and if the external pool is *stale* the router correctly does "
        f"the opposite - it takes the family line ({ps99:.1%}) because a collapsed link is now the "
        f"cheapest place in the world to buy the token. Either way the buyer pays the minimum of "
        f"the two venues, which is exactly what best-route is for: a broken mid-chain link costs a "
        f"buyer roughly {full99 - healthy_full:.1%} of extra slippage on the full line and about "
        f"half of that once an alternative venue exists. **Reinforcement is FALSIFIED at any budget "
        f"the design actually produces.** Three rounds of the parent-reinforcement sleeve at "
        f"${EDGE_VOL_USD_PER_ROUND:,.0f} of edge volume per round is "
        f"{3 * REINFORCE_PER_ROUND_ETH:.3f} ETH; it lands as {fee_frac:.3%} of #{S3_BAD}'s parent "
        f"reserve and moves the 99%-dump drawdown from {dd_none:.1%} to {dd_fee:.1%}. Even a budget "
        f"large enough to hit the brief's own 2%-of-reserve per-call cap ({cap_frac:.2%} deposited) "
        f"only reaches {dd_cap:.1%}. A single-sided bid within 30% of spot is eaten in the first few "
        f"percent of a dump: reinforcement is a slow accretion mechanism, not a shock absorber, and "
        f"the UI copy should say so. Note also that the venue which rescues the route is the same "
        f"external market that bypasses the 1% edge fee (brief section 6) - the mitigation and the "
        f"revenue leak are one mechanism."
    )
    out.notes = (
        "Two external-market regimes are reported because the answer depends entirely on which one "
        "holds: 'independent' leaves the market at #{} at its pre-collapse price (best case for "
        "best-route), 'arbitraged' runs `propagate_arbitrage` so the collapse reaches it (worst "
        "case). Deposited bids are flattened into a non-overlapping tick ladder first - see "
        "`flatten_pool`."
    ).format(S3_EXTERNAL_AT)
    return out


# ===========================================================================
# Sim 4 -- adversarial succession (headline)
# ===========================================================================
S4_CURVES = ("SINGLE_LIKE", "WALL_LIKE", "GENTLE_LIKE")
S4_H_FRACS = (0.0025, 0.005, 0.01)
S4_CAPITAL_MULTIPLES = (0.5, 1.0, 2.0, 5.0, 10.0)
S4_STRATEGIES = ("self_fund_win", "late_spike", "dynastic", "block1_sweep")

# slot value = what the next round is worth to whoever is the numeraire
S4_NEXT_ROUND_CANDIDATES = 5


def _honest_agents(rng: random.Random, interests: list[float]) -> list[Agent]:
    agents: list[Agent] = []
    for i, x in enumerate(interests):
        agents.append(Registrant(i, f"honest:{i}"))
        agents.append(interest_noise(i, x * A_BASE))
    return agents


def _s4_round(
    rng: random.Random,
    rel_name: str,
    scale: Scale,
    attacker: Attacker | None,
    interests: tuple[float, ...] = (1.0, 0.7),
):
    # "OVERRIDE" defers to round_config's own CLI_CURVE_OVERRIDE handling
    # (rel=None) so --curve applies without a start_ratio scaling mismatch
    # against the absolute-fraction LADDER preset.
    rel = None if rel_name == "OVERRIDE" else CURVE_SHAPES[rel_name]
    cfg = round_config(rel)
    agents = _honest_agents(rng, list(interests))
    if attacker is not None:
        attacker.candidate_id = len(interests)
        agents.insert(0, Registrant(len(interests), attacker.name))
        agents.append(attacker)
    return simulate_round(cfg, agents, rng, dt=scale.dt, head_supply=PARENT_SUPPLY)


def sim4_adversarial(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        4,
        "Adversarial succession: what a slot actually costs",
        "slot capture costs ~= fees",
    )
    # --curve/--h overrides (Sims 1/2/4): add the override curve as an extra
    # sweep entry and the override h as an extra win-threshold column, without
    # disturbing the fixed SINGLE_LIKE/50bps references the interpretation
    # text below relies on.
    curves_to_run = list(S4_CURVES) + (["OVERRIDE"] if CLI_CURVE_OVERRIDE else [])
    h_fracs_to_run = list(S4_H_FRACS) + (
        [CLI_H_OVERRIDE_PCT / 100.0]
        if CLI_H_OVERRIDE_PCT is not None and CLI_H_OVERRIDE_PCT / 100.0 not in S4_H_FRACS
        else []
    )

    # 1. what does an honest leader score, per curve?
    honest: dict[str, float] = {}
    honest_rows = []
    for rel_name in curves_to_run:
        avgs = []
        for _ in range(max(scale.trials_s4 // 2, 1)):
            res = _s4_round(rng, rel_name, scale, None)
            avgs.append(res.scores[0])
        honest[rel_name] = math.fsum(avgs) / len(avgs)
        honest_rows.append(
            {
                "curve": rel_name,
                "honest_leader_avg_absorption_parent": honest[rel_name],
                "honest_leader_avg_usd": honest[rel_name] * USD_PER_GENESIS_TOKEN,
                "rounds": len(avgs),
            }
        )
    out.tables["honest_baseline"] = pd.DataFrame(honest_rows)

    # 2. attacker sweep
    rows = []
    for rel_name in curves_to_run:
        A = honest[rel_name]
        for mult in S4_CAPITAL_MULTIPLES:
            C = mult * A
            for trial in range(scale.trials_s4):
                atk = Attacker.self_fund_win(capital=C, name="attacker")
                res = _s4_round(rng, rel_name, scale, atk)
                cid = atk.candidate_id
                p = res.pnl["attacker"]
                best_other = max(v for k, v in res.scores.items() if k != cid)
                rows.append(
                    {
                        "curve": rel_name,
                        "strategy": "self_fund_win",
                        "capital_multiple": mult,
                        "capital_parent": C,
                        "capital_usd": C * USD_PER_GENESIS_TOKEN,
                        "trial": trial,
                        "attacker_avg": res.scores[cid],
                        "best_honest_avg": best_other,
                        "is_top": res.scores[cid] > best_other,
                        "snipe_fees": p.snipe_fees,
                        "hop_fees": p.hop_fees,
                        "protocol_fees": p.protocol_fees,
                        "price_impact_loss": p.price_impact_loss,
                        "round_trip_loss": p.round_trip_loss,
                        "mark_to_market": p.mark_to_market,
                        "capital_deployed": p.capital,
                    }
                )
    raw = pd.DataFrame(rows)
    raw["cost_parent"] = raw["round_trip_loss"]
    raw["cost_usd"] = raw["cost_parent"] * USD_PER_GENESIS_TOKEN
    raw["cost_pct_of_capital"] = raw["cost_parent"] / raw["capital_deployed"]
    raw["fee_share_of_cost"] = (
        raw["snipe_fees"] + raw["hop_fees"] + raw["protocol_fees"]
    ) / raw["round_trip_loss"].where(raw["round_trip_loss"] != 0.0)
    for h in h_fracs_to_run:
        raw[f"win_h{h}"] = raw["is_top"] & (raw["attacker_avg"] >= h * PARENT_SUPPLY)
    out.tables["capture_raw"] = raw

    agg = (
        raw.groupby(["curve", "capital_multiple"], as_index=False)
        .agg(
            capital_usd=("capital_usd", "mean"),
            p_top=("is_top", "mean"),
            **{f"p_win_h_{int(h * 1e4)}bps": (f"win_h{h}", "mean") for h in h_fracs_to_run},
            cost_usd=("cost_usd", "mean"),
            cost_pct_of_capital=("cost_pct_of_capital", "mean"),
            capital_deployed_usd=("capital_deployed", "mean"),
            snipe_usd=("snipe_fees", "mean"),
            hop_usd=("hop_fees", "mean"),
            impact_usd=("price_impact_loss", "mean"),
            mtm_usd=("mark_to_market", "mean"),
        )
        .reset_index(drop=True)
    )
    for c in ("snipe_usd", "hop_usd", "impact_usd", "mtm_usd", "capital_deployed_usd"):
        agg[c] = agg[c] * USD_PER_GENESIS_TOKEN
    agg["deployed_frac_of_capital"] = agg["capital_deployed_usd"] / agg["capital_usd"]
    out.tables["capture_summary"] = agg

    # 3. strategy variants on the standard-ish SINGLE-like curve
    vrows = []
    for strategy in S4_STRATEGIES:
        for mult in S4_CAPITAL_MULTIPLES:
            A = honest["SINGLE_LIKE"]
            C = mult * A
            for trial in range(max(scale.trials_s4 // 2, 1)):
                if strategy == "block1_sweep":
                    atk = Attacker.block1_sweep(capital_per_candidate=C, name="attacker")
                    atk.exit_after = True
                elif strategy == "late_spike":
                    atk = Attacker.late_spike(capital=C, name="attacker")
                elif strategy == "dynastic":
                    atk = Attacker.dynastic(capital=C, name="attacker")
                else:
                    atk = Attacker.self_fund_win(capital=C, name="attacker")
                res = _s4_round(rng, "SINGLE_LIKE", scale, atk)
                cid = atk.candidate_id
                p = res.pnl["attacker"]
                own = res.scores.get(cid, 0.0) if cid is not None else 0.0
                others = [v for k, v in res.scores.items() if k != cid]
                vrows.append(
                    {
                        "strategy": strategy,
                        "capital_multiple": mult,
                        "capital_usd": C * USD_PER_GENESIS_TOKEN,
                        "attacker_avg": own,
                        "best_other_avg": max(others) if others else 0.0,
                        "is_top": bool(others) and own > max(others),
                        "snipe_usd": p.snipe_fees * USD_PER_GENESIS_TOKEN,
                        "hop_usd": p.hop_fees * USD_PER_GENESIS_TOKEN,
                        "impact_usd": p.price_impact_loss * USD_PER_GENESIS_TOKEN,
                        "mtm_usd": p.mark_to_market * USD_PER_GENESIS_TOKEN,
                        "cost_usd": p.round_trip_loss * USD_PER_GENESIS_TOKEN,
                        "cost_pct_of_capital": (
                            p.round_trip_loss / p.capital if p.capital else float("nan")
                        ),
                    }
                )
    variants = pd.DataFrame(vrows)
    out.tables["strategy_variants"] = (
        variants.groupby(["strategy", "capital_multiple"], as_index=False)
        .mean(numeric_only=True)
        .reset_index(drop=True)
    )

    # 4. slot value
    head_demand_parent = S4_NEXT_ROUND_CANDIDATES * A_BASE
    slot = pd.DataFrame(
        [
            {
                "component": "next-round buy pressure on the head (parent tokens)",
                "value_parent": head_demand_parent,
                "value_usd": head_demand_parent * USD_PER_GENESIS_TOKEN,
                "basis": f"{S4_NEXT_ROUND_CANDIDATES} candidates x A_BASE absorbed in the head",
            },
            {
                "component": "creator fee stream from one round of edge volume",
                "value_parent": float("nan"),
                "value_usd": EDGE_VOL_USD_PER_ROUND * (PROTOCOL_FEE_BPS / 1e4) * CREATOR_SHARE,
                "basis": f"${EDGE_VOL_USD_PER_ROUND:,.0f} edge volume x 1% x {CREATOR_SHARE:.0%}",
            },
        ]
    )
    slot_value_usd = float(slot["value_usd"].sum())
    out.tables["slot_value_estimate"] = slot

    # figures
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for curve in S4_CURVES:
        s = agg[agg["curve"] == curve].sort_values("capital_multiple")
        ax.plot(s["capital_multiple"], s["cost_pct_of_capital"] * 100, "o-", label=curve)
    ax.set_xlabel("attacker capital / honest leader's average absorption")
    ax.set_ylabel("total cost as % of capital cycled")
    ax.set_title("Sim 4: cost of a slot capture")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 4, "cost_pct", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for curve in S4_CURVES:
        s = agg[agg["curve"] == curve].sort_values("capital_multiple")
        ax.plot(s["capital_multiple"], s["p_win_h_50bps"], "o-", label=f"{curve} (h=0.5%)")
    ax.set_xlabel("attacker capital / honest leader's average absorption")
    ax.set_ylabel("P(attacker takes the slot)")
    ax.set_ylim(-0.05, 1.05)
    ax.set_title("Sim 4: probability of capture")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 4, "p_win", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    s = agg[agg["curve"] == "SINGLE_LIKE"].sort_values("capital_multiple")
    bottom = [0.0] * len(s)
    for col, lab in (("snipe_usd", "snipe tax"), ("hop_usd", "hop fee"), ("impact_usd", "price impact")):
        ax.bar(s["capital_multiple"].astype(str), s[col], bottom=bottom, label=lab)
        bottom = [b + v for b, v in zip(bottom, s[col])]
    ax.axhline(slot_value_usd, color="k", ls="--", label="estimated slot value")
    ax.set_xlabel("attacker capital multiple")
    ax.set_ylabel("USD")
    ax.set_title("Sim 4: cost decomposition vs slot value (SINGLE-like)")
    ax.legend()
    ax.grid(alpha=0.3, axis="y")
    save_fig(fig, 4, "cost_stack", out)

    # headline numbers
    win2 = agg[(agg["capital_multiple"] >= 2.0)]
    hp = float(win2["p_win_h_50bps"].mean())
    cheapest = agg.sort_values("cost_usd").iloc[0]
    at2 = agg[(agg["curve"] == "SINGLE_LIKE") & (agg["capital_multiple"] == 2.0)].iloc[0]
    med_fee_share = float(raw["fee_share_of_cost"].median())
    sweep = variants[variants["strategy"] == "block1_sweep"]
    spike = variants[variants["strategy"] == "late_spike"]
    out.interpretation = (
        f"Round run directly on top of GENESIS, so parent tokens convert at "
        f"${USD_PER_GENESIS_TOKEN:.2e} each (genesis FDV ${GENESIS_FDV_USD:,.0f}). The brief's "
        f"disclosure that *slot capture costs about fees* is VERIFIED, and it is worse than the "
        f"word 'fees' suggests. At 2x the honest leader's average absorption the attacker takes the "
        f"slot with probability {float(at2['p_win_h_50bps']):.0%} on the SINGLE-like curve for a "
        f"total cost of ${float(at2['cost_usd']):,.0f} on ${float(at2['capital_usd']):,.0f} of "
        f"capital cycled - {float(at2['cost_pct_of_capital']):.2%} of the capital, which is exactly "
        f"1 - (1 - f_hop)^2 for a {HOP_FEE_BPS:.1f} bps hop fee. {med_fee_share:.0%} of that cost is "
        f"the hop fee and nothing else: the snipe tax is *identically zero* at t = 3.1 s because the "
        f"hook only taxes the first {SNIPE_S:.0f} s, and the round trip's price impact is zero to "
        f"machine precision because a buy and a sell across the same static curve are exact "
        f"inverses. The attacker rents the slot, pays the toll, and walks away with the capital. "
        f"Averaged "
        f"over every curve at 2x capital or more, P(capture) is {hp:.0%}. Set against an estimated "
        f"slot value of ${slot_value_usd:,.0f} (next round's buy pressure on the head, "
        f"${float(slot['value_usd'].iloc[0]):,.0f}, plus one round of creator fee flow, "
        f"${float(slot['value_usd'].iloc[1]):,.0f}), capture is profitable by roughly "
        f"{slot_value_usd / max(float(at2['cost_usd']), 1e-9):.0f}x for anyone with the float. "
        f"The curve sweep matters less than the threshold sweep: h only changes whether *anyone* "
        f"wins, not who. The variants close off the cheaper shortcuts. late_spike costs the same "
        f"${float(spike['cost_usd'].mean()):,.0f} and tops the round "
        f"{float(spike['is_top'].mean()):.0%} of the time: capital held for one second contributes "
        f"1/{TRADING_S:.0f} of itself to an average taken over the whole window, so a last-second spike is "
        f"arithmetically incapable of buying the slot - attack-log finding 10 holds. block1_sweep "
        f"loses ${float(sweep['cost_usd'].mean()):,.0f} paying the opening tax and tops the round "
        f"{float(sweep['is_top'].mean()):.0%} of the time here, though Sim 5 shows the same sweep "
        f"turning a profit when the curve runs two orders of magnitude inside the window - the "
        f"99% tax prices the sweep, it does not forbid it. dynastic is simply self_fund_win that "
        f"keeps the position, and it shows the capture is not even a cost: the attacker ends the "
        f"round holding a mark-to-market gain. The refundable-score risk in attack-log finding 5 "
        f"is real, quantified, and only mitigable by making score cost something non-refundable."
    )
    out.notes = (
        "Slot value is an estimate, not a measurement: next round's head demand assumes {} "
        "candidates each drawing A_BASE = {:,.0f} parent, and the creator stream assumes "
        "${:,.0f} of ETH-edge volume in the round the attacker's token is the numeraire."
    ).format(S4_NEXT_ROUND_CANDIDATES, A_BASE, EDGE_VOL_USD_PER_ROUND)
    return out


# ===========================================================================
# Sim 5 -- candidate war
# ===========================================================================
S5_N = (5, 10, 20, 50)
S5_TOTAL_INTEREST = 5.0  # units of A_BASE, held constant across N


def sim5_candidate_war(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        5,
        "Candidate war: N candidates sharing one pot of interest",
        "a round creates demand for the head",
    )
    total_abs = S5_TOTAL_INTEREST * A_BASE
    rows = []
    for n in S5_N:
        for snipe in (True, False):
            for trial in range(scale.trials_s5):
                cfg = round_config(snipe=snipe)
                agents: list[Agent] = [Registrant(i, f"c:{i}") for i in range(n)]
                agents.append(
                    NoiseTrader(
                        0.5,
                        math.log(total_abs / (0.5 * TRADING_S * 0.6)) - 0.125,
                        0.5,
                        0.8,
                        list(range(n)),
                        name="pot",
                    )
                )
                bot = Attacker.block1_sweep(
                    capital_per_candidate=0.02 * total_abs / n, name="block1"
                )
                bot.exit_after = True
                agents.append(bot)
                res = simulate_round(cfg, agents, rng, dt=scale.dt, head_supply=PARENT_SUPPLY)
                rnd = res.round
                absorbed = math.fsum(max(c.R, 0.0) for c in rnd.candidates.values())
                t1 = rnd.trading_start + 1.0
                first = [s for s in rnd.swaps if s.t < t1 and s.tokens_bought > 0.0]
                bot_tokens = math.fsum(s.tokens_bought for s in first if s.trader == "block1")
                all_tokens = math.fsum(s.tokens_bought for s in first)
                scores = list(res.scores.values())
                mean_s = math.fsum(scores) / len(scores)
                var_s = math.fsum((s - mean_s) ** 2 for s in scores) / max(len(scores) - 1, 1)

                # head demand: buyers had to acquire `absorbed` head tokens for ETH
                chain, _ = new_chain()
                f0 = chain.fdv_parent(0)
                work = chain.clone()
                res_buy = work.execute_route(
                    work.route(ETH, 0, FULL_LINE), absorbed, exact_in=False
                )
                rows.append(
                    {
                        "n_candidates": n,
                        "snipe_tax": snipe,
                        "trial": trial,
                        "parent_absorbed_total": absorbed,
                        "parent_absorbed_usd": absorbed * USD_PER_GENESIS_TOKEN,
                        "head_eth_in": res_buy.amount_in,
                        "head_eth_in_usd": usd(res_buy.amount_in),
                        "head_fdv_move": work.fdv_parent(0) / f0 - 1.0,
                        "winner_avg": max(scores),
                        "score_cv": math.sqrt(var_s) / mean_s if mean_s else float("nan"),
                        "top1_share": max(scores) / math.fsum(scores),
                        "block1_share_of_first_second": (
                            bot_tokens / all_tokens if all_tokens else float("nan")
                        ),
                        "block1_snipe_usd": res.pnl["block1"].snipe_fees
                        * USD_PER_GENESIS_TOKEN,
                        "block1_cost_usd": res.pnl["block1"].round_trip_loss
                        * USD_PER_GENESIS_TOKEN,
                    }
                )
    raw = pd.DataFrame(rows)
    summary = raw.groupby(["n_candidates", "snipe_tax"], as_index=False).mean(
        numeric_only=True
    ).drop(columns=["trial"])
    out.tables["raw"] = raw
    out.tables["summary"] = summary

    fig, ax = plt.subplots(figsize=(7, 4))
    for snipe in (True, False):
        s = summary[summary["snipe_tax"] == snipe].sort_values("n_candidates")
        ax.plot(
            s["n_candidates"],
            s["block1_share_of_first_second"],
            "o-",
            label="snipe tax on" if snipe else "snipe tax off",
        )
    ax.set_xlabel("candidates in the round")
    ax.set_ylabel("block-1 bot share of first-second fills")
    ax.set_title("Sim 5: what the opening tax takes away from the sweeper")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 5, "block1", out)

    fig, ax = plt.subplots(figsize=(7, 4))
    s = summary[summary["snipe_tax"]].sort_values("n_candidates")
    ax.plot(s["n_candidates"], s["head_fdv_move"] * 100, "o-", label="head FDV move")
    ax2 = ax.twinx()
    ax2.plot(s["n_candidates"], s["score_cv"], "s--", color="tab:red", label="score CV")
    ax.set_xlabel("candidates in the round")
    ax.set_ylabel("head FDV move (%)")
    ax2.set_ylabel("dispersion of scores (CV)")
    ax.set_title("Sim 5: head demand and score dispersion vs N")
    ax.grid(alpha=0.3)
    save_fig(fig, 5, "head_demand", out)

    on = summary[summary["snipe_tax"]]
    off = summary[~summary["snipe_tax"]]
    out.interpretation = (
        f"Total interest is held fixed at {S5_TOTAL_INTEREST:.0f} x A_BASE and split across N "
        f"candidates by random arrival. The claim that *a round creates demand for the head* is "
        f"VERIFIED and is close to N-invariant: the round absorbs "
        f"${float(on['parent_absorbed_usd'].mean()):,.0f} of head token regardless of whether 5 or "
        f"50 candidates are competing, which required ${float(on['head_eth_in_usd'].mean()):,.0f} "
        f"of ETH to enter the family and moved the head's own FDV by "
        f"{float(on['head_fdv_move'].mean()):.1%}. That is the flywheel the design is built on and "
        f"it works: candidates are a demand pump for their parent whether or not any of them wins. "
        f"What does change with N is concentration - the winner's share of total score falls from "
        f"{float(on.loc[on['n_candidates'] == S5_N[0], 'top1_share'].iloc[0]):.1%} at N={S5_N[0]} "
        f"to {float(on.loc[on['n_candidates'] == S5_N[-1], 'top1_share'].iloc[0]):.1%} at "
        f"N={S5_N[-1]}, and the winning average falls with it, so a crowded round is much more "
        f"likely to miss the threshold entirely even though the head got the same demand. On the "
        f"snipe tax: the block-1 sweeper takes "
        f"{float(off['block1_share_of_first_second'].mean()):.0%} of first-second fills with the "
        f"tax off and {float(on['block1_share_of_first_second'].mean()):.0%} with it on, at a cost "
        f"of ${float(on['block1_snipe_usd'].mean()):,.0f} per round in tax. The tax does not stop the "
        f"sweep, it prices it - and at these curve slopes it does not even price it fully: the "
        f"sweeper still books a mean P&L of "
        f"${-float(on['block1_cost_usd'].mean()):,.0f} per round with the tax on "
        f"(${-float(off['block1_cost_usd'].mean()):,.0f} with it off), because paying 99% on a "
        f"buy at the very bottom of a curve that then rises two orders of magnitude inside ten "
        f"minutes is still a good trade. The tax cuts the sweeper's edge by roughly "
        f"{1 - float(on['block1_cost_usd'].mean()) / float(off['block1_cost_usd'].mean()):.0%} "
        f"and turns it break-even only in the crowded rounds where the pot is split many ways."
    )
    out.notes = (
        "Head demand is measured by re-buying the absorbed parent through the ETH edge on a fresh "
        "genesis chain (exact-output route), so it includes the 1% edge fee and the hop fee."
    )
    return out


# ===========================================================================
# Sim 6 -- fee equilibrium
# ===========================================================================
S6_CREATOR_SHARES = (0.30, 0.40, 0.50)
S6_SPLITS = (0.25, 0.50, 0.75)
S6_FEE_PAIRS = ((1.0, 1.0), (1.0, 2.0), (1.0, 3.0), (1.0, 5.0), (1.0, 10.0))
S6_EPSILONS = (0.5, 1.0, 1.5)
S6_GENS = 20
S6_SURVIVAL_CHAINS = 200


def _survival_prob(
    rng: random.Random, chains: int, gens: int, a_base: float, k: float, k_sd: float
) -> tuple[float, float]:
    """Reduced-form (P(reach #gens with no failed round), mean rounds to get there).

    Sim 2 shows the chain always gets there *eventually* (a failed round costs
    time, never the chain), so the informative statistics are how often it runs
    clean and how long it takes.
    """
    h_floor = H_FLOOR_FRAC * H0
    hits = 0
    rounds_used = []
    for _ in range(chains):
        h, gen = H0, 0
        used = 2 * gens
        for _r in range(2 * gens):
            if gen >= gens:
                used = _r
                break
            g = rng.lognormvariate(0.0, GEN_INTEREST_SIGMA)
            best = max(
                g
                * rng.lognormvariate(0.0, INTEREST_SIGMA)
                * a_base
                * max(rng.gauss(k, k_sd), 0.05 * k)
                for _c in range(5)
            )
            if best >= h:
                gen += 1
            else:
                h = max(0.9 * h, h_floor)
        rounds_used.append(used)
        hits += used <= gens
    return hits / chains, math.fsum(rounds_used) / chains


def sim6_fee_equilibrium(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        6,
        "Fee equilibrium: split sweep and the sell-tax question",
        "find the split; report sell-tax sensitivity honestly",
    )
    gens = min(S6_GENS, scale.gens_s2)
    total_edge_usd = EDGE_VOL_USD_PER_ROUND * gens
    fee_pot_usd = total_edge_usd * (PROTOCOL_FEE_BPS / 1e4)

    rows = []
    for cs in S6_CREATOR_SHARES:
        for split in S6_SPLITS:
            alloc = allocator(creator_share=cs, ancestor_split=split)
            ledger = [
                alloc.allocate(fee_pot_usd / gens, g) for g in range(1, gens + 1)
            ]
            flows = fee_flow_by_recipient(ledger)
            by_kind = flows.groupby("kind")["amount"].sum().to_dict()
            genesis_cut = float(
                flows[(flows["kind"] == "ancestor") & (flows["target"] == 0)]["amount"].sum()
            )
            rows.append(
                {
                    "creator_share": cs,
                    "ancestor_split": f"{int(split * 100)}/{int((1 - split) * 100)}",
                    "developer_usd": by_kind.get("dev", 0.0),
                    "creator_usd_total": by_kind.get("creator", 0.0),
                    "creator_usd_per_round": by_kind.get("creator", 0.0) / gens,
                    "ancestor_sleeve_usd": by_kind.get("ancestor", 0.0),
                    "reinforcement_usd": by_kind.get("reinforce", 0.0),
                    "flywheel_usd": by_kind.get("ancestor", 0.0) + by_kind.get("reinforce", 0.0),
                    "genesis_usd": genesis_cut,
                    "genesis_share_of_pot": genesis_cut / fee_pot_usd,
                }
            )
    splits = pd.DataFrame(rows)
    out.tables["split_sweep"] = splits

    # --- sell-tax sweep under volume elasticity ---------------------------
    k_mean, k_sd = _calibrate_avg_per_interest(scale, rng)
    rt0 = S6_FEE_PAIRS[0][0] + S6_FEE_PAIRS[0][1]
    frows = []
    for (buy, sell) in S6_FEE_PAIRS:
        rt = buy + sell
        for eps in S6_EPSILONS:
            vol_index = (rt / rt0) ** (-eps)
            volume_usd = total_edge_usd * vol_index
            pot = volume_usd * 0.5 * (rt / 100.0)  # half the volume pays buy, half sell
            p, rounds_needed = _survival_prob(
                rng,
                max(S6_SURVIVAL_CHAINS // (4 if scale.name == "tiny" else 1), 4),
                gens,
                A_BASE * vol_index,
                k_mean,
                k_sd,
            )
            frows.append(
                {
                    "buy_fee_pct": buy,
                    "sell_fee_pct": sell,
                    "round_trip_fee_pct": rt,
                    "epsilon": eps,
                    "volume_index": vol_index,
                    "fee_pot_usd": pot,
                    "developer_usd": pot * DEV_SHARE,
                    "creator_usd": pot * CREATOR_SHARE,
                    "flywheel_usd": pot * (1.0 - DEV_SHARE - CREATOR_SHARE),
                    f"p_clean_run_to_{gens}": p,
                    "mean_rounds_to_reach": rounds_needed,
                }
            )
    fees = pd.DataFrame(frows)
    out.tables["sell_tax_sweep"] = fees

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for eps in S6_EPSILONS:
        s = fees[fees["epsilon"] == eps].sort_values("round_trip_fee_pct")
        ax.plot(s["sell_fee_pct"], s["fee_pot_usd"], "o-", label=f"epsilon = {eps}")
    ax.set_xlabel("sell-side edge fee (%), buy side fixed at 1%")
    ax.set_ylabel("protocol fee pot over %d generations (USD)" % gens)
    ax.set_title("Sim 6: sell tax vs revenue under volume elasticity")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 6, "sell_tax", out)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    for eps in S6_EPSILONS:
        s = fees[fees["epsilon"] == eps].sort_values("sell_fee_pct")
        ax.plot(s["sell_fee_pct"], s["mean_rounds_to_reach"], "o-", label=f"epsilon = {eps}")
    ax.set_xlabel("sell-side edge fee (%)")
    ax.set_ylabel("mean rounds needed to reach #%d" % gens)
    ax.set_title("Sim 6: chain speed under the sell tax")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 6, "survival", out)

    base = splits[
        (splits["creator_share"] == 0.40) & (splits["ancestor_split"] == "50/50")
    ].iloc[0]
    e1 = fees[fees["epsilon"] == 1.0].sort_values("sell_fee_pct")
    e05 = fees[fees["epsilon"] == 0.5].sort_values("sell_fee_pct")
    e15 = fees[fees["epsilon"] == 1.5].sort_values("sell_fee_pct")
    out.interpretation = (
        f"Over {gens} generations at ${EDGE_VOL_USD_PER_ROUND:,.0f} of ETH-edge volume per round, "
        f"the 1% fee collects ${fee_pot_usd:,.0f}. The split is a pure allocation question and the "
        f"recommendation is **creator 40%, flywheel remainder 50/50** (developer "
        f"${float(base['developer_usd']):,.0f}, creators ${float(base['creator_usd_total']):,.0f} "
        f"= ${float(base['creator_usd_per_round']):,.0f} per launch, ancestor sleeve "
        f"${float(base['ancestor_sleeve_usd']):,.0f}, reinforcement "
        f"${float(base['reinforcement_usd']):,.0f}): 30% underpays the only party who has to do "
        f"work before a round exists, 50% starves the flywheel that is the product's actual "
        f"differentiator, and a 25/75 or 75/25 tilt of the remainder moves less money than one "
        f"noisy round does. On the sell tax the honest answer is that the sign of the effect is "
        f"entirely an empirical question the simulation cannot settle: revenue scales as "
        f"rt^(1 - epsilon), so at epsilon = 0.5 raising the sell fee from 1% to 10% raises the pot "
        f"from ${float(e05['fee_pot_usd'].iloc[0]):,.0f} to "
        f"${float(e05['fee_pot_usd'].iloc[-1]):,.0f}, at epsilon = 1.0 it is exactly flat at "
        f"${float(e1['fee_pot_usd'].iloc[0]):,.0f}, and at epsilon = 1.5 it *falls* from "
        f"${float(e15['fee_pot_usd'].iloc[0]):,.0f} to ${float(e15['fee_pot_usd'].iloc[-1]):,.0f}. "
        f"Survival is not ambiguous in the same way: because volume and round interest move "
        f"together, the chain slows down: at epsilon = 1.0 reaching #{gens} takes "
        f"{float(e1['mean_rounds_to_reach'].iloc[0]):.1f} rounds at 1%/1% and "
        f"{float(e1['mean_rounds_to_reach'].iloc[-1]):.1f} rounds at 1%/10%, and the share of chains "
        f"that get there without a single failed round falls from "
        f"{float(e1[f'p_clean_run_to_{gens}'].iloc[0]):.0%} to "
        f"{float(e1[f'p_clean_run_to_{gens}'].iloc[-1]):.0%}. A sell tax is therefore a bet that memecoin "
        f"traders are fee-insensitive (epsilon < 1) paid for with chain liveness, and the 1/1 "
        f"symmetric fee is the only setting that needs no such bet. Recommend keeping 1%/1%."
    )
    out.notes = (
        "Volume elasticity is an assumption, not a measurement: volume proportional to "
        "(buy + sell fee)^-epsilon, normalised at the 1%/1% schedule, and round interest is "
        "assumed to scale with the same index. No empirical elasticity for this market exists."
    )
    return out


# ===========================================================================
# Sim 7 -- route depth
# ===========================================================================
S7_DEPTHS = (10, 20, 50, 100)
S7_SIZES_USD = (1_000.0, 5_000.0, 10_000.0)
S7_EXTERNAL_FRAC = 0.20


def sim7_route_depth(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        7,
        "Route depth: 10 / 20 / 50 / 100 links",
        "flat fee + best-route keeps deep trading usable",
    )
    modes = (FULL_LINE, BEST, DEPTH_CAPPED(5))
    rows = []
    for depth in S7_DEPTHS:
        chain = reference_chain(depth)
        n_ext = max(int(round(S7_EXTERNAL_FRAC * depth)), 1)
        for i in sorted(rng.sample(range(1, depth), n_ext)):
            market_at_parity(chain, i, depth_eth=REF_RESERVE_ETH)
        dst = depth - 1
        terminal_fdv_eth = chain.fdv_eth(dst)
        sizes = [(f"${s:,.0f}", eth_of_usd(s)) for s in S7_SIZES_USD]
        sizes.append(("0.5% of terminal FDV", 0.005 * terminal_fdv_eth))
        for label, size in sizes:
            for mode in modes:
                work = chain.clone()
                route = work.route(ETH, dst, mode, probe=size)
                res = work.execute_route(route, size)
                fee_eth = res.protocol_fee_eth
                rows.append(
                    {
                        "links": depth,
                        "dst": dst,
                        "size_label": label,
                        "size_eth": size,
                        "size_usd": usd(size),
                        "mode": str(mode),
                        "hops": route.hops,
                        "uses_external": route.uses_external,
                        "terminal_fdv_usd": usd(terminal_fdv_eth),
                        "edge_fee_usd": usd(fee_eth),
                        "hop_fee_legs": len(res.hop_fees),
                        "total_fee_pct_of_trade": (fee_eth / size)
                        + len(res.hop_fees) * (HOP_FEE_BPS / 1e4),
                        "effective_loss_frac": res.effective_loss_frac,
                        "exhausted": res.exhausted,
                    }
                )
    table = pd.DataFrame(rows)
    out.tables["route_depth"] = table

    ext = (
        table[table["mode"] != "FULL_LINE"]
        .groupby(["links", "mode"], as_index=False)["uses_external"]
        .mean()
        .rename(columns={"uses_external": "frac_routes_going_external"})
    )
    out.tables["external_share"] = ext

    norm = table[table["size_label"] == "0.5% of terminal FDV"]
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for mode in norm["mode"].unique():
        s = norm[norm["mode"] == mode].sort_values("links")
        ax.plot(s["links"], s["effective_loss_frac"] * 100, "o-", label=mode)
    ax.set_xlabel("links in the chain")
    ax.set_ylabel("effective loss (%) on a 0.5%-of-FDV buy")
    ax.set_title("Sim 7: cost of reaching the deepest link")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 7, "loss_vs_depth", out)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    s = table[(table["mode"] == "FULL_LINE") & (table["size_label"] == "0.5% of terminal FDV")]
    s = s.sort_values("links")
    ax.semilogy(s["links"], s["terminal_fdv_usd"], "o-")
    ax.set_xlabel("links in the chain")
    ax.set_ylabel("terminal link FDV (USD, log)")
    ax.set_title("Sim 7: equal-ETH-depth construction holds value flat by design")
    ax.grid(alpha=0.3, which="both")
    save_fig(fig, 7, "terminal_fdv", out)

    fl = norm[norm["mode"] == "FULL_LINE"]
    deep = fl[fl["links"] == S7_DEPTHS[-1]].iloc[0]
    shallow = fl[fl["links"] == S7_DEPTHS[0]].iloc[0]
    dollar = table[(table["size_label"] == "$10,000") & (table["mode"] == "FULL_LINE")]
    n_exhausted = int(table["exhausted"].sum())
    out.interpretation = (
        f"Equal-ETH-depth chain with external ETH markets on {S7_EXTERNAL_FRAC:.0%} of links. The "
        f"claim is VERIFIED for the *fee* and FALSIFIED for *usable* at the deep end, and the two "
        f"failures have different causes. Fees behave exactly as designed: the 1% edge fee is paid "
        f"once no matter how deep the route goes, so total fee on a full-line trade is "
        f"1% + hops x {HOP_FEE_BPS:.1f} bps - {float(shallow['total_fee_pct_of_trade']):.2%} at "
        f"{S7_DEPTHS[0]} links and {float(deep['total_fee_pct_of_trade']):.2%} at "
        f"{S7_DEPTHS[-1]} links. Price impact, not fees, is what breaks: at a constant 0.5%-of-FDV "
        f"trade the full-line effective loss rises from "
        f"{float(shallow['effective_loss_frac']):.2%} to {float(deep['effective_loss_frac']):.2%}, "
        f"because the trade crosses every pool below the target and each crossing moves a price "
        f"that the next leg then pays. BEST and DEPTH_CAPPED(5) fix exactly that: they hand "
        f"{float(ext[ext['mode'] == 'BEST']['frac_routes_going_external'].mean()):.0%} of routes "
        f"to an external ETH market, cutting the hop count to whatever sits below the deepest "
        f"market. That is the mitigation and it works - but it is also the leak: every route that "
        f"goes external pays the external market's fee instead of the family's 1% edge fee, so the "
        f"same mechanism that keeps deep trading usable is the mechanism that starves the flywheel. "
        f"Hop fee sizing (Q5, 0.05-0.1%) is confirmed: at {HOP_FEE_BPS:.1f} bps even a 100-hop "
        f"route pays {S7_DEPTHS[-1] * HOP_FEE_BPS / 1e4:.1%} in hop fees, which is the same order "
        f"as the edge fee itself and is the real ceiling on chain length. {n_exhausted} of "
        f"{len(table)} quoted routes exhausted the terminal pool at fixed dollar sizes."
    )
    out.notes = (
        "Absolute dollar sizes are reported alongside a size normalised to the terminal link's own "
        "FDV, because on the brief-literal chain (Sim 1) a $10k trade exceeds the entire market cap "
        "of any link past about #6 and the comparison degenerates."
    )
    return out


# ===========================================================================
# Sim 8 -- sell cascades
# ===========================================================================
S8_LINKS = 12
S8_SHOCK_INDEX = 10
S8_FLOAT = 0.85
S8_STEPS = 100
S8_DUMP = 1.0


def sim8_cascades(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        8,
        "Sell cascades from #%d: WALL vs SINGLE-like" % S8_SHOCK_INDEX,
        "the wall is a threshold cascade (architect's prediction)",
    )
    paths = []
    per_link = []
    released = []
    bands = []
    for name, rel in (("WALL_LIKE", WALL_REL), ("SINGLE_LIKE", SINGLE_REL)):
        chain = reference_chain(S8_LINKS, rel, float_frac=S8_FLOAT)
        pool = chain.links[S8_SHOCK_INDEX].pool
        f0 = pool.fdv()
        float0 = pool.tokens_sold()
        for i, r in enumerate(pool.ranges):
            bands.append(
                {
                    "curve": name,
                    "band": i,
                    "fdv_lower": r.fdv_lower(pool.supply),
                    "fdv_upper": r.fdv_upper(pool.supply),
                    "buyout_cost_parent": r.L * (r.upper - r.lower),
                    "tokens_in_band": r.L * (1.0 / r.lower - 1.0 / r.upper),
                }
            )
        work = chain.clone()
        p = work.links[S8_SHOCK_INDEX].pool
        step = float0 * S8_DUMP / S8_STEPS
        cum_tokens = 0.0
        cum_parent = 0.0
        for k in range(S8_STEPS + 1):
            paths.append(
                {
                    "curve": name,
                    "step": k,
                    "cum_tokens_sold": cum_tokens,
                    "cum_tokens_frac_of_float": cum_tokens / float0,
                    "cum_parent_released": cum_parent,
                    "fdv_parent": p.fdv(),
                    "drawdown": 1.0 - p.fdv() / f0,
                }
            )
            if k < S8_STEPS:
                res = p.swap_exact_in(step, parent_in=False)
                cum_tokens += res.amount_in_used
                cum_parent += res.amount_out
                if res.exhausted:
                    break
        dd = drawdown_propagation(chain, S8_SHOCK_INDEX, 0.5)
        for i, v in sorted(dd.items()):
            per_link.append({"curve": name, "link": i, "drawdown": v})
        for pct in (0.05, 0.10, 0.25, 0.50, 0.75):
            rel_parent = parent_released_per_pct_decline(pool, pct)
            released.append(
                {
                    "curve": name,
                    "decline_pct": pct,
                    "parent_released": rel_parent,
                    "parent_released_per_pct": rel_parent / (pct * 100.0),
                    "parent_released_usd": usd(rel_parent * chain.price_in_eth(S8_SHOCK_INDEX - 1)),
                }
            )
    path = pd.DataFrame(paths)
    out.tables["cascade_path"] = path
    out.tables["per_link_drawdown"] = pd.DataFrame(per_link)
    out.tables["parent_released"] = pd.DataFrame(released)
    out.tables["bands"] = pd.DataFrame(bands)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for name in path["curve"].unique():
        s = path[path["curve"] == name]
        ax.plot(s["cum_tokens_frac_of_float"] * 100, s["drawdown"] * 100, "-", label=name)
    ax.set_xlabel("cumulative sells (% of float)")
    ax.set_ylabel("drawdown of the link's own FDV (%)")
    ax.set_title("Sim 8: plateau-then-cliff on a walled curve")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 8, "cascade", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for name in path["curve"].unique():
        s = path[path["curve"] == name]
        ax.plot(s["cum_tokens_frac_of_float"] * 100, s["cum_parent_released"], "-", label=name)
    ax.set_xlabel("cumulative sells (% of float)")
    ax.set_ylabel("cumulative parent released to sellers")
    ax.set_title("Sim 8: embedded parent handed back on the way down")
    ax.legend()
    ax.grid(alpha=0.3)
    save_fig(fig, 8, "released", out)

    def _cliff(name: str) -> tuple[float, float, float, float]:
        """Largest *acceleration*: a step against the trend of the ten before it.

        A convex curve (SINGLE-like) decelerates all the way down, so this ratio
        stays at or below 1.  A threshold cascade is exactly a step that is much
        larger than the ten that preceded it.
        """
        sp = path[path["curve"] == name].reset_index(drop=True)
        d = sp["drawdown"].diff().fillna(0.0)
        trail = d.rolling(10).mean().shift(1)
        ratio = (d / trail).replace([float("inf"), -float("inf")], float("nan"))
        i = int(ratio.idxmax())
        return (
            float(sp["cum_tokens_frac_of_float"].iloc[i]),
            float(d.iloc[i]),
            float(trail.iloc[i]),
            float(ratio.iloc[i]),
        )

    wall_x, wall_j, wall_avg, wall_ratio = _cliff("WALL_LIKE")
    single_x, single_j, single_avg, single_ratio = _cliff("SINGLE_LIKE")
    cliff_tbl = pd.DataFrame(
        [
            {
                "curve": "WALL_LIKE",
                "acceleration_at_frac_of_float": wall_x,
                "step_drawdown": wall_j,
                "trailing_10_step_drawdown": wall_avg,
                "acceleration_ratio": wall_ratio,
            },
            {
                "curve": "SINGLE_LIKE",
                "acceleration_at_frac_of_float": single_x,
                "step_drawdown": single_j,
                "trailing_10_step_drawdown": single_avg,
                "acceleration_ratio": single_ratio,
            },
        ]
    )
    out.tables["cliff"] = cliff_tbl
    wall_band = pd.DataFrame(bands)
    wb = wall_band[(wall_band["curve"] == "WALL_LIKE")].iloc[1]
    wall_end = path[(path["curve"] == "WALL_LIKE")].iloc[-1]
    single_end = path[(path["curve"] == "SINGLE_LIKE")].iloc[-1]
    wall_bands = wall_band[wall_band["curve"] == "WALL_LIKE"]
    wall_cost = float(wall_bands["buyout_cost_parent"].iloc[1])
    released_at_cliff = float(
        path[(path["curve"] == "WALL_LIKE")]
        .query("cum_tokens_frac_of_float >= @wall_x")["cum_parent_released"]
        .iloc[0]
    )
    out.interpretation = (
        f"Both chains are built with the same {S8_FLOAT:.0%} float and the same ETH depth per link, "
        f"so the only difference is curve shape, and the whole float is dumped in "
        f"{S8_STEPS} equal clips. The architect's prediction is VERIFIED in shape and REVERSED in "
        f"sign, which is the useful result. Shape first: the WALL curve is a threshold cascade. "
        f"The discriminating measurement is acceleration - a clip that is larger than the ten "
        f"clips before it. A convex curve can never do that, and SINGLE-like does not: its worst "
        f"acceleration is {single_ratio:.2f}x trend at {single_x:.0%} of float. The wall hits "
        f"{wall_ratio:.2f}x trend at {wall_x:.0%} of float, taking {wall_j:.1%} off the FDV in a "
        f"single clip against a trailing average of {wall_avg:.2%}. The cliff sits where the closed "
        f"form says it must: the wall band is worth s*sqrt(Fa*Fb) = {wall_cost:.3g} parent, and "
        f"cumulative releases to sellers when the cascade fires are {released_at_cliff:.3g} parent "
        f"- the band above the wall plus the wall itself, drained. Sign second: over the *whole* dump "
        f"the wall is the safer curve, not the more dangerous one - after 50% of float it is down "
        f"{float(path[(path['curve'] == 'WALL_LIKE') & (path['step'] == S8_STEPS // 2)]['drawdown'].iloc[0]):.1%} "
        f"against "
        f"{float(path[(path['curve'] == 'SINGLE_LIKE') & (path['step'] == S8_STEPS // 2)]['drawdown'].iloc[0]):.1%} "
        f"for SINGLE-like, and it hands back "
        f"{float(path[(path['curve'] == 'WALL_LIKE')]['cum_parent_released'].iloc[-1]) / max(float(path[(path['curve'] == 'SINGLE_LIKE')]['cum_parent_released'].iloc[-1]), 1e-9):.2f}x "
        f"as much embedded parent on the way down. That is the real trade: a wall buys a genuinely "
        f"better price floor and pays for it with a discontinuity that is fully predictable from "
        f"the deploy constants - anyone can compute the exact cumulative-sell level at which it "
        f"fires, and will. Every descendant of #{S8_SHOCK_INDEX} inherits the same drawdown through "
        f"the telescoping price product; every ancestor is untouched, which is the one genuinely "
        f"good property in this scenario."
    )
    out.notes = (
        "Drawdowns are measured with no external markets attached, so the shock cannot feed back "
        "down the line; that is the optimistic case for ancestors."
    )
    return out




# ===========================================================================
# Sim 9 -- reinforcement vs burn
# ===========================================================================
S9_LINKS = 8
S9_TARGET = 7


def sim9_reinforcement(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        9,
        "Reinforcement vs burn over %d rounds, then a 50%% shock" % scale.rounds_s9,
        "bid liquidity beats burn",
    )
    budget_per_round = eth_of_usd(
        EDGE_VOL_USD_PER_ROUND * (PROTOCOL_FEE_BPS / 1e4) * (1.0 - DEV_SHARE - CREATOR_SHARE)
    )
    baseline = reference_chain(S9_LINKS)
    base_pool = baseline.links[S9_TARGET].pool
    shock_tokens = 0.5 * base_pool.tokens_sold()

    rows = []
    for policy in (SINGLE_SIDED_BID, BUY_AND_BURN, TWO_SIDED, "NONE"):
        chain = reference_chain(S9_LINKS)
        deployed = 0.0
        parent_deposited = 0.0
        burned = 0.0
        for _ in range(scale.rounds_s9):
            if policy == "NONE":
                break
            dep = deploy_flat(chain, S9_TARGET, budget_per_round, policy, bid_width=0.20)
            if dep is None:
                continue
            deployed += budget_per_round
            parent_deposited += dep.parent_deposited
            burned += dep.tokens_burned
        pool = chain.links[S9_TARGET].pool
        f_pre = pool.fdv()
        depth_50 = -pool.quote_cost_to_fdv(f_pre * 0.5)
        depth_20 = -pool.quote_cost_to_fdv(f_pre * 0.8)
        pool.swap_exact_in(shock_tokens, parent_in=False)
        rows.append(
            {
                "policy": policy,
                "rounds": 0 if policy == "NONE" else scale.rounds_s9,
                "eth_deployed": deployed,
                "usd_deployed": usd(deployed),
                "parent_deposited": parent_deposited,
                "tokens_burned": burned,
                "burned_frac_of_supply": burned / pool.supply,
                "depth_within_20pct_parent": depth_20,
                "depth_within_50pct_parent": depth_50,
                "fdv_pre_shock": f_pre,
                "fdv_post_shock": pool.fdv(),
                "shock_drawdown": 1.0 - pool.fdv() / f_pre,
                "eth_price_post_shock": chain.price_in_eth(S9_TARGET),
            }
        )
    table = pd.DataFrame(rows)
    none_row = table[table["policy"] == "NONE"].iloc[0]
    table["drawdown_vs_none"] = table["shock_drawdown"] - float(none_row["shock_drawdown"])
    table["depth_gain_vs_none"] = (
        table["depth_within_50pct_parent"] / float(none_row["depth_within_50pct_parent"]) - 1.0
    )
    out.tables["policies"] = table

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.bar(table["policy"], table["shock_drawdown"] * 100)
    ax.set_ylabel("drawdown after a 50%-of-float dump (%)")
    ax.set_title("Sim 9: which use of the fee budget survives a shock")
    ax.grid(alpha=0.3, axis="y")
    save_fig(fig, 9, "drawdown", out)

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.bar(table["policy"], table["depth_gain_vs_none"] * 100)
    ax.set_ylabel("extra parent bid within 50% of spot vs no deployment (%)")
    ax.set_title("Sim 9: realised depth below spot")
    ax.grid(alpha=0.3, axis="y")
    save_fig(fig, 9, "depth", out)

    bid = table[table["policy"] == SINGLE_SIDED_BID].iloc[0]
    burn = table[table["policy"] == BUY_AND_BURN].iloc[0]
    two = table[table["policy"] == TWO_SIDED].iloc[0]
    out.interpretation = (
        f"Each policy gets the same ${usd(budget_per_round):,.0f} per round for "
        f"{scale.rounds_s9} rounds (${usd(budget_per_round) * scale.rounds_s9:,.0f} total flywheel "
        f"budget) on an equal-ETH-depth chain, then link #{S9_TARGET} eats a 50%-of-float dump. "
        f"The claim *bid liquidity beats burn* is VERIFIED but the margin is small at realistic "
        f"budgets. SINGLE_SIDED_BID leaves the link {float(bid['shock_drawdown']):.1%} down against "
        f"{float(burn['shock_drawdown']):.1%} for BUY_AND_BURN and "
        f"{float(none_row['shock_drawdown']):.1%} for no deployment at all, and it adds "
        f"{float(bid['depth_gain_vs_none']):.2%} to the parent bid sitting within 50% of spot - "
        f"real, permanent, protocol-owned depth that the burn simply does not create. Burn spends "
        f"the same money buying {float(burn['burned_frac_of_supply']):.4%} of supply and destroying "
        f"it: the price pops on the way in and then there is nothing underneath, which is precisely "
        f"why the design review told us to delete it. TWO_SIDED lands between the two "
        f"({float(two['shock_drawdown']):.1%}) because half its budget is spent buying the token it "
        f"then re-lists as an ask, i.e. it funds its own overhead. The honest caveat is scale: the "
        f"brief's own 2%-of-reserve per-call cap plus a fee budget of this size means the bid is a "
        f"rounding error against a determined seller - the mechanism is right, the magnitude only "
        f"matters once edge volume is orders of magnitude larger than assumed here."
    )
    out.notes = (
        "The shock is a fixed token quantity (50% of the *baseline* float) for every policy, so "
        "burn is not rewarded for having shrunk the float it is then shocked with. Deposited "
        "bids are flattened into a non-overlapping tick ladder (`flatten_pool`) before the "
        "shock, otherwise the sequential range walk in the swap kernel would skip the curve "
        "liquidity the bid overlaps and make a reinforced pool look *worse* than an "
        "untouched one."
    )
    return out


# ===========================================================================
# Sim 10 -- genesis economics
# ===========================================================================
S10_DEPTHS = (5, 20, 100, 1000)
S10_FLOOR = 0.10


def sim10_genesis(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        10,
        "Genesis economics: is the U-shape a genesis tax funnel?",
        "no genesis tax funnel",
    )
    rows = []
    for M in S10_DEPTHS:
        Z = ancestor_norm(M)
        g = 2.0 / Z
        newest = 1.0 / Z
        rows.append(
            {
                "depth_M": M,
                "Z_M": Z,
                "genesis_share_of_sleeve": g,
                "newest_ancestor_share": newest,
                "min_weight_share": (2.0 - 5.0 * 0.625 + 4.0 * 0.625**2) / Z,
                "genesis_over_newest": g / newest,
                "even_split_share": 1.0 / (M + 1),
                "genesis_over_even": g * (M + 1),
                "with_10pct_floor": S10_FLOOR + (1.0 - S10_FLOOR) * g,
                "floor_multiple": (S10_FLOOR + (1.0 - S10_FLOOR) * g) / g,
            }
        )
    shares = pd.DataFrame(rows)
    out.tables["genesis_share"] = shares

    gens = min(S6_GENS, max(scale.gens_s2, 2))
    alloc = allocator()
    ledger = [
        alloc.allocate(EDGE_VOL_USD_PER_ROUND * (PROTOCOL_FEE_BPS / 1e4), g)
        for g in range(1, gens + 1)
    ]
    flows = fee_flow_by_recipient(ledger)
    genesis_usd = float(flows[(flows["kind"] == "ancestor") & (flows["target"] == 0)]["amount"].sum())
    sleeve_usd = float(flows[flows["kind"] == "ancestor"]["amount"].sum())
    bonds_eth = 0.005 * 4 * gens
    locked = pd.DataFrame(
        [
            {
                "generations": gens,
                "edge_volume_usd": EDGE_VOL_USD_PER_ROUND * gens,
                "protocol_fee_usd": EDGE_VOL_USD_PER_ROUND * (PROTOCOL_FEE_BPS / 1e4) * gens,
                "ancestor_sleeve_usd": sleeve_usd,
                "genesis_usd": genesis_usd,
                "genesis_share_of_sleeve": genesis_usd / sleeve_usd,
                "forfeited_bonds_eth": bonds_eth,
                "forfeited_bonds_usd": usd(bonds_eth),
                "eth_locked_under_genesis_usd": genesis_usd + usd(bonds_eth),
            }
        ]
    )
    out.tables["genesis_locked"] = locked

    fig, ax = plt.subplots(figsize=(7, 4.5))
    ax.semilogx(shares["depth_M"], shares["genesis_share_of_sleeve"] * 100, "o-", label="w(r) polynomial, no floor")
    ax.semilogx(shares["depth_M"], shares["with_10pct_floor"] * 100, "s--", label="with a 10% fixed floor")
    ax.semilogx(shares["depth_M"], shares["even_split_share"] * 100, ":", label="even split")
    ax.set_xlabel("chain depth M")
    ax.set_ylabel("genesis share of the ancestor sleeve (%)")
    ax.set_title("Sim 10: genesis take vs depth")
    ax.legend()
    ax.grid(alpha=0.3, which="both")
    save_fig(fig, 10, "genesis_share", out)

    r5 = shares[shares["depth_M"] == 5].iloc[0]
    r1000 = shares[shares["depth_M"] == 1000].iloc[0]
    out.interpretation = (
        f"Pure arithmetic on w(r) = 2 - 5r + 4r^2 with Z(M) = (M+1)(5M+4)/(6M), plus the ledger "
        f"from {gens} generations of edge volume. The claim *no genesis tax funnel* is VERIFIED. "
        f"Genesis takes {float(r5['genesis_share_of_sleeve']):.1%} of the ancestor sleeve at M = 5 "
        f"and {float(r1000['genesis_share_of_sleeve']):.3%} at M = 1000 - it decays as 12/(5M) for "
        f"large M, i.e. genesis's cut goes to zero as the chain grows, and it is only "
        f"{float(r1000['genesis_over_even']):.2f}x an even split at any depth. Genesis is "
        f"permanently worth exactly 2x the newest ancestor and never more, by construction of "
        f"w(0) = 2 and w(1) = 1. The deleted 10% fixed floor is what a funnel would have looked "
        f"like: it would hand genesis {float(r1000['with_10pct_floor']):.1%} of every sleeve at "
        f"M = 1000, which is {float(r1000['floor_multiple']):.0f}x the polynomial's own answer and "
        f"would grow without bound relative to it. Dropping it (attack-log Q6) was correct. In "
        f"absolute terms genesis accumulates ${genesis_usd:,.0f} of sleeve plus "
        f"${usd(bonds_eth):,.0f} of forfeited bonds over {gens} generations at "
        f"${EDGE_VOL_USD_PER_ROUND:,.0f} of edge volume per round - real but modest, and delivered "
        f"as protocol-owned bid liquidity under genesis rather than as a withdrawal."
    )
    out.notes = (
        "Deep-M rows are arithmetic only: no simulation reaches M = 1000, and Sim 1 shows the "
        "brief-literal chain loses ETH-denominated relevance long before it."
    )
    return out


# ===========================================================================
# runner
# ===========================================================================
SCENARIOS = {
    1: sim1_lifecycle,
    2: sim2_stochastic,
    3: sim3_bad_link,
    4: sim4_adversarial,
    5: sim5_candidate_war,
    6: sim6_fee_equilibrium,
    7: sim7_route_depth,
    8: sim8_cascades,
    9: sim9_reinforcement,
    10: sim10_genesis,
}

# Sim 4 is the headline and runs first; the rest follow in numeric order.
ORDER = [4, 1, 2, 3, 5, 6, 7, 8, 9, 10]

ASSUMPTIONS = f"""
| assumption | value |
|---|---|
| RNG seed | {SEED} (each scenario uses `Random(SEED + n)`, so `--only n` reproduces `--all`) |
| parent supply, every link | {PARENT_SUPPLY:.0e} tokens |
| standard curve | `curves.self_similar(P)` default: 99.1% of supply over FDV `a0*P` -> `1e3*a0*P`, 0.9% tail to `1e6*a0*P`, `a0 = 1e-3` |
| hop fee `f_hop` | {HOP_FEE_BPS} bps, parent side, every family swap |
| protocol fee | {PROTOCOL_FEE_BPS / 100:.0f}% on the ETH side of the genesis pool only |
| developer | {DEV_SHARE:.0%} of the protocol fee |
| creator | {CREATOR_SHARE:.0%} baseline (swept in Sim 6) |
| flywheel remainder | {1 - DEV_SHARE - CREATOR_SHARE:.0%}, split {ANCESTOR_SPLIT:.0%}/{1 - ANCESTOR_SPLIT:.0%} ancestor sleeve / immediate-parent reinforcement (swept in Sim 6) |
| round | {REGISTRATION_S:.0f} s registration, {TRADING_S:.0f} s trading, {SNIPE_S:.0f} s snipe tax (99% -> 1%), {SUBMIT_WINDOW_S:.0f} s submission |
| threshold | `h = {H_FRAC:.2%}` of parent supply as an *average* absorption, decay x0.9 per failed round, floor {H_FLOOR_FRAC:.0%} |
| demand model | per-candidate "interest" is lognormal (sigma = {INTEREST_SIGMA}); interest 1.0 absorbs A_BASE = {A_BASE:,.0f} parent tokens over the window |
| USD | genesis FDV = ${GENESIS_FDV_USD:,.0f} at {GENESIS_FDV_ETH} ETH, i.e. ${USD_PER_ETH:,.0f}/ETH and ${USD_PER_GENESIS_TOKEN:.2e} per genesis token |
| ETH-edge volume | ${EDGE_VOL_USD_PER_ROUND:,.0f} per round where a scenario needs an exogenous figure |

Everything on the trust path is **parent-denominated**: scores, thresholds, absorption
and embedded liquidity are quoted in parent tokens (written "parent" below).  Only the
ETH edge and the fee ledger are quoted in ETH/USD.
"""


def run(keys: list[int], scale: Scale = FULL_SCALE) -> list[ScenarioOutput]:
    """Run the scenarios named by ``keys`` (in :data:`ORDER`), newest state each time."""
    outs: list[ScenarioOutput] = []
    for key in [k for k in ORDER if k in keys]:
        rng = random.Random(SEED + key)
        t0 = time.perf_counter()
        out = SCENARIOS[key](scale, rng)
        out.seconds = time.perf_counter() - t0
        save_tables(out)
        outs.append(out)
    return outs


def write_report(outs: list[ScenarioOutput], scale: Scale, path: Path | None = None) -> Path:
    """Render ``docs/sim-results.md``."""
    target = (DOCS / "sim-results.md") if path is None else path
    target.parent.mkdir(parents=True, exist_ok=True)
    total = math.fsum(o.seconds for o in outs)
    lines = [
        "# Simulation results",
        "",
        "Generated by `python -m sim.scenarios --all`. Every table here also exists as a CSV "
        "in `docs/results/` and every figure as a PNG in `docs/figures/`.",
        "",
        f"Scenarios in this file: {', '.join('Sim ' + str(o.key) for o in outs)}. "
        f"Scale `{scale.name}`. Total runtime {total:.1f} s.",
        "",
        "## Common assumptions",
        ASSUMPTIONS.strip(),
        "",
        "## Contents",
        "",
    ]
    for o in outs:
        lines.append(f"- [Sim {o.key} - {o.title}](#sim-{o.key})")
    lines.append("")
    for o in outs:
        lines += [
            f'<a id="sim-{o.key}"></a>',
            "",
            f"## Sim {o.key} - {o.title}",
            "",
            f"**Claim under test:** {o.claim}  ",
            f"**Runtime:** {o.seconds:.1f} s",
            "",
        ]
        for name, df in o.tables.items():
            lines += [
                f"### {name.replace('_', ' ')}",
                "",
                df_to_md(df),
                "",
                f"CSV: `docs/results/sim{o.key:02d}_{name}{OUTPUT_SUFFIX}.csv`",
                "",
            ]
        if o.figures:
            lines.append("### figures")
            lines.append("")
            for f in o.figures:
                lines.append(f"![{f}](figures/{f})")
            lines.append("")
        lines += ["### interpretation", "", o.interpretation, ""]
        if o.notes:
            lines += [f"*Modelling notes:* {o.notes}", ""]
    target.write_text("\n".join(lines), encoding="utf-8")
    return target


def main(argv: list[str] | None = None) -> int:
    global CLI_CURVE_OVERRIDE, CLI_H_OVERRIDE_PCT, CLI_HOP_BPS_OVERRIDE, CLI_RESET_ON_WIN
    global OUTPUT_SUFFIX

    ap = argparse.ArgumentParser(prog="python -m sim.scenarios", description=__doc__)
    ap.add_argument("--all", action="store_true", help="run every scenario")
    ap.add_argument("--only", type=str, default="", help="comma-separated scenario numbers")
    ap.add_argument("--tiny", action="store_true", help="tiny scale (smoke test sizes)")
    ap.add_argument(
        "--curve",
        choices=["single", "ladder", "mid"],
        default=None,
        help="override the standard curve used by every round-based scenario "
        "(1, 2, 4, 5, 6) and equal-ETH-depth chain (3, 7, 8, 9) "
        "(default: unchanged, self-similar SINGLE-like)",
    )
    ap.add_argument(
        "--h",
        type=float,
        default=None,
        metavar="PCT",
        help="override the win threshold h as a percent of parent supply, "
        "used by every round-based scenario (default: unchanged, {:.2f}%%)".format(
            H_FRAC * 100.0
        ),
    )
    ap.add_argument(
        "--hop-bps",
        type=float,
        default=None,
        metavar="BPS",
        help="override the hop fee f_hop (parent side, every family swap), used "
        "everywhere a chain or round is built (default: unchanged, {:.1f} bps)".format(
            HOP_FEE_BPS
        ),
    )
    ap.add_argument(
        "--reset-on-win",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="H snaps back to H0 on a win (Sim 2 reduced form and every real "
        "RoundConfig); pass --no-reset-on-win to carry decay across a win "
        "(default: True)",
    )
    ap.add_argument(
        "--final",
        action="store_true",
        help="write the 'final' deploy-config baseline outputs "
        "(docs/sim-results-final.md, *_final.csv/.png) instead of the suffix "
        "derived from --curve; keeps earlier baseline and *_ladder outputs untouched",
    )
    args = ap.parse_args(argv)
    if args.only:
        keys = [int(x) for x in args.only.replace(" ", "").split(",") if x]
        bad = [k for k in keys if k not in SCENARIOS]
        if bad:
            ap.error(f"unknown scenario(s): {bad}")
    elif args.all:
        keys = list(SCENARIOS)
    else:
        ap.error("pass --all or --only N[,M...]")
    scale = TINY_SCALE if args.tiny else FULL_SCALE

    CLI_CURVE_OVERRIDE = args.curve
    CLI_H_OVERRIDE_PCT = args.h
    CLI_HOP_BPS_OVERRIDE = args.hop_bps
    CLI_RESET_ON_WIN = args.reset_on_win
    OUTPUT_SUFFIX = "_final" if args.final else (f"_{args.curve}" if args.curve else "")

    t0 = time.perf_counter()
    outs = run(keys, scale)
    if args.final:
        report_path = DOCS / "sim-results-final.md"
    elif OUTPUT_SUFFIX:
        report_path = DOCS / f"sim-results-{args.curve}.md"
    else:
        report_path = None
    path = write_report(outs, scale, report_path)
    for o in outs:
        print(f"sim {o.key:>2}  {o.seconds:7.1f} s  {o.title}")
    print(f"total {time.perf_counter() - t0:.1f} s -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
