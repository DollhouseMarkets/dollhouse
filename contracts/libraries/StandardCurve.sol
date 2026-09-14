// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {CurveMath} from "./CurveMath.sol";
import {CurveRange} from "../types/CurveRange.sol";
import {CurveSegment} from "../types/CurveSegment.sol";

/// @title StandardCurve
/// @notice The one launch curve every succession candidate gets. The spec is a DEPLOY-TIME
/// constant of the factory (see `FamilyFactory.curveSpec`), not a hardcoded table: bounds are
/// multiples of the PARENT supply, so every link runs the same shape denominated in its own
/// parent — the self-similar property the family design depends on (`sim.curves.self_similar`).
library StandardCurve {
    error InvalidSpec();

    /// @notice Starting FDV in parent units: the lower bound of the first segment.
    function startFdv(CurveSegment[] memory spec, uint256 parentSupply) internal pure returns (uint256) {
        return FullMath.mulDiv(parentSupply, spec[0].fdvRatioLowerWad, 1e18);
    }

    /// @notice Shares must sum to 1 and the FDV bands must be contiguous and ascending, so the
    /// whole supply is on sale exactly once, with no gaps and no overlap.
    function validate(CurveSegment[] memory spec) internal pure {
        if (spec.length == 0) revert InvalidSpec();
        uint256 shares;
        for (uint256 i = 0; i < spec.length; i++) {
            if (spec[i].fdvRatioUpperWad <= spec[i].fdvRatioLowerWad) revert InvalidSpec();
            if (i > 0 && spec[i].fdvRatioLowerWad != spec[i - 1].fdvRatioUpperWad) revert InvalidSpec();
            shares += spec[i].shareWad;
        }
        if (shares != 1e18) revert InvalidSpec();
    }

    /// @notice Build the standard curve and the price the pool must be initialized at.
    /// @param spec The deploy-constant segments, relative to the parent supply.
    /// @param parentSupply Supply of the parent token (the numeraire), in parent units.
    /// @param tokenSupply Supply of the candidate token being launched.
    /// @param tickSpacing The pool's tick spacing.
    /// @param tokenIsCurrency0 True when the candidate token sorts below its parent.
    /// @return ranges Contiguous, single-sided (candidate-token-only) curve positions.
    /// @return initSqrtPriceX96 The initial price: exactly the top of the first range in the
    /// genesis frame, and one wei of sqrt price BELOW the bottom of the first range in the
    /// mirrored frame, so that in both cases every range is strictly out of range on the
    /// token-only side and no parent is ever owed at placement.
    function build(
        CurveSegment[] memory spec,
        uint256 parentSupply,
        uint256 tokenSupply,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) internal pure returns (CurveRange[] memory ranges, uint160 initSqrtPriceX96) {
        return build(spec, parentSupply, tokenSupply, tokenSupply, tickSpacing, tokenIsCurrency0);
    }

    /// @notice Build the standard curve when only `saleSupply` of `tokenSupply` is on sale: the
    /// genesis token keeps a vested developer allocation off the curve, so the Locker places the
    /// segment shares of the REMAINDER. The FDV bands (and therefore every tick) stay denominated
    /// in the full `tokenSupply`, so "FDV 1000 ETH" still means the whole supply at 1000 ETH.
    function build(
        CurveSegment[] memory spec,
        uint256 parentSupply,
        uint256 tokenSupply,
        uint256 saleSupply,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) internal pure returns (CurveRange[] memory ranges, uint160 initSqrtPriceX96) {
        ranges = new CurveRange[](spec.length);
        for (uint256 i = 0; i < spec.length; i++) {
            ranges[i] = CurveMath.rangeFromShare(
                spec[i].shareWad,
                FullMath.mulDiv(parentSupply, spec[i].fdvRatioLowerWad, 1e18),
                FullMath.mulDiv(parentSupply, spec[i].fdvRatioUpperWad, 1e18),
                tokenSupply,
                saleSupply,
                tickSpacing,
                tokenIsCurrency0
            );
        }
        initSqrtPriceX96 = tokenIsCurrency0
            ? TickMath.getSqrtPriceAtTick(ranges[0].tickLower) - 1
            : TickMath.getSqrtPriceAtTick(ranges[0].tickUpper);
    }
}
