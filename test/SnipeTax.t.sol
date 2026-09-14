// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";

/// @notice The snipe tax (and the hop fee beside it) is a fraction of the trader's TOTAL
/// parent-side payment in BOTH swap modes. Exact-input skims the rate off what the trader pays;
/// exact-output grosses the pool's cost up by `1 / (1 - rate)` and charges the difference, so a
/// sniper cannot halve a 99% tax to 49.7% just by asking for an exact number of tokens out.
contract SnipeTaxTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    /// @dev Exact-OUTPUT buy of a candidate: the trader asks for `tokensOut` and pays parent
    /// (the unspecified currency), so the whole fee is charged in `afterSwap`.
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

    /// @dev Two fresh twin candidate pools of the same round, with the parent approved. The two
    /// must share an ORIENTATION to be comparable to a fraction of a percent: a mirrored curve
    /// (child token sorting below its parent) snaps its ticks the other way, which moves the
    /// fill by a few tenths of a percent for the same nominal curve. Which side a clone sorts on
    /// is decided by its address, so register until two of them agree.
    function _twins() internal returns (Cand memory a, Cand memory b, uint64 tradingStart) {
        _buyGenesis(5 ether);
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

    /// @dev (parent the trader paid, parent the pool kept) for one buy, measured from balances
    /// and the pool's own score delta.
    function _paidAndPooled(Cand memory c, uint256 poolBefore) internal view returns (uint256, uint256) {
        return (
            poolBefore - IERC20(roundManager.head()).balanceOf(address(this)),
            uint256(uint128(hook.poolInfo(c.poolId).R))
        );
    }

    /// @notice Inside the snipe window an exact-output buy and an exact-input buy that leave the
    /// SAME amount in the pool cost the trader the same total, and both are taxed at ~99%.
    function test_snipeTaxIdenticalForExactInAndExactOut() public {
        (Cand memory a, Cand memory b, uint64 tradingStart) = _twins();
        // the finest instant the EVM can express inside the window: dt = 0, the 99% start rate
        vm.warp(tradingStart);
        assertEq(hook.SNIPE_START_PPM(), 990_000, "the window opens at 99%");

        IERC20 parent = IERC20(roundManager.head());
        uint256 before1 = parent.balanceOf(address(this));
        uint256 tokensOut = _tradeCandidate(a, true, 1 ether);
        (uint256 paidIn, uint256 pooledIn) = _paidAndPooled(a, before1);

        uint256 before2 = parent.balanceOf(address(this));
        _buyCandidateExactOut(b, tokensOut);
        (uint256 paidOut, uint256 pooledOut) = _paidAndPooled(b, before2);

        assertApproxEqRel(pooledOut, pooledIn, 1e13, "twin pools absorbed the same parent");
        assertApproxEqRel(paidOut, paidIn, 1e13, "the same fill costs the same in both modes");

        uint256 taxPpmIn = ((paidIn - pooledIn) * PPM) / paidIn;
        uint256 taxPpmOut = ((paidOut - pooledOut) * PPM) / paidOut;
        assertGe(taxPpmIn, 960_000, "exact-in: >=96% of what the trader paid is taxed away");
        assertGe(taxPpmOut, 960_000, "exact-out: >=96% of what the trader paid is taxed away");
        assertApproxEqAbs(taxPpmOut, taxPpmIn, 2, "identical effective rate in both modes");
    }

    /// @notice After the 3-second window both modes pay the hop fee and nothing else.
    function test_afterWindowBothModesPayOnlyTheHopFee() public {
        (Cand memory a, Cand memory b, uint64 tradingStart) = _twins();
        vm.warp(tradingStart + hook.SNIPE_S());

        IERC20 parent = IERC20(roundManager.head());
        uint256 before1 = parent.balanceOf(address(this));
        uint256 tokensOut = _tradeCandidate(a, true, 1 ether);
        (uint256 paidIn, uint256 pooledIn) = _paidAndPooled(a, before1);

        uint256 before2 = parent.balanceOf(address(this));
        _buyCandidateExactOut(b, tokensOut);
        (uint256 paidOut, uint256 pooledOut) = _paidAndPooled(b, before2);

        assertApproxEqRel(paidOut, paidIn, 1e13, "the same fill costs the same in both modes");
        assertApproxEqAbs(((paidIn - pooledIn) * PPM) / paidIn, HOP_FEE_PPM, 1, "exact-in: hop fee only");
        assertApproxEqAbs(((paidOut - pooledOut) * PPM) / paidOut, HOP_FEE_PPM, 1, "exact-out: hop fee only");
    }
}

/// @notice At the {FamilyHook.MAX_HOP_FEE_PPM} ceiling the parent-side rates sum to exactly 100%
/// at `tradingStart`, where the exact-output gross-up has no finite answer. The swap is refused
/// outright rather than silently charging half the intended tax.
contract SnipeTaxCeilingTest is RoundTestBase {
    function _hopFeePpm() internal pure override returns (uint256) {
        return 10_000; // 100 bps: 99% snipe + 1% hop = 100%
    }

    function setUp() public {
        _setUpFamily();
    }

    function test_exactOutRevertsWhenRatesReachOneHundredPercent() public {
        _buyGenesis(5 ether);
        Cand memory c = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart);

        bool zeroForOne = !c.tokenIsCurrency0;
        _expectHookRevert(address(hook), IHooks.afterSwap.selector, FamilyHook.SnipeExactOutputTooLarge.selector);
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(1e18),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
