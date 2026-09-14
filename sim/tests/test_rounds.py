"""Round engine + agent tests: gate, snipe tax, scoring, submission, finalize."""

from __future__ import annotations

import math
import random

import pytest

from sim.agents import Attacker, simulate_round
from sim.rounds import (
    CANDIDATE_PROTOCOL_FEE_BPS,
    Phase,
    Round,
    RoundConfig,
    RoundError,
    assert_reachable,
    wall_fdv,
)

HOP_BPS = 7.5


def cfg(**kw) -> RoundConfig:
    base = dict(hop_fee_bps=HOP_BPS, h_threshold_frac=0.005)
    base.update(kw)
    return RoundConfig(**base)


def fresh(**kw) -> Round:
    c = cfg(**kw)
    r = Round(c)
    r.register("alice", 0.0)
    return r


# --------------------------------------------------------------------------
# (a) gate
# --------------------------------------------------------------------------
def test_pool_is_gated_before_trading_start() -> None:
    r = fresh()
    assert r.phase(0.0) == Phase.REGISTRATION
    for t in (0.0, 100.0, r.trading_start - 1e-9):
        with pytest.raises(RoundError, match="gated"):
            r.swap(0, 1_000.0, True, t)
    ex = r.swap(0, 1_000.0, True, r.trading_start)
    assert ex.tokens_bought > 0.0
    assert r.phase(r.trading_start) == Phase.TRADING


def test_registration_closes_at_registration_end() -> None:
    r = fresh()
    with pytest.raises(RoundError, match="registration closed"):
        r.register("bob", r.registration_end)
    assert r.candidates[0].pool.hop_fee_bps == HOP_BPS
    assert r.candidates[0].pool.fee_on == "parent"


# --------------------------------------------------------------------------
# (b) snipe tax
# --------------------------------------------------------------------------
def test_snipe_tax_schedule() -> None:
    c = cfg()
    # brief curve: 99% -> 1% linearly across the first 3 s.  The decay factor at
    # 0.1 s is 1 - 0.1/3 = 96.67%, i.e. tax = 0.01 + 0.98 * 0.9667 = 95.73%.
    assert c.snipe_tax(0.0) == pytest.approx(0.99)
    assert 1.0 - 0.1 / c.snipe_s == pytest.approx(0.9667, abs=1e-4)
    assert c.snipe_tax(0.1) == pytest.approx(0.9573, abs=1e-4)
    assert c.snipe_tax(c.snipe_s) == pytest.approx(0.01)
    # the tax is only levied inside the window; after 3 s there is none
    assert c.applied_snipe_tax(0.1) == pytest.approx(c.snipe_tax(0.1))
    assert c.applied_snipe_tax(3.0) == 0.0
    assert c.applied_snipe_tax(3.1) == 0.0


def test_snipe_tax_bites_the_first_block_buy() -> None:
    r = fresh()
    q = 1e5
    ex = r.swap(0, q, True, r.trading_start + 0.1)
    assert ex.snipe_tax_rate == pytest.approx(0.9573, abs=1e-4)
    assert ex.snipe_fee == pytest.approx(q * ex.snipe_tax_rate)
    # only ~4.3% of the capital reaches the curve (and scores)
    assert ex.net_parent_in == pytest.approx(q * (1 - ex.snipe_tax_rate) * (1 - HOP_BPS / 1e4))


def test_exponential_snipe_variant_hits_the_same_endpoints() -> None:
    c = cfg(snipe_decay="exponential")
    assert c.snipe_tax(0.0) == pytest.approx(0.99)
    assert c.snipe_tax(3.0) == pytest.approx(0.01)
    assert c.snipe_tax(1.5) == pytest.approx(math.sqrt(0.99 * 0.01))
    assert c.snipe_tax(0.1) < cfg().snipe_tax(0.1)  # decays faster early


# --------------------------------------------------------------------------
# (c) a lone self-funder only loses fees
# --------------------------------------------------------------------------
def test_candidate_pools_charge_no_protocol_fee() -> None:
    r = fresh()
    ex = r.swap(0, 1e5, True, r.trading_start + 5.0)
    assert CANDIDATE_PROTOCOL_FEE_BPS == 0.0
    assert ex.protocol_fee == 0.0  # family<->family: no ETH edge, no 1% fee


@pytest.mark.parametrize("C", [1e3, 1e5, 5e6])
def test_lone_self_funder_loses_only_fees(C: float) -> None:
    r = fresh()
    buy = r.swap(0, C, True, r.trading_start + 3.1, trader="atk")
    assert buy.snipe_fee == 0.0
    sell = r.swap(0, buy.tokens_bought, False, r.t_end + 1.0, trader="atk")
    loss = buy.parent_spent - sell.parent_received
    fees = buy.hop_fee + sell.hop_fee + buy.protocol_fee + sell.protocol_fee
    assert abs(loss - fees) < 1e-9 * C
    f = HOP_BPS / 1e4
    assert sell.parent_received == pytest.approx(C * (1 - f) ** 2, rel=1e-12)
    # the exit is after T_end, so it cannot claw back the score
    assert sell.scored is False
    assert r.candidates[0].R == pytest.approx(buy.net_parent_in)


def test_self_funder_pnl_decomposition_is_exact() -> None:
    C = 2e6
    res = simulate_round(
        cfg(), [Attacker.self_fund_win(capital=C)], random.Random(0), dt=1.0
    )
    p = next(iter(res.attacker_pnl.values()))
    assert p.capital == pytest.approx(C)
    assert p.snipe_fees == 0.0
    assert p.protocol_fees == 0.0
    assert p.tokens_held == {}
    assert p.mark_to_market == 0.0
    assert p.price_impact_loss == pytest.approx(0.0, abs=1e-9 * C)
    assert p.round_trip_loss == pytest.approx(p.fees_paid, abs=1e-9 * C)


def test_block1_sweep_pays_the_snipe_tax() -> None:
    res = simulate_round(
        cfg(),
        [Attacker.self_fund_win(capital=1e5), Attacker.block1_sweep(capital_per_candidate=1e5)],
        random.Random(1),
        dt=1.0,
    )
    sweep = res.pnl["attacker:block1_sweep"]
    assert sweep.snipe_fees == pytest.approx(1e5 * 0.9573, abs=10.0)
    assert res.pnl["attacker:self_fund_win"].snipe_fees == 0.0


# --------------------------------------------------------------------------
# (d) submission ordering
# --------------------------------------------------------------------------
def test_first_submitter_cannot_exclude_a_better_candidate() -> None:
    c = cfg(h_threshold_frac=0.0)  # isolate the ordering rule from the threshold
    r = Round(c)
    r.register("weak", 0.0)   # id 0
    r.register("strong", 0.0)  # id 1
    r.swap(0, 1e5, True, r.trading_start + 10.0)
    r.swap(1, 1e6, True, r.trading_start + 10.0)
    weak = r.submit(0, r.t_end)             # submitted first
    strong = r.submit(1, r.submit_end - 1)  # still inside the window
    assert weak.avg < strong.avg
    with pytest.raises(RoundError, match="finalize before window end"):
        r.finalize(r.submit_end - 1e-9)
    out = r.finalize(r.submit_end)
    assert out.winner == 1
    assert r.finalize(r.submit_end + 100) is out  # idempotent
    # bonds: winner refunded, losers forfeited to the genesis bid
    assert out.refunded_bond_eth == pytest.approx(c.bond_eth)
    assert out.forfeited_bond_eth == pytest.approx(c.bond_eth)
    assert r.genesis_bid_eth == pytest.approx(c.bond_eth)


def test_submit_outside_the_window_reverts() -> None:
    r = fresh()
    r.swap(0, 1e6, True, r.trading_start + 1.0)
    with pytest.raises(RoundError, match="submitScore outside"):
        r.submit(0, r.t_end - 1e-9)
    with pytest.raises(RoundError, match="submitScore outside"):
        r.submit(0, r.submit_end)


# --------------------------------------------------------------------------
# (e) no-winner decay and floor
# --------------------------------------------------------------------------
def test_no_winner_decays_h_and_floors_at_quarter() -> None:
    c = cfg()
    h = None
    r = Round(c)
    h0 = r.h0
    seen = []
    for _ in range(60):
        r = Round(c, h_current=h)
        r.register("nobody", 0.0)
        out = r.finalize(r.submit_end)  # nothing submitted -> no winner
        assert out.winner is None
        assert out.forfeited_bond_eth == pytest.approx(c.bond_eth)
        h = out.h_next
        seen.append(h)
    assert seen[0] == pytest.approx(0.9 * h0)
    assert seen[1] == pytest.approx(0.81 * h0)
    assert min(seen) == pytest.approx(0.25 * h0)
    assert h == pytest.approx(0.25 * h0)  # floored, never zero


def test_win_resets_h_to_h0_by_default_but_not_when_disabled() -> None:
    c = cfg()
    r = Round(c)
    r.register("nobody", 0.0)
    out = r.finalize(r.submit_end)  # no winner -> H decays once
    assert out.winner is None
    h_after_fail = out.h_next
    assert h_after_fail == pytest.approx(0.9 * r.h0)

    # reset_on_win=True (default): a win snaps H back to H0, not the decayed
    # value it just had to clear.
    assert c.reset_on_win is True
    r2 = Round(c, h_current=h_after_fail)
    r2.register("winner", 0.0)
    r2.swap(0, 1e8, True, r2.trading_start + c.snipe_s)  # comfortably clears H
    r2.submit(0, r2.t_end)
    out2 = r2.finalize(r2.submit_end)
    assert out2.winner == 0
    assert out2.h_next == pytest.approx(r2.h0)

    # reset_on_win=False: old behaviour -- a win carries the decayed H over.
    c_no_reset = cfg(reset_on_win=False)
    r3 = Round(c_no_reset, h_current=h_after_fail)
    r3.register("winner", 0.0)
    r3.swap(0, 1e8, True, r3.trading_start + c_no_reset.snipe_s)
    r3.submit(0, r3.t_end)
    out3 = r3.finalize(r3.submit_end)
    assert out3.winner == 0
    assert out3.h_next == pytest.approx(h_after_fail)


def test_winner_requires_reaching_h() -> None:
    c = cfg()
    r = Round(c)
    r.register("small", 0.0)
    r.swap(0, 1e5, True, r.trading_start)  # far below H
    r.submit(0, r.t_end)
    out = r.finalize(r.submit_end)
    assert out.winner is None
    assert out.h_next == pytest.approx(0.9 * r.h0)


# --------------------------------------------------------------------------
# (f) tail extension
# --------------------------------------------------------------------------
def test_accumulator_tail_extension() -> None:
    r = fresh()
    ex = r.swap(0, 1e6, True, r.trading_start + 100.0)
    sub = r.submit(0, r.t_end)
    R = ex.net_parent_in
    T = r.config.trading_s
    assert r.candidates[0].R == pytest.approx(R)
    assert sub.avg == pytest.approx(R * (T - 100.0) / T, rel=1e-12)
    assert sub.t_first_attained == pytest.approx(r.trading_start + 100.0)
    series = r.candidates[0].r_series(r.trading_start, r.t_end, 1.0)
    assert len(series) == int(T) + 1
    assert series[99][1] == 0.0
    assert series[100][1] == pytest.approx(R)
    assert series[-1][1] == pytest.approx(R)


def test_post_t_end_trading_cannot_move_the_score() -> None:
    r = fresh()
    ex = r.swap(0, 1e6, True, r.trading_start + 100.0)
    before = r.candidates[0].running_avg(r.t_end, r.config.trading_s)
    r.swap(0, ex.tokens_bought, False, r.t_end + 0.5)  # dump after the bell
    assert r.candidates[0].running_avg(r.t_end, r.config.trading_s) == pytest.approx(before)
    assert r.candidates[0].t_last == pytest.approx(r.trading_start + 100.0)


# --------------------------------------------------------------------------
# (g) late spike
# --------------------------------------------------------------------------
def test_late_spike_adds_size_over_duration() -> None:
    S = 3e6
    r = fresh()
    T = r.config.trading_s
    ex = r.swap(0, S, True, r.t_end - 1.0)
    sub = r.submit(0, r.t_end)
    assert sub.avg == pytest.approx(ex.net_parent_in * 1.0 / T, rel=1e-12)
    assert sub.avg == pytest.approx(S / T, rel=1e-3)  # only the hop fee is lost


def test_late_spike_agent_matches_the_manual_swap() -> None:
    S = 3e6
    c = cfg()
    res = simulate_round(c, [Attacker.late_spike(capital=S)], random.Random(2), dt=1.0)
    avg = res.scores[0]
    assert avg == pytest.approx(S / c.trading_s, rel=1e-3)
    p = res.attacker_pnl["attacker:late_spike"]
    assert p.capital == pytest.approx(S)
    assert p.price_impact_loss == pytest.approx(0.0, abs=1e-9 * S)


# --------------------------------------------------------------------------
# (h) tie rule
# --------------------------------------------------------------------------
def test_tie_broken_by_earlier_attainment_then_lower_id() -> None:
    c = cfg(h_threshold_frac=0.0)
    r = Round(c)
    for who in ("a", "b", "c"):
        r.register(who, 0.0)
    q = 1e6
    r.swap(0, q, True, r.trading_start + 200.0)
    r.swap(1, q, True, r.trading_start + 100.0)  # same size, earlier -> higher avg
    r.swap(2, q, True, r.trading_start + 200.0)  # exact tie with candidate 0
    for cid in (2, 1, 0):
        r.submit(cid, r.t_end + 1.0)
    assert r.submissions[0].avg == pytest.approx(r.submissions[2].avg, rel=1e-12)
    assert r.submissions[1].avg > r.submissions[0].avg
    out = r.finalize(r.submit_end)
    assert out.winner == 1  # higher average wins outright
    # strip the earlier-attainment winner: 0 and 2 tie on avg -> lower id wins
    r2 = Round(c)
    for who in ("a", "b"):
        r2.register(who, 0.0)
    r2.swap(1, q, True, r2.trading_start + 200.0)
    r2.swap(0, q, True, r2.trading_start + 200.0)
    for cid in (1, 0):
        r2.submit(cid, r2.t_end + 1.0)
    assert r2.finalize(r2.submit_end).winner == 0
    # and attainment beats id
    r3 = Round(c)
    for who in ("a", "b"):
        r3.register(who, 0.0)
    T = c.trading_s
    r3.swap(1, q, True, r3.trading_start + 100.0)
    r3.swap(0, q * (T - 100) / (T - 300), True, r3.trading_start + 300.0)
    for cid in (0, 1):
        r3.submit(cid, r3.t_end + 1.0)
    assert r3.submissions[0].avg == pytest.approx(r3.submissions[1].avg, rel=1e-9)
    assert r3.finalize(r3.submit_end).winner == 1  # earlier t_first_attained


def test_finalize_is_deterministic_across_submission_orders() -> None:
    c = cfg(h_threshold_frac=0.0)
    winners = set()
    for order in ([0, 1, 2], [2, 1, 0], [1, 0, 2]):
        r = Round(c)
        for who in ("a", "b", "c"):
            r.register(who, 0.0)
        r.swap(0, 2e6, True, r.trading_start + 200.0)
        r.swap(1, 2e6, True, r.trading_start + 200.0)
        r.swap(2, 1e6, True, r.trading_start + 10.0)
        for cid in order:
            r.submit(cid, r.t_end + 5.0)
        winners.add(r.finalize(r.submit_end).winner)
    assert len(winners) == 1


# --------------------------------------------------------------------------
# reachability invariant
# --------------------------------------------------------------------------
def test_assert_reachable_holds_for_the_default_threshold() -> None:
    c = cfg()
    r = Round(c)
    assert r.h0 == pytest.approx(c.h_threshold_frac * c.parent_supply)
    absorption = assert_reachable(c.curve_spec, r.h0, supply=c.parent_supply)
    assert r.h0 <= 0.25 * absorption
    assert wall_fdv(c.curve_spec) == c.curve_spec[-2][2]
    with pytest.raises(AssertionError):
        assert_reachable(c.curve_spec, absorption, supply=c.parent_supply)


def test_a_reachable_threshold_can_actually_be_met() -> None:
    c = cfg()
    r = Round(c)
    r.register("whale", 0.0)
    # buy just past the snipe window and hold: the tail extension carries the
    # average up to (essentially) the whole position
    r.swap(0, r.h0 * 1.05, True, r.trading_start + 3.1)
    sub = r.submit(0, r.t_end)
    assert sub.avg >= r.h0
    assert r.finalize(r.submit_end).winner == 0


# --------------------------------------------------------------------------
# agent framework smoke test
# --------------------------------------------------------------------------
def test_simulate_round_runs_a_mixed_population() -> None:
    from sim.agents import Creator, MomentumTrader, NoiseTrader, PanicSeller

    agents = [
        Creator(self_buy_eth_equiv=5e5, timing=4.0, name="creator-0"),
        Creator(self_buy_eth_equiv=2e6, timing=4.0, name="creator-1"),
        NoiseTrader(0.2, mu=math.log(2e4), sigma=1.0, buy_prob=0.6),
        MomentumTrader(lookback_s=30.0, threshold=0.05, size=5e4),
        PanicSeller(trigger_drawdown=0.1, exit_frac=0.5, seed_buy=1e5),
        Attacker.dynastic(capital=3e6),
    ]
    c = cfg()
    res = simulate_round(c, agents, random.Random(7), dt=1.0)
    assert len(res.round.candidates) == 3
    assert set(res.scores) == set(res.round.candidates)
    assert all(len(p) == int(c.trading_s) + 1 for p in res.r_paths.values())
    assert all(
        len(p) == int(c.trading_s + c.submit_window_s) + 1 for p in res.reserve_paths.values()
    )
    dyn = res.attacker_pnl["attacker:dynastic"]
    assert dyn.capital == pytest.approx(3e6)
    assert dyn.tokens_held  # dynastic capture keeps the position
    assert dyn.mark_to_market > 0.0
    assert res.winner == res.outcome.winner
    for p in res.pnl.values():
        assert p.round_trip_loss == pytest.approx(p.fees_paid + p.price_impact_loss)
