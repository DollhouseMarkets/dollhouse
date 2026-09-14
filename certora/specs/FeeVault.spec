/*
 * FeeVault.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §I (fee semantics), §J (fee recipients, the keeper
 * model, the drawdown token bucket, the sunset handover of the ETH edge) and docs/spec/PROPERTIES.md
 * §3.2 / §3.8 / §3.9 / §6. Written from the specification only.
 *
 * Ledgers named by the spec (§J, FEE-10): devBalance, creatorBalance[token], creatorAccrued[addr],
 * the three Fenwick coefficient trees (ancestorTree), reinforcementEth[j], reinforcementBalance[parent],
 * genesisBidEarmark, pendingForward[attribution]. ledgerTotal[c] is the vault's own running sum and,
 * per the spec, counts pendingForward too.
 */

using FeeVault as vault;

// ---------------------------------------------------------------------------------------------
// methods
// ---------------------------------------------------------------------------------------------
methods {
    // --- ledger getters (spec J) ---
    function devBalance() external returns (uint256) envfree;
    function creatorBalance(address) external returns (uint256) envfree;
    function creatorAccrued(address) external returns (uint256) envfree;
    function ancestorClaimed(uint256) external returns (uint256) envfree;
    function reinforcementEth(uint256) external returns (uint256) envfree;
    function reinforcementBalance(address) external returns (uint256) envfree;
    function genesisBidEarmark() external returns (uint256) envfree;
    function pendingForward(uint256) external returns (uint256) envfree;
    function pendingForwardTotal() external returns (uint256) envfree;
    function deployerCredit() external returns (uint256) envfree;
    function forwardingFailed() external returns (bool) envfree;
    function successorVault() external returns (address) envfree;
    function developer() external returns (address) envfree;
    function bidDeployer() external returns (address) envfree;

    // --- split constants (spec J; FEE-09) ---
    function DEV_BPS() external returns (uint256) envfree;
    function CREATOR_BPS() external returns (uint256) envfree;
    function ANCESTOR_BPS() external returns (uint256) envfree;
    function REINFORCE_BPS() external returns (uint256) envfree;
    function DAILY_DRAW_BPS() external returns (uint256) envfree;
    function DRAW_WINDOW() external returns (uint64) envfree;
    function UNATTRIBUTED() external returns (uint256) envfree;
    function CANDIDATE_ATTRIBUTION() external returns (uint256) envfree;

    // --- entrypoints ---
    function accrue(FeeVault.Currency, address, uint256, uint256, uint256, bool) external;
    function accrueForwarded(uint256, uint256, uint256) external;
    function receiveForward(uint256) external;
    function flushForward(uint256, uint256) external returns (uint256);
    function depositGenesisBidEarmark() external;
    function claimDev(address) external returns (uint256);
    function claimCreator(address, address) external returns (uint256);
    function claimCreatorAccrued(address) external returns (uint256);
    function transferCreatorRecipient(address, address) external;
    function consumeAncestorClaim(uint256, uint256) external returns (uint256);
    function consumeReinforcement(address, uint256) external returns (uint256);
    function consumeGenesisEarmark(uint256) external returns (uint256);
    function payKeeper(address, uint256) external;
    function redeem(FeeVault.Currency) external;

    // --- views used by rules ---
    function holdings(FeeVault.Currency) external returns (uint256);
    function claimableEth(uint256) external returns (uint256);
    function claimableAncestor(uint256) external returns (uint256);
    function drawableEth(uint256) external returns (uint256);
    function ledgerTotal(FeeVault.Currency) external returns (uint256);

    // --- summaries -------------------------------------------------------------------------
    // The v4 singleton is not part of this proof. PROPERTIES section 6, "Summaries required": every
    // PoolManager entrypoint is summarized. mint/burn/take/settle/sync/unlock move balances the
    // solvency invariant measures through `holdings`, which is itself summarized below, so a
    // NONDET of the manager cannot weaken the ledger-side conservation claims.
    function _.mint(address, uint256, uint256) external => NONDET;
    function _.burn(address, uint256, uint256) external => NONDET;
    function _.take(FeeVault.Currency, address, uint256) external => NONDET;
    function _.settle() external => NONDET;
    function _.sync(FeeVault.Currency) external => NONDET;
    function _.unlock(bytes) external => NONDET;
    // REVIEW-1C (from the review-1b run, not yet re-run). `holdings(c)` = real balance + unredeemed
    // ERC-6909 claims, and the claim term is this `balanceOf`. Under a bare NONDET two reads of
    // `holdings` IN THE SAME STATE come back different, which is not an over-approximation of the
    // singleton - it is false, and it is what left `solvency` violated on its transient-storage step
    // and on all 20 methods (review-1b trace: two `FeeVault.holdings()` calls either side of
    // "reset transient storage", each resolving `sighash 0xfdd58e` to a fresh value). The claim
    // balance stays fully unconstrained; it is pinned so that it is merely CONSISTENT.
    function _.balanceOf(address holder, uint256 tokenId) external
        => cvlClaimBalance(holder, tokenId) expect uint256;
    // REVIEW-2: the OTHER half of `holdings`. For a non-ETH currency the real-balance term is
    // `IERC20(token).balanceOf(address(this))` - sighash 0x70a08231, the ONE-argument ERC-20
    // overload, which had no summary at all. Every `solvency` counterexample in the review-2 run
    // names it: "FeeVault.holdings(Currency) -> [?].[sighash=0x70a08231] : AUTO havoc", i.e. the two
    // `holdings()` reads either side of a step returned different numbers with nothing in between
    // changing the balance. That is the same mechanism-4 defect as the ERC-6909 term above, on the
    // overload review-1c missed. Unconstrained value, consistent read.
    function _.balanceOf(address holder) external => cvlTokenBalance(holder) expect uint256;
    // REVIEW-2: `forwardProtocolFee` hands the claim over with `poolManager.transfer` (the ERC-6909
    // three-argument overload, sighash 0x095bcdb6), which was NOT in this block's list of summarized
    // PoolManager entrypoints - so it fell through to AUTO and, being an unresolved call on an
    // unlinked address, "havocs all contracts except FeeVault" on the accrual path. The spec's own
    // stated policy (PROPERTIES section 6) is that EVERY PoolManager entrypoint is summarized; this
    // completes the list.
    function _.transfer(address, uint256, uint256) external => NONDET;
    function _.protocolFeesAccrued(FeeVault.Currency) external => NONDET;
    // REVIEW-2 (docs/attack-log.md, REN-01). `claimDev`, `claimCreator` and `claimCreatorAccrued`
    // now carry `notInsideUnlock`, which reads v4-core's transient lock slot off the PoolManager
    // with a single `exttload` (contracts/libraries/V4UnlockGuard.sol). The manager is deliberately
    // UNLINKED, so without a summary that read is a fresh per-call havoc - a guard that answers
    // differently on two calls in the same transaction is not an over-approximation of a transient
    // slot, it is false, and it is precisely the mechanism-4 defect review-1b removed everywhere
    // else. Unconstrained value, consistent read.
    function _.exttload(bytes32) external => cvlUnlockSlot() expect bytes32;

    // The RoundManager is read for attribution, sunset state and creator identity. Its own state
    // machine is proved in RoundManager.spec; here every read is NONDET so no rule below can be
    // proved true only because a particular round state was assumed.
    // REVIEW-1C: same treatment, same reason. `claimableEth(j)` / `drawableEth(j)` read
    // `headIndex()` through the RoundManager twice inside one bucket evaluation, and a per-call
    // havoc made `bucketNeverExceedsCap` unprovable on `accrue`. Values unconstrained, reads
    // consistent. `isSunset()` keeps its NONDET: nothing reads it twice, and the post-sunset rule is
    // deliberately stated over the booking ghosts (note 2 in certora/PROPERTY_MAP.md).
    function _.isSunset() external => NONDET;
    function _.canonical(uint256 i) external => cvlRmCanonical(i) expect address;
    function _.headIndex() external => cvlRmHeadIndex() expect uint256;
    function _.creatorOf(address t) external => cvlRmCreatorOf(t) expect address;
    function _.indexOf(address t) external => cvlRmIndexOf(t) expect uint256;
    function _.phase(uint256) external => NONDET;

    // A successor vault is arbitrary third-party code (it is a later, unknown deployment), and the
    // spec's claim is precisely that nothing a successor does can break this vault's solvency or
    // its queue accounting. Review-1b modelled that as HAVOC_ALL and then found the model, not the
    // code, was the problem: HAVOC_ALL also lets the callee rewrite THIS vault's own storage, which
    // no contract can do, and under that over-approximation no storage-reading invariant can ever
    // be inductive. Seven FeeVault sub-goals failed for that reason alone.
    //
    // REVIEW-2: narrowed to HAVOC_ECF, which was explicitly GATED on closing F-4 and F-4 is closed
    // (docs/attack-log.md, review-2 fixes): `accrue` is `nonReentrant`, `flushForward` already was,
    // `forwardProtocolFee` is `msg.sender == address(this)` only, and the two entrypoints a
    // successor could aim at - `accrueForwarded` and `receiveForward` - both require
    // `_isPriorVault(msg.sender)`, which a SUCCESSOR of this vault can never satisfy. So "the
    // callee does not re-enter currentContract" is a property of this contract's own guards, not an
    // assumption about the successor. Everything outside this contract stays fully havoc'd.
    function _.accrueForwarded(uint256, uint256, uint256) external => HAVOC_ECF;
    function _.receiveForward(uint256) external => HAVOC_ECF;
}

// ---------------------------------------------------------------------------------------------
// ghost state (PROPERTIES section 6, "Ghost state needed")
// ---------------------------------------------------------------------------------------------

// Mirror of the vault's own ledgerTotal. Keyed by the v4 `Currency` user-defined value type,
// because that is the key type of the storage mapping the hooks below observe.
//
// REVIEW-1B: every mirror below is `persistent`. The successor vault is summarized HAVOC_ALL (it is
// unknown third-party code), and a HAVOC_ALL summary wipes every NON-persistent ghost - the
// review-1 call traces show "All non-persistent ghosts were havoc'd" inside
// `forwardProtocolFee` / `flushForward`, which is why every ghost-delta rule came back violated
// with nonsense mirror values. `persistent` keeps the spec-side write log the `Sstore` hooks build;
// it changes no rule's meaning, because the hooks still fire on exactly the vault's own stores and
// a successor cannot write this vault's own storage slots. Post-state values that must survive the
// HAVOC are therefore read from these mirrors rather than re-read from (havoc'd) storage.
persistent ghost mapping(FeeVault.Currency => mathint) ghostLedgerTotal {
    init_state axiom forall FeeVault.Currency c. ghostLedgerTotal[c] == 0;
}

// Sum of every ETH-denominated ledger the spec enumerates in FEE-10.
persistent ghost mathint ghostDev             { init_state axiom ghostDev == 0; }
persistent ghost mathint ghostCreatorSum      { init_state axiom ghostCreatorSum == 0; }
persistent ghost mathint ghostAccruedSum      { init_state axiom ghostAccruedSum == 0; }
persistent ghost mathint ghostReinforceEth    { init_state axiom ghostReinforceEth == 0; }
persistent ghost mathint ghostEarmark         { init_state axiom ghostEarmark == 0; }
persistent ghost mathint ghostPendingSum      { init_state axiom ghostPendingSum == 0; }
persistent ghost mathint ghostAncestorClaimed { init_state axiom ghostAncestorClaimed == 0; }
// Per-attribution mirror of pendingForward, so the flush post-condition can be read from the write
// log instead of from storage that a HAVOC_ALL successor summary has wiped.
persistent ghost mapping(uint256 => mathint) ghostPending {
    init_state axiom forall uint256 a. ghostPending[a] == 0;
}

// REVIEW-1C: backing store for the consistent-read summaries in the `methods` block. Arbitrary
// values, fixed once per state, which is what a view function of another contract actually is.
persistent ghost mapping(address => mapping(uint256 => uint256)) ghostClaimBalance;
persistent ghost uint256 ghostRmHeadIndex;
persistent ghost mapping(uint256 => address) ghostRmCanonical;
persistent ghost mapping(address => address) ghostRmCreatorOf;
persistent ghost mapping(address => uint256) ghostRmIndexOf;

persistent ghost bytes32 ghostUnlockSlot;
function cvlUnlockSlot() returns bytes32 { return ghostUnlockSlot; }

persistent ghost mapping(address => uint256) ghostTokenBalance;
function cvlTokenBalance(address holder) returns uint256 { return ghostTokenBalance[holder]; }

function cvlClaimBalance(address holder, uint256 tokenId) returns uint256 {
    return ghostClaimBalance[holder][tokenId];
}
function cvlRmHeadIndex()           returns uint256 { return ghostRmHeadIndex; }
function cvlRmCanonical(uint256 i)  returns address { return ghostRmCanonical[i]; }
function cvlRmCreatorOf(address t)  returns address { return ghostRmCreatorOf[t]; }
function cvlRmIndexOf(address t)    returns uint256 { return ghostRmIndexOf[t]; }

// REVIEW-1C: the ETH-denominated half of `reinforcementBalance`. The spec's own FEE-10 enumeration
// (header of this file) names `reinforcementBalance[parent]` as a ledger, but the drafted ghost sum
// omitted it and no hook tracked it - which is exactly what violated `ethLedgerDecomposition` on
// `accrue` and `consumeReinforcement` in review-1b: `consumeReinforcement` takes 1 wei out of
// `reinforcementBalance[0x0]` AND out of `ledgerTotal[ETH]`, so the left side fell while the right
// side, missing the term, did not. Only the `address(0)` key belongs in an ETH decomposition; a
// non-ETH parent's pot is denominated in that token, not in wei.
persistent ghost mathint ghostReinforceBalanceEth {
    init_state axiom ghostReinforceBalanceEth == 0;
}

// `ledgerTotal` is keyed by the v4 `Currency` user-defined value type, not by a plain address,
// so the hook key must be declared with that type.
hook Sstore ledgerTotal[KEY FeeVault.Currency c] uint256 v (uint256 oldV) {
    ghostLedgerTotal[c] = to_mathint(v);
}
hook Sload uint256 v ledgerTotal[KEY FeeVault.Currency c] {
    require ghostLedgerTotal[c] == to_mathint(v);
}
// REVIEW-3. `devBalance` and `genesisBidEarmark` are SCALAR words, so their mirrors are absolute
// (like `ledgerTotal`'s above) rather than delta-accumulating, and an `Sload` hook pins each to the
// word it mirrors. The mapping mirrors below are sums over many words, so no load can pin them
// exactly; each load pins the sum to be at least the element read, which is what the unsigned
// element guarantees and all the decomposition needs.
hook Sstore devBalance uint256 v (uint256 oldV) {
    ghostDev = to_mathint(v);
}
hook Sload uint256 v devBalance {
    require ghostDev == to_mathint(v);
}
hook Sstore creatorBalance[KEY address t] uint256 v (uint256 oldV) {
    ghostCreatorSum = ghostCreatorSum + to_mathint(v) - to_mathint(oldV);
}
hook Sload uint256 v creatorBalance[KEY address t] {
    require ghostCreatorSum >= to_mathint(v);
}
hook Sstore creatorAccrued[KEY address a] uint256 v (uint256 oldV) {
    ghostAccruedSum = ghostAccruedSum + to_mathint(v) - to_mathint(oldV);
}
hook Sload uint256 v creatorAccrued[KEY address a] {
    require ghostAccruedSum >= to_mathint(v);
}
hook Sstore reinforcementEth[KEY uint256 j] uint256 v (uint256 oldV) {
    ghostReinforceEth = ghostReinforceEth + to_mathint(v) - to_mathint(oldV);
}
hook Sload uint256 v reinforcementEth[KEY uint256 j] {
    require ghostReinforceEth >= to_mathint(v);
}
hook Sstore genesisBidEarmark uint256 v (uint256 oldV) {
    ghostEarmark = to_mathint(v);
}
hook Sload uint256 v genesisBidEarmark {
    require ghostEarmark == to_mathint(v);
}
hook Sstore pendingForward[KEY uint256 a] uint256 v (uint256 oldV) {
    ghostPendingSum = ghostPendingSum + to_mathint(v) - to_mathint(oldV);
    ghostPending[a] = to_mathint(v);
}
hook Sload uint256 v pendingForward[KEY uint256 a] {
    require ghostPending[a] == to_mathint(v) && ghostPendingSum >= to_mathint(v);
}
hook Sstore ancestorClaimed[KEY uint256 j] uint256 v (uint256 oldV) {
    ghostAncestorClaimed = ghostAncestorClaimed + to_mathint(v) - to_mathint(oldV);
}
hook Sload uint256 v ancestorClaimed[KEY uint256 j] {
    require ghostAncestorClaimed >= to_mathint(v);
}
hook Sstore reinforcementBalance[KEY address parent] uint256 v (uint256 oldV) {
    if (parent == 0) {
        ghostReinforceBalanceEth = ghostReinforceBalanceEth + to_mathint(v) - to_mathint(oldV);
    }
}
hook Sload uint256 v reinforcementBalance[KEY address parent] {
    require parent == 0 => ghostReinforceBalanceEth >= to_mathint(v);
}
// NOT EXPRESSIBLE HERE: the ancestor sleeve is not a scalar ledger. It is a range-add of three
// WAD-scaled coefficients into the Fenwick trees (spec J, "Ancestor polynomial"), so there is no
// storage word whose delta is "the sleeve credited by this call" and no hook can mirror one. The
// sleeve's own conservation claim (SLV-03) is therefore proved in Sleeve.spec against
// certora/harness/FenwickHarness.sol; every sum below omits the sleeve term, which keeps each
// bound sound (the omitted term is non-negative) but makes FEE-08 an upper bound rather than an
// equality on this contract. See certora/PROPERTY_MAP.md.

// REVIEW-1B well-formedness. `Drawdown.updatedAt` is a uint64 that only ever receives
// `uint64(block.timestamp)`, and `_bucket` treats `updatedAt == 0` as "never drawn, full bucket".
// A `block.timestamp` outside the uint64 range (which the Prover picks by default) truncates to 0
// on the store and re-arms that sentinel, so the next draw in the same block sees a full bucket.
// Neither timestamp 0 nor timestamp 2^64 is reachable on a live chain; the sentinel collision is
// recorded as a latent-risk finding in certora/RESULTS-review-1.md rather than hidden here.
definition wellFormedTime(env e) returns bool =
    e.block.timestamp > 0 && to_mathint(e.block.timestamp) < 18446744073709551616;

// The native-ETH currency is Currency.wrap(address(0)) (spec I).
definition ETH() returns FeeVault.Currency = 0;

// Methods that are allowed to move value out of the vault at all (spec J "Claims", the keeper
// model, the sunset handover).
//
// REVIEW-1C: the drafted list named the three claims, the keeper bounty, the flush and the redeem,
// and omitted two of spec J's own paths. Review-1b showed `consumeReinforcement` paying 1 wei to the
// BidDeployer and reported it as an undeclared exit - but the BidDeployer consumption hooks ARE a
// declared path (spec J, "The keeper model"). They are `onlyBidDeployer`, and that leash is proved
// by `onlyBidDeployerHooks` in this same file, so naming them completes the spec's enumeration
// without costing the rule anything: every OTHER method must still move nothing.
//
// `accrue` and `forwardProtocolFee` are DELIBERATELY LEFT OUT. Neither moves native ETH: the sunset
// hop hands the successor an ERC-6909 CLAIM (`poolManager.transfer`), and the only ETH leg of the
// handover is `flushForward`, which is already listed. They are reported violating this rule purely
// because the successor's `accrueForwarded` / `receiveForward` are summarized HAVOC_ALL, which
// havocs native balances too. Listing them would hide a future REAL exit on the accrual path, so
// they stay out and the rule stays violated until that summary is narrowed - see the HAVOC_ALL
// entry in certora/RESULTS-review-1.md.
definition isPayoutMethod(method f) returns bool =
    f.selector == sig:claimDev(address).selector
 || f.selector == sig:claimCreator(address,address).selector
 || f.selector == sig:claimCreatorAccrued(address).selector
 || f.selector == sig:payKeeper(address,uint256).selector
 || f.selector == sig:flushForward(uint256,uint256).selector
 || f.selector == sig:redeem(FeeVault.Currency).selector
 || f.selector == sig:consumeReinforcement(address,uint256).selector
 || f.selector == sig:consumeGenesisEarmark(uint256).selector;

// ---------------------------------------------------------------------------------------------
// solvency and conservation
// ---------------------------------------------------------------------------------------------

/// FEE-11 (spec I "ERC-6909 claims", spec J): ledgerTotal[c] <= holdings(c) for every currency, where
/// holdings = real balance + unredeemed claims and ledgerTotal includes pendingForward.
/// REVIEW-3 (certora/RESULTS-review-2.md, checklist item 2). The review-2 form was TRUE BUT NOT
/// INDUCTIVE, and `payKeeper`'s counterexample said so exactly: a pre-state with
/// `ledgerTotal[ETH] == holdings(ETH)` AND a non-zero `deployerCredit`, from which paying 1 wei of
/// that credit drops holdings and leaves ledgerTotal alone. No reachable state has both, because
/// `consumeAncestorClaim` DEBITS the ledger when it creates the credit - the credit is ETH that is
/// still in the vault and no longer counted in `ledgerTotal`. Carving it back out on the ETH side is
/// the inductive statement of the same claim, and it is STRICTLY STRONGER than the review-2 one.
invariant solvency(env e, FeeVault.Currency c)
    to_mathint(ledgerTotal(e, c)) + (c == ETH() ? to_mathint(deployerCredit()) : to_mathint(0))
        <= to_mathint(holdings(e, c))
    filtered { f -> !f.isView && f.contract == currentContract }

/// FEE-10 (spec J): ledgerTotal[ETH] covers the sum of the enumerated ETH ledgers plus the queued
/// forwards, i.e. every wei with a named destination is tracked.
/// SPEC-GAP: the Fenwick residue (spec J, "Every division floors") stays in the vault forever and is
/// deliberately not subtracted, which is why the relation is `>=` on the sleeve side. PROPERTIES 7.
/// REVIEW-3 (certora/RESULTS-review-2.md, checklist item 3). The review-2 pass conjoined
/// `ghost* >= 0` to every mirror to kill counterexamples that opened with `ghostPendingSum = -7`,
/// `ghostAncestorClaimed = -8120`, `ghostDev = -1`, `ghostReinforceEth = -3`. That was THE WRONG
/// SHAPE and it cost eight methods: these mirrors accumulate DELTAS, so every method that
/// legitimately decreases one then had to re-establish `>= 0` out of nothing. The conjuncts are
/// REVERTED here and each mirror is tied to the storage word it mirrors instead, at the `Sload`
/// hooks above: a scalar mirror (`devBalance`, `genesisBidEarmark`) is pinned to EQUAL its word,
/// and a mapping SUM is pinned to be at least the element being read. The Prover can no longer
/// start a step from a mirror that contradicts the storage the step reads, and nothing has to be
/// re-proved out of thin air. The decomposition itself is unchanged from review-1c.
/// REVIEW-3 RE-RUN, the two residual methods, each with its own cause and its own fix:
///   `accrue` - the Prover calls it with `currency = 0xf84` and `parentToken = address(0)` at the
///   same time. That pair cannot occur: `parentToken` is the HOOK'S OWN genesis marker
///   (`FamilyHook._collect` passes `p.isGenesis ? address(0) : Currency.unwrap(parent)`), and the
///   genesis pool's parent currency IS native ETH, so `parentToken == 0` and `currency == ETH` are
///   the same fact. Uncoupled, the call credits `reinforcementBalance[address(0)]` - an ETH-side
///   term of this decomposition - with a NON-ETH fee, and the ETH ledger legitimately does not
///   move. The `preserved` block below states the caller's convention, which is what FEE-10 is
///   about; it does not assume anything about amounts.
///   `forwardProtocolFee` - the pre-state has `ghostAncestorClaimed` hugely NEGATIVE. The `Sload`
///   pins above tie a mapping sum only on the keys a method actually reads, and this path reads
///   none, so the mirror is still free. `ethMirrorsAreNonNegative` below is that fact proved ONCE,
///   as its own invariant (where each method only has to preserve it, which the absolute scalar
///   mirrors and the load-pinned mapping sums now do), and assumed here - which is the
///   `requireInvariant` half of review-2's checklist item 3, next to the load-hook half.
invariant ethMirrorsAreNonNegative()
    ghostDev >= 0 && ghostCreatorSum >= 0 && ghostAccruedSum >= 0 && ghostEarmark >= 0
    && ghostPendingSum >= 0 && ghostReinforceEth >= 0 && ghostReinforceBalanceEth >= 0
    && ghostAncestorClaimed >= 0
    filtered { f -> !f.isView && f.contract == currentContract }

invariant ethLedgerDecomposition()
    ghostLedgerTotal[ETH()] >= ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                              + ghostPendingSum + ghostReinforceEth + ghostReinforceBalanceEth
                              - ghostAncestorClaimed
    filtered { f -> !f.isView && f.contract == currentContract }
    {
        preserved with (env e) {
            requireInvariant ethMirrorsAreNonNegative();
        }
        preserved accrue(FeeVault.Currency c, address parentToken, uint256 hopFee,
                         uint256 protocolFee, uint256 terminalIndex, bool attributed) with (env e) {
            requireInvariant ethMirrorsAreNonNegative();
            require (parentToken == 0) <=> (c == ETH());
        }
    }

/// FEE-08 (spec J "_book"): one accrue moves at most hopFee + protocolFee into the ledgers, and every
/// credited wei is one of dev / creator / coCredit / sleeve / reinforce / hop.
rule accrueConservesTheFee(env e, FeeVault.Currency c, address parentToken,
                           uint256 hopFee, uint256 protocolFee, uint256 terminalIndex, bool attributed) {
    mathint before = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                   + ghostPendingSum + ghostReinforceEth;
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    mathint after = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                  + ghostPendingSum + ghostReinforceEth;
    // The hop fee is denominated in the parent currency and lands in reinforcementBalance[parent];
    // it is counted in this sum only when the parent currency is ETH (the genesis pool).
    assert after - before <= to_mathint(hopFee) + to_mathint(protocolFee),
        "accrue credited more than it was handed";
}

/// FEE-08 (spec J): accrue changes ledgerTotal by at most what it was handed, never more.
rule accrueMovesLedgerTotalByTheFee(env e, FeeVault.Currency c, address parentToken,
                                    uint256 hopFee, uint256 protocolFee, uint256 terminalIndex, bool attributed) {
    mathint before = ghostLedgerTotal[ETH()];
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    assert ghostLedgerTotal[ETH()] - before <= to_mathint(hopFee) + to_mathint(protocolFee),
        "ledgerTotal grew by more than the fee credited";
}

/// FEE-10 (spec J): fees enter through exactly one door — no method outside the accrual and queue
/// paths increases any ledger.
rule onlyAccrualPathsCredit(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                   + ghostPendingSum + ghostReinforceEth;
    f(e, args);
    mathint after = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                  + ghostPendingSum + ghostReinforceEth;
    assert after > before =>
        (f.selector == sig:accrue(FeeVault.Currency,address,uint256,uint256,uint256,bool).selector
      || f.selector == sig:accrueForwarded(uint256,uint256,uint256).selector
      || f.selector == sig:receiveForward(uint256).selector
      || f.selector == sig:depositGenesisBidEarmark().selector
      || f.selector == sig:transferCreatorRecipient(address,address).selector),
        "a ledger grew outside the accrual paths";
}

/// ROL-07 (spec J "Claims"): transferCreatorRecipient only moves value between two ledgers; the sum of
/// creatorBalance and creatorAccrued is unchanged by it.
rule creatorTransferIsALedgerMove(env e, address token, address to) {
    mathint before = ghostCreatorSum + ghostAccruedSum;
    transferCreatorRecipient(e, token, to);
    assert ghostCreatorSum + ghostAccruedSum == before,
        "transferring the creator right created or destroyed a credit";
}

// ---------------------------------------------------------------------------------------------
// the drawdown token bucket (BID-07)
// ---------------------------------------------------------------------------------------------

/// BID-07 (spec J "Drawdown allowance is a token bucket"): a draw succeeds only for amounts within
/// the allowance the bucket currently holds, so the bucket is never overdrawn.
rule drawNeverExceedsTheBucket(env e, uint256 j, uint256 ethAmount) {
    require wellFormedTime(e);
    uint256 allowed = drawableEth(e, j);
    consumeAncestorClaim(e, j, ethAmount);
    assert ethAmount <= allowed, "a draw exceeded the bucket's available allowance";
}

/// PUR-05 / BID-07 (PROPERTIES 3.7, REVIEW-3): the OTHER half of the keeper draw bound, and the one
/// the uncontested purse rests on - ETH drawn for generation `j` never exceeds `j`'s OWN claimable
/// sleeve. `deployAncestor(j, amount)` now deploys the WHOLE generation share in one place, so this
/// is the only thing standing between one keeper call and another generation's ETH. It is stated
/// against `claimableEth(j)` directly (the bucket bound above is the strictly tighter daily one);
/// together they are "never more than the generation has, and never more than the day allows".
rule drawNeverExceedsTheGenerationsClaim(env e, uint256 j, uint256 ethAmount) {
    uint256 claimable = claimableEth(e, j);
    consumeAncestorClaim(e, j, ethAmount);
    assert ethAmount <= claimable, "a draw exceeded generation j's own claimable sleeve";
}

/// BID-07 (spec J): the allowance is capped at DAILY_DRAW_BPS of what is claimable right now, at
/// every instant — a bucket, not a resetting window, so there is no boundary to burst at.
invariant bucketNeverExceedsCap(env e, uint256 j)
    wellFormedTime(e) =>
        to_mathint(drawableEth(e, j)) <= to_mathint(claimableEth(e, j)) * to_mathint(DAILY_DRAW_BPS()) / 10000
    filtered { f -> !f.isView && f.contract == currentContract }

/// BID-07 (spec J, audit 6): two draws in the same instant cannot together exceed one bucket.
rule twoDrawsCannotDoubleUp(env e, uint256 j, uint256 a, uint256 b) {
    require wellFormedTime(e);
    uint256 allowed = drawableEth(e, j);
    consumeAncestorClaim(e, j, a);
    // Same block: dt == 0, so the bucket has refilled by nothing between the two draws.
    consumeAncestorClaim(e, j, b);
    assert to_mathint(a) + to_mathint(b) <= to_mathint(allowed),
        "two same-instant draws exceeded one bucket";
}

/// BID-07, REVIEW-2: the same claim with NO well-formedness precondition on the clock at all.
/// Review-1b could only discharge the rule above by excluding `block.timestamp == 0` and
/// `block.timestamp >= 2^64`, because `Drawdown.updatedAt == 0` doubled as "untouched generation,
/// full bucket" and `uint64(block.timestamp)` could truncate back onto that sentinel - finding F-2.
/// F-2 is closed (docs/attack-log.md): the sentinel is an explicit `Drawdown.initialised` flag and
/// the refill clock is read in the same uint64 domain the field is stored in. This rule is the
/// formal evidence for that fix: it must pass for EVERY clock the Prover can pick.
rule twoDrawsCannotDoubleUpAtAnyClock(env e, uint256 j, uint256 a, uint256 b) {
    uint256 allowed = drawableEth(e, j);
    consumeAncestorClaim(e, j, a);
    consumeAncestorClaim(e, j, b);
    assert to_mathint(a) + to_mathint(b) <= to_mathint(allowed),
        "two same-instant draws exceeded one bucket at an extreme clock";
}

// ---------------------------------------------------------------------------------------------
// the keeper leash (BID-05, BID-14)
// ---------------------------------------------------------------------------------------------

/// BID-05 (spec J "The keeper model"): payKeeper moves at most the deployerCredit created in the
/// same transaction by consumeAncestorClaim out of generation j's own ledgers.
rule payKeeperIsBoundedByDeployerCredit(env e, address to, uint256 ethAmount) {
    uint256 credit = deployerCredit();
    payKeeper(e, to, ethAmount);
    assert ethAmount <= credit, "payKeeper paid more than the credit consumed for it";
}

/// BID-14 (PROPERTIES 3.8): no keeper call leaves a residual credit — deployerCredit is zero at rest.
invariant deployerCreditSettles()
    deployerCredit() == 0
    filtered { f -> !f.isView && f.contract == currentContract
                 && f.selector != sig:consumeAncestorClaim(uint256,uint256).selector }

/// BID-05 / FEE-10: value leaves the vault only on a declared payout path (a ledger holder's claim,
/// the keeper bounty, a forward to the successor vault, or a redeem into the vault itself).
rule valueLeavesOnlyOnPayoutMethods(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = nativeBalances[currentContract];
    f(e, args);
    assert nativeBalances[currentContract] < before => isPayoutMethod(f),
        "ETH left the vault on a method that is not a declared payout path";
}

/// BID-05 (spec J): the four leashed hooks are callable by BidDeployer alone, so no other address can
/// create a credit or spend a generation's money.
rule onlyBidDeployerHooks(method f, env e, calldataarg args)
    filtered { f -> f.selector == sig:consumeAncestorClaim(uint256,uint256).selector
                 || f.selector == sig:consumeReinforcement(address,uint256).selector
                 || f.selector == sig:consumeGenesisEarmark(uint256).selector
                 || f.selector == sig:payKeeper(address,uint256).selector }
{
    f(e, args);
    assert e.msg.sender == bidDeployer(), "a non-BidDeployer reached a leashed hook";
}

// ---------------------------------------------------------------------------------------------
// the forwarding queue (CON-04, CON-05)
// ---------------------------------------------------------------------------------------------

/// CON-05 (spec J "Sunset handover"): pendingForwardTotal is the sum of every pendingForward entry.
invariant pendingForwardTotalIsTheSum()
    to_mathint(pendingForwardTotal()) == ghostPendingSum
    filtered { f -> !f.isView && f.contract == currentContract }

/// CON-05 (spec J): flushForward moves at most `max`, decrements pendingForward and ledgerTotal by
/// exactly the amount delivered, and creates or destroys nothing.
/// REVIEW-1B: the post-state is read from the write-log mirrors, not re-read from storage. The
/// successor's `receiveForward` is summarized HAVOC_ALL, so a storage re-read after that call
/// returns an unconstrained word (review-1 call trace: `pendingForward[0]` came back as a near-max
/// uint after the contract had correctly stored 1922). The mirrors record the value the vault
/// itself stored, which is exactly what CON-05 claims: this pins the store rather than the re-read.
rule flushForwardConserves(env e, uint256 attribution, uint256 max) {
    uint256 pendingBefore = pendingForward(attribution);
    require ghostPending[attribution] == to_mathint(pendingBefore);
    mathint ledgerBefore = ghostLedgerTotal[ETH()];
    uint256 moved = flushForward(e, attribution, max);
    assert moved <= max, "flushForward moved more than max";
    assert ghostPending[attribution] == to_mathint(pendingBefore) - to_mathint(moved),
        "pendingForward did not fall by exactly what was delivered";
    assert ghostLedgerTotal[ETH()] == ledgerBefore - to_mathint(moved),
        "ledgerTotal did not fall by exactly what was delivered";
}

/// CON-04 (spec J): while the version is sunset, a protocol fee on the ETH edge is forwarded or
/// queued, never booked to a local ledger.
/// SPEC-GAP: `isSunset()` is summarized NONDET here, so the rule is stated as an implication over the
/// booking ghosts rather than over the RoundManager's real state. Cross-reference PROPERTIES 7.
rule postSunsetFeesAreNeverBookedLocally(env e, FeeVault.Currency c, address parentToken,
                                         uint256 hopFee, uint256 protocolFee, uint256 terminalIndex, bool attributed) {
    require protocolFee > 0;
    mathint devBefore = ghostDev;
    mathint creatorBefore = ghostCreatorSum;
    mathint pendingBefore = ghostPendingSum;
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    // Either the local split ran (not sunset), or nothing local moved and the fee was queued/forwarded.
    assert (ghostDev == devBefore && ghostCreatorSum == creatorBefore)
        => ghostPendingSum >= pendingBefore,
        "a post-sunset edge fee neither booked nor queued";
}

// ---------------------------------------------------------------------------------------------
// immutability of rates and splits (FEE-03, ROL-01) and CEI on claims (REN-02)
// ---------------------------------------------------------------------------------------------

/// FEE-03 / ROL-01 (spec I, spec M): no function anywhere changes a fee rate or a split after deploy.
rule ratesAndSplitsAreImmutable(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 devBps = DEV_BPS();
    uint256 creatorBps = CREATOR_BPS();
    uint256 ancestorBps = ANCESTOR_BPS();
    uint256 reinforceBps = REINFORCE_BPS();
    uint256 drawBps = DAILY_DRAW_BPS();
    f(e, args);
    assert DEV_BPS() == devBps && CREATOR_BPS() == creatorBps && ANCESTOR_BPS() == ancestorBps
        && REINFORCE_BPS() == reinforceBps && DAILY_DRAW_BPS() == drawBps,
        "a fee split moved after deployment";
}

/// REN-02 (PROPERTIES 3.14): every claim zeroes its ledger before the external transfer, so a
/// reentrant claim can never be paid twice out of the same balance.
rule claimZeroesBeforePaying(env e, address to) {
    uint256 before = devBalance();
    uint256 paid = claimDev(e, to);
    assert to_mathint(before) - to_mathint(paid) == to_mathint(devBalance()),
        "claimDev paid an amount its ledger did not lose";
    assert devBalance() == 0, "claimDev left a residue in the developer ledger";
}
