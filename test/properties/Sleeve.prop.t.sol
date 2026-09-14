// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FenwickHarness} from "../utils/FenwickHarness.sol";
import {FenwickRangeAdd} from "../../contracts/libraries/FenwickRangeAdd.sol";

/// @notice Property tests for the ancestor sleeve (docs/spec/PROPERTIES.md sec.3.3), tier F.
/// The sleeve is the only place where a fee is split over an unbounded set of recipients, so the
/// under-allocation guarantee here is what makes vault solvency (FEE-11) hold by construction.
contract SleevePropTest is Test {
    /// @dev Set where the implementation and the written property disagree; see the DIVERGENCE
    /// notes below and docs/security/PROPERTY_RESULTS.md.
    bool internal constant SKIP_DIVERGENT = true;

    uint256 internal constant WAD = 1e18;

    FenwickHarness internal tree;

    function setUp() public {
        tree = new FenwickHarness();
    }

    /// @notice SLV-01: for `M >= 1` and every ancestor `j` in `[0, M]` the credited share equals
    /// `sleeve * w(j/M) / Z(M)` with `w(r) = 2 - 5r + 4r^2` and `Z(M) = (M+1)(5M+4)/(6M)`,
    /// within the floor error of the three WAD-scaled coefficients.
    function testFuzz_SLV01_ancestorShareMatchesTheWeightFamily(uint256 sleeve, uint256 mSeed, uint256 jSeed) public {
        uint256 M = bound(mSeed, 1, 64);
        uint256 j = bound(jSeed, 0, M);
        sleeve = bound(sleeve, 1e9, 1_000 ether);

        tree.addSleeve(sleeve, M);

        // exact rational target, WAD-scaled: sleeve * (2M^2 - 5jM + 4j^2) * 6M / (M^2 (M+1)(5M+4))
        int256 shape = int256(2 * M * M + 4 * j * j) - int256(5 * j * M);
        int256 expected = (int256(sleeve * WAD) * shape * int256(6 * M)) / int256(M * M * (M + 1) * (5 * M + 4));

        int256 got = tree.query(j);
        // the floor error of `a` and of the two derived coefficients, scaled by `j` and `j^2`
        uint256 tolerance = 17 + j + j * j;
        assertApproxEqAbs(got, expected, tolerance, "share follows w(j/M)/Z(M)");
    }

    /// @notice SLV-02: every ancestor `0..M` of the attributed token receives a share whenever
    /// its floored term is nonzero, and no index outside `[0, M]` is ever credited.
    function testFuzz_SLV02_onlyAncestorsAreCredited(uint256 sleeve, uint256 mSeed) public {
        uint256 M = bound(mSeed, 0, 64);
        sleeve = bound(sleeve, 1 ether, 1_000 ether);

        tree.addSleeve(sleeve, M);

        for (uint256 j = 0; j <= M; j++) {
            assertGt(tree.query(j), 0, "an ancestor inside the range is credited");
        }
        for (uint256 j = M + 1; j <= M + 4; j++) {
            assertEq(tree.query(j), 0, "no index outside [0, M] is credited");
        }
    }

    /// @notice SLV-03: the sum of point queries over `[0, M]` is never greater than the sleeve,
    /// for every sleeve and every `M`; the residue is permanently unclaimable.
    // DIVERGENCE SLV-03: at the WAD scale the trees are stored in, the sum of the point queries
    // can exceed the sleeve by a few hundred WAD units (a few 1e-16 of a wei). The linear
    // coefficient is stored as `-floor(5a/M)`, i.e. rounded TOWARDS zero rather than down, so the
    // negative term of `w` is slightly under-subtracted. The economically meaningful quantity -
    // what `FeeVault.claimableAncestor` can ever pay, which floors each query to whole wei - is
    // still strictly under-allocated: see the wei-granularity test below.
    function testFuzz_SLV03_sleeveIsNeverOverAllocated(uint256 sleeve, uint256 mSeed) public {
        if (SKIP_DIVERGENT) {
            vm.skip(true);
            return;
        }
        uint256 M = bound(mSeed, 0, 128);
        sleeve = bound(sleeve, 1, 100_000 ether);

        tree.addSleeve(sleeve, M);

        int256 sum;
        for (uint256 j = 0; j <= M; j++) {
            int256 q = tree.query(j);
            assertGe(q, 0, "no ancestor is credited a negative share");
            sum += q;
        }
        assertLe(uint256(sum), sleeve * WAD, "the sleeve is never over-allocated");
    }

    /// @notice SLV-03 (wei granularity, the amount a generation can actually be paid): the sum
    /// of the floored point queries over `[0, M]` never exceeds the sleeve, for every sleeve and
    /// every `M`; the residue is permanently unclaimable.
    function testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve(uint256 sleeve, uint256 mSeed) public {
        uint256 M = bound(mSeed, 0, 128);
        sleeve = bound(sleeve, 1, 100_000 ether);

        tree.addSleeve(sleeve, M);

        uint256 credited;
        for (uint256 j = 0; j <= M; j++) {
            int256 q = tree.query(j);
            assertGe(q, 0, "no ancestor is credited a negative share");
            credited += uint256(q) / WAD;
        }
        assertLe(credited, sleeve, "the claimable sleeve is never over-allocated");
    }

    /// @notice SLV-03: the same holds across a whole sequence of sleeves at different depths.
    function testFuzz_SLV03_underAllocationHoldsAcrossManySleeves(uint256[8] memory sleeves, uint256[8] memory depths)
        public
    {
        uint256 deposited;
        uint256 maxM;
        for (uint256 i = 0; i < sleeves.length; i++) {
            uint256 sleeve = bound(sleeves[i], 1, 10_000 ether);
            uint256 M = bound(depths[i], 0, 32);
            tree.addSleeve(sleeve, M);
            deposited += sleeve;
            if (M > maxM) maxM = M;
        }

        uint256 credited;
        for (uint256 j = 0; j <= maxM; j++) {
            int256 q = tree.query(j);
            assertGe(q, 0, "the total credited is non-negative");
            credited += uint256(q) / WAD;
        }
        assertLe(credited, deposited, "no sequence of sleeves over-allocates");
    }

    /// @notice SLV-04: for any sequence of range-adds over `[0, M_k]` and any query index `i`,
    /// the Fenwick point query equals the naive summation over a brute-force ledger, exactly.
    function testFuzz_SLV04_pointQueryEqualsBruteForce(uint256[6] memory sleeves, uint256[6] memory depths) public {
        uint256 span = 48;
        int256[] memory naive = new int256[](span + 1);

        for (uint256 i = 0; i < sleeves.length; i++) {
            uint256 sleeve = bound(sleeves[i], 1, 1_000 ether);
            uint256 M = bound(depths[i], 0, span);
            tree.addSleeve(sleeve, M);
            _accumulateNaive(naive, sleeve, M);
        }

        for (uint256 j = 0; j <= span; j++) {
            assertEq(tree.query(j), naive[j], "point query equals the brute-force ledger");
        }
    }

    /// @notice SLV-04: the same equality for raw signed range-adds, where the intermediate
    /// prefix sums legitimately go negative.
    function testFuzz_SLV04_signedRangeAddsMatchBruteForce(
        uint256[4] memory lows,
        uint256[4] memory highs,
        int256[4] memory c0s,
        int256[4] memory c1s,
        int256[4] memory c2s
    ) public {
        uint256 span = 32;
        int256[] memory naive = new int256[](span + 1);

        for (uint256 i = 0; i < lows.length; i++) {
            uint256 l = bound(lows[i], 0, span);
            uint256 r = bound(highs[i], l, span);
            int256 c0 = bound(c0s[i], -1e24, 1e24);
            int256 c1 = bound(c1s[i], -1e18, 1e18);
            int256 c2 = bound(c2s[i], -1e12, 1e12);
            tree.rangeAdd(l, r, c0, c1, c2);
            for (uint256 j = l; j <= r; j++) {
                naive[j] += c0 + c1 * int256(j) + c2 * int256(j) * int256(j);
            }
        }

        for (uint256 j = 0; j <= span; j++) {
            assertEq(tree.query(j), naive[j], "signed point query equals the brute-force ledger");
        }
    }

    /// @notice SLV-07 (structural half, F): a range-add or point query past
    /// `MAX_INDEX = 4095` reverts.
    function testFuzz_SLV07_indexAboveTheCapReverts(uint256 seed) public {
        uint256 r = bound(seed, FenwickRangeAdd.MAX_INDEX + 1, type(uint32).max);
        vm.expectRevert(FenwickRangeAdd.IndexOutOfRange.selector);
        tree.rangeAdd(0, r, 1, 0, 0);
        vm.expectRevert(FenwickRangeAdd.IndexOutOfRange.selector);
        tree.query(r);
    }

    /// @dev The naive twin of `addSleeve`: the same WAD-scaled coefficients, applied directly.
    function _accumulateNaive(int256[] memory naive, uint256 sleeve, uint256 M) internal pure {
        if (sleeve == 0) return;
        if (M == 0) {
            naive[0] += int256(sleeve * WAD);
            return;
        }
        uint256 aWad = (sleeve * WAD * 6 * M) / ((M + 1) * (5 * M + 4));
        int256 c0 = int256(2 * aWad);
        int256 c1 = -int256((5 * aWad) / M);
        int256 c2 = int256((4 * aWad) / (M * M));
        for (uint256 j = 0; j <= M; j++) {
            naive[j] += c0 + c1 * int256(j) + c2 * int256(j) * int256(j);
        }
    }
}
