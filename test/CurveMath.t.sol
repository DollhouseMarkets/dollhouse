// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";

/// @notice The economic contract of the standard curve: a range holding share `s` of supply
/// between valuations Fa and Fb costs exactly `s * sqrt(Fa * Fb)` of the parent currency to
/// buy out. Verified by executing the buy through a real pool.
contract CurveMathTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpEdge();
        // the round that crowned link one walked its price out of the first range; put the pool
        // back at the top of its own curve so the closed form can be checked range by range
        _rewindEdgePool();
        vm.warp(block.timestamp + 10); // past the snipe window
    }

    function test_fdvRoundTrip() public pure {
        uint160 sqrtP = CurveMath.sqrtPriceAtFdv(7 ether, SUPPLY);
        assertApproxEqRel(CurveMath.fdvAtSqrtPrice(sqrtP, SUPPLY), 7 ether, 1e12, "fdv round trip");
    }

    function test_higherFdvIsLowerTick() public pure {
        uint160 a = CurveMath.sqrtPriceAtFdv(1 ether, SUPPLY);
        uint160 b = CurveMath.sqrtPriceAtFdv(100 ether, SUPPLY);
        assertGt(a, b, "a higher valuation means fewer tokens per parent unit");
    }

    function test_rangeHoldsItsShare() public view {
        // the liquidity placed for each range corresponds to its share of supply
        for (uint256 i = 0; i < ranges.length; i++) {
            uint256 amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(ranges[i].tickLower),
                TickMath.getSqrtPriceAtTick(ranges[i].tickUpper),
                ranges[i].liquidity,
                false
            );
            uint256 share = _standardCurveSpec()[i].shareWad;
            // every family token sells its whole supply: 100% of it is locked liquidity
            assertApproxEqRel(
                amount1, (SUPPLY * share) / 1e18, 1e12, "range holds its share of the supply"
            );
        }
    }

    /// @notice Buy the whole top range with an exact-output swap and compare the parent the pool
    /// took (net of hook fees) with the closed form `s * sqrt(Fa * Fb)`.
    /// @dev Fa/Fb are the valuations at the range's actual, tick-spacing-snapped bounds; the
    /// snapping is part of the curve, so the closed form is evaluated at the snapped bounds.
    function test_buyingOutARangeCostsSqrtFaFb() public {
        CurveRange memory r = ranges[0];
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(r.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(r.tickUpper);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, r.liquidity, false);

        uint256 fdvLower = CurveMath.fdvAtSqrtPrice(sqrtUpper, SUPPLY); // Fa: top price == low FDV
        uint256 fdvUpper = CurveMath.fdvAtSqrtPrice(sqrtLower, SUPPLY); // Fb
        uint256 expected = Math.mulDiv(amount1, Math.sqrt(fdvLower * fdvUpper), SUPPLY);

        uint256 vaultBefore = _feeVaultEdge();
        uint256 parentBefore = doll.balanceOf(address(this));
        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(swapRouter, true, int256(amount1), "");
        uint256 parentSpent = parentBefore - doll.balanceOf(address(this));
        uint256 fee = _feeVaultEdge() - vaultBefore;
        uint256 gross = parentSpent - fee;

        assertEq(token.balanceOf(address(this)) - tokensBefore, amount1, "bought the whole range");
        _assertNoEth();
        assertApproxEqRel(gross, expected, 5e14, "cost within 0.05% of s*sqrt(Fa*Fb)");

        // and the price now sits at the bottom of the range, i.e. the next range is on offer
        (uint160 sqrtAfter,,,) = im.getSlot0(poolId);
        assertApproxEqRel(uint256(sqrtAfter), uint256(sqrtLower), 1e12, "price walked to the range bottom");
    }
}
