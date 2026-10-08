// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice sec.2 and sec.3: the adaptive schedule, late entry, the closing-window
/// score and the random end - every rule, and the fallback for each.
contract ScheduleTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // the schedule is a pure function of the round number
    // ---------------------------------------------------------------------------------

    /// @notice The published table of sec.2, row by row, to the second. The doubling is on the
    /// WHOLE round `L(n)`, entries included: `R(n) = clamp(L/5, 3 min, 1 h)` and the round clock
    /// runs `D(n) = L(n) - R(n)`.
    function test_theScheduleTableIsExact() public view {
        uint64[16] memory l = [
            uint64(10 minutes),
            10 minutes,
            20 minutes,
            20 minutes,
            40 minutes,
            40 minutes,
            80 minutes,
            80 minutes,
            160 minutes,
            160 minutes,
            320 minutes,
            320 minutes,
            640 minutes,
            640 minutes,
            12 hours,
            12 hours
        ];
        uint64[16] memory r = [
            uint64(3 minutes),
            3 minutes,
            4 minutes,
            4 minutes,
            8 minutes,
            8 minutes,
            16 minutes,
            16 minutes,
            32 minutes,
            32 minutes,
            1 hours,
            1 hours,
            1 hours,
            1 hours,
            1 hours,
            1 hours
        ];
        uint64[16] memory late = [
            uint64(0),
            0,
            0,
            0,
            0,
            0,
            1280,
            1280,
            2560,
            2560,
            5200,
            5200,
            11_600,
            11_600,
            13_200,
            13_200
        ];
        uint64[16] memory randomEnd =
            [uint64(105), 105, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180, 180];
        for (uint256 n = 1; n <= 16; n++) {
            assertEq(roundManager.roundLengthFor(n), l[n - 1], "L(n)");
            assertEq(roundManager.registrationFor(n), r[n - 1], "R(n)");
            assertEq(roundManager.durationFor(n), l[n - 1] - r[n - 1], "D(n) = L(n) - R(n)");
            assertEq(roundManager.lateEntryUntil(n), late[n - 1], "late entry window");
            assertEq(roundManager.randomEndWindowFor(n), randomEnd[n - 1], "random-end window");
        }
        // the first two rounds: ten minutes from the first entry, seven of them on the clock
        assertEq(roundManager.durationFor(1), 420, "D(1) = 420 s");
        // late entry first appears on round 7, the first whose clock reaches an hour
        assertEq(roundManager.lateEntryUntil(6), 0, "round 6: D = 32 min, no late entry");
        assertGe(roundManager.durationFor(7), roundManager.LATE_ENTRY_FROM_S(), "round 7: D >= 1 h");
    }

    /// @notice The cap really is a cap: round 100 is still a 12-hour round with a 1-hour
    /// registration, and the doubling can never overflow the shift.
    function test_theScheduleIsCappedForever() public view {
        assertEq(roundManager.roundLengthFor(100), 12 hours, "capped round");
        assertEq(roundManager.durationFor(100), 11 hours, "capped trading");
        assertEq(roundManager.registrationFor(100), 1 hours, "capped registration");
        assertEq(roundManager.durationFor(type(uint64).max), 11 hours, "no overflow at absurd depth");
        assertEq(roundManager.roundLengthFor(type(uint256).max), 12 hours, "nor at the end of the type");
    }

    /// @notice THE CLOSING WINDOW IS FLAT: 15 minutes on every round, not a
    /// quarter of the duration above an hour (2 h -> 30 min, 12 h -> 3 h): it is the same
    /// yardstick whatever `n` is, so the round number changes only how long a coin has to build
    /// support, never how that support is measured.
    function test_theClosingWindowIsFlatOnEveryRound() public view {
        assertEq(roundManager.CLOSING_WINDOW_S(), 15 minutes, "the published constant");
        assertEq(roundManager.closingWindowFor(1), 15 minutes, "10 min round (W > D)");
        assertEq(roundManager.closingWindowFor(3), 15 minutes, "20 min round");
        assertEq(roundManager.closingWindowFor(5), 15 minutes, "40 min round");
        assertEq(roundManager.closingWindowFor(7), 15 minutes, "80 min round");
        assertEq(roundManager.closingWindowFor(9), 15 minutes, "160 min round");
        assertEq(roundManager.closingWindowFor(11), 15 minutes, "5 h 20 min round");
        assertEq(roundManager.closingWindowFor(15), 15 minutes, "12 h round");
        assertEq(roundManager.closingWindowFor(100), 15 minutes, "and every capped round after");
    }

    /// @notice The coarse score ring must REACH the far edge of the window from the pool's
    /// published end. The settlement TAIL is not part of the requirement -
    /// ring writes freeze at `nominalEnd`, so no swap made while a round is being settled or
    /// scored can overwrite an entry. The ring only has to reach back `W + RANDOM_END_S`.
    function test_theScoreRingCoversTheWholeClosingWindow() public view {
        uint256 slots = hook.SCORE_COARSE_SLOTS();
        for (uint256 n = 1; n <= 16; n++) {
            uint256 slot = roundManager.scoreSlotFor(n);
            uint256 needed = roundManager.closingWindowFor(n) + roundManager.RANDOM_END_S();
            assertGe((slots - 1) * slot, needed, "the ring reaches back over the whole scored span");
            assertGe(slot, hook.SCORE_SLOT_S(), "never finer than the fast ring");
            assertGt(roundManager.closingWindowFor(n), slot, "The two edges can never collapse");
        }
    }

    /// @notice The late-entry window always CLOSES before the closing window OPENS, which is what
    /// makes one window for everybody well defined: no candidate is ever scored over a span that
    /// starts before its own pool did.
    function test_lateEntryAlwaysEndsBeforeTheClosingWindowStarts() public view {
        for (uint256 n = 1; n <= 20; n++) {
            uint64 late = roundManager.lateEntryUntil(n);
            if (late == 0) continue;
            uint64 windowOpens =
                roundManager.durationFor(n) - roundManager.closingWindowFor(n) - roundManager.randomEndWindowFor(n);
            assertLt(late, windowOpens, "late entry closes before the closing window opens");
        }
    }

    /// @notice A round's stored schedule is the schedule of its own number, and its published
    /// end is exactly `L(n)` after the first registration opened it.
    function test_anOpenedRoundUsesItsOwnRowOfTheTable() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(2);
        assertEq(r.registrationEnd - r.openedAt, roundManager.registrationFor(2), "registration window");
        assertEq(r.nominalEnd - r.tradingStart, roundManager.durationFor(2), "trading window");
        assertEq(r.nominalEnd - r.openedAt, roundManager.roundLengthFor(2), "nominalEnd = openedAt + L(n)");
        assertEq(r.nominalEnd - r.openedAt, 10 minutes, "ten minutes from the first entry");
        assertEq(r.lateEntryEnd, 0, "a 10-minute round has no late entry");
    }

    // ---------------------------------------------------------------------------------
    // late entry
    // ---------------------------------------------------------------------------------

    /// @notice Rounds shorter than an hour refuse a late entrant outright.
    function test_lateEntryIsRefusedOnAShortRound() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.registrationEnd + 1);
        uint256 bond = roundManager.currentBond();
        _fundDoll(address(0xDEAD), bond);
        vm.prank(address(0xDEAD));
        doll.approve(address(factory), bond);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate("late", "L", "", type(uint256).max);
    }

    /// @notice On round 7 (64 minutes on the clock, the first round of an hour or more) a late
    /// entrant is accepted for the first third of trading, its pool opens at that moment, and it is
    /// refused one second after the window.
    function test_lateEntryIsAcceptedInTheWindowAndRefusedAfterIt() public {
        _reachRound(7);
        Cand memory early = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(7);
        assertEq(r.lateEntryEnd, r.tradingStart + 1280, "21 min 20 s of open entry");

        // trading has started and registration is closed - and a late entrant still gets in
        vm.warp(r.tradingStart + 10 minutes);
        Cand memory late = _registerCandidate(address(0xB0B), "B");
        assertEq(roundManager.candidateInfo(late.id).roundId, 7, "same round");
        assertEq(roundManager.candidateInfo(late.id).bond, roundManager.candidateInfo(early.id).bond, "same bond");
        assertEq(roundManager.candidateInfo(late.id).tradingStart, block.timestamp, "its pool opens right now");
        assertEq(hook.poolInfo(late.poolId).tradingStart, block.timestamp, "and the hook agrees");
        // the early candidate's own start is unchanged: the moment it registered, which opened the round
        assertEq(roundManager.candidateInfo(early.id).tradingStart, r.openedAt, "the early pool is untouched");

        // ...and its pool is live immediately: no gate, its own 3-second snipe tax instead
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(block.timestamp + 4);
        assertGt(_tradeCandidate(late, true, 1_000e18), 0, "the late pool trades at once");

        vm.warp(r.lateEntryEnd);
        uint256 bond = roundManager.currentBond();
        _fundDoll(address(0xDEAD), bond);
        vm.prank(address(0xDEAD));
        doll.approve(address(factory), bond);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate("later", "L2", "", type(uint256).max);
    }

    /// @notice THE POINT OF THE CLOSING WINDOW: a late entrant with the same support at the bell
    /// scores the same as a coin that has been there from the start. The handicap is having less
    /// time to build that support, not a smaller number once it has.
    function test_aLateEntrantWithTheSameClosingSupportScoresTheSame() public {
        _reachRound(7);
        Cand memory early = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(7);
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
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        vm.warp(r.tradingStart + 5);
        uint256 bought = _tradeCandidate(dumped, true, WINNING_BUY);
        _tradeCandidate(held, true, WINNING_BUY);

        // the first one is sold back well before the bell
        vm.warp(r.nominalEnd - 5 minutes);
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
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        // one swap, then nothing at all for the rest of the round: every slot of both rings in
        // between is empty
        vm.warp(r.tradingStart + 30);
        _tradeCandidate(a, true, WINNING_BUY);
        (, int128 R, uint64 tLast) = hook.scoreState(a.poolId);
        assertEq(tLast, r.tradingStart + 30, "one and only one accumulation");

        uint64 tEnd = r.nominalEnd;
        uint64 tStart = tEnd - roundManager.closingWindowFor(1);
        // the closing window of a 10-minute round reaches back past the round clock, so it is
        // floored there, exactly as {RoundManager.submitScore} does, and the average is over the
        // whole trading period
        if (tStart < r.tradingStart) tStart = r.tradingStart;
        (int256 avg, uint64 attained,,) = hook.averageOver(a.poolId, tStart, tEnd);
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
        (int256 after_,,,) = hook.averageOver(a.poolId, tStart, tEnd);
        assertEq(after_, avg, "post-bell swaps cannot move the reconstructed score");
    }

    /// @notice A slot is written at most once, by the first swap in it, and its contents are the
    /// state BEFORE that swap - the conservative edge convention.
    function test_aSlotIsWrittenOnceByItsFirstSwap() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
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
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.nominalEnd - 1);
        vm.expectRevert(RoundManager.EndNotDue.selector);
        roundManager.requestEnd();
    }

    function test_theEndIsPinnedOnceAndOnlyOnce() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.nominalEnd);
        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    /// @notice The true end always falls inside the round's random-end window - 105 s on the
    /// two ten-minute rounds, {RANDOM_END_S} after them - and it is exactly
    /// `T - (word mod window)`, so the offset is the beacon's, not anybody's choice.
    function test_theTrueEndFallsInTheLastThreeMinutes() public {
        uint256[5] memory words = [uint256(0), 1, 179, 180, type(uint256).max];
        for (uint256 i = 0; i < words.length; i++) {
            _registerCandidate(address(uint160(0xA11CE + i)), "A");
            uint256 roundId = roundManager.roundCount();
            RoundManager.Round memory r = roundManager.roundInfo(roundId);
            uint64 window = roundManager.randomEndWindowFor(roundId);
            (uint64 tEnd, uint64 submitEnd) = _settleEndWith(words[i]);
            assertEq(tEnd, r.nominalEnd - uint64(words[i] % window), "T - (r mod window)");
            assertLe(tEnd, r.nominalEnd, "never after T");
            assertGe(tEnd, r.nominalEnd - window, "never further back than the window");
            assertLe(window, roundManager.RANDOM_END_S(), "and never more than 3 minutes before T");
            vm.warp(submitEnd);
            roundManager.finalize();
        }
    }

    /// @notice Scores cannot be read - and the round cannot be closed - at a time nobody knows.
    function test_nothingSettlesUntilTheEndIsKnown() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
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
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.nominalEnd + 20 minutes);
        roundManager.requestEnd();
        roundManager.fulfilEnd(abi.encode(uint256(90)));
        RoundManager.Round memory after_ = roundManager.roundInfo(roundManager.roundCount());
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
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT() - 1);
        vm.expectRevert(RoundManager.TimeoutNotReached.selector);
        roundManager.finalizeDeterministic();
    }

    /// @notice A beacon that never arrives costs the round its randomness and nothing else: the
    /// round ends at `T`, loudly.
    function test_anUnrelayedBeaconEndsTheRoundAtTLoudly() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(r.tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);

        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT());
        vm.expectEmit(true, false, false, true, address(roundManager));
        emit RoundManager.RandomEndUnavailable(roundManager.roundCount(), r.nominalEnd, uint64(block.timestamp) + roundManager.SUBMIT_S());
        roundManager.finalizeDeterministic();

        assertEq(roundManager.roundInfo(roundManager.roundCount()).tradingEnd, r.nominalEnd, "T_end is T");
        roundManager.submitScore(a.id);
        vm.warp(block.timestamp + roundManager.SUBMIT_S());
        roundManager.finalize();
        assertEq(roundManager.head(), a.token, "and the round still crowns its winner");
    }

    /// @notice The fallback does not need anybody to have pinned anything first.
    function test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd() public {
        _registerCandidate(address(0xA11CE), "A");
        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        assertEq(r.randomId, bytes32(0), "nothing pinned");
        vm.warp(r.nominalEnd + roundManager.END_TIMEOUT());
        roundManager.finalizeDeterministic();
        assertEq(roundManager.roundInfo(roundManager.roundCount()).tradingEnd, r.nominalEnd, "settled deterministically");
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

    // ---------------------------------------------------------------------------------
    // The random-end window is clamped to a quarter of the round; the closing window is flat
    // ---------------------------------------------------------------------------------

    /// @notice On the mainnet schedule the quarter-duration clamp binds only on the two
    /// ten-minute rounds: `D = 420 s`, so their end is drawn from the last 105 s. From round 3
    /// (`D = 960 s`, `D/4 = 240 s`) the window is the full {RoundManager.RANDOM_END_S}.
    function test_theRandomEndWindowOnTheMainnetSchedule() public view {
        assertEq(roundManager.DURATION_SCALE_DIV(), 1, "this stack runs the published schedule");
        assertEq(roundManager.durationFor(1), 420, "the shortest trading period");
        assertEq(roundManager.randomEndWindowFor(1), 105, "a quarter of it");
        assertEq(roundManager.randomEndWindowFor(2), 105, "both ten-minute rounds");
        for (uint256 n = 3; n <= 16; n++) {
            assertEq(roundManager.randomEndWindowFor(n), roundManager.RANDOM_END_S(), "every later round");
        }
    }

    /// @notice `W` is {RoundManager.CLOSING_WINDOW_S} on every round, not a fraction of the
    /// duration such as `D(n)/4` above an hour (2 h -> 30 min, 12 h -> 3 h): the yardstick a coin
    /// is measured with does not change with the round number.
    function test_theClosingWindowIsTheSameConstantOnEveryRound() public view {
        uint64 w = roundManager.CLOSING_WINDOW_S();
        assertEq(w, 15 minutes, "the published constant");
        assertEq(roundManager.closingWindowFor(1), w, "round 1, a 10-minute round");
        assertEq(roundManager.closingWindowFor(5), w, "round 5, a 40-minute round");
        assertEq(roundManager.closingWindowFor(7), w, "round 7, an 80-minute round");
        assertEq(roundManager.closingWindowFor(15), w, "round 15, a 12-hour round");
    }

    /// @notice The hook's checkpoint rings reach back over `W + RANDOM_END_S` on every row of the
    /// schedule, which is the WHOLE span a round can be scored over: `T_end` lies in
    /// `[T - RANDOM_END_S, T]` and the window reaches `W` further back.
    ///
    /// The settlement TAIL has left this requirement. Ring writes freeze at the
    /// pool's published end `T`, so no swap made while a round is being settled or scored can
    /// overwrite an entry at all, and the ring no longer has to SURVIVE
    /// `END_TIMEOUT + SUBMIT_S` of churn on top of the span it has to REACH. On this stack the
    /// requirement is 900 + 180 = 1080 s for every round, met by 63 x 18 = 1134 s of coarse ring
    /// (it was 51 s, sized for 3180 s). The fast ring is unchanged at 36 x 5 = 180 s, which is
    /// exactly the random-end span it exists to cover.
    function test_theScoreRingsCoverTheFlatWindowAndTheRandomEnd() public view {
        assertEq(hook.SCORE_RING_S(), roundManager.RANDOM_END_S(), "the fast ring spans the random end");
        for (uint256 n = 1; n <= 20; n++) {
            uint256 needed = roundManager.closingWindowFor(n) + roundManager.RANDOM_END_S();
            assertEq(needed, 1080, "one requirement for every round now");
            uint256 slot = roundManager.scoreSlotFor(n);
            assertEq(slot, 18, "and one coarse spacing");
            assertGe((hook.SCORE_COARSE_SLOTS() - 1) * slot, needed, "the coarse ring reaches the far edge");
            assertGe(slot, hook.SCORE_SLOT_S(), "never finer than the fast ring");
        }
    }
}

/// @notice The same schedule, read on a heavily SCALED testnet divisor - the only place the
/// random-end clamp does anything at all.
contract ScheduleScaledTest is RoundTestBase {
    function setUp() public {
        durationScaleDiv = 5;
        _setUpFamily();
    }

    /// @notice `RANDOM_END_S` is not scaled by {RoundManager.DURATION_SCALE_DIV}, so on a divisor
    /// of 5 the first round trades for 84 s; without a clamp the end would be drawn from a
    /// window longer than the whole round, and `T_end` could land at `tradingStart` itself,
    /// leaving nothing to score. The clamp keeps three quarters of every round unconditionally
    /// inside the round.
    function test_theRandomEndWindowIsAQuarterOfAScaledRound() public view {
        assertEq(roundManager.DURATION_SCALE_DIV(), 5, "the scaled testnet schedule");
        assertEq(roundManager.durationFor(1), 84, "an 84-second round (420 / 5)");
        assertEq(roundManager.registrationFor(1), 36, "after a 36-second registration (180 / 5)");
        assertEq(roundManager.randomEndWindowFor(1), 21, "and a 21-second random-end window");
        assertLt(roundManager.randomEndWindowFor(1), roundManager.RANDOM_END_S(), "clamped, not RANDOM_END_S");
    }

    /// @notice The coarse ring's spacing follows the SCALED closing window, while `RANDOM_END_S`
    /// is seconds of wall clock whatever the schedule divisor does to the rounds; the settlement
    /// tail is not part of the span at all.
    function test_theCoarseSlotFollowsTheScaledWindowAndTheUnscaledRandomEnd() public view {
        assertEq(roundManager.closingWindowFor(1), 180, "W is scaled by the divisor");
        assertEq(roundManager.RANDOM_END_S(), 180, "the random-end span is not");
        uint256 needed = roundManager.closingWindowFor(1) + roundManager.RANDOM_END_S();
        assertEq(needed, 360, "180 + 180");
        assertEq(roundManager.scoreSlotFor(1), 6, "ceil(360 / 63)");
        assertGe((hook.SCORE_COARSE_SLOTS() - 1) * roundManager.scoreSlotFor(1), needed, "the ring covers it");
        assertGt(roundManager.closingWindowFor(1), roundManager.scoreSlotFor(1), "W exceeds one coarse slot");
    }

    /// @notice The clamp holds for every round of the schedule, and the window is never zero:
    /// `fulfilEnd` takes `word mod W_r`, which a zero window would make undefined.
    function test_theWindowIsNeverZeroAndNeverMoreThanAQuarter() public view {
        for (uint256 n = 1; n <= 32; n++) {
            uint64 w = roundManager.randomEndWindowFor(n);
            assertGt(w, 0, "the modulus is defined");
            assertLe(w, roundManager.RANDOM_END_S(), "never longer than RANDOM_END_S");
            assertLe(uint256(w) * 4, roundManager.durationFor(n), "never more than a quarter of the round");
        }
    }

    /// @notice LATE ENTRY ON A SCALED SCHEDULE. The divisor shrinks the late-entry window with
    /// the round but never decides WHETHER a round offers one: that is read off the unscaled
    /// `D(n)`, so late entry starts on round 7 here too, at a fifth of the mainnet length.
    function test_lateEntryFollowsTheUnscaledRuleAtADivisor() public view {
        for (uint256 n = 1; n <= 6; n++) {
            assertEq(roundManager.lateEntryUntil(n), 0, "no late entry below an unscaled hour");
        }
        assertEq(roundManager.lateEntryUntil(7), 256, "1280 / 5");
        assertEq(roundManager.lateEntryUntil(9), 512, "2560 / 5");
        assertEq(roundManager.lateEntryUntil(15), 2640, "13200 / 5");
        for (uint256 n = 7; n <= 20; n++) {
            uint64 windowOpens =
                roundManager.durationFor(n) - roundManager.closingWindowFor(n) - roundManager.randomEndWindowFor(n);
            assertLt(roundManager.lateEntryUntil(n), windowOpens, "still closes before the closing window opens");
        }
    }
}
