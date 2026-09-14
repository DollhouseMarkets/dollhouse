"""Smoke test: every v3 scenario runs end to end at tiny scale.

Same contract as ``test_scenarios_smoke``: coverage of the wiring (schedule,
purse split, sniper closed forms, figure and CSV writing, the markdown
renderer), not of the economics.  Outputs are redirected into ``tmp_path`` so a
test run never touches ``docs/``.
"""

from __future__ import annotations

import math

import pandas as pd
import pytest

from sim import scenarios_v3 as v3


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    """Point every v3 scenario output at ``tmp_path``."""
    monkeypatch.setattr(v3, "DOCS", tmp_path)
    monkeypatch.setattr(v3, "RESULTS_DIR", tmp_path / "results")
    monkeypatch.setattr(v3, "FIGURES_DIR", tmp_path / "figures")
    return tmp_path


@pytest.mark.parametrize("key", sorted(v3.SCENARIOS))
def test_scenario_runs_tiny(key, sandbox):
    outs = v3.run([key], v3.TINY_SCALE)
    assert len(outs) == 1
    out = outs[0]
    assert out.key == key
    assert out.tables, "a scenario must produce at least one table"
    for name, df in out.tables.items():
        assert isinstance(df, pd.DataFrame)
        assert not df.empty, f"sim {key} table {name} is empty"
    assert out.interpretation.strip(), "every scenario states a verdict"
    assert out.claim.strip()
    for fig in out.figures:
        assert (sandbox / "figures" / fig).exists()
    for name in out.tables:
        assert (sandbox / "results" / f"sim{key:02d}_{name}_v3.csv").exists()


def test_order_covers_every_scenario():
    assert sorted(v3.ORDER) == sorted(v3.SCENARIOS)
    assert min(v3.SCENARIOS) == 11, "the v3 block starts where the baseline block ends"


def test_report_renders(sandbox):
    outs = v3.run([13], v3.TINY_SCALE)
    path = v3.write_report(outs, v3.TINY_SCALE)
    text = path.read_text(encoding="utf-8")
    assert path.name == "sim-results-v3.md"
    assert "## Common assumptions" in text
    assert "Sim 13" in text
    assert outs[0].interpretation[:40] in text


def test_cli_only_parses_and_writes(sandbox, capsys):
    assert v3.main(["--only", "13", "--tiny"]) == 0
    assert (sandbox / "sim-results-v3.md").exists()
    assert "sim 13" in capsys.readouterr().out


def test_cli_rejects_unknown_scenario(sandbox):
    with pytest.raises(SystemExit):
        v3.main(["--only", "1", "--tiny"])


# --------------------------------------------------------------------------
# the v3 rules themselves
# --------------------------------------------------------------------------
@pytest.mark.parametrize(
    "n,D,R,late",
    [
        (1, 900.0, 180.0, 0.0),
        (2, 900.0, 180.0, 0.0),
        (3, 1800.0, 360.0, 0.0),
        (5, 3600.0, 720.0, 1200.0),
        (7, 7200.0, 1440.0, 2400.0),
        (9, 14400.0, 2880.0, 4800.0),
        (11, 28800.0, 3600.0, 9600.0),
        (13, 43200.0, 3600.0, 14400.0),
        (20, 43200.0, 3600.0, 14400.0),
    ],
)
def test_schedule_matches_the_addendum_table(n, D, R, late):
    assert v3.duration_s(n) == pytest.approx(D)
    assert v3.registration_s(n) == pytest.approx(R)
    assert v3.late_entry_s(n) == pytest.approx(late)


def test_schedule_rejects_round_zero():
    with pytest.raises(ValueError):
        v3.duration_s(0)


@pytest.mark.parametrize(
    "D",
    [900.0, 1800.0, 3600.0, 7200.0, 43200.0],
)
def test_window_s_is_flat_15_min_on_every_round(D):
    """Maintainer decision 2026-09-12: W is a flat 15 min regardless of D."""
    assert v3.window_s(D) == pytest.approx(900.0)
    assert v3.closing_window(D) == pytest.approx(900.0)


@pytest.mark.parametrize(
    "D,W",
    [
        (900.0, 900.0),      # <= 1 h: W = 15 min = the whole round
        (1800.0, 900.0),
        (3600.0, 900.0),     # exactly 1 h: still the 15-min floor
        (7200.0, 1800.0),    # > 1 h: W = D/4
        (43200.0, 10800.0),  # the 12-h round: W = 3 h
    ],
)
def test_window_s_old_rule_matches_the_addendum(D, W):
    """The pre-2026-09-12 rule is still reproducible via old_rule=True, for comparison."""
    assert v3.window_s(D, old_rule=True) == pytest.approx(W)
    assert v3.closing_window(D, old_rule=True) == pytest.approx(W)


def test_closing_window_avg_uniform_is_the_mean_of_the_window_endpoints():
    # a candidate ramping 0 -> 100 over [0, 100], window [80, 100]: endpoints
    # are 80 and 100, so the average is 90
    assert v3.closing_window_avg_uniform(100.0, 100.0, 100.0, 20.0) == pytest.approx(90.0)
    # an early true end (random end) shrinks both the level reached and the
    # window average
    assert v3.closing_window_avg_uniform(100.0, 100.0, 50.0, 20.0) == pytest.approx(40.0)
    # a window wider than the elapsed time clamps to [0, T_end]
    assert v3.closing_window_avg_uniform(100.0, 100.0, 10.0, 1000.0) == pytest.approx(5.0)


def test_late_entrant_scores_equal_to_early_coin_by_construction():
    """v3 S2: the closing window is identical for every candidate, so a coin that
    finishes deploying its capital before the window opens scores exactly its
    level, independent of when it finished -- the own-window bonus is gone."""
    D, W = v3.duration_s(9), v3.window_s(v3.duration_s(9))
    late_entry = v3.late_entry_s(9)
    C = 1234.0
    early = v3.closing_window_score_plateau(C, deploy_finish=0.0, D=D, W=W)
    late = v3.closing_window_score_plateau(C, deploy_finish=late_entry, D=D, W=W)
    assert early == pytest.approx(C)
    assert late == pytest.approx(C)
    assert early == pytest.approx(late)


def test_closing_window_score_plateau_penalises_still_filling_at_the_window_open():
    D, W = 3600.0, 900.0
    # finishes exactly when the window opens: full credit
    assert v3.closing_window_score_plateau(100.0, D - W, D, W) == pytest.approx(100.0)
    # finishes halfway through the window: half credit (linear ramp)
    assert v3.closing_window_score_plateau(100.0, D - W / 2.0, D, W) == pytest.approx(25.0)


def test_purse_goes_to_the_top_two_only_and_is_proportional():
    shares = v3.purse_split([10.0, 30.0, 5.0, 1.0])
    assert shares[1] == pytest.approx(0.75)
    assert shares[0] == pytest.approx(0.25)
    assert shares[2] == 0.0 and shares[3] == 0.0
    assert math.fsum(shares) == pytest.approx(1.0)


def test_purse_split_handles_fewer_than_two_and_dead_generations():
    assert v3.purse_split([7.0]) == [1.0]
    assert v3.purse_split([0.0, 0.0]) == [0.0, 0.0]


def test_late_entry_uplift_is_exactly_three_halves():
    """A burst at D/3 scores 1.5x what the v2 full-window rule would give it."""
    for n in (5, 7, 9, 11, 13):
        D, le = v3.duration_s(n), v3.late_entry_s(n)
        assert D / (D - le) == pytest.approx(1.5)


def test_sniper_closed_forms():
    D = 900.0  # Wc = window_s(900) = 900 = D, so the numbers match the pre-rewrite values
    fixed, frac = v3.sniper_expected("last_second", D, random_end=False)
    assert fixed == pytest.approx(v3.S13_SNIPE_AT_S / D) and frac == 1.0
    rand, frac = v3.sniper_expected("last_second", D, random_end=True)
    # E[(10 - U)^+] = 100 / 360 s, and only 10/180 of draws score at all
    assert rand == pytest.approx((100.0 / 360.0) / D)
    assert frac == pytest.approx(10.0 / 180.0)
    assert rand < fixed
    spread_f, _ = v3.sniper_expected("spread_3min", D, random_end=False)
    spread_r, spread_frac = v3.sniper_expected("spread_3min", D, random_end=True)
    assert spread_f == pytest.approx(90.0 / D)
    assert spread_r == pytest.approx(60.0 / D)      # W/3 with s, U iid U[0, W]
    assert spread_frac == pytest.approx(0.5)
    with pytest.raises(ValueError):
        v3.sniper_expected("nope", D, random_end=True)


def test_sniper_expected_uses_the_closing_window_not_the_round_duration():
    D = 43200.0  # 12 h round: Wc = 15 min flat (new rule), not D
    Wc = v3.window_s(D)
    assert Wc == pytest.approx(900.0)
    assert Wc != D
    fixed, frac = v3.sniper_expected("last_second", D, random_end=False)
    assert fixed == pytest.approx(v3.S13_SNIPE_AT_S / Wc) and frac == 1.0


def test_window_sniper_scores_nearly_everything_even_under_a_random_end():
    D = 900.0
    fixed, frac = v3.sniper_expected("window_sniper", D, random_end=False)
    assert fixed == pytest.approx(1.0) and frac == 1.0  # buys the window open, holds to a fixed end
    rand, frac = v3.sniper_expected("window_sniper", D, random_end=True)
    assert rand == pytest.approx(1.0 - v3.END_WINDOW_S / (2.0 * v3.window_s(D)))
    assert frac == 1.0  # it always executes; a random end only trims the tail, never denies it
    assert 0.0 < rand < fixed


def test_sibling_accumulator_falls_when_it_is_dumped():
    s = v3.Sibling(0, 1.0, v3.candidate_pool())
    s.buy(1e6)
    peak = s.R
    assert peak > 0.0 and s.tokens > 0.0
    s.sell_tokens(s.tokens * 0.9)
    assert s.R < peak
    assert s.buy(0.0) == 0.0
    assert s.sell_tokens(0.0) == 0.0


def test_trailing_average_is_the_window_mean():
    series = [1.0, 2.0, 3.0, 4.0]
    assert v3.trailing_average(series, 3, 2) == pytest.approx(3.5)
    assert v3.trailing_average(series, 0, 2) == pytest.approx(1.0)  # short prefix


def test_purse_income_is_the_baseline_ledger():
    """One generation's purse is its ancestor weight of the Sim 1/6/10 sleeve."""
    assert v3.SLEEVE_USD_PER_ROUND == pytest.approx(500.0)
    assert 0.0 < v3.purse_usd_per_day() < v3.SLEEVE_USD_PER_ROUND
