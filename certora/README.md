# Certora specifications

For running the Prover from WSL on a Windows machine, see `RUNBOOK-WSL.md`.

Formal specifications for the Dollhouse protocol, written **from the specification** — the only
inputs were `docs/spec/PROTOCOL_SPEC.md`, `docs/spec/PROPERTIES.md`, `docs/MECHANISM_v3.md`,
`docs/DEPLOY_CONSTANTS.md`, and the function signatures in `contracts/interfaces/` and
`contracts/*.sol`. No implementation body, test or script was consulted, so a rule the code violates
is a finding, not a documentation error to be reconciled away.

```
certora/
  specs/       FeeVault.spec  RoundManager.spec  DevVesting.spec  Sleeve.spec  FamilyHook.spec
  conf/        one .conf per spec
  harness/     FenwickHarness.sol — exposes the internal FenwickRangeAdd library, no other logic
  PROPERTY_MAP.md
```

## Running

From a **clean clone** (the Prover compiles the whole tree; a dirty `out/` or `crytic-export/` can
shadow sources):

```sh
git clone <repo> dollhouse && cd dollhouse
forge install                      # submodules only; the Prover needs the remappings resolvable
export CERTORAKEY=...              # the Prover reads the key from the environment, never from a file
certoraRun certora/conf/FeeVault.conf
certoraRun certora/conf/RoundManager.conf
certoraRun certora/conf/DevVesting.conf
certoraRun certora/conf/Sleeve.conf
certoraRun certora/conf/FamilyHook.conf
```

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
`solc_optimize: "200"` and `solc_evm_version: "cancun"` — the same three settings foundry builds
with.

`CERTORAKEY` comes from the **environment**, never from a file and never from a conf. Export it in
the shell that runs `certoraRun` (e.g. from a git-ignored `.env`) and do not echo it.

The `<TODO link>` placeholders are gone. The links were derived from `script/Deploy.s.sol` and the
three constructors; each conf documents inline which immutables are linked and, for each one that is
not, why leaving it havoc'd is sound. The v4 `PoolManager` is deliberately **not** linked: the specs
summarize every one of its entrypoints NONDET, and an unconstrained address is strictly more general
than a pinned one.

Two non-obvious build settings, also documented inline in the three big confs:

- `disable_source_finders` / `disable_internal_function_instrumentation` — the Prover's autofinder
  instrumentation adds locals to already stack-heavy functions and breaks the via-IR build. The
  finders only matter for observing or summarizing *internal* functions; every summary in these
  specs is an external `_.` wildcard.
- `yul_optimizer_steps` — the Prover replaces solc's Yul optimiser sequence with one that drops the
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
unmodified — see the environment section of `RESULTS-review-1.md` for the four path-handling defects
that have to be worked around. Prefer WSL or a Linux runner.

Results are in `RESULTS-review-3.md` (current), `RESULTS-review-2.md` and `RESULTS-review-1.md`
(the first two passes); per-rule status is in `PROPERTY_MAP.md`.

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
| `FamilyToken` (in `DevVesting.spec`) | `DISPATCHER(true)` | A fixed-supply ERC-20 with no hooks, no fee-on-transfer and no callbacks (`PROTOCOL_SPEC` §B), so dispatching to the real implementation is sound and keeps `total() = balanceOf(this) + released` meaningful. |

The `FamilyHook` and `FeeVault` specs summarize *each other's* subject matter to NONDET, so no rule
in either is proved true only because the other behaved well. That split is deliberate: it keeps each
spec's claim self-contained at the cost of two weakened cross-contract rules, both flagged in
`PROPERTY_MAP.md`.

## What these specs do NOT cover

Certora is the wrong tier for anything that needs a real `PoolManager`, real curve arithmetic, or a
long history of swaps. The following stay with fuzz, stateful-invariant and fork testing:

- **Per-route fee counting (FEE-01, ROU-02).** With `PoolManager.swap` summarized, the prover never
  executes legs 2..L of a route. "Exactly one protocol fee per traversal" is proved here only in its
  per-pool form ("charged iff the pool is the genesis pool"); the route-level count is a fork test.
- **Curve and tick arithmetic (SUP-02/03, BID-01..04, BID-08..13, the whole of §E).** Snapping,
  gross-ups, liquidity-for-amount and TWAP consultation are Halmos and fork material.
- **Reentrancy against the unlock flag (REN-01).** The transient lock lives in the singleton, which
  is summarized away; the flag is invisible to the Prover.
- **Exact accumulator reconstruction across the checkpoint rings (SCR-04, SCR-05).** Replaying an
  arbitrary swap history through two rings exceeds a discharge-able loop bound.
- **The full-depth sleeve sum (SLV-03 for symbolic `M`).** CVL cannot quantify a sum over a symbolic
  range; the spec proves it out to `M <= 3` plus a depth-independent per-term bound.
- **Supply constancy of the token clones (SUP-01).** Every family token is an EIP-1167 proxy with no
  bytecode of its own for the Prover to load.
- **Liveness.** Nothing here proves anybody *will* call `submitScore`, `finalize`, `rank`,
  `flushForward` or a keeper entrypoint. `PROTOCOL_SPEC` §A states that dependency plainly, and it
  stays a disclosed property, not a verified one.

## Rule-to-property map

See `certora/PROPERTY_MAP.md` for the full table: every rule and invariant against its
`PROPERTIES.md` ID, plus the not-expressible list with reasons and the tier each one falls back to,
and the table of `docs/spec/PROPERTIES.md` §7 spec gaps whose most plausible reading these specs
encode (marked `// SPEC-GAP:` at each site).

## Review-2 checklist — DONE, and what review-3 inherits

All five specs ran against the contracts at tag `review-2`: **5 initial runs + 3 re-runs**. The full
assessment is in `RESULTS-review-2.md`, per-rule status in `PROPERTY_MAP.md`, and the summary entry in
`docs/attack-log.md` ("Formal verification (Certora) at review-2"). **No genuine contract bug was
found**, and all four review-1b findings (F-1..F-4) are confirmed closed by the Prover.

Review-2 closed these items from the old checklist:

1. **Re-run the three big specs** after the post-review-1b fixes — done. FeeVault 7 → 3 rules with
   failures (17 of 20 fully verified); RoundManager 10 → 6 (20 of 26 fully verified); FamilyHook
   re-run with two new rules.
2. **FEE-01** — still unproved, but no longer mysterious: a new rung-1 `satisfy`
   (`anyFeeAccrualIsReachable`) shows that **no** fee accrual at all is reachable through
   `beforeSwap` under the present summaries, so the verdict beside it is vacuous coverage. Linking
   `feeVault` (already done) was not the problem.
3. **SLV-03 vacuity** — cause found: `loop_iter: 12` against a 13-deep Fenwick walk, not the `2^128`
   literal. At `loop_iter: 14` the rules are non-vacuous and time out. SLV-03 stays unproved here.
4. **`HAVOC_ALL` → `HAVOC_ECF`** — applied, gated on F-4 as review-1 required, and it unblocked
   exactly the sub-goals it was predicted to.
5. **JDK / platform** — unchanged: this machine still has only JDK 17, so every run used
   `--disable_local_typechecking` against the locally patched `certora-cli` 8.19.2. No CVL type error
   reached the server this time.
6. **Re-run the specs edited after review-1** — DevVesting and Sleeve both ran, twice each.
7. **`bondIsMonotoneInDepth`** — **verified**, by pinning `BOND_DOUBLING_EVERY` to its deploy
   constant. `noTransitionIsPrivileged`'s `rank` / `submitScore` legs still time out.
8. **`genesisWeightIsTwiceTheTerminalWeight`** — restated as a delta and bounded to `M <= 64`; still
   times out at `loop_iter: 14`.
9. **Documentation defects** — both were reconciled in the review-2 contract pass
   (`docs/attack-log.md`, "Documentation corrected in the same pass").

## Review-3 checklist — DONE, and what review-4 inherits

All five specs ran against the contracts at **review-3** (the uncontested purse): **5 initial runs +
3 re-runs**. The full assessment is in `RESULTS-review-3.md`, per-rule status in `PROPERTY_MAP.md`,
and the summary entry in `docs/attack-log.md` ("Formal verification (Certora) at review-3"). **No
genuine contract bug was found.** Every job was submitted from a pristine `git archive HEAD` export
outside the repository, so concurrent edits to the working tree could not reach a run.

Review-3 closed these items:

1. **The purse machinery** the specs referenced was one line - `rank(uint256)` in the methods block -
   and it is gone. PUR-02's destination half is carried by `canonicalIsWriteOnce` /
   `historyEntriesAreImmutable`; its landing half (`Locker.depositBid` into the summarized singleton)
   is recorded as NOT EXPRESSIBLE here, and PUR-05's generation-claim draw bound is newly proved
   (`drawNeverExceedsTheGenerationsClaim`).
2. **`_.ownsToken` pinned** (with `_.isIdle`) — the single cause it was diagnosed to be:
   RoundManager's failing sub-goals fell from **40 to 12** and two more rules
   (`headIndexOnlyGrows`, `pairingRightsAreWriteOnce`) were discharged in the re-run, leaving 22 of
   26 rules fully verified.
3. **`solvency` made inductive** with the `deployerCredit` carve-out — `payKeeper`, the rule's own
   counterexample, now verifies (17 of 20 methods).
4. **`ethLedgerDecomposition`'s review-2 regression reverted** — 10 failing methods down to 2, by
   tying each mirror to its storage word instead of asserting non-negativity from thin air.
5. **SCR-05 proved** — and it took TWO preconditions, the second of which is the finding: a
   `block.timestamp` that is a multiple of 2^64 truncates to 0 inside `_checkpoint`.
6. **VST-03's `releasedNeverExceedsVested` proved** by binding the allocation before `release()`.
7. **FEE-01 localised to one call** by two new `satisfy` rungs: `beforeSwap` runs to completion and
   reaches `_collect`'s `poolManager.mint`, while the vault call one line later is modelled as an
   unresolved AUTO summary — so the `_.accrue` summary never fires and the accrual counter has no
   writer.
8. **Sleeve bounds** proved `genesisTakesTheWholeSleeveAtMZero` for the first time; the remaining
   counterexamples sit exactly on the new bounds.

One **spec** defect was found and is recorded as S-3 in `RESULTS-review-3.md`: `isHeadWriter` named
two of the three writers of `_head` / `_headIndex` and missed `registerGenesis`. The contract is
right; the rule was asserting something it never claimed. It was invisible until the `ownsToken` pin
cleared the modelling noise in front of it.

### Review-4 checklist, in value order

1. **FEE-01 is one experiment from an answer.** Replace the `_.accrue(...)` wildcard with an EXACT
   `FeeVault.accrue(...)` entry (the vault is linked in `FamilyHook.conf`), or count accruals from the
   linked vault's own `ledgerTotal` store instead of from a summary. Rungs 0 and 0.5 already prove the
   execution gets there.
2. **Sleeve bounds one power of two tighter**: tree words `< 2^190`, coefficients `< 2^128` — the
   range a sleeve bounded by the vault's ETH balance can actually reach. It is still the only thing
   between the diagnosis and a proved SLV-03.
3. **State the history rules against LOCAL storage, not the delegating getters** — one item covering
   all four of RoundManager's remaining rules (`canonicalIsWriteOnce`, `historyEntriesAreImmutable`,
   `reverseIndexIsConsistent`, and the `finalize` leg of `noTransitionIsPrivileged`). `canonical`,
   `parentOf`, `creatorOf`, `indexOf` and `headIndex` all delegate to the prior registry while
   `!adopted`, and the methods still failing are the ones that can flip that decision mid-rule.
4. **`solvency` / `ethLedgerDecomposition` on the accrual path**: model "the fee claim was minted to
   the vault before `accrue` was called" — a `preserved` block raising the pinned claim-balance ghost,
   or a `deliveredButUnbooked` term in `holdings`.
5. **`ethLedgerDecomposition`, the last two methods.** `ethMirrorsAreNonNegative` proves as its own
   invariant, but `requireInvariant`-ing it into the decomposition did not remove the negative-mirror
   counterexample: find out why an assumed, proved invariant over `persistent` ghosts does not
   constrain the pre-state here, then give the mapping-sum mirrors the full sum-ghost treatment
   (per-key mirror plus a sum axiom); `Sload` pins only fire on keys a method reads.
6. **A `BidDeployer.spec`** whose `_.depositBid(...)` summary records `(key, childToken)` — that is
   what makes PUR-02's landing step expressible at this tier.
7. **`noTransitionIsPrivileged` / `submitScore`**: the last parametric timeout.

### Three standing lessons

- **A residual modelling failure can hide a real spec defect behind it.** `pairingRightsAreWriteOnce`
  had been "failing for the `ownsToken` reason" for two passes; with that pinned, what was left was a
  rule asserting something the contract never claimed (S-3). Do not stop diagnosing at the first
  cause that explains the count.
- **Derive `loop_iter` from the data structure, not from taste.** Under `optimistic_loop` a bound
  below the real depth makes the loop-exit assumption unsatisfiable and turns rules **vacuous**, not
  merely incomplete. Read any `rule_sanity` failure as "the loop bound is wrong" before anything else.
- **A rule can be a tautology.** `DevVesting.releasedNeverExceedsTotal` reduces to
  `released <= balance + released` and has been reported as verified since review-1 while proving
  nothing. It is marked as such now.

## Retrieving results from a finished job

The result endpoints authenticate with the per-job **read key** (the `anonymous…Key` query parameter), which the server returns once
and the CLI surfaces only on the failure path. Capture it from the run's `.certora_internal/` tree
**before** clearing the scratch, and keep it out of the tree (this repo keeps job links in
`private/certora/`, which is gitignored; grepping our own tree for that parameter name must stay empty).

Two things review-1 got wrong about these endpoints, both worth knowing:

- They reject a default Python/curl `User-Agent` with **403**, which reads exactly like a bad key.
  With a browser `User-Agent` they answer normally.
- Far more than `output.json` is reachable. `jobData/<user>/<job>` carries a `zipOutputUrl` holding
  the **entire output tree as a tarball** — including `Reports/ctpp_<rule>.txt`, the pretty-printed
  call trace with each counterexample's storage, ghosts and CVL model. That is the artefact worth
  reading; the web tree view is not needed. (`Results.txt` is 403 over HTTP but is in the tarball.)

Submit without `--wait_for_results` and poll `jobData` instead: the big specs outrun the CLI's local
client timeout while the cloud job keeps going, which is what truncated review-1.
