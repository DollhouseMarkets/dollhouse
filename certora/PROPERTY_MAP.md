# Certora property map

Every rule and invariant in `certora/specs/`, mapped back to its `docs/spec/PROPERTIES.md` ID.

**STATUS AS OF REVIEW 6: `FamilyHook` AND `RoundManager` HAVE VERDICTS. `FeeVault` HAS NONE, AND
EVERY DOCUMENTED WORKAROUND HAS NOW BEEN TRIED.** Ten jobs were submitted on 2026-09-15. The first
four failed at scene load with an internal Prover error before any rule was checked
(`certora/RESULTS-review-5.md`, finding P-1). Two then ran after `contracts/FeeVault.sol` was taken
out of the `FamilyHook` and `RoundManager` scenes, which is what gets a job past P-1. The last four
were attempts to get `FeeVault.conf` itself past P-1, and **all four were refused in the same way**:
summarizing the edge token instead of linking it (**S-14**), restructuring the contract so that no
expression holds two external-call return buffers (**S-15**, measured and then reverted), the
Prover's own `-relaxedPointerSemantics` for that method (**S-17**, identical crashing block id) and a
verification-only compilation change (**S-18**, the block id moved and the crash did not). A fifth
lever, an internal CVL summary of `holdings`, cannot be written at all: `holdings` is `public` and
the Prover's internal-function finders only cover `internal` and `private` functions (**S-19**).
**None of the five is available as a workaround and none should be re-run. FeeVault: 0 of 30
verified, 30 never checked.**

**REVIEW 5g ADDS A SIXTH LEVER AND IT DOES NOT CHANGE THAT COUNT EITHER.** A verification-only
harness that inherits `FeeVault` and overrides `holdings` (so the crashing balance reads leave
`receiveForward`'s path) cannot be type-checked: with a DERIVED contract as the verified one, CVL
accepts no spelling of the `Currency` key of the inherited `ledgerTotal` mapping, and the two hooks
on that mapping carry seven of the rules below (**S-20**). No submission was spent. Every FeeVault
row still reads "authored, not run".

- **RoundManager: 31 of 36 verified.** One CONTRACT finding, **C-1** (`adoptGenesis` uses
  `_head != address(0)` as its once-only flag, so adopting `address(0)` leaves the flag unset and a
  second adoption succeeds; latent, because the factory constructor refuses a zero or codeless
  genesis token; reported and **PATCHED AT REVIEW 5e**, with a dedicated `_genesisAdopted` flag and
  an explicit zero-`token` refusal). One spec finding, **S-12**.
- **FamilyHook: 17 of the 21 rules that ran are verified**, out of 23 authored. **Two are DISABLED**
  for **S-10**; one failure is a spec defect (**S-11**); three are the FEE-01 reachability ladder
  (**S-13**).
- **FeeVault: every row below still says "authored, not run"**, and that is the literal truth: its
  conf has never loaded, through eight submissions and two workarounds. Nothing in this file may be
  cited as evidence about the review-5 vault.

**S-8 IS WITHDRAWN.** The first pass recorded that the two `Sload` hooks type-check once the key type
is spelled `IFamilyHook.PoolId`. They do not, and neither does any other spelling tried; the
evidence table is in `RESULTS-review-5.md` under **S-10**. So note 10's neighbour risk resolves
AGAINST the hooks: `protocolFeeOnlyAtTheEdge` and `theEdgeFeeIsSuppressedDuringTheSnipeWindow` are
commented out in the spec with a restore note and DO fall back to the fuzz and unit tiers. They are
**not expressible** here, not unproved, and nothing green stands in for them.

The review-5 status note now applies to `FeeVault.spec` ALONE. Its rows below carry the LAST RUN
verdict, which was review-4's, next to what the re-base did to the rule, and every one of them is to
be read as evidence about the code it was written against rather than about the code that is there
now. That is review-4's own standing lesson (finding S-4): when the contract under a verified rule
changes, re-DERIVE the rule and re-run it; do not carry the green forward. `FamilyHook` and
`RoundManager` rows carry REVIEW-5b verdicts and are evidence about the contracts at this HEAD.
`Sleeve.spec` is untouched by the review-5 diff and keeps its review-3 verdicts. `DevVesting.spec` is
DELETED, with the contract it verified.

Status values: **verified** (ran and was not violated, and its sanity check passed), **violated**
(ran and produced a counterexample, see RESULTS for the assessment), **vacuous** (ran, reported "not
violated", but failed its `rule_sanity` vacuity check, so it proves nothing), **timeout**, **needs
harness** (runs only against a harness contract), **not expressible** (cannot be stated in Certora at
all, with the reason and the tier it belongs to), **authored, not run** (written at review 5 and
still awaiting a run, which at review 5b means the whole of `FeeVault.spec`; see
`certora/RESULTS-review-5.md`), and **disabled** (present in the spec but commented out, with the
reason and the restore condition, so that nothing passes vacuously in its place).

## FeeVault.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| FEE-11, SUP-04 | FeeVault.spec | `solvency` (invariant) | RE-BASED, authored not run. Now `ledgerTotal[c] + (c == EDGE ? deployerCredit : 0) <= holdings(c)` with `EDGE` the linked edge token, and `holdings` an ERC-20 balance plus unredeemed claims rather than an ETH balance. The INEQUALITY is load-bearing at review 5 in a way it was not before: a donation of the edge currency raises `holdings` and credits nothing, and no path sweeps the difference. Last run (review-3): verified on the base, the transient step and 17 / 20 methods; the 3 left are the accrual paths, where the fee claim is minted to the vault by the HOOK before `accrue` is called |
| FEE-10 | FeeVault.spec | `edgeMirrorsAreNonNegative` (invariant, was `ethMirrorsAreNonNegative`) | RENAMED and re-keyed, authored not run. Last run (review-4): **verified (22/22)** |
| FEE-10 | FeeVault.spec | `edgeLedgerDecomposition` (invariant, was `ethLedgerDecomposition`) | RE-BASED, authored not run. The mirrors are `reinforcementEdge`, `edgeBidEarmark` and the `reinforcementBalance[edge]` key (review 4 used the `address(0)` key, which is no longer a currency at all). The `accrue` `preserved` block states the caller's NEW convention, `parentToken == edge <=> currency == EDGE`, because `_collect` no longer passes a genesis marker. Last run (review-4): violated on 2 methods (`accrue`, `forwardProtocolFee`); checklist item 5 is still open against it |
| FEE-08 | FeeVault.spec | `accrueConservesTheFee` | re-based (edge mirrors), authored not run. Last run: **verified**, upper bound only, see note 1 |
| FEE-08 | FeeVault.spec | `accrueMovesLedgerTotalByTheFee` | re-based (`ledgerTotal[EDGE]`), authored not run. Last run: **verified** |
| FEE-10 | FeeVault.spec | `onlyAccrualPathsCredit` | CORRECTED, authored not run. `flushForward` is added to the enumeration: review 4b's dead-successor branch calls `_book` and therefore credits the local ledgers out of the queue, which this list had not caught. Same class of stale claim as finding S-4, found by re-derivation rather than by a run. Last run: **verified**, against an enumeration that was already one writer short |
| SUP-04 | FeeVault.spec | `onlyAccrualPathsRaiseLedgerTotal` (NEW at review-5) | authored not run. REVIEW5_DESIGN decision 10: an unsolicited edge-currency transfer into the vault is never sweepable. `ledgerTotal[EDGE]` rises only on the accrual, forward and earmark paths, so a donation cannot make itself claimable, and `solvency`'s inequality is what leaves the surplus unreachable |
| ROL-07 | FeeVault.spec | `creatorTransferIsALedgerMove` | unchanged, authored not run. Last run: verified |
| FEE-11 | FeeVault.spec | `receiveForwardRefusesAnUndeliveredAmount` (NEW at review-5) | authored not run. `receiveForward(attribution, amount)` is non-payable now, so the amount is a CLAIM rather than value that arrived with the call. The contract re-checks `ledgerTotal[EDGE] <= holdings(EDGE)` after crediting and reverts `NotDelivered`; this is that guard |
| RND-11 | FeeVault.spec | `depositEdgeBidEarmarkRefusesAnUndeliveredAmount` (NEW at review-5) | authored not run. The same shape on the forfeit deposit, and it is what makes the RoundManager's try / catch meaningful: a forfeit that did not arrive REVERTS the deposit, which is caught and booked into `pendingForfeits` |
| FEE-10 | FeeVault.spec | `everyEntrypointRefusesNativeValue` (NEW at review-5) | authored not run. `receive()` is gone and no entrypoint is payable, so the vault can never acquire native value it has no code to send out |
| BID-07 | FeeVault.spec | `drawNeverExceedsTheBucket` | re-based (`drawableEdge`), authored not run. Last run: verified |
| BID-07 | FeeVault.spec | `bucketNeverExceedsCap` (invariant) | re-based (`drawableEdge` / `claimableEdge`), authored not run. Last run (review-4): violated on 5, Prover imprecision in the Fenwick `_prefix` walk (the `BWAnd` abstraction) at `loop_iter: 3`, which cannot be raised here. BID-07 holds at U/F |
| PUR-05, BID-07 | FeeVault.spec | `drawNeverExceedsTheGenerationsClaim` | re-based (`claimableEdge`), authored not run. Last run: **verified** |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUp` | re-based, authored not run. Last run: **verified**; surfaced finding F-2, closed in code |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUpAtAnyClock` | re-based, authored not run. Last run: **verified**, the F-2 fix confirmed with NO clock precondition |
| BID-05 | FeeVault.spec | `payKeeperIsBoundedByDeployerCredit` | unchanged, authored not run. Last run: verified |
| BID-14 | FeeVault.spec | `deployerCreditSettles` (invariant) | unchanged, authored not run. Last run: **verified (20/20)** |
| BID-05, FEE-10 | FeeVault.spec | `valueLeavesOnlyOnPayoutMethods` | RE-BASED ONTO THE TOKEN BALANCE, authored not run. Through review 4 the measure was `nativeBalances[currentContract]`, which after the re-base can no longer fall at all (`_sendEth` is gone), so carrying the rule forward unchanged would have kept a green verdict for a reason that has nothing to do with the claim. It measures the LINKED edge token's balance of the vault now, and `consumeEdgeEarmark` / `deliverForward` join the declared-payout list |
| BID-05 | FeeVault.spec | `onlyBidDeployerHooks` | re-based (`consumeEdgeEarmark`), authored not run. Last run: verified |
| CON-05 | FeeVault.spec | `pendingForwardTotalIsTheSum` (invariant) | unchanged, authored not run. Last run: **verified (20/20)** |
| CON-05 | FeeVault.spec | `flushForwardConserves` | kept in the TWO-SIDED review-4 shape (finding S-4), re-keyed to `EDGE`, authored not run. Last run: **verified** |
| CON-05 | FeeVault.spec | `localBookingRequiresAgedEvidence` | re-keyed to `EDGE`, authored not run. Last run: **verified** |
| CON-05 | FeeVault.spec | `unresolvedSuccessorIsNeverEvidence` | unchanged, authored not run. Last run: **verified** |
| CON-05 | FeeVault.spec | `deadEvidenceMovesOnlyOnTheForwardingPaths` | re-signed (`receiveForward` takes two arguments now), authored not run. Last run: **verified** |
| CON-04 | FeeVault.spec | `candidateAttributionsCrossAsUnattributed` | unchanged, authored not run. Last run: **verified** |
| BID-05, FEE-10 | FeeVault.spec | `noPayoutPathCanBurnTokensAtTheZeroAddress` (was `noPayoutPathCanBurnEthAtTheZeroAddress`) | RENAMED and re-based on `_sendToken`'s `BadRecipient` guard, authored not run. This carries finding S-5, which review 4 left FIXED BUT NOT RUN: the `require amount > 0` that scopes the rule past `payKeeper`'s zero-amount early return is in the spec and has still never been checked by a run |
| CON-04 | FeeVault.spec | `postSunsetFeesAreNeverBookedLocally` | unchanged, authored not run. Last run: **verified**; `isSunset()` is NONDET, see note 2 |
| FEE-03, ROL-01 | FeeVault.spec | `ratesAndSplitsAreImmutable` | STRENGTHENED, authored not run. `EDGE` joins the immutable list: no call may re-point the vault at another token and make its standing ledgers payable in something else. Last run: verified |
| REN-02 | FeeVault.spec | `claimZeroesBeforePaying` | unchanged, authored not run. Last run: verified |

## RoundManager.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| RND-09 | RoundManager.spec | `canonicalIsWriteOnce` (invariant) | **review-5b: verified on the base, the transient step and 15 of 17 methods**; VIOLATED on `adoptGenesis` (C-1) and `finalize` (the review-4 delegation item, checklist item 3). Prior note: re-based (the third writer is `adoptGenesis`), authored not run. Its PUR-02 note gains cases j = 0 and 1: j = 0 is the ADOPTED token's entry, j = 1 an ordinary crowned link whose parent is that token. Last run (review-4): verified on 15 / 17; the 2 left are the DELEGATION scoping item (checklist item 4) |
| RND-09 | RoundManager.spec | `onlyFinalizeOrAdoptionWritesHistory` | **review-5b: verified (17/17 methods)**. Prior note: re-based head-writer set, authored not run. Last run: **verified** |
| RND-09, PAR-02 | RoundManager.spec | `historyEntriesAreImmutable` | **review-5b: verified on 14 of 17 methods**; VIOLATED on `addCandidate`, `adoptGenesis` (C-1) and `finalize`, all with "an existing entry was re-parented" (the delegation item). Prior note: unchanged, authored not run. Last run (review-4): violated on 3 / 14, the delegation scoping item |
| RND-09 | RoundManager.spec | `historyLengthIsMonotone` | **review-5b: verified (17/17 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-09 | RoundManager.spec | `reverseIndexIsConsistent` (invariant) | **review-5b: verified on the base, the transient step and 14 of 17 methods**; VIOLATED on `addCandidate`, `adoptGenesis` (C-1) and `finalize` (the delegation item). Prior note: unchanged, authored not run. Last run (review-4): violated on 3 / 17, same delegation item |
| PAR-01 | RoundManager.spec | `pairingRightsAreWriteOnce` | **review-5b: verified (17/17 methods)**. Prior note: re-based head-writer set, authored not run. Last run: **verified at review-3**, and only after spec defect S-3 (the enumeration had missed the third head writer). That writer was RENAMED by review 5, not removed, so the same defect is one careless edit away |
| PAR-01 | RoundManager.spec | `headIndexOnlyGrows` | **review-5b: verified (17/17 methods)**. Prior note: unchanged, authored not run. Last run: **verified at review-3** |
| RND-09, CON-01 | RoundManager.spec | `adoptGenesisIsOnceAndFactoryOnly` (NEW at review-5) | **VIOLATED at review-5b** - finding **C-1**, a contract finding: `adoptGenesis` uses `_head != address(0)` as its once-only flag, so adopting `address(0)` leaves the flag unset and a second adoption succeeds. Latent (the factory constructor refuses a zero or codeless genesis token). REPORTED, NOT PATCHED. Prior note: authored not run. REVIEW5_DESIGN decision 1 and review 5b item 6: adoption is factory-only and once, seats index 0 with no parent and no pool key, and a continuation stack (which has a `priorRegistry`) can never adopt at all |
| RND-07 | RoundManager.spec | `finalizeIsIdempotent` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-08 | RoundManager.spec | `noNewRoundBeforeFinalize` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| RND-13 | RoundManager.spec | `thresholdMovesOnlyInFinalize` | **review-5b: verified (17/17 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-11 | RoundManager.spec | `winnersBondIsReturned` | **review-5b: verified**. Prior note: RE-DENOMINATED, authored not run, AND WEAKER THAN IT WAS. The bond is an ERC-20 escrow now, and the edge token cannot be linked in this conf (`edgeToken()` is `canonical(0)`, a delegating storage read, not an immutable), so `transfer` is NONDET and a recipient's balance does not move under this model. The claim is restated over the two quantities this contract owns: the escrow is released and never grows across a finalize, and a creator's pull-fallback credit is never reduced. The delivered-to-the-creator half moves to the unit and fork tiers |
| RND-11 | RoundManager.spec | `losersBondsAreForfeited` | **review-5b: verified**. Prior note: re-based, authored not run. Arrival side is `FeeVault.spec`'s `depositEdgeBidEarmarkRefusesAnUndeliveredAmount`, see note 3 |
| RND-11 | RoundManager.spec | `addCandidateRefusesAnUnderDeliveredBond` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. Review 5c item 2: the balance check counts BOTH ledgers (`bondEscrow + pendingForfeits`), so a held forfeit can no longer stand in for a bond that was never delivered |
| RND-12 | RoundManager.spec | `registrationNeverPullsMoreThanTheQuotedBond` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. The `maxBond` ceiling of review 5b item 5 is enforced in `FamilyFactory`, which has no conf of its own; what this contract owes the property is that there is nothing ELSE it could be charged. `addCandidate` reverts `WrongBond` unless the amount equals `rounds[roundId].bondAmount`, and the escrow grows by exactly that |
| RND-11 | RoundManager.spec | `finalizeBooksWhatItCouldNotDeliver` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. Review 5b item 1: booked equals delivered plus pending. `pendingForfeits` can never grow by more than `bondEscrow` fell in the same finalize, which is what makes a deferred forfeit un-double-spendable against the escrow |
| RND-11 | RoundManager.spec | `pendingForfeitsMoveOnlyOnFinalizeOrFlush` (NEW at review-5) | **review-5b: verified (17/17 methods)**. Prior note: authored not run. The held-forfeit ledger has exactly two writers; nothing else may write off what is owed to the vault |
| REN-02 | RoundManager.spec | `flushForfeitsZeroesBeforeDelivering` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. The retry clears the ledger before either external call, so a reentrant flush finds nothing to send |
| RND-11 | RoundManager.spec | `theBondPushesAreSelfOnly` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. `pushRefund` / `pushForfeit` are `NotSelf`-gated, which is what makes the `try` indirection safe to expose. "Finalize never reverts" is NOT expressible as one rule, because finalize has legitimate revert conditions of its own (`NoRound`, `EndNotSettled`, `SubmissionWindowOpen`); what review 5b actually claims is carried by `finalizeBooksWhatItCouldNotDeliver`, which holds on both branches |
| REN-01 | RoundManager.spec | `guardedFactoryEntrypointsCannotBeReentered` (NEW at review-5) | **review-5b: verified**. Prior note: authored not run. Review 5d item 1, stated over the lock word itself: while `_locked != 1` neither `openRoundIfIdle` nor `addCandidate` may be entered. This is the ONE review-5 rule whose EXPRESSIBILITY is unconfirmed, because it reads a PRIVATE storage variable directly from CVL; if the Prover refuses, it is recorded as not expressible here and the property stays with `Review5d.t.sol`, which asserts the guard by name |
| RND-04, RAN-03 | RoundManager.spec | `requestEndIsOnceAndNotBeforeT` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified with a FULLY ARBITRARY `pin()`** |
| RND-05 | RoundManager.spec | `trueEndFallsInsideTheWindow` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-06, RAN-06 | RoundManager.spec | `timeoutFallbackSettlesAtT` | **review-5b: verified**. Prior note: unchanged, authored not run. Documentary assertion, see note 5 |
| RND-06, RAN-04 | RoundManager.spec | `endIsSettledAtMostOnce` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| RND-01 | RoundManager.spec | `scheduleIsPureInN` | **review-5b: verified (17/17 methods)**. Prior note: unchanged, authored not run. Last run: verified |
| RND-01 | RoundManager.spec | `scheduleBounds` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified**; SPEC-GAP 7.7 encoded (scaled `W`) |
| RND-02 | RoundManager.spec | `lateEntryClosesBeforeTheClosingWindow` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| RND-01, SCR-06 | RoundManager.spec | `theCoarseRingCoversTheScoredSpan` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| SCR-14 | RoundManager.spec | `theConstructorsWindowGuardMatchesTheGetters` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| SCR-14 | RoundManager.spec | `theScoredWindowAlwaysExceedsOneCoarseSlot` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-12 | RoundManager.spec | `bondSaturates` | **review-5b: verified**. Prior note: re-based onto `BOND_BASE` / `BOND_MAX` (the `_WEI` suffix went with the denomination), authored not run. Last run: verified |
| RND-12 | RoundManager.spec | `bondIsMonotoneInDepth` | **review-5b: verified**. Prior note: re-based onto `BOND_BASE`, authored not run. Last run: **verified** with `BOND_DOUBLING_EVERY` pinned to 4, a recorded scoping restriction |
| RND-15 | RoundManager.spec | `maxIndexIsRespected` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** |
| RND-03, ROL-01 | RoundManager.spec | `noTransitionIsPrivileged` | **review-5b: verified on `finalizeDeterministic` and `requestEnd`**; VIOLATED on `claimRefund`, `finalize`, `flushForfeits`, `fulfilEnd`, `pushForfeit`, `pushRefund` (finding **S-12**: the exclusion list is short by review-5s self-only pushes and the per-caller pull claim); **UNKNOWN** on `submitScore`, the timeout open since review 1. Prior note: re-based exclusion list (`adoptGenesis` replaces `registerGenesis`, `addCandidate` re-signed), authored not run. Last run (review-4): violated on 3 plus 1 timeout (`submitScore`) |
| RND-03, ROL-02 | RoundManager.spec | `sunsetTouchesNothingElse` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| CON-01 | RoundManager.spec | `adoptionHappensAtMostOnce` | **review-5b: verified (17/17 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| PUR-02 (half) | RoundManager.spec | `canonicalIsWriteOnce` + `historyEntriesAreImmutable` + `onlyFinalizeOrAdoptionWritesHistory` | **review-5b: the three rules behind this half are verified on 14 to 15 of their 17 methods each and VIOLATED on `adoptGenesis` (C-1), `finalize` and, for two of them, `addCandidate`.** The j = 0 case is exactly the one C-1 breaks. Prior note: the half of PUR-02 this tier can falsify, since the purse destination IS `canonical(j)` and is not an argument: it is fixed once the round crowns it. REVIEW 5 EXTENDS THE CASE LIST TO j IN {0, 1}: j = 0 is the adopted token, whose entry `adoptGenesis` writes once, and j = 1 is an ordinary crowned link whose parent is that token. The landing step (`Locker.depositBid` into the summarized singleton) is in the not-expressible table below |

## Sleeve.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| SLV-01 | Sleeve.spec | `rangeAddThenPointQueryIsTheClosedForm` | needs harness - still violated at review-3, but the counterexample now sits exactly ON the new bounds (`before = -(2^200 - 1)`, `c1 = -(2^160 - 2)`): one power of two tighter (tree `< 2^190`, coefficients `< 2^128`) is the next step |
| SLV-04 | Sleeve.spec | `pointQueryIsAdditive` | needs harness - still violated at review-3, same story as SLV-01 above |
| SLV-06 | Sleeve.spec | `genesisTakesTheWholeSleeveAtMZero` | needs harness - **verified at review-3**: bounding the tree pre-state (`< 2^200`) and the WAD-scaled sleeve (`< 2^160`) removed the `unchecked`-accumulator overflow. The first SLV rule to prove at a non-vacuous loop bound |
| SLV-05 | Sleeve.spec | `genesisWeightIsTwiceTheTerminalWeight` | needs harness - timeout at review-2, **violated at review-3** (the bounds made it tractable enough to produce a counterexample); still bounded to `M <= 64`, a recorded scoping restriction |
| SLV-02 | Sleeve.spec | `everyAncestorShareIsNonNegative` | needs harness - timeout at review-2 (`loop_iter: 14`) |
| SLV-03 | Sleeve.spec | `sumOfSharesNeverExceedsTheSleeveSmallM` | needs harness - **timeout** at review-2 (`loop_iter: 14`). The review-1 vacuity is SOLVED: its cause was `loop_iter: 12` against a 13-deep Fenwick walk, not the `2^128` literal. Restated as a delta at WEI granularity. SLV-03 stays UNPROVED here; bound the tree pre-state and the coefficients next |
| SLV-03 | Sleeve.spec | `noShareExceedsTheSleeve` | needs harness - **timeout** at review-2, same story; restated as a delta against the WAD-scaled sleeve |
| SLV-02 | Sleeve.spec | `noIndexOutsideTheRangeIsCredited` | needs harness - timeout at review-2, **violated at review-3**, same loose-bound cause |
| SLV-07 | Sleeve.spec | `indexPastMaxReverts` | needs harness - **verified at review-2 with the `sleeve > 0` precondition REMOVED**: review-2 fix 6 (the bounds check before the zero short-circuit) confirmed |
| SLV-07 | Sleeve.spec | `reversedRangeReverts` | needs harness, verified|

## FamilyHook.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| SCR-01, SCR-02 | FamilyHook.spec | `scoreIsMonotoneInNetParentAbsorbed` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| SCR-02 | FamilyHook.spec | `onlyTheSwapPathMovesTheScore` | **review-5b: verified (3/3 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| SUP-06 | FamilyHook.spec | `donationsAreImpossible` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| SUP-05 | FamilyHook.spec | `liquidityIsARatchet` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| SCR-04 | FamilyHook.spec | `averageOverIsTheAccumulatorDifference` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified**, see note 7 |
| SCR-14 (was SPEC-GAP 7.12) | FamilyHook.spec | `averageOverRevertsOnACollapsedWindow` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified**, and the gap is CLOSED in the code's favour |
| SCR-10 | FamilyHook.spec | `noRingEntryIsWrittenPastTheBell` | **review-5b: verified (3/3 methods)**. Prior note: STRENGTHENED, authored not run. The `nominalEnd == 0` exemption is DELETED, not carried: there is no pool class that never freezes, and leaving the disjunct in would let a registered pool with a zero end pass this rule silently. Last run: **verified** in its weaker form |
| SCR-10 | FamilyHook.spec | `endSealIsWriteOnce` | **review-5b: verified (3/3 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| SCR-10 | FamilyHook.spec | `theEndSealIsOnlyLaidPastTheBell` | **review-5b: verified (3/3 methods)**. Prior note: re-based, authored not run. It needed THREE preconditions at review 4, two of them about the genesis pool's zero end; it needs TWO now, because that class is gone. Last run: **verified at the re-run** |
| SCR-13 | FamilyHook.spec | `registerPoolRefusesAPoolWithoutAPublishedEnd` (was `registerPoolRefusesACandidateWithoutAPublishedEnd`) | **review-5b: verified**. Prior note: GENERALIZED, authored not run. The review-4 form quantified only over `isEdge == false`, because the genesis pool was allowed to carry 0; it is quantified over both values now. Last run: **verified** in its restricted form |
| SCR-10, SCR-13 | FamilyHook.spec | `everyRegisteredPoolHasAPublishedEnd` (NEW at review-5) | **review-5b: verified (3/3 methods)**. Prior note: authored not run. The registry-wide inductive invariant the `BadNominalEnd` guard buys, and the review-5 replacement for `genesisIsNeverSniped`: the ring freeze and the end seal are stated over EVERY registered pool, so something has to prove every registered pool has an end to freeze at |
| SCR-05 | FamilyHook.spec | `aSlotIsWrittenOnceByItsFirstSwap` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified**, after two preconditions, the second of which is the 2^64 truncation finding |
| SCR-06 | FamilyHook.spec | `theFastRingSpansTheRandomEndWindow` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| FEE-04 | FamilyHook.spec | `snipeTaxBounds` | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: verified |
| FEE-04, FEE-06 | FamilyHook.spec | `summedRatesStayBelowOne` | **review-5b: VIOLATED on its third assertion only** (finding **S-11**: `hopFeePpm` is an unpinned immutable and the Prover may choose 0). The two pairwise FEE-04 bounds are **verified**. Prior note: re-based, authored not run. The pairwise bound is the same; WHAT ENFORCES IT MOVED. Through review 4 the two large rates were mutually exclusive BY POOL CLASS and the exclusion lived in the factory; a round-one pool is now both edge and freshly opened, so the exclusion is in TIME and in this contract. A third assertion pins that the three rates really would overlap, so the suppression below cannot quietly become dead code. Last run: **verified** |
| FEE-04, FEE-06 | FamilyHook.spec | `theEdgeFeeIsSuppressedDuringTheSnipeWindow` (NEW at review-5) | **DISABLED at review-5b** (finding **S-10**, same cause). NOT EXPRESSIBLE here; falls back to the fuzz and unit tiers. Prior note: authored not run. REVIEW5_DESIGN decision 8, the load-bearing one: `protocolPpm != 0` implies the pool's snipe window has closed. Without it the summed parent-side rate exceeds 100% and the exact-output gross-up has no finite answer, so every parent-paying exact-output swap in a new round-one pool's first three seconds would revert. Stated against the swapped pool's own `tradingStart`, recorded by an `Sload` hook at the point `_collect` reads it |
| FEE-03 | FamilyHook.spec | `feeRatesAreImmutable` | **review-5b: verified (3/3 methods)**. Prior note: unchanged, authored not run. Last run: **verified** |
| FEE-01 | FamilyHook.spec | `protocolFeeOnlyAtTheEdge` (was `protocolFeeOnlyOnTheGenesisPool`) | **DISABLED at review-5b** (finding **S-10**: the `PoolId` key type of the `Sload` hook cannot be named in CVL at 8.19.2). NOT EXPRESSIBLE here; falls back to `test/properties/Fees.prop.t.sol` and the review-5 unit tests. S-8 is withdrawn. Prior note: RE-DERIVED, authored not run. The review-4 predicate cannot be carried: it read the flag out of the `parentToken` word the hook handed the vault, and `_collect` no longer encodes a pool class there. The predicate is `p.isEdge` itself now, recorded by an `Sload` hook in the instruction that computes `protocolPpm`. Last run: not violated but **VACUOUS** (the counter it reads has no writer). FEE-01's per-pool half stays UNPROVED, and the review-5 experiment is README item 2 |
| FEE-01 | FamilyHook.spec | `beforeSwapIsReachable` (`satisfy`) | **review-5b: verified**. Prior note: unchanged, authored not run. Last run: **verified** (rung 0) |
| FEE-01 | FamilyHook.spec | `theFeeMintIsReachable` (`satisfy`) | **review-5b: verified (reachable)**, which is exactly where the FEE-01 ladder still stops. Prior note: unchanged, authored not run. Last run: **verified** (rung 0.5) |
| FEE-01 | FamilyHook.spec | `anyFeeAccrualIsReachable` (`satisfy`) | **review-5b: VIOLATED (unreachable)** - finding **S-13**. Prior note: unchanged, authored not run. Last run: **violated**, and review-4's experiment (an EXACT `FeeVault.accrue` entry on the linked vault) is answered in the negative. Next: an `Sstore` hook on the linked vault's own `ledgerTotal`, and check whether `optimistic_fallback` swallows the vault call |
| FEE-01 | FamilyHook.spec | `someProtocolFeeIsReachable` (`satisfy`) | **review-5b: VIOLATED (unreachable)** - finding **S-13**. Prior note: unchanged, authored not run. Last run: **violated** (rung 2) |
| FEE-01 | FamilyHook.spec | `oneProtocolFeeAtTheEdgeIsReachable` (`satisfy`, was `oneProtocolFeeAtTheEthEdgeIsReachable`) | **review-5b: VIOLATED (unreachable)** - finding **S-13**. With the vault UNLINKED and the exact summary gone, three hypotheses for FEE-01 are dead; `optimistic_fallback` is the one left. Prior note: renamed, authored not run. Last run: **violated** (rung 3) |
| FEE-04 | FamilyHook.spec | `genesisIsNeverSniped` | **DELETED at review-5.** It asserted `isGenesis => tradingStart == 0` about a pool class that no longer exists, and the guard behind it (`GenesisHasNoSnipeWindow`) is gone from the contract with it. A round-one pool IS sniped, deliberately, and the fee it does not pay while that is true is `theEdgeFeeIsSuppressedDuringTheSnipeWindow` |
| FEE-04 | FamilyHook.spec | `registerPoolRefusesAGenesisSnipeWindow` | **DELETED at review-5**, with the guard it stated |

## Not expressible in these specs

| PROPERTIES ID | reason | belongs to |
|---|---|---|
| FEE-01 (per-route count) | `PoolManager.swap` is summarized NONDET, so the prover never executes legs 2..L of a route; the fee count over a whole `swapPath` cannot be counted inside a single-pool hook proof. | fork (K), FEE-01 already carries tier K |
| ROU-02 | The comparison is "routed swap vs equivalent direct `PoolManager` swap, wei for wei"; both sides require a real PoolManager. Under NONDET both sides are unconstrained and the rule is vacuous. | fork (K) |
| REN-01 (the v4 unlock flag) | "Reachable while the PoolManager unlock flag is set" is a property of the *singleton's* transient lock, which is summarized away. Certora cannot see the flag: the guard is an `exttload` on the summarized PoolManager, so the Prover would have to model that singleton's transient storage. NOTE the review-5 split: this row is about `notInsideUnlock` only. The OTHER reentrancy guard, the plain `_locked` word review 5d put on `openRoundIfIdle` / `addCandidate`, IS local to `RoundManager` and is stated as `guardedFactoryEntrypointsCannotBeReentered`. | stateful invariant (I) + fork (K) |
| PUR-02 (the landing step) | That the liquidity actually LANDS under `canonical(j)` is `locker.depositBid(roundManager.poolKeyOf(j), ...)` - an external call from `BidDeployer`, which has no spec or conf of its own, into the Locker and on into the v4 singleton, every entrypoint of which is summarized NONDET. CVL has no event predicate either, so `PurseDeployed` is not a usable witness. A `BidDeployer.spec` summarizing `_.depositBid(...)` into a ghost that records `(key, childToken)` is what would make it expressible. | fork (K): `fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing`, fuzz (F): `properties/Purse.prop.t.sol` |
| PUR-02 ("a loser never receives purse liquidity") | STRUCTURAL, and deliberately not stated as a rule: the destination is a pure function of `j` computed inside the deployer, and since review 3 there is no rank, no board and no caller-supplied token for a rule to quantify over. | fuzz (F), fork (K), as above |
| SUP-01 (supply constancy) | The family token is an EIP-1167 clone whose implementation is linked at deploy time; the clone has no verifiable bytecode of its own for the Prover to load. | unit / fuzz / stateful invariant (U, F, I) |
| SUP-04 (no protocol contract holds family supply) | REVIEW 5 restates SUP-04 in two halves. The vault half (the vault's edge balance is its ledgers plus donations) IS here, as `solvency` plus `onlyAccrualPathsRaiseLedgerTotal`. The other half, that no protocol contract holds family-token supply, quantifies over every contract in the stack and over a clone with no bytecode, so it is not a claim any single-contract proof can make. | stateful invariant (I): `Invariants.prop`, fork (K) |
| RND-11 (the bond reaches the creator) | NEW AT REVIEW 5, and a real loss of coverage: the bond is an ERC-20 escrow now and the edge token cannot be linked in `RoundManager.conf`, because `edgeToken()` is `canonical(0)`, a delegating storage read rather than an immutable. With `transfer` summarized NONDET a recipient's balance does not move, so `winnersBondIsReturned` can only assert what this contract owns (the escrow is released, the pull-fallback credit is never reduced). | unit (U): `Review5b.t.sol` / `Review5c.t.sol`, fork (K) |
| SLV-03 (unbounded `M`) | The sum over `[0, M]` for symbolic `M` is a quantified sum over a symbolic range, which CVL cannot express. Bounded to `M <= 3` here. | Halmos (H) at bounded depth, fuzz (F) at full depth |
| SCR-04 (exact reconstruction) | Requires replaying an arbitrary swap history through both checkpoint rings; the ring walk plus the swap sequence is beyond the loop bound the Prover can discharge. | Halmos (H), stateful invariant (I) |
| BID-01..BID-04, BID-08..BID-13 | TWAP reads, band guards and tick arithmetic all bottom out in `SqrtPriceMath` / `LiquidityAmounts`, which PROPERTIES section 6 summarizes NONDET, the curve math belongs to Halmos, not Certora. | Halmos (H), fork (K) |
| RAN-01, RAN-02 | BN254 pairing on precompile `0x08`, summarized NONDET bool. Signature verification cannot be proved here. | unit (U), fork (K) |
| CON-03, CON-10 | Bounded staticcall walks over an unknown chain of prior/successor deployments: the callees are contracts the Prover has no bytecode for. | unit (U), fork (K) |

## Notes

1. The ancestor sleeve is stored as three WAD-scaled Fenwick coefficient trees, not a scalar ledger,
   so no storage hook can mirror "the sleeve credited by this call". Every FeeVault sum therefore
   omits the sleeve term. Each bound stays sound (the omitted term is non-negative), but FEE-08
   becomes an upper bound on this contract; the sleeve's own conservation claim is SLV-03 in
   `Sleeve.spec`.
2. `RoundManager.isSunset()` is summarized NONDET, so the post-sunset booking rule is stated over the
   booking ghosts rather than over the real round state.
3. `FeeVault.depositEdgeBidEarmark(uint256)` is summarized NONDET in `RoundManager.spec`; the
   arrival side of a forfeited bond is covered by `onlyAccrualPathsCredit` and
   `depositEdgeBidEarmarkRefusesAnUndeliveredAmount` in `FeeVault.spec`.
4. "`requestEnd` pins a strictly future beacon round" is a property of `IRandomnessSource.pin()`,
   which is summarized NONDET. What is proved here is the once-per-round and not-before-`T` half.
5. The deterministic-fallback branch writes `tradingEnd = nominalEnd` with no beacon word involved.
   With `pin`/`fulfil` summarized, the rule reduces to a documentary assertion plus
   `endIsSettledAtMostOnce`, which is the load-bearing half.
6. `sumOfSharesNeverExceedsTheSleeveSmallM` is written out for `M <= 3` because CVL cannot quantify a
   sum over a symbolic range. The depth-independent half is `noShareExceedsTheSleeve`.
7. Reconstructing `acc` at both window edges from the rings needs the swap history; the rule is
   weakened to the attainment-time bound, which is what `submitScore` reads as `tFirstAttained`.
8. (superseded, see note 10.)
9. `protocolFeeOnlyAtTheEdge` stated the per-pool half of FEE-01 ("only if the pool is an edge
   pool"). REVIEW 5 CHANGED HOW THE PREDICATE IS OBSERVED, and the old way could not be carried: the
   review-4 rule read the flag out of the `parentToken` word the hook hands the vault, because
   `_collect` used to pass `p.isGenesis ? address(0) : parent` and that word therefore WAS the flag.
   It passes `Currency.unwrap(parent)` unconditionally now, so the word carries no pool class at all.
   The predicate had to be read from `p.isEdge` itself, through an `Sload` hook - **and at review 5b
   that hook turned out not to type-check in any spelling (finding S-10), so the rule is DISABLED and
   FEE-01's per-pool half is NOT EXPRESSIBLE at this tier.** It falls back to
   `test/properties/Fees.prop.t.sol` and the review-5 unit tests. The per-route count was already in
   the not-expressible table above, for a different reason.
10. Note 8 above is obsolete: `ghostSlotWrites` is gone. SCR-05 is now stated against the contract's
    own `scoreCheckpoint()` getter either side of a swap, because an `Sstore` hook on the nested ring
    does not type-check (the key resolves to a `PoolId` identity a hook declaration cannot name).
11. **REVIEW 5b, AND IT TURNS OUT TO BE THE SAME CASE AS NOTE 10 AFTER ALL.** The review-5 authoring
    pass argued that hooking `registeredPools[KEY PoolId id].isEdge` and `.tradingStart` was a
    different case from note 10, because note 10 failed on a NESTED mapping while this is a top-level
    `mapping(PoolId => RegisteredPool)`. **That argument is wrong, and finding S-10 has the evidence:
    a plain `mapping(PoolId => uint256)` in the same contract is rejected identically, so it is not
    about nesting and not about struct fields.** Note 10's real content is the part that survives:
    a `PoolId` key is an identity a hook declaration cannot name at `certora-cli` 8.19.2. Every
    spelling was tried, including adding `PoolIdLibrary` to the scene so the declaring contract could
    be named; the table is in `RESULTS-review-5.md`. The contrast that still holds is
    `FeeVault.spec`'s `ledgerTotal[KEY FeeVault.Currency c]`, which works and whose key type is a
    file-level value type over ADDRESS. **Consequence:** `protocolFeeOnlyAtTheEdge` and
    `theEdgeFeeIsSuppressedDuringTheSnipeWindow` are commented out in the spec with a restore note,
    and FEE-01's per-pool half and FEE-06's time half fall back to `Fees.prop` and `Review5.t.sol`.
    **S-8, which claimed `IFamilyHook.PoolId` was the accepted spelling, is withdrawn.**
12. REVIEW 5: the `EDGE` link in `FeeVault.conf` is the first link in these confs onto an immutable of
    a USER-DEFINED VALUE TYPE (`Currency` over `address`) rather than a plain address. The fallback if
    the Prover refuses it is in that conf's own header and in `RESULTS-review-5.md`. **Still UNTESTED
    after review 6: `FeeVault.conf` has never loaded a scene, because of P-1, and all five
    workarounds are now measured and refused (S-14, S-15, S-17, S-18, S-19).**
13. **REVIEW 5b, C-1, the one CONTRACT finding of this pass.** `adoptGenesisIsOnceAndFactoryOnly` is
    VIOLATED: `RoundManager.adoptGenesis` uses `_head != address(0)` as its write-once flag, so
    adopting `address(0)` performs every write, emits the event, and leaves the flag unset, after
    which a second adoption re-seats canonical index 0, the head, the index-0 creator and the edge
    currency. It is LATENT rather than live: the entrypoint is `onlyFactory` and
    `FamilyFactory`'s constructor refuses a zero or codeless genesis token, which is the guard that
    actually makes the sentinel sound. **Reported, then fixed at review 5e**: `RoundManager` carries
    its own write-once `_genesisAdopted` boolean and `adoptGenesis` refuses a zero `token`.

## Spec gaps encoded as assumptions

| PROPERTIES 7 item | where | assumption encoded |
|---|---|---|
| 1 - one fee per edge traversal | FamilyHook.spec, FEE-01 block (the per-pool rule is DISABLED at review 5b, S-10; the ladder is unreachable, S-13) | one fee per traversal, i.e. two for a round trip. REVIEW 5 gives the round trip a concrete reading, recorded in review 5b item 7: `swapPath([0, 1, 0])` ends at index 0 and credits the creator recorded for the adopted genesis token with the creator share of both edge legs |
| 7, `DURATION_SCALE_DIV` vs `closingWindowFor` | RoundManager.spec, `scheduleBounds` | `W` is computed from the **scaled** `D` |
| 8 - "no fee on genesis-less paths" | FamilyHook.spec, FEE-01 block (same review-5b caveat as item 1) | REVIEW 5: the rule is read as "only if the pool is an EDGE pool" (parent is canonical index 0, decided by the factory at registration), not in terms of a currency. There is no native-ETH reading left to choose between |
| 12, `averageOver` with `t1 == t0` | FamilyHook.spec, `averageOverRevertsOnACollapsedWindow` | **GAP CLOSED at review 4b (F6), in the code's favour**: the call REVERTS `BadScoreWindow`, because two edges resolving to one instant measure nothing and a zero there is indistinguishable from a real average of zero. The rule asserts the revert and verifies; the precondition that keeps it unreachable is a deploy-time guard, proved in `RoundManager.spec` |
| 14 - `hopFeePpm` at its ceiling | FamilyHook.spec, `summedRatesStayBelowOne` (the partner rule `theEdgeFeeIsSuppressedDuringTheSnipeWindow` is DISABLED at review 5b, S-10) | **corrected in review-1b, RE-BASED at review-5; at review 5b the two pairwise bounds VERIFY and the third assertion is VIOLATED for finding S-11, an unpinned `hopFeePpm` the Prover may choose to be 0.** The rule states `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1e6`, and PROPERTIES 7.14's "100.075%" is still arithmetically wrong (990000 + 10000 + 10000 = 101%). What changed is WHY the three are never summed. Through review 4 the protocol fee needed `isGenesis` and the snipe tax needed `tradingStart != 0`, so they were mutually exclusive by POOL CLASS. A round-one pool is now both edge and freshly opened, so the exclusion is in TIME: `protocolPpm = (p.isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0` |
| - (§J Fenwick residue) | FeeVault.spec, `edgeLedgerDecomposition` | the floored residue stays in the vault and is not subtracted from `ledgerTotal` |
| - (§J donations) | FeeVault.spec, `solvency` + `onlyAccrualPathsRaiseLedgerTotal` | REVIEW 5: an unsolicited edge-currency transfer into the vault raises `holdings(EDGE)`, credits no ledger and is permitted. Solvency is an inequality in that direction and nothing sweeps the surplus; the §B.1 `total()` gap this row replaces went with `DevVesting` |
