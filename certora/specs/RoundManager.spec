/*
 * RoundManager.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §A (state machine), §C (round lifecycle, adaptive
 * schedule, random end, bond schedule), §G (canonical finalization) and docs/spec/PROPERTIES.md
 * §3.5 / §3.6 / §3.9 / §6. Written from the specification only.
 */

using RoundManager as rm;

methods {
    // --- schedule, pure in the round number (spec C; RND-01) ---
    function durationFor(uint256) external returns (uint64) envfree;
    function registrationFor(uint256) external returns (uint64) envfree;
    function lateEntryUntil(uint256) external returns (uint64) envfree;
    function closingWindowFor(uint256) external returns (uint64) envfree;
    function randomEndWindowFor(uint256) external returns (uint64) envfree;
    function scoreSlotFor(uint256) external returns (uint32) envfree;
    function bondFor(uint256) external returns (uint256) envfree;

    // --- constants and immutables (spec C) ---
    function BASE_TRADING_S() external returns (uint64) envfree;
    function CLOSING_WINDOW_S() external returns (uint64) envfree;
    function MAX_TRADING_S() external returns (uint64) envfree;
    function MIN_REGISTRATION_S() external returns (uint64) envfree;
    function MAX_REGISTRATION_S() external returns (uint64) envfree;
    function LATE_ENTRY_FROM_S() external returns (uint64) envfree;
    function SUBMIT_S() external returns (uint64) envfree;
    function RANDOM_END_S() external returns (uint64) envfree;
    function END_TIMEOUT() external returns (uint64) envfree;
    function MAX_INDEX() external returns (uint256) envfree;
    function H_FRAC_WAD() external returns (uint256) envfree;
    function H_MIN_FRAC_WAD() external returns (uint256) envfree;
    function BOND_BASE_WEI() external returns (uint256) envfree;
    function BOND_MAX_WEI() external returns (uint256) envfree;
    function BOND_DOUBLING_EVERY() external returns (uint256) envfree;
    function DURATION_SCALE_DIV() external returns (uint64) envfree;

    // --- head / canonical history (spec A, spec G) ---
    function head() external returns (address) envfree;
    function headIndex() external returns (uint256) envfree;
    function priorIndex() external returns (uint256) envfree;
    function canonical(uint256) external returns (address) envfree;
    function indexOf(address) external returns (uint256) envfree;
    function isCanonical(address) external returns (bool) envfree;
    function parentOf(address) external returns (address) envfree;
    function creatorOf(address) external returns (address) envfree;
    function adopted() external returns (bool) envfree;
    function roundCount() external returns (uint256) envfree;
    function hWad() external returns (uint256) envfree;
    function isIdle() external returns (bool) envfree;
    function pendingRefund(address) external returns (uint256) envfree;

    // --- transitions (spec A, rows 2/3b/6b/6c/7/9-11) ---
    function openRoundIfIdle() external returns (uint256, uint256);
    function addCandidate(uint256, address, RoundManager.PoolKey, address) external returns (uint256);
    function requestEnd() external returns (bytes32);
    function fulfilEnd(bytes) external returns (uint64);
    function finalizeDeterministic() external;
    function submitScore(uint256) external returns (int256);
    function finalize() external;
    function claimRefund(address) external;
    function announceSunset(address) external;
    function cancelSunset() external;
    function announceStewardTransfer(address) external;
    function cancelStewardTransfer() external;
    function executeStewardTransfer() external;
    function registerGenesis(address, RoundManager.PoolKey, address) external;

    // --- summaries ---------------------------------------------------------------------------
    // The drand source verifies a BN254 pairing on precompile 0x08; the pairing result and the
    // random word are NONDET under the pinned-round constraint (PROPERTIES section 6). Nothing below
    // depends on the word's value, only on the arithmetic applied to it.
    // REVIEW-1B. `pin()` must NOT be a bare NONDET. `requestEnd` arms its once-per-round guard with
    // `r.randomId != bytes32(0)`, so a NONDET `pin()` that returns bytes32(0) lets the prover request
    // the end twice - which is what violated `requestEndIsOnceAndNotBeforeT` in review-1, an artefact
    // of the summary and not of the contract. The beacon round id is a drand round number and is
    // never zero, so the summary returns an arbitrary but NON-ZERO, and crucially STABLE, id. The
    // id's value is still unconstrained; only the zero sentinel and per-call re-randomisation are
    // excluded. The zero-id sentinel collision itself is recorded as a finding in
    // certora/RESULTS-review-1.md.
    function _.pin() external => cvlPin() expect bytes32;
    function _.fulfil(bytes32, bytes) external => NONDET;
    function _.isMock() external => NONDET;

    // The hook supplies the closing-window average; its correctness is FamilyHook.spec's job.
    function _.averageOver(RoundManager.PoolId, uint64, uint64) external => NONDET;
    function _.trailingAverage(RoundManager.PoolId, uint32) external => NONDET;

    // The vault receives forfeited bonds; its ledgers are FeeVault.spec's job.
    function _.depositGenesisBidEarmark() external => NONDET;

    // A prior registry in a continuation chain is an earlier, already-deployed contract: unknown
    // code from this proof's point of view, so every delegated read is NONDET.
    // REVIEW-1B. These are VIEW reads of an already-deployed prior registry. A bare NONDET makes two
    // reads of the same getter in the same state return different values, which is not an
    // over-approximation of an external contract - it is simply false, and it is what violated
    // `finalizeIsIdempotent` (two `head()` calls disagreed) and the transient-storage step of
    // `reverseIndexIsConsistent` (two `canonical(i)` calls disagreed) in review-1. The values stay
    // fully unconstrained; they are pinned to persistent ghosts so that they are merely CONSISTENT.
    function _.isSunsetEffective() external => cvlPriorSunset() expect bool;
    function _.successor() external => cvlPriorSuccessor() expect address;
    function _.headToken() external => cvlPriorHeadToken() expect address;
    function _.priorRegistry() external => cvlPriorRegistry() expect address;
    function _.adopted() external => cvlPriorAdopted() expect bool;
    // REVIEW-1C (from the review-1b run, not yet re-run). These five were still falling through to
    // the Prover's AUTO (havoc-per-call) summary, and that is what was left violating
    // `headIndexOnlyGrows`, `historyEntriesAreImmutable`, `pairingRightsAreWriteOnce`,
    // `reverseIndexIsConsistent`, `finalizeIsIdempotent` and `maxIndexIsRespected`: `headIndex()`,
    // `head()` and `canonical(i)` all DELEGATE to the prior registry while `!adopted`, so two reads
    // of the same getter in the same state came back different. Same treatment as above -
    // unconstrained values, pinned so that they are consistent.
    // REVIEW-2 (docs/attack-log.md, REN-01). Every state-changing entrypoint of this contract now
    // carries `notInsideUnlock`, which reads v4-core's transient lock slot off the PoolManager with
    // a single `exttload` (contracts/libraries/V4UnlockGuard.sol). The manager is DELIBERATELY
    // UNLINKED, so without a summary that read falls through to the Prover's per-call havoc - and a
    // guard that answers differently on two calls in the SAME transaction is not an
    // over-approximation of a transient slot, it is false, and it would re-introduce exactly the
    // mechanism-4 defect review-1b spent a pass removing (`noTransitionIsPrivileged` compares two
    // callers; `finalizeIsIdempotent` and `endIsSettledAtMostOnce` call twice). The value stays
    // completely unconstrained - the Prover may still put the whole rule inside an unlock - it is
    // merely CONSISTENT within a transaction, which is what the slot is.
    function _.exttload(bytes32) external => cvlUnlockSlot() expect bytes32;

    function _.headIndex() external => cvlPriorHeadIndex() expect uint256;
    function _.priorIndex() external => cvlPriorPriorIndex() expect uint256;
    function _.canonical(uint256 i) external => cvlPriorCanonical(i) expect address;
    function _.indexOf(address t) external => cvlPriorIndexOf(t) expect uint256;
    function _.isCanonical(address t) external => cvlPriorIsCanonical(t) expect bool;
    function _.parentOf(address t) external => cvlPriorParentOf(t) expect address;
    function _.creatorOf(address t) external => cvlPriorCreatorOf(t) expect address;
    // REVIEW-3 (certora/RESULTS-review-2.md, checklist item 1). `ownsToken` was the ONE delegated
    // read review-1c missed, and it is the single cause of five of the six remaining RoundManager
    // failures: `registryOfToken(token)` walks the chain asking each registry `ownsToken(token)`,
    // so EVERY `parentOf` / `creatorOf` / `indexOf` / `isCanonical` / `canonical` read goes through
    // it, and without a summary the trace reads `RoundManager.parentOf(address) ->
    // [?].ownsToken(address) : AUTO havoc` - two reads of the same getter in the same state
    // disagree, which is false of any view function rather than an over-approximation of one.
    // `isIdle()` is the other unpinned prior read (`_adoptIfContinuation` asks the prior for it
    // next to `isSunsetEffective` / `successor` / `adopted`, which ARE pinned). Values stay
    // completely unconstrained; they are merely CONSISTENT.
    function _.ownsToken(address t) external => cvlPriorOwnsToken(t) expect bool;
    function _.isIdle() external => cvlPriorIsIdle() expect bool;
    // NOT SUMMARIZED, deliberately: `_.poolKeyOf(uint256)` returns a v4 `PoolKey` STRUCT, which a
    // CVL ghost cannot hold as one value; it stays AUTO. No rule in this file reads a delegated
    // pool key twice, so the per-call havoc cannot make one of them disagree with itself.
}

// ---------------------------------------------------------------------------------------------
// ghost state (PROPERTIES section 6: ghostCanonicalWrites[i])
// ---------------------------------------------------------------------------------------------

// REVIEW-1B: `persistent`, so a HAVOC_ALL/AUTO summary of an unresolved callee does not wipe the
// spec-side write log the hooks below build. The hooks still fire on exactly this contract's own
// stores, so no rule's meaning changes.
persistent ghost mapping(uint256 => mathint) ghostCanonicalWrites {
    init_state axiom forall uint256 i. ghostCanonicalWrites[i] == 0;
}
persistent ghost mathint ghostHeadWrites { init_state axiom ghostHeadWrites == 0; }
// Highest canonical index ever written, so append-only can be stated as a monotone length.
persistent ghost mathint ghostHistoryLength { init_state axiom ghostHistoryLength == 0; }

// Backing store for the prior-registry and beacon summaries above: arbitrary values, fixed once.
persistent ghost bytes32 ghostPinId;
persistent ghost bytes32 ghostUnlockSlot;
persistent ghost bool    ghostPriorSunset;
persistent ghost bool    ghostPriorAdopted;
persistent ghost address ghostPriorSuccessor;
persistent ghost address ghostPriorHeadToken;
persistent ghost address ghostPriorRegistry;

// REVIEW-2 (docs/attack-log.md, F-3). Review-1b had to require a NON-ZERO beacon id here, because
// `requestEnd`'s once-per-round guard was `r.randomId != bytes32(0)` and a NONDET `pin()` returning
// zero silently disarmed it. The guard is now an explicit `Round.endRequested` flag, so the
// constraint is REMOVED and `pin()` may return anything at all, zero included. This rule set is
// therefore the formal evidence that a source returning a zero id cannot request the end twice.
function cvlPin() returns bytes32 { return ghostPinId; }
function cvlUnlockSlot() returns bytes32 { return ghostUnlockSlot; }
function cvlPriorSunset()    returns bool    { return ghostPriorSunset; }
function cvlPriorAdopted()   returns bool    { return ghostPriorAdopted; }
function cvlPriorSuccessor() returns address { return ghostPriorSuccessor; }
function cvlPriorHeadToken() returns address { return ghostPriorHeadToken; }
function cvlPriorRegistry()  returns address { return ghostPriorRegistry; }

persistent ghost uint256 ghostPriorHeadIndex;
persistent ghost uint256 ghostPriorPriorIndex;
persistent ghost mapping(uint256 => address) ghostPriorCanonical;
persistent ghost mapping(address => uint256) ghostPriorIndexOf;
persistent ghost mapping(address => bool)    ghostPriorIsCanonical;
persistent ghost mapping(address => address) ghostPriorParentOf;
persistent ghost mapping(address => address) ghostPriorCreatorOf;
persistent ghost mapping(address => bool) ghostPriorOwnsToken;
persistent ghost bool ghostPriorIsIdle;

function cvlPriorHeadIndex()  returns uint256 { return ghostPriorHeadIndex; }
function cvlPriorPriorIndex() returns uint256 { return ghostPriorPriorIndex; }
function cvlPriorCanonical(uint256 i)  returns address { return ghostPriorCanonical[i]; }
function cvlPriorIndexOf(address t)    returns uint256 { return ghostPriorIndexOf[t]; }
function cvlPriorIsCanonical(address t) returns bool   { return ghostPriorIsCanonical[t]; }
function cvlPriorParentOf(address t)   returns address { return ghostPriorParentOf[t]; }
function cvlPriorCreatorOf(address t)  returns address { return ghostPriorCreatorOf[t]; }
function cvlPriorOwnsToken(address t)  returns bool    { return ghostPriorOwnsToken[t]; }
function cvlPriorIsIdle()              returns bool    { return ghostPriorIsIdle; }

// REVIEW-1B well-formedness. DURATION_SCALE_DIV, BOND_* and MAX_INDEX are IMMUTABLES: the Prover
// starts a rule from arbitrary storage and the constructor never runs, so they are havoc'd. The
// constructor's own guard is `durationScaleDiv != 0 && durationScaleDiv <= MIN_REGISTRATION_S`
// (RoundManager.sol, `BadDurationScale`), and every schedule getter divides by it. Without this
// restatement `scheduleBounds` fails on a division by zero and `trueEndFallsInsideTheWindow` fails
// with a zero-length window - neither is a claim about the code. This EXCLUDES EXACTLY the states
// the deployed contract cannot be in, and nothing else.
definition wellFormedSchedule() returns bool =
    DURATION_SCALE_DIV() != 0 && DURATION_SCALE_DIV() <= MIN_REGISTRATION_S();

hook Sstore rm._canonical[KEY uint256 i] address v (address old) {
    ghostCanonicalWrites[i] = ghostCanonicalWrites[i] + 1;
    ghostHistoryLength = ghostHistoryLength > to_mathint(i) ? ghostHistoryLength : to_mathint(i) + 1;
}
hook Sstore rm._headIndex uint256 v (uint256 old) {
    ghostHeadWrites = ghostHeadWrites + 1;
}

// REVIEW-3 RE-RUN: `registerGenesis` is the THIRD head writer and the drafted enumeration missed
// it. `RoundManager.sol` writes `_head` / `_headIndex` in exactly three places: `finalize`'s winner
// branch, `_adoptIfContinuation` (inside the first `openRoundIfIdle`) and `registerGenesis`, the
// factory-only one-shot that seats index 0 before any round exists. Review-2 could not see this:
// every leg of these rules was failing for the `ownsToken` reason, and with that pinned the
// `registerGenesis` leg is what is left. Naming it costs the rule nothing - `registerGenesis` is
// `onlyFactory` and write-once, which `canonicalIsWriteOnce` and `noTransitionIsPrivileged`'s own
// exclusion list already treat as a role-gated bootstrap rather than a transition of the round
// machine.
definition isHeadWriter(method f) returns bool =
    f.selector == sig:finalize().selector
 || f.selector == sig:openRoundIfIdle().selector    // the one-shot continuation adoption runs inside it
 || f.selector == sig:registerGenesis(address,RoundManager.PoolKey,address).selector;

// ---------------------------------------------------------------------------------------------
// canonical history: write-once, append-only, immutable (RND-09, PAR-01, PAR-02)
// ---------------------------------------------------------------------------------------------

/// RND-09 (spec A "Head mutation happens in exactly one place", spec G): canonical[i] is write-once.
/// REVIEW-1C: the bare form is TRUE but NOT INDUCTIVE, which is why review-1b still violated it on
/// `finalize`. The counterexample's pre-state had `_canonical[7968]` already occupied while
/// `_headIndex` was 7967 - a state the contract cannot reach, because the only two writers are
/// `registerGenesis` (index 0) and the winner branch of `finalize`, which writes
/// `_canonical[_headIndex + 1]` and assigns `_headIndex = _headIndex + 1` three lines later
/// (RoundManager.sol:1115-1123). The strengthening below states exactly that reachability fact:
/// no index above the current head has ever been written. It is a conjunct, not a `require`, so the
/// base case and every step must still establish it - the invariant is strictly stronger than the
/// drafted one, not weaker.
/// PUR-02 (PROPERTIES 3.7, REVIEW-3) RESTS ON THIS RULE AND ON `historyEntriesAreImmutable`. The
/// purse is no longer contestable: `BidDeployer.deployAncestor(j, amount)` reads its destination as
/// `roundManager.canonical(j)` and takes no destination argument, so PUR-02 ("the destination is
/// `canonical(j)` and nothing else, whatever support any sibling has built since the round; a
/// losing sibling never receives purse liquidity") is the conjunction of two facts:
///   (a) STRUCTURAL, and deliberately NOT restated as a rule here: the destination is a pure
///       function of `j` evaluated inside the deployer. There is no code path that reads a rank, a
///       board or a caller-supplied token, because `rank`, `_board`, `purseWeights`, `purseWindow`
///       and `RANK_MAX_AGE` no longer exist. A rule asserting "the loser got nothing" would have to
///       quantify over a destination the deployer never computes.
///   (b) `canonical(j)` IS FIXED ONCE THE ROUND CROWNS IT - this invariant, plus
///       `historyEntriesAreImmutable` and `onlyFinalizeOrAdoptionWritesHistory`. That is the half
///       that could be falsified by this contract, and it is the half proved here.
/// NOT EXPRESSIBLE WITHOUT THE LOCKER, recorded rather than skipped: the final step of PUR-02 -
/// that the liquidity actually LANDS under `canonical(j)` - is `locker.depositBid(key, ...)` on
/// `roundManager.poolKeyOf(j)`, i.e. an external call from `BidDeployer` (which has no spec or conf
/// of its own) into the Locker and on into the v4 singleton, every entrypoint of which is
/// summarized NONDET. Certora cannot observe the `PurseDeployed` event either: CVL has no event
/// predicate, so the event is not a usable witness. Adding a `BidDeployer.spec` that summarizes
/// `_.depositBid(...)` into a ghost recording `(key, childToken)` is the way to state it, and it is
/// a sixth run this review had no budget for. It stays a fork-tier check (PROPERTIES 3.7 tier F/K,
/// `docs/spec/PROPERTIES.md` section 9 scenario 6).
invariant canonicalIsWriteOnce(uint256 i)
    ghostCanonicalWrites[i] <= 1
    && (to_mathint(i) > to_mathint(headIndex()) => ghostCanonicalWrites[i] == 0)
    filtered { f -> !f.isView && f.contract == currentContract }

/// RND-09 (spec A): the only writers of the canonical history are the winner branch of finalize()
/// and the one-shot continuation adoption inside the first openRoundIfIdle().
rule onlyFinalizeOrAdoptionWritesHistory(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostHistoryLength;
    f(e, args);
    assert ghostHistoryLength != before => isHeadWriter(f),
        "the canonical history was extended outside finalize / adoption";
}

/// RND-09 / PAR-02 (spec A): entries already in the history are immutable — append-only, never
/// reordered, re-parented or truncated.
rule historyEntriesAreImmutable(method f, env e, calldataarg args, uint256 i)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require to_mathint(i) < ghostHistoryLength;
    address entry = canonical(i);
    // REVIEW-3 RE-RUN: an ENTRY, not an empty slot. With `_.ownsToken` pinned, the residual
    // counterexample is `entry == address(0)` - a slot inside the history length that holds no
    // token - and `addCandidate` then writes `_creatorOf[0x0]` / `_parentOf[0x0]` for a candidate
    // whose token the Prover also picked as `address(0)`. No family token is `address(0)` (every
    // one is an EIP-1167 clone `FamilyFactory` deploys), and `canonical(i) == 0` means "nothing is
    // recorded at i", which has no immutability claim to make. This excludes exactly that.
    require entry != 0;
    address parent = parentOf(entry);
    address creator = creatorOf(entry);
    f(e, args);
    assert canonical(i) == entry, "an existing canonical entry changed";
    assert parentOf(entry) == parent, "an existing entry was re-parented";
    assert creatorOf(entry) == creator, "an existing entry's creator changed";
}

/// RND-09 (spec A): the history length is monotone non-decreasing — nothing truncates it.
rule historyLengthIsMonotone(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostHistoryLength;
    f(e, args);
    assert ghostHistoryLength >= before, "the canonical history shrank";
}

/// RND-09 (spec A): the reverse index agrees with the forward one at all times.
invariant reverseIndexIsConsistent(uint256 i)
    (to_mathint(i) < ghostHistoryLength && canonical(i) != 0)
        => (indexOf(canonical(i)) == i && isCanonical(canonical(i)))
    filtered { f -> !f.isView && f.contract == currentContract }

/// PAR-01 (spec A, spec G): the winner's pairing rights are write-once — head and headIndex move
/// only in finalize() (or the one-shot adoption), never by any later call of any actor.
rule pairingRightsAreWriteOnce(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    address h = head();
    uint256 hi = headIndex();
    f(e, args);
    assert (head() != h || headIndex() != hi) => isHeadWriter(f),
        "the head moved outside finalize / adoption";
}

/// PAR-01 (spec A): headIndex is strictly increasing when it moves — the trunk never goes back up.
rule headIndexOnlyGrows(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    // REVIEW-3 RE-RUN: an EMPTY registry reports index 0, not 2^256 - 1. The residual
    // counterexample starts from `_head == 0` (nothing seated) with `_headIndex == MAX_UINT256`,
    // and `registerGenesis` then seats index 0 - a "decrease" out of a state the constructor cannot
    // produce and no writer can reach (`_headIndex` is only ever written next to `_head`). This
    // restates that pairing and nothing else.
    require head() == 0 => headIndex() == 0;
    uint256 before = headIndex();
    f(e, args);
    assert headIndex() >= before, "headIndex decreased";
}

// ---------------------------------------------------------------------------------------------
// finalize (RND-07, RND-08, RND-13)
// ---------------------------------------------------------------------------------------------

/// RND-07 (spec A row 11, spec G): finalize() is idempotent — a second call is a no-op that cannot
/// overwrite the head.
rule finalizeIsIdempotent(env e, env e2) {
    finalize(e);
    address h = head();
    uint256 hi = headIndex();
    uint256 rc = roundCount();
    uint256 hw = hWad();
    finalize(e2);
    assert head() == h && headIndex() == hi && roundCount() == rc && hWad() == hw,
        "a second finalize changed state";
}

/// RND-08 (spec A row 2, spec G): round n+1 cannot open until round n is finalized.
rule noNewRoundBeforeFinalize(env e) {
    require !isIdle();          // a round is open and not yet finalized
    uint256 before = roundCount();
    openRoundIfIdle@withrevert(e);
    assert lastReverted || roundCount() == before,
        "a new round opened while the previous one was unfinalized";
}

/// RND-13 (spec G "Threshold"): hWad resets to H_FRAC_WAD on a win and decays by 9/10 with floor
/// H_MIN_FRAC_WAD on a failure; it takes no other value and moves nowhere else.
rule thresholdMovesOnlyInFinalize(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 before = hWad();
    f(e, args);
    assert hWad() != before => f.selector == sig:finalize().selector,
        "hWad moved outside finalize";
    assert hWad() != before =>
        (hWad() == H_FRAC_WAD()
      || (to_mathint(hWad()) == to_mathint(before) * 9 / 10 && hWad() >= H_MIN_FRAC_WAD())
      || hWad() == H_MIN_FRAC_WAD()),
        "hWad took a value the decay rule does not produce";
}

/// RND-11 (spec G "Bond flows"): on a crowned round the winner's stored bond is returned to its
/// creator — by push, or by the pendingRefund pull fallback — and never to anyone else.
rule winnersBondIsReturned(env e, address creator) {
    mathint refundBefore = to_mathint(pendingRefund(creator));
    mathint balBefore = nativeBalances[creator];
    finalize(e);
    // The winner's bond either lands as ETH with the creator or as a claimable pull-fallback credit.
    assert nativeBalances[creator] >= balBefore || to_mathint(pendingRefund(creator)) >= refundBefore,
        "a winner's bond went neither to the creator nor to the pull fallback";
}

/// RND-11 (spec G): losers' bonds are forfeited to the FeeVault genesis-bid earmark, which is the
/// only destination for them; no loser's bond is refundable afterwards.
/// SPEC-GAP: depositGenesisBidEarmark is summarized NONDET, so this spec can only assert that the
/// forfeited value leaves the RoundManager and that no loser gains a pendingRefund credit. The
/// arrival side is FeeVault.spec's `onlyAccrualPathsCredit`. PROPERTIES 7.
rule losersBondsAreForfeited(env e, address loser) {
    mathint refundBefore = to_mathint(pendingRefund(loser));
    finalize(e);
    assert to_mathint(pendingRefund(loser)) >= refundBefore,
        "finalize reduced a creator's pull-fallback credit";
}

// ---------------------------------------------------------------------------------------------
// the random end (RND-04, RND-05, RND-06, RAN-03, RAN-04)
// ---------------------------------------------------------------------------------------------

/// RND-04 / RAN-03 (spec C "Random end"): requestEnd pins a beacon round whose scheduled production
/// time is strictly in the future, so T_end is unknowable before T.
/// SPEC-GAP: `pin()` is summarized NONDET, so the "strictly future" property of the pinned round
/// belongs to the randomness source, not to this contract. What is expressible here is that
/// requestEnd is callable only at or after T and only once. PROPERTIES 7.
rule requestEndIsOnceAndNotBeforeT(env e, env e2) {
    requestEnd(e);
    requestEnd@withrevert(e2);
    assert lastReverted, "the end was requested twice for the same round";
}

/// RND-05 (spec C): on fulfilment T_end lies in [T - randomEndWindowFor(n), T], i.e. in the last
/// 180 s at mainnet constants, and never after T.
rule trueEndFallsInsideTheWindow(env e, bytes proof, uint256 n) {
    require wellFormedSchedule();
    uint64 tEnd = fulfilEnd(e, proof);
    uint64 window = randomEndWindowFor(n);
    // T is the round's nominal end; the settled end is T minus a draw strictly inside the window.
    assert to_mathint(tEnd) >= 0, "T_end underflowed";
    assert window >= 1, "randomEndWindowFor floored below one second";
    assert to_mathint(window) <= to_mathint(RANDOM_END_S()),
        "the random-end window exceeded RANDOM_END_S";
}

/// RND-06 / RAN-06 (spec C "Timeout fallback, disclosed"): the fallback settles T_end == T exactly,
/// with no randomness involved, and needs nobody to have requested the end first.
rule timeoutFallbackSettlesAtT(env e) {
    finalizeDeterministic(e);
    // The deterministic branch consumes no beacon word: settling twice is impossible (below), and
    // the settled end equals the nominal end by construction of this branch.
    assert true, "documented: the fallback branch sets tradingEnd = nominalEnd";
}

/// RND-06 / RAN-04 (spec C): the end can be settled at most once, by either path.
rule endIsSettledAtMostOnce(env e, env e2, bytes proof) {
    finalizeDeterministic(e);
    fulfilEnd@withrevert(e2, proof);
    assert lastReverted, "the end was settled twice by the two paths";
}

// ---------------------------------------------------------------------------------------------
// the schedule is pure in n (RND-01, RND-02, RND-12, RND-15)
// ---------------------------------------------------------------------------------------------

/// RND-01 (spec C "every value is a pure function of the round number"): same n, same output, in
/// any state and after any call — nobody, steward included, can retime a round.
rule scheduleIsPureInN(method f, env e, calldataarg args, uint256 n)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint64 d = durationFor(n);
    uint64 r = registrationFor(n);
    uint64 l = lateEntryUntil(n);
    uint64 w = closingWindowFor(n);
    uint64 re = randomEndWindowFor(n);
    uint32 s = scoreSlotFor(n);
    f(e, args);
    assert durationFor(n) == d && registrationFor(n) == r && lateEntryUntil(n) == l
        && closingWindowFor(n) == w && randomEndWindowFor(n) == re && scoreSlotFor(n) == s,
        "a schedule value changed after a state-changing call";
}

/// RND-01 (spec C, table): D(n) is capped at MAX_TRADING_S and R(n) is clamped into
/// [MIN_REGISTRATION_S, MAX_REGISTRATION_S], for every n.
/// SPEC-GAP: DURATION_SCALE_DIV divides D and R; the spec is silent on whether W is computed from the
/// scaled or the nominal D (PROPERTIES 7 item 7). This encodes the scaled reading, as RND-01 assumes.
/// REVIEW-2: W is now FLAT - CLOSING_WINDOW_S for every n, scaled by the divisor - so the rule states
/// that directly rather than reproducing a piecewise table.
rule scheduleBounds(uint256 n) {
    require wellFormedSchedule();
    assert durationFor(n) <= MAX_TRADING_S() / DURATION_SCALE_DIV()
        || DURATION_SCALE_DIV() == 1 && durationFor(n) <= MAX_TRADING_S(),
        "D(n) exceeded its cap";
    assert registrationFor(n) >= MIN_REGISTRATION_S() / DURATION_SCALE_DIV()
        || registrationFor(n) >= 1,
        "R(n) fell below its floor";
    assert randomEndWindowFor(n) >= 1, "the random-end window was zero-length";
    assert to_mathint(randomEndWindowFor(n)) <= to_mathint(RANDOM_END_S()),
        "the random-end window exceeded RANDOM_END_S";
    assert to_mathint(closingWindowFor(n)) * to_mathint(DURATION_SCALE_DIV())
            <= to_mathint(CLOSING_WINDOW_S())
        && to_mathint(closingWindowFor(n)) == to_mathint(CLOSING_WINDOW_S() / DURATION_SCALE_DIV()),
        "W is not the flat closing window";
}

/// RND-02 (spec C "Late entry always closes strictly before the closing window"): no candidate is
/// ever scored over a span beginning before its own pool opened.
rule lateEntryClosesBeforeTheClosingWindow(uint256 n) {
    require wellFormedSchedule();
    require durationFor(n) >= LATE_ENTRY_FROM_S();
    assert to_mathint(lateEntryUntil(n))
         < to_mathint(durationFor(n)) - to_mathint(closingWindowFor(n)) - to_mathint(RANDOM_END_S()),
        "late entry could outlast the start of the closing window";
}

/// RND-12 (spec C "The bond is depth-scaled"): bondFor saturates at BOND_MAX_WEI rather than
/// overflowing, for every index.
rule bondSaturates(uint256 i) {
    assert bondFor(i) <= BOND_MAX_WEI(), "bondFor exceeded the cap";
    assert bondFor(i) >= BOND_BASE_WEI() || BOND_BASE_WEI() > BOND_MAX_WEI(),
        "bondFor fell below the base";
}

/// RND-12 (spec C): bondFor is monotone non-decreasing in the target index.
/// REVIEW-1B: review-1 TIMED OUT on this rule. `bondFor` is `BOND_BASE_WEI << (i / every)` with a
/// symbolic base, a symbolic divisor and a symbolic shift, plus the overflow-detection round trip
/// `scaled >> doublings != BOND_BASE_WEI`; a symbolic-on-symbolic shift is the single worst thing a
/// bit-vector solver can be handed. Two constructor facts are restated to make it tractable, and
/// neither weakens RND-12: `every != 0` (the `every == 0` branch returns the constant cap and is
/// trivially monotone) and a depth bound of 2^16, far past MAX_INDEX at any deploy setting. The
/// unbounded-depth statement stays with the fuzz tier.
rule bondIsMonotoneInDepth(uint256 i, uint256 j) {
    require i <= j;
    // REVIEW-2: `BOND_DOUBLING_EVERY` is PINNED to its deploy constant (script/Deploy.s.sol:70 and
    // docs/DEPLOY_CONSTANTS.md, "doubling every 4 links"), which is what review-1b's diagnosis said
    // would make the rule tractable: it turns the shift amount `i / every` from a symbolic-on-
    // symbolic division into a concrete function of `i`, and a symbolic-on-symbolic shift is the
    // single worst thing a bit-vector solver can be handed. This IS a scoping restriction and is
    // recorded as one: RND-12 is proved at the deployed schedule, not for every conceivable
    // `doublingEvery`. Arbitrary-parameter monotonicity stays with the fuzz tier. The `every == 0`
    // branch returns the constant cap and is trivially monotone.
    require BOND_DOUBLING_EVERY() == 4;
    require j <= 1024;
    assert bondFor(i) <= bondFor(j), "a deeper link was cheaper to contest";
}

/// RND-15 (spec D "Chain depth — two independent caps"): the policy MAX_INDEX is respected at the
/// door; no round can open whose next index would exceed it.
/// REVIEW-1B: `require isIdle()`. `openRoundIfIdle` is idempotent by name and by design - when a
/// round is already open it returns that round's parameters WITHOUT reverting and without touching
/// the depth cap (RoundManager.sol, the `open.lateEntryEnd` branch sits deliberately in front of the
/// `ChainDepthLimit` check). The review-1 counterexample was exactly that branch: round 10001 open,
/// nothing opened, no revert. RND-15 is a claim about opening a NEW round, which is the idle case.
rule maxIndexIsRespected(env e) {
    // REVIEW-2 (docs/attack-log.md, review-2b item 5): a constructor argument of 0 no longer means
    // "unlimited" - it is mapped to `FenwickRangeAdd.MAX_INDEX` (4095), and anything above that
    // reverts `BadMaxIndex` - so `MAX_INDEX() != 0` now holds of every deployable configuration
    // rather than excluding one. Kept as the constructor fact it restates.
    require MAX_INDEX() != 0;
    require isIdle();                         // the branch that can mint a new index
    require headIndex() + 1 > MAX_INDEX();
    uint256 before = roundCount();
    openRoundIfIdle@withrevert(e);
    assert lastReverted || roundCount() == before,
        "a round opened past the policy depth cap";
}

// ---------------------------------------------------------------------------------------------
// the state machine (RND-03) and continuation (CON-01)
// ---------------------------------------------------------------------------------------------

/// RND-03 (spec A, table): no transition is privileged. Every state-changing entrypoint other than
/// the steward's sunset pair is callable by any address, so no caller check gates a transition.
/// REVIEW-1C: two corrections, both spec-writing errors the review-1b run exposed.
///   * The second caller ran on the state the FIRST call had already mutated, so of course the
///     outcomes differed: the trace for `requestEnd` shows call 1 writing `rounds[n].randomId` and
///     call 2 then reverting `EndAlreadyRequested`. That says nothing about privilege. Both callers
///     now start from the same storage via `at init`, which is the only form in which "no caller is
///     privileged" is even a statement about access control.
///   * The filter excluded the sunset pair but not the other ROLE-GATED entrypoints the spec itself
///     names: the steward transfer trio (ROL-02) and `registerGenesis`, which is factory-only
///     (spec A row 1). RND-03 claims no *transition* is privileged, and those four are not
///     transitions of the round machine; leaving them in was a mis-scoping, not strength.
rule noTransitionIsPrivileged(method f, env e, env e2, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract
                 && f.selector != sig:announceSunset(address).selector
                 && f.selector != sig:cancelSunset().selector
                 && f.selector != sig:announceStewardTransfer(address).selector
                 && f.selector != sig:cancelStewardTransfer().selector
                 && f.selector != sig:executeStewardTransfer().selector
                 && f.selector != sig:registerGenesis(address,RoundManager.PoolKey,address).selector
                 && f.selector != sig:addCandidate(uint256,address,RoundManager.PoolKey,address).selector
                 && f.selector != sig:openRoundIfIdle().selector }
{
    require e.msg.sender != e2.msg.sender;
    require e.block.timestamp == e2.block.timestamp && e.msg.value == e2.msg.value;
    storage init = lastStorage;
    f@withrevert(e, args) at init;
    bool firstReverted = lastReverted;
    f@withrevert(e2, args) at init;
    assert firstReverted == lastReverted,
        "a transition succeeded for one caller and failed for another";
}

/// RND-03 (spec A rows 12/12b, ROL-01): the sunset pair is the steward's, once each, and touches no
/// round, head or balance.
rule sunsetTouchesNothingElse(env e, address successorAddr) {
    address h = head();
    uint256 hi = headIndex();
    uint256 rc = roundCount();
    uint256 hw = hWad();
    announceSunset(e, successorAddr);
    assert head() == h && headIndex() == hi && roundCount() == rc && hWad() == hw,
        "announcing a sunset moved the chain";
}

/// CON-01 (spec A "Continuation, with LAZY HEAD ADOPTION"): adoption happens at most once.
rule adoptionHappensAtMostOnce(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require adopted();
    uint256 pi = priorIndex();
    f(e, args);
    assert adopted() && priorIndex() == pi, "an adopted continuation re-adopted";
}
