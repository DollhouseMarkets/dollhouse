// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurveRange} from "../types/CurveRange.sol";

/// @title CurveMath
/// @notice Pure conversion from the protocol's economic description of the standard launch
/// curve — "share `s` of supply offered between fully diluted valuations `fdvLower` and
/// `fdvUpper`, quoted in the parent currency" — into a v4 single-sided position.
///
/// @dev Frame of reference (this tranche): the family token is `currency1` and the parent
/// currency (native ETH for genesis) is `currency0`. That is guaranteed for the genesis pool
/// because native ETH is `address(0)` and therefore always sorts first. The pool price
/// `P = amount1 / amount0` is therefore "family tokens per parent unit", i.e.
/// `P = supply / fdv`: a HIGHER valuation is a LOWER tick. Unsold curve inventory is
/// token-only liquidity, which in v4 means ranges strictly BELOW the current tick, and buying
/// (parent in, token out) is `zeroForOne = true`, walking the price down through the ranges.
///
/// Candidate pools are quoted in the parent TOKEN, whose address may sort either side of the
/// child token, so every function takes a `tokenIsCurrency0` flag and the mirrored frame is
/// implemented alongside the genesis frame:
///
/// | orientation            | pool price P     | FDV vs tick | curve inventory | buying is |
/// |------------------------|------------------|-------------|-----------------|-----------|
/// | token = currency1 (ETH parent, always) | tokens/parent | higher FDV = lower tick | amount1, ticks BELOW spot | zeroForOne |
/// | token = currency0 (mirrored)           | parent/token  | higher FDV = higher tick | amount0, ticks ABOVE spot | oneForZero |
///
/// The two-argument overloads keep the genesis frame (`tokenIsCurrency0 == false`).
library CurveMath {
    error InvalidFdvRange();
    error InvalidShare();
    error EmptyRange();

    /// @notice sqrt price (Q64.96) at which the whole `supply` is valued at `fdv` parent units,
    /// in the genesis frame (the family token is `currency1`).
    function sqrtPriceAtFdv(uint256 fdv, uint256 supply) internal pure returns (uint160) {
        return sqrtPriceAtFdv(fdv, supply, false);
    }

    /// @notice sqrt price (Q64.96) at which the whole `supply` is valued at `fdv` parent units.
    /// @dev `sqrtP = sqrt(supply / fdv) * 2**96` when the token is `currency1`, and the
    /// reciprocal `sqrt(fdv / supply) * 2**96` when the token is `currency0`.
    function sqrtPriceAtFdv(uint256 fdv, uint256 supply, bool tokenIsCurrency0) internal pure returns (uint160) {
        if (fdv == 0 || supply == 0) revert InvalidFdvRange();
        uint256 ratioX192 = tokenIsCurrency0
            ? FullMath.mulDiv(fdv, FixedPoint96.Q96 * FixedPoint96.Q96, supply)
            : FullMath.mulDiv(supply, FixedPoint96.Q96 * FixedPoint96.Q96, fdv);
        uint256 sqrtPriceX96 = Math.sqrt(ratioX192);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert InvalidFdvRange();
        }
        return uint160(sqrtPriceX96);
    }

    /// @notice Inverse of {sqrtPriceAtFdv} in the genesis frame.
    function fdvAtSqrtPrice(uint160 sqrtPriceX96, uint256 supply) internal pure returns (uint256) {
        return fdvAtSqrtPrice(sqrtPriceX96, supply, false);
    }

    /// @notice Inverse of {sqrtPriceAtFdv}: the parent-denominated FDV implied by a sqrt price.
    function fdvAtSqrtPrice(uint160 sqrtPriceX96, uint256 supply, bool tokenIsCurrency0)
        internal
        pure
        returns (uint256)
    {
        if (tokenIsCurrency0) {
            uint256 halfUp = FullMath.mulDiv(supply, sqrtPriceX96, FixedPoint96.Q96);
            return FullMath.mulDiv(halfUp, sqrtPriceX96, FixedPoint96.Q96);
        }
        uint256 half = FullMath.mulDiv(supply, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(half, FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @notice Largest multiple of `tickSpacing` not greater than `tick` (floor, sign-correct).
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @notice Convert one curve segment into a v4 position.
    /// @param shareWad Share of `supply` sold in this segment, 1e18 = 100%.
    /// @param fdvLower Lower FDV bound of the segment, in parent units (wei for genesis).
    /// @param fdvUpper Upper FDV bound of the segment, in parent units.
    /// @param supply Total token supply (`FamilyToken.TOTAL_SUPPLY`).
    /// @param tickSpacing The pool's tick spacing; both bounds are floored to it, so that
    /// segments sharing an FDV boundary stay exactly contiguous.
    /// @return range Tick bounds and liquidity, token-only (currency1) liquidity.
    function rangeFromShare(uint256 shareWad, uint256 fdvLower, uint256 fdvUpper, uint256 supply, int24 tickSpacing)
        internal
        pure
        returns (CurveRange memory range)
    {
        return rangeFromShare(shareWad, fdvLower, fdvUpper, supply, tickSpacing, false);
    }

    /// @notice Convert one curve segment into a v4 position, in either orientation.
    /// @param tokenIsCurrency0 True when the family token sorts below its parent token.
    function rangeFromShare(
        uint256 shareWad,
        uint256 fdvLower,
        uint256 fdvUpper,
        uint256 supply,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) internal pure returns (CurveRange memory range) {
        return rangeFromShare(shareWad, fdvLower, fdvUpper, supply, supply, tickSpacing, tokenIsCurrency0);
    }

    /// @notice Convert one curve segment into a v4 position when only part of the supply is on
    /// sale (the genesis token keeps a vested developer allocation off the curve).
    /// @param supply The FULL token supply the FDV bounds are denominated in, so a band still
    /// means the fully diluted valuation it says it means.
    /// @param saleSupply The supply actually placed on the curve; the segment's share is taken
    /// of THIS, because it is all the Locker holds.
    function rangeFromShare(
        uint256 shareWad,
        uint256 fdvLower,
        uint256 fdvUpper,
        uint256 supply,
        uint256 saleSupply,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) internal pure returns (CurveRange memory range) {
        if (fdvUpper <= fdvLower) revert InvalidFdvRange();
        if (shareWad == 0 || shareWad > 1e18) revert InvalidShare();

        int24 tickLower;
        int24 tickUpper;
        if (tokenIsCurrency0) {
            // mirrored frame: higher FDV == higher tick
            tickLower = floorToSpacing(TickMath.getTickAtSqrtPrice(sqrtPriceAtFdv(fdvLower, supply, true)), tickSpacing);
            tickUpper = floorToSpacing(TickMath.getTickAtSqrtPrice(sqrtPriceAtFdv(fdvUpper, supply, true)), tickSpacing);
        } else {
            // genesis frame: higher FDV == lower price == lower tick
            tickLower = floorToSpacing(TickMath.getTickAtSqrtPrice(sqrtPriceAtFdv(fdvUpper, supply)), tickSpacing);
            tickUpper = floorToSpacing(TickMath.getTickAtSqrtPrice(sqrtPriceAtFdv(fdvLower, supply)), tickSpacing);
        }
        if (tickUpper <= tickLower) revert EmptyRange();

        uint256 amount = FullMath.mulDiv(saleSupply, shareWad, 1e18);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = tokenIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
        range = CurveRange({tickLower: tickLower, tickUpper: tickUpper, liquidity: liquidity});
    }
}
