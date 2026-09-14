// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FenwickRangeAdd} from "../../contracts/libraries/FenwickRangeAdd.sol";

/// @notice Halmos symbolic checks over `FenwickRangeAdd` — properties SLV-01, SLV-02 and SLV-04
/// of `docs/spec/PROPERTIES.md`, bounded to `M <= 8`.
///
/// @dev The tree lives in THIS contract's storage (the library is `internal`), so there are no
/// external calls to symbolise. Two design constraints make these tractable:
///   - GENERATION INDICES ARE CONCRETE. `_add`/`_prefix` walk `i += i & -i`, a data-dependent
///     loop; with a symbolic index Halmos would have to bound the unrolling. With concrete
///     indices both loops unroll exactly, and the COEFFICIENTS stay fully symbolic — which is
///     where the arithmetic content of SLV-01/02/04 lives.
///   - `addSleeve` is NOT called: it routes through `FullMath.mulDiv` (512-bit mulmod plus a
///     modular inverse), which Z3 cannot discharge. `check_sleeveShapeNonNegative` instead
///     reproduces `addSleeve`'s coefficient expressions exactly from a symbolic `aWad`, so the
///     flooring behaviour under test is the library's own.
contract FenwickCheck {
    using FenwickRangeAdd for FenwickRangeAdd.Tree;

    FenwickRangeAdd.Tree internal tree;

    /// @dev Coefficient magnitude bound. Keeps `c * j^2` clear of int256 overflow (which would
    /// revert rather than falsify) while still covering WAD-scaled sleeve coefficients.
    int256 internal constant CAP = 1e40;

    /// @notice SLV-04. After one range-add of `c0 + c1*j + c2*j^2` over `[0, M]`, the point query
    /// at every `j` equals the closed form exactly, and every index past `M` is untouched.
    function check_rangeAddMatchesClosedForm(int256 c0, int256 c1, int256 c2) public {
        if (c0 > CAP || c0 < -CAP) return;
        if (c1 > CAP || c1 < -CAP) return;
        if (c2 > CAP || c2 < -CAP) return;

        uint256 M = 8;
        tree.rangeAdd(0, M, c0, c1, c2);
        for (uint256 j = 0; j <= M; ++j) {
            int256 jj = int256(j);
            assert(tree.query(j) == c0 + c1 * jj + c2 * jj * jj);
        }
        assert(tree.query(M + 1) == 0);
        assert(tree.query(M + 2) == 0);
    }

    /// @notice SLV-04 (additivity). Two overlapping range-adds superpose exactly: each index
    /// carries the sum of the polynomials whose ranges cover it, and nothing else.
    function check_rangeAddIsAdditive(int256 a0, int256 a1, int256 b0, int256 b1) public {
        if (a0 > CAP || a0 < -CAP) return;
        if (a1 > CAP || a1 < -CAP) return;
        if (b0 > CAP || b0 < -CAP) return;
        if (b1 > CAP || b1 < -CAP) return;

        tree.rangeAdd(0, 8, a0, a1, 0);
        tree.rangeAdd(3, 5, b0, b1, 0);

        // Covered by A only.
        assert(tree.query(0) == a0);
        assert(tree.query(2) == a0 + a1 * 2);
        assert(tree.query(8) == a0 + a1 * 8);
        // Covered by A and B.
        assert(tree.query(3) == (a0 + b0) + (a1 + b1) * 3);
        assert(tree.query(5) == (a0 + b0) + (a1 + b1) * 5);
    }

    /// @notice SLV-02. No index outside the added range is ever credited: a range-add over
    /// `[3, 5]` leaves every other index at exactly zero.
    function check_noCreditOutsideRange(int256 c0, int256 c1, int256 c2) public {
        if (c0 > CAP || c0 < -CAP) return;
        if (c1 > CAP || c1 < -CAP) return;
        if (c2 > CAP || c2 < -CAP) return;

        tree.rangeAdd(3, 5, c0, c1, c2);
        assert(tree.query(0) == 0);
        assert(tree.query(1) == 0);
        assert(tree.query(2) == 0);
        assert(tree.query(6) == 0);
        assert(tree.query(7) == 0);
        assert(tree.query(4095) == 0);
    }

    /// @notice SLV-01 at wei granularity. With `addSleeve`'s own coefficient expressions for
    /// `M = 8` and an arbitrary `aWad`, every ancestor's credited share is non-negative — the
    /// floor error of `5a/M` and `4a/M^2` never drives the minimum of `w(r) = 2 - 5r + 4r^2`
    /// (attained at `r = 5/8`, i.e. `j = 5` when `M = 8`) below zero.
    function check_sleeveShapeNonNegative(uint256 aWad) public {
        if (aWad == 0 || aWad > 1e40) return;

        uint256 M = 8;
        tree.rangeAdd(0, M, int256(2 * aWad), -int256((5 * aWad) / M), int256((4 * aWad) / (M * M)));
        for (uint256 j = 0; j <= M; ++j) {
            assert(tree.query(j) >= 0);
        }
    }
}
