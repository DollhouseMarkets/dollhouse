// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice INSTANT TRADING. Every candidate's pool opens at its own registration; the round clock
/// (registration close, trading, random end, closing window) is unchanged, and every candidate is
/// scored over the same span `[max(T_end - W, r.tradingStart), T_end]`. These run on ROUND 1, a
/// short round (`W >= D`), which is where the floor at `r.tradingStart` actually binds.
///
/// Note on exactness: `starts[i] == r.tradingStart` below is EXACT only because nothing was
/// swapped on both sides of `r.tradingStart` within the same coarse slot in these tests. In
/// general `averageOver`'s start edge, like its end edge, resolves to within one coarse slot
/// (`scoreSlotFor(n)`, 18 s on the mainnet schedule) when a swap falls on each side of the
/// boundary in the same slot — see PROTOCOL_SPEC.md §F, "Exactness bound".
contract InstantTradingTest is RoundTestBase {
    /// @dev `T_end = T - 100`: on a ten-minute round (`D = 420 s`) puts `T_end - W` 580 s BEFORE
    /// the round clock, so an unfloored window would reach back into registration and beyond.
    uint256 internal constant END_WORD = 100;

    function setUp() public {
        _setUpFamily();
        _fundDoll(address(this), 1_000_000_000e18);
        IERC20(address(doll)).approve(address(swapRouter), type(uint256).max);
    }

    function _isShortRound(uint256 roundId) internal view {
        assertGe(roundManager.closingWindowFor(roundId), roundManager.durationFor(roundId), "a short round: W >= D");
        assertEq(roundManager.lateEntryUntil(roundId), 0, "no late entry on a short round");
    }

    /// @dev Submit `ids` and return the `tStartUsed` / `tEndUsed` each {RoundManager.ScoreSubmitted} carried.
    function _submitAll(uint256[] memory ids)
        internal
        returns (int256[] memory avgs, uint64[] memory starts, uint64[] memory ends)
    {
        avgs = new int256[](ids.length);
        starts = new uint64[](ids.length);
        ends = new uint64[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            vm.recordLogs();
            roundManager.submitScore(ids[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool seen;
            for (uint256 k = 0; k < logs.length; k++) {
                if (logs[k].emitter != address(roundManager) || logs[k].topics[0] != RoundManager.ScoreSubmitted.selector)
                {
                    continue;
                }
                assertEq(uint256(logs[k].topics[2]), ids[i], "the event is for this candidate");
                (avgs[i],, starts[i], ends[i],) = abi.decode(logs[k].data, (int256, uint64, uint64, uint64, address));
                seen = true;
            }
            assertTrue(seen, "ScoreSubmitted emitted");
        }
    }

    /// @notice THE FLOOR. Two round-1 candidates registered two minutes apart, both traded before
    /// and after the clock: each is scored from exactly `r.tradingStart`, not from its own pool
    /// start and not from `T_end - W` (which lies inside registration here).
    function test_roundOneCandidatesAreAllScoredFromTheRoundClock() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint256 roundId = roundManager.roundCount();
        assertEq(roundId, 1, "round one");
        _isShortRound(roundId);
        uint64 t0 = uint64(vm.getBlockTimestamp());

        vm.warp(t0 + 10);
        _tradeCandidate(a, true, 1_000_000e18);
        vm.warp(t0 + 120);
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        vm.warp(t0 + 130);
        _tradeCandidate(b, true, 1_000_000e18);

        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertEq(roundManager.candidateInfo(a.id).tradingStart, t0, "A opened at its registration");
        assertEq(roundManager.candidateInfo(b.id).tradingStart, t0 + 120, "B opened at its registration");
        assertLt(t0 + 120, r.tradingStart, "both before the round clock");

        vm.warp(r.tradingStart + 30);
        _tradeCandidate(a, true, 500_000e18);
        _tradeCandidate(b, true, 500_000e18);

        (uint64 tradingEnd,) = _settleEndWith(END_WORD);
        assertEq(tradingEnd, r.nominalEnd - END_WORD, "T_end = T - 100");
        // `T_end - W < r.tradingStart`, written without the subtraction: on a ten-minute round
        // `W > T_end` itself on a chain that started near timestamp zero
        assertLt(tradingEnd, r.tradingStart + roundManager.closingWindowFor(roundId), "T_end - W is before the clock");

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a.id, b.id);
        (int256[] memory avgs, uint64[] memory starts, uint64[] memory ends) = _submitAll(ids);
        for (uint256 i = 0; i < 2; i++) {
            assertEq(starts[i], r.tradingStart, "tStartUsed == r.tradingStart for every candidate");
            assertEq(ends[i], tradingEnd, "tEndUsed == T_end");
        }
        // identical curves, identical flow from the clock on: the same score, whenever they opened
        assertEq(avgs[0], avgs[1], "same support over the same span scores the same");
    }

    /// @notice Support bought BEFORE the clock and still held counts exactly like the same buy
    /// made at the clock; support bought before the clock and sold before it does not count.
    function test_supportBoughtBeforeTheClockAndHeldCountsSoldBeforeDoesNot() public {
        Cand memory held = _registerCandidate(address(0xA11CE), "HELD");
        Cand memory flipped = _registerCandidate(address(0xB0B), "FLIP");
        Cand memory atClock = _registerCandidate(address(0xCA7), "CLOCK");
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        uint256 buy = 1_000_000e18;

        uint64 t0 = uint64(vm.getBlockTimestamp());
        vm.warp(t0 + 10); // past every pool's own snipe tax
        _tradeCandidate(held, true, buy);
        _tradeCandidate(flipped, true, buy);
        vm.warp(t0 + 30);
        _tradeCandidate(flipped, false, IERC20(flipped.token).balanceOf(address(this)));
        assertLt(vm.getBlockTimestamp(), r.tradingStart, "all of that happened during Registration");

        vm.warp(r.tradingStart);
        _tradeCandidate(atClock, true, buy);

        _settleEndWith(END_WORD);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (held.id, flipped.id, atClock.id);
        (int256[] memory avgs, uint64[] memory starts,) = _submitAll(ids);

        assertGt(avgs[0], 0, "held support scores");
        assertEq(avgs[0], avgs[2], "held from before the clock == bought at the clock: early trading earns nothing extra");
        assertLt(avgs[1] * 100, avgs[0], "support sold before the clock does not count");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(starts[i], r.tradingStart, "every window starts at the clock");
        }
    }

    /// @notice A second candidate registered 120 s into registration trades in its registration
    /// block, with ITS OWN snipe tax: 99% at its +0 while the first pool (open for 120 s) is untaxed.
    function test_aSecondCandidateAt120sTradesImmediatelyWithItsOwnTax() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint64 t0 = uint64(vm.getBlockTimestamp());
        vm.warp(t0 + 120);
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration));
        assertEq(roundManager.candidateInfo(b.id).tradingStart, t0 + 120, "B's own start");
        assertEq(hook.poolInfo(b.poolId).tradingStart, t0 + 120, "the hook carries B's own start");

        uint256 buy = 1_000e18;
        uint256 outB = _tradeCandidate(b, true, buy); // B at its +0: 99%
        uint256 outA = _tradeCandidate(a, true, buy); // A at its +120: untaxed
        assertGt(outB, 0, "B trades in its registration block");
        // an edge pool: 1 - 99% snipe - 0.1% hop survives at +0 (the 1% edge fee waits for the
        // snipe tax to finish), against 1 - 1% edge - 0.1% hop once it has
        assertApproxEqRel(outB, (outA * 9_000) / 989_000, 2e16, "B's 99% snipe tax runs from B's own timestamp");

        vm.warp(t0 + 123);
        uint256 outB3 = _tradeCandidate(b, true, buy);
        assertApproxEqRel(outB3, outA, 2e16, "and is gone three seconds later");
    }

    /// @notice NEGATIVE: nothing registers at or after `registrationEnd` on a short round. Pools
    /// opening at registration does not open registration any later.
    function test_registeringAtOrAfterRegistrationEndIsRefusedOnAShortRound() public {
        _registerCandidate(address(0xA11CE), "A");
        uint256 roundId = roundManager.roundCount();
        _isShortRound(roundId);
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertEq(r.lateEntryEnd, 0, "no late-entry window");

        vm.warp(r.registrationEnd - 1);
        Cand memory last = _registerCandidate(address(0xB0B), "LAST");
        assertEq(roundManager.candidateInfo(last.id).tradingStart, r.registrationEnd - 1, "the last second still opens a pool");

        uint64[3] memory ts = [r.registrationEnd, r.registrationEnd + 1, r.nominalEnd - 1];
        for (uint256 i = 0; i < ts.length; i++) {
            vm.warp(ts[i]);
            vm.prank(address(0xDEAD));
            vm.expectRevert(RoundManager.RegistrationClosed.selector);
            factory.registerCandidate("late", "L", "", type(uint256).max);
        }
        assertEq(roundManager.roundInfo(roundId).candidateCount, 2, "nothing was added");
    }

    /// @notice F4: on a round whose window is SHORTER than its duration (`W < D`), the floor at
    /// `r.tradingStart` does not bind: `tStartUsed == T_end - W`, not the round's own start. The
    /// round clock is also nudged off the 18 s coarse-slot grid and settled with a non-zero word,
    /// so a mutant that always floors (or never floors) fails this test either way.
    function test_floorDoesNotBindWhenWindowShorterThanTrading() public {
        _runWinningRound(1, WINNING_ABSORPTION); // round 1, D = 420 < W
        _runWinningRound(1, WINNING_ABSORPTION); // round 2, D = 420 < W
        vm.warp(block.timestamp + 7); // desync T from the 18 s coarse-slot grid
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint256 roundId = roundManager.roundCount();
        assertEq(roundId, 3, "round three");
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertGt(roundManager.durationFor(roundId), roundManager.closingWindowFor(roundId), "W < D on round three");

        vm.warp(r.tradingStart + 10);
        _tradeCandidate(a, true, 1_000_000e18);

        (uint64 tradingEnd,) = _settleEndWith(37); // non-zero word
        uint64 windowStart = tradingEnd - roundManager.closingWindowFor(roundId);
        assertGt(windowStart, r.tradingStart, "the floor does not bind on this round");

        uint256[] memory ids = new uint256[](1);
        ids[0] = a.id;
        (, uint64[] memory starts,) = _submitAll(ids);
        assertEq(starts[0], windowStart, "tStartUsed == T_end - W, not r.tradingStart");
    }

    /// @notice F3: a late entrant on a long round (round 7, raw `D = 3840 s`, which is where late
    /// entry first exists) is scored from `T_end - W` with no floor binding — its own pool opens
    /// well before the closing window could ever start, exactly the margin
    /// `lateEntryUntil`/`closingWindowFor` keep (PROTOCOL_SPEC.md, "The closing window `W`").
    function test_lateEntrantIsScoredFromTEndMinusWWithNoFloorBinding() public {
        for (uint256 i = 0; i < 6; i++) {
            _runWinningRound(1, WINNING_ABSORPTION); // rounds 1-6: D = 420, 420, 960, 960, 1920, 1920
        }
        uint256 roundId = roundManager.roundCount();
        assertEq(roundId, 6, "six rounds won so far");

        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        roundId = roundManager.roundCount();
        assertEq(roundId, 7, "round seven");
        assertEq(roundManager.durationFor(roundId), 3840, "raw D = 3840 on round seven");
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertGt(r.lateEntryEnd, 0, "round seven offers late entry");

        vm.warp(r.tradingStart + 10);
        _tradeCandidate(a, true, 1_000_000e18);

        // register the late entrant just inside the late-entry window
        vm.warp(r.lateEntryEnd - 1);
        Cand memory late = _registerCandidate(address(0xB0B), "LATE");
        uint64 lateStart = roundManager.candidateInfo(late.id).tradingStart;
        assertEq(lateStart, r.lateEntryEnd - 1, "the late entrant's pool opens at its own registration");

        vm.warp(r.lateEntryEnd + 5);
        _tradeCandidate(late, true, 1_000_000e18);

        (uint64 tradingEnd,) = _settleEndWith(53); // non-zero word
        uint64 windowStart = tradingEnd - roundManager.closingWindowFor(roundId);
        assertGt(windowStart, r.tradingStart, "the floor at r.tradingStart does not bind on this round");
        assertLe(
            lateStart,
            r.nominalEnd - roundManager.closingWindowFor(roundId) - roundManager.RANDOM_END_S(),
            "the late entrant's start is at or before T - W - RANDOM_END_S"
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = late.id;
        (, uint64[] memory starts,) = _submitAll(ids);
        assertEq(starts[0], windowStart, "the late entrant is scored from T_end - W, no floor binding");
    }
}
