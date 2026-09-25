# Certora specifications

On Windows, run the Prover from inside WSL; see the JDK and CLI notes below.

Formal specifications for the Dollhouse protocol, written **from the specification**: the only
inputs were `docs/spec/PROTOCOL_SPEC.md`, `docs/spec/PROPERTIES.md`,
`docs/DEPLOY_CONSTANTS.md`, and the function signatures in `contracts/interfaces/` and
`contracts/*.sol`. No implementation body, test or script was consulted, so a rule the code violates
is a finding, not a documentation error to be reconciled away.

```
certora/
  specs/       FeeVault.spec  RoundManager.spec  Sleeve.spec  FamilyHook.spec
  conf/        one .conf per spec
  harness/     FenwickHarness.sol, which exposes the internal FenwickRangeAdd library and nothing else
  PROPERTY_MAP.md
```

`DevVesting.spec` and its conf are GONE, with the contract they verified (REVIEW5_DESIGN decision 9).
There is no vesting in this protocol: founders buy at the launch and the artist share is off-chain.


## Running

From a **clean clone** (the Prover compiles the whole tree; a dirty `out/` or `crytic-export/` can
shadow sources):

```sh
git clone <repo> dollhouse && cd dollhouse
forge install                      # submodules only; the Prover needs the remappings resolvable
export CERTORAKEY=...              # the Prover reads the key from the environment, never from a file
certoraRun certora/conf/FeeVault.conf
certoraRun certora/conf/RoundManager.conf
certoraRun certora/conf/FamilyHook.conf
certoraRun certora/conf/Sleeve.conf
```

**THE REVIEW-5 SPECS HAVE RUN, EXCEPT `FeeVault`.** Eight jobs were submitted on 2026-09-15. The
first four all failed at scene load with the same internal Prover error before any rule was checked
(`RESULTS-review-5.md`, finding P-1). Two then ran to completion, after `contracts/FeeVault.sol` was
taken out of the `FamilyHook` and `RoundManager` scenes, which is what gets a job past P-1:
**RoundManager 31 of 36 rules verified, FamilyHook 17 of the 21 that ran.** The last two, review 5f,
spent a submission each on the two workarounds the support report proposes, and **both were refused
by P-1 exactly as before**: a ghost-backed CVL summary of the edge token with the link and `MockDoll`
out of the scene (S-14, and the crash did not move by a single block id, so the resolved callee is
not the cause), and a restructure of `contracts/FeeVault.sol` into a shape with no two external-call
return buffers in one expression (S-15, measured and then REVERTED, because a change made for a
tool's benefit that did not benefit the tool is not worth carrying). `FeeVault.conf` is unchanged and
still blocked; it has no verdicts at all and the four commands above will reproduce the refusal on
`certora-cli 8.19.2` rather than produce one.

**REVIEW 6 SPENT TWO MORE SUBMISSIONS AND THE VAULT IS STILL BLOCKED.** It worked through the three
remaining documented, verification-only levers, in order, and all three are refused: the Prover's own
`-relaxedPointerSemantics FeeVault:receiveForward`, which names exactly the analysis that crashes and
exactly the method it crashes on, died at the IDENTICAL crashing block id (**S-17**); a
verification-only compilation change died at a DIFFERENT block id, which proves the different build
really was analysed and the crash still did not move (**S-18**); and an internal CVL summary of
`holdings`, the one thing that would take the two external balance reads off `receiveForward`'s path
without editing the contract, CANNOT BE WRITTEN, because `holdings` is `public` and the Prover's
internal-function finders only cover `internal` and `private` functions (**S-19**, refused by the
local type-checker at no cost in prover minutes). **FeeVault: 0 of 30 rules verified, and no rule has
ever been checked.** `FeeVault.conf` carries an inline note naming all three so they are not retried.
**Do not re-run any of the five ruled-out workarounds**; every one is recorded with its job id in
`private/certora/JOBS-review-5.md`.

**`FamilyHook.conf` and `RoundManager.conf` no longer compile `FeeVault.sol`.** Both dropped it from
`files` along with the `feeVault` link, and both confs carry an inline note saying why and what to
restore when the Prover is fixed. No rule lost its meaning: `RoundManager.spec` already summarized
the vault's one entrypoint NONDET and needed no edit at all, and `FamilyHook.spec` kept its
`_.accrue(...)` wildcard and lost only review-4's exact `FeeVault.accrue` entry, which cannot name a
contract outside the scene. Two `FamilyHook` rules ARE disabled, for an unrelated reason: see S-10.

**`loop_iter` must be at least the real depth of whatever the spec walks.** Under `optimistic_loop`
the Prover *assumes* the loop has exited after the unrolled iterations; if the bound is too low that
assumption is unsatisfiable on exactly the interesting paths, and rules come back "not violated"
**vacuously** rather than incompletely. `Sleeve.conf` spent two review cycles at `loop_iter: 12`
against a Fenwick walk that takes thirteen steps (`1, 2, 4, ... 4096` while `i <= 4097`); that, and
not the `2^128` literal review-1 suspected, is what made SLV-03 vacuous. Read a `rule_sanity` failure
as "the loop bound is wrong" first.

Each conf sets `solc: solc0.8.26`, `optimistic_loop: true` with a per-spec `loop_iter`,
`rule_sanity: basic`, a `msg`, and a `packages` array mirroring `foundry.toml`'s remappings.
`foundry.toml` compiles with `via_ir`, so every conf sets `solc_via_ir: true` alongside
`solc_optimize: "200"` and `solc_evm_version: "cancun"`, the same three settings foundry builds
with.

`CERTORAKEY` comes from the **environment**, never from a file and never from a conf. Export it in
the shell that runs `certoraRun` (e.g. from a git-ignored `.env`) and do not echo it.

The `<TODO link>` placeholders are gone. The links were derived from `script/Deploy.s.sol` and the
three constructors; each conf documents inline which immutables are linked and, for each one that is
not, why leaving it havoc'd is sound. The v4 `PoolManager` is deliberately **not** linked: the specs
summarize every one of its entrypoints NONDET, and an unconstrained address is strictly more general
than a pinned one.

Two non-obvious build settings, also documented inline in the three big confs:

- `disable_source_finders` / `disable_internal_function_instrumentation`, the Prover's autofinder
  instrumentation adds locals to already stack-heavy functions and breaks the via-IR build. The
  finders only matter for observing or summarizing *internal* functions; every summary in these
  specs is an external `_.` wildcard.
- `yul_optimizer_steps`: the Prover replaces solc's Yul optimiser sequence with one that drops the
  full inliner, and without it `FeeVault`, `RoundManager` and `FamilyHook` fail to compile with
  "stack too deep". The confs pass solc's own default sequence back. The space inside `gv i f` is
  load-bearing: the Prover rewrites the literal substring `gvif` to `gvf` even in a user-supplied
  sequence, and solc's step parser ignores whitespace.

`certoraRun` never overwrites its own scratch trees, so an edited spec is silently type-checked from
a stale copy. Between runs, delete `.certora_sources`, `.certora_config`, `.certora_internal` and
`.certora_*.json`.

Local CVL type-checking needs **JDK 19+** (21 recommended); on an older JVM the CLI refuses to
type-check and aborts the run.

The Prover is supported on Linux and macOS. On Windows, `certora-cli` 8.19.2 does not run
unmodified: several path-handling defects have to be worked around. Prefer WSL or a Linux runner.

Results are in `RESULTS-review-5.md` (current: FamilyHook and RoundManager verdicts filled in from
the review-5b jobs, every FeeVault cell still reading "blocked, P-1"), with the vault's prior
standing verdicts carried in `RESULTS-review-4.md`; per-rule status is in `PROPERTY_MAP.md`.

## Summarization choices, and why

| Summarized | How | Why |
|---|---|---|
| `PoolManager.swap` / `modifyLiquidity` / `initialize` / `unlock` / `sync` / `settle` / `take` / `mint` / `burn` / `getSlot0` | `NONDET` | The v4 singleton is external, unmodified third-party code. `PROPERTIES.md` §6 requires it summarized. Every rule here is a ledger, history or schedule claim; none of them may be true *because* the manager behaved in a particular way. |
| `PoolManager.protocolFeesAccrued` | `NONDET` | The v4 protocol-fee controller is an address the protocol does not control (`PROTOCOL_SPEC` §F). The score's subtraction must hold for any value it returns. |
| BN254 pairing precompile `0x08` | `NONDET bool` | Signature verification is not provable in Certora; it is a unit- and fork-tier property (RAN-01/02). |
| `IRandomnessSource.pin` / `fulfil` | `NONDET` word | The "strictly future beacon round" claim belongs to the source, not to `RoundManager`. What is proved here is the once-per-round and settle-once discipline that surrounds it. |
| `SqrtPriceMath` / `LiquidityAmounts` | `NONDET` under range constraints | Curve math belongs to Halmos (`PROPERTIES.md` §6, explicit). |
| A **successor** `FeeVault` (`accrueForwarded`, `receiveForward`) | `HAVOC_ALL` | A successor is a later, unknown deployment. The specification's claim is exactly that nothing a hostile successor does can break this vault's solvency or its queue accounting, so it must be modelled as arbitrary code, not as a cooperative twin. |
| A **prior** `RoundManager` (delegated canonical reads) | `NONDET` | Same reason in the other direction: an earlier deployment is already on chain and outside this proof. |
| The **edge currency** (in `FeeVault.spec`) | **linked to a real ERC-20 and NOT summarized** | REVIEW 5. `EDGE` is an immutable, so it can be pinned, and every ledger in the vault is denominated in it. A linked, unmodified ERC-20 is consistent between reads by construction (which is all the review-2 `cvlTokenBalance` ghost ever bought) AND its balance actually MOVES on a transfer, which is what `valueLeavesOnlyOnPayoutMethods` needs in order to be a claim about value leaving rather than about a constant. `test/utils/MockDoll.sol` is the stand-in, and the launch implementation is the same shape: no hooks, no fee on transfer, no callbacks, not pausable, not upgradeable. The wildcard `_.balanceOf(address)` summary stays for the PARENT-denominated hop pots, whose currency is symbolic. |
| The **edge currency** (in `RoundManager.spec`) | `balanceOf` consistent-read ghost, `transfer` NONDET | It CANNOT be linked there: `edgeToken()` is `canonical(0)`, a storage read that may delegate to a prior registry, not an immutable. The cost is recorded rather than hidden: a recipient's balance does not move under this model, so RND-11's "the bond reached the creator" half is stated over the escrow and the pull fallback instead. |

The `FamilyHook` and `FeeVault` specs summarize *each other's* subject matter to NONDET, so no rule
in either is proved true only because the other behaved well. That split is deliberate: it keeps each
spec's claim self-contained at the cost of two weakened cross-contract rules, both flagged in
`PROPERTY_MAP.md`.

## What these specs do NOT cover

Certora is the wrong tier for anything that needs a real `PoolManager`, real curve arithmetic, or a
long history of swaps. The following stay with fuzz, stateful-invariant and fork testing:

- **Per-route fee counting (FEE-01, ROU-02).** With `PoolManager.swap` summarized, the prover never
  executes legs 2..L of a route. "Exactly one protocol fee per traversal" is stated here only in its
  per-pool form, and REVIEW 5 restates that form: "charged only if the pool is an EDGE pool", i.e. a
  pool whose parent is canonical index 0. The route-level count is a fork test.
- **Curve and tick arithmetic (SUP-02/03, BID-01..04, BID-08..13, the whole of §E).** Snapping,
  gross-ups, liquidity-for-amount and TWAP consultation are Halmos and fork material.
- **Reentrancy against the v4 unlock flag (REN-01).** The transient lock lives in the singleton,
  which is summarized away; the flag is invisible to the Prover. REVIEW 5 splits this: the OTHER
  reentrancy guard, the plain `_locked` word review 5d put on `openRoundIfIdle` and `addCandidate`,
  is local to `RoundManager` and IS stated, as `guardedFactoryEntrypointsCannotBeReentered`.
- **Exact accumulator reconstruction across the checkpoint rings (SCR-04, SCR-05).** Replaying an
  arbitrary swap history through two rings exceeds a discharge-able loop bound.
- **The full-depth sleeve sum (SLV-03 for symbolic `M`).** CVL cannot quantify a sum over a symbolic
  range; the spec proves it out to `M <= 3` plus a depth-independent per-term bound.
- **Supply constancy of the token clones (SUP-01), and the stack-wide half of SUP-04.** Every family
  token is an EIP-1167 proxy with no bytecode of its own for the Prover to load. REVIEW 5 restates
  SUP-04 in two halves: the VAULT half (the vault's edge balance is its ledgers plus donations, and
  the donation is never sweepable) is here, as `solvency` plus `onlyAccrualPathsRaiseLedgerTotal`;
  "no protocol contract holds family-token supply" quantifies over the whole stack and stays with the
  stateful-invariant tier.
- **Liveness.** Nothing here proves anybody *will* call `submitScore`, `finalize`, `rank`,
  `flushForward` or a keeper entrypoint. `PROTOCOL_SPEC` §A states that dependency plainly, and it
  stays a disclosed property, not a verified one.

## Rule-to-property map

See `certora/PROPERTY_MAP.md` for the full table: every rule and invariant against its
`PROPERTIES.md` ID, plus the not-expressible list with reasons and the tier each one falls back to,
and the table of `docs/spec/PROPERTIES.md` §7 spec gaps whose most plausible reading these specs
encode (marked `// SPEC-GAP:` at each site).

## Review-2 checklist: DONE, and what review-3 inherits

All five specs ran against the contracts at tag `review-2`: **5 initial runs + 3 re-runs**. Per-rule
status is in `PROPERTY_MAP.md`. **No genuine contract bug was found**, and all four review-1b
findings (F-1..F-4) are confirmed closed by the Prover.

Review-2 closed these items from the old checklist:

1. **Re-run the three big specs** after the post-review-1b fixes, done. FeeVault 7 → 3 rules with
   failures (17 of 20 fully verified); RoundManager 10 → 6 (20 of 26 fully verified); FamilyHook
   re-run with two new rules.
2. **FEE-01**: still unproved, but no longer mysterious: a new rung-1 `satisfy`
   (`anyFeeAccrualIsReachable`) shows that **no** fee accrual at all is reachable through
   `beforeSwap` under the present summaries, so the verdict beside it is vacuous coverage. Linking
   `feeVault` (already done) was not the problem.
3. **SLV-03 vacuity**: cause found: `loop_iter: 12` against a 13-deep Fenwick walk, not the `2^128`
   literal. At `loop_iter: 14` the rules are non-vacuous and time out. SLV-03 stays unproved here.
4. **`HAVOC_ALL` → `HAVOC_ECF`**: applied, gated on F-4 as review-1 required, and it unblocked
   exactly the sub-goals it was predicted to.
5. **JDK / platform**: unchanged: this machine still has only JDK 17, so every run used
   `--disable_local_typechecking` against the locally patched `certora-cli` 8.19.2. No CVL type error
   reached the server this time.
6. **Re-run the specs edited after review-1**: DevVesting and Sleeve both ran, twice each.
7. **`bondIsMonotoneInDepth`**: **verified**, by pinning `BOND_DOUBLING_EVERY` to its deploy
   constant. `noTransitionIsPrivileged`'s `rank` / `submitScore` legs still time out.
8. **`genesisWeightIsTwiceTheTerminalWeight`**: restated as a delta and bounded to `M <= 64`; still
   times out at `loop_iter: 14`.
9. **Documentation defects**: both were reconciled in the review-2 contract pass.

## Review-3 checklist: DONE, and what review-4 inherits

All five specs ran against the contracts at **review-3** (the uncontested purse): **5 initial runs +
3 re-runs**. Per-rule status is in `PROPERTY_MAP.md`. **No genuine contract bug was found.** Every
job was submitted from a pristine `git archive HEAD` export
outside the repository, so concurrent edits to the working tree could not reach a run.

Review-3 closed these items:

1. **The purse machinery** the specs referenced was one line - `rank(uint256)` in the methods block -
   and it is gone. PUR-02's destination half is carried by `canonicalIsWriteOnce` /
   `historyEntriesAreImmutable`; its landing half (`Locker.depositBid` into the summarized singleton)
   is recorded as NOT EXPRESSIBLE here, and PUR-05's generation-claim draw bound is newly proved
   (`drawNeverExceedsTheGenerationsClaim`).
2. **`_.ownsToken` pinned** (with `_.isIdle`), the single cause it was diagnosed to be:
   RoundManager's failing sub-goals fell from **40 to 12** and two more rules
   (`headIndexOnlyGrows`, `pairingRightsAreWriteOnce`) were discharged in the re-run, leaving 22 of
   26 rules fully verified.
3. **`solvency` made inductive** with the `deployerCredit` carve-out, `payKeeper`, the rule's own
   counterexample, now verifies (17 of 20 methods).
4. **`ethLedgerDecomposition`'s review-2 regression reverted**: 10 failing methods down to 2, by
   tying each mirror to its storage word instead of asserting non-negativity from thin air.
5. **SCR-05 proved**: and it took TWO preconditions, the second of which is the finding: a
   `block.timestamp` that is a multiple of 2^64 truncates to 0 inside `_checkpoint`.
6. **VST-03's `releasedNeverExceedsVested` proved** by binding the allocation before `release()`.
7. **FEE-01 localised to one call** by two new `satisfy` rungs: `beforeSwap` runs to completion and
   reaches `_collect`'s `poolManager.mint`, while the vault call one line later is modelled as an
   unresolved AUTO summary, so the `_.accrue` summary never fires and the accrual counter has no
   writer.
8. **Sleeve bounds** proved `genesisTakesTheWholeSleeveAtMZero` for the first time; the remaining
   counterexamples sit exactly on the new bounds.

One **spec** defect was found, recorded as S-3: `isHeadWriter` named
two of the three writers of `_head` / `_headIndex` and missed `registerGenesis`. The contract is
right; the rule was asserting something it never claimed. It was invisible until the `ownsToken` pin
cleared the modelling noise in front of it.

### Review-4 checklist, in value order

1. **FEE-01 is one experiment from an answer.** Replace the `_.accrue(...)` wildcard with an EXACT
   `FeeVault.accrue(...)` entry (the vault is linked in `FamilyHook.conf`), or count accruals from the
   linked vault's own `ledgerTotal` store instead of from a summary. Rungs 0 and 0.5 already prove the
   execution gets there.
2. **Sleeve bounds one power of two tighter**: tree words `< 2^190`, coefficients `< 2^128`, the
   range a sleeve bounded by the vault's ETH balance can actually reach. It is still the only thing
   between the diagnosis and a proved SLV-03.
3. **State the history rules against LOCAL storage, not the delegating getters**: one item covering
   all four of RoundManager's remaining rules (`canonicalIsWriteOnce`, `historyEntriesAreImmutable`,
   `reverseIndexIsConsistent`, and the `finalize` leg of `noTransitionIsPrivileged`). `canonical`,
   `parentOf`, `creatorOf`, `indexOf` and `headIndex` all delegate to the prior registry while
   `!adopted`, and the methods still failing are the ones that can flip that decision mid-rule.
4. **`solvency` / `ethLedgerDecomposition` on the accrual path**: model "the fee claim was minted to
   the vault before `accrue` was called", a `preserved` block raising the pinned claim-balance ghost,
   or a `deliveredButUnbooked` term in `holdings`.
5. **`ethLedgerDecomposition`, the last two methods.** `ethMirrorsAreNonNegative` proves as its own
   invariant, but `requireInvariant`-ing it into the decomposition did not remove the negative-mirror
   counterexample: find out why an assumed, proved invariant over `persistent` ghosts does not
   constrain the pre-state here, then give the mapping-sum mirrors the full sum-ghost treatment
   (per-key mirror plus a sum axiom); `Sload` pins only fire on keys a method reads.
6. **A `BidDeployer.spec`** whose `_.depositBid(...)` summary records `(key, childToken)`, that is
   what makes PUR-02's landing step expressible at this tier.
7. **`noTransitionIsPrivileged` / `submitScore`**: the last parametric timeout.

## Review-4 checklist - DONE, and what review-5 inherits

The three specs the review-4 / 4b / 4c diff touches - `FamilyHook`, `FeeVault`, `RoundManager` -
ran against the contracts at the **`review-4` tag**: **3 initial runs + 3 re-runs**, the cap.
`DevVesting.spec` and `Sleeve.spec` are untouched by that diff and were not re-run; their review-3
verdicts stand. The full assessment is in `RESULTS-review-4.md`, per-rule status in
`PROPERTY_MAP.md`. **No genuine contract bug was found.** Every job was submitted from a pristine
`git archive review-4` export outside the repository - which mattered this pass, because the working
tree was being edited concurrently while the jobs ran.

Counts: FamilyHook 20 of 23 rules verified (was 16 of 20), FeeVault 22 of 26 (was 19 of 22),
RoundManager 24 of 28 (was 22 of 26). **Eleven new rules, ten of them verified.**

Review-4 closed these items:

1. **Every behaviour review 4/4b/4c introduced is now a rule, and all but one verify.** The ring
   freeze (`noRingEntryIsWrittenPastTheBell`), the end seal (`endSealIsWriteOnce`,
   `theEndSealIsOnlyLaidPastTheBell`), `BadNominalEnd`
   (`registerPoolRefusesACandidateWithoutAPublishedEnd`), `BadDurationScale`
   (`theConstructorsWindowGuardMatchesTheGetters`, `theScoredWindowAlwaysExceedsOneCoarseSlot`), the
   `ceil((W + RANDOM_END_S)/63)` slot (`theCoarseRingCoversTheScoredSpan`), the two-phase dead-successor
   evidence (`localBookingRequiresAgedEvidence`, `deadEvidenceMovesOnlyOnTheForwardingPaths`),
   "unresolved is not refused" (`unresolvedSuccessorIsNeverEvidence`), and the unattributed handover
   of a candidate id (`candidateAttributionsCrossAsUnattributed`).
2. **`PROPERTIES` §7 gap 12 is CLOSED**, in the code's favour. `averageOverHandlesTheDegenerateWindow`
   is rewritten as `averageOverRevertsOnACollapsedWindow` and verifies; it is no longer a documented
   divergence, and `RoundManager`'s two new rules prove the precondition that keeps the revert
   unreachable on any deployment that got past the constructor.
3. **FEE-01's review-4 experiment is answered - in the negative.** The EXACT `FeeVault.accrue(...)`
   summary entry is in place and the accrual counter still has no writer, while rungs 0 and 0.5
   discharge. Summary matching on the signature is ruled out; see the review-5 list.
4. **One rule had to be CORRECTED rather than re-run** (finding S-4): `flushForwardConserves`
   asserted that `ledgerTotal` falls by exactly what a flush delivered, which review 4b's
   dead-successor branch makes false. Restated two-sided, and verified.

### Review-5 checklist: AUTHORED, SUBMITTED, REFUSED, THEN RUN FOR TWO SPECS OF THREE

`FeeVault.spec`, `FamilyHook.spec` and `RoundManager.spec` were RE-DERIVED from the specification
against the contracts at review 5 (external genesis on an outside launch venue, $DOLL as the edge
currency, no native ETH anywhere in the protocol). They were then submitted in two passes on
2026-09-15, and the pass is CLOSED at **8 of 8 with two P-1 workaround runs** (the 3-plus-3 cap,
plus the two review-5f submissions spent on the two workarounds the support report names).

**First pass, four jobs, no verdicts.** Every job died in about two minutes with an internal Prover
error, a points-to invariant violation inside the return-buffer analysis, while transforming
`FeeVault.receiveForward(uint256,uint256)`. That is P-1. Two build levers were measured against it
and both were inert (S-9), and the pass stopped with two submissions unspent rather than gamble them.

**Second pass, two jobs, verdicts for both.** P-1 is a SCENE-LOADING crash, so it is decided by which
files a conf compiles. `FeeVault.sol` was in all three confs but is the SUBJECT of only one; in the
other two it was there for a link. Removing it from `FamilyHook.conf` and `RoundManager.conf`
unblocked both, and both jobs ran to completion:

- **`RoundManager`: 31 of 36 verified.** One genuine contract finding, **C-1**: `adoptGenesis` uses
  `_head != address(0)` as its once-only flag, so adopting `address(0)` leaves the flag unset and a
  second adoption succeeds. Latent, not live (the factory constructor refuses a zero or codeless
  genesis token), reported and then **PATCHED AT REVIEW 5e**: `RoundManager` now carries a dedicated
  write-once `_genesisAdopted` flag and `adoptGenesis` refuses a zero `token` explicitly. One
  specification finding, **S-12**.
- **`FamilyHook`: 17 of the 21 rules that ran, verified.** Two of the 23 authored rules are DISABLED
  for **S-10**, one failure is a specification defect (**S-11**) and three are the FEE-01 reachability
  ladder (**S-13**), which is now narrowed to one untested hypothesis.
- **`FeeVault`: still no verdict of any kind**, and it is the only thing P-1 now costs.
- **Review 5f, two more jobs, still no verdict.** Both workarounds from the support report are
  answered in the negative (S-14, S-15), and a third result corrects an earlier one: the `-cache`
  token this project had been comparing across runs is not derived from the sources, so "the cache
  key did not move" was never evidence that a build did not change (S-16).

**S-8 IS WITHDRAWN.** The first pass recorded that the two `Sload` hooks type-check once the key type
is spelled `IFamilyHook.PoolId`. They do not. No spelling does, and S-10 has the evidence table.

**A support report for Certora is drafted** at `private/certora/SUPPORT-P1.md`, ready for the project
to send from the review identity: the error, the function, what changed since the last successful
run, the job ids, the two levers already ruled out, and the two workarounds for review 6. It also
records that the documentation names NO `--prover_args` option for disabling or relaxing the
return-buffer analysis, with the page cited, so nobody spends a submission guessing one.

**The run commands, one per conf, in this order.** Run them from a pristine export outside the
repository (`git archive HEAD | tar -x -C ...`), as review 3 and review 4 did, so that concurrent
edits to the working tree cannot reach a job:

```sh
certoraRun certora/conf/FeeVault.conf
certoraRun certora/conf/RoundManager.conf
certoraRun certora/conf/FamilyHook.conf
certoraRun certora/conf/Sleeve.conf        # only if the sleeve bounds below are tightened first
```

**The budget rule: 3 INITIAL RUNS PLUS 3 RE-RUNS, and no more.** That is the same cap review 4 ran
under and it is what the pass is planned around. The three initial runs are the three re-based specs.
The three re-runs are for what the first three surface, in this priority order:

1. anything that fails to TYPE-CHECK or to LINK (see the two first-run risks below) - a run spent on
   a syntax error is the most expensive kind there is, which is why item 1 of the review-4 checklist
   was a JDK;
2. `FeeVault`, if the `EDGE` link or the exact `edgeDoll.*` entries need the fallback in that conf's
   header;
3. whichever of the three has the most sub-goals failing for ONE identified cause.

`Sleeve.conf` is deliberately outside that budget: it is untouched by the review-5 diff, its review-3
verdicts stand, and a run on it buys nothing until the bounds are tightened (item 6 below).

**Two first-run risks, both recorded in `RESULTS-review-5.md` with their fallbacks.** Neither is a
claim about the contracts:

- the `EDGE` link in `FeeVault.conf` is the first link in these confs onto an immutable of a
  user-defined value type (`Currency` over `address`) rather than a plain address;
- the two `Sload` hooks in `FamilyHook.spec` are the first struct-FIELD hooks in these specs
  (`registeredPools[KEY PoolId id].isEdge` and `.tradingStart`). They carry FEE-01's per-pool half and
  the snipe-window suppression, so if they do not type-check, both properties fall back to the fuzz
  and unit tiers.

**How the two risks turned out.** Risk 1 is STILL UNTESTED: `FeeVault.conf` has never loaded, so the
`EDGE` link has never been exercised by a job. **Risk 2 HAPPENED and its fallback is taken** (S-10):
the hooks do not type-check in any spelling, so `protocolFeeOnlyAtTheEdge` and
`theEdgeFeeIsSuppressedDuringTheSnipeWindow` are disabled in the spec with a restore note and both
properties fall back to `test/properties/Fees.prop.t.sol` and the review-5 unit tests. They are
recorded as NOT EXPRESSIBLE here, not as unproved.

### Review-6 checklist, in value order

**The one-line state, after review 6 and review 5g: `FeeVault.spec` has never run and this project
has nothing left to try against that, C-1 is CLOSED (fixed at review 5e), and three specification
defects are waiting for a one-line fix each. The full version is the review-6 section of `RESULTS-review-5.md`;
this is the short form.**

1. **Send the support report. Review 6 spent its two submissions establishing that it is the only
   lever left.** `private/certora/SUPPORT-P1.md` is drafted, updated with the review-6 results and
   ready for the project to send from the review identity. FIVE workarounds have been measured and
   all five are refused: the two the report itself proposed (S-14, S-15) and the three review 6
   added (S-17, S-18, S-19). Its cache-key question is answered by S-16 and is out of the report.
   The only thing this project can still try by itself is a `certora-cli` newer than 8.19.2, because
   this is a Prover-internal crash. **Do not re-run any of the five**, and do not spend a submission
   on another guessed `prover_args` flag: the one flag the documentation does name for this analysis
   has now been tried and it changes nothing. **Review 5g adds a SIXTH measured lever and a second
   question for the report (S-20).** The lever is a verification-only harness,
   `certora/harness/FeeVaultHarness.sol`, which inherits `FeeVault` and overrides `holdings` with one
   storage read so the crashing balance reads leave `receiveForward`'s path; `contracts/FeeVault.sol`
   carries the `virtual` keyword for it, and the deployed bytecode is byte-identical with and without
   that word. It cannot be submitted: with a DERIVED contract as the verified one, the CVL
   type-checker accepts no spelling of the `Currency` key of the inherited `ledgerTotal` mapping, and
   the two hooks on it carry seven rules. Ask Certora for that spelling in the same breath as S-10's
   `PoolId` one. **No submission was spent, and the six spellings tried are listed in S-20; do not
   re-try them.**
2. ~~**Decide C-1**~~ **DONE at review 5e.** The one contract finding: `RoundManager.adoptGenesis`
   used `_head != address(0)` as a write-once flag, so adopting `address(0)` left it unset. It was
   latent (the factory constructor refuses a zero or codeless genesis token) and is now fixed: a
   dedicated `_genesisAdopted` boolean replaces the sentinel and the zero address is refused
   explicitly.
3. **Fix S-11, S-12 and S-10**, in that order of cheapness: pin or lower-bound `hopFeePpm` in
   `summedRatesStayBelowOne`; add `pushRefund`, `pushForfeit` and `claimRefund` to
   `noTransitionIsPrivileged`'s exclusion list; and restore the two `Sload` hooks together with the
   two rules they carry, once Certora names a spelling for the `PoolId` key type.
4. **FEE-01 is one conf setting from an answer (S-13).** Run `FamilyHook` once with
   `optimistic_fallback` off and see whether the accrual becomes reachable while rungs 0 and 0.5 stay
   reachable. The linked-callee and exact-summary hypotheses are both dead.
5. **State the history rules against LOCAL storage, not the delegating getters** - review-4 item 3,
   still open. C-1's leg is no longer part of the residual: review 5e removed it.
6. **Restore `FeeVault.sol` and the `feeVault` link to the two confs** once the Prover can load that
   file. Both confs carry the note; do not leave the vault summarized out by inertia.

Carried into review 6, unchanged in substance and all of it still untested because `FeeVault.spec`
has never run:

1. **JDK 21 on the run machine: KEEP IT.** It paid for itself twice on one day: S-8 in the first pass
   and a five-probe experiment for S-10 in the second, all at no cost in prover minutes. Under JDK 17
   the CLI forces `--disable_local_typechecking` and each probe would have burned a submission.
2. **`noPayoutPathCanBurnTokensAtTheZeroAddress`** carries finding S-5: the one-line
   `require amount > 0` is in the spec and has still never been checked by a run.
3. **`solvency` / `edgeLedgerDecomposition` on the accrual path** - review-4 items 4 and 5. The
   linked edge token changes what `holdings` is, so the "minted to the vault before `accrue`"
   modelling gap may have a different shape now.
4. **Sleeve bounds one power of two tighter** (tree words `< 2^190`, coefficients `< 2^128`).
5. **A `BidDeployer.spec`** whose `_.depositBid(...)` summary records `(key, childToken)`, which is
   what makes PUR-02's landing step expressible at this tier.
6. **Re-measure S-9 only alongside a run that is happening anyway.** Both settings were carried
   unchanged into the two jobs that SUCCEEDED, so they cost nothing today.

### Standing lessons

- **An identifier is only evidence about what it is derived from.** Review 5 read "the cache key did
  not move" as "the build did not change" and recorded two settings as inert on that basis. The
  `-cache` token tracks the conf, not the sources: it moved when `files` and `link` changed and sat
  still while the contract was rewritten underneath it (S-16). Compare the per-transform keys in
  `Reports/CacheEvents.txt` and the crashing block id instead, both of which do move with the build.
- **When both workarounds for a defect fail, say so and stop, rather than inventing a third.**
  Review 5f spent one submission on each of the two the support report named, recorded both
  negatives with their job ids, reverted the contract change the second one needed, and left the
  defect where it belongs, with the tool vendor (S-14, S-15). Review 6 then worked the documented
  list to its end and stopped there: three more levers, two submissions, no verdict, and nothing
  invented past what the vendor's own changelog names (S-17, S-18, S-19).
- **Read the stack, not the error line.** P-1 reports as a points-to failure, so the vendor's
  points-to relaxation flag looked like the answer. The frame that actually throws is the RETURN
  BUFFER allocation rewrite the points-to results feed, which is why the flag changed nothing and
  why the crashing block id did not move by one (S-17). The next question for Certora is about that
  frame.
- **Check what a summary can ATTACH to before designing around it.** An internal summary is the
  clean way to take an external call off a method's path, and it is unavailable for a `public`
  function: the finders only instrument `internal` and `private` ones. A local type-check answered
  that in seconds, where a submission would have answered it in prover minutes (S-19).
- **A type-check that passed once is not evidence.** S-8 recorded a spelling as accepted; under a
  scene with one file fewer, no spelling is accepted at all, and the earlier probe cannot be
  reproduced (S-10). Re-run a type-check whenever the scene changes, and treat a remembered pass the
  same way this project treats a remembered green rule.
- **When a Prover defect blocks a file, ask which scenes NEED it, not which compile it.** Two of the
  three confs were compiling `FeeVault.sol` for a link while their specs already summarized the vault
  away. Removing it cost no rule its meaning and turned four dead jobs into two useful ones.
- **A guard that lives one contract away from the invariant it protects is a seam, not a defence.**
  C-1: `RoundManager` states adoption-is-once and enforces it with a sentinel, while what actually
  makes the sentinel sound is a constructor check in the factory.
- **A residual modelling failure can hide a real spec defect behind it.** `pairingRightsAreWriteOnce`
  had been "failing for the `ownsToken` reason" for two passes; with that pinned, what was left was a
  rule asserting something the contract never claimed (S-3). Do not stop diagnosing at the first
  cause that explains the count.
- **Derive `loop_iter` from the data structure, not from taste.** Under `optimistic_loop` a bound
  below the real depth makes the loop-exit assumption unsatisfiable and turns rules **vacuous**, not
  merely incomplete. Read any `rule_sanity` failure as "the loop bound is wrong" before anything else.
- **A rule can be a tautology.** `DevVesting.releasedNeverExceedsTotal` reduced to
  `released <= balance + released` and was reported as verified from review-1 on while proving
  nothing. That spec is deleted with its contract, but the lesson is the reason every new review-5
  rule carries a `satisfy` ladder or an explicit note about what would make it vacuous.
- **A summary can match nothing.** `_.isMock()` was summarized in `RoundManager.spec` from review-1
  through review-4 and no contract in the tree has ever declared it (`IRandomnessSource` is `pin` /
  `fulfil` / `status`). A summary that matches nothing is silent: it neither fires nor complains. It
  was found by grepping every identifier in the specs against `contracts/`, which is now part of
  authoring a pass and not just of running one.
- **A green rule is only evidence about the code it was written against** (review-4, S-4). When the
  contract under a verified rule changes, re-DERIVE the rule from the specification; do not re-run
  it. `flushForwardConserves` had been verified for three passes and became a false claim the
  moment review 4b gave `flushForward` a branch that dequeues without debiting. Re-running it would
  have reported a contract regression; loosening it to make it pass would have hidden a real one.

## Retrieving results from a finished job

The result endpoints authenticate with the per-job **read key** (the `anonymous…Key` query parameter), which the server returns once
and the CLI surfaces only on the failure path. Capture it from the run's `.certora_internal/` tree
**before** clearing the scratch, and keep it out of the tree (this repo keeps job links in
`private/certora/`, which is gitignored; grepping our own tree for that parameter name must stay empty).

Two things review-1 got wrong about these endpoints, both worth knowing:

- They reject a default Python/curl `User-Agent` with **403**, which reads exactly like a bad key.
  With a browser `User-Agent` they answer normally.
- Far more than `output.json` is reachable. `jobData/<user>/<job>` carries a `zipOutputUrl` holding
  the **entire output tree as a tarball**: including `Reports/ctpp_<rule>.txt`, the pretty-printed
  call trace with each counterexample's storage, ghosts and CVL model. That is the artefact worth
  reading; the web tree view is not needed. (`Results.txt` is 403 over HTTP but is in the tarball.)

Submit without `--wait_for_results` and poll `jobData` instead: the big specs outrun the CLI's local
client timeout while the cloud job keeps going, which is what truncated review-1.
