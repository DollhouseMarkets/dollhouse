"""Smoke test: every scenario runs end to end at tiny scale.

The point is coverage of the wiring -- registration, agents, routing, fee
allocation, figure and CSV writing, the markdown renderer -- not of the
economics, which the per-module tests cover.  Outputs are redirected into
``tmp_path`` so a test run never touches ``docs/``.
"""

from __future__ import annotations

import random

import pandas as pd
import pytest

from sim import scenarios


@pytest.fixture
def sandbox(tmp_path, monkeypatch):
    """Point every scenario output at ``tmp_path``."""
    monkeypatch.setattr(scenarios, "DOCS", tmp_path)
    monkeypatch.setattr(scenarios, "RESULTS_DIR", tmp_path / "results")
    monkeypatch.setattr(scenarios, "FIGURES_DIR", tmp_path / "figures")
    return tmp_path


@pytest.mark.parametrize("key", sorted(scenarios.SCENARIOS))
def test_scenario_runs_tiny(key, sandbox):
    outs = scenarios.run([key], scenarios.TINY_SCALE)
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
        assert (sandbox / "results" / f"sim{key:02d}_{name}.csv").exists()


def test_order_covers_every_scenario():
    assert sorted(scenarios.ORDER) == sorted(scenarios.SCENARIOS)
    assert scenarios.ORDER[0] == 4, "Sim 4 is the headline and runs first"


def test_report_renders(sandbox):
    outs = scenarios.run([10], scenarios.TINY_SCALE)
    path = scenarios.write_report(outs, scenarios.TINY_SCALE)
    text = path.read_text(encoding="utf-8")
    assert "## Common assumptions" in text
    assert "Sim 10" in text
    assert outs[0].interpretation[:40] in text


def test_cli_only_parses_and_writes(sandbox, capsys):
    assert scenarios.main(["--only", "10", "--tiny"]) == 0
    assert (sandbox / "sim-results.md").exists()
    assert "sim 10" in capsys.readouterr().out


def test_cli_rejects_unknown_scenario(sandbox):
    with pytest.raises(SystemExit):
        scenarios.main(["--only", "99", "--tiny"])


def test_cli_ladder_hop_bps_and_reset_on_win_override(sandbox):
    """--curve ladder/--h/--hop-bps/--reset-on-win reach every scenario's chain builders."""
    assert scenarios.CLI_HOP_BPS_OVERRIDE is None
    assert scenarios.CLI_RESET_ON_WIN is True
    try:
        assert (
            scenarios.main(
                [
                    "--only",
                    "3,7,8,9",
                    "--tiny",
                    "--curve",
                    "ladder",
                    "--h",
                    "0.15",
                    "--hop-bps",
                    "12.0",
                    "--no-reset-on-win",
                    "--final",
                ]
            )
            == 0
        )
        assert scenarios.CLI_CURVE_OVERRIDE == "ladder"
        assert scenarios.CLI_H_OVERRIDE_PCT == 0.15
        assert scenarios.CLI_HOP_BPS_OVERRIDE == 12.0
        assert scenarios.CLI_RESET_ON_WIN is False
        assert (sandbox / "sim-results-final.md").exists()
        chain = scenarios.reference_chain(3)
        assert chain.links[0].pool.hop_fee_bps == pytest.approx(12.0)
    finally:
        scenarios.CLI_CURVE_OVERRIDE = None
        scenarios.CLI_H_OVERRIDE_PCT = None
        scenarios.CLI_HOP_BPS_OVERRIDE = None
        scenarios.CLI_RESET_ON_WIN = True
        scenarios.OUTPUT_SUFFIX = ""


def test_reference_chain_ladder_shape_differs_from_standard():
    standard = scenarios.reference_chain(2)
    scenarios.CLI_CURVE_OVERRIDE = "ladder"
    try:
        ladder = scenarios.reference_chain(2)
    finally:
        scenarios.CLI_CURVE_OVERRIDE = None
    # Same target ETH-equivalent reserve, different curve shape -> different
    # cost to reach the same FDV multiple (the whole point of switching the
    # baseline shape).
    target = standard.links[0].pool.fdv() * 2.0
    assert standard.links[0].pool.quote_cost_to_fdv(target) != pytest.approx(
        ladder.links[0].pool.quote_cost_to_fdv(target)
    )


def test_seeding_is_reproducible(sandbox):
    a = scenarios.SCENARIOS[10](scenarios.TINY_SCALE, random.Random(scenarios.SEED + 10))
    b = scenarios.SCENARIOS[10](scenarios.TINY_SCALE, random.Random(scenarios.SEED + 10))
    pd.testing.assert_frame_equal(a.tables["genesis_share"], b.tables["genesis_share"])
    assert a.interpretation == b.interpretation


def test_flatten_pool_preserves_closed_forms():
    """The overlap flattener must not move any reserve or price."""
    chain = scenarios.reference_chain(3)
    pool = chain.links[2].pool
    F = pool.fdv()
    pool.add_locked_position(F * 0.8, F, parent_amount=pool.reserve_parent() * 0.01)
    flat = scenarios.flatten_pool(pool)
    assert flat.price == pytest.approx(pool.price)
    assert flat.reserve_parent() == pytest.approx(pool.reserve_parent(), rel=1e-9)
    assert flat.tokens_remaining() == pytest.approx(pool.tokens_remaining(), rel=1e-9)
    assert flat.quote_cost_to_fdv(F * 0.5) == pytest.approx(
        pool.quote_cost_to_fdv(F * 0.5), rel=1e-9
    )
    # ...and, unlike the overlapping original, it must not lose liquidity on a sell
    tokens = pool.tokens_sold() * 0.05
    got_flat = flat.swap_exact_in(tokens, parent_in=False)
    got_raw = pool.swap_exact_in(tokens, parent_in=False)
    assert got_flat.amount_out > got_raw.amount_out
