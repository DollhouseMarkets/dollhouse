# Certora Prover — review-3 results

Third full execution of `certora/specs/`, against the contracts at **HEAD of review-3** (the
uncontested purse: no `rank`, no `_board`, no `purseWeights` / `purseWindow` / `RANK_MAX_AGE`,
`BidDeployer.deployAncestor(uint256 j, uint256 parentAmount)` deploying the whole generation share
under `canonical(j)`). Review-2 is in `RESULTS-review-2.md`, review-1/1b in `RESULTS-review-1.md`;
this file supersedes their "needs re-run" notes.

- Prover: `certora-cli 8.19.2`, classic CLI, free prover minutes. solc `0.8.26`.
- Every run: `--msg "<spec> review-3" --disable_local_typechecking` (this machine still has only
  JDK 17), `rule_sanity: basic`, `optimistic_loop: true`. Jobs were submitted without
  `--wait_for_results` and collected by polling `jobData`, as `README.md` describes.
- `CERTORAKEY` came from the environment. **No key and no per-job read key appears in any tracked
  file**; job links and their read keys are in `private/certora/JOBS-review-3.md` (gitignored), and a
  `git grep` of this tree for the read-key parameter name is empty. Artefacts (`output.json`,
  `FinalResults.html`, `jobData.json` and the whole output tarball, call traces included) are under
  `private/certora/review-3/<Spec>/`.
- **Run root.** Every job was submitted from a pristine `git archive HEAD` export outside the
  repository (plus `lib/`, plus the edited `certora/specs` and `certora/conf`), exactly as review-2
  had to do part-way through. The exported `contracts/` were compared against `git show HEAD:`
  before use and differ only in line endings. Concurrent edits to the working tree therefore cannot
  reach a job.

## Score

| Spec | rules | non-SUCCESS at review-2 | review-3 first run | review-3 after fixes |
|---|---|---|---|---|
| DevVesting | 18 | 2 / 17 | **1 / 18** | — (not re-run; nothing left to fix) |
| Sleeve | 11 | 3 FAIL + 5 TIMEOUT / 11 | **4 FAIL + 3 TIMEOUT / 11** | — (not re-run; budget) |
| FeeVault | 21 -> 22 | 3 rules / 20 | 3 rules / 21 (18 fully SUCCESS) | **3 rules / 22** (19 fully SUCCESS; the new `ethMirrorsAreNonNegative` proves) |
| RoundManager | 26 | 6 rules / 26 | 6 rules / 26, failing SUB-GOALS down from 40 to 14 | **4 rules / 26** (22 fully SUCCESS), 12 failing sub-goals |
| FamilyHook | 20 | 5 / 18 | 5 / 20 | **4 / 20** |

**No GENUINE CONTRACT BUG was found.** Every non-SUCCESS is a spec-scoping or spec-writing defect, a
Prover-tractability limit, or a divergence already documented in `docs/security/PROPERTY_RESULTS.md`.

## The purse change (review 3), and what the specs say about it

The purse machinery the specs referenced was **one line**: `rank(uint256)` in `RoundManager.spec`'s
methods block. It is removed. No rule, ghost, hook or `definition` in any spec mentioned `_board`,
`purseWeights`, `purseWindow`, `RANK_MAX_AGE`, `Ranked`, `BadRanking` or `NotACrownedRound`, so
nothing else had to be deleted. The only downstream effect is that `noTransitionIsPrivileged`'s
parametric sweep is one method shorter: review-2 timed out on `rank` and `submitScore`, review-3 has
only `submitScore` left to time out.

The three review-3 purse claims, in the order the task asks for them:

| Claim | Status |
|---|---|
| **(a) `deployAncestor(j, amount)` can only add liquidity under `canonical(j)`** (PUR-02) | **Half proved, half NOT EXPRESSIBLE here, recorded in the spec at `canonicalIsWriteOnce`.** The destination is a pure function of `j` computed inside `BidDeployer` (`roundManager.canonical(j)`), and it is not an argument, so the part this proof can falsify is that `canonical(j)` is fixed once the round crowns it — `canonicalIsWriteOnce`, `historyEntriesAreImmutable` and `onlyFinalizeOrAdoptionWritesHistory`. The last step, that the liquidity LANDS in `poolKeyOf(j)`, is `locker.depositBid(...)` from `BidDeployer` (which has no spec or conf of its own) into the v4 singleton, every entrypoint of which is summarized NONDET. CVL has no event predicate, so `PurseDeployed` is not a usable witness either. Stating it needs a `BidDeployer.spec` that summarizes `_.depositBid(...)` into a ghost recording `(key, childToken)` — a sixth run this review had no budget for. It stays a fork-tier check (`fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing`). |
| **(b) ETH drawn for `j` never exceeds `claimableEth(j)` nor the daily bucket** (PUR-05, BID-07) | **PROVED, and strengthened this pass.** `drawNeverExceedsTheBucket` (SUCCESS) is the daily half; the new `drawNeverExceedsTheGenerationsClaim` (SUCCESS) is the generation half, which the uncontested purse now rests on entirely. `twoDrawsCannotDoubleUp` and `twoDrawsCannotDoubleUpAtAnyClock` (both SUCCESS) close the same-instant case. The `consumeAncestorClaim(j, ethAmount)` signature is unchanged by the purse change, and all four rules still hold against it. `bucketNeverExceedsCap` keeps its Fenwick-imprecision failures (below). |
| **(c) losers never receive purse liquidity** | **Structural; deliberately NOT stated as a rule.** The destination is a pure function of `j`, and there is no code path that reads a rank, a board or a caller-supplied token, because none of them exist any more. A rule would have to quantify over a destination the deployer never computes. Recorded as such in `RoundManager.spec` next to `canonicalIsWriteOnce`, and carried at F and K by `Purse.prop.t.sol` and the fork test above. |

## The review-3 checklist, item by item

| # | Item | Outcome |
|---|---|---|
| 1 | **Pin `_.ownsToken`** | **WORKED, and it was the single cause it was diagnosed to be.** `RoundManager`'s failing sub-goals fell from **40 to 14** on the first run and to **12** after the re-run: `historyEntriesAreImmutable` 15/15 → 3/14, `reverseIndexIsConsistent` 16/17 → 3/17, `headIndexOnlyGrows` and `pairingRightsAreWriteOnce` down to the single `registerGenesis` leg each. `_.isIdle()` was pinned in the same style (the prior registry is asked for it in `_adoptIfContinuation` next to three getters that were already pinned). `_.poolKeyOf` stays unpinned and is recorded in the spec: it returns a STRUCT, which a CVL ghost cannot hold, and no rule reads a delegated pool key twice. |
| 2 | **`solvency` with the `deployerCredit` carve-out** | **WORKED for the method it was diagnosed on.** `payKeeper` — the rule's own review-2 counterexample — is now SUCCESS, as are 17 of 20 methods, the base and the transient step. The remaining three (`accrue`, `accrueForwarded`, `receiveForward`) are the other half of review-2's diagnosis and are unchanged by this fix: the backing for the new credit arrives as a `poolManager.mint` the HOOK issues before `accrue` is called, i.e. outside this proof and behind a summary, so the Prover raises `ledgerTotal` against a claim balance that the pinned ghost holds flat. The trace says exactly that: `ledgerTotal[1]` +1, `ghostTokenBalance[FeeVault]` and `ghostClaimBalance[FeeVault][1]` unchanged. |
| 3 | **Revert the `ethLedgerDecomposition` non-negativity conjuncts, tie each mirror to its storage word** | **WORKED: the review-2 regression is gone — 10 failing methods → 2, and there it stops.** The conjuncts are removed; `devBalance` and `genesisBidEarmark` are now ABSOLUTE mirrors of their scalar words (like `ledgerTotal` already was) with an `Sload` hook pinning each to the word it mirrors, and every mapping-sum mirror has an `Sload` hook pinning the sum to be at least the element being read. The two residuals have separate causes, both diagnosed from the traces, and the re-run attacked both — the argument convention as a `preserved` block for `accrue`, and the mirrors' non-negativity as its OWN invariant (`ethMirrorsAreNonNegative`, which **proves, 22/22 sub-goals**) assumed here with `requireInvariant`. Neither moved the two methods: the re-run's counterexamples still open with mirror values the required invariant should exclude, which is the next thing to understand (most likely the interaction between `persistent` ghosts and an invariant assumption). Recorded, not papered over. |
| 4 | **Bound the Fenwick pre-state and the coefficients** (`Sleeve`) | **PARTIAL.** `genesisTakesTheWholeSleeveAtMZero` FAIL → **SUCCESS**, which is the first time an SLV rule has proved at a non-vacuous loop bound. `rangeAddThenPointQueryIsTheClosedForm` and `pointQueryIsAdditive` still fail, with counterexamples sitting exactly ON the new bounds (`before = -(2^200 - 1)`, `c1 = -(2^160 - 2)`), i.e. the bound is still loose enough to let the `unchecked` accumulator wrap; `noIndexOutsideTheRangeIsCredited` moved TIMEOUT → FAIL for the same reason. Three rules still TIMEOUT. Bounds one power of two tighter than the reachable range (tree words `< 2^190`, coefficients `< 2^128`, which is what a sleeve bounded by the vault's ETH balance actually produces) is the next step, and it is a re-run this pass had no budget left for. |
| 5 | **FEE-01: bisect where `beforeSwap` stops reaching `_collect`'s vault call** | **DONE, and it is now localised to one call.** Two new rungs: `beforeSwapIsReachable` (rung 0, **SUCCESS** — `beforeSwap` does execute to completion) and `theFeeMintIsReachable` (rung 0.5, **SUCCESS** — execution reaches `poolManager.mint(feeVault, parent.toId(), total)` inside `_collect`, i.e. past the `equals(specified, parent)` early return AND with a non-zero total). `anyFeeAccrualIsReachable` is still FAIL. So the loss is in the **next statement**: the vault call itself. The call trace names it — `[TransferInstance] sender: FamilyHook; receiver: FeeVault; transferred amount: 0` followed by `unknown: AUTO summary`, while the mint one line earlier resolves to `sighash 0x156e29f6: recordMint()`. The `_.accrue(...)` summary **never fires**, so `ghostAccrueCount` cannot move and `protocolFeeOnlyOnTheGenesisPool`'s "not violated" stays vacuous coverage. It is a summary-matching defect in the spec, not unreachable code: the signature matches `IFeeVault.accrue` and `FeeVault.accrue` exactly, so the next experiments are (i) an EXACT `FeeVault.accrue(...)` entry instead of the `_.` wildcard, and (ii) counting accruals from the linked vault's own `ledgerTotal` store instead of from a summary. |
| 6 | **`aSlotIsWrittenOnceByItsFirstSwap`: `cpBefore.tSwap <= e.block.timestamp`** | **FIXED, in two steps, and the second step is the finding.** The precondition alone was not enough: the new counterexample is `e.block.timestamp = 0xffff…ff0000000000000000` — a MULTIPLE OF 2^64 — against `cpBefore.tSwap = 626220`, so `_checkpoint`'s `uint64(block.timestamp)` truncates to 0 and stamps the slot lower than it found it while the mathint precondition holds. With the clock also bounded to uint64 (the same bound `FeeVault.spec` and `DevVesting.spec` already carry, finding F-2's family) the rule is **SUCCESS**. SCR-05 is now proved here. |
| 7 | **`releasedNeverExceedsVested`: bind the allocation before `release()`** | **FIXED: SUCCESS.** Same cause and same fix as `releasedEqualsTotalAfterDuration` in review-2 — OZ `safeTransfer` is an unresolved low-level call the Prover AUTO-havocs, so the post-state `total()`, and with it `vested(t)`, is unrelated to the pre-state one. `total()` is constant across `release` by construction, so binding it first is strictly stronger. |

## Per-spec detail

### DevVesting — 1 non-SUCCESS of 18

`releasedNeverExceedsVested` is **SUCCESS** (checklist 7). The only non-SUCCESS left is
`releasedNeverExceedsTotal`, the **TAUTOLOGY** review-2 identified (S-2): `total()` is defined as
`balance + released`, so the invariant reduces to `released <= balance + released`. It SANITY_FAILs
on every sub-goal, is marked as such in the spec and in `PROPERTY_MAP.md`, and is not counted as
evidence for VST-03.

### FeeVault — 3 rules with failing methods of 21, 18 fully SUCCESS

| Rule | review-2 | review-3 | classification |
|---|---|---|---|
| `solvency` | FAIL on `accrue`, `accrueForwarded`, `receiveForward`, `payKeeper` | **FAIL on 3** (`payKeeper` closed) | checklist 2 above. Spec-scoping: the claim's backing is minted by the hook, outside this proof. |
| `ethLedgerDecomposition` | FAIL (10) — a review-2 regression | **FAIL (2)** before and after the re-run: `accrue`, `forwardProtocolFee` | checklist 3 above. `accrue`: the Prover picks `currency != ETH` together with `parentToken == address(0)`, a pair the hook cannot produce (`parentToken` IS the genesis marker and the genesis pool's parent currency is ETH), which credits an ETH-side term with a non-ETH fee. `forwardProtocolFee`: `ghostAncestorClaimed` starts hugely negative on a path that reads no `ancestorClaimed` key, so no `Sload` pin fires. |
| `bucketNeverExceedsCap` | FAIL (4) | **FAIL (3) + TIMEOUT (1)** (`consumeAncestorClaim` closed) | unchanged diagnosis: Prover imprecision inside the Fenwick `_prefix` walk (`Imprecision detected: BWAnd`) at `loop_iter: 3`, which cannot be raised here. BID-07 holds at U and F. |
| new: `drawNeverExceedsTheGenerationsClaim` | — | **SUCCESS** | PUR-05, the generation half of the keeper draw bound (claim (b) above). |
| new: `ethMirrorsAreNonNegative` (re-run) | — | **SUCCESS** | every ETH-side mirror is non-negative in every reachable state — the claim review-2 tried to conjoin into the decomposition and could not discharge there. It proves as its own invariant, which is the `requireInvariant` half of checklist item 3. |
| the other 17 rules | | SUCCESS | including all five that F-4 unblocked in review-2, and `payKeeperIsBoundedByDeployerCredit`. |

### RoundManager — 6 rules with failing sub-goals of 26, but 12 failing sub-goals instead of 38

The `ownsToken` pin did what review-2 predicted. What is LEFT is a different and smaller set, and it
is one spec-writing defect plus two unreachable pre-states:

| Rule | review-2 | review-3 | classification |
|---|---|---|---|
| `historyEntriesAreImmutable` | FAIL 15/15 | **FAIL 3/14** (`addCandidate`, `finalize`, `registerGenesis`), unchanged by the re-run | The first-run counterexample was an `address(0)` entry (an empty slot inside the history length, with `addCandidate` writing `_creatorOf[0x0]` for a candidate token the Prover also picked as `address(0)`), and `require entry != 0` removed exactly that one. What is left is the SAME residual `canonicalIsWriteOnce` has: the rule reads the history through `canonical` / `parentOf` / `creatorOf`, every one of which DELEGATES while `!adopted`, and these three methods are the ones that can flip the delegation decision mid-rule. The fix is the review-4 item below: state these rules against the LOCAL storage words, not against the delegating getters. |
| `reverseIndexIsConsistent` | FAIL 16/17 | **FAIL 3/17**, unchanged by the re-run | same residual |
| `headIndexOnlyGrows` | FAIL 1/15 | FAIL 1/14 → **SUCCESS after the re-run** | Spec-scoping, fixed: the pre-state was `_head == 0` with `_headIndex == MAX_UINT256`, i.e. an empty registry with a non-zero index, which no constructor or writer can produce. Restating that pairing (`head() == 0 => headIndex() == 0`) discharges it. |
| `pairingRightsAreWriteOnce` | FAIL 1/15 | FAIL 1/14 → **SUCCESS after the re-run** | **Spec-writing defect found this pass (S-3), fixed in the spec:** `isHeadWriter` names `finalize` and `openRoundIfIdle` and MISSES `registerGenesis`, which is the third and last writer of `_head` / `_headIndex` (`RoundManager.sol` writes them in exactly three places). Review-2 could not see it because every leg was failing for the `ownsToken` reason. Naming the third writer discharges the rule. |
| `canonicalIsWriteOnce` | FAIL 2/17 | **FAIL 2/17** (`finalize`, `registerGenesis`), unchanged by the re-run | Spec-scoping: while `!adopted`, `headIndex()` DELEGATES to the prior registry, so the invariant's `i > headIndex() => writes[i] == 0` conjunct compares a local write at index 6029 against a delegated head of 6027. The conjunct wants the LOCAL `_headIndex`. |
| `noTransitionIsPrivileged` | FAIL 3 + TIMEOUT 2 | **FAIL 3 + TIMEOUT 1** | the `rank` timeout is gone with `rank`; `submitScore` still times out. ROL-01's substance is carried by `sunsetTouchesNothingElse` and (in `FeeVault.spec`) `onlyBidDeployerHooks`. |
| the other 22 rules (after the re-run) | | SUCCESS | including `bondIsMonotoneInDepth`, `maxIndexIsRespected`, `finalizeIsIdempotent`, `requestEndIsOnceAndNotBeforeT`, `adoptionHappensAtMostOnce`, `historyLengthIsMonotone`, `onlyFinalizeOrAdoptionWritesHistory`. |

### FamilyHook — 4 non-SUCCESS of 20 after the re-run

`aSlotIsWrittenOnceByItsFirstSwap` is **SUCCESS** (checklist 6). What is left is one diagnosis in
three rows plus one deliberate divergence:

- `anyFeeAccrualIsReachable`, `someProtocolFeeIsReachable`, `oneProtocolFeeAtTheEthEdgeIsReachable`
  — all FAIL, and all for the single reason in checklist 5: the vault call is not summarized by the
  `_.accrue` entry, so the accrual counter has no writer on that path. Rungs 0 and 0.5 SUCCEED, which
  is what localises it. FEE-01's per-pool half therefore stays UNPROVED (`protocolFeeOnlyOnTheGenesisPool`
  reports SUCCESS over a counter that cannot move).
- `averageOverHandlesTheDegenerateWindow` — FAIL, **documented divergence, deliberately not fixed**:
  `PROPERTIES` §7.12 gap 12, the code reverts `BadScoreWindow` at `t1 == t0` and the rule keeps the
  specification's reading.

### Sleeve — 4 FAIL + 3 TIMEOUT of 11

| Rule | review-2 | review-3 | classification |
|---|---|---|---|
| `genesisTakesTheWholeSleeveAtMZero` | FAIL | **SUCCESS** | the bounds worked here |
| `rangeAddThenPointQueryIsTheClosedForm` | FAIL | FAIL | bounds still too loose: the counterexample sits ON them (`before = -(2^200 - 1)`, `c1 = -(2^160 - 2)`), so the `unchecked` accumulator can still wrap |
| `pointQueryIsAdditive` | FAIL | FAIL | same |
| `noIndexOutsideTheRangeIsCredited` | TIMEOUT | FAIL | same (the bound made it tractable enough to produce a counterexample instead of timing out) |
| `genesisWeightIsTwiceTheTerminalWeight` | TIMEOUT | FAIL | same |
| `everyAncestorShareIsNonNegative`, `noShareExceedsTheSleeve`, `sumOfSharesNeverExceedsTheSleeveSmallM` | TIMEOUT | TIMEOUT | tractability, unchanged; a correctly unrolled 13-deep Fenwick walk over three trees with symbolic indices is expensive |
| `indexPastMaxReverts`, `reversedRangeReverts`, `envfreeFuncsStaticCheck` | SUCCESS | SUCCESS | |

**SLV-03 is still UNPROVED in Certora.** It passes at the fuzz tier at wei granularity
(`Sleeve.prop::testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`); the WAD-scale over-allocation stays
the documented divergence it already was.

## Findings

**No GENUINE CONTRACT BUG.** One **specification** defect is worth carrying as a finding about the
specs rather than the contracts, because it is the first one in three passes that is a wrong CLAIM
rather than a wrong modelling assumption:

- **S-3. `isHeadWriter` in `RoundManager.spec` enumerated two of the three head writers.**
  `registerGenesis` writes `_head` and `_headIndex` (the factory-only, write-once genesis seat) and
  was missing, so `pairingRightsAreWriteOnce` was asserting something the contract does not claim.
  The contract is right; the spec was wrong. It was invisible until `_.ownsToken` was pinned, which
  is itself the lesson: **a residual failure can hide a real spec defect behind a modelling one.**

Carried forward from review-2 and still true:

- **S-1.** A `loop_iter` below a data structure's real depth silently makes rules VACUOUS under
  `optimistic_loop`.
- **S-2.** `DevVesting.releasedNeverExceedsTotal` is a tautology and proves nothing.

## Budget

**5 initial runs** (DevVesting, RoundManager, FeeVault, FamilyHook, Sleeve) and **3 re-runs**
(FamilyHook after the clock bound — SCR-05 proved; FeeVault after the `accrue` argument convention
and the mirror non-negativity invariant — one new invariant proved, the two residuals unmoved;
RoundManager after the three spec fixes above — two rules discharged, 6 non-SUCCESS rules down to 4).
That is the cap. Two
submissions — the first FamilyHook re-run and the first RoundManager re-run — came back **FAILED in
about 100 s with no artefacts at all** (no `output.json`, no `Reports/`, nothing in the tarball);
both were re-submitted BYTE-IDENTICALLY and the FamilyHook one then ran normally, so they are
recorded as infrastructure flakes rather than as runs. Durations: DevVesting about 2 min, FamilyHook
about 5 min, FeeVault about 55 min, Sleeve about 75 min, RoundManager about 80 min.

## What review-4 should do, in value order

1. **FEE-01, one step from an answer.** Replace the `_.accrue(...)` wildcard with an EXACT
   `FeeVault.accrue(...)` entry (the vault is linked in `FamilyHook.conf`), or count accruals from
   the linked vault's own `ledgerTotal` store. Rungs 0 and 0.5 already prove the execution gets
   there; if the counter then moves, `protocolFeeOnlyOnTheGenesisPool` stops being vacuous and
   FEE-01's per-pool half is finally proved.
2. **Sleeve bounds, one power of two tighter**: tree words `< 2^190`, coefficients `< 2^128`. The
   `2^200` / `2^160` pass already flipped one rule; the counterexamples now sit exactly on the
   bounds. This is still the only thing between the diagnosis and a proved SLV-03.
3. **State the history rules against LOCAL storage, not the delegating getters.** This is now ONE
   item covering the four rules RoundManager has left: `canonicalIsWriteOnce`'s second conjunct
   compares a local write against the DELEGATED `headIndex()` (6029 vs 6027 in the trace), and
   `historyEntriesAreImmutable` / `reverseIndexIsConsistent` read the history through `canonical` /
   `parentOf` / `creatorOf` / `indexOf`, all of which delegate while `!adopted` — and the three
   methods still failing are exactly the ones that can flip the delegation decision mid-rule. A
   storage read or a ghost mirror of `_canonical` / `_headIndex` states what RND-09 actually claims.
4. **`solvency` / `ethLedgerDecomposition` on the accrual path**: give the spec a way to model "the
   fee claim was minted to the vault before `accrue` was called" — either a `preserved` block that
   raises the pinned claim-balance ghost by the credited amount, or an explicit `deliveredButUnbooked`
   term in `holdings`.
5. **`ethLedgerDecomposition`, the last two methods.** `ethMirrorsAreNonNegative` PROVES but
   `requireInvariant`-ing it into the decomposition did not remove the negative-mirror
   counterexamples, and the `accrue` argument convention did not remove the other one. Find out why
   an assumed, proved invariant over `persistent` ghosts is not constraining the pre-state here; then
   give `ghostAncestorClaimed` and `ghostPendingSum` the full sum-ghost treatment (per-key mirror plus
   a sum axiom), because `Sload` pins only fire on keys a method actually reads.
6. **A `BidDeployer.spec`** whose `_.depositBid(...)` summary records `(key, childToken)` into a
   ghost. That is what makes PUR-02's landing step expressible at this tier; without it the claim
   stays a fork test.
7. **`noTransitionIsPrivileged` / `submitScore`**: still a timeout, still the last parametric leg.
