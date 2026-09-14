// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice MECHANISM_v3 sec.2 and sec.3: the adaptive schedule, late entry, the closing-window
/// score and the random end - every rule, and the fallback for each.
contract ScheduleTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
    }

    // ---------------------------------------------------------------------------------
    // the schedule is a pure function of the round number
    // ---------------------------------------------------------------------------------

    /// @notice The published table of MECHANISM_v3 sec.2, row by row, to the second.
    function test_theScheduleTableIsExact() public view {
        uint64[14] memory d = [
            uint64(15 minutes),
            15 minutes,
            30 minutes,
            30 minutes,
            1 hours,
            1 hours,
            2 hours,
            2 hours,
            4 hours,
            4 hours,
            8 hours,
            8 hours,
            12 hours,
            12 hours
        ];
        uint64[14] memory r = [
            uint64(3 minutes),
            3 minutes,
            6 minutes,
            6 minutes,
            12 minutes,
            12 minutes,
            24 minutes,
            24 minutes,
            48 minutes,
            48 minutes,
            1 hours,
            1 hours,
            1 hours,
            1 hours
        ];
        uint64[14] memory late = [
            uint64(0),
            0,
            0,
            0,
            20 minutes,
            20 minutes,
            40 minutes,
            40 minutes,
            80 minutes,
            80 minutes,
            160 minutes,
            160 minutes,
            4 hours,
            4 hours
        ];
        for (uint256 n = 1; n <= 14; n++) {
            assertEq(roundManager.durationFor(n), d[n - 1], "D(n)");
            assertEq(roundManager.registrationFor(n), r[n - 1], "R(n)");
            assertEq(roundManager.lateEntryUntil(n), late[n - 1], "late entry window");
        }
    }

    /// @notice The cap really is a cap: round 100 is still a 12-hour round with a 1-hour
    /// registration, and the doubling can never overflow the shift.
    function test_theScheduleIsCappedForever() public view {
        assertEq(roundManager.durationFor(100), 12 hours, "capped duration");
        assertEq(roundManager.registrationFor(100), 1 hours, "capped registration");
        assertEq(roundManager.durationFor(type(uint64).max), 12 hours, "no overflow at absurd depth");
    }

    /// @notice THE CLOSING WINDOW IS FLAT: 15 minutes on every round (review-2). It used to be a
    /// quarter of the duration above an hour - 2 h -> 30 min, 12 h -> 3 h - and is now the same
    /// yardstick whatever `n` is, so the round number changes only how long a coin has to build
    /// support, never how that support is measured.
    function test_theClosingWindowIsFlatOnEveryRound() public view {
        assertEq(roundManager.CLOSING_WINDOW_S(), 15 minutes, "the published constant");
        assertEq(roundManager.closingWindowFor(1), 15 minutes, "15 min round");
        assertEq(roundManager.closingWindowFor(3), 15 minutes, "30 min round");
        assertEq(roundManager.closingWindowFor(5), 15 minutes, "1 h round");
        assertEq(roundManager.closingWindowFor(7), 15 minutes, "2 h round");
        assertEq(roundManager.closingWindowFor(9), 15 minutes, "4 h round");
        assertEq(roundManager.closingWindowFor(11), 15 minutes, "8 h round");
        assertEq(roundManager.closingWindowFor(13), 15 minutes, "12 h round");
        assertEq(roundManager.closingWindowFor(100), 15 minutes, "and every capped round after");
    }

    /// @notice The coarse score ring must REACH the far edge of the window, and still reach it
    /// after a whole settlement tail of swaps has been written into it.
    function test_theScoreRingCoversTheWholeClosingWindowPlusTheTail() public view {
        uint256 slots = hook.SCORE_COARSE_SLOTS();
        for (uint256 n = 1; n <= 14; n++) {
            uint256 slot = roundManager.scoreSlotFor(n);
            // review 2: the tail includes END_TIMEOUT, because `fulfilEnd` has no deadline and a
            // round settled by the fallback opens its submission window at `T + END_TIMEOUT`
            uint256 needed = roundManager.closingWindowFor(n) + roundManager.RANDOM_END_S()
                + roundManager.END_TIMEOUT() + roundManager.SUBMIT_S();
            assertGe((slots - 1) * slot, needed, "the ring reaches back over the window and the tail");
            assertGe(slot, hook.SCORE_SLOT_S(), "never finer than the fast ring");
        }
    }

    /// @notice The late-entry window always CLOSES before the closing window OPENS, which is what
    /// makes one window for everybody well defined: no candidate is ever scored over a span that
    /// starts before its own pool did.
    function test_lateEntryAlwaysEndsBeforeTheClosingWindowStarts() public view {
        for (uint256 n = 5; n <= 20; n++) {
            uint64 late = roundManager.lateEntryUntil(n);
            if (late == 0) continue;
            uint64 windowOpens =
                roundManager.durationFor(n) - roundManager.closingWindowFor(n) - roundManager.randomEndWindowFor(n);
            assertLt(late, windowOpens, "late entry closes before the closing window opens");
        }
    }

    /// @notice A round's stored schedule is the schedule of its own number.
    function test_anOpenedRoundUsesItsOwnRowOfTheTable() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        assertEq(r.registrationEnd - r.openedAt, roundManager.registrationFor(1), "registration window");
        assertEq(r.nominalEnd - r.tradingStart, roundManager.durationFor(1), "trading window");
        assertEq(r.lateEntryEnd, 0, "a 15-minute round has no late entry");
    }

    // ---------------------------------------------------------------------------------
    // late entry
    // ---------------------------------------------------------------------------------

    /// @notice Rounds shorter than an hour refuse a late entrant outright.
    function test_lateEntryIsRefusedOnAShortRound() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.registrationEnd + 1);
        uint256 bond = roundManager.currentBond();
        vm.deal(address(0xDEAD), bond);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate{value: bond}("late", "L", "");
    }

    /// @notice On a one-hour round a late entrant is accepted for the first third of trading,
    /// its pool opens at that moment, and it is refused one second after the window.
    function test_lateEntryIsAcceptedInTheWindowAndRefusedAfterIt() public {
        _reachRound(5);
        Cand memory early = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(5);
        assertEq(r.lateEntryEnd, r.tradingStart + 20 minutes, "20 minutes of open entry");

        // trading has started and registration is closed - and a late entrant still gets in
        vm.warp(r.tradingStart + 10 minutes);
        Cand memory late = _registerCandidate(address(0xB0B), "B");
        assertEq(roundManager.candidateInfo(late.id).roundId, 5, "same round");
        assertEq(roundManager.candidateInfo(late.id).bond, roundManager.candidateInfo(early.id).bond, "same bond");
        assertEq(roundManager.candidateInfo(late.id).tradingStart, block.timestamp, "its pool opens right now");
        assertEq(hook.poolInfo(late.poolId).tradingStart, block.timestamp, "and the hook agrees");
        // the early candidate's own window is unchanged
        assertEq(roundManager.candidateInfo(early.id).tradingStart, r.tradingStart, "the early pool is untouched");

        // ...and its pool is live immediately: no gate, its own 3-second snipe tax instead
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(block.timestamp + 4);
        assertGt(_tradeCandidate(late, true, 1_000e18), 0, "the late pool trades at once");

        vm.warp(r.lateEntryEnd);
        uint256 bond = roundManager.currentBond();
        vm.deal(address(0xDEAD), bond);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate{value: bond}("later", "L2", "");
    }

    /// @notice THE POINT OF THE CLOSING WINDOW: a late entrant with the same support at the bell
    /// scores the same as a coin that has been there from the start. The handicap is having less
    /// time to build that support, not a smaller number once it has.
    function test_aLateEntrantWithTheSameClosingSupportScoresTheSame() public {
        _reachRound(5);
        Cand memory early = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(5);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        vm.warp(r.tradingStart + 60);
        _tradeCandidate(early, true, WINNING_BUY);

        // the late entrant comes in at the end of the open-entry window and buys the same amount
        vm.warp(r.tradingStart + 19 minutes);
        Cand memory late = _registerCandidate(address(0xB0B), "B");
        vm.warp(block.timestamp + 10);
        _tradeCandidate(late, true, WINNING_BUY);

        _settleEnd();
        int256 earlyAvg = roundManager.submitScore(early.id);
        int256 lateAvg = roundManager.submitScore(late.id);
        assertEq(earlyAvg, lateAvg, "identical support at the bell scores identically");
        assertGt(earlyAvg, 0, "and it is a real score");
    }

    /// @notice ...and what the closing window really measures is the support that is STILL there:
    /// a coin that is sold down before the bell loses to one that is not, however early it bought.
    function test_supportSoldBeforeTheBellDoesNotCount() public {
        Cand memory dumped = _registerCandidate(address(0xA11CE), "A");
        Cand memory held = _registerCandidate(address(0xB0B), "B");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        vm.warp(r.tradingStart + 5);
        uint256 bought = _tradeCandidate(dumped, true, WINNING_BUY);
        _tradeCandidate(held, true, WINNING_BUY);

        // the first one is sold back well before the bell
        vm.warp(r.nominalEnd - 10 minutes);
        _tradeCandidate(dumped, false, bought);

        _settleEnd();
        int256 dumpedAvg = roundManager.submitScore(dumped.id);
        int256 heldAvg = roundManager.submitScore(held.id);
        assertLt(dumpedAvg, heldAvg, "the dumped coin scores less");
        vm.warp(r.nominalEnd + roundManager.SUBMIT_S());
        roundManager.finalize();
        assertEq(roundManager.head(), held.token, "and loses the round");
    }

    // ---------------------------------------------------------------------------------
    // the checkpoint rings
    // ---------------------------------------------------------------------------------

    /// @notice Reconstruction across a GAP: `R` is constant between swaps, so a window whose
    /// edges fall in slots with no swap in them is still evaluated exactly.
    function test_theRingReconstructsExactlyAcrossGaps() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        // one swap, then nothing at all for the rest of the round: every slot of both rings in
        // between is empty
        vm.warp(r.tradingStart + 30);
        _tradeCandidate(a, true, WINNING_BUY);
        (, int128 R, uint64 tLast) = hook.scoreState(a.poolId);
        assertEq(tLast, r.tradingStart + 30, "one and only one accumulation");

        uint64 tEnd = r.nominalEnd;
        uint64 tStart = tEnd - roundManager.closingWindowFor(1);
        // the closing window of a 15-minute round reaches back past the pool's own open, so it is
        // floored there and the average is over the whole round
        (int256 avg, uint64 attained) = hook.averageOver(a.poolId, tStart, tEnd);
        assertEq(attained, r.tradingStart + 30, "the last update before the bell");
        int256 expected =
            (int256(R) * int256(uint256(tEnd - (r.tradingStart + 30)))) / int256(uint256(tEnd - r.tradingStart));
        assertEq(avg, expected, "exact across an entirely empty ring");

        // now bury the ring under post-bell swaps - enough of them to overwrite the FAST ring
        // slot that held the round's only checkpoint. The reconstruction at the same edges is
        // byte-identical, because the COARSE ring still brackets both of them.
        vm.warp(r.nominalEnd + 1);
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + 7);
            _tradeCandidate(a, false, IERC20(a.token).balanceOf(address(this)) / 50);
        }
        (int256 after_,) = hook.averageOver(a.poolId, tStart, tEnd);
        assertEq(after_, avg, "post-bell swaps cannot move the reconstructed score");
    }

    /// @notice A slot is written at most once, by the first swap in it, and its contents are the
    /// state BEFORE that swap - the conservative edge convention.
    function test_aSlotIsWrittenOnceByItsFirstSwap() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        uint64 t = r.tradingStart + 25;
        vm.warp(t);
        _tradeCandidate(a, true, 100_000e18);
        uint256 slot = uint256(t / hook.SCORE_SLOT_S()) % hook.SCORE_SLOTS();
        IFamilyHook.ScoreCheckpoint memory cp = hook.scoreCheckpoint(a.poolId, slot);
        assertEq(cp.tSwap, t, "tagged by the first swap of the slot");
        assertEq(cp.R, int128(0), "and holds the state BEFORE it");

        // a second swap in the same 5-second slot leaves the entry alone
        _tradeCandidate(a, true, 100_000e18);
        IFamilyHook.ScoreCheckpoint memory cp2 = hook.scoreCheckpoint(a.poolId, slot);
        assertEq(cp2.tSwap, cp.tSwap, "unchanged");
        assertEq(cp2.R, cp.R, "unchanged");
    }

    // ---------------------------------------------------------------------------------
    // the random end
    // ---------------------------------------------------------------------------------

    function test_theEndCannotBeRequestedBeforeTheNominalEnd() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.nominalEnd - 1);
        vm.expectRevert(RoundManager.EndNotDue.selector);
        roundManager.requestEnd();
    }

    function test_theEndIsPinnedOnceAndOnlyOnce() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.nominalEnd);
        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    /// @notice The true end always falls inside the last {RANDOM_END_S} seconds, and it is
    /// exactly `T - (word mod 180)` - so the offset is the beacon's, not anybody's choice.
    function test_theTrueEndFallsInTheLastThreeMinutes() public {
        uint256[5] memory words = [uint256(0), 1, 179, 180, type(uint256).max];
        for (uint256 i = 0; i < words.length; i++) {
            _registerCandidate(address(uint160(0xA11CE + i)), "A");
            uint256 roundId = roundManager.roundCount();
            RoundManager.Round memory r = roundManager.roundInfo(roundId);
            (uint64 tEnd, uint64 submitEnd) = _settleEndWith(words[i]);
            assertEq(tEnd, r.nominalEnd - uint64(words[i] % roundManager.RANDOM_END_S()), "T - (r mod 180)");
            assertLe(tEnd, r.nominalEnd, "never after T");
            assertGe(tEnd, r.nominalEnd - roundManager.RANDOM_END_S(), "never more than 3 minutes before T");
            vm.warp(submitEnd);
            roundManager.finalize();
        }
    }

    /// @notice Scores cannot be read - and the round cannot be closed - at a time nobody knows.
    function test_nothingSettlesUntilTheEndIsKnown() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.nominalEnd + 1);
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.EndPending), "end pending");
        vm.expectRevert(RoundManager.EndNotSettled.selector);
        roundManager.submitScore(a.id);
        vm.warp(r.nominalEnd + roundManager.SUBMIT_S() + 1);
        vm.expectRevert(RoundManager.EndNotSettled.selector);
        roundManager.finalize();
    }

    /// @notice The submission window starts when the end is FULFILLED, not at `T`: a beacon that
    /// takes twenty minutes to arrive does not eat the window it opens.
    function test_theSubmissionWindowStartsAtFulfilment() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.nominalEnd + 20 minutes);
        roundManager.requestEnd();
        roundManager.fulfilEnd(abi.encode(uint256(90)));
        RoundManager.Round memory after_ = roundManager.roundInfo(1);
        assertEq(after_.tradingEnd, r.nominalEnd - 90, "T_end is still measured from T");
        assertEq(after_.submitEnd, block.timestamp + roundManager.SUBMIT_S(), "the window opens now");
    }

    function test_theEndCannotBeSettledTwice() public {
        _registerCandidate(address(0xA11CE), "A");
        _settleEnd();
        vm.expectRevert(RoundManager.EndAlreadySettled.selector);
        roundManager.fulfilEnd(abi.encode(uint256(0)));
        vm.warp(block.timestamp + roundManager.END_TIMEOUT() + 1);
        vm.expectRevert(RoundManager.EndAlreadySettled.selector);
        roundManager.finalizeDeterministic();
    }

    // ---------------------------------------------------------------------------------
    // the disclosed fallback
    // ---------------------------------------------------------------------------------

    function test_theDeterministicFallbackIsRefusedBeforeTheTimeout() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT() - 1);
        vm.expectRevert(RoundManager.TimeoutNotReached.selector);
        roundManager.finalizeDeterministic();
    }

    /// @notice A beacon that never arrives costs the round its randomness and nothing else: the
    /// round ends at `T`, loudly.
    function test_anUnrelayedBeaconEndsTheRoundAtTLoudly() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(r.tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);

        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT());
        vm.expectEmit(true, false, false, true, address(roundManager));
        emit RoundManager.RandomEndUnavailable(1, r.nominalEnd, uint64(block.timestamp) + roundManager.SUBMIT_S());
        roundManager.finalizeDeterministic();

        assertEq(roundManager.roundInfo(1).tradingEnd, r.nominalEnd, "T_end is T");
        roundManager.submitScore(a.id);
        vm.warp(block.timestamp + roundManager.SUBMIT_S());
        roundManager.finalize();
        assertEq(roundManager.head(), a.token, "and the round still crowns its winner");
    }

    /// @notice The fallback does not need anybody to have pinned anything first.
    function test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(1);
        assertEq(r.randomId, bytes32(0), "nothing pinned");
        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT());
        roundManager.finalizeDeterministic();
        assertEq(roundManager.roundInfo(1).tradingEnd, r.nominalEnd, "settled deterministically");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev Burn rounds until the NEXT round to open is number `n`. A round with no absorption at
    /// all fails, so the head never moves and only the round number advances.
    function _reachRound(uint256 n) internal {
        while (roundManager.roundCount() < n - 1) {
            _registerCandidate(address(uint160(0xFA11 + roundManager.roundCount())), "F");
            (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
            _settleEnd();
            vm.warp(submitEnd + 1);
            roundManager.finalize();
        }
    }
}
