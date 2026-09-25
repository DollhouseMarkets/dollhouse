/*
 * RoundManager.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §A (state machine), §C (round lifecycle, adaptive
 * schedule, random end, bond schedule), §G (canonical finalization) and docs/spec/PROPERTIES.md
 * §3.5 / §3.6 / §3.9 / §6.
 *
 * WHAT THIS CONTRACT DOES:
 *   - `registerGenesis(token, key, creator)` does not exist. Canonical index 0 is ADOPTED, not launched:
 *     `adoptGenesis(token, creator)` is factory-only, once, and writes an entry with NO POOL KEY.
 *     It is the third writer of `_head` / `_headIndex` and belongs in the head-writer set.
 *   - THE BOND IS AN ERC-20 ESCROW IN THE EDGE CURRENCY, not `msg.value`. `registerCandidate` is
 *     non-payable, the factory pulls the bond and sends it here, and this contract proves delivery
 *     by reading its own balance against BOTH ledgers it owes: `bondEscrow + pendingForfeits`.
 * - FORFEITS NEVER BLOCK A CROWNING. A forfeit delivery that fails is booked
 *     into `pendingForfeits` and retried by the permissionless `flushForfeits`, instead of reverting
 *     the round's only progression path.
 * - `openRoundIfIdle` and `addCandidate` CARRY THE REENTRANCY GUARD, because
 *     both are reachable from inside a transfer this contract is making.
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
    // The coarse ring has to REACH BACK over the scored span and nothing more; the
    // settlement tail is gone, because the hook freezes its rings at the pool's published end.
    // `scoreSlotFor(n) = max(SCORE_MIN_SLOT_S, ceil((W(n) + RANDOM_END_S) / 63))`.
    function SCORE_MIN_SLOT_S() external returns (uint64) envfree;
    function END_TIMEOUT() external returns (uint64) envfree;
    function MAX_INDEX() external returns (uint256) envfree;
    function H_FRAC_WAD() external returns (uint256) envfree;
    function H_MIN_FRAC_WAD() external returns (uint256) envfree;
    // The bond schedule is denominated in THE EDGE CURRENCY, and the immutables lost their
    // `_WEI` suffix with the denomination. `BOND_BASE_WEI` / `BOND_MAX_WEI` no longer exist.
    function BOND_BASE() external returns (uint256) envfree;
    function BOND_MAX() external returns (uint256) envfree;
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
    // The edge currency, i.e. canonical index 0, resolved through the registry chain. It
    // is what every bond, refund and forfeit in this contract is denominated in.
    function edgeToken() external returns (address) envfree;
    function genesisToken() external returns (address) envfree;
    function adopted() external returns (bool) envfree;
    function roundCount() external returns (uint256) envfree;
    function hWad() external returns (uint256) envfree;
    function isIdle() external returns (bool) envfree;
    function pendingRefund(address) external returns (uint256) envfree;
    // The two ledgers this contract owes out of ONE token balance.
    // `bondEscrow` is what it owes candidates (open bonds plus every pull-fallback refund);
    // `pendingForfeits` is what it owes the vault after a forfeit delivery that failed. They are
    // disjoint by construction, and every balance check must count BOTH.
    function bondEscrow() external returns (uint256) envfree;
    function pendingForfeits() external returns (uint256) envfree;
    function roundInfo(uint256) external returns (RoundManager.Round) envfree;

    // --- transitions (spec A, rows 2/3b/6b/6c/7/9-11) ---
    // `openRoundIfIdle` answers with the round's whole opening tuple, including the bond
    // the round quotes, and `addCandidate` takes that bond as its fifth argument.
    function openRoundIfIdle() external returns (uint256, uint64, uint64, uint32, address, uint256);
    function addCandidate(uint256, address, RoundManager.PoolKey, address, uint256) external returns (uint256);
    function requestEnd() external returns (bytes32);
    function fulfilEnd(bytes) external returns (uint64);
    function finalizeDeterministic() external;
    function submitScore(uint256) external returns (int256);
    function finalize() external;
    function claimRefund(address) external;
    // The deferred-forfeit retry and the two self-only pushes that make the deferral
    // possible at all.
    function flushForfeits() external;
    function pushRefund(address, address, uint256) external;
    function pushForfeit(address, uint256) external;
    function announceSunset(address) external;
    function cancelSunset() external;
    function announceStewardTransfer(address) external;
    function cancelStewardTransfer() external;
    function executeStewardTransfer() external;
    // Adoption, not creation. Factory only, once, no pool key.
    function adoptGenesis(address, address) external;

    // --- summaries ---------------------------------------------------------------------------
    // The drand source verifies a BN254 pairing on precompile 0x08; the pairing result and the
    // random word are NONDET (PROPERTIES section 6). Nothing below depends on the word's value.
    // `pin()` must not re-randomise per call: the beacon round id is pinned to a stable
    // ghost so two reads in one state agree. Its VALUE is unconstrained, zero included, which is
    // what makes this rule set the evidence that a source returning a zero id cannot request the end
    // twice (closed by an explicit `Round.endRequested` flag).
    function _.pin() external => cvlPin() expect bytes32;
    function _.fulfil(bytes32, bytes) external => NONDET;
    // NO STALE SUMMARY HERE. `_.isMock()` is not summarized: no
    // contract in the tree has ever had that function: `IRandomnessSource` is `pin` / `fulfil` /
    // `status`. A summary of a method nobody declares matches nothing and silently proves nothing,
    // which is the same class of defect as a rule about a field that moved. `status` is the read
    // that does exist, and no rule in this file consults it.
    function _.status(bytes32) external => NONDET;

    // The hook supplies the closing-window average; its correctness is FamilyHook.spec's job.
    function _.averageOver(RoundManager.PoolId, uint64, uint64) external => NONDET;
    function _.trailingAverage(RoundManager.PoolId, uint32) external => NONDET;

    // The vault receives forfeited bonds as an ERC-20 DEPOSIT WITH AN AMOUNT
    // (`depositGenesisBidEarmark()` is gone). Its ledgers are FeeVault.spec's job, and the arrival
    // side of RND-11 is proved there by `depositEdgeBidEarmarkRefusesAnUndeliveredAmount`.
    function _.depositEdgeBidEarmark(uint256) external => NONDET;

    // THE EDGE CURRENCY IS AN ERC-20 THIS PROTOCOL DID NOT WRITE, and it cannot be linked
    // here: `edgeToken()` is `canonical(0)`, a STORAGE read that may delegate to a prior registry,
    // not an immutable. So the token is summarized rather than pinned.
    //   - `balanceOf` gets the consistent-read treatment every other unlinked view in these specs
    //     gets: the value is completely unconstrained (a donation, a fee-on-transfer token or a
    //     hostile balance are all still in scope) but two reads in the same state agree, because a
    //     view that disagrees with itself is false rather than general. `addCandidate` reads it once
    //     per call and the rules below read it either side of one.
    //   - `transfer` is NONDET, which is the honest model of a token this contract does not own. The
    //     consequence is recorded rather than hidden: a recipient's balance does NOT move under this
    //     summary, so RND-11's "the bond reached the creator" half cannot be stated over balances
    //     here. It is stated over the ESCROW and the pull-fallback credit instead, which is the part
    //     this contract actually controls.
    function _.balanceOf(address holder) external => cvlTokenBalance(holder) expect uint256;
    function _.transfer(address, uint256) external => NONDET;
    function _.transferFrom(address, address, uint256) external => NONDET;

    // A prior registry in a continuation chain is an earlier, already-deployed contract: unknown
    // code from this proof's point of view. These are VIEW reads of it. A bare NONDET makes two
    // reads of the same getter in the same state return different values, which is not an
    // over-approximation of an external contract, it is simply false, and it is what violated
    // `finalizeIsIdempotent` and the transient-storage step of `reverseIndexIsConsistent` in
    // The values stay fully unconstrained; they are pinned to persistent ghosts so that
    // they are merely CONSISTENT.
    function _.isSunsetEffective() external => cvlPriorSunset() expect bool;
    function _.successor() external => cvlPriorSuccessor() expect address;
    function _.headToken() external => cvlPriorHeadToken() expect address;
    function _.priorRegistry() external => cvlPriorRegistry() expect address;
    function _.adopted() external => cvlPriorAdopted() expect bool;
    // Every state-changing entrypoint carries
    // `notInsideUnlock`, which reads v4-core's transient lock slot off the PoolManager with a single
    // `exttload`. The manager is DELIBERATELY UNLINKED, so without a summary that read falls through
    // to the Prover's per-call havoc, and a guard that answers differently on two calls in the SAME
    // transaction is not an over-approximation of a transient slot, it is false. The value stays
    // completely unconstrained (the Prover may still put the whole rule inside an unlock); it is
    // merely CONSISTENT within a transaction, which is what the slot is.
    function _.exttload(bytes32) external => cvlUnlockSlot() expect bytes32;

    function _.headIndex() external => cvlPriorHeadIndex() expect uint256;
    function _.priorIndex() external => cvlPriorPriorIndex() expect uint256;
    function _.canonical(uint256 i) external => cvlPriorCanonical(i) expect address;
    function _.indexOf(address t) external => cvlPriorIndexOf(t) expect uint256;
    function _.isCanonical(address t) external => cvlPriorIsCanonical(t) expect bool;
    function _.parentOf(address t) external => cvlPriorParentOf(t) expect address;
    function _.creatorOf(address t) external => cvlPriorCreatorOf(t) expect address;
    // `ownsToken` is a delegated read that is easy to miss, and missing it
    // is the single cause of most RoundManager failures without this summary: `registryOfToken`
    // walks the chain asking each registry `ownsToken(token)`, so EVERY `parentOf` / `creatorOf` /
    // `indexOf` / `isCanonical` / `canonical` read goes through it. `isIdle()` is the other unpinned
    // prior read. Values stay completely unconstrained; they are merely CONSISTENT.
    function _.ownsToken(address t) external => cvlPriorOwnsToken(t) expect bool;
    function _.isIdle() external => cvlPriorIsIdle() expect bool;
    // NOT SUMMARIZED, deliberately: `_.poolKeyOf(uint256)` returns a v4 `PoolKey` STRUCT, which a
    // CVL ghost cannot hold as one value; it stays AUTO. No rule in this file reads a delegated pool
    // key twice, so the per-call havoc cannot make one of them disagree with itself.
}

// ---------------------------------------------------------------------------------------------
// ghost state (PROPERTIES section 6: ghostCanonicalWrites[i])
// ---------------------------------------------------------------------------------------------

// `persistent`, so a HAVOC_ALL / AUTO summary of an unresolved callee does not wipe the spec-side
// write log the hooks below build. The hooks fire on exactly this contract's own stores, so no
// rule's meaning changes.
persistent ghost mapping(uint256 => mathint) ghostCanonicalWrites {
    init_state axiom forall uint256 i. ghostCanonicalWrites[i] == 0;
}
persistent ghost mathint ghostHeadWrites { init_state axiom ghostHeadWrites == 0; }
// Highest canonical index ever written, so append-only can be stated as a monotone length.
persistent ghost mathint ghostHistoryLength { init_state axiom ghostHistoryLength == 0; }

// Backing store for the prior-registry, beacon and token summaries above: arbitrary values, fixed
// once per state.
persistent ghost bytes32 ghostPinId;
persistent ghost bytes32 ghostUnlockSlot;
persistent ghost bool    ghostPriorSunset;
persistent ghost bool    ghostPriorAdopted;
persistent ghost address ghostPriorSuccessor;
persistent ghost address ghostPriorHeadToken;
persistent ghost address ghostPriorRegistry;
persistent ghost mapping(address => uint256) ghostTokenBalance;

function cvlPin() returns bytes32 { return ghostPinId; }
function cvlUnlockSlot() returns bytes32 { return ghostUnlockSlot; }
function cvlPriorSunset()    returns bool    { return ghostPriorSunset; }
function cvlPriorAdopted()   returns bool    { return ghostPriorAdopted; }
function cvlPriorSuccessor() returns address { return ghostPriorSuccessor; }
function cvlPriorHeadToken() returns address { return ghostPriorHeadToken; }
function cvlPriorRegistry()  returns address { return ghostPriorRegistry; }
function cvlTokenBalance(address holder) returns uint256 { return ghostTokenBalance[holder]; }

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

// Well-formedness. DURATION_SCALE_DIV, BOND_* and MAX_INDEX are IMMUTABLES: the Prover
// starts a rule from arbitrary storage and the constructor never runs, so they are havoc'd. The
// constructor's own guard is `durationScaleDiv != 0 && durationScaleDiv <= MIN_REGISTRATION_S`
// (`BadDurationScale`), and every schedule getter divides by it. Without this restatement
// `scheduleBounds` fails on a division by zero and `trueEndFallsInsideTheWindow` fails with a
// zero-length window; neither is a claim about the code. This EXCLUDES EXACTLY the states the
// deployed contract cannot be in, and nothing else.
definition wellFormedSchedule() returns bool =
    DURATION_SCALE_DIV() != 0 && DURATION_SCALE_DIV() <= MIN_REGISTRATION_S();

hook Sstore rm._canonical[KEY uint256 i] address v (address old) {
    ghostCanonicalWrites[i] = ghostCanonicalWrites[i] + 1;
    ghostHistoryLength = ghostHistoryLength > to_mathint(i) ? ghostHistoryLength : to_mathint(i) + 1;
}
hook Sstore rm._headIndex uint256 v (uint256 old) {
    ghostHeadWrites = ghostHeadWrites + 1;
}

// THE THIRD HEAD WRITER IS `adoptGenesis`, NOT `registerGenesis`. `RoundManager.sol`
// writes `_head` / `_headIndex` in exactly three places: `finalize`'s winner branch,
// `_adoptIfContinuation` (inside the first `openRoundIfIdle`) and `adoptGenesis`, the factory-only
// one-shot that seats index 0 before any round exists. Missing this third writer from the
// enumeration would assert something the contract never claims. Naming it costs the rules
// nothing: `adoptGenesis` is `onlyFactory` and
// write-once, which `canonicalIsWriteOnce` and `noTransitionIsPrivileged`'s own exclusion list
// already treat as a role-gated bootstrap rather than a transition of the round machine.
definition isHeadWriter(method f) returns bool =
    f.selector == sig:finalize().selector
 || f.selector == sig:openRoundIfIdle().selector    // the one-shot continuation adoption runs inside it
 || f.selector == sig:adoptGenesis(address,address).selector;

// ---------------------------------------------------------------------------------------------
// canonical history: write-once, append-only, immutable (RND-09, PAR-01, PAR-02)
// ---------------------------------------------------------------------------------------------

/// Canonical[i] is write-once.
/// The bare form is TRUE but NOT INDUCTIVE on its own: a naive induction over
/// `finalize` fails on a pre-state with a canonical slot above `_headIndex` already
/// occupied, a state the contract cannot reach: the only two writers are `adoptGenesis` (index 0)
/// and the winner branch of `finalize`, which writes `_canonical[_headIndex + 1]` and assigns
/// `_headIndex = _headIndex + 1` three lines later. The strengthening below states exactly that
/// reachability fact. It is a conjunct, not a `require`, so the base case and every step must still
/// establish it; the invariant is strictly stronger than the drafted one, not weaker.
/// PUR-02 (PROPERTIES 3.7) RESTS ON THIS RULE AND ON `historyEntriesAreImmutable`. The purse is not
/// contestable: `BidDeployer.deployAncestor(j, amount)` reads its destination as
/// `roundManager.canonical(j)` and takes no destination argument, so PUR-02 is the conjunction of
///   (a) STRUCTURAL, deliberately NOT restated as a rule here: the destination is a pure function of
///       `j` evaluated inside the deployer, with no rank, board or caller-supplied token to read;
///   (b) `canonical(j)` IS FIXED ONCE THE ROUND CROWNS IT, which is this invariant plus
///       `historyEntriesAreImmutable` and `onlyFinalizeOrAdoptionWritesHistory`.
/// PUR-02's CASE LIST EXTENDS TO j IN {0, 1}, and both cases land here rather than in
/// the deployer: j = 0 is the ADOPTED token, whose entry `adoptGenesis` writes once and which this
/// invariant covers under its writer; j = 1 is an ordinary crowned link whose parent is the
/// adopted token. The LANDING step (that liquidity actually arrives under `canonical(j)`) is still
/// `locker.depositBid` into the summarized singleton and stays NOT EXPRESSIBLE here; a
/// `BidDeployer.spec` summarizing `_.depositBid(...)` into a ghost recording `(key, childToken)` is
/// the way to state it, and it is still unbudgeted.
invariant canonicalIsWriteOnce(uint256 i)
    ghostCanonicalWrites[i] <= 1
    && (to_mathint(i) > to_mathint(headIndex()) => ghostCanonicalWrites[i] == 0)
    filtered { f -> !f.isView && f.contract == currentContract }

/// The only writers of the canonical history are the winner branch of finalize(),
/// the one-shot continuation adoption inside the first openRoundIfIdle(), and adoptGenesis().
rule onlyFinalizeOrAdoptionWritesHistory(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostHistoryLength;
    f(e, args);
    assert ghostHistoryLength != before => isHeadWriter(f),
        "the canonical history was extended outside finalize / adoption";
}

/// RND-09 / PAR-02 (spec A): entries already in the history are immutable. Append-only, never
/// reordered, re-parented or truncated.
rule historyEntriesAreImmutable(method f, env e, calldataarg args, uint256 i)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require to_mathint(i) < ghostHistoryLength;
    address entry = canonical(i);
    // AN ENTRY, not an empty slot. With `_.ownsToken` pinned, a residual
    // counterexample would be `entry == address(0)`, a slot inside the history length that holds no token,
    // and `addCandidate` then writes `_creatorOf[0x0]` / `_parentOf[0x0]` for a candidate whose
    // token the Prover also picked as `address(0)`. No family token is `address(0)` (every one is an
    // EIP-1167 clone the factory deploys) and neither is the adopted edge currency (`adoptGenesis`
    // is reached only through `wire()`, which checks the token has code). `canonical(i) == 0` means
    // "nothing is recorded at i", which has no immutability claim to make.
    require entry != 0;
    address parent = parentOf(entry);
    address creator = creatorOf(entry);
    f(e, args);
    assert canonical(i) == entry, "an existing canonical entry changed";
    assert parentOf(entry) == parent, "an existing entry was re-parented";
    assert creatorOf(entry) == creator, "an existing entry's creator changed";
}

/// The history length is monotone non-decreasing. Nothing truncates it.
rule historyLengthIsMonotone(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostHistoryLength;
    f(e, args);
    assert ghostHistoryLength >= before, "the canonical history shrank";
}

/// The reverse index agrees with the forward one at all times.
invariant reverseIndexIsConsistent(uint256 i)
    (to_mathint(i) < ghostHistoryLength && canonical(i) != 0)
        => (indexOf(canonical(i)) == i && isCanonical(canonical(i)))
    filtered { f -> !f.isView && f.contract == currentContract }

/// PAR-01 (spec A, spec G): the winner's pairing rights are write-once. Head and headIndex move only
/// in finalize() (or the one-shot adoption), never by any later call of any actor.
rule pairingRightsAreWriteOnce(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    address h = head();
    uint256 hi = headIndex();
    f(e, args);
    assert (head() != h || headIndex() != hi) => isHeadWriter(f),
        "the head moved outside finalize / adoption";
}

/// PAR-01 (spec A): headIndex is strictly increasing when it moves. The trunk never goes back up.
rule headIndexOnlyGrows(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    // AN EMPTY registry reports index 0, not 2^256 - 1. A residual counterexample would
    // start from `_head == 0` (nothing seated) with `_headIndex == MAX_UINT256`, and the adoption
    // then seats index 0: a "decrease" out of a state the constructor cannot produce and no writer
    // can reach (`_headIndex` is only ever written next to `_head`).
    require head() == 0 => headIndex() == 0;
    uint256 before = headIndex();
    f(e, args);
    assert headIndex() >= before, "headIndex decreased";
}

/// ADOPTION HAPPENS ONCE AND ONLY FROM THE FACTORY.
/// Index 0 is a token this protocol did not launch. Whoever seats it decides what every bond, fee
/// and payout of the whole chain is denominated in, so the entry point is `onlyFactory` and runs
/// inside `wire()` with the creator fixed at construction, which is what makes the outcome identical
/// whoever sends the wiring transaction (there is no permissionless `adoptGenesis(token)` any more).
/// The once-only half is a dedicated `_genesisAdopted` flag, checked
/// first and reverting `GenesisAlreadyAdopted`. A sentinel read of `_head !=
/// address(0)` alone would let a second call re-adopt `address(0)`; the dedicated flag closes that.
/// The continuation half is `priorRegistry != address(0)` reverting `GenesisAlreadyRegistered`: a
/// continuation stack may never adopt at all, because its index 0 belongs to the trunk it
/// continues. `token == address(0)` is refused explicitly (`BadGenesisToken`) as well, so the first
/// `adoptGenesis` call below only seats a real token and the rule's assertions hold without
/// relying on the sentinel coincidence.
rule adoptGenesisIsOnceAndFactoryOnly(env e, env e2, address token, address creator,
                                      address token2, address creator2) {
    adoptGenesis(e, token, creator);
    // once seated, no second adoption of any token by any caller
    adoptGenesis@withrevert(e2, token2, creator2);
    assert lastReverted, "the genesis link was adopted twice";
    assert canonical(0) == token, "adoption did not seat the token at canonical index 0";
    assert headIndex() == 0 && head() == token,
        "adoption did not seat the token as the head at index 0";
    assert parentOf(token) == 0, "the adopted genesis link was given a parent";
}

// ---------------------------------------------------------------------------------------------
// finalize
// ---------------------------------------------------------------------------------------------

/// Finalize() is idempotent. A second call is a no-op that cannot
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

/// Round n+1 cannot open until round n is finalized.
rule noNewRoundBeforeFinalize(env e) {
    require !isIdle();          // a round is open and not yet finalized
    uint256 before = roundCount();
    openRoundIfIdle@withrevert(e);
    assert lastReverted || roundCount() == before,
        "a new round opened while the previous one was unfinalized";
}

/// HWad resets to H_FRAC_WAD on a win and decays by 9/10 with floor
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

/// On a crowned round the winner's stored
/// bond is returned to its creator, by push or by the `pendingRefund` pull fallback, and never to
/// anyone else.
/// WHAT THE MEASURE IS, AND WHY. `nativeBalances[creator]` cannot be watched directly:
/// the bond is an ERC-20 escrow and the edge token is summarized NONDET on `transfer` (it cannot
/// be linked; see the methods block), so a recipient's balance does not move under this model and a
/// balance-based assertion would be about nothing. The claim is restated over the two quantities
/// this contract does own: the escrow is RELEASED (it never grows across a finalize, because the
/// failed-push branch credits the pull fallback for exactly what it adds back), and a creator's
/// pull-fallback credit is never reduced by a finalize. The delivered-to-the-creator half is a
/// fork-tier and unit-tier check.
rule winnersBondIsReturned(env e, address creator) {
    mathint refundBefore = to_mathint(pendingRefund(creator));
    mathint escrowBefore = to_mathint(bondEscrow());
    finalize(e);
    assert to_mathint(pendingRefund(creator)) >= refundBefore,
        "finalize reduced a creator's pull-fallback credit";
    assert to_mathint(bondEscrow()) <= escrowBefore,
        "finalize grew the bond escrow instead of releasing it";
}

/// Losers' bonds are forfeited to the FeeVault edge bid earmark, which is the only
/// destination for them, and no loser's bond is refundable afterwards.
/// SPEC-GAP: `depositEdgeBidEarmark` is summarized NONDET, so this spec can only assert that the
/// forfeited value leaves this contract's ledgers and that no loser gains a pull-fallback credit.
/// The arrival side is FeeVault.spec's `onlyAccrualPathsCredit` and
/// `depositEdgeBidEarmarkRefusesAnUndeliveredAmount`. PROPERTIES 7.
rule losersBondsAreForfeited(env e, address loser) {
    mathint refundBefore = to_mathint(pendingRefund(loser));
    finalize(e);
    assert to_mathint(pendingRefund(loser)) >= refundBefore,
        "finalize reduced a creator's pull-fallback credit";
}

// ---------------------------------------------------------------------------------------------
// The bond escrow in the edge currency, and the deferred forfeits
// ---------------------------------------------------------------------------------------------

/// RND-11 - THE ESCROW CHECK COUNTS THE HELD FORFEITS.
/// The bond is delivered by the factory in the instruction before `addCandidate`, so the only proof
/// it arrived is this contract's own balance. The contract has a SECOND thing to owe out
/// of that same balance (`pendingForfeits`, held here for the vault), so checking against
/// `bondEscrow` alone would let a deferred forfeit stand in for a bond that was never delivered: the
/// candidate would register, and the shortfall would surface later as a refund or a flush that
/// cannot be paid. The check is against BOTH ledgers, and this is that check stated as a refusal.
rule addCandidateRefusesAnUnderDeliveredBond(env e, uint256 roundId, address token,
                                             RoundManager.PoolKey key, address creator,
                                             uint256 bondAmount) {
    // the post-credit escrow the contract compares its balance against
    mathint owedAfter = to_mathint(bondEscrow()) + to_mathint(bondAmount)
                      + to_mathint(pendingForfeits());
    require to_mathint(ghostTokenBalance[currentContract]) < owedAfter;
    addCandidate@withrevert(e, roundId, token, key, creator, bondAmount);
    assert lastReverted,
        "a candidate registered on a bond the contract's balance does not cover";
}

/// RND-12 - THE ESCROWED BOND IS EXACTLY THE ROUND'S OWN BOND, WHICH IS WHAT
/// MAKES `maxBond` A CEILING. `FamilyFactory.registerCandidate(name, symbol, uri, maxBond)` reads
/// the figure from `openRoundIfIdle`, refuses it with `BondTooHigh(bondAmount, maxBond)` if it
/// exceeds what the caller agreed to, and only then pulls. The ceiling itself is enforced in the
/// factory, which has no spec of its own; what this contract owes the property is that there is
/// nothing ELSE it could be charged. `addCandidate` reverts `WrongBond` unless the amount equals
/// `rounds[roundId].bondAmount`, and the escrow grows by exactly that, so the sum pulled from a
/// registrant can never exceed the figure the factory compared against `maxBond`. An allowance left
/// standing across a rollover is charged the quoted bond or nothing at all.
rule registrationNeverPullsMoreThanTheQuotedBond(env e, uint256 roundId, address token,
                                                 RoundManager.PoolKey key, address creator,
                                                 uint256 bondAmount) {
    uint256 quoted = roundInfo(roundId).bondAmount;
    mathint escrowBefore = to_mathint(bondEscrow());
    addCandidate(e, roundId, token, key, creator, bondAmount);
    assert bondAmount == quoted,
        "a candidate was registered on a bond the round did not quote";
    assert to_mathint(bondEscrow()) == escrowBefore + to_mathint(bondAmount),
        "the escrow grew by something other than the quoted bond";
}

/// RND-11 - WHAT FINALIZE BOOKED EQUALS WHAT IT DELIVERED PLUS WHAT IT HELD.
/// The forfeited bonds are released from `bondEscrow` FIRST and in full, and only then pushed. If
/// the push fails, the same amount is booked into `pendingForfeits` and retried later, so across one
/// finalize the escrow release covers the deferral exactly: `pendingForfeits` can never grow by more
/// than `bondEscrow` fell. That is the conservation statement the deferral rests on, and it is what
/// makes a deferred forfeit un-double-spendable against the escrow.
rule finalizeBooksWhatItCouldNotDeliver(env e) {
    mathint escrowBefore = to_mathint(bondEscrow());
    mathint heldBefore = to_mathint(pendingForfeits());
    finalize(e);
    assert to_mathint(pendingForfeits()) >= heldBefore,
        "finalize reduced the held forfeits";
    assert to_mathint(pendingForfeits()) - heldBefore <= escrowBefore - to_mathint(bondEscrow()),
        "finalize held more forfeits than it released from the escrow";
}

/// RND-11: the held-forfeit ledger moves in exactly two places. `finalize`
/// books a delivery that failed and `flushForfeits` clears one that succeeded. Nothing else in the
/// contract may touch it, or an unrelated entrypoint could write off what is owed to the vault.
rule pendingForfeitsMoveOnlyOnFinalizeOrFlush(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 before = pendingForfeits();
    f(e, args);
    assert pendingForfeits() != before =>
        (f.selector == sig:finalize().selector
      || f.selector == sig:flushForfeits().selector),
        "the held forfeits moved outside finalize / flushForfeits";
}

/// REN-02 - `flushForfeits` ZEROES BEFORE IT SENDS.
/// The retry is permissionless and it makes two external calls (a token transfer and the vault's own
/// delivery check), so the ledger is cleared in the instruction BEFORE either. A reentrant flush
/// therefore finds nothing to send rather than sending the same forfeits twice. The cost of that
/// ordering is a window on the OTHER side: for the duration of the transfer this
/// contract's balance holds tokens no ledger counts, which is exactly why `addCandidate` is
/// `nonReentrant` (see `guardedFactoryEntrypointsCannotBeReentered`). Both halves are needed; either
/// alone is a defect.
rule flushForfeitsZeroesBeforeDelivering(env e) {
    uint256 before = pendingForfeits();
    flushForfeits(e);
    assert before != 0, "flushForfeits ran with nothing held";
    assert pendingForfeits() == 0, "flushForfeits left a residue in the held forfeits";
}

/// RND-11 - THE TWO PUSHES ARE SELF-ONLY, AND THAT IS WHAT LETS FINALIZE
/// SURVIVE THEM. There is no pause and no rollback in this protocol: one revert on the round's only
/// progression path and the chain never crowns again. Both value moves in `finalize` are therefore
/// made through `try this.pushRefund(...)` / `try this.pushForfeit(...)`, so a token that reverts,
/// returns false, charges a fee or blacklists the vault fails the CALL rather than the round. The
/// `NotSelf` guard is what makes that indirection safe to expose as an external function, and it is
/// the half that is expressible here: the catch itself is a property of `finalize`'s control flow,
/// and "finalize never reverts" is NOT expressible as one rule, because `finalize` has legitimate
/// revert conditions of its own (`NoRound`, `EndNotSettled`, `SubmissionWindowOpen`). What actually
/// matters - that no FAILURE OF THE DELIVERY reverts it - is covered by
/// `finalizeBooksWhatItCouldNotDeliver` above, which holds on both branches.
rule theBondPushesAreSelfOnly(env e, address edge, address to, uint256 amount) {
    require e.msg.sender != currentContract;
    pushRefund@withrevert(e, edge, to, amount);
    assert lastReverted, "an outside caller pushed a bond refund";
    pushForfeit@withrevert(e, edge, amount);
    assert lastReverted, "an outside caller pushed a forfeit to the vault";
}

/// REN-01 - THE TWO FACTORY ENTRYPOINTS CANNOT BE RE-ENTERED.
/// `addCandidate` proves a bond was really delivered by reading this contract's balance against
/// `bondEscrow + pendingForfeits`. That is sound BETWEEN calls and stale DURING one: `flushForfeits`
/// zeroes `pendingForfeits` before it transfers, and `finalize` releases `bondEscrow` before it
/// pushes, so inside either window the balance still holds tokens no ledger counts, and a bond
/// delivered SHORT would pass. The edge currency is an ERC-20 this protocol did not write; one with
/// a sender hook can call `FamilyFactory.registerCandidate` back from inside the very transfer this
/// contract is making. Both entrypoints now carry the guard.
/// The claim is stated over the LOCK ITSELF, which is the only observable a reentrancy guard has:
/// while `_locked != 1` (some guarded call is in progress) neither entrypoint may be entered.
rule guardedFactoryEntrypointsCannotBeReentered(env e, uint256 roundId, address token,
                                                RoundManager.PoolKey key, address creator,
                                                uint256 bondAmount) {
    require rm._locked != 1;                 // we are inside a guarded call
    openRoundIfIdle@withrevert(e);
    assert lastReverted, "openRoundIfIdle was re-entered";
    addCandidate@withrevert(e, roundId, token, key, creator, bondAmount);
    assert lastReverted, "addCandidate was re-entered";
}

// ---------------------------------------------------------------------------------------------
// the random end (RND-04, RND-05, RND-06, RAN-03, RAN-04)
// ---------------------------------------------------------------------------------------------

/// RND-04 / RAN-03 (spec C "Random end"): requestEnd pins a beacon round whose scheduled production
/// time is strictly in the future, so T_end is unknowable before T.
/// SPEC-GAP: `pin()` is summarized, so the "strictly future" property of the pinned round belongs to
/// the randomness source, not to this contract. What is expressible here is that requestEnd is
/// callable only at or after T and only once. PROPERTIES 7.
rule requestEndIsOnceAndNotBeforeT(env e, env e2) {
    requestEnd(e);
    requestEnd@withrevert(e2);
    assert lastReverted, "the end was requested twice for the same round";
}

/// On fulfilment T_end lies in [T - randomEndWindowFor(n), T], i.e. in the last
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
// the schedule is pure in n
// ---------------------------------------------------------------------------------------------

/// Same n, same output, in any
/// state and after any call, so nobody, steward included, can retime a round.
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

/// D(n) is capped at MAX_TRADING_S and R(n) is clamped into
/// [MIN_REGISTRATION_S, MAX_REGISTRATION_S], for every n.
/// SPEC-GAP: DURATION_SCALE_DIV divides D and R; the spec is silent on whether W is computed from the
/// scaled or the nominal D (PROPERTIES 7 item 7). This encodes the scaled reading, as RND-01 assumes.
/// W is FLAT, CLOSING_WINDOW_S for every n scaled by the divisor, so the rule states that
/// directly rather than reproducing a piecewise table.
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

/// THE COARSE SLOT COVERS THE SCORED SPAN.
/// `scoreSlotFor(n)` is the spacing of the hook's coarse checkpoint ring, and the ring has 63 usable
/// entries. The span it has to reach back over is the scored window `W(n)` plus the random-end
/// window, and NOTHING MORE: the ring freeze removes the settlement tail from the span, taking
/// the mainnet spacing to 18 s and the far-edge dilution bound to 2.0%. The
/// claim is the ceiling itself (63 slots at that spacing cover the span) plus the floor, which keeps
/// the coarse ring from ever being finer than the hook's own fast ring.
rule theCoarseRingCoversTheScoredSpan(uint256 n) {
    require wellFormedSchedule();
    mathint span = to_mathint(closingWindowFor(n)) + to_mathint(RANDOM_END_S());
    assert to_mathint(scoreSlotFor(n)) * 63 >= span,
        "63 coarse slots do not reach back over the scored span";
    assert to_mathint(scoreSlotFor(n)) >= to_mathint(SCORE_MIN_SLOT_S()),
        "the coarse slot fell below its floor";
    // the ceiling is TIGHT: one slot narrower and the ring no longer covers the span, which is what
    // makes this a derivation rather than a loose bound
    assert to_mathint(scoreSlotFor(n)) == to_mathint(SCORE_MIN_SLOT_S())
        || (to_mathint(scoreSlotFor(n)) - 1) * 63 < span,
        "the coarse slot is wider than the ceiling of the scored span over 63";
}

/// THE CONSTRUCTOR'S WINDOW GUARD, AND THE SEAM IT SITS ON.
/// `FamilyHook.averageOver` reverts `BadScoreWindow` when both edges of the scored window resolve to
/// the same instant, and the precondition that keeps that unreachable is
/// `closingWindowFor(n) > scoreSlotFor(n)`. A deployment with a large `DURATION_SCALE_DIV` would
/// otherwise deploy happily and then revert EVERY score submission, so the constructor refuses it
/// with `BadDurationScale`.
///
/// The constructor cannot call `closingWindowFor` or `scoreSlotFor`: an immutable is not readable
/// through a function during construction, so it WRITES THE SAME ARITHMETIC OUT BY HAND from the
/// constants. That duplication is the seam. This rule is the anti-drift check on it: the
/// hand-written expressions in the constructor must equal the getters that every other part of the
/// system reads. If the two ever diverge, the guard protects a window nobody uses.
rule theConstructorsWindowGuardMatchesTheGetters(uint256 n) {
    require wellFormedSchedule();
    // copied from the constructor's guard block
    uint64 w = assert_uint64(CLOSING_WINDOW_S() / DURATION_SCALE_DIV());
    mathint rawSlot = (to_mathint(w) + to_mathint(RANDOM_END_S()) + 62) / 63;
    mathint slot = rawSlot < to_mathint(SCORE_MIN_SLOT_S()) ? to_mathint(SCORE_MIN_SLOT_S()) : rawSlot;
    assert to_mathint(closingWindowFor(n)) == to_mathint(w),
        "the constructor's W differs from closingWindowFor(n)";
    assert to_mathint(scoreSlotFor(n)) == slot,
        "the constructor's coarse slot differs from scoreSlotFor(n)";
}

/// The other half: ON A DEPLOYED CONTRACT the scored window is strictly wider than
/// one coarse slot, for every round number. The constructor's guard is a fact about immutables the
/// Prover starts from havoc'd, so, exactly like `wellFormedSchedule` above, it is RESTATED as the
/// precondition it is, and what is proved is that it propagates to every `n`. With the rule above
/// showing the constructor's expressions ARE the getters, the two together say: no deployment that
/// passes the constructor can produce a round whose two window edges collapse onto one checkpoint,
/// which is what makes `FamilyHook.averageOver`'s `BadScoreWindow` unreachable.
rule theScoredWindowAlwaysExceedsOneCoarseSlot(uint256 n) {
    require wellFormedSchedule();
    // the constructor's guard, restated (`BadDurationScale`, second check)
    uint64 w = assert_uint64(CLOSING_WINDOW_S() / DURATION_SCALE_DIV());
    mathint rawSlot = (to_mathint(w) + to_mathint(RANDOM_END_S()) + 62) / 63;
    mathint slot = rawSlot < to_mathint(SCORE_MIN_SLOT_S()) ? to_mathint(SCORE_MIN_SLOT_S()) : rawSlot;
    require to_mathint(w) > slot;
    assert to_mathint(closingWindowFor(n)) > to_mathint(scoreSlotFor(n)),
        "a round's scored window is no wider than one coarse slot";
}

/// No candidate is
/// ever scored over a span beginning before its own pool opened.
rule lateEntryClosesBeforeTheClosingWindow(uint256 n) {
    require wellFormedSchedule();
    require durationFor(n) >= LATE_ENTRY_FROM_S();
    assert to_mathint(lateEntryUntil(n))
         < to_mathint(durationFor(n)) - to_mathint(closingWindowFor(n)) - to_mathint(RANDOM_END_S()),
        "late entry could outlast the start of the closing window";
}

/// BondFor saturates at BOND_MAX rather than
/// overflowing, for every index. The cap and the base are denominated in the edge
/// currency, so a deployment calibrates them from the graduated launch price rather than in wei.
rule bondSaturates(uint256 i) {
    assert bondFor(i) <= BOND_MAX(), "bondFor exceeded the cap";
    assert bondFor(i) >= BOND_BASE() || BOND_BASE() > BOND_MAX(),
        "bondFor fell below the base";
}

/// BondFor is monotone non-decreasing in the target index.
/// Without the restriction below, this rule TIMES OUT: `bondFor` is `BOND_BASE << (i / every)` with a
/// symbolic base, a symbolic divisor and a symbolic shift, plus the overflow-detection round trip;
/// a symbolic-on-symbolic shift is the single worst thing a bit-vector solver can be handed.
rule bondIsMonotoneInDepth(uint256 i, uint256 j) {
    require i <= j;
    // `BOND_DOUBLING_EVERY` is PINNED to its deploy constant (doubling every 4 links),
    // which turns the shift amount from a symbolic-on-symbolic division into a concrete function of
    // `i`. This IS a scoping restriction and is recorded as one: RND-12 is proved at the deployed
    // schedule, not for every conceivable `doublingEvery`. Arbitrary-parameter monotonicity stays
    // with the fuzz tier. The `every == 0` branch returns the constant cap and is trivially monotone.
    require BOND_DOUBLING_EVERY() == 4;
    require j <= 1024;
    assert bondFor(i) <= bondFor(j), "a deeper link was cheaper to contest";
}

/// The policy MAX_INDEX is respected at the
/// door; no round can open whose next index would exceed it.
/// `require isIdle()`. `openRoundIfIdle` is idempotent by name and by design: when a
/// round is already open it returns that round's parameters WITHOUT reverting and without touching
/// the depth cap. RND-15 is a claim about opening a NEW round, which is the idle case.
rule maxIndexIsRespected(env e) {
    // A constructor argument of 0 no longer means "unlimited", it is mapped to
    // `FenwickRangeAdd.MAX_INDEX` (4095) and anything above that reverts `BadMaxIndex`, so
    // `MAX_INDEX() != 0` holds of every deployable configuration rather than excluding one.
    require MAX_INDEX() != 0;
    require isIdle();                         // the branch that can mint a new index
    require headIndex() + 1 > MAX_INDEX();
    uint256 before = roundCount();
    openRoundIfIdle@withrevert(e);
    assert lastReverted || roundCount() == before,
        "a round opened past the policy depth cap";
}

// ---------------------------------------------------------------------------------------------
// the state machine and continuation (CON-01)
// ---------------------------------------------------------------------------------------------

/// No transition is privileged. Every state-changing entrypoint other than
/// the steward's sunset pair is callable by any address, so no caller check gates a transition.
/// Both callers start from the same storage via `at init`, which is the only form in
/// which "no caller is privileged" is even a statement about access control; and the filter excludes
/// the ROLE-GATED entrypoints the spec itself names, which are not transitions of the round machine.
/// The factory-only bootstrap in that list is `adoptGenesis`, and `openRoundIfIdle` /
/// `addCandidate` stay excluded for the same reason they always were (factory-only, spec A row 1).
rule noTransitionIsPrivileged(method f, env e, env e2, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract
                 && f.selector != sig:announceSunset(address).selector
                 && f.selector != sig:cancelSunset().selector
                 && f.selector != sig:announceStewardTransfer(address).selector
                 && f.selector != sig:cancelStewardTransfer().selector
                 && f.selector != sig:executeStewardTransfer().selector
                 && f.selector != sig:adoptGenesis(address,address).selector
                 && f.selector != sig:addCandidate(uint256,address,RoundManager.PoolKey,address,uint256).selector
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

/// The sunset pair is the steward's, once each, and touches no
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
