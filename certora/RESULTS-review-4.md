# Certora Prover: review-4 results

> Superseded by review 5 (2026-09-16). Historical record. The current results file is `certora/RESULTS-review-5.md`. The vault verdicts here (22 of 26 rules) are the last full ones: at review 5 the vault specification stopped loading in the Prover (P-1) and is covered by `docs/security/halmos-review-5.md` instead.

Fourth execution of `certora/specs/`, against the contracts at the **`review-4` tag**: the tree
after the automated-review fixes (review 4), the independent review of that diff (review 4b: the
ring freeze, the end seal, the two-phase dead-successor evidence, the flush reordering) and the
independent review of THAT diff (review 4c: `BadDurationScale`, `BadNominalEnd`, "unresolved is not
refused"). This file supersedes review-3's "needs re-run" notes for the three specs that ran.

**Scope.** Only the three specs the review-4 diff touches were run: `FamilyHook`, `FeeVault`,
`RoundManager`. `DevVesting.spec` and `Sleeve.spec` are unchanged by review 4/4b/4c and were not
re-run; their review-3 verdicts stand.

- Prover: `certora-cli 8.19.2`, classic CLI, free prover minutes. solc `0.8.26`.
- Every run: `--msg "<spec> review-4" --disable_local_typechecking` (this machine still has only
  JDK 17), `rule_sanity: basic`, `optimistic_loop: true`. Jobs were submitted without
  `--wait_for_results` and collected by polling `progress` / `jobData`, as `README.md` describes.
- `CERTORAKEY` came from the environment. **No key and no per-job read key appears in any tracked
  file**; job links and their read keys are in `private/certora/JOBS-review-4.md` (gitignored), and a
  `git grep` of this tree for the read-key parameter name is empty. Artefacts (`jobData.json`,
  `output.json`, the whole output tarball, `Results.txt` and every `ctpp_` call trace) are under
  `private/certora/review-4/<label>/`.
- **Run root.** Every job was submitted from a pristine `git archive review-4` export outside the
  repository (plus `lib/`, plus the edited `certora/specs` and `certora/conf`), exactly as review-3
  did. The exported `contracts/` were compared against `git show review-4:` before use and differ
  only in line endings. This mattered more than usual this pass: the working tree was being edited
  concurrently while the jobs ran, and the export is why none of that could reach a run.

## Score

| Spec | rules | review-3 | review-4 first run | review-4 after the re-run |
|---|---|---|---|---|
| FamilyHook | 20 -> **23** | 4 non-SUCCESS / 20 | 4 / 23 (19 verified) | **3 / 23 (20 verified)** |
| FeeVault | 22 -> **26** | 3 rules / 22 (19 fully SUCCESS) | **4 / 26 (22 verified)** |, (budget; one rule fixed in the spec, see below) |
| RoundManager | 26 -> **28** | 4 rules / 26 (22 fully SUCCESS) | **4 / 28 (24 verified)** |, (nothing left to fix) |
| DevVesting | 18 | 1 / 18 | not run (unchanged by review 4) | - |
| Sleeve | 11 | 4 FAIL + 3 TIMEOUT / 11 | not run (unchanged by review 4) | - |

**No GENUINE CONTRACT BUG was found.** Every non-SUCCESS is a spec-scoping defect, a
Prover-tractability limit, or a divergence already documented. Durations: FamilyHook 7 min (1 min on
the re-run), FeeVault 48 min, RoundManager 77 min.

## What the specs had to be taught, and what that proved

The review-4 diff changed four things the specs could see. All four are now stated as rules.

| Change (review 4 / 4b / 4c) | Spec change | Verdict |
|---|---|---|
| `averageOver` returns `(avg, tLastBefore, tStartUsed, tEndUsed)` and REVERTS `BadScoreWindow` on a collapsed window (4b F5/F6) | `averageOverHandlesTheDegenerateWindow` **rewritten** as `averageOverRevertsOnACollapsedWindow`, asserting the revert; `averageOverIsTheAccumulatorDifference` gained the two new instants and asserts `tStartUsed < tEndUsed <= t1` | **both SUCCESS.** `PROPERTIES` §7 gap 12 is CLOSED in the code's favour and is no longer a documented divergence |
| The score rings FREEZE at the pool's published end (4b F1) | new `noRingEntryIsWrittenPastTheBell` - no method writes either ring when `nominalEnd != 0 && block.timestamp > nominalEnd` | **SUCCESS** (all methods) |
| The END SEAL: one final checkpoint, written by the first swap past the bell (4b F1) | new `endSealIsWriteOnce` (once `tSwap != 0`, no field of the seal ever changes again) and `theEndSealIsOnlyLaidPastTheBell` (the seal's interval brackets `T`) | **both SUCCESS**: the second only after three reachability preconditions, below |
| `registerPool` takes `nominalEnd` and reverts `BadNominalEnd` (4c F-C) | methods-block arity updated everywhere; new `registerPoolRefusesACandidateWithoutAPublishedEnd` | **SUCCESS** |
| `RoundManager` constructor reverts `BadDurationScale` unless `W > slot` (4c F-B) | new `theConstructorsWindowGuardMatchesTheGetters` and `theScoredWindowAlwaysExceedsOneCoarseSlot` | **both SUCCESS** |
| `scoreSlotFor(n) = max(SCORE_MIN_SLOT_S, ceil((W + RANDOM_END_S) / 63))` (4b F1) | new `theCoarseRingCoversTheScoredSpan` | **SUCCESS**, including the tightness half |
| `deadEvidenceAt` per attribution, two-phase (4b F2) | new `localBookingRequiresAgedEvidence`, `deadEvidenceMovesOnlyOnTheForwardingPaths` | **both SUCCESS** |
| An unresolved successor is never evidence of a dead one (4c F-A) | new `unresolvedSuccessorIsNeverEvidence` | **SUCCESS** |
| `flushForward` dequeue-debit-call-requeue (4b F7) | `flushForwardConserves` **restated** (see the finding below) | **SUCCESS** |
| A candidate attribution crosses the handover as `UNATTRIBUTED` (review 4, item 4) | new `candidateAttributionsCrossAsUnattributed` | **SUCCESS** |
| `_sendEth` refuses `address(0)` (review 4, item 5) | new `noPayoutPathCanBurnEthAtTheZeroAddress` | **violated on `payKeeper`, spec-scoping, fixed in the spec, NOT re-run** |

### The one rule that had to be corrected rather than added: `flushForwardConserves`

This is worth stating plainly because the OLD rule would now be a **wrong claim**, and it had been
reported "verified" for three passes. Through review-3 it asserted that `flushForward` decrements
`pendingForward` **and** `ledgerTotal[ETH]` by exactly the amount delivered. Review 4b's
dead-successor branch takes the same `amount` out of the queue and books it to THIS version's
ledgers instead (`SuccessorDeclaredDead`); on that path the ETH never leaves, so `ledgerTotal[ETH]`
is deliberately untouched while the return value is non-zero. The rule is restated as the two-sided
claim that is actually CON-05: the ledger falls by exactly what was delivered, or does not fall at
all, and never by more. Which branch ran is then separated by `localBookingRequiresAgedEvidence`.
It is **SUCCESS** in the restated form.

## Per-spec detail

### FamilyHook: 3 non-SUCCESS of 23 after the re-run (was 4 of 20)

| Rule | review-3 | review-4 | classification |
|---|---|---|---|
| `averageOverRevertsOnACollapsedWindow` (was `...HandlesTheDegenerateWindow`) | FAIL, documented divergence | **SUCCESS** | the divergence is closed: the spec now encodes the code's reading, because review 4b settled the gap and said why |
| `averageOverIsTheAccumulatorDifference` | SUCCESS | **SUCCESS**, strengthened | now also asserts `tStartUsed < tEndUsed` and `tEndUsed <= t1` |
| new: `registerPoolRefusesACandidateWithoutAPublishedEnd` | - | **SUCCESS** | 4c F-C's guard, stated directly and independent of any pre-state |
| new: `noRingEntryIsWrittenPastTheBell` | - | **SUCCESS** | 4b F1's freeze. Stated over an ARBITRARY `id` (CVL cannot compute `key.toId()`), which costs nothing: for any other pool the rings do not move and the implication is vacuous |
| new: `endSealIsWriteOnce` | - | **SUCCESS** | the seal is immutable once laid, which is the whole point of it |
| new: `theEndSealIsOnlyLaidPastTheBell` | - | FAIL -> **SUCCESS after the re-run** | **spec-scoping, and the counterexample is the interesting part**: the pre-state is `isGenesis == true` WITH `nominalEnd == 1`, which `registerPool` cannot produce (`p.nominalEnd = isGenesis ? 0 : nominalEnd`), and `tLast == 2` against `tradingStart == 815`, which it cannot produce either (`p.tLast = tradingStart`). Three preconditions discharge it: `registerPool`'s two guards, plus the induction hypothesis of this very invariant (an UNLAID seal means nothing has been swapped past the bell, so `tLast <= nominalEnd`) |
| `anyFeeAccrualIsReachable`, `someProtocolFeeIsReachable`, `oneProtocolFeeAtTheEthEdgeIsReachable` | FAIL | **FAIL** (SANITY_FAIL) | FEE-01, and the review-4 experiment is ANSWERED IN THE NEGATIVE, see below |
| the other 17 | | SUCCESS | including `aSlotIsWrittenOnceByItsFirstSwap`, `genesisIsNeverSniped`, `beforeSwapIsReachable` and `theFeeMintIsReachable` (rungs 0 and 0.5 still discharge) |

**FEE-01: the review-4 checklist item is closed, and the answer is "not that".** Review-3's
diagnosis was that the `_.accrue(...)` wildcard never fires on `_collect`'s vault call, and its
proposed experiment was to replace it with an EXACT `FeeVault.accrue(...)` entry, since `feeVault`
is linked in `FamilyHook.conf`. That entry is now in the spec (two CVL syntax corrections were
needed to get it accepted: an exact target must use the CONTRACT's own parameter names, and it may
not carry an `expect` clause). With it in place **the accrual counter still has no writer**: rungs 0
and 0.5 discharge, rungs 1, 2 and 3 do not. So the loss is NOT summary matching on the signature, an exact entry on the linked callee is as specific as CVL gets, and it still does not intercept that
call. What is left to test is whether the call site resolves to `FeeVault` at all under
`disable_internal_function_instrumentation` / `optimistic_fallback`, or whether the fee claim
`mint` one line earlier leaves the execution in a state the vault call cannot be entered from.
`protocolFeeOnlyOnTheGenesisPool` therefore still reports SUCCESS over a counter that cannot move,
and FEE-01's per-pool half is still UNPROVED here.

### FeeVault: 4 rules with failing methods of 26 (22 fully verified)

| Rule | review-3 | review-4 | classification |
|---|---|---|---|
| `solvency` | FAIL on 3 | **FAIL on 3** (`accrue`, `accrueForwarded`, `receiveForward`) | unchanged, and unchanged diagnosis: the claim's backing is minted to the vault by the HOOK before `accrue` is called, i.e. outside this proof and behind a summary. Review-4 checklist item 4 was not attempted this pass |
| `ethLedgerDecomposition` | FAIL (2) | **FAIL (2)** (`accrue`, `forwardProtocolFee`) | unchanged; review-4 checklist item 5 was not attempted this pass |
| `bucketNeverExceedsCap` | FAIL (3) + TIMEOUT (1) | **FAIL (5), TIMEOUT (0)** | the same Prover imprecision in the Fenwick `_prefix` walk at `loop_iter: 3`; the review-3 timeout has resolved into a counterexample of the same family rather than into a new one. BID-07 holds at U and F |
| new: `noPayoutPathCanBurnEthAtTheZeroAddress` | - | **FAIL on `payKeeper`** | **spec-scoping, mine**: the counterexample is `payKeeper(address(0), 0)`, which returns on `if (ethAmount == 0) return;` WITHOUT reverting, and without sending anything, so nothing is burned. `require ethAmount > 0` is in the spec now; there was no budget left to re-run it. The three CLAIM paths (`claimDev`, `claimCreator`, `claimCreatorAccrued`) all verify with no such bound |
| new: `localBookingRequiresAgedEvidence` | - | **SUCCESS** | 4b F2: a queued fee can only be booked locally against an evidence timestamp that already exists and is already `DEAD_SUCCESSOR_DELAY` old |
| new: `unresolvedSuccessorIsNeverEvidence` | - | **SUCCESS** | 4c F-A, stated through the resolution cache: `_resolveSuccessorVault` caches a success and never caches a failure, so "the vault resolved" is observable afterwards as `successorVault() != 0`, and no write to `deadEvidenceAt` is possible without it |
| new: `deadEvidenceMovesOnlyOnTheForwardingPaths` | - | **SUCCESS** | no unrelated entrypoint can age a successor into death or reset a standing clock |
| new: `candidateAttributionsCrossAsUnattributed` | - | **SUCCESS** | review-4 item 4: no attribution other than `UNATTRIBUTED` gains a queued balance from an accrual carrying `CANDIDATE_ATTRIBUTION` |
| `flushForwardConserves` | SUCCESS (of a claim that is now false) | **SUCCESS** restated | see the finding above |
| the other 17 | | SUCCESS | |

### RoundManager: 4 rules with failing sub-goals of 28 (24 fully verified)

All three NEW rules verify, and the four residuals are exactly review-3's, unchanged:

| Rule | review-3 | review-4 | classification |
|---|---|---|---|
| new: `theCoarseRingCoversTheScoredSpan` | - | **SUCCESS** | `63 * scoreSlotFor(n) >= W(n) + RANDOM_END_S`, plus the floor, plus tightness (one slot narrower and the ring no longer covers the span) |
| new: `theConstructorsWindowGuardMatchesTheGetters` | - | **SUCCESS** | the anti-drift check on 4c F-B's seam: the constructor writes `W` and the coarse slot OUT BY HAND (an immutable is not readable through a function during construction), and this proves the hand-written expressions equal `closingWindowFor(n)` and `scoreSlotFor(n)` for every `n` |
| new: `theScoredWindowAlwaysExceedsOneCoarseSlot` | - | **SUCCESS** | with the constructor guard restated as the precondition it is, `closingWindowFor(n) > scoreSlotFor(n)` for every `n`, which is what makes `FamilyHook.averageOver`'s `BadScoreWindow` unreachable on any deployment that got past the constructor |
| `canonicalIsWriteOnce` | FAIL 2/17 | **FAIL 2/17** (`finalize`, `registerGenesis`) | unchanged: the second conjunct compares a local write against the DELEGATED `headIndex()`. Review-4 checklist item 3 (state the history rules against LOCAL storage) was not attempted this pass |
| `historyEntriesAreImmutable` | FAIL 3/14 | **FAIL 3** (`finalize`, `registerGenesis`, `addCandidate`) | same residual |
| `reverseIndexIsConsistent` | FAIL 3/17 | **FAIL 3** (`addCandidate`, `finalize`, `registerGenesis`) | same residual |
| `noTransitionIsPrivileged` | FAIL 3 + TIMEOUT 1 | **FAIL 3 + TIMEOUT 1** (`submitScore`) | unchanged |
| the other 21 | | SUCCESS | |

`NoScoreSubmitted(roundId, candidateCount)` (the event `finalize` emits when a round closes with no
score submitted at all) is **NOT EXPRESSIBLE** here and is recorded as such rather than skipped:
CVL has no event predicate, so an emission is not a usable witness. It is held by
`Review4.t.sol::test_aRoundWithNoSubmittedScoreSaysSo` at the unit tier.

## Findings

**No GENUINE CONTRACT BUG.** Two **specification** findings, both about the specs rather than the
contracts, and the first is the one to remember:

- **S-4. A rule that was verified for three passes became a WRONG CLAIM when the code under it
  changed, and nothing would have caught that except re-deriving it.** `flushForwardConserves`
  asserted "`ledgerTotal` falls by exactly what was delivered". Review 4b added a branch where the
  queue falls and the ledger deliberately does not. Had the rule been carried forward unexamined it
  would have failed and been read as a regression in the CONTRACT; had the contract instead grown a
  path that really did lose wei, the rule as written could equally have been "fixed" by loosening it.
  The lesson is the review-2 lesson in a new place: **a green rule is only evidence about the code it
  was written against.** Every rule touching a changed function has to be re-derived from the
  specification, not re-run.
- **S-5. `noPayoutPathCanBurnEthAtTheZeroAddress` needed `ethAmount > 0`.** `payKeeper(address(0), 0)`
  returns before `_sendEth` on its own zero-amount guard, so it neither reverts nor burns anything.
  The rule was asserting something the contract does not claim. Fixed in the spec, not re-run.

Carried forward and still true: **S-1** (a `loop_iter` below a structure's real depth makes rules
VACUOUS under `optimistic_loop`), **S-2** (`DevVesting.releasedNeverExceedsTotal` is a tautology),
**S-3** (`isHeadWriter` had enumerated two of three head writers; fixed at review-3).

## Budget

**3 initial runs** (FamilyHook, FeeVault, RoundManager) and **3 re-runs**, which is the cap.
Two of the three re-runs were spent on CVL type errors in ONE new line (the exact
`FeeVault.accrue(...)` summary entry) which reached the server because this machine has only JDK 17
and cannot type-check locally:

1. *"Cannot merge ... Conflicting parameter names"*, an exact summary target must use the
   CONTRACT's own parameter names (`currency`, not `c`).
2. *"An exact summary target may not contain expected return type in the summary body"*, an exact
   target takes no `expect` clause, unlike the `_.` wildcard, where it is mandatory.

Both failed in about 7 seconds with a full `alertReport.json`, so they were cheap in minutes and
expensive in budget. The third re-run was the real FamilyHook re-run (end-seal preconditions), which
discharged `theEndSealIsOnlyLaidPastTheBell`. One further submission was attempted and never reached
the server: the local `solc0.8.26` compile of `RoundManager.sol` failed under memory pressure on this
16 GB box, so it consumed no prover minutes and is not counted as a run.

**Get a JDK 21 on this machine before review-5.** Two of six runs this pass were spent on errors a
local type-check would have caught in seconds, and that is now the single largest tax on the budget.

## What review-5 should do, in value order

1. **FEE-01 is no longer "one experiment away", it needs a different experiment.** The exact
   `FeeVault.accrue` entry is in place and the counter still does not move, which rules out summary
   matching. Next: count accruals from the LINKED vault's own `ledgerTotal` store (an `Sstore` hook
   in `FamilyHook.spec` on `FeeVault.ledgerTotal`) rather than from any summary at all, and check
   whether `optimistic_fallback` is swallowing the vault call.
2. **Re-run FeeVault** for the one-line `require ethAmount > 0` in
   `noPayoutPathCanBurnEthAtTheZeroAddress`, which is the only rule this pass left fixed-but-unrun.
3. **State the history rules against LOCAL storage, not the delegating getters**: unchanged from
   review-4's list, and still the one item covering all four of RoundManager's residuals
   (`canonicalIsWriteOnce`, `historyEntriesAreImmutable`, `reverseIndexIsConsistent`, and
   `noTransitionIsPrivileged`'s `finalize` leg).
4. **`solvency` / `ethLedgerDecomposition` on the accrual path**: carried over untouched from
   review-4's checklist items 4 and 5.
5. **Sleeve bounds one power of two tighter** (tree words `< 2^190`, coefficients `< 2^128`) and a
   `DevVesting` / `Sleeve` re-run; neither spec ran this pass.
6. **A `BidDeployer.spec`** whose `_.depositBid(...)` summary records `(key, childToken)`, which is
   what makes PUR-02's landing step expressible at this tier.
7. **JDK 21**, per the budget note above.
