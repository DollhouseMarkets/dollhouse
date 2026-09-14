// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice One contiguous single-sided range of the standard launch curve.
/// @dev Ranges are token-only (the family token is the only asset deposited) and sit on the
/// side of the initial price that buying moves into. Produced by `CurveMath.rangeFromShare`.
struct CurveRange {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}
