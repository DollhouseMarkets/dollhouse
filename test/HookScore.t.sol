// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @dev The start of the window {RoundManager.submitScore} actually scores:
/// `max(tEnd - W, r.tradingStart)`. On the ten-minute rounds `W > D`, so the floor binds.
function _scoredFrom(uint64 tEnd, uint64 w, uint64 tradingStart) pure returns (uint64) {
    uint64 from = tEnd > w ? tEnd - w : 0;
    return from < tradingStart ? tradingStart : from;
}

/// @notice The score is the NET PARENT THAT STAYS IN THE POOL, in every one of the four
/// swap orientations, and a fee skimmed in `beforeSwap` is counted exactly once.
///
/// The pool's parent delta is not directly observable from a test, but it is exactly
/// `-(trader's parent delta) - (parent-denominated fee the vault collected)` in all four cases:
/// every wei the trader parts with either lands in the pool or is minted to the vault as a
/// 6909 claim. Each case below pins `R` against that identity, measured from real balances.
contract HookScoreTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpEdge();
    }

    /// @dev (trader $DOLL delta, fee collected) for one swap on the EDGE pool, link one.
    function _swapAndMeasure(bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 traderDollDelta, uint256 fee, int128 rBefore, int128 rAfter)
    {
        rBefore = hook.poolInfo(poolId).R;
        uint256 vaultBefore = _feeVaultEdge();
        uint256 dollBefore = doll.balanceOf(address(this));
        _swap(swapRouter, zeroForOne, amountSpecified, "");
        traderDollDelta = int256(doll.balanceOf(address(this))) - int256(dollBefore);
        fee = _feeVaultEdge() - vaultBefore;
        rAfter = hook.poolInfo(poolId).R;
    }

    /// @notice UNISWAP'S OWN PROTOCOL FEE. If the v4 fee controller ever switches a
    /// protocol fee on for a family pool, part of the parent a trader pays is taken by the
    /// PoolManager and never becomes pool liquidity. The swapper delta still counts it, so it
    /// would inflate the absorption score a candidate is judged on - a rival could buy a better
    /// score with money that never reached the pool. It is subtracted from the scored input.
    function test_aV4ProtocolFeeDoesNotInflateTheScore() public {
        // the vendored core's own fee-controller path: the test contract owns the PoolManager
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, ProtocolFeeLibrary.MAX_PROTOCOL_FEE | (ProtocolFeeLibrary.MAX_PROTOCOL_FEE << 12));

        uint256 accruedBefore = manager.protocolFeesAccrued(Currency.wrap(address(doll)));
        int128 rBefore = hook.poolInfo(poolId).R;
        uint256 vaultBefore = _feeVaultEdge();
        uint256 dollBefore = doll.balanceOf(address(this));
        _swap(swapRouter, true, -1 ether, "");
        int256 traderDollDelta = int256(doll.balanceOf(address(this))) - int256(dollBefore);
        uint256 fee = _feeVaultEdge() - vaultBefore;
        int128 rAfter = hook.poolInfo(poolId).R;

        uint256 protocolFee = manager.protocolFeesAccrued(Currency.wrap(address(doll))) - accruedBefore;
        assertGt(protocolFee, 0, "the v4 protocol fee really was charged");

        // the score is what STAYED in the pool: the trader's parent, minus this version's own fee
        // claim, minus what Uniswap kept
        int256 expected = -traderDollDelta - int256(fee) - int256(protocolFee);
        assertEq(int256(rAfter) - int256(rBefore), expected, "the v4 protocol fee is not scored");
    }

    function _assertScoreIsPoolDelta(bool zeroForOne, int256 amountSpecified, string memory what) internal {
        (int256 traderDollDelta, uint256 fee, int128 rBefore, int128 rAfter) =
            _swapAndMeasure(zeroForOne, amountSpecified);
        int256 expected = -traderDollDelta - int256(fee);
        assertEq(int256(rAfter) - int256(rBefore), expected, what);
    }

    /// @notice exact-IN buy: the parent is the SPECIFIED currency and the fee is skimmed in
    /// `beforeSwap`. This is the case the old code double-counted.
    function test_scoreExactInParentSpecified() public {
        uint256 amountIn = 1 ether;
        uint256 fee = (amountIn * TOTAL_FEE_PPM) / PPM;
        int128 rBefore = hook.poolInfo(poolId).R;
        _swap(swapRouter, true, -int256(amountIn), "");
        int128 rAfter = hook.poolInfo(poolId).R;

        // the pool received exactly the input minus the fee, and that is the whole score move
        assertEq(int256(rAfter) - int256(rBefore), int256(amountIn - fee), "R = input net of the skimmed fee");
        assertEq(uint256(uint128(rAfter - rBefore)), amountIn - fee, "exact value, not an approximation");
    }

    /// @notice exact-OUT sell: the parent is the specified currency and the fee is added on top
    /// in `beforeSwap`; the pool pays out the gross, so the score falls by the gross.
    function test_scoreExactOutParentSpecified() public {
        _swap(swapRouter, true, -int256(2 ether), "");
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        _assertScoreIsPoolDelta(false, int256(0.5 ether), "exact-out, parent specified");
    }

    /// @notice exact-IN sell: the parent is the UNSPECIFIED currency, fee charged in `afterSwap`.
    function test_scoreExactInParentUnspecified() public {
        _swap(swapRouter, true, -int256(2 ether), "");
        uint256 tokens = token.balanceOf(address(this)) / 2;
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        _assertScoreIsPoolDelta(false, -int256(tokens), "exact-in, parent unspecified");
    }

    /// @notice exact-OUT buy: the parent is the unspecified (input) currency.
    function test_scoreExactOutParentUnspecified() public {
        _assertScoreIsPoolDelta(true, int256(1_000_000e18), "exact-out, parent unspecified");
    }

    /// @notice The four orientations agree with each other: a buy and the sell that exactly
    /// undoes it leave the score at the net of the two pool deltas, never at a fee-adjusted
    /// number that drifts with the number of swaps.
    function test_scoreIsAdditiveAcrossOrientations() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        int128 r1 = hook.poolInfo(poolId).R;
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);

        uint256 vaultBefore = _feeVaultEdge();
        uint256 dollBefore = doll.balanceOf(address(this));
        _swap(swapRouter, false, -int256(token.balanceOf(address(this))), "");
        int256 traderDelta = int256(doll.balanceOf(address(this))) - int256(dollBefore);
        uint256 fee = _feeVaultEdge() - vaultBefore;

        assertEq(int256(hook.poolInfo(poolId).R), int256(r1) - traderDelta - int256(fee), "additive across swaps");
        assertLt(hook.poolInfo(poolId).R, r1, "selling gives the parent back");
        _assertNoEth();
    }

    /// @notice A buy inside the snipe window scores what the POOL absorbed - a small
    /// positive number - and never a negative one. With a 99% snipe tax and a 10 bps hop fee,
    /// 1e18 of parent leaves 0.9% = 0.009e18 in the pool.
    function test_snipeWindowBuyScoresPoolDeltaAndNeverGoesNegative() public {
        _buyLink(1, 5 ether);
        Cand memory c = _registerCandidate(address(0xA11CE), "SNIPE");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        uint64 tradingStart = _poolStart(c); // the pool's OWN start

        // exactly at the pool's own start the tax is SNIPE_START_PPM = 99%
        vm.warp(tradingStart);
        uint256 amountIn = 1 ether; // 1e18 units of the PARENT token
        uint256 feePpm = hook.SNIPE_START_PPM() + hook.hopFeePpm();
        assertEq(feePpm, 991_000, "99% snipe + 10 bps hop");

        int128 rBefore = hook.poolInfo(c.poolId).R;
        assertEq(rBefore, 0, "a fresh candidate pool starts at zero");
        _tradeCandidate(c, true, amountIn);
        int128 rAfter = hook.poolInfo(c.poolId).R;

        assertEq(uint256(uint128(rAfter)), amountIn - (amountIn * feePpm) / PPM, "R = the pool's own delta");
        assertEq(uint256(uint128(rAfter)), 0.009 ether, "0.9% of the 1e18 buy reached the pool");
        assertGt(rAfter, 0, "a sniped buy can never score negative");
    }

    /// @notice The same buy one second later is taxed less, so it scores more - the score
    /// tracks the pool, not the trader's gross.
    function test_snipeDecayMovesTheScoreNotTheSign() public {
        _buyLink(1, 5 ether);
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        uint64 tradingStart = _poolStart(a); // a and b opened in one block

        vm.warp(tradingStart);
        _tradeCandidate(a, true, 1 ether);
        vm.warp(tradingStart + 2);
        _tradeCandidate(b, true, 1 ether);

        int128 rEarly = hook.poolInfo(a.poolId).R;
        int128 rLate = hook.poolInfo(b.poolId).R;
        assertGt(rLate, rEarly, "less tax later means more parent stays in the pool");
        assertGt(rEarly, 0);
    }

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    // ---------------------------------------------------------------------------------
    // Every registered pool has a published end, and an EDGE pool keeps its snipe window
    // ---------------------------------------------------------------------------------

    /// @notice There is no genesis pool: an EDGE pool is an ordinary
    /// candidate pool with a snipe window, and the protocol fee and the opening snipe tax are
    /// mutually exclusive IN TIME (the edge fee is suppressed while the snipe tax runs), not by
    /// pool class. What the hook guarantees at registration is that EVERY pool has a published
    /// end strictly after its start, so the ring freeze is universal and no pool is frozen before
    /// it opens.
    function test_everyPoolNeedsAPublishedEndAfterItsStart() public {
        PoolKey memory k = _spareKey(address(0xDEADBEEF));
        uint64 start = uint64(block.timestamp) + 60;

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, true, initSqrtPriceX96, start, 0, 0, false);

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, true, initSqrtPriceX96, start, start, 0, false);

        // an EDGE pool with a real schedule registers, snipe window and all
        vm.prank(address(factory));
        hook.registerPool(k, true, initSqrtPriceX96, start, start + 900, 0, false);
        assertTrue(hook.poolInfo(k.toId()).registered, "an edge pool with a published end registers");
        assertTrue(hook.poolInfo(k.toId()).isEdge, "and it is marked as the edge");
        assertEq(hook.poolInfo(k.toId()).tradingStart, start, "it keeps its snipe window");

        // and so does a non-edge candidate pool
        PoolKey memory c = _spareKey(address(0xC0FFEE));
        vm.prank(address(factory));
        hook.registerPool(c, false, initSqrtPriceX96, start, start + 900, 0, false);
        assertEq(hook.poolInfo(c.toId()).tradingStart, start, "a candidate still gets one");
        assertFalse(hook.poolInfo(c.toId()).isEdge, "but no protocol fee");
    }

    // ---------------------------------------------------------------------------------
    // Ring writes freeze at the published end
    // ---------------------------------------------------------------------------------

    /// @dev The leader of a fresh round, with its support built early and topped up inside the
    /// closing window, warped to the nominal end `T`. Returns the candidate and the average its
    /// closing window is worth as of `T`, read BEFORE anything can have overwritten the ring.
    function _leaderAtNominalEnd() internal returns (Cand memory lead, int256 expected) {
        uint256 roundId = roundManager.roundCount() + 1;
        lead = _registerCandidate(address(0x1EADE4), "LEAD");
        assertEq(roundManager.roundCount(), roundId, "the registration opened the round");
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundId);
        uint64 w = roundManager.closingWindowFor(roundId);

        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(lead, true, WINNING_BUY);
        // one more buy INSIDE the closing window, so the far edge of the window is resolved by a
        // coarse checkpoint rather than by the pool's live state
        uint64 from = _scoredFrom(nominalEnd, w, tradingStart);
        vm.warp(from + (nominalEnd - from) / 2);
        _tradeCandidate(lead, true, WINNING_BUY / 50);

        vm.warp(nominalEnd);
        (expected,,,) = hook.averageOver(lead.poolId, from, nominalEnd);
        assertGt(expected, 0, "the leader has a real closing-window average");
    }

    /// @dev Swap the leader's pool once per coarse slot across `(from, to]`, which is the fastest
    /// anyone can turn the ring over: a second swap inside the same slot writes nothing.
    function _swapEverySlot(Cand memory lead, uint64 from, uint64 to) internal {
        uint64 slot = uint64(roundManager.scoreSlotFor(roundManager.roundCount()));
        for (uint64 t = from + slot; t <= to; t += slot) {
            vm.warp(t);
            _tradeCandidate(lead, true, 1e18);
        }
    }

    /// @notice The ring is not merely large enough to
    /// survive the whole beacon-timeout gap - it is UNTOUCHED by it. Nobody relays a beacon, the
    /// leader's pool is swapped once per coarse slot for the entire `[T, T + END_TIMEOUT]`
    /// window, and the round is then settled deterministically and scored at the last moment of
    /// its submission window. Every one of those swaps is past the pool's published end, so none
    /// of them writes a ring entry: the whole ring is byte-identical afterwards, and the score is
    /// the one measured at `T`.
    function test_theRingIsUnchangedByAFullBeaconTimeoutOfPostBellDust() public {
        (Cand memory lead, int256 expected) = _leaderAtNominalEnd();
        uint256 roundId = roundManager.roundCount();
        (, uint64 nominalEnd,) = _roundTimes(roundId);
        uint64 timeout = roundManager.END_TIMEOUT();

        IFamilyHook.ScoreCheckpoint[] memory before = _ringSnapshot(lead.poolId);
        _swapEverySlot(lead, nominalEnd, nominalEnd + timeout);
        _assertRingsUnchangedUpTo(lead.poolId, before, nominalEnd);

        vm.warp(nominalEnd + timeout);
        roundManager.finalizeDeterministic();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertEq(r.tradingEnd, nominalEnd, "the deterministic end is T exactly");
        assertEq(r.submitEnd, uint64(block.timestamp) + roundManager.SUBMIT_S(), "the window opens now");

        vm.warp(r.submitEnd - 1);
        int256 avg = roundManager.submitScore(lead.id);
        assertEq(avg, expected, "the closing-window average is the one measured at T");
        assertEq(roundManager.candidateInfo(lead.id).avg, avg, "and it is what the round recorded");
    }

    /// @notice The same round with a PROMPT beacon: a submission window's worth of dust likewise
    /// writes nothing, and the far edge still resolves.
    function test_theRingIsUnchangedByASubmissionWindowOfDustAfterAPromptFulfil() public {
        (Cand memory lead, int256 expected) = _leaderAtNominalEnd();
        (, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        (uint64 tradingEnd, uint64 submitEnd) = _settleEnd();
        assertEq(tradingEnd, nominalEnd, "a word of zero ends the round at T");

        IFamilyHook.ScoreCheckpoint[] memory before = _ringSnapshot(lead.poolId);
        _swapEverySlot(lead, tradingEnd, submitEnd - 1);
        _assertRingsUnchangedUpTo(lead.poolId, before, nominalEnd);

        vm.warp(submitEnd - 1);
        assertEq(roundManager.submitScore(lead.id), expected, "the same average, read after the dust");
    }

    /// @dev Both rings of a pool, in one array: the fast ring first, then the coarse one.
    function _ringSnapshot(PoolId id) internal view returns (IFamilyHook.ScoreCheckpoint[] memory ring) {
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

    /// @dev Every entry stamped at or before the published end `T` is still there,
    /// unchanged, and no entry stamped AFTER `T` has appeared.
    function _assertRingsUnchangedUpTo(PoolId id, IFamilyHook.ScoreCheckpoint[] memory before, uint64 publishedEnd)
        internal
        view
    {
        IFamilyHook.ScoreCheckpoint[] memory now_ = _ringSnapshot(id);
        uint256 kept;
        for (uint256 i = 0; i < before.length; i++) {
            assertLe(now_[i].tSwap, publishedEnd, "no ring entry is ever stamped after the bell");
            assertEq(now_[i].tSwap, before[i].tSwap, "tSwap unchanged");
            assertEq(now_[i].tState, before[i].tState, "tState unchanged");
            assertEq(now_[i].R, before[i].R, "R unchanged");
            assertEq(now_[i].acc, before[i].acc, "acc unchanged");
            if (before[i].tSwap != 0) kept++;
        }
        assertGt(kept, 0, "the pool really did have a ring to preserve");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev A well-formed key that no pool has been registered under, so `registerPool`'s own
    /// guards are what the test is measuring.
    function _spareKey(address other) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(other),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}

/// @notice Score availability and the ring freeze. A slot holds the state before its FIRST swap, so
/// without an exact-sample fallback a second swap in the bell's own slot left no checkpoint
/// bracketing `T_end`. The fallback alone would open a SELECTION: after the reveal, anyone could
/// bury the fast ring in dust and push the `T_end` edge onto whichever sample the rings had left.
/// The rings therefore FREEZE: past the pool's published end `T`, swaps still move the live
/// accumulator and write no ring entries at all, so the whole of `[T_end - W, T_end]` is beyond
/// the reach of post-bell flow by construction.
contract HookScoreRingFreezeTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        // the cases below are stated in whole {FamilyHook.SCORE_SLOT_S} slots, so the schedule is
        // aligned to one before any round opens
        vm.warp(block.timestamp + (5 - (block.timestamp % 5)) % 5);
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // score availability: the ring must always answer for `T_end`
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
        (int256 expected,,,) = hook.averageOver(a.poolId, _scoredFrom(nominalEnd, w, tradingStart), nominalEnd);

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
        (int256 expected,,,) = hook.averageOver(a.poolId, _scoredFrom(tradingEnd, w, tradingStart), tradingEnd);

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
        // round 3 is the first whose trading duration (16 min) EXCEEDS the flat 15-minute closing
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

    /// @notice A pool at the instant it opens - its own registration, before the round clock -
    /// has no history at all. The question is answerable without underflow, and the answer is
    /// "nothing covered".
    function test_trailingAverageAtTheOpenDoesNotRevert() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        assertEq(_poolStart(a), block.timestamp, "the pool opens at its registration");
        assertLt(block.timestamp, tradingStart, "before the round clock starts");

        (int256 avg, uint32 covered) = hook.trailingAverage(a.poolId, 1800);
        assertEq(avg, 0, "no average at the open");
        assertEq(covered, 0, "and no coverage claimed");
    }

    // ---------------------------------------------------------------------------------
    // the ring freezes at the published end
    // ---------------------------------------------------------------------------------

    /// @notice THE SCENARIO. The round's last swap is in the bell's own fast slot, so
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

        (int256 expected,,, uint64 tEndUsed) =
            hook.averageOver(a.poolId, _scoredFrom(nominalEnd, w, tradingStart), nominalEnd);
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

        (int256 got,,, uint64 tEndAfter) =
            hook.averageOver(a.poolId, _scoredFrom(nominalEnd, w, tradingStart), nominalEnd);
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
    // the far edge drifts by at most one coarse slot
    // ---------------------------------------------------------------------------------

    /// @notice Post-bell flow cannot change the sampled instant or the
    /// value at all; what an adversary CAN still do is dust the far edge of the window
    /// BEFORE the bell, so that `T_end - W` has no bracketing checkpoint and resolves to the
    /// nearest earlier sample. That drift is bounded by ONE COARSE SLOT - 18 s on the mainnet
    /// schedule against a 900-second window - and the instant is never later than the edge.
    function test_farEdgeDriftIsAtMostOneCoarseSlot() public {
        // round 3 is the first whose duration (16 min) exceeds the flat 15-minute window, so the
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
    // the v4 protocol-fee snapshot is per leg, not per transaction
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

/// @notice Registration guards of the hook: a candidate pool must have a published end after its
/// start.
contract HookPoolRegistrationTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    /// @notice The published end `T` is what freezes the score rings and what every scored window
    /// is measured back from. A candidate registered with `nominalEnd == 0` is therefore frozen
    /// before it opens: it accumulates nothing, writes no ring entry, and can never be scored,
    /// while still charging the hop fee on every swap. The factory always passes a real end; the
    /// hook guarantees it too, so no other caller can register a pool that is dead on arrival.
    function test_aCandidatePoolCannotBeRegisteredWithoutAnEndAfterItsStart() public {
        PoolKey memory k = _candidateKey(address(0xC0FFEE));
        uint64 start = uint64(block.timestamp) + 60;

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, false, initSqrtPriceX96, start, 0, 0, false);

        // an end AT the start measures nothing either
        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, false, initSqrtPriceX96, start, start, 0, false);

        // and a real one registers
        vm.prank(address(factory));
        hook.registerPool(k, false, initSqrtPriceX96, start, start + 900, 0, false);
        assertEq(hook.poolInfo(k.toId()).nominalEnd, start + 900, "the candidate carries its end");

        // The freeze is UNIVERSAL. There is no genesis exemption - every pool
        // this protocol owns is launched by a round - so an EDGE pool is held to exactly the same
        // rule as any other candidate.
        PoolKey memory g = _candidateKey(address(0xDEADBEEF));
        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(g, true, initSqrtPriceX96, start, 0, 0, false);

        vm.prank(address(factory));
        hook.registerPool(g, true, initSqrtPriceX96, start, start + 900, 0, false);
        assertTrue(hook.poolInfo(g.toId()).isEdge, "an edge pool...");
        assertEq(hook.poolInfo(g.toId()).nominalEnd, start + 900, "...with an end like every other");
    }

    function _candidateKey(address other) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(DOLL_ADDRESS),
            currency1: Currency.wrap(other),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
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
