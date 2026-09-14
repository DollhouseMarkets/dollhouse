// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @title FenwickRangeAdd
/// @notice Range-add / point-query of the quadratic `c0 + c1*j + c2*j^2` over generation
/// indices, in O(log N) per fee. This is the on-chain twin of `sim/family.py`'s
/// `FenwickRangeAdd`: three signed Fenwick trees hold the polynomial COEFFICIENTS, so adding
/// the polynomial over `[l, r]` is `+c_k` at `l` and `-c_k` at `r + 1` in tree `k`, and a
/// prefix sum at `j` recovers the accumulated coefficients:
///
///     query(j) = C0(j) + C1(j) * j + C2(j) * j^2
///
/// @dev The trees MUST be signed: for the ancestor weight family `w(r) = 2 - 5r + 4r^2` the
/// linear coefficient is negative, so tree 1's intermediate prefix sums legitimately go below
/// zero even though every point query is non-negative. Coefficients are stored WAD-scaled
/// (see FeeVault) so that `c1 = -5a/M` and `c2 = 4a/M^2` keep their precision.
library FenwickRangeAdd {
    /// @notice Largest supported generation index (inclusive). One index per family link.
    uint256 internal constant MAX_INDEX = 4095;
    /// @notice Fixed-point scale of the stored coefficients.
    uint256 internal constant WAD = 1e18;

    error IndexOutOfRange();
    error BadRange();

    struct Tree {
        mapping(uint256 => int256) t0;
        mapping(uint256 => int256) t1;
        mapping(uint256 => int256) t2;
    }

    function _add(mapping(uint256 => int256) storage t, uint256 i, int256 v) private {
        unchecked {
            i += 1; // 1-based
            while (i <= MAX_INDEX + 2) {
                t[i] += v;
                i += i & (~i + 1);
            }
        }
    }

    function _prefix(mapping(uint256 => int256) storage t, uint256 i) private view returns (int256 s) {
        unchecked {
            i += 1;
            while (i > 0) {
                s += t[i];
                i -= i & (~i + 1);
            }
        }
    }

    /// @notice Add `c0 + c1*j + c2*j^2` to every index `j` in `[l, r]`.
    function rangeAdd(Tree storage tree, uint256 l, uint256 r, int256 c0, int256 c1, int256 c2) internal {
        if (l > r) revert BadRange();
        if (r > MAX_INDEX) revert IndexOutOfRange();
        if (c0 != 0) {
            _add(tree.t0, l, c0);
            _add(tree.t0, r + 1, -c0);
        }
        if (c1 != 0) {
            _add(tree.t1, l, c1);
            _add(tree.t1, r + 1, -c1);
        }
        if (c2 != 0) {
            _add(tree.t2, l, c2);
            _add(tree.t2, r + 1, -c2);
        }
    }

    /// @notice Range-add one ancestor sleeve over `[0, M]` with the brief's weight family
    /// `w(r) = 2 - 5r + 4r^2`, `r = j/M`, normalised by `Z(M) = (M+1)(5M+4)/(6M)`.
    /// @dev Coefficients are WAD-scaled so that `c1 = -5a/M` and `c2 = 4a/M^2` keep their
    /// precision; `a = sleeve / Z(M)`. Every division floors, so the point queries sum to
    /// slightly LESS than `sleeve` (a few wei), never more. `M == 0` is the genesis-only case,
    /// where `Z` is undefined and the whole sleeve goes to index 0.
    function addSleeve(Tree storage tree, uint256 sleeve, uint256 M) internal {
        // the bound is checked BEFORE the zero short-circuit, so an index past the cap always
        // reverts rather than passing silently when there is nothing to credit (SLV-07)
        if (M > MAX_INDEX) revert IndexOutOfRange();
        if (sleeve == 0) return;
        if (M == 0) {
            rangeAdd(tree, 0, 0, int256(sleeve * WAD), 0, 0);
            return;
        }
        uint256 aWad = FullMath.mulDiv(sleeve * WAD, 6 * M, (M + 1) * (5 * M + 4));
        rangeAdd(tree, 0, M, int256(2 * aWad), -int256((5 * aWad) / M), int256((4 * aWad) / (M * M)));
    }

    /// @notice Point query at generation `j`.
    function query(Tree storage tree, uint256 j) internal view returns (int256) {
        if (j > MAX_INDEX) revert IndexOutOfRange();
        int256 jj = int256(j);
        return _prefix(tree.t0, j) + _prefix(tree.t1, j) * jj + _prefix(tree.t2, j) * jj * jj;
    }

    /// @notice Accumulated coefficient `k` at `j`; exposed so tests can show the signed
    /// intermediates really do go negative (an unsigned port would underflow here).
    function coefficientPrefix(Tree storage tree, uint256 k, uint256 j) internal view returns (int256) {
        if (k == 0) return _prefix(tree.t0, j);
        if (k == 1) return _prefix(tree.t1, j);
        return _prefix(tree.t2, j);
    }
}
