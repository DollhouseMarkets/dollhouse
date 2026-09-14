// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @notice Fork scenarios 4 and 5 of docs/spec/PROPERTIES.md sec.4 on the real `PoolManager`: a
/// scaled long round with a late entrant and a closing-window contest, and the beacon-timeout
/// fallback. Covers RND-04/05/06/07/11, SCR-07/09/10.
///
/// @dev The random end is driven by the labelled mock source, exactly as a testnet deployment of
/// the script does when `RANDOMNESS_SOURCE` is unset. A REAL drand relay cannot run against a
/// pinned fork: the beacon for the pinned round does not exist at the pinned timestamp and no
/// relayer submits into a local fork. The beacon verifier itself is covered on chain by the unit
/// tier (`test/Drand.t.sol`, real beacons against the deployed group key).
contract RoundForkTest is ForkBase {
    /// @dev Round 5 is the first round whose UNSCALED duration reaches `LATE_ENTRY_FROM_S`, so
    /// it is the first round that offers late entry at all.
    uint256 internal constant LONG_ROUND = 5;
    /// @dev The parent-token support each contender puts behind its pool.
    uint256 internal constant SUPPORT = 1_000_000e18;

    function setUp() public {
        if (!_setUpForkFamily()) return;
        _buyGenesis(30 ether);
    }

    /// @dev One round that crowns nobody: a single candidate whose support stays far below the
    /// threshold, carried through settlement and finalization. Used only to advance the round
    /// number to one that offers late entry.
    function _runFailedRound() internal {
        Cand memory c = _registerCandidate(address(uint160(0xFA11ED + roundManager.roundCount())), "NIL");
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(c, true, 1e18);
        _settleEnd();
        roundManager.submitScore(c.id);
        vm.warp(submitEnd + 1);
        roundManager.finalize();
    }

    function _advanceToLongRound() internal {
        while (roundManager.roundCount() < LONG_ROUND - 1) {
            _runFailedRound();
        }
        assertEq(roundManager.headIndex(), 0, "no failed round crowned anything");
    }

    /// @notice RND-04/RND-05: `requestEnd` is callable only at or after `T` and only once, and on
    /// fulfilment `T_end = T - (word mod randomEndWindowFor(n))`, so `T_end` lands inside the
    /// window and the submission window opens at the moment of settlement.
    function testFork_RND04_theEndIsDrawnInsideItsWindow() public {
        _requireFork();
        Cand memory c = _registerCandidate(address(0xA11CE), "R");
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);

        vm.expectRevert(RoundManager.EndNotDue.selector);
        roundManager.requestEnd();

        uint64 window = roundManager.randomEndWindowFor(roundId);
        assertGt(window, 0, "a nonzero draw window");
        uint256 word = 7;

        vm.warp(r.nominalEnd);
        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();

        uint64 settledAt = uint64(block.timestamp);
        roundManager.fulfilEnd(abi.encode(word));
        r = roundManager.roundInfo(roundId);

        assertEq(r.tradingEnd, r.nominalEnd - uint64(word % window), "T_end = T - (word mod the window)");
        assertLe(r.tradingEnd, r.nominalEnd, "never later than T");
        assertGt(r.tradingEnd, r.nominalEnd - window, "and never earlier than the window allows");
        assertEq(r.submitEnd, settledAt + roundManager.SUBMIT_S(), "submission opens at settlement, not at T");
        assertEq(c.id, roundManager.candidateIds(roundId)[0], "the round's only candidate");
    }

    /// @notice SCR-07 and SCR-09 on a round that offers late entry: two contenders with identical
    /// support held across `[T_end - W, T_end]` score identically, however early either pool
    /// opened, and support that was sold back before the window opened counts for nothing.
    function testFork_SCR07_lateEntrantMatchesAnEqualClosingWindowLevel() public {
        _requireFork();
        _advanceToLongRound();

        // ---- the long round opens ----
        Cand memory early = _registerCandidate(address(0xA11CE), "EARLY");
        Cand memory sold = _registerCandidate(address(0xB0B), "SOLD");
        uint256 roundId = roundManager.roundCount();
        assertEq(roundId, LONG_ROUND, "the first round that offers late entry");

        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        uint64 lateEnd = r.lateEntryEnd;
        uint64 window = roundManager.closingWindowFor(roundId);
        assertGt(lateEnd, r.tradingStart, "late entry is open on this round");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        // ---- both early pools take the same support, clear of their own snipe window ----
        vm.warp(r.tradingStart + 4);
        _tradeCandidate(early, true, SUPPORT);
        _tradeCandidate(sold, true, SUPPORT);

        // ---- a late entrant joins inside `lateEntryUntil` ----
        vm.warp(r.tradingStart + 10);
        assertLt(block.timestamp, lateEnd, "still inside the late-entry window");
        Cand memory late = _registerCandidate(address(0xCA7), "LATE");
        assertEq(roundManager.candidateIds(roundId).length, 3, "three contenders in one round");

        // ---- one contender sells its whole position back BEFORE the window opens ----
        vm.warp(r.nominalEnd - window - 5);
        _tradeCandidate(sold, false, IERC20(sold.token).balanceOf(address(this)));

        // ---- the late entrant puts the same support on the board as the window opens ----
        vm.warp(r.nominalEnd - window);
        _tradeCandidate(late, true, SUPPORT);

        // ---- settle at `T` exactly (word 0) and score ----
        (, uint64 submitEnd) = _settleEndWith(0);
        r = roundManager.roundInfo(roundId);
        assertEq(r.tradingEnd, r.nominalEnd, "word 0 settles at T");

        int256 avgEarly = roundManager.submitScore(early.id);
        int256 avgLate = roundManager.submitScore(late.id);
        int256 avgSold = roundManager.submitScore(sold.id);

        assertGt(avgEarly, 0, "a held level scores");
        assertApproxEqRel(uint256(avgLate), uint256(avgEarly), 1e15, "equal closing-window support, equal score");
        assertLt(avgSold, avgEarly / 100, "support sold before the window counts for nothing");

        // ---- RND-07: finalize is refused before the submission window closes, then idempotent
        vm.expectRevert(RoundManager.SubmissionWindowOpen.selector);
        roundManager.finalize();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        address crowned = roundManager.head();
        roundManager.finalize(); // a second call is a no-op
        assertEq(roundManager.head(), crowned, "finalization cannot be replayed onto the head");
    }

    /// @notice SCR-10: a swap after `T_end` still executes and still pays fees, but changes
    /// nothing `submitScore` reads for that round.
    function testFork_SCR10_swapsAfterTheEndDoNotMoveTheSubmittedScore() public {
        _requireFork();
        Cand memory c = _registerCandidate(address(0xA11CE), "L");
        uint256 roundId = roundManager.roundCount();
        (uint64 tradingStart,,) = _roundTimes(roundId);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        vm.warp(tradingStart + 4);
        _tradeCandidate(c, true, SUPPORT);
        (uint64 tradingEnd,) = _settleEndWith(0);

        int256 avgBefore = roundManager.submitScore(c.id);
        vm.warp(uint256(tradingEnd) + 30);
        uint256 out = _tradeCandidate(c, true, SUPPORT);
        assertGt(out, 0, "trading is never gated after the end (RND-16)");

        RoundManager.Candidate memory info = roundManager.candidateInfo(c.id);
        assertEq(info.avg, avgBefore, "the submitted score is bounded at T_end");
    }

    /// @notice RND-06: with no relay at all, anyone may settle `tradingEnd = T` once
    /// `END_TIMEOUT` has passed - loudly, without a prior `requestEnd`, and only once.
    function testFork_RND06_beaconTimeoutFallback() public {
        _requireFork();
        Cand memory c = _registerCandidate(address(0xA11CE), "F");
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);

        vm.warp(r.nominalEnd + 1);
        vm.expectRevert(RoundManager.TimeoutNotReached.selector);
        roundManager.finalizeDeterministic();

        uint64 at = r.nominalEnd + roundManager.END_TIMEOUT() + 1;
        vm.warp(at);
        vm.expectEmit(true, false, false, true, address(roundManager));
        emit RoundManager.RandomEndUnavailable(roundId, r.nominalEnd, at + roundManager.SUBMIT_S());
        vm.prank(address(0xBEEF)); // permissionless: any address may unstick the round
        roundManager.finalizeDeterministic();

        r = roundManager.roundInfo(roundId);
        assertEq(r.tradingEnd, r.nominalEnd, "the deterministic end is exactly T");
        assertEq(r.submitEnd, at + roundManager.SUBMIT_S(), "the submission window opens at the fallback call");

        // the end is settled at most once, by either path
        vm.expectRevert(RoundManager.EndAlreadySettled.selector);
        roundManager.finalizeDeterministic();
        vm.expectRevert(RoundManager.EndAlreadySettled.selector);
        roundManager.fulfilEnd(abi.encode(uint256(0)));

        // ...and the round still scores and finalizes normally
        roundManager.submitScore(c.id);
        vm.warp(uint256(r.submitEnd) + 1);
        roundManager.finalize();
        assertTrue(roundManager.roundInfo(roundId).finalized, "a round never hangs on the beacon");
    }

    /// @notice RND-11: a failed round forfeits every bond to the genesis bid earmark; there is no
    /// third destination for a bond.
    function testFork_RND11_forfeitedBondsLandInTheEarmark() public {
        _requireFork();
        uint256 bond = roundManager.currentBond();
        uint256 earmarkBefore = vault.genesisBidEarmark();
        _runFailedRound();

        assertEq(roundManager.headIndex(), 0, "the round crowned nobody");
        assertEq(vault.genesisBidEarmark() - earmarkBefore, bond, "the loser's whole bond was forfeited");
        _assertSolvent();
    }
}
