# Certora Prover — review-1 results

First execution of the spec-derived CVL in `certora/specs/`. Before this run the specs had never
been near a compiler: they were written from `docs/spec/PROTOCOL_SPEC.md` and
`docs/spec/PROPERTIES.md` alone, and the confs still carried `<TODO link>` placeholders. So the
headline result of review-1 is **the pipeline now runs end to end**, plus a first, partial harvest
of rule outcomes.

- Prover: `certora-cli 8.19.2`, classic CLI (`certoraRun <conf>`), free prover minutes.
- solc: `0.8.26` (Foundry's svm copy, exposed on PATH as `solc0.8.26`).
- `CERTORAKEY` is read from the environment. It is never written to a file, a conf or this report.
- Every run: `--msg "<spec> review-1" --wait_for_results`, `rule_sanity: basic`,
  `optimistic_loop: true`.

## Status by spec

| Spec | Job | Type-checks | Outcome at cut-off |
|---|---|---|---|
| DevVesting | [33a96270…](https://prover.certora.com/output/4818370/33a962700f3c404686630ad537c9f63e) | yes | completed — 4 rule violations + 1 envfree static-check violation |
| Sleeve | [ac2c6f2f…](https://prover.certora.com/output/4818370/ac2c6f2f6cb44dbe8b6d3d984b0c9c38) | yes (after 1 fix) | completed — 4 violations, 2 sanity failures, 1 timeout |
| FeeVault | [88273a7b…](https://prover.certora.com/output/4818370/88273a7bff5f461e963394347cc9ebae) | yes (after 3 fixes) | retrieved in review-1b — 13/29 non-SUCCESS; re-run as [23c8f4ac…](https://prover.certora.com/output/4818370/23c8f4ac19b54a0f9cba6d81cd4d96bf), 7/29 |
| RoundManager | [e286a631…](https://prover.certora.com/output/4818370/e286a631b0c546d0bcc9244fcb8cc35a) | yes | retrieved in review-1b — 17/30 non-SUCCESS; re-run as [cba72e35…](https://prover.certora.com/output/4818370/cba72e3575af4fae8da8e2162d53627b), 10/30 |
| FamilyHook | [aa7d28a9…](https://prover.certora.com/output/4818370/aa7d28a9ef074c88b109b0f8575d3b30) | yes (after 3 fixes) | retrieved in review-1b — 8/15 non-SUCCESS; re-run as [cdeafe7f…](https://prover.certora.com/output/4818370/cdeafe7f06514ad1b6cdc4e448e3564a), 4/15 |

The DevVesting counts below are from the run as the spec stood *before* the two spec-writing fixes
described in "Spec fixes". They are reported as observed; the fixes are in the tree and the rules
need a review-2 re-run to be re-scored.

## Violations

### DevVesting

| # | Rule | Counterexample | Assessment |
|---|---|---|---|
| 1 | `envfreeFuncsStaticCheck` | "Specification marks `DevVesting.releasable()` as `envfree` but the method uses `[TIMESTAMP]`" | **Spec-writing error.** `releasable()` is `vested(block.timestamp) - released`, so it cannot be `envfree`. Fixed: it now takes an `env` and the two rules that call it pass `e`. |
| 2 | `releasePaysTheDeltaToTheCurrentBeneficiary` | `owed = 0`, `paid = MAX_UINT256` | **Spec-writing error, knock-on of #1.** With `releasable()` mis-declared `envfree` the Prover reads it outside the environment, so `owed` and `paid` are unrelated. |
| 3 | `everythingVestsAtTheEnd` | `t = 2^64 - 2` | **Spec-writing error.** Parametric rules start from an arbitrary storage state, so the constructor's own guards (`_duration != 0`, `_duration >= _cliff`, and `start + cliff` / `start + duration` not overflowing `uint64`) do not hold. `vested()` computes `start + cliff` in `uint64`, which reverts on overflow. The rule needs those constructor-established preconditions stated; it is not a claim about the code. **Open for review-2.** |
| 4 | `releasedEqualsTotalAfterDuration` | `e.block.timestamp` near `MAX_UINT64` | Same cause as #3. **Open for review-2.** |
| 5 | `nothingReducesClaimableExceptRelease` — violated on `FamilyToken.transfer`, `FamilyToken.approve`, `FamilyToken.transferFrom`, `FamilyToken.burn`, `DevVesting.executeBeneficiaryTransfer`, `DevVesting.announceBeneficiaryTransfer`, `DevVesting.cancelBeneficiaryTransfer` | any token method moving the vesting contract's balance | **Spec-writing error.** The parametric `method f` ranged over *every* contract in the scene, including the linked `FamilyToken`. A token transfer out of the vesting contract does reduce `releasable()`, but that is not a DevVesting method and VST-05 does not claim otherwise. Fixed: every parametric rule is now filtered with `f.contract == currentContract`. |

No DevVesting violation is a genuine contract bug. Nothing here touches PROPERTY_RESULTS' SLV-03 or
REN-01 divergences.

### FamilyHook — found while type-checking, before any rule ran

| # | What | Assessment |
|---|---|---|
| 10 | The drafted `registerPool` signature was `(PoolKey, uint160, bool, bool, uint32)`. The contract's is `(PoolKey key, bool isGenesis, uint160 initSqrtPriceX96, uint64 tradingStart, uint32 scoreSlotS, bool parentIsCurrency0)` — six parameters, different order. | **Spec-vs-code divergence in the written specification.** The spec was drafted from `docs/`, so this says the documented interface for `registerPool` does not match the deployed one. Worth reconciling in `docs/spec/PROTOCOL_SPEC.md`, not just in the CVL. The spec now uses the contract's signature. |
| 11 | The drafted `afterSwap` took `int256` where v4 passes `BalanceDelta` (a user-defined value type over `int256`). | **Spec-writing error**, corrected to `FamilyHook.BalanceDelta`. |

Neither was reachable before review-1 because nothing had ever compiled the specs.

### Sleeve (FenwickRangeAdd via FenwickHarness)

| # | Rule | Counterexample | Assessment |
|---|---|---|---|
| 6 | `rangeAddThenPointQueryIsTheClosedForm` | `c0 = c1 = c2 = 0`, `M = j = 2638`, `query(j) != 0` | **Spec-writing error.** The harness's Fenwick tree starts in an *arbitrary* state, not an empty one, so a zero range-add does not imply a zero query. The rule must either require an empty tree or assert the **delta** across the `rangeAdd`. Re-stating it as a delta keeps SLV-01 at full strength. **Open for review-2.** |
| 7 | `everyAncestorShareIsNonNegative` | `sleeve = 0`, `M = 2920`, `j = 2919` | Same cause as #6 (pre-existing negative tree contents). **Open for review-2.** |
| 8 | `genesisTakesTheWholeSleeveAtMZero` | `sleeve = 0` | Same cause as #6. |
| 9 | `indexPastMaxReverts` | `sleeve = 0`, `M = 2^12 + 1 = 4097` | **Spec-vs-code divergence, benign.** `FenwickRangeAdd.addSleeve` short-circuits `if (sleeve == 0) return;` *before* it reaches `rangeAdd`'s `r > MAX_INDEX` check, so a zero sleeve at `M > MAX_INDEX` is a silent no-op rather than a revert. SLV-07's intent — "no index past MAX_INDEX is ever credited" — is not broken: nothing is credited at all, and `noIndexOutsideTheRangeIsCredited` verified. The rule should require `sleeve > 0`. Recorded as a finding so the short-circuit is a deliberate, documented choice rather than an accident. |

Sanity (vacuity) failures: `noShareExceedsTheSleeve` and `sumOfSharesNeverExceedsTheSleeveSmallM`
both report `rule_not_vacuous` unsat, i.e. their preconditions are unsatisfiable, so their "Not
violated" verdicts are worth nothing. Both are the SLV-03 conservation bound and both must be
re-stated for review-2. **This is the most important Sleeve finding: SLV-03 is currently unproved,
not proved.**

Verified (non-vacuous): `reversedRangeReverts`, `pointQueryIsAdditive` (SLV-04),
`noIndexOutsideTheRangeIsCredited` (SLV-02), `envfreeFuncsStaticCheck`.

Timeout: `genesisWeightIsTwiceTheTerminalWeight` (SLV-05) at 417 s. The rule multiplies two point
queries by four-digit constants over a 4096-wide tree; it needs a bounded `M` or a `--smt_timeout`
bump in review-2.


## Unretrieved verdicts (FeeVault, RoundManager, FamilyHook) — RESOLVED IN REVIEW-1B

> **This section is kept as the review-1 record. All three verdicts were retrieved in review-1b and
> are assessed rule by rule at the end of this file. The diagnosis below is correct about the
> read key but wrong about the endpoints: they reject a default Python/curl `User-Agent` with
> 403 and answer normally with a browser one, and the whole output tree — call traces included — is
> downloadable as a tarball from `jobData`'s `zipOutputUrl`. See "How the artefacts were retrieved".**


All three jobs type-checked, uploaded and started proving; none of their result tables could be
collected afterwards, and **this is a process failure worth fixing before review-2, not a property
result.**

Certora's result endpoints (`/output/<user>/<run>/output.json`, `/jobStatus/...`, `/jobData/...`)
authenticate with the per-job **read key** (the `anonymous…Key` query parameter), which the server returns exactly once in the
response to `POST /cli/verify` and which the CLI prints only on the *failure* path. These three runs
did not take that path, so the key was never printed. It is held only in the run's
`.certora_internal/` tree, which is deleted between runs (the CLI never overwrites its own scratch,
so a stale copy silently shadows an edited spec — see the environment note). Passing `CERTORAKEY`
instead returns **403** on every one of those endpoints, and `certora-cli` 8.19.2 exposes no
job-listing API (`/cli/verify` and `/cli/options` are the only endpoints it knows). The verdicts are
therefore reachable only through a logged-in session on `prover.certora.com`.

This was verified, not assumed: a disk-wide search for the three run IDs returns only this report and
the CLI's own transcript logs, and a search for per-job read key returns exactly three keys — the two
DevVesting attempts and Sleeve, i.e. precisely the runs that took the failure path. All four endpoints
were probed with `CERTORAKEY` and returned 403 (`exists` returned 404).

Job URLs, for whoever has that session:

- FeeVault — `https://prover.certora.com/output/4818370/88273a7bff5f461e963394347cc9ebae`
- RoundManager — `https://prover.certora.com/output/4818370/e286a631b0c546d0bcc9244fcb8cc35a`
- FamilyHook — `https://prover.certora.com/output/4818370/aa7d28a9ef074c88b109b0f8575d3b30`

**Fix for review-2:** capture the per-job read key at submission — it is in the CLI's
`.certora_internal/latest/` metadata and in the `reportUrl` the CLI builds — and record it next to
the job URL *before* the scratch tree is cleaned. Nothing about FeeVault, RoundManager or FamilyHook
is verified or falsified by review-1; treat all three as **unrun**.

## Spec fixes made during review-1

All are syntax/type/scope corrections. **No rule's meaning was weakened**; where a rule could only
be salvaged by weakening it, it was left violated and recorded above instead.

1. `Sleeve.spec` — CVL forbids assigning to a variable after it has been read, so the `s = s + …`
   accumulator in `sumOfSharesNeverExceedsTheSleeveSmallM` became four separately-bound terms with
   the out-of-range ones zeroed. Same sum, same bound.
2. `FeeVault.spec` — `old` is reserved in CVL hook bodies; the eight `(uint256 old)` hook
   declarations and their seven `to_mathint(old)` uses became `oldV`.
3. `FeeVault.spec` — `ledgerTotal` is keyed by the v4 `Currency` user-defined value type, not by
   `address`. Both hooks, the `ghostLedgerTotal` mapping and its `init_state axiom` were retyped to
   `FeeVault.Currency`, and `definition ETH()` now returns `FeeVault.Currency`.
4. `DevVesting.spec` — `releasable()` un-declared as `envfree` (see violation #1).
5. `DevVesting.spec` — every parametric rule and the `releasedNeverExceedsTotal` invariant gained
   `f.contract == currentContract` (see violation #5).
6. `FamilyHook.spec` — `using FamilyHook as hook;` renamed to `familyHook`: `hook` is a CVL keyword.
7. `FamilyHook.spec` — `RegisteredPool` and `ScoreCheckpoint` are declared on `IFamilyHook`, so they
   must be referenced as `IFamilyHook.<T>`, not `FamilyHook.<T>`.
8. `FamilyHook.spec` — `registerPool` and `afterSwap` corrected to the contract's real ABI
   (findings #10 and #11).

Applied after the run, from the review-1 findings, and **not yet re-run**:

9. `Sleeve.spec` — violations #6, #7 and #8 restated as **deltas** across the `rangeAdd`/`addSleeve`,
   which is the claim SLV-01/SLV-02/SLV-06 actually make and is strictly more general than the
   empty-tree form the drafts assumed. #8 was additionally *tightened* from "credited something" to
   "credited the whole WAD-scaled sleeve to index 0", which is what spec J states.
10. `Sleeve.spec` — `indexPastMaxReverts` (#9) now requires `sleeve > 0`, so it states SLV-07 about
    sleeves that actually credit something. The zero-sleeve short-circuit stays on the record as a
    finding rather than being silently absorbed.
11. `Sleeve.spec` — `2^128` replaced with its decimal value in the two SLV-03 rules. **`^` is not
    exponentiation in CVL**, so the drafted bound did not mean what it read as; this is the prime
    suspect for those two rules coming back vacuous, and review-2 should confirm it.
12. `DevVesting.spec` — a `wellFormedSchedule()` definition restates the constructor's own guards
    (`duration != 0`, `cliff <= duration`, and `start + cliff` / `start + duration` not overflowing
    `uint64`) and is required by `everythingVestsAtTheEnd` and `releasedEqualsTotalAfterDuration`
    (#3, #4). It excludes exactly the states the deployed contract cannot be in.

Nothing was marked `// NOT-EXPRESSIBLE` in review-1: every error hit so far was a CVL syntax or
typing problem with a meaning-preserving fix, not a property that CVL cannot state. The
not-expressible notes already in the specs (the ancestor sleeve as a scalar ledger delta, in
`FeeVault.spec`) were written at drafting time and still stand.

## Conf fixes made during review-1

The `<TODO link>` placeholders are gone. Wiring was read from `script/Deploy.s.sol` and the three
constructors; each conf now documents which immutables are linked and, for each one that is *not*,
why leaving it havoc'd is sound (in every case the spec already summarizes every call through it,
and an unconstrained address is strictly more general than a pinned one). The v4 `PoolManager` is
deliberately not linked, per the specs' own `methods` blocks.

Also, per conf: `packages` mirroring `foundry.toml`'s remappings, `solc_optimize: "200"`,
`solc_evm_version: "cancun"`, `solc_via_ir: true`, and `optimistic_fallback` moved from the
now-rejected `prover_args` form to its own attribute.

Two build-level settings needed for the three big contracts, both documented inline in the confs:

- `disable_source_finders` / `disable_internal_function_instrumentation`. The Prover's autofinder
  instrumentation adds locals to already stack-heavy functions. The finders exist only to let a spec
  observe or summarize *internal* functions; every summary in these specs is an external `_.`
  wildcard, so turning them off costs no rule any strength.
- `yul_optimizer_steps`. The Prover substitutes its own Yul optimiser sequence for solc's, and its
  sequence drops the full inliner — which makes `FeeVault`, `RoundManager` and `FamilyHook` fail to
  compile with "stack too deep" even though foundry builds them cleanly with the same solc, the same
  `via_ir` and the same `runs = 200`. The confs now pass solc's own default sequence. Note the space
  in `gv i f`: the Prover rewrites the literal substring `gvif` to `gvf` even inside a user-supplied
  sequence, and solc's step parser ignores whitespace, so the spaces are what preserve the inliner.
  An optimiser sequence changes code layout, never behaviour; this is the sequence `foundry.toml`
  builds with.

## Environment note (Windows)

`certora-cli` is not supported on Windows and 8.19.2 does not run there unmodified. Four
path-handling defects had to be patched **in the local certora-cli install** — not in this repo — to
get a job submitted at all:

1. solc keys its standard-json output with forward slashes; the CLI looks the file up with `os.sep`,
   so the primary source is never found ("Worklist contains … does not exist in contract set").
2. `find_contract_address` splits the `file:contract` key on `':'`, which a Windows drive letter
   turns into three parts ("too many values to unpack").
3. The local CVL typechecker is handed a `NamedTemporaryFile` that Python still holds open, which
   Windows refuses to let the JVM write to, so local type-checking always "fails" and the run aborts.
4. `.certora_verify.json` records the spec path with backslashes; the Linux prover container then
   cannot open it, and the job dies remotely with `NoSuchFileException`.

All four are separator/handle bugs in the CLI's file plumbing. None of them changes what is proved.
They are listed here so review-2 can decide whether to run the Prover from WSL or a Linux CI runner
instead of re-applying local patches. A JDK 21 is also required (the CLI refuses to type-check
locally on the JDK 17 that is on this machine's PATH).

Separately: `certoraRun` never overwrites its own `.certora_sources` scratch tree, so an edited spec
is silently type-checked from a stale copy. Delete `.certora_sources`, `.certora_config`,
`.certora_internal` and `.certora_*.json` between runs.

## What review-2 must do

1. Collect the FeeVault and RoundManager results from their job URLs; both were still running when
   review-1 cut off locally.
2. Collect the FamilyHook results from its job URL; it too was still running at the cut-off.
3. Re-state the three Sleeve rules that assume an empty tree (#6, #7, #8) as deltas, and add
   `sleeve > 0` to #9.
4. Fix the two vacuous SLV-03 rules. **SLV-03 is currently unproved.**
5. Re-run DevVesting after the `envfree` and `f.contract` fixes, and give `everythingVestsAtTheEnd`
   and `releasedEqualsTotalAfterDuration` the constructor's own preconditions.
6. Bound `M` (or raise the SMT timeout) for `genesisWeightIsTwiceTheTerminalWeight`.
7. Reconcile `registerPool`'s documented signature (finding #10) with the deployed one.
8. Run the three big specs somewhere they are not competing with a 16 GB machine's single build
   lock: FeeVault and RoundManager each outran the 60-minute local client timeout while the cloud
   job kept going.

---

# Review-1b — the three big specs, retrieved, assessed and re-run

Review-1 left FeeVault, RoundManager and FamilyHook **unrun**: their jobs completed but the per-job
per-job read key the result endpoints authenticate with had been lost. That is now solved, the verdicts
are in, every non-SUCCESS rule has been assessed against the contract, the spec-scoping and
spec-writing errors have been fixed, and all three specs have been re-run.

## How the artefacts were retrieved

The keys were recovered and are kept in `private/certora/JOBS-review-1.md` (gitignored; **no key
appears in any tracked file** — grepping our own tree for that parameter name finds nothing). Two practical notes for
review-2:

- The endpoints reject a default Python/curl `User-Agent` with **403**, which is what review-1 read
  as "the key does not work". With a browser `User-Agent` they all answer.
- Far more than `output.json` is reachable: `/<job>/FinalResults.html`, `/<job>/statsdata.json`,
  `/jobData/<user>/<job>` and — the useful one — the **whole output tree** as a `.tar.gz` at the
  `zipOutputUrl` in `jobData`. That archive contains `Reports/ctpp_<rule>.txt`, the Prover's
  **pretty-printed call trace with the counterexample's storage, ghosts and CVL model**, which is
  what every assessment below is built on. Nothing had to be read out of the web tree view.
  `Results.txt` is 403 over HTTP but is inside the archive.

Artefacts are saved under `private/certora/<Spec>/` (review-1) and
`private/certora/<Spec>-review-1b/` (this pass).

## Score

| Spec | non-SUCCESS at review-1 | non-SUCCESS at review-1b | of which are claims about the code |
|---|---|---|---|
| FeeVault | 13 / 29 | **7 / 29** | 0 |
| RoundManager | 17 / 30 | **10 / 30** | 0 |
| FamilyHook | 8 / 15 | **4 / 15** | 2 documented divergences + 1 honest vacuity report |

**No GENUINE BUG was found.** Every one of the 38 review-1 failures, and every one of the 21 that
remain, is a spec-scoping or spec-writing defect, a documented spec-vs-code divergence, or a
deliberate over-approximation in a summary. Four latent-risk observations are recorded at the end;
none of them is reachable on a live chain, and none is a violation of a stated property.

## The four mechanisms behind almost every review-1 failure

Four root causes, each confirmed from a call trace, explain 36 of the 38:

1. **Parametric rules ranged over the whole scene.** `FamilyHook`, `FeeVault` and `RoundManager` are
   all compiled into every job and linked to each other, so `method f` enumerated all three
   contracts' entrypoints. A rule like `historyEntriesAreImmutable` was being asked to hold across
   `FeeVault.cancelDeveloperTransfer()`. Fixed by `f.contract == currentContract` on every
   parametric rule and invariant, as `DevVesting.spec` already had after review-1.
   *(FeeVault 6 rules, RoundManager 11, FamilyHook 2.)*

2. **`HAVOC_ALL` and `AUTO` summaries wipe non-persistent ghosts.** The call traces say it in as many
   words: `[AllGhostsHavocInstance] All non-persistent ghosts were havoc'd`, inside
   `FeeVault.forwardProtocolFee` and `FeeVault.flushForward`, i.e. at the summarized successor vault.
   Every ghost-delta rule in `FeeVault.spec` was therefore comparing two unrelated numbers —
   `accrueConservesTheFee`'s counterexample opens with `ghostDev = -2201`, `ghostPendingSum = -2500`.
   Fixed by declaring every mirror `persistent ghost`. The hooks still fire on exactly this
   contract's own stores, so no rule's meaning changes.

3. **Immutables are havoc'd; constructor guards are not free.** `hopFeePpm`, `DURATION_SCALE_DIV`,
   `BOND_*` and `MAX_INDEX` are immutables. The Prover starts a parametric rule from arbitrary
   storage with the constructor never run, so they take arbitrary values. `feeRatesAreImmutable`
   failed on **all 38** methods — including pure `RoundManager` calls, which is the tell — because
   `hopFeePpm() <= MAX_HOP_FEE_PPM()` is only established by the constructor's `HopFeeTooHigh` guard.
   `scheduleBounds` failed on a literal **division by zero** (`assertNot DURATION_SCALE_DIV() == 0`)
   and `trueEndFallsInsideTheWindow` on a zero-length window from the same cause. Fixed by
   restating each constructor guard as a well-formedness `definition`, which excludes exactly the
   states the deployed contract cannot be in.

4. **`NONDET` on a *view* read is not an over-approximation — it is false.** A NONDET summary
   re-randomises on every call, so two reads of the same getter in the same state disagree. That is
   not something an external contract can do, and it is what violated:
   - `finalizeIsIdempotent` — `head()` delegates to `priorRegistry.headToken()` while `!adopted`;
     the two reads either side of the second `finalize` returned different addresses.
   - `reverseIndexIsConsistent`, *transient-storage step* — `canonical(i)` walks the prior-registry
     chain; the trace shows the two calls either side of "reset transient storage" resolving
     `priorRegistry()` NONDET and `canonical(uint256)` AUTO to different answers, across a step that
     changes nothing at all.
   - `solvency`, *transient-storage step* — `holdings(c)` = balance + unredeemed ERC-6909 claims, and
     the claim term is `poolManager.balanceOf` (`sighash 0xfdd58e`), summarized NONDET.
   - `requestEndIsOnceAndNotBeforeT` — `randomness.pin()` NONDET returned `bytes32(0)` on the first
     call, and `requestEnd` arms its once-only guard with `r.randomId != bytes32(0)`, so the second
     request sailed through.
   - `bucketNeverExceedsCap` on `accrue` — `drawableEth` reads `headIndex()` through the RoundManager
     twice inside one bucket evaluation.

   Fixed by backing each such read with a `persistent ghost` through a CVL function summary: the
   value stays completely unconstrained, it just stops changing between two reads of the same state.

## FeeVault — per-rule

Job: `23c8f4ac…` (review-1b). 29 sub-goals, 7 non-SUCCESS (was 13).

| Rule / sub-goal | review-1 | review-1b | classification and evidence |
|---|---|---|---|
| `envfreeFuncsStaticCheck` | SUCCESS | SUCCESS | |
| `solvency` — base | SUCCESS | SUCCESS | |
| `solvency` — transient reset | FAIL | **FAIL** | **Spec-scoping (mechanism 4).** Trace: two `FeeVault.holdings()` calls either side of `reset transient storage allContracts`, each resolving `sighash 0xfdd58e` (`poolManager.balanceOf`) to a fresh NONDET. The step itself writes nothing. Fixed in the spec after this run (`_.balanceOf` → consistent ghost); **not yet re-run**. |
| `solvency` — 20 methods | FAIL (38) | **FAIL (20)** | Same cause, plus mechanism 5 below (`HAVOC_ALL`). The 18 non-FeeVault methods are gone (mechanism 1). |
| `ethLedgerDecomposition` — base / transient | SUCCESS | SUCCESS | |
| `ethLedgerDecomposition` — `accrue`, `consumeReinforcement` | FAIL (9) | **FAIL (2)** | **Spec-writing error, now diagnosed exactly.** This file's own FEE-10 header enumerates `reinforcementBalance[parent]` as a ledger, but no hook tracked it and the ghost sum omitted it. Trace: `consumeReinforcement` stores `reinforcementBalance[0x0]: 807 → 806` **and** `ledgerTotal[0]: MAX → MAX-1`, so the left side of the decomposition fell and the right side, missing the term, did not. A `reinforcementBalance[address(0)]` mirror has been added; **not yet re-run**. |
| `accrueConservesTheFee` | FAIL | **SUCCESS** | was mechanism 2 |
| `accrueMovesLedgerTotalByTheFee` | FAIL | **SUCCESS** | was mechanism 2 |
| `onlyAccrualPathsCredit` | FAIL (8) | **SUCCESS** | was mechanisms 1 + 2 |
| `creatorTransferIsALedgerMove` | SUCCESS | SUCCESS | |
| `drawNeverExceedsTheBucket` | SUCCESS | SUCCESS | |
| `bucketNeverExceedsCap` — base / transient | SUCCESS | SUCCESS | |
| `bucketNeverExceedsCap` — 6 methods | FAIL (11) | **FAIL (6)** | **Spec-scoping (mechanisms 4 + 5).** Trace on `accrue` shows two `headIndex(): NONDET` resolutions inside one bucket evaluation; the other five methods are the `HAVOC_ALL` successor calls. Both fixes are in the spec, **not yet re-run**. |
| `twoDrawsCannotDoubleUp` | FAIL | **SUCCESS** | **Was spec-scoping — and it surfaced a latent-risk observation, kept on the record below.** Counterexample: `e.block.timestamp = 2^64`, `drawdowns[j].updatedAt = MAX_UINT64`, `a = 0`, `b = 3114 > allowed = 3113`. `consumeAncestorClaim` stores `d.updatedAt = uint64(block.timestamp)`, which truncates 2^64 to **0** — and `_bucket` reads `updatedAt == 0` as "untouched generation, full bucket". The second draw in the same block therefore saw a refilled bucket. Neither timestamp 0 nor 2^64 is reachable on a live chain, so a `wellFormedTime(e)` definition (`0 < block.timestamp < 2^64`) now states that, and the rule passes. |
| `payKeeperIsBoundedByDeployerCredit` | SUCCESS | SUCCESS | |
| `deployerCreditSettles` — base / transient | SUCCESS | SUCCESS | |
| `deployerCreditSettles` — `accrue`, `flushForward`, `forwardProtocolFee` | FAIL (8) | **FAIL (3)** | **Mechanism 5.** Exactly the three methods that call the successor vault. |
| `valueLeavesOnlyOnPayoutMethods` | FAIL (10) | **FAIL (4)** | **Two different causes, split.** `consumeReinforcement` / `consumeGenesisEarmark`: **spec-writing error** — the trace shows `consumeReinforcement` paying 1 wei to the BidDeployer, which is a *declared* path in spec J's keeper model (`onlyBidDeployer`, and that leash is proved by `onlyBidDeployerHooks`, which passes); the drafted `isPayoutMethod` list simply omitted the consumption hooks. Now listed; **not yet re-run**. `accrue` / `forwardProtocolFee`: **mechanism 5** — neither moves native ETH (the handover transfers an ERC-6909 *claim*), they are flagged only because `HAVOC_ALL` havocs balances. Deliberately **not** added to the list, so a future real exit on the accrual path cannot hide behind them. |
| `onlyBidDeployerHooks` | SUCCESS | SUCCESS | |
| `pendingForwardTotalIsTheSum` — base / transient | SUCCESS | SUCCESS | |
| `pendingForwardTotalIsTheSum` — 3 methods | FAIL (9) | **FAIL (3)** | **Mechanism 5**, the three successor callers. |
| `flushForwardConserves` | FAIL | **SUCCESS** | **Was mechanism 5 in its purest form.** The trace shows the contract behaving perfectly — `pendingForward[0]: 4934 → 1922`, `ledgerTotal[0]: 3504 → 492`, `moved = 3012`, both deltas exact — and then `receiveForward(uint256): HAVOC_ALL summary` wiping storage, so the rule's *re-read* of `pendingForward` came back as a near-max uint. The post-conditions now read the write-log mirrors instead of re-reading storage, which pins the store rather than the re-read and is strictly stronger. |
| `postSunsetFeesAreNeverBookedLocally` | FAIL | **SUCCESS** | was mechanism 2 |
| `ratesAndSplitsAreImmutable` | SUCCESS | SUCCESS | |
| `claimZeroesBeforePaying` | SUCCESS | SUCCESS | |

### Mechanism 5 — `HAVOC_ALL` on the successor vault

All seven remaining FeeVault failures involve one of `accrue`, `accrueForwarded`, `receiveForward`,
`flushForward`, `forwardProtocolFee` or `consumeAncestorClaim`. `FeeVault.spec` summarizes the
successor's `accrueForwarded` and `receiveForward` as `HAVOC_ALL`, on the stated grounds that a
successor is unknown third-party code. That is sound for *external* state — but `HAVOC_ALL` also lets
the callee rewrite **this vault's own storage**, which no contract can do, and under that
over-approximation no storage-reading invariant can ever be inductive.

This is a spec-scoping defect, not a code finding, and the fix is `HAVOC_ECF` — with one caveat that
has to be resolved first, because it is a real question about the code:

> **`FeeVault.accrue` is not `nonReentrant`**, and on the post-sunset path it hands control to an
> unknown successor contract (`accrue` → `this.forwardProtocolFee` → `IFeeVault(v).accrueForwarded`)
> at a point where `reinforcementBalance[parentToken]` has already been credited and
> `ledgerTotal[currency]` has **not** yet been. `flushForward` and every `claim*` are `nonReentrant`,
> but that lock is not held during `accrue`.
>
> No loss was constructed: the window leaves `ledgerTotal` *understated*, which satisfies the
> solvency bound more easily, not less; the claims pay only out of their own ledgers; the
> consumption hooks are `onlyBidDeployer`; and a reentrant `flushForward` would have to `redeem`
> through `poolManager.unlock` from inside the hook's own unlock and would revert — into the
> `try/catch` that already wraps the hop. It is recorded as a **latent risk**, and it is the reason
> `HAVOC_ECF` is not applied blind in this pass.

## RoundManager — per-rule

Job: `cba72e35…` (review-1b). 30 sub-goals, 10 non-SUCCESS (was 17).

| Rule / sub-goal | review-1 | review-1b | classification and evidence |
|---|---|---|---|
| `envfreeFuncsStaticCheck` | SUCCESS | SUCCESS | |
| `canonicalIsWriteOnce` — base / transient | SUCCESS | SUCCESS | |
| `canonicalIsWriteOnce` — `finalize` | FAIL (14) | **FAIL (1)** | **Spec-scoping: the invariant is true but NOT INDUCTIVE.** The counterexample's pre-state is `_headIndex = 7967` with `_canonical[7968]` *already occupied* and `ghostCanonicalWrites[7968] = 1`. That state is unreachable: the only two writers are `registerGenesis` (`_canonical[0]`) and the winner branch of `finalize`, which writes `_canonical[_headIndex + 1]` and sets `_headIndex = _headIndex + 1` eight lines later (RoundManager.sol:1115-1123). Strengthened with the conjunct `i > headIndex() => ghostCanonicalWrites[i] == 0`; **not yet re-run**. |
| `onlyFinalizeOrAdoptionWritesHistory` | FAIL (13) | **SUCCESS** | was mechanism 1 |
| `historyEntriesAreImmutable` | FAIL (38) | **FAIL (15)** | **Spec-scoping (mechanism 4), residual.** `canonical(i)`, `parentOf`, `creatorOf` all delegate to the prior registry while `!adopted`, and `_.canonical`, `_.indexOf`, `_.parentOf`, `_.creatorOf` were still falling through to the Prover's per-call AUTO havoc — only `_.headToken`, `_.priorRegistry`, `_.adopted`, `_.successor`, `_.isSunsetEffective` were pinned in this pass. The remaining seven are pinned in the spec now; **not yet re-run**. |
| `historyLengthIsMonotone` | FAIL (13) | **SUCCESS** | was mechanism 1 |
| `reverseIndexIsConsistent` — transient reset, and 15 methods | FAIL | **FAIL** | Same residual as above; the transient-reset trace is the clearest single piece of evidence for mechanism 4 (two `canonical(i)` calls, one step that changes nothing, two different answers). |
| `pairingRightsAreWriteOnce` | FAIL (35) | **FAIL (12)** | Same residual. Note `finalize` and `openRoundIfIdle` — the two methods the rule is *about* — now both pass. |
| `headIndexOnlyGrows` | FAIL (37) | **FAIL (14)** | Same residual: `headIndex()` itself delegates, and `_.headIndex()` had no summary at all. The `maxIndexIsRespected` trace shows it plainly: `headIndex(): AUTO summary @ [internally generated]`. |
| `finalizeIsIdempotent` | FAIL | **FAIL** | Same residual (`head()` → `headToken()`/`headIndex()`). |
| `noNewRoundBeforeFinalize` | SUCCESS | SUCCESS | |
| `thresholdMovesOnlyInFinalize` | FAIL (13) | **SUCCESS** | was mechanism 1 |
| `winnersBondIsReturned` | SUCCESS | SUCCESS | |
| `losersBondsAreForfeited` | SUCCESS | SUCCESS | |
| `requestEndIsOnceAndNotBeforeT` | FAIL | **SUCCESS** | **Was spec-scoping (mechanism 4) — and it surfaced a latent-risk observation.** `pin()` NONDET returned `bytes32(0)`; `requestEnd`'s once-only guard is `r.randomId != bytes32(0)`. The summary now returns an arbitrary but non-zero, stable id, which is what `DrandSource.pin()` (`id = bytes32(round)`) actually produces. |
| `trueEndFallsInsideTheWindow` | FAIL | **SUCCESS** | was mechanism 3 |
| `timeoutFallbackSettlesAtT` | SUCCESS | SUCCESS | documentary assertion, see PROPERTY_MAP note 5 |
| `endIsSettledAtMostOnce` | SUCCESS | SUCCESS | |
| `scheduleIsPureInN` | SUCCESS | SUCCESS | |
| `scheduleBounds` | FAIL | **SUCCESS** | **Was mechanism 3, and specifically a division by zero**: `[DivZeroInstance] assertNot RoundManager.DURATION_SCALE_DIV() == 0`. The constructor rejects `durationScaleDiv == 0` and anything above `MIN_REGISTRATION_S` (`BadDurationScale`); restating that is what fixed it. |
| `lateEntryClosesBeforeTheClosingWindow` | SUCCESS | SUCCESS | |
| `bondSaturates` | SUCCESS | SUCCESS | |
| `bondIsMonotoneInDepth` | TIMEOUT | **TIMEOUT** | **Tractability, not a claim about the code.** `bondFor` is `BOND_BASE_WEI << (i / BOND_DOUBLING_EVERY)` with a symbolic base, a symbolic divisor and a symbolic shift amount, plus an overflow round trip (`scaled >> doublings != BOND_BASE_WEI`). A symbolic-on-symbolic shift is the worst case for a bit-vector solver. `BOND_DOUBLING_EVERY() != 0` and a depth bound were added this pass and did not help; **what would make it tractable is pinning `BOND_DOUBLING_EVERY` to its deploy constant**, which turns the shift amount into a concrete function of `i`, and/or raising `--smt_timeout`. Unbounded-depth monotonicity stays with the fuzz tier. |
| `maxIndexIsRespected` | FAIL | **FAIL** | **Two spec-writing errors, one fixed, one residual.** Fixed this pass: the rule asserted `lastReverted` for a method that, by name and by design, returns *without* reverting when a round is already open — the review-1 trace took exactly that branch (round 10001 open, `lateEntryEnd = 1`, no revert, nothing opened); it now requires `isIdle()` and asserts `lastReverted || roundCount() unchanged`. Residual: `require headIndex() + 1 > MAX_INDEX()` and the contract's own `_headIndex + 1` read disagree because `headIndex()` delegates through an AUTO-summarized `_.headIndex()` (mechanism 4). Pinned in the spec now; **not yet re-run**. |
| `noTransitionIsPrivileged` | FAIL (31) + TIMEOUT (2) | **FAIL (9)** + TIMEOUT (2) | **Spec-writing error, diagnosed exactly.** The rule ran the second caller on the state the FIRST call had already mutated. Trace for `requestEnd`: call 1 stores `rounds[5609].randomId`, call 2 then reverts `EndAlreadyRequested`. That says nothing about privilege. Both callers now start from the same storage (`storage init = lastStorage; f@withrevert(…) at init`), and the filter now also excludes the entrypoints the spec itself declares role-gated (the steward-transfer trio, ROL-02, and the factory-only `registerGenesis`) — those are not transitions of the round machine. **Not yet re-run.** `rank` / `submitScore` TIMEOUT on top of that. |
| `sunsetTouchesNothingElse` | SUCCESS | SUCCESS | |
| `adoptionHappensAtMostOnce` | FAIL (13) | **SUCCESS** | was mechanism 1 |

## FamilyHook — per-rule

Job: `cdeafe7f…` (review-1b). 15 sub-goals, 4 non-SUCCESS (was 8).

| Rule / sub-goal | review-1 | review-1b | classification and evidence |
|---|---|---|---|
| `envfreeFuncsStaticCheck` | FAIL (`trailingAverage`) | **SUCCESS** | **Spec-writing error.** `trailingAverage` walks the coarse ring back from `block.timestamp`, so it cannot be `envfree`. Declaration corrected. |
| `scoreIsMonotoneInNetParentAbsorbed` | SUCCESS | SUCCESS | |
| `onlyTheSwapPathMovesTheScore` | FAIL (14) | **SUCCESS** | was mechanism 1 |
| `donationsAreImpossible` | SUCCESS | SUCCESS | |
| `liquidityIsARatchet` | SUCCESS | SUCCESS | |
| `averageOverIsTheAccumulatorDifference` | SUCCESS | SUCCESS | |
| `averageOverHandlesTheDegenerateWindow` | FAIL | **FAIL — kept** | **Spec-vs-code divergence, deliberately not fixed.** PROPERTIES §7 item 12 asks what `averageOver` does with `t1 == t0`; the spec's most plausible reading is "return the instantaneous level", and the code reverts `BadScoreWindow` (`FamilyHook.sol:661`, `if (tEnd <= start) revert BadScoreWindow();`) — which is exactly what `docs/security/PROPERTY_RESULTS.md` §2 gap 12 already records. The rule keeps the spec's reading and stays violated, as instructed. To adopt the code's reading, flip the assertion to `lastReverted`. |
| `aSlotIsWrittenOnceByItsFirstSwap` | FAIL | **FAIL** | **Was coverage theatre; now a real rule that needs one more precondition.** In review-1 it asserted over `ghostSlotWrites`, a ghost **nothing ever wrote** — so it proved nothing and happened to fail. It now reads the ring through `scoreCheckpoint()` either side of a swap. The remaining counterexample starts from an *inconsistent* ring: slot index 1 holding `tSwap = 10`, which at `SCORE_SLOT_S = 5` belongs to span 2, not span 1. A swap at t = 9 then legitimately claims that slot for span 1 — a lower `tSwap`, but not an overwrite of anything `_checkpoint` put there. The slot's own reachable invariant (`tSwap / SCORE_SLOT_S % SCORE_SLOTS == index`) has been added as a `require`; **not yet re-run**. *(An `Sstore` hook on the ring was tried first and does not type-check — see the note at the end.)* |
| `theFastRingSpansTheRandomEndWindow` | SUCCESS | SUCCESS | |
| `snipeTaxBounds` | SUCCESS | SUCCESS | |
| `summedRatesStayBelowOne` | FAIL | **SUCCESS** | **Spec-vs-code divergence in the *specification*, corrected — and PROPERTIES §7 item 14 has its arithmetic wrong.** The drafted rule summed all three parent-side rates unconditionally under the guard `hopFeePpm < MAX_HOP_FEE_PPM`; that guard could never have made it pass, because `SNIPE_START_PPM + PROTOCOL_FEE_PPM = 990_000 + 10_000` is **already** 1_000_000 at `hopFeePpm == 0`. And §7.14's "100.075% at the ceiling" is arithmetically wrong: `990_000 + 10_000 + 10_000 = 1_010_000`, i.e. 101%. Neither figure describes the code, because **the three rates are never summed on a real pool**: `_collect` takes `protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0` while `snipePpm = _snipeTaxPpm(p.tradingStart)` is 0 whenever `tradingStart == 0`, and the genesis pool is registered with `tradingStart = 0` (`FamilyFactory.sol:300`). The protocol fee and the snipe tax are **mutually exclusive per pool**. The rule now states the real worst case — `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000` — which is the claim that keeps the exact-output gross-up finite, and it verifies. This reconciles with `PROPERTY_RESULTS.md` gap 14, whose *measured* number (`990_000 + 10_000 = 1_000_000` on a candidate pool, reverting `SnipeExactOutputTooLarge`) was right all along. |
| `feeRatesAreImmutable` | FAIL (38) | **SUCCESS** | was mechanisms 1 + 3 |
| `protocolFeeOnlyOnTheGenesisPool` | FAIL | **SUCCESS — but see the next row** | **Was a spec-writing error, twice over.** The drafted rule read `poolInfo(id)` for an `id` declared *unconstrained* and having nothing to do with the `key` that was swapped, and compared it against `ghostProtocolFeeCount`, which **nothing incremented**. The fee is never stored, so the only observable is the vault call: `_collect` passes `p.isGenesis ? address(0) : Currency.unwrap(parent)` as the vault's `parentToken`, so that word *is* the genesis-pool flag of the pool the fee was charged on. The `_.accrue` summary now records it and the rule states FEE-01 over the accrual that actually happened. |
| `oneProtocolFeeAtTheEthEdgeIsReachable` (`satisfy`) | SUCCESS | **FAIL** | **The one verdict that got *worse*, and it is the honest one.** In review-1 this "passed" only because a havoc could move an unfed counter. With the counter properly fed, the Prover **cannot construct a single execution of `beforeSwap` that charges one protocol fee** — so the row above is **vacuous coverage and FEE-01's per-pool half is still UNPROVED**. This is precisely the job this `satisfy` exists to do. Next things to try, in order: link `feeVault` in `FamilyHook.conf` so the accrual resolves to a real callee instead of a wildcard; relax `== before + 1` to `> before` to separate "no fee at all" from "not exactly one"; and check whether the `PoolManager.getSlot0` / `swap` NONDET summaries make `_collect`'s parent-side branch unreachable. |
| `genesisIsNeverSniped` | FAIL | **FAIL — kept** | **Spec-vs-code divergence, kept as the spec reads it, and a real defence-in-depth gap.** `registerPool` does **not** enforce `isGenesis => tradingStart == 0`; it stores whatever it is handed, checking only `msg.sender == factory`. The invariant is established one layer up: `FamilyFactory.createGenesis` is the only caller that ever passes `isGenesis = true` and it always passes `tradingStart = 0` (`FamilyFactory.sol:300`), while `createCandidate` always passes `isGenesis = false` (`:388`). So FEE-04 holds in the deployed system, by the factory's discipline rather than by the hook's. The rule is left **failing** rather than quietly requiring that discipline. See the finding below. |

## Findings

No GENUINE BUG. Four latent-risk observations, all **status: open**, none reachable on a live chain
as deployed, all recorded so that they are deliberate choices rather than accidents.

**F-1 (low, defence in depth) — `FamilyHook.registerPool` does not enforce
`isGenesis => tradingStart == 0`.** The whole snipe-tax/protocol-fee mutual exclusion that keeps the
summed parent-side rate at or below 100% rests on it. Today `FamilyFactory` is the only caller and
always passes `tradingStart = 0` for genesis, so nothing is wrong. If a genesis pool were ever
registered with a non-zero `tradingStart`, that pool would carry **both** the 1% protocol fee and the
99% snipe tax, `_collect` would compute `totalPpm >= PPM_DENOM` and every parent-paying exact-output
swap in its first three seconds would revert `SnipeExactOutputTooLarge`. Suggested fix: one line in
`registerPool` — `if (isGenesis && tradingStart != 0) revert …;`. That also turns
`genesisIsNeverSniped` into a passing invariant with no spec change.

**F-2 (low) — sentinel collision in the drawdown bucket.** `Drawdown.updatedAt == 0` means "untouched
generation, full bucket" (`FeeVault.sol:804`), and the same field is written with
`uint64(block.timestamp)` (`:842`). The two meanings collide at any timestamp congruent to 0 mod
2^64. Found as `twoDrawsCannotDoubleUp`'s counterexample: two draws in one block totalling more than
one bucket. Not reachable (a live `block.timestamp` is neither 0 nor 2^64), so it is excluded by a
well-formedness `require` rather than by weakening the rule. Suggested fix, if it is ever cheap: a
separate `bool initialised` flag, or store `updatedAt + 1`.

**F-3 (low) — sentinel collision in the end-request guard.** `requestEnd`'s once-per-round guard is
`r.randomId != bytes32(0)` and the id it stores is whatever `randomness.pin()` returns. A zero id
would silently disarm the guard. `DrandSource.pin()` returns `bytes32(round)`, so this needs beacon
round 0 and is not reachable — but it is the same shape as F-2 and it is next to an already-recorded
divergence (`PROPERTY_RESULTS.md` gap 11 / RAN-04: nothing prevents the *same* beacon round settling
two RoundManager rounds). Suggested fix: `if (randomId == bytes32(0)) revert BadBeaconId();`.

**F-4 (low) — `FeeVault.accrue` hands control to an unknown successor with no reentrancy lock held.**
See the mechanism-5 box above for the full window and why no loss could be constructed. Suggested
fix: mark `accrue` `nonReentrant`, or move the `ledgerTotal[currency] +=` above the forwarding hop so
the ledger is never understated while foreign code runs. Either one would also let `FeeVault.spec`
narrow the successor summary from `HAVOC_ALL` to `HAVOC_ECF`, which is what currently blocks seven
FeeVault sub-goals.

## Divergences, cross-referenced

| Divergence | Where it shows up | Reference |
|---|---|---|
| `averageOver` with `t1 == t0` reverts `BadScoreWindow` | `averageOverHandlesTheDegenerateWindow` — FAIL, kept | PROPERTIES §7.12; `PROPERTY_RESULTS.md` §2 gap 12 |
| The protocol-fee predicate is the `isGenesis` pool flag, not the currency | `protocolFeeOnlyOnTheGenesisPool` — now stated over the vault's `parentToken`, which is that flag | PROPERTIES §7.8; `PROPERTY_RESULTS.md` §2 gap 8 |
| `hopFeePpm` at its ceiling | `summedRatesStayBelowOne` — **§7.14's arithmetic is wrong** (101%, not 100.075%) and the three rates are never summed on one pool | PROPERTIES §7.14; `PROPERTY_RESULTS.md` §2 gap 14 |
| `W` is computed from the **scaled** duration; `randomEndWindowFor` has no `max(1, …)` | `scheduleBounds` — verified under the constructor's `DURATION_SCALE_DIV` bound | PROPERTIES §7.7; `PROPERTY_RESULTS.md` §2 gap 7 |
| `requestEnd` timing / beacon reuse | `requestEndIsOnceAndNotBeforeT` — the once-per-round half verifies; reuse across rounds is RAN-04 and is not expressible here | PROPERTIES §7.11; `PROPERTY_RESULTS.md` §2 gap 11 |
| `finalize` idempotence | `finalizeIsIdempotent` — still blocked by the prior-registry summary, not by the code; `Round.t.sol::test_staleFinalizeIsIdempotent` passes at the unit tier | `PROPERTY_RESULTS.md` RND-07 |
| `MAX_INDEX` is checked only on the branch that opens a round | `maxIndexIsRespected` — rule corrected to the idle case | RoundManager.sol:888-895 |

## Spec and conf changes in this pass

Applied **and re-run** (the review-1b jobs above):

1. All three specs — every parametric rule and invariant filtered with `f.contract == currentContract`.
2. All three specs — every mirror ghost declared `persistent`.
3. `FeeVault.spec` — `wellFormedTime(env)`; `flushForwardConserves` reads the write-log mirrors;
   per-attribution `ghostPending` mirror.
4. `RoundManager.spec` — `wellFormedSchedule()`; consistent-read ghost summaries for `pin()`,
   `headToken`, `priorRegistry`, `adopted`, `successor`, `isSunsetEffective`; `maxIndexIsRespected`
   requires `isIdle()`; `bondIsMonotoneInDepth` bounded.
5. `FamilyHook.spec` — `trailingAverage` un-`envfree`d; `hopFeePpm <= MAX_HOP_FEE_PPM` restated;
   `summedRatesStayBelowOne` restated as the real worst case; `_.accrue` summarized to record the
   accrual so `ghostProtocolFeeCount` is actually fed; `aSlotIsWrittenOnceByItsFirstSwap` rewritten
   against the ring getter; `genesisIsNeverSniped` documented and left failing.

Applied **after** the review-1b run, from its findings, and **not yet re-run** — review-2 must
re-run all three before any of these is believed:

6. `FeeVault.spec` — consistent-read summaries for `_.balanceOf` (the ERC-6909 claim term of
   `holdings`) and for `_.headIndex` / `_.canonical` / `_.creatorOf` / `_.indexOf`; a
   `reinforcementBalance[address(0)]` mirror added to the FEE-10 decomposition; `consumeReinforcement`
   and `consumeGenesisEarmark` added to `isPayoutMethod` (and `accrue` / `forwardProtocolFee`
   deliberately not).
7. `RoundManager.spec` — consistent-read summaries for the remaining seven IPriorRegistry reads
   (`headIndex`, `priorIndex`, `canonical`, `indexOf`, `isCanonical`, `parentOf`, `creatorOf`);
   `canonicalIsWriteOnce` strengthened to an inductive form; `noTransitionIsPrivileged` runs both
   callers from the same storage and excludes the role-gated entrypoints.
8. `FamilyHook.spec` — ring well-formedness `require` on `aSlotIsWrittenOnceByItsFirstSwap`; the
   `oneProtocolFeeAtTheEthEdgeIsReachable` result written into the spec so the vacuity cannot be
   mistaken for coverage.

No rule was weakened to make it pass. Where a rule could only pass by weakening — `genesisIsNeverSniped`,
`averageOverHandlesTheDegenerateWindow` — it was left violated and recorded above.

## Environment notes added by this pass

- **No JDK 19+ on this machine** (only JDK 17 and a JRE 8), so `certoraRun` cannot type-check CVL
  locally and every run used `--disable_local_typechecking`. The cost showed up immediately: the
  first FamilyHook submission died on the server after five seconds with
  `Type mismatch: keys to FamilyHook.scoreRing should have type PoolId but id has type PoolId`.
  CVL resolves the nested ring's key to a `PoolId` identity that a hook declaration cannot name
  (`FamilyHook.PoolId` is a *different* identity to the prover), even though both come from
  `v4-core/src/types/PoolId.sol`. The rule was restated against the `scoreCheckpoint()` getter, which
  needs no hook. **Install a JDK 21 or run from Linux/WSL before review-2**; a five-second remote
  type-check failure is cheap in prover minutes but expensive in wall-clock.
- `certoraRun` must be on `PATH` from `~/.local/bin`; it is not there by default in this shell.
- Submitting without `--wait_for_results` and polling `jobData` afterwards avoids the 30/60-minute
  local client timeouts that truncated review-1 entirely.
- Job accounting for this pass: **three result-producing jobs**, one per spec. Two extra submissions
  were made and produced nothing — the CVL type-check failure above (5 s, no prover time) and one
  job that died in the queue before `startTime` with no output at all, most likely a concurrency
  limit with three jobs already in flight. Both are recorded in `private/certora/JOBS-review-1.md`.
