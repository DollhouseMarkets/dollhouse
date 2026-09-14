# Certora Prover — review-2 results

Second full execution of `certora/specs/`, against the contracts at tag `review-2`. Review-1/1b are
in `RESULTS-review-1.md`; this file supersedes their "needs re-run" notes.

- Prover: `certora-cli 8.19.2`, classic CLI, free prover minutes. solc `0.8.26`.
- Every run: `--msg "<spec> review-2" --wait_for_results all --disable_local_typechecking`,
  `rule_sanity: basic`, `optimistic_loop: true`.
- `CERTORAKEY` came from the environment. **No key and no per-job read key appears in any tracked
  file**; job links and their read keys are in `private/certora/JOBS-review-2.md` (gitignored), and
  a `git grep` of this tree for the per-job read-key parameter name (`anonymous...Key`) is empty. Artefacts (`output.json`,
  `FinalResults.html`, `jobData.json` and the whole output tarball, call traces included) are under
  `private/certora/review-2/<Spec>/`.

## Where the runs were executed, and why it matters

The first three jobs (DevVesting, Sleeve, FeeVault) were submitted from the repository working tree
while it was clean at tag `review-2`. Part-way through the FeeVault job **another process began
editing `contracts/` in the same working tree** (`RoundManager.sol`, `FamilyHook.sol`,
`BidDeployer.sol`, `IFamilyHook.sol` and much of `test/`), and HEAD moved past the tag. Because the
Prover compiles whatever is on disk at submission time, every job after that point was submitted
from a **pristine export of tag `review-2`** (`git archive review-2` plus `lib/`, outside the
repository), with only `certora/specs` and `certora/conf` taken from the working tree. The exported
`contracts/` were byte-compared against `git show review-2:` before use. Nothing in this file
describes the concurrent edits.


## Jobs

Read keys are **not** here; they are in `private/certora/JOBS-review-2.md` (gitignored), next to the
same links. Artefacts per job are in `private/certora/review-2/<dir>/` (`output.json`,
`FinalResults.html`, `jobData.json`, and the whole output tree as `output.tar.gz` / `tree/`).

| Run | Job | Artefacts |
|---|---|---|
| DevVesting | [49365a4b...](https://prover.certora.com/output/4818370/49365a4be10f41eba642a24fc1b8c78c) | `DevVesting/` |
| DevVesting re-run | [93ca2bac...](https://prover.certora.com/output/4818370/93ca2bac1a2446bebb151d6840f7d5a3) | `DevVesting-re-run/` |
| Sleeve | [1ddf3ca1...](https://prover.certora.com/output/4818370/1ddf3ca1d411446e8ab64e684cde513c) | `Sleeve/` |
| Sleeve re-run (`loop_iter: 14`) | [430a4cf2...](https://prover.certora.com/output/4818370/430a4cf29f7f4dc5961b0fc0e55d8124) | `Sleeve-re-run/` |
| FeeVault | [4d3c7134...](https://prover.certora.com/output/4818370/4d3c71345ab044d994549ce1754e1ebc) | `FeeVault/` |
| FeeVault re-run | [e7a60b6c...](https://prover.certora.com/output/4818370/e7a60b6cc9a6461f827094d424c917d7) | `FeeVault-re-run/` |
| RoundManager | [088243b8...](https://prover.certora.com/output/4818370/088243b8978243d1812f5e093fbcca46) | `RoundManager/` |
| FamilyHook | [cdd4f854...](https://prover.certora.com/output/4818370/cdd4f85480ac485b88bf67ca05d05c73) | `FamilyHook/` |

## Score

| Spec | non-SUCCESS at review-1b | review-2 first run | review-2 after fixes |
|---|---|---|---|
| DevVesting | 5 (review-1) | 2 / 16 | **2 / 17** (different two; see below) |
| Sleeve | 4 violated + 2 vacuous + 1 timeout (review-1) | 3 / 11 (all vacuity) | 3 FAIL + 5 TIMEOUT / 11 — **the honest number, see SLV-03** |
| FeeVault | 7 / 29 | 4 / 29 | **3 rules of 20** (16-18 of 20-22 methods pass in each) |
| RoundManager | 10 / 30 | **6 rules of 26** (20 fully SUCCESS) | not re-run (budget) |
| FamilyHook | 4 / 15 | **5 / 18** (three of them are one diagnosis) | not re-run (budget) |

**No GENUINE CONTRACT BUG was found.** Every non-SUCCESS is a spec-scoping or spec-writing defect, a
Prover-tractability limit, or a divergence already documented in `docs/security/PROPERTY_RESULTS.md`.

## The five review-2 contract fixes, checked formally

| Fix | Rule that is the evidence | Verdict |
|---|---|---|
| **F-1** `registerPool` reverts `GenesisHasNoSnipeWindow` | `genesisIsNeverSniped` (restated as the inductive step it always was) and the new `registerPoolRefusesAGenesisSnipeWindow` | **both SUCCESS.** F-1 closed: review-1b left this rule deliberately failing, and it now proves with the guard in place. |
| **F-2** `Drawdown.initialised` replaces the `updatedAt == 0` sentinel | the new `twoDrawsCannotDoubleUpAtAnyClock` — the review-1b rule with **no** `wellFormedTime(e)` precondition at all | **SUCCESS.** The sentinel collision is gone: two same-instant draws cannot exceed one bucket for *any* clock the Prover can pick, including 0 and 2^64. |
| **F-3** `Round.endRequested` replaces the `randomId != 0` guard | `requestEndIsOnceAndNotBeforeT`, with the `pin()` summary relaxed to a **fully arbitrary** `bytes32` (review-1b had to require it non-zero) | see the RoundManager table |
| **F-4** `accrue` is `nonReentrant` and credits the ledger before the hop | the successor summary narrowed `HAVOC_ALL` → `HAVOC_ECF`, which review-1 gated on exactly this fix | **worked.** `deployerCreditSettles`, `pendingForwardTotalIsTheSum` and `valueLeavesOnlyOnPayoutMethods` went from 3+3+4 failing methods to **fully SUCCESS**. |
| **fix 6** `addSleeve` bounds-checks `M` before the zero short-circuit | `indexPastMaxReverts`, with the `sleeve > 0` precondition **removed** | **SUCCESS.** SLV-07 now proves as written. |

## DevVesting

First run: 2 / 16 non-SUCCESS. Re-run after the fixes: 2 / 17.

| Rule | first run | re-run | classification and evidence |
|---|---|---|---|
| `releasedEqualsTotalAfterDuration` | FAIL | **SUCCESS** | **Spec-writing error, two causes, both in the counterexample.** (a) `release()` ends in OZ `SafeERC20.safeTransfer`, which is a low-level `call` with hand-encoded calldata: the trace's own call-resolution table says `DevVesting.release() -> FamilyToken.[?] : AUTO havoc`, *"havocs all contracts except DevVesting"*, so `FamilyToken._balances[DevVesting]` — and therefore `total()` **re-read** after the transfer — was unrelated to the allocation (trace: `released = 1`, `total() = 2^256 - 3652`). `total()` is now read BEFORE the call, which is the same claim pinned at the store rather than the re-read. (b) `e.block.timestamp = 2^256 - 1923` satisfied `timestamp >= start + duration` as a mathint while `releasable()`'s `uint64(block.timestamp)` truncated mid-schedule; a `wellFormedNow(e)` definition bounds the clock to uint64. |
| `releasedNeverExceedsTotal` (invariant) | SANITY_FAIL | SANITY_FAIL | **Spec-writing weakness, kept and marked.** The invariant is a TAUTOLOGY: `total()` is *defined* as `token.balanceOf(this) + released`, so `released <= total()` is `released <= balance + released` and holds of any two unsigned numbers whatever the contract does. 0 s on every sub-goal. It is **not** counted as evidence for VST-03; `releasedIsMonotone`, `everythingVestsAtTheEnd` and `vestedNeverExceedsTotal` carry that. |
| `releasedNeverExceedsVested` (new) | — | FAIL | **Spec-scoping, same AUTO-havoc as above**, diagnosed and NOT re-run (budget). `vested(t)` is computed from `total()`, which the havoc'd `safeTransfer` moves, so the post-state schedule value is unrelated to the pre-state one. The fix is the same one that worked above: bind the allocation before the call and state the schedule against it. |
| everything else (14 rules) | SUCCESS | SUCCESS | includes `everythingVestsAtTheEnd`, `nothingReducesClaimableExceptRelease` and `releasePaysTheDeltaToTheCurrentBeneficiary`, the three review-1 violations the post-review-1 fixes were meant to close. All three are closed. |

## Sleeve — the SLV-03 vacuity is solved, and it was not the `^`

This is the most consequential finding of review-2 about the specs themselves.

**Root cause.** `FenwickRangeAdd._add` walks `i = 1, 2, 4, … 4096` while `i <= MAX_INDEX + 2 == 4097`:
**thirteen** iterations from index 0, which is the left edge every sleeve range-adds at. `Sleeve.conf`
carried `loop_iter: 12`. With `optimistic_loop: true` the Prover *assumes* the loop has exited after
the unrolled iterations, and at 12 that assumption is **unsatisfiable** on exactly those paths — so
every rule that forced a NON-ZERO sleeve through `addSleeve` had an unsatisfiable precondition and
came back "not violated" **vacuously**. The rules that allow `sleeve == 0` (which short-circuits
before the loop) passed sanity. That is precisely the observed partition, in review-1 and again in
review-2's first run:

| first run (`loop_iter: 12`) | verdict |
|---|---|
| `noShareExceedsTheSleeve`, `sumOfSharesNeverExceedsTheSleeveSmallM`, `genesisWeightIsTwiceTheTerminalWeight` (all force `sleeve > 0`) | **SANITY_FAIL** |
| every other rule | SUCCESS |

Review-1's suspicion that `2^128` (which is `2 XOR 128 = 130` in CVL, not exponentiation) caused the
vacuity was a real defect but **not** this one; it was corrected and the vacuity survived it.

Two further spec-writing defects were corrected in this pass, both restoring the claim the
specification makes: the two SLV-03 rules were stated as **deltas** (the Prover starts from an
arbitrary tree) and at the **right scale** — the trees hold WAD-scaled coefficients, so
`query(j) <= sleeve` was comparing a 1e18-scaled share against a raw wei sleeve. The sum is now taken
at wei granularity, which is the row `docs/security/PROPERTY_RESULTS.md` records as passing
(`testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`); the WAD-scale over-allocation of a few hundred
WAD units stays the documented divergence it already was.

**Re-run at `loop_iter: 14`** (job in `private/certora/JOBS-review-2.md`):

| Rule | verdict | classification |
|---|---|---|
| `indexPastMaxReverts` | **SUCCESS** | review-2 fix 6 verified, with `sleeve > 0` removed |
| `reversedRangeReverts`, `envfreeFuncsStaticCheck` | SUCCESS | |
| `genesisTakesTheWholeSleeveAtMZero` | **FAIL** | **Spec-writing: unbounded int256 pre-state.** Counterexample: `before = 0x7fff…0133` (one below `INT256_MAX`) and a 200-bit `sleeve`, so the `unchecked` `t[i] += v` in `_add` wraps. Not a contract defect — `_add` is `unchecked` by design and a real sleeve is `sleeve * WAD` with `sleeve` bounded by the vault's ETH. The rule places no bound on the tree it starts from. |
| `rangeAddThenPointQueryIsTheClosedForm` | **FAIL** | Same. `before = -0x7fff…1c3` (one above `INT256_MIN`), `c0 = -0x5555…599`. |
| `pointQueryIsAdditive` | **FAIL** | Same. `first = -0x7fff…d8b0`, `a1 = 0x3fff…96ad`. |
| `everyAncestorShareIsNonNegative`, `noIndexOutsideTheRangeIsCredited`, `genesisWeightIsTwiceTheTerminalWeight`, `noShareExceedsTheSleeve`, `sumOfSharesNeverExceedsTheSleeveSmallM` | **TIMEOUT** (1518–4167 s at `smt_timeout: 900`) | Tractability. A correctly unrolled 13-deep Fenwick walk over three trees with symbolic indices is expensive; `loop_iter: 12` was buying its speed with an unsound assumption. |

**So SLV-03 is still UNPROVED in Certora — but for a different and now precisely known reason.** It
is no longer "vacuous and nobody knows why"; it is "the loop bound that makes it non-vacuous makes it
time out". The next step is stated in the checklist below and costs no new insight, only bounds:
constrain the tree pre-state and the coefficients to a range the vault can actually reach
(|value| < 2^200, |c| < 2^160), which removes both the overflow counterexamples and most of the
solver's search space. The wei-granularity claim keeps passing at the fuzz tier meanwhile.

## FamilyHook

First run: 5 / 18 non-SUCCESS (was 4 / 15; the three new rows are the FEE-01 reachability ladder
added this pass, and they are one diagnosis, not three).

| Rule | review-1b | review-2 | classification and evidence |
|---|---|---|---|
| `genesisIsNeverSniped` | FAIL (kept) | **SUCCESS** | **F-1 closed.** Restated as the inductive step (the review-1b form asserted over arbitrary registry storage, which no guard in `registerPool` could ever discharge; the base case is free because a fresh pool is `registered == false`). |
| `registerPoolRefusesAGenesisSnipeWindow` (new) | — | **SUCCESS** | The F-1 guard stated directly, independent of any starting storage. |
| `protocolFeeOnlyOnTheGenesisPool` | SUCCESS (vacuous) | SUCCESS (**still vacuous**) | see the next three rows |
| `anyFeeAccrualIsReachable` (new, `satisfy`) | — | **FAIL** | **This is the review-2 answer to review-1's open item 2, and it is more specific than expected.** Review-1b knew only that "exactly one protocol fee" could not be constructed. Rung 1 of the new ladder asks whether **any** fee accrual at all is reachable through `beforeSwap` — and it is not. So the FEE-01 vacuity is *not* about the fee count or about `feeVault` being unlinked (it is linked); **no execution of `beforeSwap` reaches `_collect`'s vault call under the present summaries at all**, and `protocolFeeOnlyOnTheGenesisPool`'s "not violated" is pure vacuous coverage. |
| `someProtocolFeeIsReachable` (new, `satisfy`) | — | FAIL | Rung 2 (`> before` instead of `== before + 1`), as review-1b's own next-steps list asked for. Fails for the same reason as rung 1. |
| `oneProtocolFeeAtTheEthEdgeIsReachable` (`satisfy`) | FAIL | FAIL | Rung 3. Unchanged. |
| `aSlotIsWrittenOnceByItsFirstSwap` | FAIL | FAIL | **Spec-scoping, now diagnosed exactly.** Counterexample: `e.block.timestamp = 10`, `cpBefore.tSwap = 191`, `cpAfter.tSwap = 10`, `index = 2`. Both 191 and 10 satisfy the ring well-formedness precondition added after review-1b (`191/5 % 36 == 2` and `10/5 % 36 == 2`) — they are spans 38 and 2, which the 36-slot ring legitimately aliases. So the "overwrite" is a checkpoint written at t = 10 replacing one stamped t = 191, i.e. **a checkpoint from the future**, which no chain can produce. `cpBefore.acc` and `cpAfter.acc` sit at the int256 extremes as well. The missing precondition is one line (`cpBefore.tSwap <= e.block.timestamp`); it is **not** re-run (budget). SCR-05 passes at the fuzz tier (`Score.prop::testFuzz_SCR05_aSlotIsWrittenOnceByItsFirstSwap`). |
| `averageOverHandlesTheDegenerateWindow` | FAIL (kept) | FAIL (kept) | **Documented divergence, deliberately not fixed.** `PROPERTIES` §7.12 / `PROPERTY_RESULTS.md` §2 gap 12: the code reverts `BadScoreWindow` at `t1 == t0`; the spec's most plausible reading is "return the instantaneous level". The rule keeps the spec's reading. |
| the other 10 rows | | SUCCESS | including `summedRatesStayBelowOne`, `feeRatesAreImmutable`, `onlyTheSwapPathMovesTheScore`, `theFastRingSpansTheRandomEndWindow`, `snipeTaxBounds`, `liquidityIsARatchet`, `donationsAreImpossible`, `averageOverIsTheAccumulatorDifference`, `scoreIsMonotoneInNetParentAbsorbed`. |

## FeeVault

First run: 4 / 29 sub-goal rows non-SUCCESS (was 7 at review-1b). Re-run after this pass's fixes:
3 rules with failing methods out of 20; **17 of the 20 rules are fully SUCCESS**.

| Rule | review-1b | review-2 first | review-2 re-run | classification and evidence |
|---|---|---|---|---|
| `deployerCreditSettles` | FAIL (3 methods) | **SUCCESS** | SUCCESS | **`HAVOC_ALL` → `HAVOC_ECF`, unblocked by F-4.** |
| `pendingForwardTotalIsTheSum` | FAIL (3) | **SUCCESS** | SUCCESS | same |
| `valueLeavesOnlyOnPayoutMethods` | FAIL (4) | **SUCCESS (20/20)** | SUCCESS | same, plus the review-1c `isPayoutMethod` list |
| `twoDrawsCannotDoubleUpAtAnyClock` (new) | — | **SUCCESS** | SUCCESS | **F-2 verified, with no clock precondition at all.** |
| `solvency` | FAIL (transient + 20) | FAIL (transient + 20) | **SUCCESS on the base, on the transient step and on 16 / 20 methods**; FAIL on `accrue`, `accrueForwarded`, `receiveForward`, `payKeeper` | **Two spec-scoping defects: one fixed, one diagnosed.** *Fixed:* `holdings()` sums a real balance and an ERC-6909 claim. Review-1c pinned the claim term (`balanceOf(address,uint256)`) but not the ERC-20 term, and every review-2 counterexample named it — `FeeVault.holdings(Currency) -> [?].[sighash=0x70a08231] : AUTO havoc`, "a havoc that only havocs the return value". Pinning it to a consistent ghost is what moved 17 sub-goals. *Remaining:* the invariant is **true but not inductive**. `payKeeper`'s trace is the clearest: the pre-state has `ledgerTotal[ETH] == holdings(ETH)` exactly **and** a non-zero `deployerCredit`; `payKeeper` sends 1 wei out of that credit — which `consumeAncestorClaim` had already debited from `ledgerTotal` — so holdings falls by 1 and `ledgerTotal` does not. No reachable state has both, because the credit is always carved out of the ledger first. The inductive form is `ledgerTotal[c] + (c == ETH ? deployerCredit : 0) <= holdings(c)`. On `accrue` / `accrueForwarded` / `receiveForward` the backing for the new credit arrives as a `poolManager.mint` issued by the hook *before* `accrue` is called, i.e. outside this proof and behind a summary, so the Prover may raise `ledgerTotal` against a flat claim balance. |
| `ethLedgerDecomposition` | FAIL (2) | FAIL (2: `accrue`, `forwardProtocolFee`) | FAIL (10) — **a regression this pass introduced** | The first run's counterexamples opened with negative mirrors (`ghostPendingSum = -7`, `ghostAncestorClaimed = -8120`, `ghostDev = -1`, `ghostReinforceEth = -3`), none of which any call sequence can produce, so non-negativity conjuncts were added to make the invariant inductive. That was the wrong shape: the mirrors accumulate **deltas**, so every method that legitimately decreases one must now re-establish `>= 0` out of nothing, and eight more methods fail. The right fix is to tie each mirror to its storage word (a load hook, or `requireInvariant`) rather than to assert non-negativity from thin air. Recorded as a defect of this pass's spec change, not of the contract. |
| `bucketNeverExceedsCap` | FAIL (6) | FAIL (3) + TIMEOUT (1) | FAIL (4: `accrue`, `accrueForwarded`, `consumeAncestorClaim`, `receiveForward`) | **Prover imprecision inside the Fenwick walk.** The traces show, inside `claimableAncestor` → `_prefix`: `Imprecision detected: mismatch: BWAnd(1675, ...) = 1, but is 1675` — the Prover's bitwise-and abstraction, on top of `loop_iter: 3`, far below the 13 the tree needs. Raising `loop_iter` here is not viable: the Sleeve re-run shows what a correctly unrolled Fenwick walk costs, and this job already runs about 40 minutes. BID-07's bucket claim holds at the unit and fuzz tiers. |
| the other 13 rules | | SUCCESS | SUCCESS | `accrueConservesTheFee`, `accrueMovesLedgerTotalByTheFee`, `onlyAccrualPathsCredit`, `creatorTransferIsALedgerMove`, `drawNeverExceedsTheBucket`, `twoDrawsCannotDoubleUp`, `payKeeperIsBoundedByDeployerCredit`, `onlyBidDeployerHooks`, `flushForwardConserves`, `postSunsetFeesAreNeverBookedLocally`, `ratesAndSplitsAreImmutable`, `claimZeroesBeforePaying`, `envfreeFuncsStaticCheck`. |

One more summary gap was closed on the way: `forwardProtocolFee` hands the claim over with
`poolManager.transfer` (the ERC-6909 three-argument overload), which was **not** in the spec's list of
summarized PoolManager entrypoints, so it fell through to AUTO and "havocs all contracts except
FeeVault" on the accrual path. The spec's own stated policy is that every PoolManager entrypoint is
summarized; the list is now complete.

## RoundManager

26 rules; **20 fully SUCCESS**, 6 with failing sub-goals. Review-1b was 10 / 30 non-SUCCESS.

Closed this pass:

| Rule | review-1b | review-2 | why |
|---|---|---|---|
| `bondIsMonotoneInDepth` (RND-12) | TIMEOUT, twice | **SUCCESS** | Pinning `BOND_DOUBLING_EVERY` to its deploy constant (4) turns `i / every` into a concrete function of `i`, exactly as review-1b's diagnosis predicted; `smt_timeout` was raised to 1200 s as well. **Scoping restriction, recorded:** RND-12 is proved at the deployed schedule, not for every conceivable `doublingEvery`. |
| `requestEndIsOnceAndNotBeforeT` | SUCCESS, but only with a **non-zero** `pin()` summary | **SUCCESS with a fully arbitrary `bytes32`** | **F-3 verified.** The once-per-round guard is `Round.endRequested`, so a source returning a zero id can no longer disarm it. |
| `maxIndexIsRespected` (RND-15) | FAIL | **SUCCESS** | the review-1c `isIdle()` restatement plus the prior-registry pins |
| `finalizeIsIdempotent` (RND-07) | FAIL | **SUCCESS** | the consistent-read summaries for `headToken` / `headIndex` |
| `canonicalIsWriteOnce` | FAIL (1) | SUCCESS on 15 / 17 | the inductive strengthening landed; two `finalize` legs remain |
| 16 others | | SUCCESS | `historyLengthIsMonotone`, `onlyFinalizeOrAdoptionWritesHistory`, `thresholdMovesOnlyInFinalize`, `adoptionHappensAtMostOnce`, `scheduleBounds`, `trueEndFallsInsideTheWindow`, `endIsSettledAtMostOnce`, `timeoutFallbackSettlesAtT`, `scheduleIsPureInN`, `lateEntryClosesBeforeTheClosingWindow`, `bondSaturates`, `winnersBondIsReturned`, `losersBondsAreForfeited`, `noNewRoundBeforeFinalize`, `sunsetTouchesNothingElse`, `envfreeFuncsStaticCheck` |

Still failing — **one diagnosis covers five of the six**:

| Rule | non-SUCCESS | classification and evidence |
|---|---|---|
| `historyEntriesAreImmutable` | FAIL (15 / 15) | **Spec-scoping (mechanism 4), the last un-pinned delegated read.** The trace names it: `RoundManager.parentOf(address) -> [?].ownsToken(address) : AUTO havoc`, and the same inside `creatorOf`. `parentOf` / `creatorOf` / `isCanonical` route through `registryOfToken(token)`, which asks the prior registry `ownsToken(token)` — and **`_.ownsToken` has no summary**, so two reads of the same getter in the same state disagree. Review-1c pinned twelve delegated reads and missed this one. The fix is one line per missing getter, in the same consistent-ghost style. **Not re-run: the run budget was spent.** |
| `reverseIndexIsConsistent` | FAIL (16 / 17) | same cause (`indexOf` / `isCanonical` route through `ownsToken`) |
| `headIndexOnlyGrows` | FAIL (1 / 15) | same residual, now on one method only (was all 15 at review-1) |
| `pairingRightsAreWriteOnce` | FAIL (1 / 15) | same residual, one method (was 12) |
| `canonicalIsWriteOnce` | FAIL (2 / 17) | same residual, two `finalize` legs |
| `noTransitionIsPrivileged` | FAIL (3) + TIMEOUT (2) | The same-storage restatement landed; the two timeouts are `rank` / `submitScore`, unchanged from review-1b. The three failures share the residual above. ROL-01's substance is carried by `sunsetTouchesNothingElse` and (in `FeeVault.spec`) `onlyBidDeployerHooks`. |

The REN-01 guard (`notInsideUnlock`) is now on every state-changing entrypoint, and it reads
v4-core's transient lock slot with an `exttload` on the **unlinked** PoolManager. Without a summary
that read is a fresh per-call havoc, which would have re-introduced mechanism 4 across
`noTransitionIsPrivileged`, `finalizeIsIdempotent` and `endIsSettledAtMostOnce`; `_.exttload(bytes32)`
is therefore pinned to an unconstrained but consistent ghost in both `RoundManager.spec` and
`FeeVault.spec`. That does **not** make REN-01 expressible — it only stops the guard from
contradicting itself inside one transaction. No existing rule was broken by the guard's arrival.

## The six review-1 open items

| # | Item | Status at review-2 |
|---|---|---|
| 1 | SLV-03 vacuity: both rules must show non-vacuous | **Cause found and removed** — `loop_iter: 12` against a 13-deep Fenwick walk — plus two further spec defects corrected (delta form, WAD scale). Both rules are now **non-vacuous but TIMEOUT** at `loop_iter: 14`. SLV-03 stays UNPROVED in Certora; it passes at the fuzz tier at wei granularity. |
| 2 | FEE-01 per-pool `satisfy` | **Still unproved, now precisely localised.** The new rung-1 `satisfy` shows that **no** fee accrual at all is reachable through `beforeSwap` under the present summaries, so the verdict beside it is vacuous coverage. It is not a fee-counting problem, and not the `feeVault` link (which is in place). |
| 3 | `bondIsMonotoneInDepth` (pin `BOND_DOUBLING_EVERY`) | **SUCCESS. Closed.** |
| 4 | `solvency` induction step with the transient reset | **The transient-reset step is SUCCESS**, as are 16 of 20 methods. The remaining four are the non-inductive `deployerCredit` carve-out described above. |
| 5 | The RoundManager write-once / append-only invariants | `canonicalIsWriteOnce` 15/17, `historyLengthIsMonotone` and `onlyFinalizeOrAdoptionWritesHistory` SUCCESS; `historyEntriesAreImmutable` and `reverseIndexIsConsistent` still blocked by the un-pinned `ownsToken` read. |
| 6 | The new guard-related rules | The guard is modelled consistently (above); REN-01 itself stays not-expressible here because the `exttload` is on the summarized singleton. `genesisIsNeverSniped` and `registerPoolRefusesAGenesisSnipeWindow` (F-1) and `twoDrawsCannotDoubleUpAtAnyClock` (F-2) all prove. |

## Budget

**5 initial runs** (DevVesting, Sleeve, FeeVault, RoundManager, FamilyHook) and **3 re-runs** (Sleeve
at `loop_iter: 14`; FeeVault after the `balanceOf` / `transfer` / ghost fixes; DevVesting after the
`total()` and clock fixes). That is the cap. Durations: DevVesting about 2 min, Sleeve about 2 min at
`loop_iter: 12` and about 75 min at 14, FamilyHook about 5 min, FeeVault about 55 min, RoundManager
about 80 min. Both big specs outran the local client's `timeout 2400` and were collected by polling
`jobData`, as `README.md` describes.

## What review-3 should do, in value order

1. **Pin `_.ownsToken`** (and any other prior-registry getter reached through `registryOfToken`) to a
   consistent ghost in `RoundManager.spec`. One line each; it is the single cause of five of the six
   remaining RoundManager failures.
2. **Make `solvency` inductive**: `ledgerTotal[c] + (c == ETH ? deployerCredit : 0) <= holdings(c)`.
3. **Revert the `ethLedgerDecomposition` non-negativity conjuncts** and tie each mirror to its storage
   word instead (load hook, or `requireInvariant`).
4. **Bound the Fenwick pre-state and the coefficients** in `Sleeve.spec` (tree values below 2^200,
   coefficients below 2^160). That removes the three overflow counterexamples *and* most of the search
   space the five timeouts are lost in; it is the only thing between review-2's diagnosis and a proved
   SLV-03.
5. **FEE-01**: find which step makes `beforeSwap` unable to reach `_collect`'s vault call. The rungs
   are already in the spec, so bisecting further is cheap — put a `satisfy` immediately after
   `_observe`, after the `equals(specified, parent)` early return, and after `poolManager.mint`.
6. **`aSlotIsWrittenOnceByItsFirstSwap`**: one more precondition, `cpBefore.tSwap <= e.block.timestamp`
   (no checkpoint from the future).
7. **`releasedNeverExceedsVested`**: bind the allocation before `release()`, exactly as
   `releasedEqualsTotalAfterDuration` now does.

## Findings

**No GENUINE CONTRACT BUG.** F-1..F-4 from review-1b are closed in code, and all four are now
corroborated by the Prover: F-1 and F-3 directly, F-2 by a rule whose precondition could be removed,
F-4 by the summary narrowing it was gating.

Two **specification** defects found this pass are worth carrying as process notes rather than as
contract findings:

- **S-1. A `loop_iter` below a data structure's real depth silently makes rules VACUOUS** under
  `optimistic_loop`, because the "the loop has exited" assumption becomes unsatisfiable on exactly the
  paths that matter. It cost SLV-03 two review cycles and was misattributed to a `2^128` literal. Any
  conf whose subject walks a Fenwick tree, a ring or a list should derive `loop_iter` from that
  structure's size, and any `rule_sanity` failure should be read as "the loop bound is wrong" first.
- **S-2. `DevVesting.releasedNeverExceedsTotal` is a tautology** — `total()` is *defined* as
  `balance + released`, so the invariant is `released <= balance + released`. It has been reported as
  verified since review-1 and proves nothing. It is now marked as such in the spec and in
  `PROPERTY_MAP.md`.
