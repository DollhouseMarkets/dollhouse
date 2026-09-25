// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Test.sol";
// the successor().factory().feeVault() walk, already stubbed here
import {SuccessorRegistryStub, SuccessorFactoryStub} from "./Review2.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice REGRESSIONS from the automated audit report. Each test pins the guarantee so it
/// comes from the contract rather than from a reading of it.
contract Review4Test is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;
    /// @dev The attribution the EDGE fee is queued under: the terminal canonical index, which for
    /// a $DOLL -> link-one buy is 1. The edge is not at index 0.
    uint256 internal constant QUEUE_KEY = 1;

    /// @dev Declared locally so that {vm.expectEmit} can name them before the vault does.
    event SuccessorDeclaredDead(address indexed successor, uint256 attribution, uint256 amount);
    event SuccessorDeliveryFailed(uint256 indexed attribution, bytes reason);
    event SuccessorUnresolved(address indexed successor);
    event SuccessorDeliveryEvidenceCleared(uint256 indexed attribution);

    function setUp() public {
        // the score-ring cases below are stated in whole {FamilyHook.SCORE_SLOT_S} slots, so the
        // schedule is aligned to one before any round opens
        vm.warp(block.timestamp + (5 - (block.timestamp % 5)) % 5);
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // 1. score availability: the ring must always answer for `T_end`
    // ---------------------------------------------------------------------------------

    /// @notice A slot holds the state before its FIRST swap, so a second swap in the SAME slot as
    /// the bell leaves no checkpoint whose interval brackets `T_end`: the round's score became
    /// unreadable and every candidate of the round was denied. The exact-sample fallback answers
    /// out of the checkpoint written AT `T_end`, which is the exact value.
    function test_aSecondSwapInTheBellsOwnSlotCannotDenyTheScore() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        assertLt(nominalEnd % hook.SCORE_SLOT_S(), 4, "the bell leaves room for a later swap in its own slot");

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);

        // the last swap of the round lands exactly on the bell
        vm.warp(nominalEnd);
        _tradeCandidate(a, true, WINNING_BUY / 1000);
        uint64 w = roundManager.closingWindowFor(roundManager.roundCount());
        (int256 expected,,,) = hook.averageOver(a.poolId, nominalEnd - w, nominalEnd);

        (uint64 tradingEnd,) = _settleEnd();
        assertEq(tradingEnd, nominalEnd, "the word is 0, so T_end is the nominal end");

        // ...and one more swap one second later, in the same 5-second slot
        vm.warp(nominalEnd + 1);
        _tradeCandidate(a, true, WINNING_BUY / 1000);

        int256 avg = roundManager.submitScore(a.id);
        assertEq(avg, expected, "the score at T_end is the checkpoint written at T_end");
        assertTrue(roundManager.roundInfo(roundManager.roundCount()).hasBest, "the round has a best candidate");
    }

    /// @notice The fast ring is 36 slots of 5 seconds. Dust swaps one per slot for three minutes
    /// after the reveal overwrite every one of them, and the coarse slot the bell falls in was
    /// already written before it - so nothing brackets `T_end` any more. The score must still be
    /// submittable at the very last second of the window.
    function test_aRingBuriedUnderPostBellDustStillAnswers() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        uint64 cs = uint64(roundManager.scoreSlotFor(roundManager.roundCount()));

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);

        // draw `T_end` onto a coarse-slot boundary, and put the round's last swap on it: the
        // coarse slot that contains the bell is then written with `tSwap == T_end`, which no
        // later swap can replace and which no bracket search can use
        uint64 word = nominalEnd % cs;
        uint64 tEnd = nominalEnd - word;
        vm.warp(tEnd);
        _tradeCandidate(a, true, WINNING_BUY / 1000);

        (uint64 tradingEnd, uint64 submitEnd) = _settleEndWith(word);
        assertEq(tradingEnd, tEnd, "T_end is the coarse-slot boundary");
        uint64 w = roundManager.closingWindowFor(roundManager.roundCount());
        (int256 expected,,,) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);

        // one dust swap per fast slot, for the whole 180 s the fast ring covers
        for (uint256 i = 0; i <= hook.SCORE_SLOTS(); i++) {
            _tradeCandidate(a, true, 1e12);
            vm.warp(block.timestamp + hook.SCORE_SLOT_S());
        }

        vm.warp(submitEnd - 1);
        int256 avg = roundManager.submitScore(a.id);
        assertEq(avg, expected, "the buried ring still reconstructs the score at T_end exactly");
    }

    /// @notice The FAR edge of the window, `T_end - W`, has the same hole: a swap every 10 s
    /// across the coarse slot that contains it leaves that slot written from BEFORE the edge and
    /// every later slot stamped from after it, so no checkpoint brackets it once the fast ring
    /// has moved on. Round 2, because round 1's window reaches back past the pool's own open.
    function test_theFarEdgeOfTheWindowIsAlwaysResolvable() public {
        // round 3 is the first whose trading duration (30 min) EXCEEDS the flat 15-minute closing
        // window, so `T_end - W` falls strictly inside the round rather than on its own open.
        // `_setUpEdge` already ran round one, so one more round reaches it.
        _runWinningRound(1, WINNING_BUY);

        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        uint256 roundId = roundManager.roundCount();
        assertEq(roundId, 3, "round 3");
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundId);
        assertGt(nominalEnd - tradingStart, roundManager.closingWindowFor(roundId), "the window fits inside");

        vm.warp(tradingStart + 50);
        _tradeCandidate(a, true, WINNING_BUY / 10);
        _tradeCandidate(b, true, WINNING_BUY / 20);

        uint64 cs = uint64(roundManager.scoreSlotFor(roundId));
        uint64 farEdge = nominalEnd - roundManager.closingWindowFor(roundId);
        // the grid starts on the coarse-slot boundary at or before the far edge, so that slot's
        // only checkpoint is stamped at or before it
        uint64 gridFrom = (farEdge / cs) * cs;
        assertGt(gridFrom, tradingStart + 50, "the grid starts after the pool opened");
        for (uint256 i = 0; i <= 36; i++) {
            vm.warp(gridFrom + 10 * i);
            _tradeCandidate(a, true, 1e12);
            _tradeCandidate(b, true, 1e12);
        }

        _settleEnd();
        int256 avgA = roundManager.submitScore(a.id);
        int256 avgB = roundManager.submitScore(b.id);
        assertGt(avgA, 0, "A scored");
        assertGt(avgB, 0, "B scored");
        assertGt(avgA, avgB, "and the coin with more support still scores higher");
    }

    /// @notice The fallback may not become a way to move a score after the reveal: every
    /// checkpoint it can reach is stamped at or before `T_end` and holds the state BEFORE its own
    /// swap, so flow after the bell is invisible to it.
    function test_postBellFlowStillCannotMoveTheScore() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        uint64 cs = uint64(roundManager.scoreSlotFor(roundManager.roundCount()));

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);

        uint64 word = nominalEnd % cs;
        vm.warp(nominalEnd - word);
        _tradeCandidate(a, true, WINNING_BUY / 1000);
        (uint64 tradingEnd,) = _settleEndWith(word);
        uint64 w = roundManager.closingWindowFor(roundManager.roundCount());
        (int256 expected,,,) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);

        // bury the fast ring, then buy hard - and keep buying
        for (uint256 i = 0; i <= hook.SCORE_SLOTS(); i++) {
            _tradeCandidate(a, true, 1e12);
            vm.warp(block.timestamp + hook.SCORE_SLOT_S());
        }
        (int256 buried,,,) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);
        assertEq(buried, expected, "burying the ring does not move the score");

        _tradeCandidate(a, true, WINNING_BUY);
        (int256 after1,,,) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);
        assertEq(after1, expected, "a post-bell buy does not move the score");
        vm.warp(block.timestamp + 7);
        _tradeCandidate(a, true, WINNING_BUY);
        (int256 after2,,,) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);
        assertEq(after2, expected, "and neither does a second one");
    }

    /// @notice A pool that is registered but not yet open has no history at all. The question is
    /// answerable without underflow, and the answer is "nothing covered".
    function test_trailingAverageBeforeTheOpenDoesNotRevert() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        assertLt(block.timestamp, tradingStart, "the pool has not opened yet");

        (int256 avg, uint32 covered) = hook.trailingAverage(a.poolId, 1800);
        assertEq(avg, 0, "no average before the open");
        assertEq(covered, 0, "and no coverage claimed");

        // and at the open itself, still nothing covered rather than a revert
        vm.warp(tradingStart);
        (avg, covered) = hook.trailingAverage(a.poolId, 1800);
        assertEq(avg, 0, "no average at the open");
        assertEq(covered, 0, "and no coverage claimed");
    }

    /// @notice A denied submission must be legible after the fact: a round that finalizes with no
    /// score at all says so on chain.
    function test_aRoundWithNoSubmittedScoreSaysSo() public {
        _registerCandidate(address(0xA11CE), "A");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);

        vm.recordLogs();
        roundManager.finalize();
        assertTrue(_sawNoScoreSubmitted(2), "finalize reports that no score was ever submitted");
    }

    function _sawNoScoreSubmitted(uint256 roundId) internal returns (bool) {
        bytes32 sig = keccak256("NoScoreSubmitted(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(roundManager) || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) == roundId) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------
    // 2. a successor that never answers may not freeze the queue forever
    // ---------------------------------------------------------------------------------

    /// @dev Sunset this version in favour of a stack that RESOLVES to a vault which refuses every
    /// delivery, and charge one edge fee so that the forward queue holds something. A successor
    /// that does not resolve at all is a different case entirely and is never
    /// evidence of a dead one, so the recovery path has to be exercised against a real refusal.
    function _queueBehindADeadSuccessor() internal returns (address stub, uint256 fee) {
        FlakySuccessorVault v = new FlakySuccessorVault();
        v.setFailing(true);
        stub = _sunsetTowards(address(v));
        // the canonical router attributes the edge to the terminal index, so the queue key is 0
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    /// @notice The queue is not allowed to depend entirely on a successor that
    /// answers: the escape is TWO-PHASE. The first full-budget failure only
    /// records evidence against that attribution and forwards nothing; only a SECOND full-budget
    /// failure, {FeeVault.DEAD_SUCCESSOR_DELAY} after the first, books the fee here.
    function test_aDeadSuccessorCannotFreezeTheQueueForever() public {
        (address stub, uint256 fee) = _queueBehindADeadSuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        // PHASE ONE: the successor's vault refuses the delivery, which is said out loud, and the
        // failure is recorded rather than acted on
        uint64 evidenceAt = uint64(block.timestamp);
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorDeliveryFailed(attribution, "");
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "nothing is forwarded on the first failure");
        assertEq(vault.deadEvidenceAt(attribution), evidenceAt, "the clock starts HERE, on evidence");
        assertEq(vault.pendingForward(attribution), fee, "still queued");
        assertEq(vault.devBalance(), devBefore, "and nothing booked locally");
        _assertSolvent();

        // inside the timelock the fee stays queued: the successor may still come to life
        vm.warp(uint256(evidenceAt) + 29 days);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "still nothing");
        assertEq(vault.pendingForward(attribution), fee, "still queued");
        assertEq(vault.devBalance(), devBefore, "still nothing booked");

        // PHASE TWO: the delay has run out behind the recorded evidence AND this attempt failed
        vm.warp(uint256(evidenceAt) + 30 days + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SuccessorDeclaredDead(stub, attribution, fee);
        uint256 flushed = vault.flushForward(attribution, type(uint256).max);

        assertEq(flushed, fee, "the whole queued fee was recovered");
        assertEq(vault.pendingForward(attribution), 0, "the queue is empty");
        assertEq(vault.pendingForwardTotal(), 0, "and so is its total");
        assertGt(vault.devBalance() - devBefore, 0, "booked with this version's split");
        _assertSolvent();
    }

    /// @notice A successor that does not RESOLVE YET is not a successor that is
    /// DEAD. The registry names a stack whose vault is still to be deployed at the address its
    /// factory already publishes; until that address has code there is no delivery attempt to
    /// fail, so the flush says so and records NOTHING. Counting an unresolved hop as evidence let
    /// this version take the whole queue for itself thirty days into a handover that was merely
    /// unfinished, without one real delivery ever having been refused.
    function test_anUnresolvedSuccessorIsNeverEvidenceOfADeadOne() public {
        // the address the successor's factory publishes, before anything is deployed at it
        address predicted = address(0xFEE7A17);
        address successor = _sunsetTowards(predicted);
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        uint256 fee = 1 ether / 100;
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();
        assertEq(vault.pendingForward(attribution), fee, "the edge is queued, not booked");

        // day 0, full gas: the resolution fails, which is said out loud and is all that happens
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorUnresolved(successor);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "there is nobody to deliver to");
        assertEq(vault.deadEvidenceAt(attribution), 0, "an unresolved successor is not evidence");

        // day 31, full gas: a month of the same answer is still not evidence, and the timelock
        // has nothing to run against
        vm.warp(block.timestamp + 31 days);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "still nothing forwarded");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and still no evidence");
        assertEq(vault.pendingForward(attribution), fee, "the fee is still the successor's");
        assertEq(vault.devBalance(), devBefore, "nothing was booked locally");
        _assertSolvent();

        // the vault is deployed at the address the factory always named, and the queue goes
        // where it belongs
        vm.etch(predicted, address(new FlakySuccessorVault()).code);
        assertEq(vault.flushForward(attribution, type(uint256).max), fee, "delivered");
        assertEq(vault.pendingForward(attribution), 0, "the queue is empty");
        assertEq(doll.balanceOf(predicted), fee, "the successor really has the $DOLL");
        _assertSolvent();
    }

    /// @notice THE PROPERTY. The clock runs on evidence about the successor itself, NOT on when
    /// the queue filled: a perfectly healthy successor that simply had nothing pushed to it for
    /// thirty days is never declared dead by the very FIRST flush ever made, on one transient
    /// revert. It takes two full-budget failures a month apart, and one transient revert is not
    /// two.
    function test_aHealthySuccessorCannotBeDeclaredDead() public {
        (FlakySuccessorVault successorVault, uint256 fee) = _queueBehindAFlakySuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        // the OLD clock is long expired: the queue has been sitting here for a month
        uint64 flushedAt = uint64(block.timestamp + 30 days + 1);
        vm.warp(flushedAt);

        // ...and the successor reverts once, the way a live contract transiently can
        successorVault.setFailing(true);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "the transient revert forwards nothing");
        assertEq(vault.devBalance(), devBefore, "and books NOTHING locally: one revert is not evidence enough");
        assertEq(vault.pendingForward(attribution), fee, "the fee is still the successor's");
        assertEq(vault.deadEvidenceAt(attribution), flushedAt, "it only started the clock");
        _assertSolvent();

        // the successor is healthy again, so the very next flush delivers
        successorVault.setFailing(false);
        uint256 flushed = vault.flushForward(attribution, type(uint256).max);
        assertEq(flushed, fee, "delivered");
        assertEq(doll.balanceOf(address(successorVault)), fee, "the successor really has the $DOLL");
        assertEq(vault.devBalance(), devBefore, "still nothing booked here");
        _assertSolvent();
    }

    /// @notice ...and a delivery WITHDRAWS the evidence, so a successor that has one bad month
    /// does not carry a half-spent death sentence forever.
    function test_evidenceClearsOnDelivery() public {
        (FlakySuccessorVault successorVault, uint256 fee) = _queueBehindAFlakySuccessor();
        uint256 attribution = QUEUE_KEY;

        uint64 firstFailureAt = uint64(block.timestamp);
        successorVault.setFailing(true);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), firstFailureAt, "evidence stands");

        // half the queue is delivered: that is proof of life
        successorVault.setFailing(false);
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorDeliveryEvidenceCleared(attribution);
        assertEq(vault.flushForward(attribution, fee / 2), fee / 2, "half forwarded");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and the evidence is withdrawn");

        // so a later failure starts a FRESH thirty days rather than completing the old ones
        uint64 secondFailureAt = firstFailureAt + 29 days;
        vm.warp(secondFailureAt);
        successorVault.setFailing(true);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), secondFailureAt, "the clock restarted here");
        vm.warp(uint256(secondFailureAt) + 29 days);
        uint256 devBefore = vault.devBalance();
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "29 days is not 30");
        assertEq(vault.devBalance(), devBefore, "nothing booked on the old clock");
        _assertSolvent();
    }

    /// @notice The queue entry and the ledger are debited BEFORE the successor is
    /// called, so at no instant of ITS execution does this vault count the same wei twice - once
    /// as $DOLL already sent and once as still queued. The successor reads the prior vault from
    /// inside `receiveForward` and the numbers it sees are the ones that must hold.
    function test_noTransientDoubleCountDuringTheHandoverCall() public {
        (ObservingSuccessorVault successorVault, uint256 fee) = _queueBehindAnObservingSuccessor();
        uint256 attribution = QUEUE_KEY;

        assertEq(vault.flushForward(attribution, type(uint256).max), fee, "delivered");
        assertEq(successorVault.seenPending(), 0, "the queue no longer counts what is already in flight");
        assertLe(successorVault.seenLedger(), successorVault.seenHoldings(), "and the vault looks solvent throughout");
        _assertSolvent();
    }

    /// @dev Sunset this version in favour of a stack that DOES resolve to a vault, and charge one
    /// edge fee. The in-swap hop fails (the stub has no `accrueForwarded`), so the fee queues
    /// exactly as it does behind a dead successor - but the flush path can reach it.
    function _queueBehindAFlakySuccessor() internal returns (FlakySuccessorVault v, uint256 fee) {
        v = new FlakySuccessorVault();
        _sunsetTowards(address(v));
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    function _queueBehindAnObservingSuccessor() internal returns (ObservingSuccessorVault v, uint256 fee) {
        v = new ObservingSuccessorVault(address(vault));
        _sunsetTowards(address(v));
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    /// @dev Name a successor whose `factory().feeVault()` resolves to `successorVault`.
    function _sunsetTowards(address successorVault) internal returns (address successor) {
        SuccessorFactoryStub f = new SuccessorFactoryStub(successorVault);
        SuccessorRegistryStub reg = new SuccessorRegistryStub(address(f));
        successor = address(reg);
        vm.prank(steward);
        roundManager.announceSunset(successor);
        vm.warp(roundManager.sunsetAt());
    }

    /// @notice ...and a caller cannot declare the successor dead by starving the hop of gas: the
    /// recovery only arms behind a delivery attempt that had the full {FeeVault.FORWARD_GAS}, and
    /// a thin-gas call may not even RECORD the evidence that starts the clock.
    function test_aThinGasFlushCannotDeclareTheSuccessorDead() public {
        (, uint256 fee) = _queueBehindADeadSuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        (bool ok,) = address(vault).call{gas: 2_000_000}(
            abi.encodeCall(FeeVault.flushForward, (attribution, type(uint256).max))
        );
        assertFalse(ok, "a thin-gas flush is refused");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and it recorded no evidence against the successor");
        assertEq(vault.pendingForward(attribution), fee, "nothing left the queue");
        assertEq(vault.devBalance(), devBefore, "and nothing was booked locally");
        _assertSolvent();

        // the honest calls still work: one to record the evidence, one to act on it
        uint64 recordedAt = uint64(block.timestamp);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), recordedAt, "full gas records it");
        vm.warp(uint256(recordedAt) + 30 days + 1);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.pendingForward(attribution), 0, "a second full-gas flush recovers it");
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // 3. the v4 protocol-fee snapshot is per leg, not per transaction
    // ---------------------------------------------------------------------------------

    /// @notice The snapshot of Uniswap's own protocol fee is keyed by currency and lives in
    /// transient storage. Two pools of the SAME parent in ONE unlock therefore shared it: the leg
    /// on the pool with no v4 fee read the previous leg's snapshot and subtracted a fee its own
    /// pool never paid, understating its score. The two legs must be in one unlock - transient
    /// storage does not survive between two top-level calls under the test runner.
    function test_aStaleProtocolFeeSnapshotCannotUnderstateALaterPool() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 60); // past the snipe window

        TwoLegSwapper legs = new TwoLegSwapper(manager);
        Currency parent = Currency.wrap(roundManager.head());
        IERC20(Currency.unwrap(parent)).approve(address(legs), type(uint256).max);

        // only pool A carries a v4 protocol fee
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(a.key, ProtocolFeeLibrary.MAX_PROTOCOL_FEE | (ProtocolFeeLibrary.MAX_PROTOCOL_FEE << 12));

        uint256 amountIn = 1_000e18;
        uint256 accruedBefore = manager.protocolFeesAccrued(parent);
        int128 rBefore = hook.poolInfo(b.poolId).R;

        legs.swapTwo(
            TwoLegSwapper.Legs({
                a: a.key,
                aZeroForOne: !a.tokenIsCurrency0,
                b: b.key,
                bZeroForOne: !b.tokenIsCurrency0,
                amountIn: amountIn,
                payer: address(this)
            })
        );

        uint256 takenOnA = manager.protocolFeesAccrued(parent) - accruedBefore;
        assertGt(takenOnA, 0, "the v4 fee really was charged on A");
        uint256 hopFee = (amountIn * HOP_FEE_PPM) / PPM;
        assertEq(
            int256(hook.poolInfo(b.poolId).R) - int256(rBefore),
            int256(amountIn - hopFee),
            "B scores what stayed in B, with no fee of A's subtracted"
        );
    }

    // ---------------------------------------------------------------------------------
    // 5. a payout may not be burned
    // ---------------------------------------------------------------------------------

    /// @notice Every payout refuses `address(0)`: without the guard, since the ledger is debited
    /// before the send, a mistyped destination would burn the claim permanently.
    function test_noPayoutPathCanBurnAPayoutAtTheZeroAddress() public {
        // an ATTRIBUTED edge buy, so both the developer and link one's creator are owed something
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        assertGt(vault.devBalance(), 0, "the edge buy accrued a developer share");
        vm.prank(vault.developer());
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.claimDev(address(0));

        address edgeToken = roundManager.canonical(1);
        address creator = vault.creatorRecipient(edgeToken);
        assertGt(vault.creatorBalance(edgeToken), 0, "and a creator share");
        vm.prank(creator);
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.claimCreator(edgeToken, address(0));

        // the ledgers are untouched by the refusal, and the honest claim still pays
        uint256 owed = vault.devBalance();
        vm.prank(vault.developer());
        uint256 paid = vault.claimDev(address(0xD00D));
        assertEq(paid, owed, "the developer share is still there to claim");
        assertEq(doll.balanceOf(address(0xD00D)), owed, "and it arrived");
        _assertSolvent();
        _assertNoEth();
    }
}

/// @notice Item 4: attribution across the sunset handover. Needs two complete stacks,
/// and a v1 round that is still TRADING when the handover takes effect - so this deployment uses
/// the {RoundManager.MIN_SUNSET_DELAY} floor rather than the mainnet seven days.
contract Review4ContinuationTest is RoundTestBase {
    address internal constant STEWARD = address(0x57E4A2D);
    Currency internal constant EDGE = Currency.wrap(DOLL_ADDRESS);

    Stack internal v1;
    Stack internal v2;

    function setUp() public {
        steward = STEWARD;
        sunsetDelay = 1 hours;
        _setUpEdge();
        v1 = _currentStack();
        _buyLink(1, 5 ether);
        v2 = _deployStack(true, STEWARD, address(v1.roundManager));
    }

    /// @notice A CANDIDATE attribution is a local index into this version's own `candidates`
    /// array. Forwarded across the handover it named some entirely unrelated coin in the
    /// successor's array - or nothing at all, which queued the fee behind a hop that could never
    /// complete. It crosses as {FeeVault.UNATTRIBUTED} instead.
    function test_aCandidateAttributionDoesNotCrossTheHandover() public {
        vm.prank(STEWARD);
        v1.roundManager.announceSunset(address(v2.roundManager));
        uint64 at = v1.roundManager.sunsetAt();

        // a v1 round that outlives the handover: the sunset stops v1 opening a NEW round, it does
        // not stop the one already open from trading
        vm.warp(at - 300);
        Cand memory c = _registerCandidate(address(0xCA11), "CAND");
        (, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        assertLt(at, nominalEnd, "the round is still trading when the handover lands");

        vm.warp(at + 1);
        assertTrue(v1.roundManager.isSunsetEffective(), "the handover is live");

        uint256 v2LedgerBefore = v2.vault.ledgerTotal(EDGE);
        vm.recordLogs();
        v1.router.buyCandidate(c.id, 1 ether, 0, address(this), 4);

        uint256 fee = 1 ether / 100;
        assertEq(v2.vault.ledgerTotal(EDGE) - v2LedgerBefore, fee, "the edge reached v2");
        assertEq(_receivedAttribution(), vault.UNATTRIBUTED(), "and it crossed unattributed");
        assertEq(v2.vault.creatorBalance(c.token), 0, "v1's candidate is not a creator in v2");
        assertEq(v2.vault.devBalance(), (fee * v2.vault.DEV_BPS()) / 10_000, "v2 booked it with its own split");
        assertEq(v1.vault.pendingForward(vault.CANDIDATE_ATTRIBUTION() | c.id), 0, "nothing queued under the id");
        assertLe(v1.vault.ledgerTotal(EDGE), v1.vault.holdings(EDGE), "v1 stays solvent");
        assertLe(v2.vault.ledgerTotal(EDGE), v2.vault.holdings(EDGE), "v2 stays solvent");
    }

    /// @dev The attribution v2's vault was actually handed, out of its own receipt event.
    function _receivedAttribution() internal returns (uint256) {
        bytes32 sig = keccak256("ProtocolFeeReceived(address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(v2.vault) || logs[i].topics[0] != sig) continue;
            (, uint256 attribution) = abi.decode(logs[i].data, (uint256, uint256));
            return attribution;
        }
        revert("v2 never received the edge");
    }
}

/// @dev Two exact-in swaps on two pools inside ONE `PoolManager` unlock, settled together. The
/// hook's transient per-currency snapshot of the v4 protocol fee only spans a transaction, so a
/// test that drives the two legs as separate top-level calls cannot see it at all.
contract TwoLegSwapper is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    struct Legs {
        PoolKey a;
        bool aZeroForOne;
        PoolKey b;
        bool bZeroForOne;
        uint256 amountIn;
        address payer;
    }

    IPoolManager internal immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swapTwo(Legs memory legs) external {
        manager.unlock(abi.encode(legs));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the PoolManager");
        Legs memory legs = abi.decode(data, (Legs));
        manager.swap(legs.a, _params(legs.aZeroForOne, legs.amountIn), "");
        manager.swap(legs.b, _params(legs.bZeroForOne, legs.amountIn), "");
        _settle(legs.a.currency0, legs.payer);
        _settle(legs.a.currency1, legs.payer);
        _settle(legs.b.currency0, legs.payer);
        _settle(legs.b.currency1, legs.payer);
        return "";
    }

    function _params(bool zeroForOne, uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    /// @dev Idempotent per currency: the parent appears in both keys and is settled by whichever
    /// call reaches it first, after which its delta is zero.
    function _settle(Currency c, address payer) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d < 0) c.settle(manager, payer, uint256(-d), false);
        else if (d > 0) c.take(manager, payer, uint256(d), false);
    }
}


/// @dev A successor vault that takes delivery unless it is switched to failing. The switch is
/// EXTERNAL on purpose: a revert inside `receiveForward` rolls back any state it wrote, so a
/// self-decrementing counter would stay stuck at its initial value forever. It deliberately does
/// NOT implement `accrueForwarded`, so the in-swap hop always fails and the fee queues.
contract FlakySuccessorVault {
    bool public failing;
    uint256 public received;

    function setFailing(bool f) external {
        failing = f;
    }

    function receiveForward(uint256, uint256 amount) external {
        if (failing) revert("transient");
        received += amount;
    }

    receive() external payable {}
}

/// @dev A successor vault that reads the PRIOR vault's books from inside the handover call: what
/// it sees is the state foreign code observes while the hop is in flight.
contract ObservingSuccessorVault {
    FeeVault internal immutable prior;
    uint256 public seenPending;
    uint256 public seenLedger;
    uint256 public seenHoldings;

    constructor(address _prior) {
        prior = FeeVault(payable(_prior));
    }

    function receiveForward(uint256 attribution, uint256) external {
        Currency edge = prior.EDGE();
        seenPending = prior.pendingForward(attribution);
        seenLedger = prior.ledgerTotal(edge);
        seenHoldings = prior.holdings(edge);
    }

    receive() external payable {}
}
