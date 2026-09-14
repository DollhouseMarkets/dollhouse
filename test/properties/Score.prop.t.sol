// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../../contracts/interfaces/IFamilyHook.sol";

/// @notice Property tests for the score accumulator and the closing window
/// (docs/spec/PROPERTIES.md sec.3.4), tier F.
contract ScorePropTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
    }

    /// @notice SCR-01: the accumulator update is exactly `acc += R*(now - tLast); tLast = now;
    /// R += (-parentDelta_pool)`, where `parentDelta_pool` excludes every hook-charged fee.
    function testFuzz_SCR01_theAccumulatorIntegratesTheNetParentLevel(uint256 ethIn, uint256 gap) public {
        ethIn = bound(ethIn, 0.001 ether, 20 ether);
        uint256 dt = bound(gap, 1, 3600);

        (int256 accBefore, int128 rBefore, uint64 tLastBefore) = hook.scoreState(poolId);
        vm.warp(vm.getBlockTimestamp() + dt);
        uint64 tNow = uint64(vm.getBlockTimestamp());

        familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);

        (int256 accAfter, int128 rAfter, uint64 tLastAfter) = hook.scoreState(poolId);
        assertEq(tLastAfter, tNow, "tLast moves to now");
        assertEq(
            accAfter,
            accBefore + int256(rBefore) * int256(uint256(tNow - tLastBefore)),
            "acc integrates the PREVIOUS level over the gap"
        );

        // each rate is floored independently, exactly as the hook charges them
        uint256 fees = (ethIn * _hopFeePpm()) / PPM + (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM;
        assertEq(int256(rAfter - rBefore), int256(ethIn - fees), "R moves by the parent the POOL kept");
    }

    /// @notice SCR-02 (stateless half): `R` increases on a net buy and strictly decreases on a
    /// net sell, and a plain transfer changes neither `acc` nor `R`.
    function testFuzz_SCR02_buysRaiseAndSellsLowerTheLevel(uint256 ethIn, uint256 sellShare) public {
        ethIn = bound(ethIn, 0.01 ether, 10 ether);

        (, int128 r0,) = hook.scoreState(poolId);
        uint256 bought = familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
        (, int128 r1,) = hook.scoreState(poolId);
        assertGt(r1, r0, "a net buy raises the level");

        IERC20(address(token)).approve(address(familyRouter), type(uint256).max);
        uint256 amount = bound(sellShare, 1e18, bought);
        familyRouter.sellExactIn(0, amount, 0, address(this), 1);
        (int256 acc2, int128 r2,) = hook.scoreState(poolId);
        assertLt(r2, r1, "a net sell lowers it");

        // a transfer between holders moves no pool parent at all
        IERC20(address(token)).transfer(address(0xF00D), IERC20(address(token)).balanceOf(address(this)) / 2);
        (int256 acc3, int128 r3,) = hook.scoreState(poolId);
        assertEq(r3, r2, "a transfer does not move R");
        assertEq(acc3, acc2, "nor the accumulator");
    }

    /// @notice SCR-03: a buy inside the snipe window increases the score by the POST-FEE pool
    /// delta and never makes the score negative.
    function testFuzz_SCR03_aSnipedBuyStillScoresItsPostFeeDelta(uint256 dtSeed, uint256 amountSeed) public {
        uint256 dt = bound(dtSeed, 0, 2);
        uint256 amount = bound(amountSeed, 1e18, 200_000e18);

        Cand memory c = _registerCandidate(address(0xA11CE), "S");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + dt);

        uint256 snipePpm = _snipePpmSpec(dt);
        (, int128 rBefore,) = hook.scoreState(c.poolId);
        _tradeCandidate(c, true, amount);
        (, int128 rAfter,) = hook.scoreState(c.poolId);

        uint256 fees = (amount * _hopFeePpm()) / PPM + (amount * snipePpm) / PPM;
        assertEq(int256(rAfter - rBefore), int256(amount - fees), "the post-fee pool delta is what scores");
        assertGe(rAfter, 0, "a 99% tax never makes the score negative");
        assertGt(rAfter, rBefore, "and it is still an increase");
    }

    /// @notice SCR-04: for every `t0 < t1`, `averageOver(id, t0, t1)` equals
    /// `(acc(t1) - acc(t0))/(t1 - t0)` computed from the exact swap history.
    function testFuzz_SCR04_averageOverIsExact(uint256[4] memory amounts, uint256[4] memory gaps, uint256 windowSeed)
        public
    {
        uint64[5] memory times;
        int128[5] memory levels;
        IERC20(address(token)).approve(address(familyRouter), type(uint256).max);

        // a history of spaced swaps, each in its own coarse slot, recorded as it is made
        (, int128 r,) = hook.scoreState(poolId);
        times[0] = uint64(vm.getBlockTimestamp());
        levels[0] = r;
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 200, 900));
            uint256 ethIn = bound(amounts[i], 0.001 ether, 5 ether);
            if (i % 2 == 1) {
                uint256 held = IERC20(address(token)).balanceOf(address(this));
                familyRouter.sellExactIn(0, held / 4, 0, address(this), 1);
            } else {
                familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
            }
            (, r,) = hook.scoreState(poolId);
            times[i + 1] = uint64(vm.getBlockTimestamp());
            levels[i + 1] = r;
        }
        vm.warp(vm.getBlockTimestamp() + 100);

        uint64 first = times[1];
        uint64 last = uint64(vm.getBlockTimestamp());
        uint64 t0 = uint64(bound(windowSeed, first, last - 2));
        uint64 t1 = uint64(bound(uint256(keccak256(abi.encode(windowSeed))), uint256(t0) + 1, last));

        (int256 avg,) = hook.averageOver(poolId, t0, t1);
        int256 expected = (_accAt(times, levels, t1) - _accAt(times, levels, t0)) / int256(uint256(t1 - t0));
        assertEq(avg, expected, "the window average is the exact integral of the recorded history");
    }

    /// @notice SCR-05: a checkpoint slot is written at most once, by the first swap in that
    /// slot, and it holds the state as it stood BEFORE that swap.
    function testFuzz_SCR05_aSlotIsWrittenOnceByItsFirstSwap(uint256 ethA, uint256 ethB, uint256 gap) public {
        uint64 slotS = hook.SCORE_SLOT_S();
        // land at the start of a fresh slot so both swaps share it
        vm.warp((vm.getBlockTimestamp() / slotS) * slotS + slotS);
        uint256 within = bound(gap, 0, slotS - 1);

        (int256 accBefore, int128 rBefore, uint64 tLastBefore) = hook.scoreState(poolId);
        uint64 slot = uint64(vm.getBlockTimestamp()) / slotS;

        familyRouter.buyExactIn{value: bound(ethA, 0.001 ether, 5 ether)}(0, 0, address(this), 1);
        IFamilyHook.ScoreCheckpoint memory cp = hook.scoreCheckpoint(poolId, slot % hook.SCORE_SLOTS());
        assertEq(cp.tSwap, vm.getBlockTimestamp(), "the first swap of the slot wrote it");
        assertEq(cp.acc, accBefore, "with the PRE-swap accumulator");
        assertEq(cp.R, rBefore, "and the pre-swap level");
        assertEq(cp.tState, tLastBefore, "tagged with the state it was valid from");

        vm.warp(vm.getBlockTimestamp() + within);
        familyRouter.buyExactIn{value: bound(ethB, 0.001 ether, 5 ether)}(0, 0, address(this), 1);
        IFamilyHook.ScoreCheckpoint memory after_ = hook.scoreCheckpoint(poolId, slot % hook.SCORE_SLOTS());
        assertEq(after_.tSwap, cp.tSwap, "a second swap in the same slot does not rewrite it");
        assertEq(after_.acc, cp.acc, "nor its accumulator");
        assertEq(after_.R, cp.R, "nor its level");
    }

    /// @notice SCR-09: parent absorbed and then sold back before the closing window contributes
    /// nothing: the window measures a level, not a total.
    function testFuzz_SCR09_supportSoldBeforeTheWindowDoesNotCount(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 100_000e18, 4_000_000e18);

        // a round long enough to HAVE a before-the-window: the closing window is 15 minutes and
        // rounds 1 and 2 are 15 minutes long, so the window would cover the whole round
        _runWinningRound(1, WINNING_BUY);
        _runWinningRound(1, WINNING_BUY);
        assertGt(roundManager.durationFor(3), roundManager.closingWindowFor(3), "round 3 is longer than its window");

        Cand memory c = _registerCandidate(address(0xA11CE), "S");
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);
        IERC20(c.token).approve(address(swapRouter), type(uint256).max);

        vm.warp(tradingStart + 5);
        uint256 got = _tradeCandidate(c, true, amount);
        vm.warp(vm.getBlockTimestamp() + 60);
        _tradeCandidate(c, false, got); // sold straight back out

        uint64 window = roundManager.closingWindowFor(roundManager.roundCount());
        assertLt(tradingStart + 65, nominalEnd - window, "the whole trade happened before the window opens");
        vm.warp(nominalEnd);
        (int256 avg,) = hook.averageOver(c.poolId, nominalEnd - window, nominalEnd);

        assertLt(avg * 100, int256(amount), "support that left before the bell is not a level");
        assertLt(avg, int256(roundManager.threshold()), "and cannot win the round on its own");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev The accumulator at `t`, integrated from the recorded piecewise-constant levels.
    function _accAt(uint64[5] memory times, int128[5] memory levels, uint64 t) internal pure returns (int256 acc) {
        for (uint256 i = 0; i < 4; i++) {
            if (t <= times[i]) break;
            uint64 upper = t < times[i + 1] ? t : times[i + 1];
            acc += int256(levels[i]) * int256(uint256(upper - times[i]));
        }
        if (t > times[4]) acc += int256(levels[4]) * int256(uint256(t - times[4]));
    }

    /// @dev The published snipe schedule, with the negative term taken at true floor division.
    function _snipePpmSpec(uint256 dt) internal view returns (uint256) {
        uint256 s = hook.SNIPE_S();
        if (dt >= s) return 0;
        uint256 start = hook.SNIPE_START_PPM();
        uint256 drop = start - hook.SNIPE_END_PPM();
        uint256 fall = (drop * dt) / s;
        if ((drop * dt) % s != 0) fall += 1;
        return start - fall;
    }
}
