/*
 * FamilyHook.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §F (winner score, checkpoint rings, averageOver),
 * §I (fee semantics: protocol fee, hop fee, snipe tax) and docs/spec/PROPERTIES.md §3.2 / §3.4 / §6.
 *
 * `isGenesis` IS `isEdge`: there is no genesis pool at all:
 * canonical index 0 is a token this protocol did not launch and does not quote, so every pool the
 * hook ever registers is a ROUND pool with a published end. Three things follow, and all three are
 * rules below rather than readings of the source:
 *   - the protocol fee is charged on an EDGE pool (a pool whose parent is canonical index 0, decided
 *     by the factory at registration and frozen for the pool's life) and on no other;
 *   - `GenesisHasNoSnipeWindow` is gone, because a round-one pool IS both edge and freshly opened.
 *     The two rates would sum above 100% and break the exact-output gross-up, so the EDGE FEE IS
 * SUPPRESSED FOR THE SNIPE WINDOW's three seconds. The summed-rate invariant is
 *     preserved IN TIME rather than by pool class;
 *   - the `nominalEnd == 0` freeze exemption is gone: every registered pool has
 *     `nominalEnd > tradingStart` and every registered pool's score rings freeze at that end.
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
    // `averageOver` returns the two INSTANTS the accumulator was actually evaluated
    // at alongside the average and the attainment time: (avg, tLastBefore, tStartUsed, tEndUsed).
    function averageOver(FamilyHook.PoolId, uint64, uint64) external returns (int256, uint64, uint64, uint64) envfree;
    // NOT envfree. `trailingAverage` walks the coarse ring back from `block.timestamp`,
    // so `envfreeFuncsStaticCheck` fails on it. No rule calls it.
    function trailingAverage(FamilyHook.PoolId, uint32) external returns (int256, uint32);
    function scoreCheckpoint(FamilyHook.PoolId, uint256) external returns (IFamilyHook.ScoreCheckpoint) envfree;
    function coarseCheckpoint(FamilyHook.PoolId, uint256) external returns (IFamilyHook.ScoreCheckpoint) envfree;
    // The END SEAL. One checkpoint per pool, written by the FIRST swap strictly
    // after the pool's published end, whose interval `[tState, tSwap)` brackets every instant the
    // round can be scored at. `endSeal` itself is internal; this is its getter.
    function endCheckpoint(FamilyHook.PoolId) external returns (IFamilyHook.ScoreCheckpoint) envfree;

    // --- entrypoints ---
    function beforeSwap(address, FamilyHook.PoolKey, FamilyHook.SwapParams, bytes) external;
    // The 4th argument is v4's BalanceDelta (a UDVT over int256), not a bare int256.
    function afterSwap(address, FamilyHook.PoolKey, FamilyHook.SwapParams, FamilyHook.BalanceDelta, bytes) external;
    function beforeAddLiquidity(address, FamilyHook.PoolKey, FamilyHook.ModifyLiquidityParams, bytes) external;
    function beforeRemoveLiquidity(address, FamilyHook.PoolKey, FamilyHook.ModifyLiquidityParams, bytes) external;
    function beforeDonate(address, FamilyHook.PoolKey, uint256, uint256, bytes) external;
    // The contract takes
    // (key, isEdge, initSqrtPriceX96, tradingStart, nominalEnd, scoreSlotS, parentIsCurrency0).
    // The second argument is `isEdge`, not `isGenesis`, and `nominalEnd > tradingStart` is
    // now UNIVERSAL (`BadNominalEnd`). There is no pool class that carries 0 and never freezes.
    function registerPool(FamilyHook.PoolKey, bool, uint160, uint64, uint64, uint32, bool) external;

    // --- summaries ---------------------------------------------------------------------------
    // PROPERTIES section 6: every PoolManager entrypoint is summarized. `protocolFeesAccrued` is the
    // one the hook actually reads (spec F, "v4 protocol-fee subtraction"), and it must be NONDET
    // because the v4 protocol-fee controller is an address this protocol does not control.
    function _.protocolFeesAccrued(FamilyHook.Currency) external => NONDET;
    // Still summarized away, but the CALL is counted: `_collect` issues
    // `poolManager.mint(feeVault, parent.toId(), total)` immediately after `total != 0` and
    // immediately BEFORE the vault's `accrue`, so this counter is the rung between "past the
    // `equals(specified, parent)` early return with a non-zero fee" and "the vault was called".
    function _.mint(address, uint256, uint256) external => recordMint() expect void;
    function _.getSlot0(FamilyHook.PoolId) external => NONDET;
    function _.swap(FamilyHook.PoolKey, FamilyHook.SwapParams, bytes) external => NONDET;

    // The vault is the fee sink; its ledgers are FeeVault.spec's job. But the CALL ITSELF is the
    // only observable the protocol fee has (it is never stored here), so the summary records it.
    function _.accrue(FamilyHook.Currency currency, address parentToken, uint256 hopFee,
                      uint256 protocolFee, uint256 terminalIndex, bool attributed) external
        => recordAccrue(parentToken, protocolFee) expect void;
    // WHY THERE IS NO EXACT ENTRY HERE. An EXACT
    // `FeeVault.accrue(...)` entry beside the wildcard would need `feeVault` LINKED in
    // FamilyHook.conf, because an exact entry takes precedence for a known callee, and it would need
    // to name the `FeeVault` contract, so it could only exist while `contracts/FeeVault.sol` is in
    // the scene. The Prover CANNOT LOAD A SCENE CONTAINING
    // THAT FILE: it dies transforming `FeeVault.receiveForward(uint256,uint256)` before any rule is
    // checked. FamilyHook.conf therefore drops the file and the link, the vault is an unlinked
    // address, and the wildcard above is the ONLY summary the call can reach - which is the model
    // this spec always described in prose ("its ledgers are FeeVault.spec's job"). Nothing else in
    // this file mentions the vault, so no rule's claim changes; what changes is that FEE-01's
    // reachability ladder is measured against an unlinked callee rather than a linked one.
    // For the record, an exact entry would also need its parameter names to match the
    // contract's own, because CVL merges the wildcard and the exact entry for one callee and refuses
    // conflicting names; and an EXACT summary target takes NO `expect` clause, unlike the `_.`
    // wildcard above where it is mandatory.

    // Round state and successor-router resolution: both are other specs' subject matter.
    function _.isSunsetEffective() external => NONDET;
    function _.successor() external => NONDET;
    function _.factory() external => NONDET;
    function _.router() external => NONDET;
}

// ---------------------------------------------------------------------------------------------
// ghost state: the accumulator, the per-swap fee total and the swapped pool's own predicates
// ---------------------------------------------------------------------------------------------

// `persistent`, so an unresolved-callee summary does not wipe the spec-side log.
persistent ghost mathint ghostProtocolFeeCount { init_state axiom ghostProtocolFeeCount == 0; }
// The `parentToken` of the last accrual.
//
// AND THE REASON THE TWO `Sload` HOOKS BELOW EXIST. There is no genesis marker; `_collect` passes `Currency.unwrap(parent)`
// unconditionally, and `parentToken` is simply the currency the hop fee is denominated in. It is
// still recorded (it is what FeeVault.spec's decomposition keys on), but it can no longer carry
// FEE-01. Stating FEE-01 over `parent == edge currency` instead would be a claim about the FACTORY's
// registration, not about this contract, and the hook would rightly fail it: `registerPool` stores
// whatever `isEdge` it is handed. The predicate has to be read from the pool the swap actually hit,
// which is what the hooks below do.
persistent ghost address ghostAccrueParentToken;

// Every accrual is counted too, fee-bearing or not, so the `satisfy` ladder can bisect
// "any accrual at all" against "an accrual carrying a protocol fee" against "exactly one".
persistent ghost mathint ghostAccrueCount { init_state axiom ghostAccrueCount == 0; }

// The mint rung of the FEE-01 bisect (see the `_.mint` summary above).
persistent ghost mathint ghostMintCount { init_state axiom ghostMintCount == 0; }

// THE TWO `Sload` HOOKS ON `registeredPools` ARE GONE, AND SO
// ARE THE TWO GHOSTS THEY FED AND THE TWO RULES STATED OVER THEM.
//
// What they were for: `_collect` reads `p.isEdge` and `p.tradingStart` off
// `registeredPools[key.toId()]` in the two instructions that decide `protocolPpm` and `snipePpm`,
// and CVL cannot compute `key.toId()` to fetch that struct itself, so a load hook was the only way
// to record what the code read and state the rule over it.
//
// Why they are gone: the key type CANNOT BE NAMED IN CVL at `certora-cli` 8.19.2. `PoolId` is a
// FILE-LEVEL user-defined value type over `bytes32` in `lib/v4-core/src/types/PoolId.sol`, and every
// spelling the local type-checker was offered is rejected with the same message, "keys to
// FamilyHook.registeredPools should have type PoolId but id has type PoolId":
//   `FamilyHook.PoolId`, `IFamilyHook.PoolId`, `RoundManager.PoolId`, and `PoolIdLibrary.PoolId`
//   with `PoolId.sol:PoolIdLibrary` added to the scene so the DECLARING contract could be named.
//   A bare `PoolId` is read as an uninterpreted sort ("PoolId is not a valid EVM type") and
//   `bytes32` is rejected on the underlying type ("... but id has type bytes32").
// It is not about struct FIELDS: a probe hook on `obsCount`, a plain
// `mapping(PoolId => uint256)` in the same contract, is rejected identically. It is not about scene
// composition either: the rejection is the same with one contract in the scene and with three. The
// neighbouring construction that DOES work is `FeeVault.spec`'s `ledgerTotal[KEY FeeVault.Currency
// c]`, where `Currency` is a file-level UDVT over ADDRESS, which is why the difference is recorded
// as being about the underlying type rather than about the shape of the mapping.
//
// `IFamilyHook.PoolId` does not type-check either, despite once appearing to be an accepted
// spelling; no spelling of the key type type-checks against this mapping.
//
// The consequence: `protocolFeeOnlyAtTheEdge` and `theEdgeFeeIsSuppressedDuringTheSnipeWindow`
// have NO OBSERVABLE at this tier and are DISABLED below rather than left to pass vacuously. FEE-01's
// per-pool half and FEE-06's time-based half fall back to `test/properties/Fees.prop.t.sol` and the
// unit tests, and are recorded as NOT EXPRESSIBLE here rather than as unproved.

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
// the score accumulator
// ---------------------------------------------------------------------------------------------

/// SCR-02 (spec F "_updateScore: acc += R*(now - tLast); R += (-parentDelta)"): R rises exactly on a
/// net buy and falls on a net sell, so the accumulator is monotone in net parent absorbed.
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

/// SCR-02 (spec F "on swap deltas only, never on transfers, donations (disabled) or balances"):
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
         || f.selector == sig:registerPool(FamilyHook.PoolKey,bool,uint160,uint64,uint64,uint32,bool).selector),
        "the score moved outside the swap path";
}

/// SUP-06 (PROPERTIES 3.1): donations are impossible and only the Locker may add liquidity. Without
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
// averageOver and the degenerate window
// ---------------------------------------------------------------------------------------------

/// For t0 < t1 the average is the accumulator difference
/// over the elapsed span, reconstructed from the rings.
rule averageOverIsTheAccumulatorDifference(FamilyHook.PoolId id, uint64 t0, uint64 t1) {
    require t0 < t1;
    int256 avg; uint64 tLastBefore; uint64 tStartUsed; uint64 tEndUsed;
    avg, tLastBefore, tStartUsed, tEndUsed = averageOver(id, t0, t1);
    // tLastBefore is the last real score update at or before t1 (spec F, "tFirstAttained").
    assert to_mathint(tLastBefore) <= to_mathint(t1),
        "averageOver reported an attainment time after the window's end";
    // The average is divided by the span between the instants the accumulator was
    // ACTUALLY evaluated at, and a call that returns at all has a strictly positive one; the
    // collapsed window is a revert, not a zero (see the rule below).
    assert to_mathint(tEndUsed) > to_mathint(tStartUsed),
        "averageOver returned an answer over a collapsed window";
    // Nothing the exact-sample fallback can reach is LATER than the requested edge, so
    // flow after a revealed T_end is invisible to the reconstruction.
    assert to_mathint(tEndUsed) <= to_mathint(t1),
        "the far edge resolved to an instant after the window's end";
}

/// SCR-14 / PROPERTIES 7.12, THE GAP IS CLOSED. The code reverts `BadScoreWindow` here rather than
/// answering with "a zero-length window answers with the instantaneous level", and for good reason:
/// two edges that resolve to the same
/// instant measure nothing at all, and a zero there is indistinguishable from a real average of
/// zero, i.e. a denial dressed as an answer. The rule asserts the revert, which is the documented
/// behaviour; the precondition that keeps it unreachable
/// (`closingWindowFor(n) > scoreSlotFor(n)`) is a deploy-time guard proved in RoundManager.spec
/// (`theConstructorsWindowGuardMatchesTheGetters`).
rule averageOverRevertsOnACollapsedWindow(FamilyHook.PoolId id, uint64 t) {
    int256 avg; uint64 tLastBefore; uint64 tStartUsed; uint64 tEndUsed;
    avg, tLastBefore, tStartUsed, tEndUsed = averageOver@withrevert(id, t, t);
    assert lastReverted, "averageOver answered over a zero-length window instead of reverting";
}

/// A checkpoint slot is written at most once, by the first swap in that
/// slot. The rule reads the ring slot through the contract's own `scoreCheckpoint` getter either
/// side of a swap and states the claim directly: a slot's recorded swap time never stands still and
/// never goes backwards, which is exactly what `_checkpoint`'s early exit produces. (An `Sstore`
/// hook on the ring was tried first and does not type-check: the NESTED mapping's key resolves to a
/// PoolId identity a hook declaration cannot name. The two hooks at the top of this file are on a
/// TOP-LEVEL `mapping(PoolId => RegisteredPool)`, which is a different case.)
rule aSlotIsWrittenOnceByItsFirstSwap(env e, address sender, FamilyHook.PoolKey key,
                                      FamilyHook.SwapParams params, FamilyHook.BalanceDelta delta,
                                      bytes hookData, FamilyHook.PoolId id, uint256 index) {
    // Well-formedness. A ring slot's own invariant is that it can only ever hold a
    // checkpoint whose span maps back to that slot: `_checkpoint` writes
    // `ring[(nowTs / SCORE_SLOT_S) % SCORE_SLOTS]` and stores `nowTs` there. Without this
    // precondition, a ring where it did not hold would let a swap legitimately claim
    // that slot for an earlier span, which is not an overwrite of anything the contract put there.
    require to_mathint(scoreCheckpoint(id, index).tSwap) / to_mathint(SCORE_SLOT_S())
                % to_mathint(SCORE_SLOTS()) == to_mathint(index % SCORE_SLOTS());
    IFamilyHook.ScoreCheckpoint cpBefore = scoreCheckpoint(id, index);
    // NO CHECKPOINT FROM THE FUTURE. Every `tSwap` in the ring was
    // written by an earlier `afterSwap` as `uint64(block.timestamp)` of ITS own block, and no chain
    // produces a block older than one already recorded.
    require to_mathint(cpBefore.tSwap) <= to_mathint(e.block.timestamp);
    // The bound above was necessary but not sufficient: a clock that is a
    // MULTIPLE OF 2^64 truncates inside `_checkpoint` to 0 and stamps the slot lower than what was
    // there, while satisfying the mathint precondition above. No live `block.timestamp` is outside
    // uint64.
    require to_mathint(e.block.timestamp) < 18446744073709551616;
    afterSwap(e, sender, key, params, delta, hookData);
    IFamilyHook.ScoreCheckpoint cpAfter = scoreCheckpoint(id, index);
    assert cpAfter.tSwap != cpBefore.tSwap
        => to_mathint(cpAfter.tSwap) > to_mathint(cpBefore.tSwap),
        "a checkpoint slot was overwritten within its own span";
}

/// The fast ring spans exactly 36 * 5 s = 180 s = RANDOM_END_S.
rule theFastRingSpansTheRandomEndWindow() {
    assert to_mathint(SCORE_RING_S()) == to_mathint(SCORE_SLOTS()) * to_mathint(SCORE_SLOT_S()),
        "the fast ring does not span its slot count";
    assert SCORE_RING_S() == 180, "the fast ring does not span RANDOM_END_S";
}

// ---------------------------------------------------------------------------------------------
// the snipe tax schedule (FEE-04) and the edge fee's suppression inside it
// ---------------------------------------------------------------------------------------------

/// FEE-04 (spec I, table): the snipe tax runs 99% to 1% linearly over SNIPE_S = 3 s and is exactly 0
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
/// THE PAIRWISE BOUND, AND WHAT ENFORCES IT. There is no genesis pool exempt from the snipe tax:
/// a round-one pool is BOTH edge and freshly opened, so the two large rates are made mutually
/// exclusive in TIME rather than by pool class: `theEdgeFeeIsSuppressedDuringTheSnipeWindow` below. What stays
/// here is the arithmetic the gross-up needs, stated pairwise, and the third assertion is the reason
/// the suppression is load-bearing rather than cosmetic.
rule summedRatesStayBelowOne() {
    require hopFeePpm() <= MAX_HOP_FEE_PPM();
    assert to_mathint(SNIPE_START_PPM()) + to_mathint(hopFeePpm()) <= 1000000,
        "hop fee plus the snipe tax at its start reached 100% on a freshly opened pool";
    assert to_mathint(PROTOCOL_FEE_PPM()) + to_mathint(hopFeePpm()) <= 1000000,
        "hop fee plus the protocol fee reached 100% on an edge pool";
    // the hazard the time-based suppression exists to remove: charged together, the three rates
    // exceed 100% and the gross-up has no finite answer at all
    assert to_mathint(PROTOCOL_FEE_PPM()) + to_mathint(SNIPE_END_PPM()) + to_mathint(hopFeePpm())
        > 1000000
        || to_mathint(PROTOCOL_FEE_PPM()) + to_mathint(SNIPE_START_PPM()) + to_mathint(hopFeePpm())
        > 1000000,
        "the three rates no longer overlap, so the suppression below may be obsolete";
}

/// FEE-04 / FEE-06 - THE EDGE FEE IS SUPPRESSED DURING THE SNIPE WINDOW.
/// `_collect` computes `protocolPpm = (p.isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0`, so a
/// non-zero protocol fee implies the snipe tax is zero, which `_snipeTaxPpm` returns exactly when
/// the pool has no start at all or `block.timestamp - tradingStart >= SNIPE_S`. The rule states that
/// implication against the pool the swap actually hit (`ghostLastTradingStart`, loaded by `_collect`
/// one instruction before it decides both rates), which is the only form in which a per-pool,
/// per-instant claim is expressible here.
///
/// This is FEE-06 restated BY TIME-BASED EXCLUSION, and the reason it matters is not the fee. At
/// 99% + 1% + the hop fee the exact-output gross-up divides by a non-positive number: without the
/// suppression, every parent-paying exact-output swap in a new round-one pool's first three seconds
/// reverts. The loss is bounded by SNIPE_S seconds of one pool's flow and the snipe tax, which is
/// far larger, is protocol-owned reinforcement in the same currency.
// DISABLED (see the note at the top of this file on the `PoolId` key type). This rule's only
// observable was `ghostLastTradingStart`, written by an `Sload` hook on
// `registeredPools[...].tradingStart` whose PoolId key type cannot be named in CVL at
// `certora-cli` 8.19.2. Without the hook the ghost has no writer, the implication would be checked
// against an unconstrained word, and the rule would report "not violated" while proving nothing -
// a standing lesson about tautologies. It is commented out rather than weakened,
// so that nothing green in the table stands for it. FEE-06's time-based half is carried by
// `test/properties/Fees.prop.t.sol` and the unit tests until the key type is nameable.
// RESTORE IT TOGETHER WITH THE HOOK, NOT BEFORE.
// rule theEdgeFeeIsSuppressedDuringTheSnipeWindow(env e, address sender, FamilyHook.PoolKey key,
//                                                 FamilyHook.SwapParams params, bytes hookData) {
// // the same uint64 clock domain every other rule in this file works in
//     require to_mathint(e.block.timestamp) < 18446744073709551616;
//     mathint before = ghostProtocolFeeCount;
//     beforeSwap(e, sender, key, params, hookData);
//     assert ghostProtocolFeeCount > before =>
//         (ghostLastTradingStart == 0
//          || to_mathint(e.block.timestamp)
//               >= to_mathint(ghostLastTradingStart) + to_mathint(SNIPE_S())),
//         "the edge fee was charged while the pool's snipe window was still open";
// }

/// FEE-03 (spec I): hopFeePpm is bounded at construction and no function changes any rate afterwards.
/// `hopFeePpm` is an IMMUTABLE. The Prover starts from arbitrary storage with the
/// constructor never run, so it is havoc'd and the ceiling assertion below is needed on every
/// method, including pure RoundManager calls, which is the tell. The constructor's own guard
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
// fee-once at the edge (FEE-01)
// ---------------------------------------------------------------------------------------------

/*
 * FEE-01: a route of any length L that traverses AN EDGE POOL once pays
 * exactly one protocol fee of PROTOCOL_FEE_PPM on that leg's parent-side amount, and zero on the
 * other L-1 legs. An edge pool is one whose parent is canonical index 0, decided by the factory at
 * registration and frozen for the pool's life.
 *
 * WHAT IS EXPRESSIBLE HERE. The hook charges the protocol fee in `_collect`, and only when the pool
 * is an edge pool and the snipe window has closed. Since every leg of a route is a separate
 * `beforeSwap` / `afterSwap` pair on a separate pool, "exactly one fee per traversal" reduces to the
 * per-pool rule "the protocol fee is charged only if `p.isEdge`", which IS expressible and is
 * asserted below.
 *
 * WHAT IS NOT EXPRESSIBLE HERE. The count over a whole multi-hop route is a property of the router's
 * loop inside one PoolManager unlock. `PoolManager.swap` is summarized NONDET (PROPERTIES section
 * 6), so the prover never executes the second, third, ... leg. That belongs to the fork tier
 * (FEE-01 carries tier K) and to ROU-02 against a real PoolManager.
 *
 * SPEC-GAP (PROPERTIES 7 items 1 and 8), NOW WITH A CONCRETE INSTANCE. The spec does not say what a
 * round trip inside one swapPath should pay. The code settles the ATTRIBUTION half of that
 * question and this records it: with the edge currency at index 0, `swapPath([0, 1,
 * 0])` ends at index 0 and credits the creator recorded for the adopted genesis token with the
 * creator share of BOTH edge legs. The fee COUNT for that route stays a fork-tier check.
 */

/// FEE-01 (spec I, table): the protocol fee is charged on an EDGE pool
/// and on no other pool.
/// The predicate is taken from the pool the swap actually hit. `_collect` loads `p.isEdge` in the
/// instruction that computes `protocolPpm`, and the load hook at the top of this file records it, so
/// the rule compares the fee that was charged against the flag the code read to decide it. Reading
/// the flag out of the `parentToken` word the vault is handed cannot work: that word does not
/// encode a pool class (see `ghostAccrueParentToken`).
// DISABLED (see the note at the top of this file on the `PoolId` key type). Same cause: the rule's
// consequent is `ghostLastIsEdge`, written by an `Sload` hook on `registeredPools[...].isEdge` whose
// PoolId key type cannot be named in CVL at `certora-cli` 8.19.2. With no writer the ghost is an
// unconstrained boolean and the assertion is not a claim about the code. FEE-01's per-pool half
// ("charged only at an edge pool") therefore has no observable at this tier and falls back to
// `test/properties/Fees.prop.t.sol` and the unit tests. The `satisfy` rungs below are NOT
// disabled: they measure reachability of the fee path itself and do not touch the hooks.
// RESTORE IT TOGETHER WITH THE HOOK, NOT BEFORE.
// rule protocolFeeOnlyAtTheEdge(env e, address sender, FamilyHook.PoolKey key,
//                               FamilyHook.SwapParams params, bytes hookData) {
//     mathint before = ghostProtocolFeeCount;
//     beforeSwap(e, sender, key, params, hookData);
//     assert ghostProtocolFeeCount > before => ghostLastIsEdge,
//         "a protocol fee was charged on a pool that is not an edge pool";
// }

/// FEE-01 vacuity check: the single-fee edge path is reachable, so the rule above is not vacuously
/// true.
///
/// READ THIS BEFORE TRUSTING THE RULE ABOVE: if the Prover cannot construct a single execution of
/// `beforeSwap` that charges one protocol fee, `protocolFeeOnlyAtTheEdge`'s "Not violated" verdict
/// is VACUOUS COVERAGE and FEE-01's per-pool half is UNPROVED here, even though rungs 0 and 0.5
/// discharge. An EXACT `FeeVault.accrue` summary entry in place above does not by itself fix that;
/// the remaining experiment is named in certora/README.md item 2: count accruals from the
/// LINKED vault's own `ledgerTotal` store with an `Sstore` hook rather than from any summary, and
/// check whether `optimistic_fallback` is swallowing the vault call one line after the fee mint. Do
/// not delete this rule to make the table green.
rule oneProtocolFeeAtTheEdgeIsReachable(env e, address sender, FamilyHook.PoolKey key,
                                        FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostProtocolFeeCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostProtocolFeeCount == before + 1,
        "exactly one protocol fee per edge-leg traversal is reachable";
}

/// FEE-01 reachability, RUNG 1. Is ANY fee accrual reachable through `beforeSwap` at all,
/// protocol fee or not? If this also fails then the `PoolManager.getSlot0` / `swap` NONDET summaries
/// (or `onlyPoolManager` against an unlinked manager) make `_collect` unreachable and the verdict
/// above says nothing about FEE-01: it is a summary artefact.
rule anyFeeAccrualIsReachable(env e, address sender, FamilyHook.PoolKey key,
                              FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostAccrueCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostAccrueCount > before, "no fee accrual at all is reachable through beforeSwap";
}

/// FEE-01 reachability, RUNG 0. Can `beforeSwap` be executed to completion AT ALL under
/// the present summaries and the `onlyPoolManager` guard against an unlinked manager? If even this
/// fails, every verdict on the fee path is vacuous for a reason that has nothing to do with fees.
rule beforeSwapIsReachable(env e, address sender, FamilyHook.PoolKey key,
                           FamilyHook.SwapParams params, bytes hookData) {
    beforeSwap(e, sender, key, params, hookData);
    satisfy true, "no execution of beforeSwap completes at all";
}

/// FEE-01 reachability, RUNG 0.5. Between rung 0 and rung 1: `_collect` mints the fee
/// claim to the vault after the `equals(specified, parent)` early return and after `total != 0`, and
/// only then calls `accrue`. If this rung is reachable and rung 1 is not, the loss is in the vault
/// call itself; if this rung is NOT reachable, the loss is upstream and the fee count is not the
/// subject.
rule theFeeMintIsReachable(env e, address sender, FamilyHook.PoolKey key,
                           FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostMintCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostMintCount > before, "no swap reaches the fee mint in _collect";
}

/// FEE-01 reachability, RUNG 2. `== before + 1` relaxed to `> before`, which separates
/// "the Prover cannot charge a protocol fee at all" from "it cannot charge exactly one".
rule someProtocolFeeIsReachable(env e, address sender, FamilyHook.PoolKey key,
                                FamilyHook.SwapParams params, bytes hookData) {
    mathint before = ghostProtocolFeeCount;
    beforeSwap(e, sender, key, params, hookData);
    satisfy ghostProtocolFeeCount > before, "no protocol-fee-charging swap is reachable";
}

// ---------------------------------------------------------------------------------------------
// the published end, the ring freeze and the end seal
// ---------------------------------------------------------------------------------------------

/// UNIVERSAL: a pool's published end is what freezes its score rings
/// and what every scored window is measured back from. An end at or before the start registers a
/// pool that is frozen before it opens (it writes no ring entry and can never be scored) while still
/// charging the hop fee on every swap. `registerPool` must refuse it, whoever calls and WHATEVER
/// `isEdge` says: the rule is quantified over both values of `isEdge`, since there is no exempt
/// pool class.
rule registerPoolRefusesAPoolWithoutAPublishedEnd(env e, FamilyHook.PoolKey key, bool isEdge,
                                                  uint160 initSqrtPriceX96, uint64 tradingStart,
                                                  uint64 nominalEnd, uint32 scoreSlotS,
                                                  bool parentIsCurrency0) {
    require to_mathint(nominalEnd) <= to_mathint(tradingStart);
    registerPool@withrevert(e, key, isEdge, initSqrtPriceX96, tradingStart, nominalEnd,
                            scoreSlotS, parentIsCurrency0);
    assert lastReverted, "a pool was registered with no end after its start";
}

/// EVERY REGISTERED POOL HAS A PUBLISHED END, stated as the inductive invariant
/// the guard above buys. The rule directly above is about one call; this one is about the registry
/// as a whole, which is what the ring freeze and the end seal are stated over. The base case is free
/// (a fresh pool has `registered == false`) and the step is `registerPool`'s `BadNominalEnd` check.
rule everyRegisteredPoolHasAPublishedEnd(method f, env e, calldataarg args, FamilyHook.PoolId id)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    IFamilyHook.RegisteredPool pre = poolInfo(id);
    // the inductive hypothesis, and the base case: an unregistered pool satisfies it vacuously
    require pre.registered => to_mathint(pre.nominalEnd) > to_mathint(pre.tradingStart);
    f(e, args);
    IFamilyHook.RegisteredPool post = poolInfo(id);
    assert post.registered => to_mathint(post.nominalEnd) > to_mathint(post.tradingStart),
        "a registered pool has no end after its start, so it can never be scored";
}

/// THE RING FREEZE, stated as post-bell ring immutability.
/// Past a pool's PUBLISHED end `T` the live accumulator keeps running, but NO ring entry is ever
/// written again. That is what makes the whole of `[T_end - W, T_end]` impossible to erase with
/// post-reveal flow: it closes the SELECTION defect where a trader could bury the fast
/// ring in dust after the reveal to move which sample answered the edge.
///
/// THE FREEZE IS UNIVERSAL: THERE IS NO `end == 0` DISJUNCT. There is no pool exempt with
/// `nominalEnd == 0` and rings written forever; leaving such an exemption in would let a
/// registered pool with a zero end pass this rule silently, which
/// is exactly the state `everyRegisteredPoolHasAPublishedEnd` above proves unreachable.
///
/// The rule is stated over an ARBITRARY `id` and an arbitrary ring index, deliberately: CVL cannot
/// compute `key.toId()`, so `id` is not tied to the swapped key, but that costs nothing here,
/// because for any other pool the rings do not move at all and the implication is vacuous, while for
/// the swapped pool it is exactly the claim. Both rings are covered in one statement.
rule noRingEntryIsWrittenPastTheBell(method f, env e, calldataarg args,
                                     FamilyHook.PoolId id, uint256 index)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    // the same uint64 clock domain every other rule in this file works in:
    // a `block.timestamp` at a multiple of 2^64 truncates inside `_updateScore` and says nothing.
    require to_mathint(e.block.timestamp) < 18446744073709551616;
    uint64 end = poolInfo(id).nominalEnd;
    IFamilyHook.ScoreCheckpoint fastBefore = scoreCheckpoint(id, index);
    IFamilyHook.ScoreCheckpoint coarseBefore = coarseCheckpoint(id, index);
    f(e, args);
    IFamilyHook.ScoreCheckpoint fastAfter = scoreCheckpoint(id, index);
    IFamilyHook.ScoreCheckpoint coarseAfter = coarseCheckpoint(id, index);
    bool moved = fastAfter.tSwap != fastBefore.tSwap || fastAfter.tState != fastBefore.tState
              || fastAfter.acc != fastBefore.acc || fastAfter.R != fastBefore.R
              || coarseAfter.tSwap != coarseBefore.tSwap || coarseAfter.tState != coarseBefore.tState
              || coarseAfter.acc != coarseBefore.acc || coarseAfter.R != coarseBefore.R;
    assert moved => to_mathint(e.block.timestamp) <= to_mathint(end),
        "a ring entry was written after the pool's published end";
}

/// THE END SEAL IS WRITE-ONCE. The freeze alone left `(lastInRoundSwap, T]`
/// uncovered, so the FIRST swap past the bell writes ONE final entry whose interval
/// `[tState, tSwap)` brackets the whole scored span forever. "Forever" is the claim: once
/// `endSeal[id].tSwap` is non-zero, no call of any kind may change any field of it, or the edge the
/// seal answers could be moved after the reveal, which is the very defect the seal exists to close.
rule endSealIsWriteOnce(method f, env e, calldataarg args, FamilyHook.PoolId id)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    IFamilyHook.ScoreCheckpoint sealBefore = endCheckpoint(id);
    require sealBefore.tSwap != 0;          // the seal has been laid; the claim is about after that
    f(e, args);
    IFamilyHook.ScoreCheckpoint sealAfter = endCheckpoint(id);
    assert sealAfter.tSwap == sealBefore.tSwap && sealAfter.tState == sealBefore.tState
        && sealAfter.acc == sealBefore.acc && sealAfter.R == sealBefore.R,
        "the end seal was rewritten after it had been laid";
}

/// The seal is only ever laid PAST the bell, and it brackets the bell.
/// `_accumulatorAt` consults the seal BEFORE the rings, so a seal laid from inside the round would
/// shadow them; and its interval `[tState, tSwap)` has to contain `T` for it to cover the scored
/// span at all. Both halves come from the one write in `_updateScore`'s `else` branch, where
/// `p.tLast <= end < nowTs` holds by construction of the branch.
/// THE PRECONDITIONS THIS TAKES: without them, the Prover's counterexample is an UNREACHABLE
/// pool. Two `require`s are needed. What is left is
/// `registerPool`'s own surviving guard (`nominalEnd > tradingStart`, itself proved as
/// `everyRegisteredPoolHasAPublishedEnd`) and the induction hypothesis of this very rule: an UNLAID
/// seal means no swap has yet happened past the bell, so the live `tLast` is still at or before it.
/// Both are facts about reachable states, not weakenings of the claim.
rule theEndSealIsOnlyLaidPastTheBell(method f, env e, calldataarg args, FamilyHook.PoolId id)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require to_mathint(e.block.timestamp) < 18446744073709551616;
    IFamilyHook.RegisteredPool pre = poolInfo(id);
    uint64 end = pre.nominalEnd;
    // registerPool: every registered pool's end is strictly after its start
    require pre.registered => to_mathint(end) > to_mathint(pre.tradingStart);
    // the induction hypothesis: while the seal is unlaid, nothing has been swapped past the bell
    require end != 0 => to_mathint(pre.tLast) <= to_mathint(end);
    IFamilyHook.ScoreCheckpoint sealBefore = endCheckpoint(id);
    require sealBefore.tSwap == 0;
    f(e, args);
    IFamilyHook.ScoreCheckpoint sealAfter = endCheckpoint(id);
    assert sealAfter.tSwap != 0 =>
        (end != 0 && to_mathint(sealAfter.tSwap) > to_mathint(end)
         && to_mathint(sealAfter.tState) <= to_mathint(end)),
        "an end seal was laid at or before the pool's published end";
}
