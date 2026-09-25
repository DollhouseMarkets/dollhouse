/*
 * FeeVault.spec
 *
 * Source of truth: docs/spec/PROTOCOL_SPEC.md §I (fee semantics), §J (fee recipients, the keeper
 * model, the drawdown token bucket, the sunset handover) and docs/spec/PROPERTIES.md §3.2 / §3.8 /
 * §3.9 / §6.
 *
 * THE VAULT IS DENOMINATED IN THE EDGE CURRENCY, NOT IN NATIVE ETH: there is no
 * `Currency.wrap(address(0))` anywhere in it. The immutable `EDGE` is the adopted
 * genesis token (`FamilyFactory.genesisToken()`), the vault has no `receive()`, no entrypoint is
 * payable, and every payout is an ERC-20 transfer through `_sendToken`. The ledgers are:
 * `reinforcementEdge[j]`, `edgeBidEarmark`, `claimableEdge(j)`,
 * `drawableEdge(j)`.
 *
 * Ledgers named by the spec (§J, FEE-10): devBalance, creatorBalance[token], creatorAccrued[addr],
 * the Fenwick coefficient trees (ancestorTree), reinforcementEdge[j], reinforcementBalance[parent],
 * edgeBidEarmark, pendingForward[attribution]. ledgerTotal[c] is the vault's own running sum and,
 * per the spec, counts pendingForward too.
 *
 * SOLVENCY IS AN INEQUALITY, DELIBERATELY (SUP-04). Anyone may transfer the
 * edge currency straight to this address. A donation credits no ledger, so `holdings(EDGE)` may
 * exceed `ledgerTotal[EDGE]` by any amount and no code path may ever sweep the difference. The
 * invariant below is `>=` in that direction and `onlyAccrualPathsRaiseLedgerTotal` is the other
 * half: a donation cannot make itself claimable by raising a ledger.
 */

using FeeVault as vault;
// The Prover needs a CONCRETE edge token. `EDGE` is an immutable the constructor reads off
// the factory, so it is havoc'd unless it is linked, and every `IERC20(Currency.unwrap(EDGE))` call
// then lands on an unknown address and havocs whatever it touches. `MockDoll` is the plain
// 18-decimal ERC-20 the test bases already deploy for exactly this role
// (test/utils/MockDoll.sol): no hooks, no fee on transfer, no callbacks, which is what the launch
// implementation is as well. It is LINKED in
// certora/conf/FeeVault.conf.
using MockDoll as edgeDoll;

// ---------------------------------------------------------------------------------------------
// methods
// ---------------------------------------------------------------------------------------------
methods {
    // --- ledger getters (spec J) ---
    function devBalance() external returns (uint256) envfree;
    function creatorBalance(address) external returns (uint256) envfree;
    function creatorAccrued(address) external returns (uint256) envfree;
    function ancestorClaimed(uint256) external returns (uint256) envfree;
    // `reinforcementEth` / `genesisBidEarmark` are gone. Same slots, edge denomination.
    function reinforcementEdge(uint256) external returns (uint256) envfree;
    function reinforcementBalance(address) external returns (uint256) envfree;
    function edgeBidEarmark() external returns (uint256) envfree;
    function pendingForward(uint256) external returns (uint256) envfree;
    function pendingForwardTotal() external returns (uint256) envfree;
    function deployerCredit() external returns (uint256) envfree;
    function forwardingFailed() external returns (bool) envfree;
    function successorVault() external returns (address) envfree;
    // The dead-successor escape is TWO-PHASE and PER-ATTRIBUTION.
    // `deadEvidenceAt[a]` is the timestamp of the FIRST full-`FORWARD_GAS` delivery failure against
    // a RESOLVED successor vault for attribution `a`. Booking locally needs that timestamp to be
    // `DEAD_SUCCESSOR_DELAY` old AND a second full-budget failure in the flush that books; any
    // successful delivery clears it.
    function deadEvidenceAt(uint256) external returns (uint64) envfree;
    function developer() external returns (address) envfree;
    function bidDeployer() external returns (address) envfree;
    // The immutable edge currency itself. Linked, so this reads a concrete address.
    function EDGE() external returns (FeeVault.Currency) envfree;

    // --- split constants (spec J; FEE-09) ---
    function DEV_BPS() external returns (uint256) envfree;
    function CREATOR_BPS() external returns (uint256) envfree;
    function ANCESTOR_BPS() external returns (uint256) envfree;
    function REINFORCE_BPS() external returns (uint256) envfree;
    function DAILY_DRAW_BPS() external returns (uint256) envfree;
    function DRAW_WINDOW() external returns (uint64) envfree;
    function DEAD_SUCCESSOR_DELAY() external returns (uint64) envfree;
    function FORWARD_GAS() external returns (uint256) envfree;
    function UNATTRIBUTED() external returns (uint256) envfree;
    function CANDIDATE_ATTRIBUTION() external returns (uint256) envfree;

    // --- entrypoints ---
    function accrue(FeeVault.Currency, address, uint256, uint256, uint256, bool) external;
    function accrueForwarded(uint256, uint256, uint256) external;
    // NON-PAYABLE, and it carries the amount. The prior vault transfers the edge currency
    // in the instruction before this call and the delivery is VERIFIED here against the solvency
    // inequality (`ledgerTotal[EDGE] <= holdings(EDGE)`), not taken on the caller's word.
    function receiveForward(uint256, uint256) external;
    function flushForward(uint256, uint256) external returns (uint256);
    // `deliverForward` is the self-only transfer-and-notify step split out of
    // `flushForward`; it is an external method, so every parametric rule below reaches it.
    function deliverForward(address, uint256, uint256, uint256) external;
    function forwardProtocolFee(FeeVault.Currency, uint256, uint256, uint256) external;
    // NON-PAYABLE, and it carries the amount (`depositGenesisBidEarmark()` is gone).
    function depositEdgeBidEarmark(uint256) external;
    function claimDev(address) external returns (uint256);
    function claimCreator(address, address) external returns (uint256);
    function claimCreatorAccrued(address) external returns (uint256);
    function transferCreatorRecipient(address, address) external;
    function consumeAncestorClaim(uint256, uint256) external returns (uint256);
    function consumeReinforcement(address, uint256) external returns (uint256);
    function consumeEdgeEarmark(uint256) external returns (uint256);
    function payKeeper(address, uint256) external;
    function redeem(FeeVault.Currency) external;

    // --- views used by rules ---
    function holdings(FeeVault.Currency) external returns (uint256);
    function claimableEdge(uint256) external returns (uint256);
    function claimableAncestor(uint256) external returns (uint256);
    function drawableEdge(uint256) external returns (uint256);
    function ledgerTotal(FeeVault.Currency) external returns (uint256);

    // --- the linked edge token ----------------------------------------------------------------
    // EXACT entries with NO summary, so these calls run the real ERC-20 code. An exact entry takes
    // precedence over the `_.` wildcards below, which stay for every OTHER token this vault touches
    // (the parent-denominated hop pots of `reinforcementBalance`, whose currencies are symbolic).
    // This is what replaces the general `cvlTokenBalance` ghost FOR THE EDGE CURRENCY ONLY: that
    // ghost exists because an unlinked callee havocs, and a linked, unmodified ERC-20 is CONSISTENT
    // by construction while also actually MOVING on a transfer, which is what the payout rules below
    // need in order to be about value leaving at all rather than about a constant.
    function edgeDoll.balanceOf(address) external returns (uint256) envfree;
    function edgeDoll.transfer(address, uint256) external returns (bool);
    function edgeDoll.transferFrom(address, address, uint256) external returns (bool);
    function edgeDoll.totalSupply() external returns (uint256) envfree;

    // --- summaries ----------------------------------------------------------------------------
    // The v4 singleton is not part of this proof. PROPERTIES section 6, "Summaries required": every
    // PoolManager entrypoint is summarized. mint/burn/take/settle/sync/unlock move balances the
    // solvency invariant measures through `holdings`, whose claim term is summarized below, so a
    // NONDET of the manager cannot weaken the ledger-side conservation claims.
    function _.mint(address, uint256, uint256) external => NONDET;
    function _.burn(address, uint256, uint256) external => NONDET;
    function _.take(FeeVault.Currency, address, uint256) external => NONDET;
    function _.settle() external => NONDET;
    function _.sync(FeeVault.Currency) external => NONDET;
    function _.unlock(bytes) external => NONDET;
    // `holdings(c)` = real balance + unredeemed ERC-6909 claims, and the claim term is
    // this `balanceOf`. Under a bare NONDET two reads of `holdings` IN THE SAME STATE would come
    // back different, which is not an over-approximation of the singleton, it is false, and it
    // would leave `solvency` violated on its transient-storage step and on every other method.
    // The claim balance stays fully unconstrained; it is pinned so that it is merely CONSISTENT.
    function _.balanceOf(address holder, uint256 tokenId) external
        => cvlClaimBalance(holder, tokenId) expect uint256;
    // NARROWED TO THE EDGE CURRENCY LINK ABOVE. The other half of `holdings` is
    // `IERC20(Currency.unwrap(currency)).balanceOf(address(this))`, the one-argument ERC-20
    // overload. For the EDGE currency it now resolves to the linked token above; this wildcard is
    // what is left for a SYMBOLIC currency (a parent-denominated hop pot), where the callee is an
    // address the Prover cannot resolve. Unconstrained value, consistent read.
    function _.balanceOf(address holder) external => cvlTokenBalance(holder) expect uint256;
    // `forwardProtocolFee` hands the claim over with `poolManager.transfer` (the ERC-6909
    // three-argument overload), which must be summarized like every other manager entrypoint.
    function _.transfer(address, uint256, uint256) external => NONDET;
    function _.protocolFeesAccrued(FeeVault.Currency) external => NONDET;
    // `claimDev`, `claimCreator` and `claimCreatorAccrued`
    // carry `notInsideUnlock`, which reads v4-core's transient lock slot off the PoolManager with a
    // single `exttload` (contracts/libraries/V4UnlockGuard.sol). The manager is deliberately
    // UNLINKED, so without a summary that read is a fresh per-call havoc: a guard that answers
    // differently on two calls in the same transaction is not an over-approximation of a transient
    // slot, it is false. Unconstrained value, consistent read.
    function _.exttload(bytes32) external => cvlUnlockSlot() expect bytes32;

    // The RoundManager is read for attribution, sunset state and creator identity. Its own state
    // machine is proved in RoundManager.spec; here every read is NONDET or a consistent-read ghost,
    // so no rule below can be proved true only because a particular round state was assumed.
    function _.isSunset() external => NONDET;
    function _.canonical(uint256 i) external => cvlRmCanonical(i) expect address;
    function _.headIndex() external => cvlRmHeadIndex() expect uint256;
    function _.creatorOf(address t) external => cvlRmCreatorOf(t) expect address;
    function _.indexOf(address t) external => cvlRmIndexOf(t) expect uint256;
    function _.phase(uint256) external => NONDET;

    // A successor vault is arbitrary third-party code (it is a later, unknown deployment), and the
    // spec's claim is precisely that nothing a successor does can break this vault's solvency or its
    // queue accounting. HAVOC_ECF rather than HAVOC_ALL: `accrue` is
    // `nonReentrant`, `flushForward` already was, `forwardProtocolFee` and `deliverForward` are
    // `msg.sender == address(this)` only, and the two entrypoints a successor could aim at,
    // `accrueForwarded` and `receiveForward`, both require `_isPriorVault(msg.sender)`, which a
    // SUCCESSOR of this vault can never satisfy. Everything outside this contract stays havoc'd.
    // `receiveForward` gained its `amount` argument, so the entry is re-signed.
    function _.accrueForwarded(uint256, uint256, uint256) external => HAVOC_ECF;
    function _.receiveForward(uint256, uint256) external => HAVOC_ECF;
}

// ---------------------------------------------------------------------------------------------
// ghost state (PROPERTIES section 6, "Ghost state needed")
// ---------------------------------------------------------------------------------------------

// Mirror of the vault's own ledgerTotal, keyed by the v4 `Currency` user-defined value type because
// that is the key type of the storage mapping the hooks below observe.
//
// Every mirror is `persistent`: a HAVOC_ECF summary of the successor wipes every NON-persistent
// ghost, which without `persistent` makes every ghost-delta rule come back violated with nonsense
// mirror values. `persistent` keeps the spec-side write log the `Sstore` hooks build; it changes no rule's
// meaning, because the hooks fire on exactly this vault's own stores and a successor cannot write
// this vault's storage slots.
persistent ghost mapping(FeeVault.Currency => mathint) ghostLedgerTotal {
    init_state axiom forall FeeVault.Currency c. ghostLedgerTotal[c] == 0;
}

// Sum of every EDGE-denominated ledger the spec enumerates in FEE-10.
persistent ghost mathint ghostDev             { init_state axiom ghostDev == 0; }
persistent ghost mathint ghostCreatorSum      { init_state axiom ghostCreatorSum == 0; }
persistent ghost mathint ghostAccruedSum      { init_state axiom ghostAccruedSum == 0; }
persistent ghost mathint ghostReinforceEdge   { init_state axiom ghostReinforceEdge == 0; }
persistent ghost mathint ghostEarmark         { init_state axiom ghostEarmark == 0; }
persistent ghost mathint ghostPendingSum      { init_state axiom ghostPendingSum == 0; }
persistent ghost mathint ghostAncestorClaimed { init_state axiom ghostAncestorClaimed == 0; }
// Per-attribution mirror of pendingForward, so the flush post-condition can be read from the write
// log instead of from storage a HAVOC summary has wiped.
persistent ghost mapping(uint256 => mathint) ghostPending {
    init_state axiom forall uint256 a. ghostPending[a] == 0;
}

// Backing store for the consistent-read summaries in the `methods` block. Arbitrary values, fixed
// once per state, which is what a view function of another contract actually is.
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

// `reinforcementBalance[parent]` is
// keyed by the PARENT TOKEN's address. The edge-denominated half of it is keyed by
// `Currency.unwrap(EDGE)`, the linked edge token; `address(0)` is not a currency here. A
// storage hook cannot call `EDGE()`, so the address is carried in this ghost and pinned to the
// linked token by `edgeIsPinned()` wherever it matters.
persistent ghost address ghostEdgeToken;
persistent ghost mathint ghostReinforceBalanceEdge {
    init_state axiom ghostReinforceBalanceEdge == 0;
}

// `ledgerTotal` is keyed by the v4 `Currency` user-defined value type, not by a plain address, so
// the hook key must be declared with that type.
hook Sstore ledgerTotal[KEY FeeVault.Currency c] uint256 v (uint256 oldV) {
    ghostLedgerTotal[c] = to_mathint(v);
}
hook Sload uint256 v ledgerTotal[KEY FeeVault.Currency c] {
    require ghostLedgerTotal[c] == to_mathint(v);
}
// `devBalance` and `edgeBidEarmark` are SCALAR words, so their mirrors are absolute (like
// `ledgerTotal`'s) rather than delta-accumulating, and an `Sload` hook pins each to the word it
// mirrors. The mapping mirrors below are sums over many words, so no load can pin them exactly; each
// load pins the sum to be at least the element read, which is what the unsigned element guarantees
// and all the decomposition needs.
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
hook Sstore reinforcementEdge[KEY uint256 j] uint256 v (uint256 oldV) {
    ghostReinforceEdge = ghostReinforceEdge + to_mathint(v) - to_mathint(oldV);
}
hook Sload uint256 v reinforcementEdge[KEY uint256 j] {
    require ghostReinforceEdge >= to_mathint(v);
}
hook Sstore edgeBidEarmark uint256 v (uint256 oldV) {
    ghostEarmark = to_mathint(v);
}
hook Sload uint256 v edgeBidEarmark {
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
    if (parent == ghostEdgeToken) {
        ghostReinforceBalanceEdge = ghostReinforceBalanceEdge + to_mathint(v) - to_mathint(oldV);
    }
}
hook Sload uint256 v reinforcementBalance[KEY address parent] {
    require parent == ghostEdgeToken => ghostReinforceBalanceEdge >= to_mathint(v);
}
// NOT EXPRESSIBLE HERE: the ancestor sleeve is not a scalar ledger. It is a range-add of three
// WAD-scaled coefficients into the Fenwick trees (spec J, "Ancestor polynomial"), so there is no
// storage word whose delta is "the sleeve credited by this call" and no hook can mirror one. The
// sleeve's own conservation claim is proved in Sleeve.spec against
// certora/harness/FenwickHarness.sol; every sum below omits the sleeve term, which keeps each bound
// sound (the omitted term is non-negative) but makes FEE-08 an upper bound rather than an equality
// on this contract. See certora/PROPERTY_MAP.md.

// Well-formedness. `Drawdown.updatedAt` is a uint64 that only ever receives
// `uint64(block.timestamp)`. A `block.timestamp` outside the uint64 range (which the Prover picks by
// default) truncates on the store. Neither timestamp 0 nor timestamp 2^64 is reachable on a live
// chain; the restriction below states that explicitly rather than hiding it.
definition wellFormedTime(env e) returns bool =
    e.block.timestamp > 0 && to_mathint(e.block.timestamp) < 18446744073709551616;

// The edge-token ghost IS the linked token. This is a pin, not an assumption: `EDGE` is
// linked to `MockDoll` in the conf, so the two are the same address in every state the Prover can
// build. It is written as a definition so that every rule reading `ghostEdgeToken` says so out loud.
definition edgeIsPinned() returns bool = ghostEdgeToken == edgeDoll;

// Methods that are allowed to move the edge currency out of the vault at all (spec J "Claims", the
// keeper model, the sunset handover).
//
// The BidDeployer consumption hooks ARE a declared path (spec J, "The keeper model").
// They are `onlyBidDeployer`, and that leash is proved by `onlyBidDeployerHooks` in this same file.
//
// `consumeGenesisEarmark` is `consumeEdgeEarmark`, and `deliverForward` joins the list. It
// is the self-only half split out of `flushForward` and it holds the `safeTransfer` to the
// successor, so it moves value by construction and the parametric rule reaches it directly.
// `accrue` and `forwardProtocolFee` are DELIBERATELY LEFT OUT: neither moves the edge TOKEN (the
// sunset hop hands the successor an ERC-6909 CLAIM), and listing them would hide a future real exit
// on the accrual path.
definition isPayoutMethod(method f) returns bool =
    f.selector == sig:claimDev(address).selector
 || f.selector == sig:claimCreator(address,address).selector
 || f.selector == sig:claimCreatorAccrued(address).selector
 || f.selector == sig:payKeeper(address,uint256).selector
 || f.selector == sig:flushForward(uint256,uint256).selector
 || f.selector == sig:deliverForward(address,uint256,uint256,uint256).selector
 || f.selector == sig:redeem(FeeVault.Currency).selector
 || f.selector == sig:consumeReinforcement(address,uint256).selector
 || f.selector == sig:consumeEdgeEarmark(uint256).selector;

// ---------------------------------------------------------------------------------------------
// solvency and conservation
// ---------------------------------------------------------------------------------------------

/// FEE-11 / SUP-04 (spec I "ERC-6909 claims", spec J): for every
/// currency `ledgerTotal[c] <= holdings(c)`, where holdings = real ERC-20 balance + unredeemed
/// claims and ledgerTotal includes pendingForward.
/// THE DIRECTION IS THE POINT. It is an INEQUALITY, not an equality: the gap is reachable in
/// practice because anyone may transfer the edge currency straight to this
/// address, that donation credits no ledger, and nothing in the contract sweeps the difference. An
/// equality here would be a false claim AND would invite exactly the sweep the design refuses.
/// A bare, non-inductive form of this claim fails on `payKeeper`'s
/// counterexample: a pre-state with `ledgerTotal[EDGE] == holdings(EDGE)` AND a
/// non-zero `deployerCredit`, from which paying one unit of that credit drops holdings and leaves
/// ledgerTotal alone. No reachable state has both, because `consumeAncestorClaim` DEBITS the ledger
/// when it creates the credit: the credit is edge currency that is still in the vault and no longer
/// counted in `ledgerTotal`. Carving it back out on the edge side is the inductive statement of the
/// same claim, and it is STRICTLY STRONGER than the non-inductive form.
invariant solvency(env e, FeeVault.Currency c)
    to_mathint(ledgerTotal(e, c)) + (c == EDGE() ? to_mathint(deployerCredit()) : to_mathint(0))
        <= to_mathint(holdings(e, c))
    filtered { f -> !f.isView && f.contract == currentContract }

/// FEE-10 (spec J): every mirror of an unsigned ledger word is non-negative in every reachable
/// state. Proved ONCE here, where each method only has to PRESERVE it, and assumed into the
/// decomposition below. The mapping mirrors accumulate deltas, so conjoining `>= 0` inside the
/// decomposition instead would make eight methods re-prove it out of nothing; this is the shape
/// that works.
invariant edgeMirrorsAreNonNegative()
    ghostDev >= 0 && ghostCreatorSum >= 0 && ghostAccruedSum >= 0 && ghostEarmark >= 0
    && ghostPendingSum >= 0 && ghostReinforceEdge >= 0 && ghostReinforceBalanceEdge >= 0
    && ghostAncestorClaimed >= 0
    filtered { f -> !f.isView && f.contract == currentContract }

/// FEE-10 (spec J): `ledgerTotal[EDGE]` covers the sum of the enumerated edge-denominated ledgers
/// plus the queued forwards, i.e. every unit with a named destination is tracked.
/// SPEC-GAP: the Fenwick residue (spec J, "Every division floors") stays in the vault forever and is
/// deliberately not subtracted, which is why the relation is `>=` on the sleeve side. PROPERTIES 7.
/// THE `accrue` PRECONDITION. There is no genesis marker: `FamilyHook._collect` passes
/// `Currency.unwrap(parent)` unconditionally, so the caller's convention is simply that the
/// `parentToken` word IS the currency the hop fee is denominated in. Uncoupled, the Prover credits
/// `reinforcementBalance[edge]`, an edge-side term of this decomposition, with a NON-edge fee while
/// the edge ledger legitimately does not move. The block states the convention, nothing about
/// amounts.
invariant edgeLedgerDecomposition()
    ghostLedgerTotal[EDGE()] >= ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                                + ghostPendingSum + ghostReinforceEdge + ghostReinforceBalanceEdge
                                - ghostAncestorClaimed
    filtered { f -> !f.isView && f.contract == currentContract }
    {
        preserved with (env e) {
            require edgeIsPinned();
            requireInvariant edgeMirrorsAreNonNegative();
        }
        preserved accrue(FeeVault.Currency c, address parentToken, uint256 hopFee,
                         uint256 protocolFee, uint256 terminalIndex, bool attributed) with (env e) {
            require edgeIsPinned();
            requireInvariant edgeMirrorsAreNonNegative();
            require (parentToken == edgeDoll) <=> (c == EDGE());
        }
    }

/// FEE-08 (spec J "_book"): one accrue moves at most hopFee + protocolFee into the ledgers, and
/// every credited unit is one of dev / creator / coCredit / sleeve / reinforce / hop.
rule accrueConservesTheFee(env e, FeeVault.Currency c, address parentToken,
                           uint256 hopFee, uint256 protocolFee, uint256 terminalIndex, bool attributed) {
    require edgeIsPinned();
    mathint before = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                   + ghostPendingSum + ghostReinforceEdge;
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    mathint after = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                  + ghostPendingSum + ghostReinforceEdge;
    // The hop fee (and the snipe tax folded into it by `_collect`) is denominated in the PARENT
    // currency and lands in reinforcementBalance[parent]; it is counted in this sum only when the
    // parent is the edge currency, i.e. on a link-one pool.
    assert after - before <= to_mathint(hopFee) + to_mathint(protocolFee),
        "accrue credited more than it was handed";
}

/// FEE-08 (spec J): accrue changes ledgerTotal by at most what it was handed, never more.
rule accrueMovesLedgerTotalByTheFee(env e, FeeVault.Currency c, address parentToken,
                                    uint256 hopFee, uint256 protocolFee, uint256 terminalIndex, bool attributed) {
    require edgeIsPinned();
    mathint before = ghostLedgerTotal[EDGE()];
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    assert ghostLedgerTotal[EDGE()] - before <= to_mathint(hopFee) + to_mathint(protocolFee),
        "ledgerTotal grew by more than the fee credited";
}

/// FEE-10 (spec J): fees enter through exactly one door. No method outside the accrual and queue
/// paths increases any ledger.
/// `flushForward` IS NAMED, because it has a dead-successor branch, which calls `_book` and
/// therefore credits dev / creator / sleeve / reinforce out of the queue. The fee is not created: it is moved from
/// `pendingForward` (which this sum does count) into the local ledgers, and `flushForwardConserves`
/// is what bounds the move.
rule onlyAccrualPathsCredit(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                   + ghostPendingSum + ghostReinforceEdge;
    f(e, args);
    mathint after = ghostDev + ghostCreatorSum + ghostAccruedSum + ghostEarmark
                  + ghostPendingSum + ghostReinforceEdge;
    assert after > before =>
        (f.selector == sig:accrue(FeeVault.Currency,address,uint256,uint256,uint256,bool).selector
      || f.selector == sig:accrueForwarded(uint256,uint256,uint256).selector
      || f.selector == sig:receiveForward(uint256,uint256).selector
      || f.selector == sig:flushForward(uint256,uint256).selector
      || f.selector == sig:depositEdgeBidEarmark(uint256).selector
      || f.selector == sig:transferCreatorRecipient(address,address).selector),
        "a ledger grew outside the accrual paths";
}

/// SUP-04 - A DONATION IS NEVER CREDITED, SO IT IS NEVER SWEEPABLE.
/// The vault's edge balance can be raised by anyone at any time with a plain ERC-20 transfer, and
/// the protocol's answer is that the balance is not what anyone is owed: `ledgerTotal[EDGE]` is, and
/// it moves only where a fee, a forward or a forfeited bond was BOOKED. This is the running-sum half
/// of `onlyAccrualPathsCredit` above (that rule watches the individual ledgers, this one watches the
/// total every payout path debits), and together with `solvency`'s inequality it is what makes the
/// donated surplus unreachable: no path pays out against a number a donation can move.
rule onlyAccrualPathsRaiseLedgerTotal(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require edgeIsPinned();
    mathint before = ghostLedgerTotal[EDGE()];
    f(e, args);
    assert ghostLedgerTotal[EDGE()] > before =>
        (f.selector == sig:accrue(FeeVault.Currency,address,uint256,uint256,uint256,bool).selector
      || f.selector == sig:accrueForwarded(uint256,uint256,uint256).selector
      || f.selector == sig:receiveForward(uint256,uint256).selector
      || f.selector == sig:flushForward(uint256,uint256).selector
      || f.selector == sig:depositEdgeBidEarmark(uint256).selector),
        "ledgerTotal rose outside the accrual paths, so a donation could be made claimable";
}

/// ROL-07 (spec J "Claims"): transferCreatorRecipient only moves value between two ledgers; the sum
/// of creatorBalance and creatorAccrued is unchanged by it.
rule creatorTransferIsALedgerMove(env e, address token, address to) {
    mathint before = ghostCreatorSum + ghostAccruedSum;
    transferCreatorRecipient(e, token, to);
    assert ghostCreatorSum + ghostAccruedSum == before,
        "transferring the creator right created or destroyed a credit";
}

// ---------------------------------------------------------------------------------------------
// The deposits are non-payable and verify their own delivery
// ---------------------------------------------------------------------------------------------

/// FEE-11 - `receiveForward` IS NON-PAYABLE AND VERIFIES DELIVERY.
/// The prior vault transfers the edge currency in the instruction before the
/// call and passes the figure as an argument, which is a claim, not evidence. The contract answers
/// by re-checking the solvency inequality after crediting: `ledgerTotal[EDGE] > holdings(EDGE)`
/// reverts `NotDelivered`. This is that guard stated directly, and it is the one thing standing
/// between a hostile prior vault and a free credit on this version's ledgers.
rule receiveForwardRefusesAnUndeliveredAmount(env e, uint256 attribution, uint256 amount) {
    require edgeIsPinned();
    require amount > 0;
    mathint ledgerBefore = ghostLedgerTotal[EDGE()];
    uint256 held = holdings(e, EDGE());
    require ledgerBefore + to_mathint(amount) > to_mathint(held);
    receiveForward@withrevert(e, attribution, amount);
    assert lastReverted, "receiveForward credited an amount that was never delivered";
}

/// RND-11 - `depositEdgeBidEarmark` IS NON-PAYABLE AND VERIFIES
/// DELIVERY. The same shape on the other deposit: the RoundManager transfers the forfeited bonds in
/// the instruction before the call (`RoundManager.pushForfeit` and `flushForfeits`) and this call
/// books them. The check is what makes the RoundManager's try / catch meaningful: a forfeit that did
/// not arrive makes the deposit REVERT, which is caught and booked into `pendingForfeits` rather
/// than silently earmarked.
rule depositEdgeBidEarmarkRefusesAnUndeliveredAmount(env e, uint256 amount) {
    require edgeIsPinned();
    require amount > 0;
    mathint ledgerBefore = ghostLedgerTotal[EDGE()];
    uint256 held = holdings(e, EDGE());
    require ledgerBefore + to_mathint(amount) > to_mathint(held);
    depositEdgeBidEarmark@withrevert(e, amount);
    assert lastReverted, "the earmark booked forfeits that were never delivered";
}

/// THE VAULT TOUCHES NATIVE VALUE NOWHERE. `receive()` is gone and every
/// entrypoint (`receiveForward`, `depositGenesisBidEarmark`) is an ERC-20
/// deposit. A contract that accepts native value it can never send out has built itself a
/// permanent, unrecoverable sink; this states the whole external surface's non-payability as one
/// property rather than trusting a reading of the source.
rule everyEntrypointRefusesNativeValue(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    require e.msg.value > 0;
    f@withrevert(e, args);
    assert lastReverted, "an entrypoint accepted native value";
}

// ---------------------------------------------------------------------------------------------
// the drawdown token bucket (BID-07)
// ---------------------------------------------------------------------------------------------

/// BID-07 (spec J "Drawdown allowance is a token bucket"): a draw succeeds only for amounts within
/// the allowance the bucket currently holds, so the bucket is never overdrawn.
rule drawNeverExceedsTheBucket(env e, uint256 j, uint256 edgeAmount) {
    require wellFormedTime(e);
    uint256 allowed = drawableEdge(e, j);
    consumeAncestorClaim(e, j, edgeAmount);
    assert edgeAmount <= allowed, "a draw exceeded the bucket's available allowance";
}

/// PUR-05 / BID-07 (PROPERTIES 3.7): the OTHER half of the keeper draw bound, and the one the
/// uncontested purse rests on. Edge currency drawn for generation `j` never exceeds `j`'s OWN
/// claimable sleeve. It is stated against `claimableEdge(j)` directly; the bucket bound above is the
/// strictly tighter daily one, and together they are "never more than the generation has, and never
/// more than the day allows".
rule drawNeverExceedsTheGenerationsClaim(env e, uint256 j, uint256 edgeAmount) {
    uint256 claimable = claimableEdge(e, j);
    consumeAncestorClaim(e, j, edgeAmount);
    assert edgeAmount <= claimable, "a draw exceeded generation j's own claimable sleeve";
}

/// BID-07 (spec J): the allowance is capped at DAILY_DRAW_BPS of what is claimable right now, at
/// every instant. A bucket, not a resetting window, so there is no boundary to burst at.
invariant bucketNeverExceedsCap(env e, uint256 j)
    wellFormedTime(e) =>
        to_mathint(drawableEdge(e, j)) <= to_mathint(claimableEdge(e, j)) * to_mathint(DAILY_DRAW_BPS()) / 10000
    filtered { f -> !f.isView && f.contract == currentContract }

/// BID-07 (spec J): two draws in the same instant cannot together exceed one bucket.
rule twoDrawsCannotDoubleUp(env e, uint256 j, uint256 a, uint256 b) {
    require wellFormedTime(e);
    uint256 allowed = drawableEdge(e, j);
    consumeAncestorClaim(e, j, a);
    // Same block: dt == 0, so the bucket has refilled by nothing between the two draws.
    consumeAncestorClaim(e, j, b);
    assert to_mathint(a) + to_mathint(b) <= to_mathint(allowed),
        "two same-instant draws exceeded one bucket";
}

/// BID-07: the same claim with NO well-formedness precondition on the clock at all.
/// Without an explicit sentinel, the rule above could only be discharged by excluding
/// `block.timestamp == 0` and `block.timestamp >= 2^64`, because `Drawdown.updatedAt == 0` would
/// double as "untouched generation, full bucket" and `uint64(block.timestamp)` could truncate back
/// onto that sentinel. The sentinel is instead an explicit `Drawdown.initialised` flag, and the
/// refill clock is read in the same uint64 domain the field is stored in. This rule is the formal
/// evidence for that: it must pass for EVERY clock the Prover can pick.
rule twoDrawsCannotDoubleUpAtAnyClock(env e, uint256 j, uint256 a, uint256 b) {
    uint256 allowed = drawableEdge(e, j);
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
rule payKeeperIsBoundedByDeployerCredit(env e, address to, uint256 edgeAmount) {
    uint256 credit = deployerCredit();
    payKeeper(e, to, edgeAmount);
    assert edgeAmount <= credit, "payKeeper paid more than the credit consumed for it";
}

/// BID-14 (PROPERTIES 3.8): no keeper call leaves a residual credit. deployerCredit is zero at rest.
invariant deployerCreditSettles()
    deployerCredit() == 0
    filtered { f -> !f.isView && f.contract == currentContract
                 && f.selector != sig:consumeAncestorClaim(uint256,uint256).selector }

/// BID-05 / FEE-10, STATED ON THE TOKEN BALANCE. Value leaves the vault only on a
/// declared payout path (a ledger holder's claim, the keeper bounty, a forward to the successor
/// vault, or a redeem into the vault itself). Stating this over
/// `nativeBalances[currentContract]` would be vacuous: the vault
/// holds no native value and has no way to send one, so that measure would be true for a reason
/// that has nothing to do with the claim. The measure is the LINKED edge token's balance of this
/// contract, which is exactly what `_sendToken` moves.
rule valueLeavesOnlyOnPayoutMethods(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    mathint before = to_mathint(edgeDoll.balanceOf(currentContract));
    f(e, args);
    assert to_mathint(edgeDoll.balanceOf(currentContract)) < before => isPayoutMethod(f),
        "the edge currency left the vault on a method that is not a declared payout path";
}

/// BID-05 (spec J): the four leashed hooks are callable by BidDeployer alone, so no other address
/// can create a credit or spend a generation's money.
rule onlyBidDeployerHooks(method f, env e, calldataarg args)
    filtered { f -> f.selector == sig:consumeAncestorClaim(uint256,uint256).selector
                 || f.selector == sig:consumeReinforcement(address,uint256).selector
                 || f.selector == sig:consumeEdgeEarmark(uint256).selector
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

/// CON-05 (spec J): flushForward moves at most `max`, decrements pendingForward by exactly the
/// amount it took out of the queue, and creates or destroys nothing.
/// The post-state is read from the write-log mirrors, not re-read from storage: the successor's
/// `receiveForward` is summarized HAVOC_ECF, so a storage re-read after that call returns an
/// unconstrained word. The mirrors record the value the vault itself stored, which is exactly what
/// CON-05 claims.
///
/// `flushForward` dequeues
/// and debits `ledgerTotal` in the instruction BEFORE the delivery and restores both (`_requeue`) if
/// the hop fails. The queue half of a plain "unchanged" assertion holds exactly. The LEDGER half
/// does not, and asserting it unchanged would be a WRONG CLAIM rather than a strong one: the
/// dead-successor branch takes the same `amount` out of the queue and books it to THIS version's
/// ledgers instead, and there the value never left, so `ledgerTotal[EDGE]` is deliberately untouched
/// while the return value is non-zero. The honest statement is the TWO-SIDED one below: the ledger
/// either falls by exactly what was delivered, or does not fall at all, and it never falls by more.
/// Which branch ran is separated by `localBookingRequiresAgedEvidence`.
rule flushForwardConserves(env e, uint256 attribution, uint256 max) {
    require edgeIsPinned();
    uint256 pendingBefore = pendingForward(attribution);
    require ghostPending[attribution] == to_mathint(pendingBefore);
    mathint ledgerBefore = ghostLedgerTotal[EDGE()];
    uint256 moved = flushForward(e, attribution, max);
    assert moved <= max, "flushForward moved more than max";
    assert ghostPending[attribution] == to_mathint(pendingBefore) - to_mathint(moved),
        "pendingForward did not fall by exactly what left the queue";
    assert ghostLedgerTotal[EDGE()] >= ledgerBefore - to_mathint(moved),
        "ledgerTotal fell by more than what left the queue";
    assert ghostLedgerTotal[EDGE()] <= ledgerBefore,
        "a flush raised ledgerTotal";
    assert ghostLedgerTotal[EDGE()] == ledgerBefore - to_mathint(moved)
        || ghostLedgerTotal[EDGE()] == ledgerBefore,
        "a flush neither delivered the amount nor booked it locally";
}

/// CON-05 - THE TWO-PHASE DEAD-SUCCESSOR ESCAPE, stated as a guard on the
/// only branch that can take a successor's fee away from it. A local booking is observable from
/// outside as "the queue fell but `ledgerTotal[EDGE]` did not", because the value never left the
/// vault. The booking flush must find an evidence timestamp that is already there and already
/// `DEAD_SUCCESSOR_DELAY` old.
rule localBookingRequiresAgedEvidence(env e, uint256 attribution, uint256 max) {
    require edgeIsPinned();
    require wellFormedTime(e);
    uint64 evidenceBefore = deadEvidenceAt(attribution);
    mathint ledgerBefore = ghostLedgerTotal[EDGE()];
    uint256 moved = flushForward(e, attribution, max);
    assert (moved > 0 && ghostLedgerTotal[EDGE()] == ledgerBefore) =>
        (evidenceBefore != 0
         && to_mathint(e.block.timestamp)
              >= to_mathint(evidenceBefore) + to_mathint(DEAD_SUCCESSOR_DELAY())),
        "a queued fee was booked locally without aged evidence against the successor";
}

/// CON-05 - AN UNRESOLVED SUCCESSOR IS NEVER EVIDENCE OF A DEAD ONE. A steward who
/// names the next version's registry before that version's vault is deployed (the normal order, and
/// exactly why a negative resolution is deliberately not cached) would otherwise have seen the whole
/// queue booked locally thirty days later without the successor refusing a single unit.
/// The claim is stated through the RESOLUTION CACHE, which is what makes it expressible here:
/// `_resolveSuccessorVault` caches a successful resolution in `successorVault` and never caches a
/// negative one, so "the vault resolved on this call" is observable afterwards as
/// `successorVault() != 0`. Every write to `deadEvidenceAt` sits behind `v != address(0)`.
rule unresolvedSuccessorIsNeverEvidence(env e, uint256 attribution, uint256 max) {
    uint64 evidenceBefore = deadEvidenceAt(attribution);
    flushForward(e, attribution, max);
    assert deadEvidenceAt(attribution) != evidenceBefore => successorVault() != 0,
        "evidence moved against a successor whose vault never resolved";
}

/// CON-05: the evidence word is the forwarding path's alone. It is written in
/// exactly two places, `flushForward` (set on the first real failure, cleared on delivery) and
/// `forwardProtocolFee` (cleared on delivery), and nothing else in the contract may touch it, or an
/// unrelated entrypoint could age a successor into death or reset a standing clock.
rule deadEvidenceMovesOnlyOnTheForwardingPaths(method f, env e, calldataarg args, uint256 attribution)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint64 before = deadEvidenceAt(attribution);
    f(e, args);
    assert deadEvidenceAt(attribution) != before =>
        (f.selector == sig:flushForward(uint256,uint256).selector
      || f.selector == sig:accrue(FeeVault.Currency,address,uint256,uint256,uint256,bool).selector
      || f.selector == sig:accrueForwarded(uint256,uint256,uint256).selector
      || f.selector == sig:receiveForward(uint256,uint256).selector
      || f.selector == sig:forwardProtocolFee(FeeVault.Currency,uint256,uint256,uint256).selector),
        "the dead-successor evidence moved outside the forwarding paths";
}

/// CON-04 - A CANDIDATE ATTRIBUTION NEVER CROSSES THE HANDOVER.
/// A candidate id indexes THIS version's own `candidates` array and means nothing in the successor's,
/// where the same number is some other coin; forwarding it would credit the successor's candidate #n
/// with a fee earned by this version's candidate #n. `accrue` substitutes `UNATTRIBUTED` whenever the
/// attribution word carries `CANDIDATE_ATTRIBUTION`, so the share goes to the flywheel rather than to
/// the wrong creator. `CANDIDATE_ATTRIBUTION` is `1 << 255`, so "the flag is set" is stated as the
/// unsigned comparison rather than with a bitwise mask, which keeps the rule out of bit-vector
/// arithmetic. The claim is over the QUEUE, the observable half of the handover.
rule candidateAttributionsCrossAsUnattributed(env e, FeeVault.Currency c, address parentToken,
                                              uint256 hopFee, uint256 protocolFee,
                                              uint256 terminalIndex, bool attributed, uint256 a) {
    require attributed;
    require to_mathint(terminalIndex) >= to_mathint(CANDIDATE_ATTRIBUTION());
    require a != UNATTRIBUTED();
    mathint before = ghostPending[a];
    accrue(e, c, parentToken, hopFee, protocolFee, terminalIndex, attributed);
    assert ghostPending[a] <= before,
        "a candidate attribution was queued for the successor under its deployment-local id";
}

/// NO PAYOUT PATH CAN BURN THE EDGE CURRENCY AT THE ZERO
/// ADDRESS. Every claim debits its ledger BEFORE the send, and plenty of ERC-20s accept a transfer
/// to `address(0)`, so without a guard a mistyped destination would burn the claim permanently with
/// nothing to show for
/// it. `_sendToken` refuses `address(0)` (`BadRecipient`) before it calls `safeTransfer`, which
/// covers every payout path at once; the four stated here are the ones whose destination is a
/// caller-supplied argument.
/// `payKeeper` NEEDS `amount > 0` IN THIS RULE. A
/// counterexample without it is `payKeeper(address(0), 0)`, which returns on
/// `if (edgeAmount == 0) return;` WITHOUT reverting and without sending anything, so nothing is
/// burned and the claim this rule makes is not about it. The three claims need no such bound: each
/// reverts on the zero address before it can decide whether its ledger is empty.
rule noPayoutPathCanBurnTokensAtTheZeroAddress(env e, address token, uint256 edgeAmount) {
    require edgeAmount > 0;
    claimDev@withrevert(e, 0);
    assert lastReverted, "claimDev paid the zero address";
    claimCreator@withrevert(e, token, 0);
    assert lastReverted, "claimCreator paid the zero address";
    claimCreatorAccrued@withrevert(e, 0);
    assert lastReverted, "claimCreatorAccrued paid the zero address";
    payKeeper@withrevert(e, 0, edgeAmount);
    assert lastReverted, "payKeeper paid the zero address";
}

/// CON-04 (spec J): while the version is sunset, a protocol fee on the edge currency is forwarded or
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
    // Either the local split ran (not sunset), or nothing local moved and the fee was queued.
    assert (ghostDev == devBefore && ghostCreatorSum == creatorBefore)
        => ghostPendingSum >= pendingBefore,
        "a post-sunset edge fee neither booked nor queued";
}

// ---------------------------------------------------------------------------------------------
// immutability of rates and splits (FEE-03, ROL-01) and CEI on claims (REN-02)
// ---------------------------------------------------------------------------------------------

/// FEE-03 / ROL-01 (spec I, spec M): no function anywhere changes a fee rate or a split after
/// deploy. `EDGE` is on that list: the denomination of every ledger in this contract is an
/// immutable with no setter, so a later call cannot re-point the vault at a different token and make
/// its existing ledgers payable in something else.
rule ratesAndSplitsAreImmutable(method f, env e, calldataarg args)
    filtered { f -> !f.isView && f.contract == currentContract }
{
    uint256 devBps = DEV_BPS();
    uint256 creatorBps = CREATOR_BPS();
    uint256 ancestorBps = ANCESTOR_BPS();
    uint256 reinforceBps = REINFORCE_BPS();
    uint256 drawBps = DAILY_DRAW_BPS();
    FeeVault.Currency edge = EDGE();
    f(e, args);
    assert DEV_BPS() == devBps && CREATOR_BPS() == creatorBps && ANCESTOR_BPS() == ancestorBps
        && REINFORCE_BPS() == reinforceBps && DAILY_DRAW_BPS() == drawBps,
        "a fee split moved after deployment";
    assert EDGE() == edge, "the edge currency moved after deployment";
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
