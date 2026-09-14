// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurveMath} from "../../contracts/libraries/CurveMath.sol";

/// @notice Halmos symbolic checks over CurveMath's pure, allocation-free helpers. Kept separate
/// from CurveMath.t.sol (concrete/fuzz forge tests) so the symbolic run has a tight target:
/// pure integer arithmetic with no storage and no external state.
///
/// @dev Scope note. Z3 cannot handle 256-bit division by a SYMBOLIC divisor in reasonable
/// time, so `tickSpacing` is held concrete here: `60` is the production value
/// (`FamilyFactory.TICK_SPACING`) and `1 / 10 / 200` cover the other standard v4 spacings.
/// The fully-symbolic-spacing variant lives in `CurveMathSlowCheck.t.sol` and is a known
/// TIMEOUT; see `docs/security/halmos-review-1.md`.
contract CurveMathCheck {
    /// @dev Production tick spacing (`FamilyFactory.TICK_SPACING`).
    int24 internal constant PROD_SPACING = 60;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    /// @dev Production total supply (`FamilyToken.FAMILY_TOTAL_SUPPLY`).
    uint256 internal constant SUPPLY = 1e27;

    /// @dev `TickMath.MIN_SQRT_PRICE`.
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;

    function _floorIsFloor(int24 tick, int24 spacing) internal pure {
        int24 floored = CurveMath.floorToSpacing(tick, spacing);
        assert(floored <= tick);
        assert(tick - floored < spacing);
        assert(floored % spacing == 0);
    }

    /// @notice CRV-adjacent: at the PRODUCTION tick spacing, floorToSpacing always rounds toward
    /// negative infinity to a multiple of the spacing, never past `tick`, and never more than one
    /// spacing width away — over every tick in the v4 tick range, including negative ticks.
    function check_floorToSpacingProd(int24 tick) public pure {
        if (tick < MIN_TICK || tick > MAX_TICK) return;
        _floorIsFloor(tick, PROD_SPACING);
    }

    /// @notice Same property at tickSpacing 1 (the degenerate spacing).
    function check_floorToSpacingOne(int24 tick) public pure {
        if (tick < MIN_TICK || tick > MAX_TICK) return;
        _floorIsFloor(tick, 1);
    }

    /// @notice Same property at tickSpacing 10.
    function check_floorToSpacingTen(int24 tick) public pure {
        if (tick < MIN_TICK || tick > MAX_TICK) return;
        _floorIsFloor(tick, 10);
    }

    /// @notice Same property at tickSpacing 200 (the widest standard v4 spacing).
    function check_floorToSpacingTwoHundred(int24 tick) public pure {
        if (tick < MIN_TICK || tick > MAX_TICK) return;
        _floorIsFloor(tick, 200);
    }

    /// @notice `sqrtPriceAtFdv` never returns a price below `TickMath.MIN_SQRT_PRICE`: it either
    /// reverts with `InvalidFdvRange` or returns an in-range price. There is no silent
    /// out-of-range return that a caller could pass on to v4.
    function check_sqrtPriceNeverOutOfRange(uint256 fdv) public view {
        if (fdv < 1e15 || fdv > 1e24) return;
        try this.sqrtPriceAtFdvExternal(fdv) returns (uint160 p) {
            assert(p >= MIN_SQRT_PRICE);
        } catch {
            return;
        }
    }

    /// @dev External wrapper so the checks above can use `try/catch` on a pure function.
    function sqrtPriceAtFdvExternal(uint256 fdv) external pure returns (uint160) {
        return CurveMath.sqrtPriceAtFdv(fdv, SUPPLY, false);
    }
}
