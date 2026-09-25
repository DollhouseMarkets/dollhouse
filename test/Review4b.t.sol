// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";

/// @notice REGRESSIONS pinning the score-ring freeze and related properties. Some of these
/// properties are also exercised beside related tests in `Review4.t.sol` and
/// `DeployConstants.t.sol`.
///
/// The ring freeze is the one that matters. An exact-sample fallback alone closes a denial, but
/// opens a SELECTION: after the reveal, anyone could bury the fast ring in dust and push the
/// `T_end` edge off the live state and onto whichever sample the rings had left, changing a score
/// the reveal was supposed to have fixed. The fix is not a bigger ring but a FREEZE: past the
/// pool's published end `T`, swaps still move the live accumulator and write no ring entries at
/// all, so the whole of `[T_end - W, T_end]` is beyond the reach of post-bell flow by
/// construction.
contract Review4bTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        // the cases below are stated in whole {FamilyHook.SCORE_SLOT_S} slots
        vm.warp(block.timestamp + (5 - (block.timestamp % 5)) % 5);
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // The ring freezes at the published end
    // ---------------------------------------------------------------------------------

    /// @notice THE REVIEWER'S SCENARIO. The round's last swap is in the bell's own fast slot, so
    /// the `T_end` edge has no bracketing checkpoint once the fast ring turns over; before the
    /// freeze, three minutes of one-per-slot dust after the reveal therefore moved the edge onto
    /// the coarse sample at `T_end - 1` and CHANGED the score. Nothing after the bell writes a
    /// ring entry any more, so the value is the one measured at `T_end`, whatever is swapped.
    function test_postRevealDustCannotSelectADifferentScore() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        uint64 w = roundManager.closingWindowFor(roundManager.roundCount());

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);

        // the first swap of the bell's COARSE slot, well before the bell...
        vm.warp(nominalEnd - 40);
        _tradeCandidate(a, true, WINNING_BUY / 500);
        // ...and the round's last swap, one second before it: the fast slot containing `T_end` is
        // now stamped BEFORE `T_end`, so it can never bracket it
        vm.warp(nominalEnd - 1);
        _tradeCandidate(a, true, WINNING_BUY / 1000);

        (int256 expected,,, uint64 tEndUsed) = hook.averageOver(a.poolId, nominalEnd - w, nominalEnd);
        assertEq(tEndUsed, nominalEnd, "the edge resolves at the bell exactly, off the live state");

        (uint64 tradingEnd, uint64 submitEnd) = _settleEnd();
        assertEq(tradingEnd, nominalEnd, "a word of zero ends the round at T");

        // one swap just past the bell, inside its own 5-second neighbourhood...
        vm.warp(nominalEnd + 2);
        _tradeCandidate(a, true, WINNING_BUY / 1000);
        // ...then one per fast slot for the whole span the fast ring covers
        for (uint256 i = 0; i <= hook.SCORE_SLOTS(); i++) {
            _tradeCandidate(a, true, 1e12);
            vm.warp(block.timestamp + hook.SCORE_SLOT_S());
        }

        (int256 got,,, uint64 tEndAfter) = hook.averageOver(a.poolId, nominalEnd - w, nominalEnd);
        assertEq(tEndAfter, nominalEnd, "the edge still resolves at the bell");
        assertEq(got, expected, "and post-reveal dust cannot select a different score");

        vm.warp(submitEnd - 1);
        assertEq(roundManager.submitScore(a.id), expected, "the round records the same number");
    }

    /// @notice The property behind it, stated directly: every ring entry stamped at or before the
    /// published end is byte-identical after 300 seconds of post-bell dust, and no entry stamped
    /// after the bell ever appears.
    function test_theRingIsByteIdenticalAfterPostBellDust() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);
        vm.warp(nominalEnd - 30);
        _tradeCandidate(a, true, WINNING_BUY / 500);
        vm.warp(nominalEnd);
        _tradeCandidate(a, true, WINNING_BUY / 1000);

        IFamilyHook.ScoreCheckpoint[] memory before = _rings(a.poolId);
        _settleEnd();

        for (uint64 t = nominalEnd + 1; t <= nominalEnd + 300; t += 5) {
            vm.warp(t);
            _tradeCandidate(a, true, 1e12);
        }

        IFamilyHook.ScoreCheckpoint[] memory got = _rings(a.poolId);
        uint256 written;
        for (uint256 i = 0; i < before.length; i++) {
            assertLe(got[i].tSwap, nominalEnd, "no entry is ever stamped after the bell");
            assertEq(got[i].tSwap, before[i].tSwap, "tSwap");
            assertEq(got[i].tState, before[i].tState, "tState");
            assertEq(got[i].R, before[i].R, "R");
            assertEq(got[i].acc, before[i].acc, "acc");
            if (before[i].tSwap != 0) written++;
        }
        assertGt(written, 0, "the pool really did have a ring to preserve");
    }

    /// @notice The freeze is of the RINGS, not of the score. A swap after the published end still
    /// moves the live accumulator, which is what the chain's permanent support measure is read
    /// from: `trailingAverage` and `scoreState` keep working for the rest of the pool's life.
    function test_aSwapAfterTheEndStillMovesTheLiveAccumulator() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 100);
        _tradeCandidate(a, true, WINNING_BUY);
        _settleEnd();

        vm.warp(nominalEnd + 60);
        (int256 accBefore, int128 rBefore,) = hook.scoreState(a.poolId);
        _tradeCandidate(a, true, WINNING_BUY / 10);
        (int256 accAfter, int128 rAfter, uint64 tLast) = hook.scoreState(a.poolId);

        assertGt(rAfter, rBefore, "the rate absorbed the post-bell buy");
        assertGt(accAfter, accBefore, "and the accumulator integrated the elapsed time");
        assertEq(tLast, nominalEnd + 60, "the live state is stamped now, not at the bell");

        vm.warp(nominalEnd + 300);
        (int256 avg, uint32 covered) = hook.trailingAverage(a.poolId, 600);
        assertGt(avg, 0, "the trailing view still answers after the freeze");
        assertGt(covered, 0, "over a span it really measured");
    }

    // ---------------------------------------------------------------------------------
    // The far edge drifts by at most one coarse slot
    // ---------------------------------------------------------------------------------

    /// @notice Restated honestly. Post-bell flow cannot change the sampled instant or the
    /// value at all; what an adversary CAN still do is dust the far edge of the window
    /// BEFORE the bell, so that `T_end - W` has no bracketing checkpoint and resolves to the
    /// nearest earlier sample. That drift is bounded by ONE COARSE SLOT - 18 s on the mainnet
    /// schedule against a 900-second window - and the instant is never later than the edge.
    function test_farEdgeDriftIsAtMostOneCoarseSlot() public {
        // round 3 is the first whose duration (30 min) exceeds the flat 15-minute window, so the
        // far edge falls strictly inside the round rather than on the pool's own open
        _runWinningRound(1, WINNING_BUY);
        _runWinningRound(1, WINNING_BUY);

        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        uint256 roundId = roundManager.roundCount();
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundId);
        uint64 w = roundManager.closingWindowFor(roundId);
        uint64 cs = uint64(roundManager.scoreSlotFor(roundId));
        uint64 farEdge = nominalEnd - w;

        vm.warp(tradingStart + 50);
        _tradeCandidate(a, true, WINNING_BUY / 10);

        // ADVERSARIAL DUST across the far edge: a swap every other second from the coarse-slot
        // boundary at or before the edge, so that slot's only entry is stamped before the edge
        // and every later one is stamped after it. No checkpoint brackets `farEdge` at all.
        uint64 gridFrom = (farEdge / cs) * cs;
        assertGt(gridFrom, tradingStart + 50, "the grid starts after the pool opened");
        for (uint64 t = gridFrom; t <= farEdge + 2 * cs; t += 2) {
            vm.warp(t);
            _tradeCandidate(a, true, 1e12);
        }
        // and one more swap inside the closing window, so the near edge is the live state
        vm.warp(nominalEnd);
        _tradeCandidate(a, true, WINNING_BUY / 1000);

        (uint64 tradingEnd,) = _settleEnd();
        (, , uint64 tStartUsed, uint64 tEndUsed) = hook.averageOver(a.poolId, tradingEnd - w, tradingEnd);

        assertLe(tStartUsed, tradingEnd - w, "the measured start is never later than the far edge");
        assertLe(
            uint256(tradingEnd - w) - uint256(tStartUsed), cs, "and never more than one coarse slot before it"
        );
        assertEq(tEndUsed, tradingEnd, "the near edge is unaffected: it is the bell exactly");
        assertGt(roundManager.submitScore(a.id), 0, "and the round still scores");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev Both rings of a pool in one array: the fast ring first, then the coarse one.
    function _rings(PoolId id) internal view returns (IFamilyHook.ScoreCheckpoint[] memory ring) {
        uint256 fast = hook.SCORE_SLOTS();
        uint256 coarse = hook.SCORE_COARSE_SLOTS();
        ring = new IFamilyHook.ScoreCheckpoint[](fast + coarse);
        for (uint256 i = 0; i < fast; i++) {
            ring[i] = hook.scoreCheckpoint(id, i);
        }
        for (uint256 i = 0; i < coarse; i++) {
            ring[fast + i] = hook.coarseCheckpoint(id, i);
        }
    }
}
