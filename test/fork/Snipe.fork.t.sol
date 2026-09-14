// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork scenario 3 of docs/spec/PROPERTIES.md sec.4: identical buys into fresh candidate
/// pools on the real `PoolManager` at three offsets from `tradingStart`, in both exact-in and
/// exact-out mode. Covers FEE-04, FEE-05, SCR-03.
contract SnipeForkTest is ForkBase {
    function setUp() public {
        if (!_setUpForkFamily()) return;
        _buyGenesis(5 ether);
    }

    /// @dev Exact-OUTPUT buy of a candidate: the trader asks for `tokensOut` and pays parent (the
    /// unspecified currency), so the whole fee is charged in `afterSwap`.
    function _buyCandidateExactOut(Cand memory c, uint256 tokensOut) internal {
        bool zeroForOne = !c.tokenIsCurrency0;
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(tokensOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Two fresh candidate pools of the same round that share an ORIENTATION. Which side a
    /// clone sorts on is decided by its address, so register until two of them agree; a mirrored
    /// curve snaps its ticks the other way and the two fills stop being comparable.
    function _twins() internal returns (Cand memory a, Cand memory b, uint64 tradingStart) {
        string[6] memory names = ["A", "B", "C", "D", "E", "F"];
        a = _registerCandidate(address(0xA11CE), names[0]);
        bool matched;
        for (uint256 i = 1; i < names.length && !matched; i++) {
            Cand memory c = _registerCandidate(address(0xB0B), names[i]);
            if (c.tokenIsCurrency0 == a.tokenIsCurrency0) {
                b = c;
                matched = true;
            }
        }
        assertTrue(matched, "no twin pool with the same curve orientation");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (tradingStart,,) = _roundTimes(roundManager.roundCount());
    }

    /// @notice FEE-04: the tax at `t` is `SNIPE_START_PPM + (SNIPE_END_PPM - SNIPE_START_PPM) *
    /// (t - tradingStart)/SNIPE_S` inside the three-second window and exactly 0 at `+4 s`, with
    /// the hop fee charged beside it in every case.
    function testFork_FEE04_snipeTaxFollowsTheLinearSchedule() public {
        _requireFork();
        Cand memory c1 = _registerCandidate(address(0xA11CE), "S1");
        Cand memory c2 = _registerCandidate(address(0xA11CE), "S2");
        Cand memory c3 = _registerCandidate(address(0xA11CE), "S3");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());

        assertEq(hook.SNIPE_START_PPM(), 990_000, "the window opens at 99%");
        assertEq(hook.SNIPE_END_PPM(), 10_000, "and lands at 1%");
        assertEq(hook.SNIPE_S(), 3, "over three seconds");

        uint256 amount = 100_000e18;
        uint256 taxAtOne = _feeOfBuyAt(c1, tradingStart + 1, amount);
        uint256 taxAtTwo = _feeOfBuyAt(c2, tradingStart + 2, amount);
        uint256 taxAtFour = _feeOfBuyAt(c3, tradingStart + 4, amount);

        uint256 hopOnly = (amount * _hopFeePpm()) / PPM;
        assertEq(taxAtOne, hopOnly + (amount * _snipePpmSpec(1)) / PPM, "the scheduled tax at +1 s");
        assertEq(taxAtTwo, hopOnly + (amount * _snipePpmSpec(2)) / PPM, "the scheduled tax at +2 s");
        assertEq(taxAtFour, hopOnly, "no tax at all at +4 s, only the hop fee");
        assertGt(taxAtOne, taxAtTwo, "the schedule falls");
        assertGt(taxAtTwo, taxAtFour, "and keeps falling");
    }

    /// @notice FEE-04: the genesis pool is never sniped, at any time.
    function testFork_FEE04_genesisIsNeverSniped() public {
        _requireFork();
        vm.warp(block.timestamp + 400 days);
        uint256 ethIn = 0.25 ether;
        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one leg");
        assertEq(splits[0].hopFee, (ethIn * _hopFeePpm()) / PPM, "the hop fee alone, never a snipe tax");
        assertEq(splits[0].protocolFee, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "and the 1% edge fee");
    }

    /// @notice FEE-05: inside the snipe window an exact-output buy and an exact-input buy that
    /// leave the SAME amount in the pool cost the trader the same total - the hook grosses the
    /// pool's cost up by `1/(1 - rate)` whenever it is handed the pool's side, so a sniper cannot
    /// halve a 99% tax by asking for an exact number of tokens out.
    function testFork_FEE05_parityBetweenExactInAndExactOut() public {
        _requireFork();
        (Cand memory a, Cand memory b, uint64 tradingStart) = _twins();
        vm.warp(tradingStart + 1);

        IERC20 parent = IERC20(roundManager.head());
        uint256 before1 = parent.balanceOf(address(this));
        uint256 tokensOut = _tradeCandidate(a, true, 1e18);
        uint256 paidIn = before1 - parent.balanceOf(address(this));
        uint256 pooledIn = uint256(uint128(hook.poolInfo(a.poolId).R));

        uint256 before2 = parent.balanceOf(address(this));
        _buyCandidateExactOut(b, tokensOut);
        uint256 paidOut = before2 - parent.balanceOf(address(this));
        uint256 pooledOut = uint256(uint128(hook.poolInfo(b.poolId).R));

        assertApproxEqRel(pooledOut, pooledIn, 1e13, "twin pools absorbed the same parent");
        assertApproxEqRel(paidOut, paidIn, 1e13, "the same fill costs the same in both modes");

        uint256 ratePpm = _hopFeePpm() + _snipePpmSpec(1);
        assertApproxEqRel((paidIn - pooledIn) * PPM / paidIn, ratePpm, 1e13, "exact-in: the rate of the gross");
        assertApproxEqRel((paidOut - pooledOut) * PPM / paidOut, ratePpm, 1e13, "exact-out: the rate of the gross");
    }

    /// @notice SCR-03: a buy inside the snipe window still increases the score by its post-fee
    /// pool delta and never makes the score negative; the same buy later in the window scores
    /// strictly more.
    function testFork_SCR03_snipedBuysStillScoreAndScoreMoreLater() public {
        _requireFork();
        (Cand memory a, Cand memory b, uint64 tradingStart) = _twins();
        uint256 amount = 50_000e18;

        vm.warp(tradingStart); // dt = 0: the 99% start rate
        _tradeCandidate(a, true, amount);
        int128 early = hook.poolInfo(a.poolId).R;

        vm.warp(tradingStart + 2); // dt = 2: the tax has fallen a long way
        _tradeCandidate(b, true, amount);
        int128 late = hook.poolInfo(b.poolId).R;

        assertGt(early, 0, "even a 99% taxed buy leaves a positive delta in the pool");
        assertGt(late, early, "the same buy later in the window scores strictly more");
        assertEq(
            uint256(uint128(early)), amount - (amount * (_hopFeePpm() + _snipePpmSpec(0))) / PPM, "the post-fee delta"
        );
    }

    /// @dev The total parent-side fee one exact-in buy of `amount` pays at absolute time `at`.
    function _feeOfBuyAt(Cand memory c, uint64 at, uint256 amount) internal returns (uint256) {
        vm.warp(at);
        vm.recordLogs();
        _tradeCandidate(c, true, amount);
        Split[] memory splits = _splits();
        assertEq(splits.length, 1, "one pool, one accrual");
        assertEq(splits[0].protocolFee, 0, "no protocol fee off the ETH edge");
        return splits[0].hopFee;
    }
}
