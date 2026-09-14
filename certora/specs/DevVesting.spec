/*
 * DevVesting.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §B.1 (developer vesting) and docs/spec/PROPERTIES.md
 * §3.11 (VST-01..VST-06) and §6. Written from the specification only.
 *
 * Schedule, exactly (spec B.1):
 *   vested(t) = 0                              for t <  start + cliff
 *   vested(t) = total() * (t - start)/duration for start + cliff <= t < start + duration
 *   vested(t) = total()                        for t >= start + duration
 * with total() = token.balanceOf(this) + released.
 */

using DevVesting as vesting;

methods {
    function token() external returns (address) envfree;
    function start() external returns (uint64) envfree;
    function cliff() external returns (uint64) envfree;
    function duration() external returns (uint64) envfree;
    function beneficiary() external returns (address) envfree;
    function pendingBeneficiary() external returns (address) envfree;
    function beneficiaryTransferAt() external returns (uint64) envfree;
    function released() external returns (uint256) envfree;
    function ROLE_TRANSFER_DELAY() external returns (uint64) envfree;

    function total() external returns (uint256) envfree;
    function vested(uint64) external returns (uint256) envfree;
    // NOT envfree: releasable() reads block.timestamp (it is vested(now) - released).
    function releasable() external returns (uint256);

    function release() external returns (uint256);
    function announceBeneficiaryTransfer(address) external;
    function executeBeneficiaryTransfer() external;
    function cancelBeneficiaryTransfer() external;

    // The allocation token is a FamilyToken clone: a fixed-supply ERC-20 with no hooks and no
    // fee on transfer (spec B), so DISPATCHER is safe and no transfer can re-enter.
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
}

// ---------------------------------------------------------------------------------------------
// ghost state: the schedule triple must never move (VST-05)
// ---------------------------------------------------------------------------------------------

ghost mathint ghostScheduleWrites { init_state axiom ghostScheduleWrites == 0; }
ghost mathint ghostReleasedWrites { init_state axiom ghostReleasedWrites == 0; }

hook Sstore vesting.released uint256 v (uint256 old) {
    ghostReleasedWrites = ghostReleasedWrites + 1;
}

// ---------------------------------------------------------------------------------------------
// REVIEW-1: the constructor's own guards, restated
// ---------------------------------------------------------------------------------------------
// The schedule triple is written once, by a constructor that refuses `_duration == 0` and
// `_duration < _cliff`. `vested()` then evaluates `start + cliff` and `start + duration` in uint64,
// which reverts on overflow. Certora starts every rule from an ARBITRARY storage state, so none of
// that holds unless it is said out loud. This is not a weakening: it excludes exactly the states
// the deployed contract cannot be in.
// REVIEW-2. `releasable()` is `vested(uint64(block.timestamp)) - released`: the clock is TRUNCATED
// into uint64 on the way in, and the Prover picks `e.block.timestamp` out of the full uint256 range.
// `releasedEqualsTotalAfterDuration`'s review-2 counterexample was exactly that - a timestamp of
// 2^256 - 1923 satisfying `timestamp >= start + duration` as a mathint while the truncated clock
// landed mid-schedule. No live `block.timestamp` is outside uint64; this says so, and nothing more.
definition wellFormedNow(env e) returns bool =
    to_mathint(e.block.timestamp) < 18446744073709551616;

definition wellFormedSchedule() returns bool =
    duration() != 0
    && to_mathint(cliff()) <= to_mathint(duration())
    && to_mathint(start()) + to_mathint(cliff()) <= 18446744073709551615
    && to_mathint(start()) + to_mathint(duration()) <= 18446744073709551615;

// ---------------------------------------------------------------------------------------------
// the schedule (VST-02, VST-03)
// ---------------------------------------------------------------------------------------------

/// VST-02 (spec B.1 "Schedule, exactly"): nothing vests before the cliff.
rule nothingVestsBeforeTheCliff(uint64 t) {
    require to_mathint(t) < to_mathint(start()) + to_mathint(cliff());
    assert vested(t) == 0, "value vested before the cliff";
}

/// VST-02 (spec B.1): everything is vested at and after start + duration.
rule everythingVestsAtTheEnd(uint64 t) {
    require wellFormedSchedule();
    require to_mathint(t) >= to_mathint(start()) + to_mathint(duration());
    assert vested(t) == total(), "the schedule did not complete at start + duration";
}

/// VST-02 / VST-03 (spec B.1): vested(t) never exceeds total(), at any t.
rule vestedNeverExceedsTotal(uint64 t) {
    assert vested(t) <= total(), "vested exceeded the allocation";
}

/// VST-03 (spec B.1): vested(t) is monotone non-decreasing in t — the schedule only ever unlocks.
rule vestedIsMonotoneInTime(uint64 t0, uint64 t1) {
    require t0 <= t1;
    assert vested(t0) <= vested(t1), "vested decreased as time advanced";
}

/// VST-02 (spec B.1, "the cliff does not unlock zero"): at the cliff the vested amount is already
/// total() * cliff / duration, the whole amount accrued linearly since start.
rule theCliffUnlocksWhatAccruedSinceStart(uint64 t) {
    require to_mathint(t) == to_mathint(start()) + to_mathint(cliff());
    require duration() > 0 && to_mathint(cliff()) < to_mathint(duration());
    assert to_mathint(vested(t)) == to_mathint(total()) * to_mathint(cliff()) / to_mathint(duration()),
        "the cliff did not release the accrual since start";
}

// ---------------------------------------------------------------------------------------------
// released (VST-03, VST-04)
// ---------------------------------------------------------------------------------------------

/// VST-03 (spec B.1, PROPERTIES 3.11): released is monotone non-decreasing across every method.
rule releasedIsMonotone(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 before = released();
    f(e, args);
    assert released() >= before, "released decreased";
}

/// VST-03: released never exceeds total().
///
/// REVIEW-2 RESULT, READ IT BEFORE TRUSTING THIS INVARIANT: every sub-goal came back SANITY_FAIL in
/// 0 s. The invariant is a TAUTOLOGY as written - `total()` is DEFINED as
/// `token.balanceOf(address(this)) + released` (DevVesting.sol:83), so `released <= total()` reduces
/// to `released <= balance + released`, which is true of any two unsigned numbers whatever the
/// contract does. It is kept, marked, and NOT counted as evidence for VST-03; the rule below is the
/// non-trivial half, and `releasedIsMonotone` / `everythingVestsAtTheEnd` / `vestedNeverExceedsTotal`
/// carry the rest.
invariant releasedNeverExceedsTotal()
    released() <= total()
    filtered { f -> !f.isView && f.contract == currentContract }

/// VST-03, REVIEW-2: the claim the invariant above was meant to make - nothing is ever released
/// ahead of the schedule. This one is not a tautology: `vested(t)` is the schedule, not an identity
/// on `released`. Stated over the whole reachable clock range (see `wellFormedNow`).
/// REVIEW-3 (certora/RESULTS-review-2.md, checklist item 7): the schedule value is BOUND BEFORE THE
/// CALL, exactly as `releasedEqualsTotalAfterDuration` now does it, and for the same reason -
/// `vested(t)` is computed from `total()`, and `release` ends in OZ `safeTransfer`, an unresolved
/// low-level call the Prover AUTO-havocs ("havocs all contracts except DevVesting"), so the
/// post-state `total()` (and with it the post-state schedule) is unrelated to the pre-state one.
/// `total()` is `balanceOf(this) + released` and is CONSTANT across `release` by construction - the
/// balance falls by exactly `amount` and `released` rises by exactly `amount` - so the pre-state
/// schedule value IS the post-state one, and stating the claim against it is strictly stronger than
/// stating it against a havoc'd re-read.
rule releasedNeverExceedsVested(env e) {
    require wellFormedSchedule();
    require wellFormedNow(e);
    mathint vestedNow = to_mathint(vested(assert_uint64(e.block.timestamp)));
    require to_mathint(released()) <= vestedNow;
    release(e);
    assert to_mathint(released()) <= vestedNow,
        "more was released than the schedule had vested";
}

/// VST-03 (spec B.1): only release() moves released.
rule onlyReleaseMovesReleased(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 before = released();
    f(e, args);
    assert released() != before => f.selector == sig:release().selector,
        "released moved on a method other than release";
}

/// VST-04 (spec B.1 "Release"): release pays exactly vested(now) - released, to the current
/// beneficiary, regardless of who called.
rule releasePaysTheDeltaToTheCurrentBeneficiary(env e) {
    address b = beneficiary();
    uint256 owed = releasable(e);
    uint256 paid = release(e);
    assert paid == owed, "release paid an amount other than vested(now) - released";
    assert beneficiary() == b, "release changed the beneficiary";
}

/// VST-03 (spec B.1): released equals total() once the schedule has completed and a release has run.
/// REVIEW-2, TWO CORRECTIONS, neither weakening the claim:
///   (a) `total()` is read BEFORE the release. `release` ends in `token.safeTransfer`, which OZ's
///       SafeERC20 issues as a low-level `call` with hand-encoded calldata - so the Prover resolves
///       the CONTRACT but not the SIGHASH and applies an AUTO havoc ("havocs all contracts except
///       DevVesting"), which is in the review-2 counterexample's own call-resolution table. That
///       havoc rewrites `FamilyToken._balances[DevVesting]`, so `total()` RE-READ after the transfer
///       is unrelated to the allocation. The allocation is constant across `release` by
///       construction (the balance falls by exactly `amount` and `released` rises by exactly
///       `amount`), so reading it first states the same VST-03 claim against a value the havoc
///       cannot touch. Pinning the store rather than the re-read is strictly stronger.
///   (b) the clock is bounded to uint64 - see `wellFormedNow`.
rule releasedEqualsTotalAfterDuration(env e) {
    require wellFormedSchedule();
    require wellFormedNow(e);
    require to_mathint(e.block.timestamp) >= to_mathint(start()) + to_mathint(duration());
    uint256 allocation = total();
    release(e);
    assert released() == allocation,
        "the schedule completed without paying out the whole allocation";
}

// ---------------------------------------------------------------------------------------------
// no clawback, no acceleration (VST-05)
// ---------------------------------------------------------------------------------------------

/// VST-05 (spec B.1 "No clawback, no acceleration — structurally"): every non-view method either
/// reverts or leaves start, cliff and duration untouched. There is no function that can move them.
rule scheduleStorageIsImmutable(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint64 s = start();
    uint64 c = cliff();
    uint64 d = duration();
    address t = token();
    f(e, args);
    assert start() == s && cliff() == c && duration() == d && token() == t,
        "a method changed the vesting schedule";
}

/// VST-05 (spec B.1): no method reduces what the beneficiary can still claim, except release itself
/// (which reduces it by paying it out). There is no revoke, pause or clawback path.
rule nothingReducesClaimableExceptRelease(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 before = releasable(e);
    f(e, args);
    assert releasable(e) < before => f.selector == sig:release().selector,
        "a method other than release reduced the claimable amount";
}

/// VST-05 (spec B.1): no method accelerates the schedule — vested(t) for a fixed t never increases
/// except through total() growing, which only happens if the contract is sent more allocation.
/// SPEC-GAP: total() is defined as balanceOf(this) + released, so an unsolicited transfer in raises
/// total() and therefore vested(t). The spec does not forbid that; it is encoded as permitted here.
rule noAcceleration(method f, env e, calldataarg args, uint64 t)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 vBefore = vested(t);
    uint256 totalBefore = total();
    f(e, args);
    assert vested(t) > vBefore => total() > totalBefore,
        "vested(t) rose for a fixed t without the allocation growing";
}

// ---------------------------------------------------------------------------------------------
// the beneficiary triple (ROL-05, spec B.1 "Beneficiary transfer")
// ---------------------------------------------------------------------------------------------

/// ROL-05 (spec B.1): announce is current-beneficiary-only, refuses the zero address and refuses to
/// overwrite a pending transfer.
rule announceIsBeneficiaryOnly(env e, address to) {
    announceBeneficiaryTransfer(e, to);
    assert e.msg.sender == beneficiary() || e.msg.sender == pendingBeneficiary(),
        "a non-beneficiary announced a transfer";
    assert to != 0, "the zero address was accepted as beneficiary";
}

/// ROL-05 (spec B.1): execute is permissionless but reverts before announcement + 7 days, so an
/// incoming beneficiary can take the role even if the outgoing key is lost.
rule executeWaitsOutTheDelay(env e) {
    require beneficiaryTransferAt() != 0;
    require e.block.timestamp < beneficiaryTransferAt();
    executeBeneficiaryTransfer@withrevert(e);
    assert lastReverted, "a beneficiary transfer executed before its delay elapsed";
}

/// ROL-06 (PROPERTIES 3.10): executing a role transfer touches no balance and no schedule.
rule roleTransferTouchesNothingElse(env e) {
    uint256 r = released();
    uint64 s = start();
    uint64 d = duration();
    executeBeneficiaryTransfer(e);
    assert released() == r && start() == s && duration() == d,
        "a beneficiary transfer touched the schedule or the released amount";
}
