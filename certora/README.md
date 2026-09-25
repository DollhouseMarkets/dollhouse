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

There is no vesting contract in this protocol and no vesting spec.


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

**Scope of each conf.** `FamilyHook.conf` and `RoundManager.conf` do not compile `FeeVault.sol`;
both specs summarize the vault's entrypoints, and each conf notes inline what the vault link would
add. `FeeVault.conf` loads the vault with its edge-token link. Two `FamilyHook` rules are disabled
in the spec because the storage hook they need cannot name the `PoolId` key type in CVL; each
carries a restore note.

**`loop_iter` must be at least the real depth of whatever the spec walks.** Under `optimistic_loop`
the Prover *assumes* the loop has exited after the unrolled iterations; if the bound is too low that
assumption is unsatisfiable on exactly the interesting paths, and rules come back "not violated"
**vacuously** rather than incompletely. At `loop_iter: 12`, `Sleeve.conf` ran
against a Fenwick walk that takes thirteen steps (`1, 2, 4, ... 4096` while `i <= 4097`), and that is
what made SLV-03 vacuous. Read a `rule_sanity` failure
as "the loop bound is wrong" first.

Each conf sets `solc: solc0.8.26`, `optimistic_loop: true` with a per-spec `loop_iter`,
`rule_sanity: basic`, a `msg`, and a `packages` array mirroring `foundry.toml`'s remappings.
`foundry.toml` compiles with `via_ir`, so every conf sets `solc_via_ir: true` alongside
`solc_optimize: "200"` and `solc_evm_version: "cancun"`, the same three settings foundry builds
with.

`CERTORAKEY` comes from the **environment**, never from a file and never from a conf. Export it in
the shell that runs `certoraRun` (e.g. from a git-ignored `.env`) and do not echo it.


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

Results are in `RESULTS.md`; per-rule status is in `PROPERTY_MAP.md`.

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
| The **edge currency** (in `FeeVault.spec`) | **linked to a real ERC-20 and NOT summarized** | `EDGE` is an immutable, so it can be pinned, and every ledger in the vault is denominated in it. A linked, unmodified ERC-20 is consistent between reads by construction (which is all a consistent-read ghost would buy) AND its balance actually MOVES on a transfer, which is what `valueLeavesOnlyOnPayoutMethods` needs in order to be a claim about value leaving rather than about a constant. `test/utils/MockDoll.sol` is the stand-in, and the launch implementation is the same shape: no hooks, no fee on transfer, no callbacks, not pausable, not upgradeable. The wildcard `_.balanceOf(address)` summary stays for the PARENT-denominated hop pots, whose currency is symbolic. |
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
  per-pool form: "charged only if the pool is an EDGE pool", i.e. a
  pool whose parent is canonical index 0. The route-level count is a fork test.
- **Curve and tick arithmetic (SUP-02/03, BID-01..04, BID-08..13, the whole of §E).** Snapping,
  gross-ups, liquidity-for-amount and TWAP consultation are Halmos and fork material.
- **Reentrancy against the v4 unlock flag (REN-01).** The transient lock lives in the singleton,
  which is summarized away; the flag is invisible to the Prover. The OTHER
  reentrancy guard, the plain `_locked` word on `openRoundIfIdle` and `addCandidate`,
  is local to `RoundManager` and IS stated, as `guardedFactoryEntrypointsCannotBeReentered`.
- **Exact accumulator reconstruction across the checkpoint rings (SCR-04, SCR-05).** Replaying an
  arbitrary swap history through two rings exceeds a discharge-able loop bound.
- **The full-depth sleeve sum (SLV-03 for symbolic `M`).** CVL cannot quantify a sum over a symbolic
  range; the spec proves it out to `M <= 3` plus a depth-independent per-term bound.
- **Supply constancy of the token clones (SUP-01), and the stack-wide half of SUP-04.** Every family
  token is an EIP-1167 proxy with no bytecode of its own for the Prover to load. SUP-04 is stated
  in two halves: the VAULT half (the vault's edge balance is its ledgers plus donations, and
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

## Retrieving results from a finished job

The result endpoints authenticate with the per-job **read key** (the `anonymous…Key` query parameter), which the server returns once
and the CLI surfaces only on the failure path. Capture it from the run's `.certora_internal/` tree
**before** clearing the scratch, and keep it out of any tracked file.

Two properties of these endpoints:

- They reject a default Python/curl `User-Agent` with **403**, which reads exactly like a bad key.
  With a browser `User-Agent` they answer normally.
- Far more than `output.json` is reachable. `jobData/<user>/<job>` carries a `zipOutputUrl` holding
  the **entire output tree as a tarball**: including `Reports/ctpp_<rule>.txt`, the pretty-printed
  call trace with each counterexample's storage, ghosts and CVL model. That is the artefact worth
  reading; the web tree view is not needed. (`Results.txt` is 403 over HTTP but is in the tarball.)

Submit without `--wait_for_results` and poll `jobData` instead: the big specs outrun the CLI's local
client timeout while the cloud job keeps going.
