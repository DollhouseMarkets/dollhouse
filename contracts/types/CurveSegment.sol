// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice One segment of the standard launch curve, expressed relative to the PARENT supply so
/// that the same spec describes every link in the chain (the self-similar property).
/// @param shareWad Share of the candidate's own supply sold in this segment (1e18 = 100%).
/// @param fdvRatioLowerWad Lower FDV bound as a multiple of the parent supply (WAD).
/// @param fdvRatioUpperWad Upper FDV bound as a multiple of the parent supply (WAD).
struct CurveSegment {
    uint256 shareWad;
    uint256 fdvRatioLowerWad;
    uint256 fdvRatioUpperWad;
}
