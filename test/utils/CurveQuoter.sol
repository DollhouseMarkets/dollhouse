// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StandardCurve} from "../../contracts/libraries/StandardCurve.sol";
import {CurveRange} from "../../contracts/types/CurveRange.sol";
import {CurveSegment} from "../../contracts/types/CurveSegment.sol";

/// @notice The standard curve, behind an EXTERNAL call. Tests need the range table a link was
/// launched on in order to quote against it; calling `StandardCurve.build` inline inside a test
/// base puts the whole curve construction and the caller's own locals in one stack frame, which
/// the IR pipeline cannot allocate. An external call is the inlining barrier that fixes it, and
/// costs nothing that matters in a test.
contract CurveQuoter {
    function build(
        CurveSegment[] memory spec,
        uint256 parentSupply,
        uint256 tokenSupply,
        int24 tickSpacing,
        bool tokenIsCurrency0
    ) external pure returns (CurveRange[] memory ranges, uint160 initSqrtPriceX96) {
        return StandardCurve.build(spec, parentSupply, tokenSupply, tickSpacing, tokenIsCurrency0);
    }
}
