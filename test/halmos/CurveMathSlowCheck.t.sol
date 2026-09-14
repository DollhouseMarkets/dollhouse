// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

/// @notice The two CurveMath checks that Halmos cannot discharge on this machine. They are kept
/// in a SEPARATE contract so the default `--contract CurveMathCheck` run stays green and fast;
/// neither has ever produced a verdict, and neither has produced a counterexample either.
///
/// @dev Measured (halmos 0.3.3, Z3, single solver thread — see `docs/security/halmos-review-1.md`):
///   - `check_floorToSpacingAnySpacing`: 23 paths, TIMEOUT after 270s of solver time with
///     `--solver-timeout-assertion 30000`. Cause: 256-bit `sdiv`/`smod` by a SYMBOLIC divisor.
///   - `check_fdvRoundTrip`: no result in 10 minutes wall clock. Cause: `FullMath.mulDiv`
///     (512-bit mulmod plus a modular inverse) composed three deep with OpenZeppelin `Math.sqrt`
///     (an unrolled Newton iteration), all over a symbolic numerator.
/// Both properties are covered concretely by the forge fuzz suite (`test/CurveMath.t.sol`).
contract CurveMathSlowCheck {
    uint256 internal constant SUPPLY = 1e27;

    /// @notice KNOWN TIMEOUT: floorToSpacing is a true floor for EVERY positive spacing.
    function check_floorToSpacingAnySpacing(int24 tick, int24 tickSpacing) public pure {
        if (tickSpacing <= 0 || tickSpacing > 1000) return;
        if (tick < -887272 || tick > 887272) return;
        int24 floored = CurveMath.floorToSpacing(tick, tickSpacing);
        assert(floored <= tick);
        assert(tick - floored < tickSpacing);
        assert(floored % tickSpacing == 0);
    }

    /// @notice KNOWN TIMEOUT: `sqrtPriceAtFdv` and `fdvAtSqrtPrice` are inverses to within
    /// 1 part in 10_000, at the production supply.
    function check_fdvRoundTrip(uint256 fdv) public view {
        if (fdv < 1e15 || fdv > 1e24) return;
        uint160 sqrtPriceX96;
        try this.sqrtPriceAtFdvExternal(fdv) returns (uint160 p) {
            sqrtPriceX96 = p;
        } catch {
            return;
        }
        uint256 recovered = CurveMath.fdvAtSqrtPrice(sqrtPriceX96, SUPPLY, false);
        uint256 diff = recovered > fdv ? recovered - fdv : fdv - recovered;
        assert(diff * 10_000 <= fdv);
    }

    function sqrtPriceAtFdvExternal(uint256 fdv) external pure returns (uint160) {
        return CurveMath.sqrtPriceAtFdv(fdv, SUPPLY, false);
    }
}
