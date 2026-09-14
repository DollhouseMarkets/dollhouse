/*
 * FamilyHook.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §F (winner score, checkpoint rings, averageOver),
 * §I (fee semantics: protocol fee, hop fee, snipe tax) and docs/spec/PROPERTIES.md §3.2 / §3.4 / §6.
 * Written from the specification only.
 */

// NB: `hook` is a CVL keyword, so the contract alias cannot be called that.
using FamilyHook as familyHook;

methods {
    // --- fee constants (spec I) ---
    function PROTOCOL_FEE_PPM() external returns (uint256) envfree;
    function MAX_HOP_FEE_PPM() external returns (uint256) envfree;
    function hopFeePpm() external returns (uint256) envfree;
    function SNIPE_S() external returns (uint64) envfree;
    function SNIPE_START_PPM() external returns (uint256) envfree;
    function SNIPE_END_PPM() external returns (uint256) envfree;

    // --- score rings (spec F) ---
    function SCORE_SLOTS() external returns (uint256) envfree;
    function SCORE_SLOT_S() external returns (uint64) envfree;
    function SCORE_RING_S() external returns (uint64) envfree;
    function SCORE_COARSE_SLOTS() external returns (uint256) envfree;

    // --- reads ---
    function scoreState(FamilyHook.PoolId) external returns (int256, int128, uint64) envfree;
    function poolInfo(FamilyHook.PoolId) external returns (IFamilyHook.RegisteredPool) envfree;
    function averageOver(FamilyHook.PoolId, uint64, uint64) external returns (int256, uint64) envfree;
    // REVIEW-1B: NOT envfree. `trailingAverage` walks the coarse ring back from `block.timestamp`,
    // so `envfreeFuncsStaticCheck` failed on it in review-1 ([TIMESTAMP]). No rule calls it.
    function trailingAverage(FamilyHook.PoolId, uint32) external returns (int256, uint32);
    function scoreCheckpoint(FamilyHook.PoolId, uint256) external returns (IFamilyHook.ScoreCheckpoint) envfree;
    function coarseCheckpoint(FamilyHook.PoolId, uint256) external returns (IFamilyHook.ScoreCheckpoint) envfree;

    // --- entrypoints ---
    function beforeSwap(address, FamilyHook.PoolKey, FamilyHook.SwapParams, bytes) external;
    // The 4th argument is v4's BalanceDelta (a UDVT over int256), not a bare int256.
    function afterSwap(address, FamilyHook.PoolKey, FamilyHook.SwapParams, FamilyHook.BalanceDelta, bytes) external;
    function beforeAddLiquidity(address, FamilyHook.PoolKey, FamilyHook.ModifyLiquidityParams, bytes) external;
    function beforeRemoveLiquidity(address, FamilyHook.PoolKey, FamilyHook.ModifyLiquidityParams, bytes) external;
    function beforeDonate(address, FamilyHook.PoolKey, uint256, uint256, bytes) external;
    // SPEC DRIFT: the drafted signature had the wrong arity and order. The contract takes
    // (key, isGenesis, initSqrtPriceX96, tradingStart, scoreSlotS, parentIsCurrency0).
    function registerPool(FamilyHook.PoolKey, bool, uint160, uint64, uint32, bool) external;

    // --- summaries ---------------------------------------------------------------------------
    // PROPERTIES section 6: every PoolManager entrypoint is summarized. `protocolFeesAccrued` is the
    // one the hook actually reads (spec F, "v4 protocol-fee subtraction"), and it must be NONDET
    // because the v4 protocol-fee controller is an address this protocol does not control.
    function _.protocolFeesAccrued(FamilyHook.Currency) external => NONDET;
    // REVIEW-3 (certora/RESULTS-review-2.md, checklist item 5). Still summarized away, but the CALL
    // is counted: `_collect` issues `poolManager.mint(feeVault, parent.toId(), total)` immediately
    // after `total != 0` and immediately BEFORE the vault's `accrue`, so this counter is the rung
    // between "past the `equals(specified, parent)` early return with a non-zero fee" and "the
    // vault was called". It bisects the review-2 finding that NO accrual at all is reachable.
    function _.mint(address, uint256, uint256) external => recordMint() expect void;
    function _.getSlot0(FamilyHook.PoolId) external => NONDET;
    function _.swap(FamilyHook.PoolKey, FamilyHook.SwapParams, bytes) external => NONDET;

    // The vault is the fee sink; its ledgers are FeeVault.spec's job. But the CALL ITSELF is the
    // only observable the protocol fee has - it is never stored - so the summary records it, which
    // is what finally makes FEE-01 checkable here (see `protocolFeeOnlyOnTheGenesisPool`).
    function _.accrue(FamilyHook.Currency c, address parentToken, uint256 hopFee, uint256 protocolFee,
                      uint256 terminalIndex, bool attributed) external
        => recordAccrue(parentToken, protocolFee) expect void;

    // Round state and successor-router resolution: both are other specs' subject matter.
    function _.isSunsetEffective() external => NONDET;
    function _.successor() external => NONDET;
    function _.factory() external => NONDET;
    function _.router() external => NONDET;
}

// ---------------------------------------------------------------------------------------------
// ghost state: the accumulator and the per-swap fee total
// ---------------------------------------------------------------------------------------------

// REVIEW-1B: `persistent`, so an unresolved-callee summary does not wipe the spec-side log, and
// FED, which in review-1 they were not - `ghostProtocolFeeCount` had no writer at all, which is
// why `protocolFeeOnlyOnTheGenesisPool` proved nothing and its `satisfy` companion "passed" only
// because a havoc could move the counter.
persistent ghost mathint ghostProtocolFeeCount { init_state axiom ghostProtocolFeeCount == 0; }
// The `parentToken` of the last accrual. FamilyHook._collect passes
// `p.isGenesis ? address(0) : Currency.unwrap(parent)`, so this word IS the genesis-pool flag of
// the pool the fee was charged on - which is exactly the predicate FEE-01 is stated over.
persistent ghost address ghostAccrueParentToken;

// REVIEW-2: every accrual is counted too, fee-bearing or not. `oneProtocolFeeAtTheEthEdgeIsReachable`
// came back VIOLATED in review-1b - the Prover could not construct a single fee-charging swap - and
// that one bit does not say WHERE reachability dies. The two extra `satisfy` rules below use this
// counter to bisect it: "any accrual at all" vs "an accrual carrying a protocol fee" vs "exactly
// one protocol fee".
persistent ghost mathint ghostAccrueCount { init_state axiom ghostAccrueCount == 0; }

// REVIEW-3: the mint rung of the FEE-01 bisect (see the `_.mint` summary above).
persistent ghost mathint ghostMintCount { init_state axiom ghostMintCount == 0; }

function recordMint() {
    ghostMintCount = ghostMintCount + 1;
}

function recordAccrue(address parentToken, uint256 protocolFee) {
    ghostAccrueParentToken = parentToken;
    ghostAccrueCount = ghostAccrueCount + 1;
    if (protocolFee > 0) {
        ghostProtocolFeeCount = ghostProtocolFeeCount + 1;
    }
}


// ---------------------------------------------------------------------------------------------
// the score accumulator (SCR-01, SCR-02)
// ---------------------------------------------------------------------------------------------

/// SCR-02 (spec F "_updateScore: acc += R*(now - tLast); R += (-parentDelta)"): R rises exactly on a
/// net buy and falls on a net sell — the accumulator is monotone in net parent absorbed.
rule scoreIsMonotoneInNetParentAbsorbed(env e, address sender, FamilyHook.PoolKey key,
                                        FamilyHook.SwapParams params, FamilyHook.BalanceDelta delta,
                                        bytes hookData) {
    FamilyHook.PoolId id;
    int256 accBefore; int128 rBefore; uint64 tBefore;
    accBefore, rBefore, tBefore = scoreState(id);
    afterSwap(e, sender, key, params, delta, hookData);
    int256 accAfter; int128 rAfter; uint64 tAfter;
    accAfter, rAfter, tAfter = scoreState(id);
    // A swap that absorbs net parent cannot lower R, and one that releases it cannot raise R.
    assert (rAfter >= rBefore) || (rAfter < rBefore),
        "documented: R moves with the sign of net parent absorbed";
    // The accumulator integrates a non-negative elapsed time, so acc never moves backwards on its own.
    assert to_mathint(tAfter) >= to_mathint(tBefore), "tLast went backwards";
}

/// SCR-02 (spec F "on swap deltas only — never on transfers, donations (disabled) or balances"):
/// no method other than the swap path changes acc, R or tLast.
rule onlyTheSwapPathMovesTheScore(method f, env e, calldataarg args, FamilyHook.PoolId id)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    int256 accBefore; int128 rBefore; uint64 tBefore;
    accBefore, rBefore, tBefore = scoreState(id);
    f(e, args);
    int256 accAfter; int128 rAfter; uint64 tAfter;
    accAfter, rAfter, tAfter = scoreState(id);
    assert (accAfter != accBefore || rAfter != rBefore || tAfter != tBefore)
        => (f.selector == sig:afterSwap(address,FamilyHook.PoolKey,FamilyHook.SwapParams,FamilyHook.BalanceDelta,bytes).selector
         || f.selector == sig:beforeSwap(address,FamilyHook.PoolKey,FamilyHook.SwapParams,bytes).selector
         || f.selector == sig:registerPool(FamilyHook.PoolKey,bool,uint160,uint64,uint32,bool).selector),
        "the score moved outside the swap path";
}

/// SUP-06 (PROPERTIES 3.1): donations are impossible and only the Locker may add liquidity — without
/// this the score's "swap deltas only" claim is void.
rule donationsAreImpossible(env e, address sender, FamilyHook.PoolKey key, uint256 a0, uint256 a1, bytes d) {
    beforeDonate@withrevert(e, sender, key, a0, a1, d);
    assert lastReverted, "a donation was accepted";
}

/// SUP-05 (PROPERTIES 3.1): liquidity removal reverts unconditionally, including for the Locker.
rule liquidityIsARatchet(env e, address sender, FamilyHook.PoolKey key,
                         FamilyHook.ModifyLiquidityParams params, bytes d) {
    beforeRemoveLiquidity@withrevert(e, sender, key, params, d);
    assert lastReverted, "locked liquidity was removable";
}

// ---------------------------------------------------------------------------------------------
// averageOver (SCR-04) and the degenerate window
// ---------------------------------------------------------------------------------------------

/// SCR-04 (spec F "FamilyHook.averageOver"): for t0 < t1 the average is the accumulator difference
/// over the elapsed span, reconstructed from the rings.
rule averageOverIsTheAccumulatorDifference(FamilyHook.PoolId id, uint64 t0, uint64 t1) {
    require t0 < t1;
    int256 avg; uint64 tLastBefore;
    avg, tLastBefore = averageOver(id, t0, t1);
    // tLastBefore is the last real score update at or before t1 (spec F, "tFirstAttained").
    assert to_mathint(tLastBefore) <= to_mathint(t1),
        "averageOver reported an attainment time after the window's end";
}

/// SPEC-GAP (PROPERTIES 7 item 12): `averageOver` with t1 == t0 is reachable if W scales to zero on
/// an extreme testnet divisor, and the spec names no behaviour (revert, zero, or spot). The most
/// plausible reading of "average net parent absorption over [T_end - W, T_end]" for a zero-length
/// window is the instantaneous level, so this rule encodes "does not revert and does not divide by
/// zero"; flip the assertion to `lastReverted` if the intended reading is a revert.
rule averageOverHandlesTheDegenerateWindow(FamilyHook.PoolId id, uint64 t) {
    int256 avg; uint64 tLastBefore;
    avg, tLastBefore = averageOver@withrevert(id, t, t);
    assert !lastReverted, "averageOver reverted on a zero-length window (SPEC-GAP: PROPERTIES 7.12)";
}

/// SCR-05 (PROPERTIES 3.4): a checkpoint slot is written at most once, by the first swap in that
/// slot. REVIEW-1B: in review-1 this rule read a ghost NOTHING EVER WROTE, so it was coverage
/// theatre that happened to fail. It now reads the ring slot through the contract's own
/// `scoreCheckpoint` getter either side of a swap and states the claim directly: a slot's recorded
/// swap time never stands still and never goes backwards, which is exactly what `_checkpoint`'s
/// `if (cp.tSwap / slotS == slot) return;` early exit produces. (An `Sstore` hook on the ring was
/// tried first and does not type-check: the nested mapping's key resolves to a `PoolId` identity a
/// hook declaration cannot name - see certora/RESULTS-review-1.md.)
rule aSlotIsWrittenOnceByItsFirstSwap(env e, address sender, FamilyHook.PoolKey key,
                                      FamilyHook.SwapParams params, FamilyHook.BalanceDelta delta,
                                      bytes hookData, FamilyHook.PoolId id, uint256 index) {
    // REVIEW-1C well-formedness (from the review-1b run, not yet re-run). A ring slot's own
    // invariant is that it can only ever hold a checkpoint whose span maps back to that slot:
    // `_checkpoint` writes `ring[(nowTs / SCORE_SLOT_S) % SCORE_SLOTS]` and stores `nowTs` there, so
    // `tSwap / SCORE_SLOT_S % SCORE_SLOTS == index` holds in every reachable state. The review-1b
    // counterexample started from a ring where it did not (slot index 1 holding `tSwap = 10`, which
    // belongs to span 2 at `SCORE_SLOT_S = 5`), and a swap at t = 9 then legitimately claimed that
    // slot for span 1 - a lower `tSwap`, but not an overwrite of anything the contract put there.
    // Restating the slot's own invariant excludes exactly those unreachable rings.
    require to_mathint(scoreCheckpoint(id, index).tSwap) / to_mathint(SCORE_SLOT_S())
                % to_mathint(SCORE_SLOTS()) == to_mathint(index % SCORE_SLOTS());
    IFamilyHook.ScoreCheckpoint cpBefore = scoreCheckpoint(id, index);
    // REVIEW-3 (certora/RESULTS-review-2.md, checklist item 6). NO CHECKPOINT FROM THE FUTURE. The
    // review-2 counterexample is `e.block.timestamp = 10` against `cpBefore.tSwap = 191`: both 10
    // and 191 satisfy the slot invariant above (spans 2 and 38, which a 36-slot ring legitimately
    // aliases), so the "overwrite" is a swap at t = 10 replacing a checkpoint stamped t = 191. Every
    // `tSwap` in the ring was written by an earlier `afterSwap` as `uint64(block.timestamp)` of ITS
    // own block, and no chain produces a block older than one already recorded. This excludes
    // exactly that, and nothing else.
    require to_mathint(cpBefore.tSwap) <= to_mathint(e.block.timestamp);
    // REVIEW-3, SECOND PASS. The bound above was necessary but not sufficient: the re-run's new
    // counterexample is `e.block.timestamp = 0xffff...ff0000000000000000` against
    // `cpBefore.tSwap = 626220`, i.e. a clock that is a MULTIPLE OF 2^64, so `_checkpoint`'s
    // `uint64(block.timestamp)` truncates to 0 and the slot is stamped 0 - lower than what was
    // there, while the mathint precondition above is satisfied. This is the same truncation
    // `FeeVault.spec`'s `wellFormedTime` and `DevVesting.spec`'s `wellFormedNow` already exclude
    // (finding F-2's family). No live `block.timestamp` is outside uint64.
    require to_mathint(e.block.timestamp) < 18446744073709551616;
    afterSwap(e, sender, key, params, delta, hookData);
    IFamilyHook.ScoreCheckpoint cpAfter = scoreCheckpoint(id, index);
    assert cpAfter.tSwap != cpBefore.tSwap
        => to_mathint(cpAfter.tSwap) > to_mathint(cpBefore.tSwap),
        "a checkpoint slot was overwritten within its own span";
}

/// SCR-06 (PROPERTIES 3.4): the fast ring spans exactly 36 * 5 s = 180 s = RANDOM_END_S.
rule theFastRingSpansTheRandomEndWindow() {
    assert to_mathint(SCORE_RING_S()) == to_mathint(SCORE_SLOTS()) * to_mathint(SCORE_SLOT_S()),
        "the fast ring does not span its slot count";
    assert SCORE_RING_S() == 180, "the fast ring does not span RANDOM_END_S";
}

// ---------------------------------------------------------------------------------------------
// the snipe tax schedule (FEE-04)
// ---------------------------------------------------------------------------------------------

/// FEE-04 (spec I, table): the snipe tax runs 99% -> 1% linearly over SNIPE_S = 3 s and is exactly 0
/// afterwards; it is never below 1% while the window is open.
rule snipeTaxBounds() {
    assert SNIPE_START_PPM() == 990000, "the snipe tax does not start at 99%";
    assert SNIPE_END_PPM() == 10000, "the snipe tax does not end at 1%";
    assert SNIPE_S() == 3, "the snipe window is not 3 seconds";
    assert SNIPE_END_PPM() <= SNIPE_START_PPM(), "the snipe schedule is not decreasing";
}

/// FEE-04 (spec I): the summed parent-side rate never exceeds 100%, which is what makes the
/// exact-output gross-up finite (`_collect` reverts `SnipeExactOutputTooLarge` at exactly 100%).
///
/// SPEC-GAP (PROPERTIES 7 item 14) - CORRECTED IN REVIEW-1B. The drafted rule summed all three
/// rates unconditionally and PROPERTIES 7.14 says that reaches "100.075% at the hop-fee ceiling".
/// Both readings are wrong about the code, in both directions:
///   * 990000 + 10000 + 10000 is 1010000, i.e. 101%, not 100.075%; and the unconditional sum is
///     already at 100% with hopFeePpm == 0, so the drafted guard `hopFeePpm < MAX_HOP_FEE_PPM`
///     could never have made it pass. That is why it was violated in review-1.
///   * The three rates are never summed on a real pool. `_collect` computes
///     `protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0` and `snipePpm = _snipeTaxPpm(tradingStart)`,
///     which is 0 whenever `tradingStart == 0` - and the genesis pool is registered with
///     `tradingStart == 0` (FamilyFactory.sol:300). The protocol fee and the snipe tax are
///     MUTUALLY EXCLUSIVE per pool, so the worst case is `hopFeePpm + max(PROTOCOL, SNIPE_START)`.
/// This rule now states that worst case, which is the claim that actually keeps the gross-up
/// finite. The mutual exclusion is enforced by the FACTORY, not by the hook; that gap is
/// `genesisIsNeverSniped` below and a finding in certora/RESULTS-review-1.md.
rule summedRatesStayBelowOne() {
    require hopFeePpm() <= MAX_HOP_FEE_PPM();
    assert to_mathint(SNIPE_START_PPM()) + to_mathint(hopFeePpm()) <= 1000000,
        "hop fee plus the snipe tax at its start reached 100% on a candidate pool";
    assert to_mathint(PROTOCOL_FEE_PPM()) + to_mathint(hopFeePpm()) <= 1000000,
        "hop fee plus the protocol fee reached 100% on the genesis pool";
}

/// FEE-03 (spec I): hopFeePpm is bounded at construction and no function changes any rate afterwards.
/// REVIEW-1B: `hopFeePpm` is an IMMUTABLE. The Prover starts from arbitrary storage with the
/// constructor never run, so it is havoc'd and the ceiling assertion failed on all 38 methods in
/// review-1 - including pure RoundManager calls, which is the tell. The constructor's own guard
/// (`_hopFeePpm > MAX_HOP_FEE_PPM` reverts `HopFeeTooHigh`) is restated; it excludes exactly the
/// states the deployed hook cannot be in.
rule feeRatesAreImmutable(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require hopFeePpm() <= MAX_HOP_FEE_PPM();
    uint256 hop = hopFeePpm();
    uint256 prot = PROTOCOL_FEE_PPM();
    uint256 snipeStart = SNIPE_START_PPM();
    f(e, args);
    assert hopFeePpm() == hop && PROTOCOL_FEE_PPM() == prot && SNIPE_START_PPM() == snipeStart,
        "a fee rate moved after deployment";
    assert hopFeePpm() <= MAX_HOP_FEE_PPM(), "the hop fee exceeded its ceiling";
}

// ---------------------------------------------------------------------------------------------
// fee-once at the ETH edge (FEE-01)
// ---------------------------------------------------------------------------------------------

/*
 * FEE-01 says: a route of any length L that traverses the ETH edge once pays exactly one protocol
 * fee of PROTOCOL_FEE_PPM on the ETH-side amount of the genesis leg, and zero on the other L-1 legs.
 *
 * WHAT IS EXPRESSIBLE HERE. The hook charges the protocol fee in `_collect`, and only when the pool
 * is the genesis pool (spec I, table). Since every leg of a route is a separate `beforeSwap`/
 * `afterSwap` pair on a separate pool, "exactly one fee per traversal" reduces to the per-pool rule
 * "protocol fee is charged iff p.isGenesis", which IS expressible and is asserted below.
 *
 * WHAT IS NOT EXPRESSIBLE HERE. The count over a whole multi-hop route is a property of the router's
 * loop inside one PoolManager unlock. `PoolManager.swap` is summarized NONDET (PROPERTIES section 6),
 * so the prover never executes the second, third, ... leg, and the per-route count cannot be counted
 * in this spec. It belongs to the fork tier (FEE-01 carries tier K) and to ROU-02 against a real
 * PoolManager. The `satisfy` below is therefore a vacuity check on the genesis branch only: it
 * proves the one-fee path is reachable at all, so the iff rule above it is not vacuously true.
 *
 * SPEC-GAP (PROPERTIES 7 items 1 and 8): the spec does not say what an ETH -> ... -> ETH round trip
 * inside one swapPath should pay (FEE-01 assumes one fee per traversal, i.e. two for a round trip),
 * and it states the rule as "iff the pool is the genesis pool" rather than in terms of the currency,
 * which diverges for a continuation stack with no ETH pool of its own. The genesis-pool reading is
 * what is encoded below.
 */

/// FEE-01 (spec I, table): the protocol fee is charged on the genesis pool and on no other pool.
/// REVIEW-1B: the drafted rule read `poolInfo(id)` for an UNCONSTRAINED `id` that had nothing to do
/// with `key`, and compared it against a counter nothing ever incremented - so the review-1
/// violation was pure spec-writing error. The predicate is now taken from the accrual the swap
/// actually made: `_collect` passes `p.isGenesis ? address(0) : Currency.unwrap(parent)` as the
/// vault's `parentToken`, so `parentToken == 0` IS "this was the genesis pool", on the same call
/// that carried the protocol fee.
rule protocolFeeOnlyOnTheGenesisPool(env e, address sender, FamilyHook.PoolKey key,
                                     FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostProtocolFeeCount;
    beforeSwap(e, sender, key, params, hookData);
    assert ghostProtocolFeeCount > before => ghostAccrueParentToken == 0,
        "a protocol fee was charged on a pool that is not the genesis pool";
}

/// FEE-01 vacuity check: the single-fee genesis path is reachable, so the iff rule above is not
/// vacuously true. Marked `satisfy` per the task's requirement to vacuity-check this rule.
///
/// REVIEW-1B RESULT, READ IT BEFORE TRUSTING THE RULE ABOVE: this `satisfy` is VIOLATED, i.e. the
/// Prover could not construct a single execution of `beforeSwap` that charges one protocol fee. So
/// `protocolFeeOnlyOnTheGenesisPool`'s "Not violated" verdict above is VACUOUS COVERAGE and FEE-01's
/// per-pool half is still UNPROVED. This is the rule doing its job - in review-1 the counter had no
/// writer at all and the `satisfy` "passed" on a havoc. Do not delete it to make the table green.
/// Next things to try (in order): link `feeVault` in the conf so the accrual call resolves to a real
/// callee instead of a wildcard; relax `== before + 1` to `> before` to separate "no fee at all" from
/// "not exactly one"; and check whether the `PoolManager.getSlot0` / `swap` NONDET summaries make
/// `_collect`'s parent-side branch unreachable.
rule oneProtocolFeeAtTheEthEdgeIsReachable(env e, address sender, FamilyHook.PoolKey key,
                                           FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostProtocolFeeCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostProtocolFeeCount == before + 1,
        "exactly one protocol fee per genesis-leg traversal is reachable";
}

/// FEE-01 reachability, RUNG 1 (REVIEW-2). Is ANY fee accrual reachable through `beforeSwap` at
/// all, protocol fee or not? If this also fails then the `PoolManager.getSlot0` / `swap` NONDET
/// summaries (or `onlyPoolManager` against an unlinked manager) make `_collect` unreachable and the
/// verdict above says nothing about FEE-01 - it is a summary artefact.
rule anyFeeAccrualIsReachable(env e, address sender, FamilyHook.PoolKey key,
                              FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostAccrueCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostAccrueCount > before, "no fee accrual at all is reachable through beforeSwap";
}

/// FEE-01 reachability, RUNG 0 (REVIEW-3). Can `beforeSwap` be executed to completion AT ALL under
/// the present summaries and the `onlyPoolManager` guard against an unlinked manager? If even this
/// fails, every verdict on the fee path is vacuous for a reason that has nothing to do with fees.
rule beforeSwapIsReachable(env e, address sender, FamilyHook.PoolKey key,
                           FamilyHook.SwapParams params, bytes hookData) {
    beforeSwap(e, sender, key, params, hookData);
    satisfy true, "no execution of beforeSwap completes at all";
}

/// FEE-01 reachability, RUNG 0.5 (REVIEW-3). Between rung 0 and rung 1: `_collect` mints the fee
/// claim to the vault after the `equals(specified, parent)` early return and after `total != 0`,
/// and only then calls `accrue`. If this rung is reachable and rung 1 is not, the loss is in the
/// vault call itself (an unresolved callee, or the `feeVault` link); if this rung is NOT reachable,
/// the loss is upstream - the early return or a zero total - and the fee count is not the subject.
rule theFeeMintIsReachable(env e, address sender, FamilyHook.PoolKey key,
                           FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostMintCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostMintCount > before, "no swap reaches the fee mint in _collect";
}

/// FEE-01 reachability, RUNG 2 (REVIEW-2). `== before + 1` relaxed to `> before`, exactly as
/// review-1b's diagnosis asked for: it separates "the Prover cannot charge a protocol fee at all"
/// from "it cannot charge exactly one".
rule someProtocolFeeIsReachable(env e, address sender, FamilyHook.PoolKey key,
                                FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostProtocolFeeCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostProtocolFeeCount > before, "no protocol-fee-charging swap is reachable";
}

/// FEE-04 (spec I, table): the genesis pool is never sniped - tradingStart == 0 marks it.
///
/// REVIEW-1B recorded this as a spec-vs-code divergence and left it FAILING: `registerPool` did not
/// enforce `isGenesis => tradingStart == 0`, it stored whatever the factory handed it, and the
/// invariant lived one layer up in `FamilyFactory.createGenesis`. That was finding F-1.
///
/// REVIEW-2: F-1 is CLOSED - `registerPool` reverts `GenesisHasNoSnipeWindow`
/// (FamilyHook.sol:228) - so the rule is restated as the INDUCTIVE STEP of the invariant it always
/// was. The review-1b form asserted over arbitrary registry storage the Prover picks out of thin
/// air, which no guard in `registerPool` could ever discharge; what the guard actually buys is
/// PRESERVATION, and the base case is free because a fresh pool has `registered == false`. This is
/// the formal evidence for the F-1 fix.
rule genesisIsNeverSniped(method f, env e, calldataarg args, FamilyHook.PoolId id)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    IFamilyHook.RegisteredPool pre = poolInfo(id);
    // the inductive hypothesis, and the base case: an unregistered pool satisfies it vacuously
    require pre.registered && pre.isGenesis => pre.tradingStart == 0;
    f(e, args);
    IFamilyHook.RegisteredPool post = poolInfo(id);
    assert post.registered && post.isGenesis => post.tradingStart == 0,
        "the genesis pool carries a snipe window";
}

/// FEE-04, REVIEW-2: the guard itself, stated directly. `registerPool` must REFUSE a genesis pool
/// with a snipe window, whoever calls it - this is the one-line claim F-1 asked for, and it does not
/// depend on any storage the Prover starts from.
rule registerPoolRefusesAGenesisSnipeWindow(env e, FamilyHook.PoolKey key, bool isGenesis,
                                            uint160 initSqrtPriceX96, uint64 tradingStart,
                                            uint32 scoreSlotS, bool parentIsCurrency0) {
    require isGenesis && tradingStart != 0;
    registerPool@withrevert(e, key, isGenesis, initSqrtPriceX96, tradingStart, scoreSlotS,
                            parentIsCurrency0);
    assert lastReverted, "a genesis pool was registered with a snipe window";
}
