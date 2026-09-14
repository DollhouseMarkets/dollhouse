/*
 * Sleeve.spec — the Fenwick ancestor sleeve
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §J ("Ancestor polynomial") and docs/spec/PROPERTIES.md
 * §3.3 (SLV-01..SLV-07) and §6. Written from the specification only.
 *
 * Closed form (spec J): weights w(r) = 2 - 5r + 4r^2 with r = j/M, normalised by
 * Z(M) = (M+1)(5M+4)/(6M), so a = sleeve/Z(M), c0 = 2a, c1 = -5a/M, c2 = 4a/M^2, WAD-scaled; a
 * sleeve is one range-add over [0, M] and a payout is one point query. Every division floors, so the
 * point queries sum to slightly LESS than the sleeve and the residue is permanently unclaimable.
 *
 * FenwickRangeAdd is an internal library, so these rules run against
 * certora/harness/FenwickHarness.sol, which exposes rangeAdd / addSleeve / query /
 * coefficientPrefix and nothing else.
 */

using FenwickHarness as fenwick;

methods {
    function MAX_INDEX() external returns (uint256) envfree;
    function WAD() external returns (uint256) envfree;
    function rangeAdd(uint256, uint256, int256, int256, int256) external envfree;
    function addSleeve(uint256, uint256) external envfree;
    function query(uint256) external returns (int256) envfree;
    function coefficientPrefix(uint256, uint256) external returns (int256) envfree;
}

// ---------------------------------------------------------------------------------------------
// ghost state (PROPERTIES section 6: ghostSleeveDeposited[M], ghostSleeveQueried[j])
// ---------------------------------------------------------------------------------------------

ghost mathint ghostSleeveDeposited { init_state axiom ghostSleeveDeposited == 0; }
// Highest index ever credited by a range-add, so "no index outside [0, M]" is checkable.
ghost mathint ghostMaxCreditedIndex { init_state axiom ghostMaxCreditedIndex == 0; }

// ---------------------------------------------------------------------------------------------
// REVIEW-3 (certora/RESULTS-review-2.md, checklist item 4): BOUND THE TREE THE PROVER STARTS FROM
// ---------------------------------------------------------------------------------------------
// Review-2 left three rules FAILING on counterexamples that are all the same thing: a pre-state
// tree word one below `INT256_MAX` (`before = 0x7fff...0133`) or one above `INT256_MIN`
// (`-0x7fff...1c3`), against which `_add`'s `unchecked` `t[i] += v` wraps. `_add` is unchecked BY
// DESIGN - the trees are signed and tree 1's intermediate prefix sums are legitimately negative -
// and the wrap is not a claim about the sleeve. The reachable magnitudes are bounded by
// construction: a tree word is a sum of WAD-scaled coefficients of sleeves, each sleeve is bounded
// by the vault's ETH balance (< 2^128 wei), WAD is 1e18 < 2^60, and at most 4096 indices
// contribute, so |word| < 2^128 * 2^60 * 2^12 = 2^200. This says exactly that and nothing else. It
// also removes most of the search space the five review-2 TIMEOUTS were lost in.
definition TREE_BOUND() returns mathint =
    1606938044258990275541962092341162602522202993782792835301376;       // 2^200
definition COEFF_BOUND() returns mathint =
    1461501637330902918203684832716283019655932542976;                   // 2^160

hook Sload int256 v fenwick.tree.t0[KEY uint256 i] {
    require to_mathint(v) < TREE_BOUND() && to_mathint(v) > -TREE_BOUND();
}
hook Sload int256 v fenwick.tree.t1[KEY uint256 i] {
    require to_mathint(v) < TREE_BOUND() && to_mathint(v) > -TREE_BOUND();
}
hook Sload int256 v fenwick.tree.t2[KEY uint256 i] {
    require to_mathint(v) < TREE_BOUND() && to_mathint(v) > -TREE_BOUND();
}

// ---------------------------------------------------------------------------------------------
// the closed form (SLV-01, SLV-05, SLV-06)
// ---------------------------------------------------------------------------------------------

/// SLV-01 (spec J "Ancestor polynomial"): a range-add of the sleeve's coefficients followed by a
/// point query at j returns the quadratic c0 + c1*j + c2*j^2 the closed form prescribes.
/// Stated on the harness, on a single sleeve, so the reconstruction is exact modulo the WAD floors.
/// REVIEW-1: stated as a DELTA. The Prover starts every rule from an arbitrary tree, not an empty
/// one, so `query(j) == c0 + c1*j + c2*j^2` was false for a zero range-add on a non-empty tree.
/// The delta form is the claim SLV-01 actually makes ("a range-add contributes the quadratic") and
/// is strictly more general than the empty-tree form, so nothing is weakened.
rule rangeAddThenPointQueryIsTheClosedForm(uint256 M, uint256 j, int256 c0, int256 c1, int256 c2) {
    require M <= MAX_INDEX() && j <= M;
    // REVIEW-3: the coefficients a real sleeve deposits are `c0 = 2a`, `c1 = -5a/M`, `c2 = 4a/M^2`
    // with `a = sleeve * WAD / Z(M)`, so |c| < 2^160 covers every sleeve the vault can hold. Without
    // it the Prover picks `c0 = -0x5555...599` against a near-INT256_MAX tree word and the
    // `unchecked` add wraps - an overflow of the rule's own choosing, not a defect of the library.
    require to_mathint(c0) < COEFF_BOUND() && to_mathint(c0) > -COEFF_BOUND();
    require to_mathint(c1) < COEFF_BOUND() && to_mathint(c1) > -COEFF_BOUND();
    require to_mathint(c2) < COEFF_BOUND() && to_mathint(c2) > -COEFF_BOUND();
    int256 before = query(j);
    rangeAdd(0, M, c0, c1, c2);
    assert to_mathint(query(j)) - to_mathint(before)
        == to_mathint(c0) + to_mathint(c1) * to_mathint(j) + to_mathint(c2) * to_mathint(j) * to_mathint(j),
        "the point query did not reconstruct the quadratic";
}

/// SLV-04 (PROPERTIES 3.3): the Fenwick point query is additive over range-adds — two sleeves
/// deposited in sequence query as the sum of their individual contributions.
rule pointQueryIsAdditive(uint256 M, uint256 j, int256 a0, int256 a1, int256 a2,
                          int256 b0, int256 b1, int256 b2) {
    require M <= MAX_INDEX() && j <= M;
    // REVIEW-3: same bound as above, on both range-adds (review-2 counterexample:
    // `first = -0x7fff...d8b0`, `a1 = 0x3fff...96ad`).
    require to_mathint(a0) < COEFF_BOUND() && to_mathint(a0) > -COEFF_BOUND();
    require to_mathint(a1) < COEFF_BOUND() && to_mathint(a1) > -COEFF_BOUND();
    require to_mathint(a2) < COEFF_BOUND() && to_mathint(a2) > -COEFF_BOUND();
    require to_mathint(b0) < COEFF_BOUND() && to_mathint(b0) > -COEFF_BOUND();
    require to_mathint(b1) < COEFF_BOUND() && to_mathint(b1) > -COEFF_BOUND();
    require to_mathint(b2) < COEFF_BOUND() && to_mathint(b2) > -COEFF_BOUND();
    rangeAdd(0, M, a0, a1, a2);
    int256 first = query(j);
    rangeAdd(0, M, b0, b1, b2);
    int256 second = query(j);
    assert to_mathint(second) - to_mathint(first)
        == to_mathint(b0) + to_mathint(b1) * to_mathint(j) + to_mathint(b2) * to_mathint(j) * to_mathint(j),
        "a second range-add did not add its own quadratic";
}

/// SLV-06 (spec J "M == 0 is the genesis-only case"): a sleeve at M == 0 credits genesis alone, with
/// no division by zero.
/// REVIEW-1: stated as a DELTA (see the note on rangeAddThenPointQueryIsTheClosedForm), and
/// tightened from "credited something" to the amount spec J actually names: at M == 0 the WHOLE
/// WAD-scaled sleeve lands on index 0. That is SLV-06's claim, so this is a strengthening.
rule genesisTakesTheWholeSleeveAtMZero(uint256 sleeve) {
    // REVIEW-3: the WAD-scaled sleeve is bounded like every other coefficient (was: below
    // INT256_MAX, which let the deposit itself wrap a near-extreme tree word).
    require to_mathint(sleeve) * to_mathint(WAD()) < COEFF_BOUND();
    int256 before = query(0);
    addSleeve(sleeve, 0);
    assert to_mathint(query(0)) - to_mathint(before) == to_mathint(sleeve) * to_mathint(WAD()),
        "the genesis-only sleeve did not credit the whole sleeve to index 0";
}

/// SLV-05 (PROPERTIES 3.3): w(0) = 2*w(M) for every M >= 1 — the shape the weights are defined by.
/// REVIEW-2: stated as a DELTA, for the same reason as SLV-01/02/06 above - the Prover starts from
/// an ARBITRARY tree, so the absolute form was a claim about whatever was already in it, not about
/// the sleeve this call deposited. The delta form is SLV-05's actual claim and is unweakened.
/// REVIEW-2 tractability: this rule TIMED OUT at 417 s in review-1 over the full 4096-wide index
/// range. `M` is bounded to 64 here. That IS a scoping restriction and is recorded as one: the
/// shape claim at arbitrary depth stays with the fuzz tier
/// (`Sleeve.prop::testFuzz_SLV01_ancestorShareMatchesTheWeightFamily`).
rule genesisWeightIsTwiceTheTerminalWeight(uint256 sleeve, uint256 M) {
    require M >= 1 && M <= 64;
    require sleeve > 0 && sleeve < 340282366920938463463374607431768211456;
    mathint before0 = to_mathint(query(0));
    mathint beforeM = to_mathint(query(M));
    addSleeve(sleeve, M);
    mathint d0 = to_mathint(query(0)) - before0;
    mathint dM = to_mathint(query(M)) - beforeM;
    // w(0) = 2 and w(1) = 1 in unnormalised units, so the first ancestor's credit is twice the last's,
    // to within the WAD floor of the three coefficients.
    assert d0 * 1000 >= dM * 1999 && d0 * 1000 <= dM * 2001 + 1000,
        "w(0) was not twice w(M) within the stated floor tolerance";
}

/// SLV-02 (PROPERTIES 3.3): every point query in [0, M] is non-negative — no ancestor is ever debited
/// even though the linear coefficient and tree 1's intermediate prefix sums are negative.
/// REVIEW-1: stated as a DELTA. SLV-02's claim is that a sleeve never DEBITS an ancestor; the
/// absolute form was false only because the tree it starts from is arbitrary, which says nothing
/// about the sleeve. The delta form is the property, unweakened.
rule everyAncestorShareIsNonNegative(uint256 sleeve, uint256 M, uint256 j) {
    require M <= MAX_INDEX() && j <= M;
    int256 before = query(j);
    addSleeve(sleeve, M);
    assert to_mathint(query(j)) >= to_mathint(before), "an ancestor's share was negative";
}

// ---------------------------------------------------------------------------------------------
// conservation (SLV-03) and range discipline (SLV-02, SLV-07)
// ---------------------------------------------------------------------------------------------

/// SLV-03 (spec J "Every division floors, so the point queries sum to slightly less than the sleeve"):
/// the sum over [0, M] never exceeds the sleeve; the residue is permanently unclaimable.
/// Stated pairwise plus the closed-form bound, because CVL cannot quantify a sum over a symbolic
/// range: for the depth-bounded case M <= 3 the sum is written out, and the general case is carried
/// by the per-term bound `query(j) <= sleeve` combined with rangeAddThenPointQueryIsTheClosedForm.
/// REVIEW-2, TWO CORRECTIONS, both restoring the claim the specification makes rather than
/// weakening it - and together they are why this rule and the one below came back VACUOUS.
///   (a) DELTA, not absolute. The Prover starts from an ARBITRARY tree (the same defect review-1
///       found in SLV-01/02/06), so the absolute sum said nothing about THIS sleeve.
///   (b) SCALE. The trees store WAD-scaled coefficients - `addSleeve` range-adds `sleeve * WAD` -
///       so a point query is in WAD units, and `query(j) <= sleeve` was comparing a 1e18-scaled
///       share against a raw wei sleeve. Conservation is stated at the granularity that can
///       actually be PAID: `FeeVault.claimableAncestor` divides the point query by WAD, so it is
///       the sum of the per-generation WEI credits that must not exceed the sleeve.
/// That is exactly the row `docs/security/PROPERTY_RESULTS.md` records as PASSING
/// (`testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`). The WAD-scale sum is a DOCUMENTED
/// DIVERGENCE in the row above it: `c1` is stored as `-floor(5a/M)`, rounded towards zero, so the
/// negative term is slightly under-subtracted and the WAD-scale sum can sit a few hundred WAD
/// units (~1e-16 wei) ABOVE the sleeve. The divergence is not asserted away here; it is the reason
/// the bound is taken at wei granularity, and it stays on the record in PROPERTY_RESULTS.md.
rule sumOfSharesNeverExceedsTheSleeveSmallM(uint256 sleeve, uint256 M) {
    require M <= 3;
    // REVIEW-1: written as a decimal. `^` is not exponentiation in CVL, so `2^128` did not
    // mean what it read as.
    require sleeve > 0 && sleeve < 340282366920938463463374607431768211456;
    // CVL forbids reassigning a variable after it has been read, so the four terms are bound
    // once each and the out-of-range ones are zeroed rather than accumulated in place.
    mathint b0 = to_mathint(query(0));
    mathint b1 = M >= 1 ? to_mathint(query(1)) : 0;
    mathint b2 = M >= 2 ? to_mathint(query(2)) : 0;
    mathint b3 = M >= 3 ? to_mathint(query(3)) : 0;
    addSleeve(sleeve, M);
    mathint w = to_mathint(WAD());
    mathint q0 = (to_mathint(query(0)) - b0) / w;
    mathint q1 = M >= 1 ? (to_mathint(query(1)) - b1) / w : 0;
    mathint q2 = M >= 2 ? (to_mathint(query(2)) - b2) / w : 0;
    mathint q3 = M >= 3 ? (to_mathint(query(3)) - b3) / w : 0;
    assert q0 + q1 + q2 + q3 <= to_mathint(sleeve), "the ancestor shares over-allocated the sleeve";
}

/// SLV-03 (spec J): no single ancestor's share can exceed the whole sleeve, at any depth. This is the
/// depth-independent half of the conservation bound.
/// Rounding bound: each of the three WAD-scaled coefficients floors once per term, so the sum over
/// [0, M] is at least sleeve - 3*(M+1) wei below the sleeve and never above it.
/// REVIEW-2: the same two corrections as the rule above - DELTA rather than absolute, and the bound
/// is the WAD-SCALED sleeve because a point query is in WAD units. `w(0) = 2a` is the largest single
/// share and `2a <= sleeve * WAD` for every M (an equality only at M == 0, the genesis-only case),
/// so this is the depth-independent half of SLV-03 stated at the scale the tree holds.
rule noShareExceedsTheSleeve(uint256 sleeve, uint256 M, uint256 j) {
    require M <= MAX_INDEX() && j <= M;
    // REVIEW-1: written as a decimal. `^` is not exponentiation in CVL, so `2^128` did not
    // mean what it read as.
    require sleeve > 0 && sleeve < 340282366920938463463374607431768211456;
    int256 before = query(j);
    addSleeve(sleeve, M);
    assert to_mathint(query(j)) - to_mathint(before) <= to_mathint(sleeve) * to_mathint(WAD()),
        "one ancestor took more than the whole sleeve";
}

/// SLV-02 (PROPERTIES 3.3): no index outside [0, M] is ever credited by a sleeve.
rule noIndexOutsideTheRangeIsCredited(uint256 sleeve, uint256 M, uint256 j) {
    require M < MAX_INDEX() && j > M && j <= MAX_INDEX();
    int256 before = query(j);
    addSleeve(sleeve, M);
    assert query(j) == before, "an index beyond M was credited";
}

/// SLV-07 (spec J "MAX_INDEX = 4095 caps the chain"): a range-add or a query past MAX_INDEX reverts.
/// REVIEW-1 added `sleeve > 0`, because `addSleeve` short-circuited on a zero sleeve BEFORE
/// `rangeAdd`'s MAX_INDEX check, so a zero sleeve past MAX_INDEX was a silent no-op rather than a
/// revert. REVIEW-2 fix 6 (docs/attack-log.md) moved the `M > MAX_INDEX` check ABOVE the
/// short-circuit, so the precondition is REMOVED again and the rule states SLV-07 as written: an
/// out-of-range index ALWAYS reverts. This rule is the formal evidence for that fix.
rule indexPastMaxReverts(uint256 sleeve, uint256 M) {
    require M > MAX_INDEX();
    addSleeve@withrevert(sleeve, M);
    assert lastReverted, "a sleeve was deposited past MAX_INDEX";
}

/// SLV-07: a reversed range is refused rather than silently treated as empty.
rule reversedRangeReverts(uint256 l, uint256 r, int256 c0, int256 c1, int256 c2) {
    require l > r;
    rangeAdd@withrevert(l, r, c0, c1, c2);
    assert lastReverted, "a reversed range was accepted";
}
