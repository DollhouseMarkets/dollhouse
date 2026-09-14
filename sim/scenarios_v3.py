"""Three scenarios that put numbers on the MECHANISM_v3 addendum.

Run everything::

    python -m sim.scenarios_v3 --all

Run a subset (by scenario number)::

    python -m sim.scenarios_v3 --only 12

Outputs
-------
``docs/sim-results-v3.md``    tables + one interpretation paragraph per scenario
``docs/results/*_v3.csv``     one CSV per table
``docs/figures/*_v3.png``     matplotlib (no seaborn) figures

The three scenarios map one-to-one onto the addendum's own checklist item 4:

``Sim 11``  contestable purse -- top-2, proportional, trunk locked (v3 S1).
            SUPERSEDED by the review-3 decision of 2026-09-13: the purse is no longer
            contestable and is deployed in full under the trunk coin that won the
            round. Kept as the evidence the decision was made against; not re-run.
            See ``docs/MECHANISM_v3.md`` section 1 and ``docs/sim-results-v3.md``.
``Sim 12``  adaptive round duration and the late-entry burst exploit (v3 S2)
``Sim 13``  random end inside the last 3 minutes (v3 S3)

Everything reuses :mod:`sim.scenarios` (same curve, same fee split, same USD
calibration) so the numbers here sit next to ``docs/sim-results-final.md``
without re-deriving the baseline.  The existing ten scenarios are untouched:
this module only *imports* from them.
"""

from __future__ import annotations

import argparse
import math
import random
import time
from dataclasses import dataclass
from pathlib import Path

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from .clmm import Pool  # noqa: E402
from .curves import build_pool  # noqa: E402
from .family import ancestor_norm, ancestor_weight  # noqa: E402
from .scenarios import (  # noqa: E402
    A_BASE,
    ANCESTOR_SPLIT,
    CREATOR_SHARE,
    DEV_SHARE,
    EDGE_VOL_USD_PER_ROUND,
    FULL_SCALE,
    H0,
    H_FLOOR_FRAC,
    H_FRAC,
    HOP_FEE_BPS,
    INTEREST_SIGMA,
    PARENT_SUPPLY,
    PROTOCOL_FEE_BPS,
    TINY_SCALE,
    USD_PER_GENESIS_TOKEN,
    Scale,
    ScenarioOutput,
    df_to_md,
    round_config,
)

__all__ = [
    "SEED",
    "SCENARIOS",
    "ORDER",
    "duration_s",
    "registration_s",
    "late_entry_s",
    "window_s",
    "closing_window_avg_uniform",
    "closing_window_score_plateau",
    "purse_split",
    "run",
    "write_report",
    "main",
]

# ---------------------------------------------------------------------------
# common assumptions (mirrored exactly into the results file)
# ---------------------------------------------------------------------------
SEED = 20260912  # the v3 addendum's date; each scenario uses Random(SEED + n)

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
RESULTS_DIR = DOCS / "results"
FIGURES_DIR = DOCS / "figures"
OUTPUT_SUFFIX = "_v3"

# --- v3 S2: the duration schedule (a pure function of the round number) -----
D_BASE_S = 900.0             # 15 min
D_CAP_S = 12 * 3600.0        # 12 h
R_MIN_S = 180.0              # 3 min
R_MAX_S = 3600.0             # 1 h
LATE_ENTRY_MIN_D_S = 3600.0  # late entry allowed iff D(n) >= 1 h
END_WINDOW_S = 180.0         # v3 S3: T_end = T - (r mod 180 s)
W_SHORT_S = 900.0            # v3 S2: closing-window scoring, flat 15 min
W_LONG_CAP_D_S = 3600.0      # old-rule threshold: W = 15 min for D <= 1 h, else D/4
                             # (kept only for closing_window(D, old_rule=True))


# ---------------------------------------------------------------------------
# v3 S2 schedule: pure functions of the round number, nothing else
# ---------------------------------------------------------------------------
def duration_s(n: int) -> float:
    """``D(n) = min(15 min x 2^floor((n-1)/2), 12 h)``."""
    if n < 1:
        raise ValueError("round numbers start at 1")
    return min(D_BASE_S * 2.0 ** ((n - 1) // 2), D_CAP_S)


def registration_s(n: int) -> float:
    """``R(n) = clamp(D(n)/5, 3 min, 1 h)``."""
    return min(max(duration_s(n) / 5.0, R_MIN_S), R_MAX_S)


def late_entry_s(n: int) -> float:
    """Open-entry window: ``D(n)/3`` iff ``D(n) >= 1 h``, else 0 (no late entry)."""
    D = duration_s(n)
    return D / 3.0 if D >= LATE_ENTRY_MIN_D_S else 0.0


def closing_window(D: float, old_rule: bool = False) -> float:
    """v3 S2 closing-window scoring rule.

    Maintainer decision (2026-09-12): ``W`` is a flat 15 minutes on every
    round, regardless of duration ``D``. Pass ``old_rule=True`` to reproduce
    the previous rule (``W = 15 min`` for ``D <= 1 h``, else ``D/4``) for
    comparison.

    Identical for every candidate in the round (including late entrants) --
    there is no own-window/full-window distinction either way.
    """
    if old_rule:
        return W_SHORT_S if D <= W_LONG_CAP_D_S else D / 4.0
    return W_SHORT_S


def window_s(D: float, old_rule: bool = False) -> float:
    """Back-compat name for :func:`closing_window` (used throughout this module)."""
    return closing_window(D, old_rule=old_rule)


def closing_window_avg_uniform(level: float, D_nominal: float, T_end: float, W: float) -> float:
    """Closing-window average of a candidate accumulating linearly to ``level``
    over ``[0, D_nominal]`` (uniform arrival, no selling), scored over the window
    ``[max(0, T_end - W), T_end]`` of a (possibly early, random) end ``T_end``.

    Because the path is linear, the window average is just the mean of the two
    endpoints of the window -- exact, no numerical integration needed.
    """
    win_start = max(0.0, T_end - W)
    if T_end <= win_start:
        return 0.0
    rate = level / D_nominal
    return rate * (T_end + win_start) / 2.0


def closing_window_score_plateau(C: float, deploy_finish: float, D: float, W: float) -> float:
    """Score of a candidate that deploys total ``C`` by ``deploy_finish`` and then
    holds flat (no further trading) through the round, under closing-window
    averaging over ``[D - W, D]``.

    If ``deploy_finish`` falls before the window opens, the candidate is flat for
    the *whole* window and the score is exactly ``C`` -- independent of when it
    finished. That is the "equal by construction" property v3 S2 relies on to
    remove the late-entry own-window bonus: a late entrant that reaches the same
    level as an early one before the window opens scores identically; its only
    handicap is having less time to reach that level in the first place.
    """
    window_start = D - W
    if deploy_finish <= window_start:
        return C
    span = D - deploy_finish
    if span <= 0.0:
        return C
    # still filling when the window opens: ramps 0 -> C over [deploy_finish, D],
    # which lies entirely inside the window (deploy_finish > window_start here).
    return C * (D - deploy_finish) / (2.0 * W)


# --- v3 S1: purse accounting ------------------------------------------------
# The ancestor sleeve is (1 - dev - creator) * ancestor_split of the 1% edge
# fee, i.e. exactly the ledger Sims 1/6/10 use.  One generation's purse is its
# ancestor weight w(g/M)/Z(M) of every later round's sleeve.
SLEEVE_SHARE = (1.0 - DEV_SHARE - CREATOR_SHARE) * ANCESTOR_SPLIT
SLEEVE_USD_PER_ROUND = EDGE_VOL_USD_PER_ROUND * (PROTOCOL_FEE_BPS / 1e4) * SLEEVE_SHARE
S11_GEN_INDEX = 10            # the generation whose purse is being contested
S11_CHAIN_DEPTH = 20          # head index M while the contest runs
S11_ROUNDS_PER_DAY = 2.0      # mature chain: D = 12 h, so two rounds a day

# ---------------------------------------------------------------------------
# Sim 11 knobs
# ---------------------------------------------------------------------------
S11_NS = (3, 6, 12)
S11_DAYS = 30
S11_STEP_H = 1.0                  # support is re-sampled hourly (fine enough to
                                   # resolve a sub-6h trailing window, see below)
S11_STEPS_PER_DAY = int(24 / S11_STEP_H)
S11_POST_FLOW_PER_DAY = 0.05      # post-round net support, in units of A_BASE/day
S11_FLOW_SIGMA = 0.8              # lognormal noise on each step's net flow
S11_DUMP_DAY = 3
S11_RALLY_DAY = 10
S11_RALLY_MULT = 3.0
S11_WHALE_DEPLOY_DAY = 15          # integer day: a keeper deployment the whale times against
S11_CAPITAL_APR = 0.05            # opportunity cost of parked capital
S11_MODES = (
    ("honest", "honest", 0.0),
    ("dump50", "dump", 0.50),
    ("dump90", "dump", 0.90),
    ("rally", "rally", 0.0),
    ("whale", "whale", 0.0),
)
# v3 design decision (2026-09-12): trailing support uses the *generation's own*
# closing window W(D), not the round duration -- generation g was minted by
# round n = g, so its window is window_s(duration_s(g)), not a fixed 12/24 h
# assumption.  Re-run under this rule to see how much cheaper whale parking
# gets (reported honestly, whatever the number comes out to).
S11_D_GEN_S = duration_s(S11_GEN_INDEX)
S11_W_GEN_S = window_s(S11_D_GEN_S)
S11_W_H = S11_W_GEN_S / 3600.0
# The whale only needs to be parked for one trailing window ending right at a
# keeper deployment -- not a fixed calendar day -- so its buy/sell are aligned
# exactly to the step grid that feeds the day-`S11_WHALE_DEPLOY_DAY` snapshot
# (see the deployment loop below, `i = d * S11_STEPS_PER_DAY - 1`).
S11_WHALE_HOLD_STEPS = max(1, math.ceil(S11_W_GEN_S / 3600.0 / S11_STEP_H))
S11_WHALE_DEPLOY_STEP = S11_WHALE_DEPLOY_DAY * S11_STEPS_PER_DAY - 1
S11_WHALE_BUY_STEP = S11_WHALE_DEPLOY_STEP - S11_WHALE_HOLD_STEPS + 1
S11_WHALE_DAY = S11_WHALE_BUY_STEP / S11_STEPS_PER_DAY
S11_WHALE_HOLD_DAYS = S11_WHALE_HOLD_STEPS / S11_STEPS_PER_DAY

# ---------------------------------------------------------------------------
# Sim 12 knobs
# ---------------------------------------------------------------------------
S12_ROUNDS = tuple(range(1, 15))
S12_DEMAND_EXPONENT = 0.5   # arrivals ~ duration^0.5 (stated assumption)
S12_CANDIDATES = 5
S12_LATE_PROFILES = 400     # honest buy-profile draws for the exploit MC

# --- closing-window snipe (v3 S2 rewrite, 2026-09-12) -----------------------
S12_CHALLENGER_MULT = 1.0     # challenger capital, in units of A_BASE
S12_SNIPE_LEAD_S = 180.0      # buys W + this many seconds before the window opens
S12_RIVAL_SELL_PROB = 0.20    # P(the leader's community sells into the snipe)
S12_RIVAL_SELL_FRAC = 0.25    # that sell, as a fraction of the challenger's tokens

# ---------------------------------------------------------------------------
# Sim 13 knobs
# ---------------------------------------------------------------------------
S13_DURATIONS = (900.0, 12 * 3600.0)       # the 15-minute and the 12-hour round
S13_SNIPE_AT_S = 10.0                      # last-second sniper buys at T - 10 s
S13_CAPITAL_MULTS = (0.25, 0.5, 1.0, 2.0)  # sniper capital, in units of A_BASE


# ---------------------------------------------------------------------------
# IO helpers (own copies so the smoke test can redirect them independently)
# ---------------------------------------------------------------------------
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


def human(seconds: float) -> str:
    """``900 -> '15 min'``, ``43200 -> '12 h'`` (table-friendly duration label)."""
    return f"{seconds / 60:.0f} min" if seconds < 3600 else f"{seconds / 3600:.0f} h"


# ---------------------------------------------------------------------------
# shared plumbing
# ---------------------------------------------------------------------------
def candidate_pool() -> Pool:
    """A fresh candidate curve, exactly as :meth:`sim.rounds.Round.register` builds it."""
    cfg = round_config()
    return build_pool(
        cfg.curve_spec,
        supply=cfg.parent_supply,
        snap_ticks=cfg.snap_ticks,
        tick_spacing=cfg.tick_spacing,
        hop_fee_bps=cfg.hop_fee_bps,
        fee_on="parent",
    )


@dataclass
class Sibling:
    """One coin of a generation, with its pool and the hook's running accumulator.

    ``R`` is cumulative net parent absorbed -- the same quantity the round is
    scored with, kept running after the round (v3 S1), so a sell really does
    take the coin's support back down.
    """

    idx: int
    interest: float
    pool: Pool
    tokens: float = 0.0
    R: float = 0.0

    def buy(self, parent_in: float) -> float:
        """Absorb ``parent_in`` parent; returns the net parent added to ``R``."""
        if parent_in <= 0.0:
            return 0.0
        res = self.pool.swap_exact_in(parent_in, parent_in=True)
        self.tokens += res.amount_out
        net = res.amount_in_used - res.fee_paid
        self.R += net
        return net

    def sell_tokens(self, tokens_in: float) -> float:
        """Sell ``tokens_in``; returns parent received (``R`` falls by the gross)."""
        if tokens_in <= 0.0 or self.tokens <= 0.0:
            return 0.0
        res = self.pool.swap_exact_in(min(tokens_in, self.tokens), parent_in=False)
        self.tokens -= res.amount_in_used
        self.R -= res.amount_out + res.fee_paid
        return res.amount_out


def purse_usd_per_day(gen: int = S11_GEN_INDEX, depth: int = S11_CHAIN_DEPTH) -> float:
    """USD/day accruing to generation ``gen``'s purse on a depth-``depth`` chain."""
    weight = ancestor_weight(gen / depth) / ancestor_norm(depth)
    return SLEEVE_USD_PER_ROUND * S11_ROUNDS_PER_DAY * weight


def trailing_average(series: list[float], i: int, window_steps: int) -> float:
    """Time-weighted mean of a step-constant accumulator over the trailing window."""
    seg = series[max(0, i - window_steps + 1) : i + 1]
    return math.fsum(seg) / len(seg)


def purse_split(trailing: list[float]) -> list[float]:
    """v3 S1: proportional split between the top 2 by trailing support, else 0.

    SUPERSEDED (review 3, 2026-09-13): the protocol no longer splits a purse at all.
    Retained so Sim 11 still reproduces the numbers the decision was made against.
    """
    order = sorted(range(len(trailing)), key=lambda i: (-trailing[i], i))
    top = [i for i in order[:2] if trailing[i] > 0.0]
    total = math.fsum(trailing[i] for i in top)
    shares = [0.0] * len(trailing)
    if total <= 0.0:
        return shares
    for i in top:
        shares[i] = trailing[i] / total
    return shares


# ===========================================================================
# Sim 11 -- contestable purse: top 2, proportional, trunk locked
# ===========================================================================
def _s11_trial(
    n: int, mode: str, rng: random.Random, dump_frac: float = 0.0
) -> dict[str, object]:
    """One generation's 30-day post-round life under one behaviour ``mode``.

    ``mode`` is ``honest`` | ``dump`` | ``rally`` | ``whale``.  Sibling 0 is the
    *round winner* by construction (the highest interest draw), which is what
    makes "the winner loses the purse" a well-posed question.
    """
    interests = sorted(
        (rng.lognormvariate(0.0, INTEREST_SIGMA) for _ in range(n)), reverse=True
    )
    sibs = [Sibling(i, x, candidate_pool()) for i, x in enumerate(interests)]
    for s in sibs:
        s.buy(s.interest * A_BASE)  # the round itself

    steps = S11_DAYS * S11_STEPS_PER_DAY
    window_steps = max(1, int(round(S11_W_H / S11_STEP_H)))
    base = S11_POST_FLOW_PER_DAY * A_BASE / S11_STEPS_PER_DAY
    paths: list[list[float]] = [[] for _ in sibs]
    rally_idx: int | None = None
    whale_idx: int | None = None
    whale_parent = 0.0
    whale_tokens = 0.0
    whale_returned = 0.0
    whale_friction = 0.0

    for k in range(steps):
        day = k / S11_STEPS_PER_DAY
        # -- ordinary support: lognormal noise around the interest level -----
        for s in sibs:
            mult = S11_RALLY_MULT if (rally_idx == s.idx and day >= S11_RALLY_DAY) else 1.0
            flow = (
                s.interest
                * base
                * mult
                * (rng.lognormvariate(-0.5 * S11_FLOW_SIGMA**2, S11_FLOW_SIGMA) - 0.5)
            )
            if flow > 0.0:
                s.buy(flow)
            elif flow < 0.0 and s.tokens > 0.0:
                # net selling: the parent shortfall converted to tokens at spot
                s.sell_tokens(min(s.tokens, -flow / max(s.pool.price, 1e-18)))
        # -- the scripted event for this mode ---------------------------------
        if mode == "dump" and abs(day - S11_DUMP_DAY) < 1e-9:
            sibs[0].sell_tokens(sibs[0].tokens * dump_frac)
        if mode == "rally" and abs(day - S11_RALLY_DAY) < 1e-9 and rally_idx is None:
            ranked = sorted(sibs, key=lambda s: -s.R)
            rally_idx = ranked[min(2, len(ranked) - 1)].idx  # first coin out of the money
        if mode == "whale" and abs(day - S11_WHALE_DAY) < 1e-9:
            ranked = sorted(sibs, key=lambda s: -s.R)
            target = ranked[min(2, len(ranked) - 1)]
            whale_idx = target.idx
            whale_parent = max(ranked[0].R, 0.0)  # capital = the leader's support
            # friction is priced on a clone: buy in and unwind immediately, so
            # it is hop fees both ways plus own price impact and nothing else.
            # The realised P&L below also contains a day of market drift, which
            # is speculation, not a cost of parking.
            probe = target.pool.clone()
            got = probe.swap_exact_in(whale_parent, parent_in=True)
            whale_friction = whale_parent - probe.swap_exact_in(
                got.amount_out, parent_in=False
            ).amount_out
            before = target.tokens
            target.buy(whale_parent)
            whale_tokens = target.tokens - before
        if (
            whale_idx is not None
            and whale_tokens > 0.0
            and abs(day - (S11_WHALE_DAY + S11_WHALE_HOLD_DAYS)) < 1e-9
        ):
            whale_returned = sibs[whale_idx].sell_tokens(whale_tokens)
            whale_tokens = 0.0
        for s in sibs:
            paths[s.idx].append(s.R)

    # -- daily keeper deployments --------------------------------------------
    per_day = purse_usd_per_day()
    share_hist: list[list[float]] = []
    winner_usd = 0.0
    sibling_usd = 0.0
    whale_usd = 0.0
    for d in range(1, S11_DAYS + 1):
        i = d * S11_STEPS_PER_DAY - 1
        trailing = [trailing_average(p, i, window_steps) for p in paths]
        shares = purse_split(trailing)
        share_hist.append(shares)
        winner_usd += shares[0] * per_day
        sibling_usd += (1.0 - shares[0]) * per_day
        if whale_idx is not None and S11_WHALE_DAY < d <= S11_WHALE_DAY + S11_WHALE_HOLD_DAYS + 1e-9:
            whale_usd += shares[whale_idx] * per_day

    final = share_hist[-1]
    return {
        "shares": share_hist,
        "winner_final_share": final[0],
        "winner_lost_top1": final[0] < max(final),
        "winner_out_of_money": final[0] <= 0.0,
        "winner_usd": winner_usd,
        "sibling_usd": sibling_usd,
        "whale_usd": whale_usd,
        "whale_parent": whale_parent,
        "whale_returned": whale_returned,
        "whale_friction": whale_friction,
    }


def sim11_purse(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        11,
        "Contestable purse: top-2 proportional, trunk locked",
        "a dumped winner can lose the purse, and parked capital cannot buy it cheaply",
    )
    trials = max(2, scale.chains_s2 // 4)
    v2_purse = purse_usd_per_day() * S11_DAYS

    rows: list[dict] = []
    whale_rows: list[dict] = []
    demo: dict[str, list[list[float]]] = {}
    for n in S11_NS:
        for label, mode, frac in S11_MODES:
            res = [_s11_trial(n, mode, rng, frac) for _ in range(trials)]
            if n == 6:
                demo[label] = res[0]["shares"]
            winner_usd = math.fsum(r["winner_usd"] for r in res) / trials
            rows.append(
                {
                    "siblings": n,
                    "scenario": label,
                    "trials": trials,
                    "p_winner_not_top1": sum(r["winner_lost_top1"] for r in res) / trials,
                    "p_winner_out_of_money": sum(r["winner_out_of_money"] for r in res) / trials,
                    "winner_final_share": math.fsum(r["winner_final_share"] for r in res) / trials,
                    "winner_purse_usd_30d": winner_usd,
                    "siblings_purse_usd_30d": math.fsum(r["sibling_usd"] for r in res) / trials,
                    "v2_winner_purse_usd_30d": v2_purse,
                    "v3_over_v2_winner": winner_usd / v2_purse,
                }
            )
            if mode == "whale":
                cap = math.fsum(r["whale_parent"] for r in res) / trials
                back = math.fsum(r["whale_returned"] for r in res) / trials
                fric = math.fsum(r["whale_friction"] for r in res) / trials
                got = math.fsum(r["whale_usd"] for r in res) / trials
                fric_usd = fric * USD_PER_GENESIS_TOKEN
                carry = (
                    cap * USD_PER_GENESIS_TOKEN * S11_CAPITAL_APR * S11_WHALE_HOLD_DAYS / 365.0
                )
                whale_rows.append(
                    {
                        "siblings": n,
                        "parked_parent": cap,
                        "parked_usd": cap * USD_PER_GENESIS_TOKEN,
                        "days_parked": S11_WHALE_HOLD_DAYS,
                        "friction_usd": fric_usd,
                        "friction_bps_of_capital": 1e4 * fric / max(cap, 1e-12),
                        "carry_cost_usd": carry,
                        "total_cost_usd": fric_usd + carry,
                        "purse_captured_usd": got,
                        "net_usd": got - fric_usd - carry,
                        "actual_purse_per_day_usd": purse_usd_per_day(),
                        "breakeven_multiple": (fric_usd + carry)
                        / max(purse_usd_per_day() * S11_WHALE_HOLD_DAYS, 1e-12),
                        "realised_market_pnl_usd": (back - cap) * USD_PER_GENESIS_TOKEN,
                    }
                )
    summary = pd.DataFrame(rows)
    whales = pd.DataFrame(whale_rows)
    out.tables["purse_outcomes"] = summary
    out.tables["whale_economics"] = whales

    path_rows = []
    for label, hist in demo.items():
        for d, shares in enumerate(hist, start=1):
            order = sorted(range(len(shares)), key=lambda i: -shares[i])
            path_rows.append(
                {
                    "scenario": label,
                    "day": d,
                    "top1_share": shares[order[0]],
                    "top2_share": shares[order[1]] if len(order) > 1 else 0.0,
                    "round_winner_share": shares[0],
                    "round_winner_is_top1": order[0] == 0,
                }
            )
    paths_df = pd.DataFrame(path_rows)
    out.tables["share_paths_n6"] = paths_df

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for label in demo:
        sub = paths_df[paths_df["scenario"] == label]
        ax.plot(sub["day"], sub["round_winner_share"] * 100, label=label)
    ax.axhline(100.0, color="k", ls=":", lw=1, label="v2 rule (winner keeps 100%)")
    ax.set_xlabel("day after the round")
    ax.set_ylabel("round winner's purse share (%)")
    ax.set_title("Sim 11: purse share of the round winner, 6 siblings")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    save_fig(fig, 11, "purse_share", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    labels = [m[0] for m in S11_MODES]
    width = 0.25
    for k, n in enumerate(S11_NS):
        vals = [
            float(
                summary[(summary["siblings"] == n) & (summary["scenario"] == lab)][
                    "p_winner_not_top1"
                ].iloc[0]
            )
            for lab in labels
        ]
        ax.bar([i + k * width for i in range(len(labels))], vals, width, label=f"N = {n}")
    ax.set_xticks([i + width for i in range(len(labels))])
    ax.set_xticklabels(labels)
    ax.set_ylabel("P(round winner is not top-1 at day 30)")
    ax.set_title("Sim 11: how often the winner loses the purse lead")
    ax.legend()
    ax.grid(alpha=0.3, axis="y")
    save_fig(fig, 11, "winner_loses", out)

    def cell(n: int, label: str):
        return summary[(summary["siblings"] == n) & (summary["scenario"] == label)].iloc[0]

    h6, d5, d9, r6 = cell(6, "honest"), cell(6, "dump50"), cell(6, "dump90"), cell(6, "rally")
    w6 = whales[whales["siblings"] == 6].iloc[0]
    out.interpretation = (
        f"Post-round support is simulated on a {S11_STEP_H:.0f}-hour grid for {S11_DAYS} days "
        f"against real candidate curves, with the trailing window W_gen = window_s(D({S11_GEN_INDEX})) "
        f"= {S11_W_H:.2g} h (generation {S11_GEN_INDEX}'s own closing window, not the round "
        f"duration D({S11_GEN_INDEX}) = {duration_s(S11_GEN_INDEX) / 3600.0:.2g} h -- per the "
        f"2026-09-12 rewrite) and the purse split proportionally between the top 2 by trailing "
        f"support at a daily keeper deployment. The claim is "
        f"VERIFIED. Honest drift alone already costs the round winner the lead in "
        f"{float(h6['p_winner_not_top1']):.0%} of 6-sibling trials, and it keeps only "
        f"{float(h6['winner_final_share']):.0%} of the purse at day 30 against 100% under the v2 "
        f"rule: over 30 days it banks ${float(h6['winner_purse_usd_30d']):,.0f} of the "
        f"${v2_purse:,.0f} generation purse and its siblings take "
        f"${float(h6['siblings_purse_usd_30d']):,.0f}. Dumping is punished exactly as the addendum "
        f"claims: a 50% dump at day {S11_DUMP_DAY} leaves the winner "
        f"{float(d5['winner_final_share']):.0%} of the purse and a 90% dump "
        f"{float(d9['winner_final_share']):.0%}, losing the lead in "
        f"{float(d9['p_winner_not_top1']):.0%} of trials and falling out of the money entirely in "
        f"{float(d9['p_winner_out_of_money']):.0%}. An underdog rally (interest "
        f"x{S11_RALLY_MULT:.0f} from day {S11_RALLY_DAY} for the coin sitting third) flips the "
        f"lead in {float(r6['p_winner_not_top1']):.0%} of trials, so 'an underdog can grow into "
        f"the money' is real on a timescale of weeks rather than years. The whale is the "
        f"interesting case, and under the generation's own {S11_W_H * 60.0:.0f}-minute window it is "
        f"close to free. Parking parent equal to the leader's trailing support "
        f"(${float(w6['parked_usd']):,.0f}) for the {float(w6['days_parked']) * 24.0:.1f} hours "
        f"needed to span one W_gen either side of a keeper deployment costs "
        f"${float(w6['total_cost_usd']):,.2f} - ${float(w6['friction_usd']):,.2f} of round-trip "
        f"friction ({float(w6['friction_bps_of_capital']):.1f} bps: two hop fees, price impact "
        f"cancels on an immediate unwind) plus ${float(w6['carry_cost_usd']):,.2f} of carry - and "
        f"buys ${float(w6['purse_captured_usd']):,.2f} of purse, a net "
        f"${float(w6['net_usd']):,.2f} at a breakeven multiple of "
        f"{float(w6['breakeven_multiple']):.2f}x - that is, the cost of holding for just "
        f"{float(w6['days_parked']) * 24.0:.1f} hours already equals "
        f"{float(w6['breakeven_multiple']):.0%} of one *full day's* purse "
        f"(${float(w6['actual_purse_per_day_usd']):,.2f}) while the park buys "
        f"{float(w6['purse_captured_usd']) / float(w6['actual_purse_per_day_usd']):.0%} of it -- "
        f"because keeper deployments are lump-sum and daily, a whale only has to win the single "
        f"snapshot instant, not hold for the whole day it pays out. In "
        f"other words the attack is exactly at the money at ${EDGE_VOL_USD_PER_ROUND:,.0f} of edge "
        f"volume per round, and it turns profitable on any generation with more fee flow, more "
        f"frequent keeper deployments or a lower hop fee, because the only cost that scales with "
        f"the size of the park is {float(w6['friction_bps_of_capital']):.1f} bps of friction while "
        f"the purse share bought scales with the capital. The addendum's "
        f"disclosure is therefore accurate but understated: parked capital buys purse share and "
        f"never pairing rights, and it buys it cheaply. The defence that actually binds is the "
        f"trailing window - the whale must hold across a keeper deployment and for W_gen "
        f"({S11_W_H:.0f} h) either side of it - not the cost of the capital. Note also that a "
        f"whale that parks while honest flow continues to arrive books "
        f"${float(w6['realised_market_pnl_usd']):,.0f} of ordinary market P&L on top, which is "
        f"speculation rather than a cost of the attack and is excluded from the ledger above."
    )
    out.notes = (
        f"Purse income uses the Sim 1/6/10 ledger: ${EDGE_VOL_USD_PER_ROUND:,.0f} of ETH-edge "
        f"volume per round x {PROTOCOL_FEE_BPS / 100:.0f}% x {SLEEVE_SHARE:.0%} ancestor sleeve = "
        f"${SLEEVE_USD_PER_ROUND:,.0f}/round, {S11_ROUNDS_PER_DAY:.0f} rounds/day, generation "
        f"{S11_GEN_INDEX} of a depth-{S11_CHAIN_DEPTH} chain taking w(g/M)/Z(M) = "
        f"${purse_usd_per_day():,.2f}/day. Parent tokens are valued at "
        f"${USD_PER_GENESIS_TOKEN:.2e} (the equal-depth self-similar convention). Post-round "
        f"support per unit of interest is {S11_POST_FLOW_PER_DAY:.0%} of A_BASE per day with "
        f"lognormal (sigma = {S11_FLOW_SIGMA}) noise that can go negative; sibling 0 is the round "
        f"winner by construction (highest interest draw). Keeper deployments are daily, so the "
        f"whale captures at most one day of accrual."
    )
    return out


# ===========================================================================
# Sim 12 -- adaptive duration and the late-entry burst exploit
# ===========================================================================
def sim12_duration(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        12,
        "Adaptive round duration: demand, fail rate and the closing-window snipe",
        "the schedule stays winnable at a fixed threshold; late entry is equal by "
        "construction under closing-window scoring, but a closing-window snipe against a "
        "spread-out honest leader is real",
    )
    trials = max(2, scale.chains_s2)
    profiles = max(2, scale.chains_s2 * 2)
    h_floor = H_FLOOR_FRAC * H0

    capacity = candidate_pool().max_absorption()

    def _round_stats(n: int, exponent: float, draws: int) -> dict:
        """MC over ``draws`` rounds of number ``n`` at a given demand exponent."""
        D = duration_s(n)
        demand_scale = (D / D_BASE_S) ** exponent
        fails = fails_floor = 0
        best_avgs: list[float] = []
        floats: list[float] = []
        for _ in range(draws):
            interests = [rng.lognormvariate(0.0, INTEREST_SIGMA) for _ in range(S12_CANDIDATES)]
            # arrivals uniform over the window, so the accumulator's time-average
            # is exactly half the total parent absorbed -- and note the window
            # length cancels: the score is a level, not a rate
            avgs = [x * A_BASE * demand_scale / 2.0 for x in interests]
            best = max(avgs)
            best_avgs.append(best)
            fails += best < H0
            fails_floor += best < h_floor
            pool = candidate_pool()
            pool.swap_exact_in(best * 2.0, parent_in=True)
            floats.append(pool.tokens_sold() / PARENT_SUPPLY)
        head_demand = math.fsum(best_avgs) / draws * 2.0
        return {
            "round_n": n,
            "D_s": D,
            "D_human": human(D),
            "R_s": registration_s(n),
            "late_entry_s": late_entry_s(n),
            "demand_scale": demand_scale,
            "head_demand_parent": head_demand,
            "head_demand_usd": head_demand * USD_PER_GENESIS_TOKEN,
            "mean_best_avg_parent": math.fsum(best_avgs) / draws,
            "threshold_H0_parent": H0,
            "fail_rate_at_H0": fails / draws,
            "fail_rate_at_floor": fails_floor / draws,
            "winner_float_sold": math.fsum(floats) / draws,
            "curve_capacity_used": head_demand / capacity,
        }

    sched = pd.DataFrame([_round_stats(n, S12_DEMAND_EXPONENT, trials) for n in S12_ROUNDS])
    out.tables["schedule_and_demand"] = sched

    # -- how the verdict moves with the arrival assumption --------------------
    sens_rows = []
    for exponent in (-0.5, 0.0, 0.5, 1.0):
        for n in (1, 7, 13):
            r = _round_stats(n, exponent, trials)
            sens_rows.append(
                {
                    "demand_exponent": exponent,
                    "round_n": n,
                    "D_human": r["D_human"],
                    "mean_best_avg_parent": r["mean_best_avg_parent"],
                    "fail_rate_at_H0": r["fail_rate_at_H0"],
                    "winner_float_sold": r["winner_float_sold"],
                    "curve_capacity_used": r["curve_capacity_used"],
                }
            )
    out.tables["demand_exponent_sensitivity"] = pd.DataFrame(sens_rows)

    # -- closing-window snipe (v3 S2 rewrite, 2026-09-12) ----------------------
    # There is no more own-window/full-window split: every candidate, early or
    # late, is scored over the identical closing window [T_end - W, T_end]. The
    # question that matters now is the one the addendum discloses directly: can
    # a challenger who buys just before the window opens and holds beat an
    # honest leader who spread the same capital over the *whole* round?
    snipe_rows = []
    for n in S12_ROUNDS:
        D = duration_s(n)
        W = window_s(D)
        C = S12_CHALLENGER_MULT * A_BASE
        hop = HOP_FEE_BPS / 1e4
        # honest leader: spreads C evenly over [0, D], scored over the same
        # closing window, deterministic end (Sim 13 covers the random-end case)
        honest_avg = closing_window_avg_uniform(C * (1.0 - hop), D, D, W)
        wins = 0
        realised: list[float] = []
        for _ in range(profiles):
            pool = candidate_pool()
            res = pool.swap_exact_in(C, parent_in=True)
            r = res.amount_in_used - res.fee_paid
            if rng.random() < S12_RIVAL_SELL_PROB:
                sell_tokens = res.amount_out * S12_RIVAL_SELL_FRAC
                sell_res = pool.swap_exact_in(sell_tokens, parent_in=False)
                r -= sell_res.amount_out + sell_res.fee_paid
            realised.append(r)
            wins += r > honest_avg
        challenger_score = math.fsum(realised) / profiles
        hold_days = (W + S12_SNIPE_LEAD_S) / 86400.0
        fee_usd = C * hop * USD_PER_GENESIS_TOKEN
        carry_usd = C * USD_PER_GENESIS_TOKEN * S11_CAPITAL_APR * hold_days
        rival_cost_usd = max(0.0, C * (1.0 - hop) - challenger_score) * USD_PER_GENESIS_TOKEN
        snipe_rows.append(
            {
                "round_n": n,
                "D_human": human(D),
                "W_human": human(W),
                "challenger_capital_parent": C,
                "challenger_score_parent": challenger_score,
                "honest_spread_score_parent": honest_avg,
                "p_challenger_wins": wins / profiles,
                "hold_seconds": W + S12_SNIPE_LEAD_S,
                "fee_usd": fee_usd,
                "carry_usd": carry_usd,
                "rival_sell_cost_usd": rival_cost_usd,
                "total_cost_usd": fee_usd + carry_usd + rival_cost_usd,
            }
        )
    snipe = pd.DataFrame(snipe_rows)
    out.tables["closing_window_snipe"] = snipe

    # -- late entry is now equal to the early coin by construction -------------
    # Both reach the same level C; as long as they are done deploying it before
    # the window opens, the closing-window average is C for both, independent
    # of when each finished. (Asserted directly in the smoke tests too.)
    equal_rows = []
    for n in S12_ROUNDS:
        D, le = duration_s(n), late_entry_s(n)
        if le <= 0.0:
            continue
        W = window_s(D)
        C = A_BASE
        early_score = closing_window_score_plateau(C, 0.0, D, W)
        late_score = closing_window_score_plateau(C, le, D, W)
        equal_rows.append(
            {
                "round_n": n,
                "D_human": human(D),
                "late_entry_s": le,
                "early_coin_score": early_score,
                "late_entrant_score": late_score,
                "equal_by_construction": early_score == late_score,
            }
        )
    equal = pd.DataFrame(equal_rows)
    assert bool(equal["equal_by_construction"].all()), "late entry must score equal to the early coin"
    out.tables["late_entry_equal"] = equal

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    ax.plot(sched["round_n"], sched["fail_rate_at_H0"] * 100, "o-", label="fail rate at H0")
    ax.plot(
        sched["round_n"], sched["fail_rate_at_floor"] * 100, "s--",
        label="fail rate at the 25% floor",
    )
    ax2 = ax.twinx()
    ax2.semilogy(sched["round_n"], sched["D_s"] / 60.0, ":", color="grey")
    ax2.set_ylabel("D(n) (minutes, log)")
    ax.set_xlabel("round number n")
    ax.set_ylabel("rounds with no winner (%)")
    ax.set_title("Sim 12: fail rate under demand ~ D^0.5 with a fixed threshold")
    ax.legend(loc="center left", fontsize=8)
    ax.grid(alpha=0.3)
    save_fig(fig, 12, "duration_fail_rate", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    ax.plot(snipe["round_n"], snipe["p_challenger_wins"] * 100, "o-", label="P(closing-window snipe wins)")
    ax.set_xlabel("round number n")
    ax.set_ylabel("challenger win rate (%)")
    ax.set_title("Sim 12: closing-window snipe vs an honest full-round spread")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    save_fig(fig, 12, "late_entry", out)

    r1 = sched[sched["round_n"] == 1].iloc[0]
    r7 = sched[sched["round_n"] == 7].iloc[0]
    r13 = sched[sched["round_n"] == 13].iloc[0]
    e = snipe[snipe["round_n"] == 9].iloc[0]
    sens = out.tables["demand_exponent_sensitivity"]
    neg = sens[(sens["demand_exponent"] == -0.5) & (sens["round_n"] == 13)].iloc[0]
    out.interpretation = (
        f"Demand is assumed to arrive in proportion to duration^{S12_DEMAND_EXPONENT} - twice the "
        f"window brings sqrt(2) times the flow, the usual sub-linear attention assumption - and "
        f"arrivals are uniform over the window. The first thing the sweep shows is structural and "
        f"has nothing to do with the exponent: the score is the time-*average of an accumulator*, "
        f"so it has units of parent, not parent per second, and the window length cancels exactly "
        f"(uniform arrivals give avg = total/2 for any D). A fixed threshold H is therefore "
        f"already duration-neutral, and any demand assumption that is increasing in D makes long "
        f"rounds strictly *easier*. The claim *the schedule stays winnable* is VERIFIED and then "
        f"some. Round 1 (D = {r1['D_human']}) generates {float(r1['head_demand_parent']):,.0f} "
        f"parent of head demand (${float(r1['head_demand_usd']):,.0f}) and fails "
        f"{float(r1['fail_rate_at_H0']):.1%} of the time; round 7 ({r7['D_human']}) fails "
        f"{float(r7['fail_rate_at_H0']):.1%}; round 13 ({r13['D_human']}) draws "
        f"{float(r13['head_demand_parent']):,.0f} parent "
        f"(${float(r13['head_demand_usd']):,.0f}) and fails {float(r13['fail_rate_at_H0']):.1%}. "
        f"Only a *decreasing* arrival assumption breaks it: at exponent -0.5 round 13 fails "
        f"{float(neg['fail_rate_at_H0']):.0%} of the time. The real cost of the schedule is on the "
        f"other side of the ledger. The winner's float sold climbs from "
        f"{float(r1['winner_float_sold']):.1%} to {float(r13['winner_float_sold']):.2%} of supply "
        f"and the head round consumes {float(r13['curve_capacity_used']):.0%} of the standard "
        f"curve's entire absorption capacity by round 13, up from "
        f"{float(r1['curve_capacity_used']):.0%} at round 1 - the duration schedule scales with n "
        f"but the curve constants and H do not, so a mature round hands its winner an almost fully "
        f"distributed float and leaves nothing in the curve to absorb later flow. If demand really "
        f"grows with D, H(n) should grow with it (or the curve should) or succession becomes a "
        f"formality and the float is exhausted in one round. The closing-window rewrite removes "
        f"the own-window/full-window bug entirely: every candidate, late entrant included, is "
        f"scored over the identical window [T_end - W, T_end]. The late-entry case is now equal "
        f"to the early coin "
        f"*by construction* -- verified in the table and asserted in the code and the tests: a "
        f"late entrant that reaches the same level as an early coin before the window opens scores "
        f"exactly the same, regardless of when each finished deploying its capital, because the "
        f"window only sees the held level, not the arrival history. Its only real handicap is the "
        f"one the addendum names: less time to raise that level in the first place. The trade-off "
        f"the addendum discloses is a different, real one: a challenger with "
        f"{S12_CHALLENGER_MULT:.0f}x A_BASE who buys {S12_SNIPE_LEAD_S:.0f} s before the window "
        f"opens (round {int(e['round_n'])}, {e['D_human']} round, W = {e['W_human']}) and holds "
        f"scores {float(e['challenger_score_parent']):,.0f} parent against an honest leader who "
        f"spread the same capital over the *whole* round and scores only "
        f"{float(e['honest_spread_score_parent']):,.0f} parent -- because the honest leader is "
        f"still mid-ramp for most of the window while the challenger is already flat at its full "
        f"level. The challenger wins {float(e['p_challenger_wins']):.0%} of trials even after a "
        f"{S12_RIVAL_SELL_PROB:.0%} chance the leader's community sells "
        f"{S12_RIVAL_SELL_FRAC:.0%} of the challenger's tokens into it, at a total cost of "
        f"${float(e['total_cost_usd']):,.2f} (fee ${float(e['fee_usd']):,.2f} + carry "
        f"${float(e['carry_usd']):,.2f} + expected rival-sell hit "
        f"${float(e['rival_sell_cost_usd']):,.2f}) for holding "
        f"{float(e['hold_seconds']) / 60.0:.0f} minutes. This is exactly the trade-off "
        f"MECHANISM_v3 S2 discloses ('a coin can lead for hours and lose to one pumped and held "
        f"through the closing window') and it is real, not bounded at 1.5x the way the old "
        f"own-window bug was."
    )
    out.notes = (
        f"Arrival model: total absorbed = interest x A_BASE x (D/D1)^{S12_DEMAND_EXPONENT} with "
        f"arrivals uniform over the window, so the time-average of the accumulator is exactly half "
        f"the total; {S12_CANDIDATES} candidates per round, interest lognormal "
        f"(sigma = {INTEREST_SIGMA}). Winner float sold and curve capacity used are read off a "
        f"real candidate curve (`max_absorption` = {candidate_pool().max_absorption():,.0f} "
        f"parent). The closing-window snipe assumes a deterministic end (Sim 13 prices the "
        f"random-end case separately) and an honest leader spreading capital continuously and "
        f"uniformly over the whole round (`closing_window_avg_uniform`); the rival-sell exposure "
        f"is modelled as a real pool trade against the challenger's own position, not a discount "
        f"factor. The late-entry equality table uses a plateau model (`closing_window_score_"
        f"plateau`): both coins finish deploying their capital before the window opens and hold "
        f"flat, which is sufficient to prove the 'equal by construction' claim for any level they "
        f"both reach -- it does not model how much *harder* it is for the late entrant to reach "
        f"that level with less time, which is the handicap the addendum names and leaves outside "
        f"the scoring rule."
    )
    return out


# ===========================================================================
# Sim 13 -- random end inside the last 3 minutes
# ===========================================================================
def sniper_expected(strategy: str, D: float, random_end: bool) -> tuple[float, float]:
    """``(score per unit of net parent, fraction of the capital that scores)``.

    v3 S2 rewrite (2026-09-12): the scoring window is now ``Wc = window_s(D)``,
    not the full round ``D`` -- there is no own-window/full-window average
    anymore, just the closing window everyone shares. The random-end fuzz
    ``U ~ U[0, 180)`` (``END_WINDOW_S``, unchanged, v3 S3) is a *separate*,
    much shorter window that only jitters where inside ``Wc`` the true end
    falls: ``T_end = T - U``. A buy of size ``c`` at ``T - s`` contributes
    ``c * max(0, s - U) / Wc`` to the closing-window average, so the only
    thing to average is ``(s - U)^+``.
    """
    Wc = window_s(D)
    fuzz = END_WINDOW_S
    if strategy == "last_second":
        s = S13_SNIPE_AT_S
    elif strategy == "window_sniper":
        s = Wc  # buys right as the window opens and holds through the end
    elif strategy == "spread_3min":
        if not random_end:
            return (fuzz / 2.0) / Wc, 1.0               # E[s], s ~ U[0, fuzz)
        return (fuzz / 3.0) / Wc, 0.5                    # E[(s-U)^+] = fuzz/3; P(s > U) = 1/2
    else:
        raise ValueError(f"unknown sniper strategy {strategy!r}")
    if not random_end:
        return s / Wc, 1.0
    if s <= fuzz:
        return (s * s / (2.0 * fuzz)) / Wc, s / fuzz     # E[(s-U)^+] = s^2/2*fuzz for s <= fuzz
    return (s - fuzz / 2.0) / Wc, 1.0                    # s > fuzz: s - U is always positive


def sim13_random_end(scale: Scale, rng: random.Random) -> ScenarioOutput:
    out = ScenarioOutput(
        13,
        "Random end in the last 3 minutes: what it costs a sniper",
        "a random end makes last-second buying a losing gamble",
    )
    trials = max(2, scale.chains_s2 * 5)

    rows = []
    for D in S13_DURATIONS:
        for strategy in ("last_second", "spread_3min", "window_sniper"):
            for random_end in (False, True):
                per_unit, scored_frac = sniper_expected(strategy, D, random_end)
                for mult in S13_CAPITAL_MULTS:
                    C = mult * A_BASE
                    pool = candidate_pool()
                    res = pool.swap_exact_in(C, parent_in=True)
                    net = res.amount_in_used - res.fee_paid
                    back = pool.swap_exact_in(res.amount_out, parent_in=False)
                    rt_loss = C - back.amount_out
                    rows.append(
                        {
                            "D_human": human(D),
                            "strategy": strategy,
                            "end_rule": "random" if random_end else "fixed",
                            "capital_x_A_BASE": mult,
                            "capital_parent": C,
                            "net_parent_in": net,
                            "expected_score_gain_parent": net * per_unit,
                            "score_gain_vs_H0": net * per_unit / H0,
                            "fraction_of_capital_that_scores": scored_frac,
                            "round_trip_loss_parent": rt_loss,
                            "round_trip_loss_usd": rt_loss * USD_PER_GENESIS_TOKEN,
                            "expected_wasted_cost_usd": rt_loss
                            * USD_PER_GENESIS_TOKEN
                            * (1.0 - scored_frac),
                        }
                    )
    value = pd.DataFrame(rows)
    out.tables["sniper_value"] = value

    out.tables["honest_cost"] = pd.DataFrame(
        [
            {
                "D_human": human(D),
                "W_human": human(window_s(D)),
                "expected_end_pullback_s": END_WINDOW_S / 2.0,
                "expected_score_loss_frac": (END_WINDOW_S / 2.0) / window_s(D),
                "worst_case_score_loss_frac": END_WINDOW_S / window_s(D),
            }
            for D in S13_DURATIONS
        ]
    )

    # -- flip rate: can the sniper overturn an honest leader? -----------------
    # The two honest candidates build continuously toward their own final level
    # over the *whole* round (closing_window_avg_uniform); the sniper's gain
    # uses the same per-draw model as sniper_expected, but for a realised draw
    # of U rather than its expectation.
    def _sniper_gain_per_unit(strategy: str, D: float, U: float) -> float:
        Wc = window_s(D)
        fuzz = END_WINDOW_S
        if strategy == "last_second":
            return max(0.0, S13_SNIPE_AT_S - U) / Wc
        if strategy == "window_sniper":
            return max(0.0, Wc - U) / Wc
        if strategy == "spread_3min":
            surviving = max(0.0, fuzz - U)
            return (surviving**2) / (2.0 * fuzz * Wc)
        raise ValueError(f"unknown sniper strategy {strategy!r}")

    flip_rows = []
    for D in S13_DURATIONS:
        Wc = window_s(D)
        for strategy in ("last_second", "spread_3min", "window_sniper"):
            for random_end in (False, True):
                for mult in S13_CAPITAL_MULTS:
                    net = mult * A_BASE * (1.0 - HOP_FEE_BPS / 1e4)
                    flips = 0
                    for _ in range(trials):
                        a = rng.lognormvariate(0.0, INTEREST_SIGMA)
                        b = rng.lognormvariate(0.0, INTEREST_SIGMA)
                        U = rng.uniform(0.0, END_WINDOW_S) if random_end else 0.0
                        T_end = D - U
                        lead_avg = closing_window_avg_uniform(max(a, b) * A_BASE, D, T_end, Wc)
                        chase_avg = closing_window_avg_uniform(min(a, b) * A_BASE, D, T_end, Wc)
                        gain = net * _sniper_gain_per_unit(strategy, D, U)
                        flips += (chase_avg + gain) > lead_avg
                    flip_rows.append(
                        {
                            "D_human": human(D),
                            "strategy": strategy,
                            "end_rule": "random" if random_end else "fixed",
                            "capital_x_A_BASE": mult,
                            "flip_rate": flips / trials,
                        }
                    )
    flips_df = pd.DataFrame(flip_rows)
    out.tables["flip_rate"] = flips_df

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for D in S13_DURATIONS:
        for strategy, marker in (("last_second", "o-"), ("window_sniper", "^-")):
            for rule in ("fixed", "random"):
                sub = flips_df[
                    (flips_df["D_human"] == human(D))
                    & (flips_df["end_rule"] == rule)
                    & (flips_df["strategy"] == strategy)
                ]
                ax.plot(
                    sub["capital_x_A_BASE"], sub["flip_rate"] * 100, marker,
                    label=f"{strategy}, {human(D)}, {rule} end",
                )
    ax.set_xlabel("sniper capital (x A_BASE)")
    ax.set_ylabel("rounds flipped (%)")
    ax.set_title("Sim 13: last-second vs window sniper, fixed vs random end")
    ax.legend(fontsize=6)
    ax.grid(alpha=0.3)
    save_fig(fig, 13, "flip_rate", out)

    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    sub = value[value["capital_x_A_BASE"] == 1.0]
    keys = [f"{r.strategy}\n{r.D_human}, {r.end_rule}" for r in sub.itertuples()]
    ax.bar(range(len(keys)), sub["score_gain_vs_H0"] * 100)
    ax.set_xticks(range(len(keys)))
    ax.set_xticklabels(keys, fontsize=6)
    ax.set_ylabel("expected score gain (% of H0)")
    ax.set_title("Sim 13: score bought by 1x A_BASE spent in the last 3 minutes")
    ax.grid(alpha=0.3, axis="y")
    save_fig(fig, 13, "sniper_value", out)

    def cell(D, strat, rule, mult=1.0):
        return value[
            (value["D_human"] == human(D))
            & (value["strategy"] == strat)
            & (value["end_rule"] == rule)
            & (value["capital_x_A_BASE"] == mult)
        ].iloc[0]

    def flip(D, strat, rule, mult=1.0):
        return float(
            flips_df[
                (flips_df["D_human"] == human(D))
                & (flips_df["strategy"] == strat)
                & (flips_df["end_rule"] == rule)
                & (flips_df["capital_x_A_BASE"] == mult)
            ]["flip_rate"].iloc[0]
        )

    W15, W12 = window_s(900.0), window_s(43200.0)
    f15 = cell(900.0, "last_second", "fixed")
    r15 = cell(900.0, "last_second", "random")
    s15f = cell(900.0, "spread_3min", "fixed")
    s15r = cell(900.0, "spread_3min", "random")
    w15f = cell(900.0, "window_sniper", "fixed")
    w15r = cell(900.0, "window_sniper", "random")
    f12 = cell(43200.0, "last_second", "fixed")
    r12 = cell(43200.0, "last_second", "random")
    s12f = cell(43200.0, "spread_3min", "fixed")
    s12r = cell(43200.0, "spread_3min", "random")
    w12f = cell(43200.0, "window_sniper", "fixed")
    w12r = cell(43200.0, "window_sniper", "random")
    out.interpretation = (
        f"The scoring window is now flat (maintainer decision 2026-09-12): Wc = closing_window(D) "
        f"= {human(W15)} on every round regardless of D, so the 15-minute and 12-hour rounds share "
        f"exactly the same scoring window instead of the old ``W = 15 min for D <= 1 h, else D/4`` "
        f"rule (still reproducible via ``closing_window(D, old_rule=True)``). With T_end = "
        f"T - (r mod {END_WINDOW_S:.0f} s), i.e. U ~ U[0, {END_WINDOW_S:.0f}), a buy of c at T - s "
        f"scores c*max(0, s - U)/Wc, so the closed forms are E[(s-U)^+] = s^2/(2*fuzz) for a single "
        f"late buy inside the fuzz window and fuzz/3 for capital spread evenly over it. Because Wc "
        f"no longer depends on D, the last-second and spread strategies now price *identically* on "
        f"the 15-minute and 12-hour rounds: a last-second sniper with 1x A_BASE buys "
        f"{float(f15['score_gain_vs_H0']):.2%} of H0 under a fixed end but only "
        f"{float(r15['score_gain_vs_H0']):.3%} under a random end on both durations - "
        f"{float(r15['expected_score_gain_parent']) / float(f15['expected_score_gain_parent']):.1%} "
        f"of the value - because the buy lands before T_end only "
        f"{float(r15['fraction_of_capital_that_scores']):.1%} of the time while the round-trip "
        f"cost of ${float(r15['round_trip_loss_usd']):,.0f} is paid every time (the 12-hour figures "
        f"are {float(f12['score_gain_vs_H0']):.2%} fixed / {float(r12['score_gain_vs_H0']):.3%} "
        f"random, matching within rounding). Spreading the same capital over the whole 3 minutes "
        f"recovers {float(s15r['expected_score_gain_parent']) / float(s15f['expected_score_gain_parent']):.0%} "
        f"of the fixed-end value on both durations ({float(s12r['expected_score_gain_parent']) / float(s12f['expected_score_gain_parent']):.0%} "
        f"on the 12-hour round). The claim is VERIFIED for both durations under the flat window: "
        f"the 3-minute fuzz is a real fraction ({END_WINDOW_S / W15:.1%}) of the *scoring* window on "
        f"every round now, not a vanishing one on the long durations the way ``D/4`` used to make it. "
        f"The **window sniper** - buy at the moment the window opens and hold - is the strictly "
        f"better defensive/offensive strategy on both durations: it scores "
        f"{float(w15f['score_gain_vs_H0']):.1%} of H0 under a fixed end and still "
        f"{float(w15r['score_gain_vs_H0']):.1%} under a random end "
        f"({float(w15r['fraction_of_capital_that_scores']) * 100:.0f}% of the naive full value; "
        f"12-hour figures {float(w12f['score_gain_vs_H0']):.1%} fixed / {float(w12r['score_gain_vs_H0']):.1%} "
        f"random), because with Wc = 15 min >> the {END_WINDOW_S:.0f} s fuzz, the random end can "
        f"only clip a small piece off the *end* of an already-full window, not deny the buy entirely "
        f"the way it denies a last-second snipe. Flip rates on the 15-minute round at 1x A_BASE: "
        f"{flip(900.0, 'last_second', 'fixed'):.1%} fixed -> "
        f"{flip(900.0, 'last_second', 'random'):.1%} random for the last-second buy, "
        f"{flip(900.0, 'spread_3min', 'fixed'):.1%} -> "
        f"{flip(900.0, 'spread_3min', 'random'):.1%} for the spread, and "
        f"{flip(900.0, 'window_sniper', 'fixed'):.1%} -> "
        f"{flip(900.0, 'window_sniper', 'random'):.1%} for the window sniper - by far the most "
        f"dangerous of the three, because it is scored over the *entire* round on the 15-minute "
        f"schedule (Wc = D there). On the 12-hour round the flat window now makes the same window "
        f"sniper genuinely dangerous where the old D/4 rule already made it dangerous, and it also "
        f"lifts the last-second and spread flip rates off the floor they sat at under the old rule: "
        f"{flip(43200.0, 'last_second', 'fixed'):.2%} -> {flip(43200.0, 'last_second', 'random'):.2%} "
        f"for last-second, {flip(43200.0, 'spread_3min', 'fixed'):.1%} -> "
        f"{flip(43200.0, 'spread_3min', 'random'):.1%} for the spread, and "
        f"{flip(43200.0, 'window_sniper', 'fixed'):.1%} -> {flip(43200.0, 'window_sniper', 'random'):.1%} "
        f"for the window sniper at 1x A_BASE under a random end, scoring "
        f"{float(w12r['score_gain_vs_H0']):.2%} of H0 - because a 15-minute closing window on a "
        f"12-hour round is a *smaller*, cheaper-to-defend target in absolute time than the old 3-hour "
        f"window was, so the same capital now buys a larger share of it. Randomness still helps: the "
        f"drand relay only has to beat a sniper who buys at the *nominal* window open, and it costs "
        f"that sniper the expected {END_WINDOW_S / 2:.0f} s of the window every time, on every "
        f"duration. The addendum's own disclosure - 'a coin can lead for hours and lose to one "
        f"pumped and held through the closing window' - is best read through the window sniper, not "
        f"the last-second one; a flat 15-minute window makes that threat model dominant on every "
        f"round, short or long, not just the long ones. This simulation prices the sniper's entry "
        f"and hold only; it does not model the sniper's exit after the round closes, which is the "
        f"maintainer's stated reason for accepting the flat window despite the exposure shown here."
    )
    out.notes = (
        "Score gains are closed-form expectations over U (and over the buy time for the spread "
        "strategy), now divided by the closing window Wc = window_s(D) instead of the round "
        "duration D; the flip MC redraws U per round and scores both honest candidates and the "
        "sniper via closing_window_avg_uniform / the matching per-draw gain, so only the sniper's "
        "timing risk relative to two continuously-accumulating honest candidates is being priced. "
        "Round-trip loss is measured on a real candidate curve (buy the capital in, sell every "
        "token back out), i.e. hop fees both ways plus price impact; the 3-second snipe tax does "
        "not reach this late in a round. The window sniper's 'wasted cost' column is 0 by "
        "definition (it always executes, well before the nominal end) even though its score is "
        "reduced by a random early end; that reduction shows up in score_gain_vs_H0, not in "
        "fraction_of_capital_that_scores."
    )
    return out


# ===========================================================================
# runner
# ===========================================================================
SCENARIOS = {
    11: sim11_purse,
    12: sim12_duration,
    13: sim13_random_end,
}

ORDER = [11, 12, 13]

ASSUMPTIONS = f"""
| assumption | value |
|---|---|
| RNG seed | {SEED} (each scenario uses `Random(SEED + n)`, so `--only n` reproduces `--all`) |
| inherited baseline | every curve, fee, threshold and USD number is imported from `sim.scenarios`, so these tables sit next to `docs/sim-results-final.md` unchanged |
| duration schedule | `D(n) = min(15 min x 2^floor((n-1)/2), 12 h)`, `R(n) = clamp(D/5, 3 min, 1 h)`, late entry in the first `D/3` iff `D >= 1 h` |
| scoring window | closing-window average `W = 15 min` flat, on every round regardless of `D` (maintainer decision 2026-09-12; the old `W = 15 min` for `D <= 1 h` else `D/4` rule is still available via `closing_window(D, old_rule=True)` for comparison); identical for every candidate, including late entrants (`window_s`) |
| random end | `T_end = T - (r mod {END_WINDOW_S:.0f} s)`, `r` uniform, so `U ~ U[0, {END_WINDOW_S:.0f})`; jitters where inside `W` the true end falls, does not change `W` itself |
| purse rule | top 2 siblings by trailing support, proportional, trunk gets no guaranteed share; trailing window `W_gen = window_s(D(g))` of the generation's *own* round `g`, here {S11_W_H:.2g} h |
| purse income | ${EDGE_VOL_USD_PER_ROUND:,.0f} edge volume/round x {PROTOCOL_FEE_BPS / 100:.0f}% x {SLEEVE_SHARE:.0%} ancestor sleeve = ${SLEEVE_USD_PER_ROUND:,.0f}/round; generation {S11_GEN_INDEX} of a depth-{S11_CHAIN_DEPTH} chain at {S11_ROUNDS_PER_DAY:.0f} rounds/day -> ${purse_usd_per_day():,.2f}/day |
| Sim 12 demand | arrivals proportional to `D^{S12_DEMAND_EXPONENT}`, uniform over the window (so the accumulator's time-average is half the total absorbed) |
| parent -> USD | ${USD_PER_GENESIS_TOKEN:.2e} per parent token (equal-depth self-similar convention) |
| threshold | `h = {H_FRAC:.2%}` of parent supply as an *average* absorption, floor {H_FLOOR_FRAC:.0%} |

Scores, thresholds and absorption are **parent-denominated**; only the fee ledger is
quoted in USD.
"""


def run(keys: list[int], scale: Scale = FULL_SCALE) -> list[ScenarioOutput]:
    """Run the scenarios named by ``keys`` (in :data:`ORDER`)."""
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
    """Render ``docs/sim-results-v3.md``."""
    target = (DOCS / "sim-results-v3.md") if path is None else path
    target.parent.mkdir(parents=True, exist_ok=True)
    total = math.fsum(o.seconds for o in outs)
    lines = [
        "# Simulation results - MECHANISM_v3 addendum",
        "",
        "Generated by `python -m sim.scenarios_v3 --all`. Every table here also exists as a CSV "
        "in `docs/results/` (suffix `_v3`) and every figure as a PNG in `docs/figures/`. The ten "
        "baseline scenarios are unchanged and live in `docs/sim-results-final.md`.",
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
    ap = argparse.ArgumentParser(prog="python -m sim.scenarios_v3", description=__doc__)
    ap.add_argument("--all", action="store_true", help="run every v3 scenario")
    ap.add_argument("--only", type=str, default="", help="comma-separated scenario numbers")
    ap.add_argument("--tiny", action="store_true", help="tiny scale (smoke test sizes)")
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

    t0 = time.perf_counter()
    outs = run(keys, scale)
    path = write_report(outs, scale)
    for o in outs:
        print(f"sim {o.key:>2}  {o.seconds:7.1f} s  {o.title}")
    print(f"total {time.perf_counter() - t0:.1f} s -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
