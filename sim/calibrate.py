"""Calibrate the standard curve and win threshold ``h`` so a winner is not
exhausted at the threshold.

Sim 1 (``docs/sim-results.md``) found that clearing a threshold ``h`` (an
*average* absorption over the 600 s trading window) requires a winner to
absorb roughly 2.9x that threshold in *total*, and that the self-similar
SINGLE-like standard curve cannot survive that: the median winner ends up
with ~98.7% of its supply sold and an FDV far above its own parent's, backed
by a thin sliver of real reserve.

This script prints, for a given curve spec and parent supply, the FDV
multiple, supply sold fraction, and embedded-parent backing fraction a
winner would land at when absorbing ``2.9 * h`` total -- for a sweep of
candidate thresholds ``h`` -- so a threshold/curve pair can be picked where
the winner is nowhere near exhausting the curve.

Run::

    python -m sim.calibrate
"""

from __future__ import annotations

import argparse

import pandas as pd

from .curves import Spec, build_pool, self_similar, self_similar_ladder

# Sim 1's measured average-to-total ratio: a winner clearing an *average*
# absorption threshold h over the full window has absorbed ~2.9x h in total
# by the time the window closes (docs/sim-results.md, Sim 1 interpretation).
AVG_TO_TOTAL_RATIO = 2.9

H_FRACS_PCT = (0.05, 0.1, 0.15, 0.2, 0.3, 0.5)  # % of parent supply


def calibration_table(
    spec: Spec,
    parent_supply: float = 1e9,
    h_fracs_pct: tuple[float, ...] = H_FRACS_PCT,
    avg_to_total_ratio: float = AVG_TO_TOTAL_RATIO,
    hop_fee_bps: float = 0.0,
) -> pd.DataFrame:
    """One row per candidate threshold ``h`` (fee-free, exact closed form)."""
    cap_pool = build_pool(spec, parent_supply, hop_fee_bps=hop_fee_bps, fee_on="parent")
    max_absorption = cap_pool.max_absorption()

    rows = []
    for h_pct in h_fracs_pct:
        h_frac = h_pct / 100.0
        h0 = h_frac * parent_supply  # average absorption threshold, parent units
        total_absorption = avg_to_total_ratio * h0

        pool = build_pool(spec, parent_supply, hop_fee_bps=hop_fee_bps, fee_on="parent")
        pool.swap_exact_in(total_absorption, parent_in=True)

        fdv = pool.fdv()
        sold_frac = pool.tokens_sold() / parent_supply
        reserve = pool.reserve_parent()
        backing_frac = reserve / fdv if fdv else float("nan")

        rows.append(
            {
                "h_pct_of_parent_supply": h_pct,
                "h0_avg_absorption_parent": h0,
                "total_absorption_needed_parent": total_absorption,
                "fdv_parent": fdv,
                "fdv_vs_parent_multiple": fdv / parent_supply,
                "supply_sold_frac": sold_frac,
                "embedded_backing_frac": backing_frac,
                "max_absorption_parent": max_absorption,
                "total_absorption_frac_of_max": total_absorption / max_absorption,
            }
        )
    return pd.DataFrame(rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m sim.calibrate", description=__doc__)
    ap.add_argument("--parent-supply", type=float, default=1e9)
    args = ap.parse_args(argv)
    supply = args.parent_supply

    specs = {
        "SINGLE-like self-similar": self_similar(supply),
        "LADDER": self_similar_ladder(supply),
    }
    for name, spec in specs.items():
        print(f"\n=== {name} ===")
        df = calibration_table(spec, supply)
        with pd.option_context("display.width", 200, "display.float_format", "{:.4g}".format):
            print(df.to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
