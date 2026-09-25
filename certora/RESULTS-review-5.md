# Certora, review 5: the run, and the Prover refusal that stopped it

**Date authored:** 2026-09-14. **Date run:** 2026-09-15. **Contracts:** HEAD at `b6fb58f`
(review 5 / 5b / 5c / 5d). **Design:** the review-5 design decisions, including the 5b, 5c and 5d fix passes.

- Prover: `certora-cli 8.19.2`, classic CLI, free plan. solc `0.8.26`.
- **THIS FILE COVERS THREE PASSES ON THE SAME DAY.** The FIRST pass submitted four jobs and got no
  verdict at all (finding P-1 below). The SECOND pass, review 5b, spent the budget's last two
  submissions after taking `contracts/FeeVault.sol` out of the `FamilyHook` and `RoundManager`
  scenes, which is what gets a job past P-1, and those two DID return verdicts. The THIRD pass,
  review 5f, spent two extra submissions on the two workarounds the support report names, one
  spec-side and one contract-side, and **both were refused by P-1 exactly as before** (S-14 and
  S-15). The FOURTH pass, review 6, is in this file too: it worked through the three remaining
  documented, verification-only levers, spent two submissions on the two that could be submitted,
  and **got no verdict either** (S-17, S-18, S-19). `FeeVault.spec` is still blocked and still has
  no verdict of any kind.
- Every job was submitted from a pristine `git archive HEAD` export outside the repository, plus the
  one spec fix below, because a testnet job was editing the working tree while the jobs ran.
- **JDK 21 is on the run machine**, which is review-4's checklist item 1 and the first pass in which
  local CVL type-checking actually runs. It paid for itself immediately: see S-8.
- `CERTORAKEY` came from the environment. **No key and no per-job read key appears in any tracked
  file**; job links and their read keys are in `private/certora/JOBS-review-5.md` (gitignored) and
  the artefacts (`jobData.json`, `output.json`, the whole output tarball and `Results.txt`) are under
  `private/certora/review-5/<label>/`. A `git grep` of this tree for the read-key parameter name is
  empty.

## The result in one line

**THE FIRST PASS PRODUCED NO RULE VERDICT AT ALL.** Four jobs were submitted and every one failed in
about two minutes with the same internal Prover error, raised while loading the scene, long before
any rule was checked. That is finding P-1, and it is the most important thing this pass found.

**THE SECOND PASS GOT TWO OF THE THREE SPECS PAST IT.** `FeeVault.sol` is the file the Prover cannot
load, and it was in all three confs. It is only the SUBJECT of one of them; in the other two it was
there to satisfy one link and, in `FamilyHook`, one exact summary entry. Taking it out of those two
scenes and letting the existing CVL summaries carry the vault cost no rule its meaning, and both jobs
ran to completion:

- **`RoundManager`: 31 of 36 rules verified.** Five have failures, and one of those five is a real
  finding about the contract, recorded as **C-1** below. It was not patched at the time of this pass;
  it was fixed at review 5e, and the C-1 entry below carries that status.
- **`FamilyHook`: 17 of the 21 rules that ran are verified.** Two of the 23 authored rules are
  DISABLED rather than run, for finding **S-10**; of the four that failed, one is a specification
  defect (**S-11**) and three are the FEE-01 reachability ladder, which is now answered further than
  it ever has been (**S-13**).
- **`FeeVault`: still no verdict of any kind.** Every cell in its table below reads "blocked, P-1",
  and none of them may be cited as evidence about the code.

**THE THIRD PASS TRIED BOTH WORKAROUNDS AND NEITHER ONE WORKS.** Review 5f spent two further
submissions on `FeeVault.conf`, in the order the support report sets out. Workaround (a), a
ghost-backed CVL summary of the edge token with the link and `test/utils/MockDoll.sol` out of the
scene, was refused identically (**S-14**). The last resort, a restructure of
`contracts/FeeVault.sol` so that no expression holds two external-call return buffers, was refused
identically as well (**S-15**), and that contract change was REVERTED rather than carried, because
it bought nothing. A third result fell out of reading the two jobs side by side and it CORRECTS an
earlier reading: the `-cache` string this project has been comparing across runs is not derived from
the sources at all (**S-16**).

**THE FOURTH PASS EXHAUSTED THE DOCUMENTED LEVERS AND STILL HAS NO VERDICT.** Review 6 tried, in
order: the Prover's own `-relaxedPointerSemantics` escape hatch for exactly this method and this
analysis (**S-17**, crashed at the identical block id), a verification-only change to how the scene
is COMPILED (**S-18**, crashed at a different block id, so the different build really was analysed),
and an internal CVL summary of `holdings`, the one thing that would take the two external balance
reads off `receiveForward`'s path without editing the contract (**S-19**, which cannot be written at
all: `holdings` is `public`, and the Prover's internal-function finders only cover `internal` and
`private` functions). Two submissions, no verdict, and the third lever cost nothing because the local
type-checker refused it.

**THE FIFTH PASS, REVIEW 5g, BUILT THE HARNESS AND NEVER GOT TO SUBMIT IT.** The sixth lever is a
verification-only harness that INHERITS `FeeVault` and overrides `holdings` with one storage read, so
that the two external balance reads P-1 crashes on are not on `receiveForward`'s path at all. The
contract side of it is one word, `virtual`, and the deployed bytecode is byte-identical with and
without it (`docs/security/full-suite-review-5g.txt`). The harness compiles, and the whole spec
type-checks against it EXCEPT the two storage hooks on `ledgerTotal`: with a DERIVED contract as the
verified one, the CVL type-checker accepts no spelling of that mapping's user-defined key type
(**S-20**). Those hooks carry `ghostLedgerTotal`, which the delivery guards, `edgeLedgerDecomposition`
and the two-sided `flushForwardConserves` are stated over, so the conf and the spec were left at
their review-6 form rather than weakened to fit the harness. **Six local type-checks, no submission
spent, and still no verdict.** `contracts/FeeVault.sol` keeps the `virtual` keyword and
`certora/harness/FeeVaultHarness.sol` is kept as built.

## Score

| Spec | rules | review-4 | review-5 (first pass) | review-5b (second pass) |
|---|---|---|---|---|
| FeeVault | 26 to **30** | 22 of 26 verified | no verdict (2 jobs, refused at scene load) | **STILL NO VERDICT, blocked by P-1**, not submitted |
| RoundManager | 28 to **36** | 24 of 28 verified | no verdict (1 job, refused at scene load) | **31 of 36 verified** |
| FamilyHook | 23 to **23**, of which **2 disabled** | 20 of 23 verified | no job reached the server (CVL type error, S-8) | **17 of the 21 that ran, verified** |
| Sleeve | 10 | review-3 verdicts stand | not run | not run (untouched by the review-5 diff) |

**Review 5f adds no column, because it adds no verdict.** Its two jobs are two more refusals of
`FeeVault.conf` at scene load, and they are recorded as findings about P-1 rather than as evidence
about any rule. **Review 6 adds no column either, for the same reason**: two more refusals at scene
load, one lever refused locally before it could be submitted, and **0 of FeeVault's 30 rules
verified**. The FeeVault column of every table in this file still reads "blocked, P-1".

**Review 5g adds no column and no submission either:** its lever was refused by the LOCAL
type-checker before it could be submitted (S-20), exactly as review 6's third lever was (S-19).
FeeVault stays at **0 of 30 rules verified**.

Every FamilyHook and RoundManager verdict in the tables at the end of this file is from the review-5b
jobs and is evidence about the contracts at this HEAD. Every FeeVault cell is empty of evidence and
says so. The review-4 column is history and is evidence about the review-4 contracts, which is this
project's own standing lesson (S-4).

**Sanity.** `rule_sanity: basic` ran on both jobs and no rule that reported verified failed its
vacuity check. That check is the reason two of this project's earlier findings exist, so it is
recorded here rather than assumed.

## P-1. The Prover refusal, which is what this pass actually found

Every submitted job died with:

```
Encountered an unexpected error in Prover, please report in certora.com. Error code 1693402113.
Error message: Got exception while transforming FeeVault-receiveForward(uint256,uint256)
```

and, one frame down:

```
analysis.pta.PointsToAnalysis ... Caused by: analysis.PointsToInvariantViolation:
Broken invariant, in concrete mode we are accessing a pointer value or we think we should ignore a write
... analysis.alloc.ReturnBufferAnalysis.rewriteConstantSizeAllocation
```

**The trigger is a review-5 change to that function, and it is the ERC-20 re-denomination.** At
review 4, `receiveForward(uint256 attribution)` was `payable`, took `msg.value`, and made no external
call at all. At review 5 it is `receiveForward(uint256 attribution, uint256 amount)` and carries the
delivery guard `if (ledgerTotal[edge] > holdings(edge)) revert NotDelivered();`. `holdings` is two
external calls whose return buffers have to be decoded into memory, and decoding a constant-size
return buffer is exactly the analysis that crashes. The same crash, on the same method, appears in
`RoundManager`'s job as well, because `FeeVault.sol` is compiled into all three of the big confs.
`FamilyHook.conf` compiles it too, so the third spec is blocked by the same defect.

This is a defect in the Prover, not in the contracts and not in the specs. `receiveForward` compiles
under solc `0.8.26` with the same settings foundry builds with, and the guard it added is a
review-5b delivery check that the unit and fuzz tiers exercise.

**WHAT THE SECOND PASS ESTABLISHED ABOUT P-1, and it is worth more than the two levers below.** The
crash is in SCENE LOADING, so it is decided entirely by which files a conf compiles, and by nothing
in the specs. `FamilyHook.conf` and `RoundManager.conf` were compiling `FeeVault.sol` for a link, not
for a claim: `RoundManager.spec` already summarized the vault's only entrypoint into it
(`_.depositEdgeBidEarmark(uint256) => NONDET`), and `FamilyHook.spec` already had a `_.accrue(...)`
wildcard summary beside its exact `FeeVault.accrue` entry. Drop the file and the link from both, and
both scenes load and both jobs run to completion in seven minutes and two hours respectively. So:

- P-1 is **CONFIRMED to be about that one file**, not about the toolchain, the build settings, the
  specs or this machine. Two jobs on the same CLI version, the same solc, the same conf settings and
  two of the same three contracts loaded without complaint.
- The block is therefore **exactly as wide as `FeeVault.sol`'s presence in a scene**, which makes
  workaround (a) in `private/certora/SUPPORT-P1.md` (summarize the edge token's `balanceOf`, so the
  return buffers the analysis chokes on are never decoded) the right next thing to try, and makes
  moving contract code for the Prover's benefit still a last resort.
- It also means `FeeVault.spec` is the ONLY thing P-1 costs this project now, rather than three
  quarters of the tier.

**WHAT THE THIRD PASS ESTABLISHED ABOUT P-1, and it narrows the defect further than either of the
two passes before it.** Review 5f attacked the crash from both sides of the call, and neither side
is where it lives:

- The CALLEE does not matter. With the link and `MockDoll` gone and the edge token's `balanceOf`,
  `transfer` and `transferFrom` all answered by a ghost-backed CVL summary, the job crashed in the
  same analysis, on the same method, at the SAME crashing block id as the review-5 job (S-14). So
  the analysis is not reading anything about the resolved ERC-20; it is failing inside the transform
  of `FeeVault.receiveForward` itself.
- The EXPRESSION SHAPE does not matter either. With `holdings` rewritten so that each of its two
  external calls sits in its own statement behind its own single-call `private view` reader, and
  with each delivery guard hoisting the read into a local, the crashing block id MOVED (so the new
  code really was analysed and this was not a cached replay) and the crash was otherwise identical
  (S-15).

Taken together: the trigger is the PRESENCE of the two balance reads on that method's path, not how
they are written or how their callee resolves. Nothing short of removing a read (which would change
what the guard checks) or a Prover fix is going to move it, which puts the whole of `FeeVault.spec`
behind the support report and a newer `certora-cli`.

**Two levers were tried against it in the FIRST pass, and both were read as answered in the
negative. The second half of that reading is WITHDRAWN by S-16:**

1. **The custom Yul optimiser sequence was removed**, on the theory that the full inliner it restores
   produces memory layouts the Prover's analysis was never meant to read (the Prover drops that
   inliner from its own sequence deliberately). The job failed identically **and reported the same
   cache key as the run before it**, so the setting is INERT at review 5: it changes nothing about
   the code the Prover sees. A side result worth keeping: the three big contracts now compile
   cleanly WITHOUT that sequence, so the "stack too deep" the setting was added for is gone.
2. **The two autofinder switches were removed**, on the theory that the analysis that crashes is fed
   by the annotations those switches suppress. The local build changed (the instrumentation warnings
   appear) and the job failed identically, again under the same cache key.

That the reported cache key did not move across three materially different builds is itself worth
recording: either the key is not derived from the build, or all three jobs replayed one cached,
already-crashed analysis. Either reading leads to the same next step, which is review-6 item 1.

## Budget

The cap is **3 initial runs plus 3 re-runs**, and review 5f spent **two more on the two P-1
workarounds**, with nothing else left to learn from them. **8 of 8 with two P-1 workaround runs.**
**Review 6 carries its own cap of 4 submissions and spent 2 of them**, both on `FeeVault.conf`: one
per lever that could be submitted at all. The third lever never reached the server, because the local
type-checker refused it for free (S-19), which is the JDK-21 line paying for itself a third time.
**Review 6: 2 of 4.** **Review 5g: 0 submissions**, and six local type-checks.

| # | Pass | Class | Spec | Outcome |
|---|---|---|---|---|
| 1 | first | initial | FeeVault | FAILED, P-1 |
| 2 | first | initial | RoundManager | FAILED, P-1 |
| 3 | first | re-run | FeeVault, custom Yul sequence removed | FAILED, P-1, same cache key |
| 4 | first | re-run | FeeVault, autofinders on | FAILED, P-1, same cache key |
| 5 | **5b** | initial | **FamilyHook**, `FeeVault.sol` out of the scene | **SUCCEEDED. 17 of 21 run rules verified**; 7 minutes |
| 6 | **5b** | re-run | **RoundManager**, `FeeVault.sol` out of the scene | **SUCCEEDED. 31 of 36 verified**; 2 hours |
| 7 | **5f** | workaround | **FeeVault**, edge token summarized instead of linked (support report workaround (a)) | FAILED, P-1, same crashing block as run 1 (S-14) |
| 8 | **5f** | workaround | **FeeVault**, `holdings` and the delivery guards restructured in the contract | FAILED, P-1, crashing block moved but the crash did not (S-15); the contract change was REVERTED |
| 9 | **6** | workaround | **FeeVault**, `-relaxedPointerSemantics FeeVault:receiveForward` | FAILED, P-1, IDENTICAL crashing block id (S-17) |
| 10 | **6** | workaround | **FeeVault**, compiled differently (via-IR at `solc_optimize: "1"`, no custom Yul sequence) | FAILED, P-1, crashing block id MOVED and the crash did not (S-18) |
| n/a | **6** | not submitted | **FeeVault**, internal CVL summary of `holdings` | REFUSED LOCALLY, no submission spent: `holdings` is `public` and has no internal entry to summarize (S-19) |
| n/a | **5g** | not submitted | **FeeVault**, verification-only harness overriding `holdings` | REFUSED LOCALLY, no submission spent: the two `ledgerTotal` hooks cannot be typed against a derived verified contract (S-20) |
| n/a | all | not submitted | Sleeve | untouched by the diff, bounds not tightened, buys nothing |

The first pass stopped with two submissions unspent rather than gamble them on a defect that had
already refused three builds of the same bytecode. The second pass spent exactly those two, on the
one lever that was not a gamble: it removes the crashing file from the scene rather than hoping the
crash goes away. **No submission remains for review 5. `FeeVault.spec` waits for review 6, and the
first thing review 6 does is send the support report** - which review 5f has now made considerably
shorter to answer, because it rules out both of the workarounds that report proposed.

**The JDK 21 line in review-4's checklist paid for itself twice.** In the first pass it caught
`FamilyHook`'s CVL error (S-8) for free. In the second it caught finding S-10 across FIVE local
type-check attempts, each of which would have been a burned submission under review-4's JDK 17, and
there were only two submissions left to burn. Local type-checking is what made a five-probe
experiment affordable at all.

## Findings

**ONE FINDING ABOUT THE CONTRACTS, C-1. It was not patched during this pass; it was fixed at review 5e (see its status line below).** The brief for the second pass was
to report a genuine contract finding and stop, not to fix it, and that is what happened. Four
specification findings and one build-settings finding sit beside it, and review 6 adds three more
(S-17, S-18, S-19), all of them about the Prover and the specs rather than about the contracts.
**Review 6 found no contract finding, because no rule about the vault has ever been checked.**

### C-1 (CONTRACT). `RoundManager.adoptGenesis` can be run twice if it is first run with `address(0)`

**Rule:** `adoptGenesisIsOnceAndFactoryOnly`, VIOLATED on its first assertion, "the genesis link was
adopted twice". This rule is NEW at review 5, written for REVIEW5_DESIGN decision 1, and this is the
first run it has ever had.

**The scenario, from the Prover's own counterexample.** `adoptGenesis(token, creator)` guards itself
with

```solidity
if (_head != address(0) || priorRegistry != address(0)) revert GenesisAlreadyRegistered();
```

and then seats the token: `_canonical[0] = token; _indexOf[token] = 0; _isCanonical[token] = true;
_head = token; _headIndex = 0;`. Call it once with `token == address(0)` on a fresh trunk
(`priorRegistry == 0`) and every one of those writes happens, the `GenesisAdopted` event is emitted,
and `_head` is still `address(0)`. The once-only guard therefore does not hold, and a second
`adoptGenesis` of any token by the factory succeeds and re-seats canonical index 0, a new head, a new
index-0 creator and a new edge currency. The same counterexample drops out of `canonicalIsWriteOnce`,
`historyEntriesAreImmutable` and `reverseIndexIsConsistent`, all three of which fail on
`adoptGenesis` with "an existing entry was re-parented".

**The cause, stated as a cause and not as an effect.** The write-once flag for adoption is
`_head != address(0)`, i.e. the SENTINEL VALUE OF A DATA FIELD is doing the job of a boolean. That is
only sound while the data field can never legitimately take the sentinel, and nothing in this
contract enforces that. `RoundManager` has no `token != address(0)` check on the one entrypoint that
decides the edge currency for the whole chain.

**Reachability under the PRODUCTION configuration, traced one hop past the boundary.**
`adoptGenesis` is `onlyFactory`, and the only caller in the tree is `FamilyFactory._adoptGenesis`,
which passes the immutable `GENESIS_TOKEN`. The factory constructor refuses a zero or codeless token
(`if (_genesisToken == address(0) || _genesisToken.code.length == 0) revert BadGenesisToken();`) and
`_adoptGenesis` additionally reads `decimals()` and `totalSupply()` off it and carries its own
one-shot `genesisAdopted` flag. **So on the deployed wiring the zero-address path is unreachable, and
this is a LATENT finding rather than a live one.** It is the same class this project has recorded
before: unreachable as deployed, and worth fixing anyway because the guard belongs where the claim is
made.

**Why it is still worth reporting.** `RoundManager` states adoption-is-once as ITS OWN property (it
raises `GenesisAlreadyRegistered`), while the factory constructor is what actually enforces it. That
is a guard living one contract away from the invariant it protects, which is exactly the seam a
component-scoped review does not see. If a future factory, a redeployment, or a differently wired
stack ever calls `adoptGenesis` without that constructor check in front of it, the chain seats
`address(0)` as its edge currency and can be re-seated at will.

**Status: fixed in review 5e** (dedicated adoption flag and zero-address refusal in `RoundManager.adoptGenesis`). At the time of this run, `contracts/` was untouched.

### S-10 (SPEC). The `PoolId` key type of an `Sload` hook cannot be named in CVL, and this REVERSES S-8

`FamilyHook.spec`'s two `Sload` hooks on `registeredPools[...].isEdge` and `.tradingStart` do not
type-check in any spelling. `PoolId` is a FILE-LEVEL user-defined value type over `bytes32` in
`lib/v4-core/src/types/PoolId.sol`, and the local type-checker rejects all of these with the same
message, *"keys to FamilyHook.registeredPools should have type PoolId but id has type PoolId"*:

| spelling tried | scene | result |
|---|---|---|
| `IFamilyHook.PoolId` | hook + manager | rejected |
| `FamilyHook.PoolId` | hook + manager | rejected |
| `RoundManager.PoolId` | hook + manager | rejected |
| `FamilyHook.PoolId` | hook ALONE | rejected |
| `PoolIdLibrary.PoolId`, with `PoolId.sol:PoolIdLibrary` added to the scene so the DECLARING contract could be named | hook + library | rejected |
| bare `PoolId` | any | "PoolId is not a valid EVM type" (read as an uninterpreted sort) |
| `bytes32` | any | "... but id has type bytes32" |

Two controls rule out the obvious explanations. It is **not about struct fields**: a probe hook on
`obsCount`, a plain `mapping(PoolId => uint256)` in the same contract, is rejected identically. It is
**not about scene composition**: the rejection is the same with one contract in the scene and with
three. The neighbouring construction that DOES work is `FeeVault.spec`'s long-standing
`ledgerTotal[KEY FeeVault.Currency c]`, where `Currency` is a file-level value type over ADDRESS,
which is why this is recorded as being about the underlying type rather than about the mapping shape.

**This reverses S-8.** S-8 read the same rejection as a naming defect in the spec and recorded
`IFamilyHook.PoolId` as the accepted spelling. That spelling does not type-check, and the earlier
probe that appeared to accept it cannot be reproduced. **Treat S-8 as WITHDRAWN.** The lesson it
leaves behind is the honest one: a type-check that passed once, under a scene that has since changed,
is not evidence; run it again.

**What it costs, and what was done instead of letting it pass.** The fallback the authoring pass
wrote down in advance as first-run risk 2 is taken: `protocolFeeOnlyAtTheEdge` (FEE-01's per-pool
half) and `theEdgeFeeIsSuppressedDuringTheSnipeWindow` (FEE-06's time half) have NO OBSERVABLE at
this tier, because CVL cannot compute `key.toId()` to fetch the pool the swap hit and cannot read it
through a hook either. Both rules are **commented out in the spec with a restore note**, NOT
weakened: with the ghosts unwritten they would have reported "not violated" while proving nothing,
which is this project's own tautology lesson. Both properties fall back to
`test/properties/Fees.prop.t.sol` and the review-5 unit tests and are recorded as **not expressible
here**, not as unproved. The question is in the support report for Certora.

### S-11 (SPEC). `summedRatesStayBelowOne`'s third assertion is stated over an unpinned immutable

VIOLATED, and only on the third of its three assertions: *"the three rates no longer overlap, so the
suppression below may be obsolete"*. The first two assertions pass.

`hopFeePpm` is an IMMUTABLE, so the Prover starts from arbitrary storage with the constructor never
run, and the rule's only constraint on it is the ceiling `require hopFeePpm() <= MAX_HOP_FEE_PPM()`.
The constructor guard is an UPPER bound only (`_hopFeePpm > MAX_HOP_FEE_PPM` reverts), so the Prover
is free to choose `hopFeePpm == 0`. At zero,
`PROTOCOL_FEE_PPM + SNIPE_START_PPM + hopFeePpm` is exactly 1000000 and the assertion's `> 1000000`
fails on both disjuncts. The deployed hop fee is 750 ppm, at which the assertion is true.

**Class: specification, not contract.** It is the same shape as review-2's fix to
`bondIsMonotoneInDepth`, which needed `BOND_DOUBLING_EVERY` pinned to its deploy constant. The remedy
is one line (`require hopFeePpm() > 0`, or pin the deploy constant), and it is a review-6 item rather
than a re-run, because there is no submission left. **Note what this does NOT say:** the two
assertions that carry FEE-04's actual arithmetic claim, the pairwise bounds, are **verified**.

### S-12 (SPEC). `noTransitionIsPrivileged`'s exclusion list is short by review-5's new entrypoints

VIOLATED on `claimRefund`, `finalize`, `flushForfeits`, `fulfilEnd`, `pushForfeit` and `pushRefund`;
verified on `finalizeDeterministic` and `requestEnd`; **UNKNOWN** on `submitScore`, which is the
tractability timeout that has been open since review 1 (the solver died after 80 splits at about 23
percent proved). The rule runs the same call from two different senders on the same storage and
asserts that they agree on reverting.

Two of the six are a WRONG CLAIM by this rule, and the spec next door proves it:

- **`pushRefund` and `pushForfeit` are caller-restricted BY DESIGN**, to `address(this)`. That is
  review-5b's `try this.pushRefund(...)` construction, and `theBondPushesAreSelfOnly` is **verified**
  in the same job. A rule asserting that no caller is privileged, over two entrypoints another rule
  proves are self-only, is asserting something the contract never claimed. Same class as S-3 and S-7.
- **`claimRefund(address)` is a PER-CALLER PULL CLAIM**: it reads `pendingRefund[msg.sender]` and
  reverts `NothingToClaim` at zero. Two different senders differing is the designed behaviour.

The other three (`finalize`, `flushForfeits`, `fulfilEnd`) are most plausibly MODELLING rather than
either: each makes an external call this spec summarizes NONDET (`transfer`, `depositEdgeBidEarmark`,
the randomness source), and a NONDET summary is free to answer differently in the two executions, so
the revert outcomes can differ for a reason that has nothing to do with the caller. **That reading is
NOT confirmed by a run** and is listed in the unknowns below; it needs the behaviour of summaries
under the `at init` storage snapshot checked, which is a review-6 experiment.

### S-13 (REACHABILITY). FEE-01's ladder fails identically with the vault UNLINKED

The three `satisfy` rungs that need the vault call to happen are all VIOLATED -
`anyFeeAccrualIsReachable`, `someProtocolFeeIsReachable`, `oneProtocolFeeAtTheEdgeIsReachable` -
while the two rungs below them, `beforeSwapIsReachable` and `theFeeMintIsReachable`, are
**verified**. So execution reaches `_collect`'s `poolManager.mint(feeVault, ...)` and does not reach
the `IFeeVault(feeVault).accrue(...)` one line later, exactly as at review 3 and review 4.

**The new information is that this is now measured with the vault NOT LINKED and with review-4's
exact `FeeVault.accrue` summary entry GONE**, leaving only the `_.accrue(...)` wildcard. Three
hypotheses are therefore dead, and this answers the first half of review-6 checklist item 2:

1. it is not the linked callee shadowing the wildcard, because there is no linked callee now;
2. it is not exact-versus-wildcard precedence, because there is no exact entry now;
3. it is not signature matching on the exact entry, which review 4 had already answered.

What is left, and what review 6 should test first, is the remaining half of that item: that
`optimistic_fallback` swallows the vault call as an unresolved call before any summary is consulted,
in which case the counter has no writer for a reason that is a conf setting. The `Sstore`-hook
experiment on the vault's own `ledgerTotal` cannot be run from this spec now that the vault is out of
the scene, so it needs `FeeVault.conf` unblocked first, which puts it behind P-1. **FEE-01's per-pool
half stays UNPROVED here**, and with S-10 it now has no rule in this tier at all; it is a fuzz and
fork property until both are cleared.

### The three history rules, and why their residual is NOT counted as new

`canonicalIsWriteOnce` (base, transient step and 15 of 17 methods verified),
`reverseIndexIsConsistent` (base, transient step and 14 of 17) and `historyEntriesAreImmutable` (14
of 17) fail on `adoptGenesis`, `finalize` and, for two of them, `addCandidate`, with "an existing
entry was re-parented" and "assert weak invariant in post-state". Two causes are tangled here and
this pass can separate them only partly:

- the `adoptGenesis` leg is **C-1**, straightforwardly: the counterexample re-seats index 0;
- the `finalize` and `addCandidate` legs are the **review-4 residual**, checklist item 3: these rules
  are stated against the DELEGATING getters (`canonical`, `parentOf`, `indexOf`, `headIndex`), all of
  which answer from the prior registry while `!adopted`, so a method that can flip that decision
  mid-rule produces a counterexample about the model rather than about the code. That item has been
  open since review 4 and carries forward unchanged.

**Neither reading is confirmed by a second run, because there is no submission left.** The honest
statement is that C-1 is proved (its own rule names it, with a call trace) and that the split of the
remaining legs is inferred.

### Unknowns, and what would close each one

| unknown | why it is open | evidence that would close it |
|---|---|---|
| Whether `finalize`, `flushForfeits` and `fulfilEnd` fail `noTransitionIsPrivileged` for the NONDET-summary reason given above | inferred from the summaries on those paths, not read end to end from a call trace | a run with those three summaries replaced by deterministic ghost-backed ones; if the three legs then verify, the reading is confirmed |
| Whether the `finalize` and `addCandidate` legs of the three history rules are entirely the review-4 delegating-getter residual | C-1 explains the `adoptGenesis` leg and could also reach the others through the shared pre-state | restate the three rules against LOCAL storage (review-6 item 4) and re-run; whatever still fails is a different cause |
| Whether `FeeVault.spec` holds at all at review 5 | P-1; no job has ever loaded that scene. Review 5f ruled out both workarounds the support report proposed (S-14, S-15) and review 6 ruled out all three of the remaining documented levers (S-17, S-18, S-19) | a `certora-cli` newer than 8.19.2, or a fix from Certora. **Nothing in this project's own hands is left to try**, and that is now measured rather than assumed: five distinct workarounds across two passes, all refused |
| Whether `optimistic_fallback` is what swallows the vault call (S-13) | the remaining hypothesis, untested | one run with `optimistic_fallback` off, watching the two lower rungs stay reachable |
| Whether S-11 is the ONLY reason `summedRatesStayBelowOne` fails | the first two assertions passed and the third names the hop fee, but only one counterexample was read | pin `hopFeePpm` to its deploy constant and re-run |
| Whether `submitScore` satisfies `noTransitionIsPrivileged` | UNKNOWN: the solver died after 80 splits at about 23 percent proved | more SMT budget or different splitting settings; open since review 1 |
| Whether C-1 is reachable through any caller other than the factory | `onlyFactory` was read, and the whole tree was searched for callers of `adoptGenesis` | nothing further; this one is closed, and the answer is no |

### S-14 (PROVER). Support-report workaround (a) does NOT get past P-1, and the callee is not the cause

`FeeVault.conf` dropped `test/utils/MockDoll.sol` from `files` and the `FeeVault:EDGE=MockDoll` link
with it, and `FeeVault.spec` answered the edge token's `balanceOf`, `transfer` and `transferFrom`
with a GHOST-BACKED CVL summary keyed by (token, holder): a read returns the ghost, a transfer moves
it, and an amount above the sender's modelled balance returns false rather than being assumed away.
That summary is not a weakening dressed up as a workaround: it keeps both properties the link was
there for, a balance that is consistent between two reads in one state and a balance that FALLS on a
payout, which is the whole content of `valueLeavesOnlyOnPayoutMethods`. It type-checked locally on
the first try.

**The job failed with the identical P-1**, in the same analysis
(`ReturnBufferAnalysis.rewriteConstantSizeAllocation`), on the same method
(`FeeVault.receiveForward(uint256,uint256)`), and **at the same crashing block id** as the review-5
initial run. That last detail is the finding: if the resolved ERC-20 were what the analysis choked
on, removing it from the scene would have changed where the transform died. It did not change
anything at all. **The callee is not the cause**, and workaround (a) is answered in the negative.

The spec and conf changes were reverted with the result. They are recorded here and in
`private/certora/JOBS-review-5.md` so that nobody spends a ninth submission re-running them.

### S-15 (PROVER). The contract restructure does NOT get past P-1 either, and it was REVERTED

The last resort in the support report was to change the contract into a shape with no two
external-call return buffers in one expression. It was done and measured: `holdings` was rewritten so
that each of its two external calls sits in its own statement behind its own single-call
`private view` reader (`_tokenBalanceOf`, `_claimBalanceOf`), and `receiveForward`,
`depositEdgeBidEarmark` and `flushForward` each hoisted their read into a local before comparing.
Same two calls, same order, same sum, same reverts, same events; the full suite passed (346 passed,
0 failed, 1 skipped, fork tests excluded) and `FeeVault`'s runtime size was 16,807 bytes, comfortably
under EIP-170.

**The job failed with the identical P-1.** The crashing block id DID move
(`8222_1001_0_0_0_0` to `8249_1001_0_0_0_0`), which proves the restructured code really was the code
analysed and that this was not a cached replay of an earlier crash. The crash itself did not move.

**Status: the contract change is REVERTED and `contracts/FeeVault.sol` is untouched by this pass.**
This project does not carry a change made for a tool's benefit that did not benefit the tool, which
is the same rule that left the two S-9 build settings in place. The measurement is the deliverable.

### S-16 (BUILD). The `-cache` string is not derived from the sources, which WITHDRAWS half of S-9's evidence

Review 5 recorded that two build levers were "inert" partly because **the reported cache key did not
move** across three materially different builds, and flagged that as something to ask Certora about.
Review 5f answers it from this project's own artefacts. The string in question is the `-cache` token
in the Prover's command line, and across the five `FeeVault` jobs it behaves like this:

| job | conf and spec | contract source | `-cache` token |
|---|---|---|---|
| review-5 initial run 1 | review-5 form | review-5 form | `8e79013...` |
| review-5 re-run 1, no custom Yul sequence | conf edited | review-5 form | `8e79013...` |
| review-5 re-run 2, autofinders on | conf edited | review-5 form | `8e79013...` |
| review-5f attempt 1 | `files` and `link` edited, spec edited | review-5 form | `70a1519...` **moved** |
| review-5f attempt 2 | review-5 form | RESTRUCTURED | `8e79013...` **did not move** |

The token moves when the conf's `files` and `link` change and does NOT move when the contract source
changes underneath an unchanged conf. **So it is not a content hash of the build, and "the cache key
did not move" is not evidence that a build did not change.** The artefacts that ARE evidence are the
per-transform cache keys in `Reports/CacheEvents.txt` (attempt 2 reports cache MISSES on the
transforms it had to redo) and the crashing block id, which moved for attempt 2 and had ALSO moved
for review 5's own no-Yul-sequence re-run (`5432_1007_0_0_0_0` against `8222_1001_0_0_0_0`).

**What this changes about S-9.** Both settings are still measured as not fixing anything, and that
half stands on the jobs failing identically. What is WITHDRAWN is the inference that the builds were
byte-identical: review 5's no-Yul-sequence build demonstrably produced different code and crashed
anyway. The question for Certora shrinks from "why did the cache key not move" to nothing at all,
and one question comes off the support report.

### S-17 (PROVER). The Prover's own escape hatch for this analysis does NOT get past P-1

The Prover changelog (5.0.5, 21 November 2023) documents `-relaxedPointerSemantics`, "an option
accepting a comma-separated list of `contract:methodWithoutParamTypes` pairs where the points-to
analysis is allowed to be less strict". P-1 is raised by `analysis.pta.PointsToAnalysis`, on one
named method. So the flag names exactly the analysis that crashes and exactly the method it crashes
on, it is the vendor's own documented relaxation for it, and it changes nothing about the contracts,
the compilation or any rule's statement. It went in as
`"prover_args": ["-relaxedPointerSemantics FeeVault:receiveForward"]`, and the job's own
`jarSettings` confirm the Prover received it.

**The job failed with the identical P-1, at the IDENTICAL crashing block id** (`8222_1001_0_0_0_0`,
the same one the review-5 initial run and review 5f attempt 1 died at). The stack says why the flag
could not help: the exception is thrown from `ReturnBufferAnalysis.rewriteConstantSizeAllocation`,
inside `PatchingTACProgram.replaceCommand`, as `IllegalArgumentException: CmdPointer(block=...,
pos=0) is not in this program`. **The failure is in the ALLOCATION REWRITE that the points-to
results feed, not in points-to strictness**, and relaxing the latter leaves the former exactly where
it was.

Nothing was kept. `FeeVault.conf` carries a comment naming this lever so that nobody spends another
submission on it.

### S-18 (PROVER). Compiling the scene differently does NOT get past P-1 either

The last lever that touches neither the contracts nor the specs is HOW the scene is compiled: P-1 is
a crash over the code solc emits, so a different legal compilation of the same source is a different
input to the crashing analysis.

**Plain legacy codegen is not available here, and that is worth recording on its own.** Dropping
`solc_via_ir` and the custom `yul_optimizer_steps` while keeping `solc_optimize: "200"` does not
compile at all: `FamilyHook._collect` fails with "Stack too deep", which is the same wall that put
`via_ir` in `foundry.toml` in the first place. Measured locally, at no cost in prover minutes. So
via-IR stayed, the custom Yul sequence came out (S-9 measured that the contracts compile cleanly
without it) and the optimiser runs parameter dropped from `"200"` to `"1"`, which is what actually
moves the inlining and the memory layout the crashing analysis reads.

**The job failed with the identical P-1**, error code 1693402113, same analysis, same method. **The
crashing block id MOVED**, from `8222_1001_0_0_0_0` to `5401_1007_0_0_0_0`, which proves the
differently compiled code really was the code analysed and that this was not a cached replay. The
crash did not move.

This would have carried a real caveat if it had worked, and the caveat is recorded here because the
next person to reach for this lever will face it: `foundry.toml` builds the DEPLOYED bytecode at
`optimizer_runs = 200` with that Yul sequence, so a conf compiled any other way is no longer checking
the way the shipped bytecode is compiled. Rules are claims about the SOURCE and are discharged
against a legal compilation of it, which is what a claim about the contract's behaviour needs, but it
is NOT deployment-bytecode equivalence evidence. **Nothing was kept**: the conf is back to the
review-5 settings, which are foundry's.

One side result, which CONFIRMS S-16 from a third build: this job reported the SAME `-cache` token
(`8e79013...`) as the review-5 initial run while crashing at a different block id. The token tracks
the conf's file set, not the code. "The cache key did not move" remains worthless as evidence.

### S-19 (SPEC). An internal summary of `holdings` CANNOT BE WRITTEN, because `holdings` is `public`

The third lever was the sharpest one on paper. `FeeVault.holdings(Currency)` is the only pair of
external balance reads on `receiveForward`'s path, and P-1 is a crash rewriting a constant-size
RETURN BUFFER allocation. An internal CVL summary of `holdings` would take both calls, and therefore
both return buffers, off that path without changing one character of the contract:

```
function FeeVault.holdings(FeeVault.Currency c) internal returns (uint256) => cvlHoldings(c);
```

with `cvlHoldings` built from the terms the body actually sums: the LINKED edge token's real balance
for the edge currency (so a transfer still MOVES holdings, which is what the payout rules need), the
`ghostTokenBalance` consistent-read ghost for a symbolic currency, and the existing
`ghostClaimBalance` for the ERC-6909 claim, added with `require_uint256` so that the checked add's
revert is modelled as a pruned path rather than wrapped away. The conf's two autofinder switches came
out with it, since an internal summary cannot attach with the finders off, and
`function_finder_mode: relaxed` went in, which is the mode the changelog documents for internal
summaries under via-IR.

**It does not type-check, and it cannot be made to:**

```
Error in spec file (FeeVault.spec:112:5): Internal method entry
FeeVault.holdings(Currency c) returns (uint256) does not appear in code.
```

`holdings` is declared `public`. The Prover's internal-function finders instrument `internal` and
`private` functions; a `public` function is an external entry point, so there is no internal entry
for a summary to attach to. `.certora_build.json` confirms it: the only `holdings` records in the
build are external method records. The same error appears under `function_finder_mode: relaxed` and
under the default mode, and the spelling is not the problem either (`Currency` alone is rejected as
"not a valid EVM type"; `FeeVault.Currency` is the accepted spelling and produces the error above).

Making it work would mean declaring `holdings` `internal` behind a `public` wrapper in
`contracts/FeeVault.sol`, i.e. a contract change made for a tool's benefit. That is the class of
change S-15 already tried and reverted, and it is refused here without spending a submission.
**Cost: zero prover minutes.** The local type-check caught it, which is the third time JDK 21 on the
run machine has paid for itself.

### S-20 (SPEC). A DERIVED harness cannot carry this spec's `ledgerTotal` hooks, and that is what stopped review 5g

The sixth lever against P-1, and the first one that attacks the crash where it actually lives. P-1 is
a crash rewriting a constant-size RETURN BUFFER allocation while transforming `receiveForward`, and
the only return buffers on that path are the two external balance reads inside `holdings`. S-19
established that they cannot be summarized away, because `holdings` is `public`. A HARNESS can do
what a summary cannot: `certora/harness/FeeVaultHarness.sol` inherits `FeeVault`, forwards the
constructor arguments, and overrides `holdings(Currency)` with a single read of a verification-only
mapping. No external call anywhere in the override.

**The contract side is one word and it costs the deployment nothing.** `holdings` is now
`public view virtual`. `forge inspect FeeVault bytecode` and `forge inspect FeeVault
deployedBytecode`, captured before the keyword and again after a full rebuild with it, are
BYTE-IDENTICAL (37,306 and 34,068 characters, `0x` included, diffed rather than eyeballed), and the
suite is 346 passed, 0 failed, 1 skipped with `FeeVault` at 17,033 bytes, 7,543 under EIP-170:
`docs/security/full-suite-review-5g.txt`. This is why the keyword and the harness are KEPT even
though the lever did not fire, and it is the opposite of the S-15 case, where a contract change made
for the tool's benefit was reverted: that one changed the emitted code, this one provably does not.

**It does not type-check, and the obstacle is the same class as S-10.** With `FeeVaultHarness` as the
verified contract, the whole spec type-checks except its two storage hooks on `ledgerTotal`, whose
key is the `Currency` user-defined value type:

```
Error in spec file (FeeVault.spec:277:1): Type mismatch: keys to FeeVaultHarness.ledgerTotal
should have type Currency but c has type Currency
```

The expected type and the offered type PRINT THE SAME and are not the same type. Every spelling
available was tried, one local compile each:

| spelling tried | scene | result |
|---|---|---|
| `FeeVaultHarness.Currency` | harness + hook + manager + token | rejected |
| `FeeVault.Currency` | the same (the base is compiled as the harness's parent) | rejected |
| `FeeVault.Currency` | with `contracts/FeeVault.sol` ALSO listed in `files` | rejected, identically |
| `CurrencyLibrary.Currency`, with `lib/v4-core/src/types/Currency.sol:CurrencyLibrary` added so the declaring file is in the scene | + library | rejected |
| `FamilyHook.Currency` (a scene contract that imports the same type) | the same | rejected |
| `IFeeVault.Currency`, with the interface added to `files` | + interface | the interface has no bytecode, so the BUILD fails before the type-check |
| bare `Currency` | any | "Currency is not a valid EVM type" |

So the key type of an INHERITED, UDVT-keyed mapping has no name in CVL when the verified contract is
a derived one. This is S-10's lesson on a second type: `ledgerTotal[KEY FeeVault.Currency c]` is the
construction S-10 cited as the one that WORKS, and it works only while `FeeVault` itself is the
verified contract.

**Why the spec was not rewritten around it.** Those two hooks maintain `ghostLedgerTotal`, and seven
rules are stated over it, including the two delivery guards the review-5 design added, the
`edgeLedgerDecomposition` invariant and the two-sided `flushForwardConserves`. Re-stating them
against storage reads would change what they claim in the one place this spec has already been burned
(the mirrors exist because a `HAVOC_ECF` summary sits in the middle of the flush), and a pass whose
job is to get a verdict is not the pass to loosen seven rules on a guess. **The conf and the spec are
therefore UNCHANGED from review 6**, and `git diff` for this pass is the `virtual` keyword, the new
harness file, this record and the suite log.

**Cost: zero prover minutes, six local type-checks.** That is the fourth time JDK 21 on the run
machine has paid for itself, and the second lever in a row (with S-19) that the local type-checker
refused before the server could charge for it.

**What would unblock it**, in the order a later pass should try it: ask Certora for the spelling of an
inherited UDVT key (the question belongs in the support report beside S-10's `PoolId` question);
failing that, a harness that is not derived is not available here, because the override is the whole
mechanism. **Do not re-run the six spellings above.**

### S-8, WITHDRAWN

Recorded at the first pass as "the two `Sload` hooks named the wrong `PoolId`, and the accepted
spelling is `IFamilyHook.PoolId`". **It is withdrawn: that spelling does not type-check.** See S-10,
which replaces it.

### S-9 (BUILD), unchanged

Two build settings in the three big confs no longer do what their comments say. The custom
`yul_optimizer_steps` sequence is inert (an identical cache key with and without it) and the
contracts compile cleanly under the Prover's own sequence; the build is likewise clean with the two
autofinder switches removed. Both settings were added to defeat a "stack too deep" that the review-5
contracts no longer produce. **The confs are left UNCHANGED on this point**, because neither removal
fixed anything and an unjustified build change is not worth carrying. The review-5b measurement adds
one line to it: both settings were carried unchanged into the two jobs that SUCCEEDED, so they are
not what was blocking anything either.

Carried forward from the re-derivation, before any run: **S-6** (a summary that matched nothing) and
**S-7** (an enumeration one writer short), both described below. Carried from earlier passes and
still true: **S-1** (a `loop_iter` below a structure's real depth makes rules vacuous), **S-2**,
**S-3**, **S-4** (a green rule is only evidence about the code it was written against), and **S-5**
(`noPayoutPathCanBurnTokensAtTheZeroAddress` needs `amount > 0`, still never checked by a run).

## What review 5g did, and what is left after it

Review 5g built the sixth lever, measured that it cannot be typed, and spent no submission on it
(S-20). It leaves two things behind for review 7: `contracts/FeeVault.sol` marked `virtual` at
`holdings` (bytecode-identical, so it costs nothing to carry) and
`certora/harness/FeeVaultHarness.sol` ready to use the moment CVL can name the key type of an
inherited UDVT-keyed mapping. **Add that question to the support report beside S-10's.** Everything
below is unchanged by this pass.

## What review 6 did, and what is left after it

Review 6 took item 1 below as far as this project can take it without Certora. Items 2 to 8 are
untouched by it and carry forward to review 7 unchanged.

1. **SEND THE SUPPORT REPORT. It is now the ONLY thing left, and review 6 proved it rather than
   assumed it.** The report is drafted at `private/certora/SUPPORT-P1.md` and is ready to send from
   the review identity; it carries the error, the function, what changed, the job ids and the levers
   ruled out. **FIVE workarounds have now been measured and every one is refused.** Review 5f ruled
   out the two the report proposed: the CVL summary of the edge token's `balanceOf` (S-14, and the
   crash did not move by a single block id, so the callee is not the cause) and the contract
   restructure (S-15, measured and reverted). Review 6 ruled out the three that were left:
   `-relaxedPointerSemantics`, the Prover's own documented relaxation for this analysis and this
   method (S-17, identical crashing block id), a verification-only compilation change (S-18, the
   block id moved and the crash did not), and an internal summary of `holdings`, which cannot be
   written at all because `holdings` is `public` (S-19, refused locally, no submission spent). The
   only remaining lever this project can pull by itself is **a `certora-cli` newer than 8.19.2**,
   because this is a Prover-internal crash. **Do not spend a submission re-running any of the five**;
   all are recorded with their job ids, and `FeeVault.conf` names them inline.
2. ~~**Decide C-1.**~~ **DONE at review 5e.** It was a latent, unreachable-as-deployed contract
   finding. The fix taken is the second of the two options listed here: `RoundManager` holds a real
   write-once `_genesisAdopted` boolean instead of reading `_head` as a sentinel, and
   `adoptGenesis` refuses `token == address(0)` explicitly. The `adoptGenesis` legs of
   `canonicalIsWriteOnce`, `historyEntriesAreImmutable` and `reverseIndexIsConsistent` should clear
   with it on the next pass that gets a verdict, which is how the fix gets checked.
3. **Fix the three specification defects this pass found, none of which needs a design decision.**
   S-11: pin or lower-bound `hopFeePpm` in `summedRatesStayBelowOne`. S-12: add `pushRefund`,
   `pushForfeit` and `claimRefund` to `noTransitionIsPrivileged`'s exclusion list, with a comment
   naming `theBondPushesAreSelfOnly` as the rule that carries the self-only claim instead. S-10: ask
   Certora for the `PoolId` spelling (the question is in the support report) and restore the two
   hooks and the two rules together, never one without the other.
4. **S-13 leaves FEE-01 one experiment from an answer, and it is a conf setting.** Turn
   `optimistic_fallback` off for one `FamilyHook` run and watch whether `anyFeeAccrualIsReachable`
   becomes reachable while rungs 0 and 0.5 stay reachable. The linked-callee and exact-summary
   hypotheses are both dead now.
5. **State the history rules against LOCAL storage, not the delegating getters** - review-4 item 3,
   still open. C-1's leg left the residual when review 5e replaced the sentinel.
6. **Everything on the review-5 checklist that `FeeVault.spec` carries is still untested**, because
   that spec has never run: FEE-01's `ledgerTotal` store experiment, S-5's `amount > 0`, `solvency`
   and `edgeLedgerDecomposition` on the accrual path, and the review-5 delivery guards. All of it is
   behind item 1.
7. **Sleeve bounds one power of two tighter**, and **a `BidDeployer.spec`** - both unchanged from the
   review-5 list, and both still outside the crowded part of the budget.
8. **Re-measure S-9 only if something else needs a run anyway.** Two settings that exist to defeat a
   compile error that no longer happens can be deleted, but they were carried unchanged into two
   SUCCEEDING jobs, so they cost nothing and the measurement buys little. Review 6 adds one half of
   an answer: the custom Yul sequence can indeed come out (the scene still compiles without it), but
   `solc_via_ir` itself CANNOT, because `FamilyHook._collect` is stack-too-deep under legacy codegen
   (S-18).

## Why the whole set was re-derived instead of re-run

Review 4's standing lesson, learned as finding S-4: **a green rule is only evidence about the code it
was written against.** The review-5 diff re-denominates every ledger in the protocol from native ETH
to an adopted ERC-20, deletes a whole pool class (there is no genesis pool, so there is no
`isGenesis`, no `nominalEnd == 0` freeze exemption and no `GenesisHasNoSnipeWindow`), turns two
payable entrypoints into non-payable token deposits with an `amount` argument, adds a second thing
the RoundManager owes out of one balance, and puts a reentrancy guard on two factory entrypoints.
Re-running the review-4 specs against that would have reported contract regressions that are really
spec drift, and loosening them until they passed would have hidden a real one.

So each rule was re-derived from the review-5 design decisions and the contract signatures, and each is
marked below as unchanged, re-based, renamed, corrected, new or deleted.

## What the re-derivation found before any run

Two things, neither of them a contract defect, both of the class that only a re-derivation finds:

- **S-6, a summary that matched nothing.** `RoundManager.spec` summarized `_.isMock()` from review-1
  through review-4 and no contract in this tree has ever declared that function
  (`IRandomnessSource` is `pin` / `fulfil` / `status`). A summary that matches nothing is silent: it
  neither fires nor complains, and four passes of "the randomness source is summarized, per
  PROPERTIES section 6" were one third less true than they read. Replaced with `_.status(bytes32)`,
  which is the read that exists.
- **S-7, an enumeration one writer short.** `FeeVault.spec`'s `onlyAccrualPathsCredit` listed the
  methods that may raise a ledger and did not include `flushForward`. Review 4b gave `flushForward` a
  dead-successor branch that calls `_book`, i.e. that credits dev / creator / sleeve / reinforce out
  of the queue, and the rule has been reported **verified** since. This is the same shape as S-4
  (`flushForwardConserves`) on the neighbouring rule, missed at the time. Corrected; the value is not
  created, it moves from `pendingForward` into the local ledgers, and `flushForwardConserves` is what
  bounds the move.

## Two first-run risks, with their fallbacks

Neither is a claim about the contracts. Both are about whether the Prover accepts the construction,
and both are the reason the budget reserves a re-run for type-check and link failures first.

1. **The `EDGE` link** (`certora/conf/FeeVault.conf`, `FeeVault:EDGE=MockDoll`) is the first link in
   these confs onto an immutable of a USER-DEFINED VALUE TYPE (`Currency` over `address`) rather than
   a plain address. *Fallback:* drop the link and the four exact `edgeDoll.*` entries in the spec,
   let the `_.balanceOf(address)` wildcard cover the edge currency again, and restate
   `valueLeavesOnlyOnPayoutMethods` over `holdings(EDGE)`. The cost of the fallback is that the
   measure stops moving on a transfer, so that rule becomes weaker than it looks and must be marked
   as such rather than counted green.
2. **The two `Sload` hooks in `FamilyHook.spec`** on `registeredPools[KEY PoolId id].isEdge` and
   `.tradingStart` are the first struct-FIELD hooks in these specs. They are not the case note 10 of
   `PROPERTY_MAP.md` records as failing: that was a NESTED `mapping(PoolId => mapping(uint256 =>
   ...))` whose key could not be named, while this is a top-level `mapping(PoolId => RegisteredPool)`,
   the same shape as `FeeVault.spec`'s long-standing `ledgerTotal[KEY Currency c]` hook on a
   user-defined key type. *Outcome: THE FALLBACK WAS TAKEN.* S-8 recorded at the first pass that the
   hooks type-check once the key type is spelled `IFamilyHook.PoolId`; S-10 withdraws that, because
   no spelling type-checks. `protocolFeeOnlyAtTheEdge` and
   `theEdgeFeeIsSuppressedDuringTheSnipeWindow` therefore have no observable in this tier at all,
   because CVL cannot compute `key.toId()` to fetch the pool the swap hit and cannot read it through
   a hook either. Both properties fall back to `test/properties/Fees.prop.t.sol` and the review-5 unit
   tests, and are recorded here as not expressible rather than as unproved. Risk 1 is still
   UNTESTED: the `EDGE` link has never been loaded by a job, because `FeeVault.conf` has never run.

## One property this pass LOSES at this tier, stated plainly

**RND-11's "the bond reached the creator" half.** The bond is an ERC-20 escrow now, and the edge
token cannot be linked in `RoundManager.conf`, because this contract reaches it through
`edgeToken()`, which is `canonical(0)`: a storage read that may delegate to a prior registry, not an
immutable. With `transfer` summarized NONDET a recipient's balance does not move, so
`winnersBondIsReturned` can only assert what this contract owns (the escrow is released and never
grows across a finalize, and a creator's pull-fallback credit is never reduced). The delivery itself
is a unit-tier and fork-tier check. This is a real reduction against review 4, where the same rule
watched `nativeBalances[creator]`, and it is written down rather than absorbed.

## Rules, and what each one now says

**The FeeVault table below is still empty of evidence: every cell reads "blocked, P-1", after
review 6 as after review 5f: 0 of 30 verified, 0 violated, 30 never checked.** The
FamilyHook and RoundManager tables carry the review-5b verdicts and ARE evidence about the contracts
at this HEAD.

89 rules and invariants across three specs. Counts: **FeeVault 26 carried + 4 new = 30 (none run)**,
**RoundManager 28 carried + 8 new = 36 (31 verified)**, **FamilyHook 23 carried - 2 deleted + 2 new =
23, of which 2 are DISABLED for S-10 and 21 ran (17 verified)**. `Sleeve.spec` (10 rules) is
untouched by the review-5 diff and keeps its review-3 verdicts; `DevVesting.spec` (17 rules) is
deleted with the contract it verified.

Legend for "state": `unchanged` (the review-5 diff does not touch what it claims), `re-based` (same
claim, new names or new denomination), `renamed`, `corrected` (the review-4 form was a wrong claim
about the review-5 code), `strengthened`, `new`.

### FeeVault.spec (30)

| rule / invariant | state | property | contract functions it touches | verdict |
|---|---|---|---|---|
| `solvency` (inv) | re-based | FEE-11, SUP-04 | `ledgerTotal`, `holdings`, `deployerCredit`, `EDGE`, and every non-view method as the step |  blocked, P-1 |
| `edgeMirrorsAreNonNegative` (inv) | renamed | FEE-10 | every non-view method, through the ledger store hooks |  blocked, P-1 |
| `edgeLedgerDecomposition` (inv) | re-based | FEE-10 | `accrue`, `accrueForwarded`, `receiveForward`, `flushForward`, `depositEdgeBidEarmark`, `consumeAncestorClaim`, `consumeReinforcement`, `consumeEdgeEarmark`, the three claims |  blocked, P-1 |
| `accrueConservesTheFee` | re-based | FEE-08 | `accrue`, `_book` |  blocked, P-1 |
| `accrueMovesLedgerTotalByTheFee` | re-based | FEE-08 | `accrue`, `ledgerTotal` |  blocked, P-1 |
| `onlyAccrualPathsCredit` | corrected | FEE-10 | every non-view method; the named set is `accrue`, `accrueForwarded`, `receiveForward`, `flushForward`, `depositEdgeBidEarmark`, `transferCreatorRecipient` |  blocked, P-1 |
| `onlyAccrualPathsRaiseLedgerTotal` | new | SUP-04 | every non-view method; `ledgerTotal[EDGE]` |  blocked, P-1 |
| `creatorTransferIsALedgerMove` | unchanged | ROL-07 | `transferCreatorRecipient`, `creatorBalance`, `creatorAccrued` |  blocked, P-1 |
| `receiveForwardRefusesAnUndeliveredAmount` | new | FEE-11 | `receiveForward`, `holdings`, `ledgerTotal`, `_isPriorVault` |  blocked, P-1 |
| `depositEdgeBidEarmarkRefusesAnUndeliveredAmount` | new | RND-11 | `depositEdgeBidEarmark`, `holdings`, `ledgerTotal`, `edgeBidEarmark` |  blocked, P-1 |
| `everyEntrypointRefusesNativeValue` | new | FEE-10 (review 5 decision 4) | every non-view method |  blocked, P-1 |
| `drawNeverExceedsTheBucket` | re-based | BID-07 | `consumeAncestorClaim`, `drawableEdge`, `_bucket` |  blocked, P-1 |
| `drawNeverExceedsTheGenerationsClaim` | re-based | PUR-05, BID-07 | `consumeAncestorClaim`, `claimableEdge`, `claimableAncestor`, `reinforcementEdge` |  blocked, P-1 |
| `bucketNeverExceedsCap` (inv) | re-based | BID-07 | `drawableEdge`, `claimableEdge`, `_dailyAllowance`, every non-view method |  blocked, P-1 |
| `twoDrawsCannotDoubleUp` | re-based | BID-07 | `consumeAncestorClaim` twice, `_bucket` |  blocked, P-1 |
| `twoDrawsCannotDoubleUpAtAnyClock` | re-based | BID-07 (F-2) | `consumeAncestorClaim` twice, `_bucket`, `Drawdown.initialised` |  blocked, P-1 |
| `payKeeperIsBoundedByDeployerCredit` | unchanged | BID-05 | `payKeeper`, `deployerCredit` |  blocked, P-1 |
| `deployerCreditSettles` (inv) | unchanged | BID-14 | every non-view method except `consumeAncestorClaim` |  blocked, P-1 |
| `valueLeavesOnlyOnPayoutMethods` | re-based | BID-05, FEE-10 | every non-view method; `_sendToken`, `consumeReinforcement`, `consumeEdgeEarmark`, `deliverForward`, `redeem` |  blocked, P-1 |
| `onlyBidDeployerHooks` | re-based | BID-05 | `consumeAncestorClaim`, `consumeReinforcement`, `consumeEdgeEarmark`, `payKeeper` |  blocked, P-1 |
| `pendingForwardTotalIsTheSum` (inv) | unchanged | CON-05 | `_queueForward`, `_dequeue`, `_requeue`, every non-view method |  blocked, P-1 |
| `flushForwardConserves` | re-based | CON-05 | `flushForward`, `deliverForward`, `_dequeue`, `_requeue`, `_book` |  blocked, P-1 |
| `localBookingRequiresAgedEvidence` | re-based | CON-05 | `flushForward`, `deadEvidenceAt`, `DEAD_SUCCESSOR_DELAY` |  blocked, P-1 |
| `unresolvedSuccessorIsNeverEvidence` | unchanged | CON-05 | `flushForward`, `_resolveSuccessorVault`, `successorVault` |  blocked, P-1 |
| `deadEvidenceMovesOnlyOnTheForwardingPaths` | re-signed | CON-05 | every non-view method; `flushForward`, `forwardProtocolFee`, `accrue`, `accrueForwarded`, `receiveForward` |  blocked, P-1 |
| `candidateAttributionsCrossAsUnattributed` | unchanged | CON-04 | `accrue`, `_resolveAttribution`, `CANDIDATE_ATTRIBUTION`, `pendingForward` |  blocked, P-1 |
| `noPayoutPathCanBurnTokensAtTheZeroAddress` | renamed (carries S-5) | BID-05, FEE-10 | `claimDev`, `claimCreator`, `claimCreatorAccrued`, `payKeeper`, `_sendToken` |  blocked, P-1 |
| `postSunsetFeesAreNeverBookedLocally` | unchanged | CON-04 | `accrue`, `_book`, `_queueForward`, `roundManager.isSunset` |  blocked, P-1 |
| `ratesAndSplitsAreImmutable` | strengthened | FEE-03, ROL-01 | every non-view method; `DEV_BPS`, `CREATOR_BPS`, `ANCESTOR_BPS`, `REINFORCE_BPS`, `DAILY_DRAW_BPS`, `EDGE` |  blocked, P-1 |
| `claimZeroesBeforePaying` | unchanged | REN-02 | `claimDev`, `devBalance`, `_sendToken` |  blocked, P-1 |

### RoundManager.spec (36)

| rule / invariant | state | property | contract functions it touches | verdict |
|---|---|---|---|---|
| `canonicalIsWriteOnce` (inv) | re-based | RND-09, PUR-02 (half) | `finalize`, `openRoundIfIdle` / `_adoptIfContinuation`, `adoptGenesis`, `_canonical`, `headIndex` |  verified on the base, the transient step and 15 of 17 methods; **VIOLATED on `adoptGenesis` and `finalize`** (see C-1 and the residual note) |
| `onlyFinalizeOrAdoptionWritesHistory` | re-based | RND-09 | every non-view method; the writer set is `finalize`, `openRoundIfIdle`, `adoptGenesis` |  **verified** (17/17 methods) |
| `historyEntriesAreImmutable` | unchanged | RND-09, PAR-02 | every non-view method; `canonical`, `parentOf`, `creatorOf` |  verified on 14 of 17 methods; **VIOLATED on `addCandidate`, `adoptGenesis`, `finalize`** ("an existing entry was re-parented") |
| `historyLengthIsMonotone` | unchanged | RND-09 | every non-view method; `_canonical` |  **verified** (17/17 methods) |
| `reverseIndexIsConsistent` (inv) | unchanged | RND-09 | `canonical`, `indexOf`, `isCanonical`, every non-view method |  verified on the base, the transient step and 14 of 17 methods; **VIOLATED on `addCandidate`, `adoptGenesis`, `finalize`** |
| `pairingRightsAreWriteOnce` | re-based | PAR-01 | every non-view method; `head`, `headIndex`, the three writers |  **verified** (17/17 methods) |
| `headIndexOnlyGrows` | unchanged | PAR-01 | every non-view method; `head`, `headIndex` |  **verified** (17/17 methods) |
| `adoptGenesisIsOnceAndFactoryOnly` | new | RND-09, CON-01 (review 5 decision 1) | `adoptGenesis`, `canonical`, `head`, `headIndex`, `parentOf`, `priorRegistry` |  **VIOLATED** - "the genesis link was adopted twice" (finding C-1) |
| `finalizeIsIdempotent` | unchanged | RND-07 | `finalize` twice; `head`, `headIndex`, `roundCount`, `hWad` |  **verified** |
| `noNewRoundBeforeFinalize` | unchanged | RND-08 | `openRoundIfIdle`, `isIdle`, `roundCount` |  **verified** |
| `thresholdMovesOnlyInFinalize` | unchanged | RND-13 | every non-view method; `hWad`, `H_FRAC_WAD`, `H_MIN_FRAC_WAD` |  **verified** (17/17 methods) |
| `winnersBondIsReturned` | re-denominated (weaker) | RND-11 | `finalize`, `bondEscrow`, `pendingRefund`, `_tryTransfer`, `pushRefund` |  **verified** |
| `losersBondsAreForfeited` | re-based | RND-11 | `finalize`, `pendingRefund`, `_tryForfeit` |  **verified** |
| `addCandidateRefusesAnUnderDeliveredBond` | new | RND-11 (review 5c item 2) | `addCandidate`, `bondEscrow`, `pendingForfeits`, `edgeToken`, `IERC20.balanceOf` |  **verified** |
| `registrationNeverPullsMoreThanTheQuotedBond` | new | RND-12 (review 5b item 5) | `addCandidate`, `roundInfo`, `bondEscrow`, `openRoundIfIdle`, `bondFor` |  **verified** |
| `finalizeBooksWhatItCouldNotDeliver` | new | RND-11 (review 5b item 1) | `finalize`, `bondEscrow`, `pendingForfeits`, `_tryForfeit`, `pushForfeit` |  **verified** |
| `pendingForfeitsMoveOnlyOnFinalizeOrFlush` | new | RND-11 | every non-view method; `pendingForfeits` |  **verified** (17/17 methods) |
| `flushForfeitsZeroesBeforeDelivering` | new | REN-02 | `flushForfeits`, `pendingForfeits`, `feeVault.depositEdgeBidEarmark` |  **verified** |
| `theBondPushesAreSelfOnly` | new | RND-11 | `pushRefund`, `pushForfeit` |  **verified** |
| `guardedFactoryEntrypointsCannotBeReentered` | new | REN-01 (review 5d item 1) | `openRoundIfIdle`, `addCandidate`, the `nonReentrant` `_locked` word |  **verified** |
| `requestEndIsOnceAndNotBeforeT` | unchanged | RND-04, RAN-03 | `requestEnd` twice; `randomness.pin`, `Round.endRequested` |  **verified** |
| `trueEndFallsInsideTheWindow` | unchanged | RND-05 | `fulfilEnd`, `randomEndWindowFor`, `RANDOM_END_S` |  **verified** |
| `timeoutFallbackSettlesAtT` | unchanged | RND-06, RAN-06 | `finalizeDeterministic` |  **verified** |
| `endIsSettledAtMostOnce` | unchanged | RND-06, RAN-04 | `finalizeDeterministic`, `fulfilEnd` |  **verified** |
| `scheduleIsPureInN` | unchanged | RND-01 | every non-view method; the six schedule getters |  **verified** (17/17 methods) |
| `scheduleBounds` | unchanged | RND-01 | `durationFor`, `registrationFor`, `randomEndWindowFor`, `closingWindowFor`, `DURATION_SCALE_DIV` |  **verified** |
| `theCoarseRingCoversTheScoredSpan` | unchanged | RND-01, SCR-06 | `scoreSlotFor`, `closingWindowFor`, `RANDOM_END_S`, `SCORE_MIN_SLOT_S` |  **verified** |
| `theConstructorsWindowGuardMatchesTheGetters` | unchanged | SCR-14 | the constructor's `BadDurationScale` block, `closingWindowFor`, `scoreSlotFor` |  **verified** |
| `theScoredWindowAlwaysExceedsOneCoarseSlot` | unchanged | SCR-14 | the same pair |  **verified** |
| `lateEntryClosesBeforeTheClosingWindow` | unchanged | RND-02 | `lateEntryUntil`, `durationFor`, `closingWindowFor` |  **verified** |
| `bondSaturates` | re-based | RND-12 | `bondFor`, `BOND_BASE`, `BOND_MAX` |  **verified** |
| `bondIsMonotoneInDepth` | re-based | RND-12 | `bondFor`, `BOND_BASE`, `BOND_DOUBLING_EVERY` |  **verified** |
| `maxIndexIsRespected` | unchanged | RND-15 | `openRoundIfIdle`, `headIndex`, `MAX_INDEX`, `isIdle` |  **verified** |
| `noTransitionIsPrivileged` | re-based | RND-03, ROL-01 | every non-view method except the steward set, `adoptGenesis`, `openRoundIfIdle`, `addCandidate` |  verified on `finalizeDeterministic`, `requestEnd`; **VIOLATED on `claimRefund`, `finalize`, `flushForfeits`, `fulfilEnd`, `pushForfeit`, `pushRefund`** (S-12); **UNKNOWN** on `submitScore` (the standing timeout) |
| `sunsetTouchesNothingElse` | unchanged | RND-03, ROL-02 | `announceSunset`, `head`, `headIndex`, `roundCount`, `hWad` |  **verified** |
| `adoptionHappensAtMostOnce` | unchanged | CON-01 | every non-view method; `adopted`, `priorIndex` |  **verified** (17/17 methods) |

### FamilyHook.spec (23)

| rule / invariant | state | property | contract functions it touches | verdict |
|---|---|---|---|---|
| `scoreIsMonotoneInNetParentAbsorbed` | unchanged | SCR-01, SCR-02 | `afterSwap`, `_updateScore`, `scoreState` |  **verified** |
| `onlyTheSwapPathMovesTheScore` | unchanged | SCR-02 | every non-view method; `afterSwap`, `beforeSwap`, `registerPool` |  **verified** (3/3 methods) |
| `donationsAreImpossible` | unchanged | SUP-06 | `beforeDonate` |  **verified** |
| `liquidityIsARatchet` | unchanged | SUP-05 | `beforeRemoveLiquidity` |  **verified** |
| `averageOverIsTheAccumulatorDifference` | unchanged | SCR-04 | `averageOver`, `_accumulatorAt`, `_sample`, `_bracket` |  **verified** |
| `averageOverRevertsOnACollapsedWindow` | unchanged | SCR-14 | `averageOver` (`BadScoreWindow`) |  **verified** |
| `aSlotIsWrittenOnceByItsFirstSwap` | unchanged | SCR-05 | `afterSwap`, `_updateScore`, `_checkpoint`, `scoreCheckpoint` |  **verified** |
| `theFastRingSpansTheRandomEndWindow` | unchanged | SCR-06 | `SCORE_RING_S`, `SCORE_SLOTS`, `SCORE_SLOT_S` |  **verified** |
| `snipeTaxBounds` | unchanged | FEE-04 | `SNIPE_START_PPM`, `SNIPE_END_PPM`, `SNIPE_S` |  **verified** |
| `summedRatesStayBelowOne` | re-based | FEE-04, FEE-06 | `_collect`'s gross-up, `PROTOCOL_FEE_PPM`, `SNIPE_START_PPM`, `SNIPE_END_PPM`, `hopFeePpm`, `MAX_HOP_FEE_PPM` |  **VIOLATED** on the third assertion only (finding S-11) |
| `theEdgeFeeIsSuppressedDuringTheSnipeWindow` | new | FEE-04, FEE-06 (review 5 decision 8) | `beforeSwap`, `_collect`, `_snipeTaxPpm`, `registeredPools[...].tradingStart`, `SNIPE_S` |  **DISABLED at review 5b** (S-10) |
| `feeRatesAreImmutable` | unchanged | FEE-03 | every non-view method; `hopFeePpm`, `PROTOCOL_FEE_PPM`, `SNIPE_START_PPM` |  **verified** (3/3 methods) |
| `protocolFeeOnlyAtTheEdge` | re-derived | FEE-01 | `beforeSwap`, `_collect`, `registeredPools[...].isEdge`, `feeVault.accrue` |  **DISABLED at review 5b** (S-10) |
| `oneProtocolFeeAtTheEdgeIsReachable` (satisfy) | renamed | FEE-01 rung 3 | `beforeSwap`, `_collect`, `feeVault.accrue` |  **VIOLATED** (unreachable) - the FEE-01 ladder, see S-13 |
| `someProtocolFeeIsReachable` (satisfy) | unchanged | FEE-01 rung 2 | the same |  **VIOLATED** (unreachable) - the FEE-01 ladder, see S-13 |
| `anyFeeAccrualIsReachable` (satisfy) | unchanged | FEE-01 rung 1 | the same |  **VIOLATED** (unreachable) - the FEE-01 ladder, see S-13 |
| `theFeeMintIsReachable` (satisfy) | unchanged | FEE-01 rung 0.5 | `beforeSwap`, `_collect`, `poolManager.mint` |  **verified** (reachable), which is where the ladder still stops |
| `beforeSwapIsReachable` (satisfy) | unchanged | FEE-01 rung 0 | `beforeSwap` |  **verified** |
| `registerPoolRefusesAPoolWithoutAPublishedEnd` | generalized | SCR-13 | `registerPool` (`BadNominalEnd`) |  **verified** |
| `everyRegisteredPoolHasAPublishedEnd` | new | SCR-10, SCR-13 | every non-view method; `registerPool`, `poolInfo` |  **verified** (3/3 methods) |
| `noRingEntryIsWrittenPastTheBell` | strengthened | SCR-10 | every non-view method; `_updateScore`, `_checkpoint`, `scoreCheckpoint`, `coarseCheckpoint` |  **verified** (3/3 methods) |
| `endSealIsWriteOnce` | unchanged | SCR-10 | every non-view method; `_updateScore`'s seal branch, `endCheckpoint` |  **verified** (3/3 methods) |
| `theEndSealIsOnlyLaidPastTheBell` | re-based | SCR-10 | every non-view method; `_updateScore`, `poolInfo`, `endCheckpoint` |  **verified** (3/3 methods) |

### Deleted at review 5

| rule | spec | why |
|---|---|---|
| `genesisIsNeverSniped` | FamilyHook.spec | asserted `isGenesis => tradingStart == 0` about a pool class that no longer exists. A round-one pool IS sniped, deliberately |
| `registerPoolRefusesAGenesisSnipeWindow` | FamilyHook.spec | stated the `GenesisHasNoSnipeWindow` guard, which is gone from the contract |
| all 17 rules of `DevVesting.spec` | deleted | the contract is removed from the deployment and the tree (REVIEW5_DESIGN decision 9) |

## What the second pass did, step by step, so it can be repeated

1. JDK 21 and the local CVL type-checker first, as at the first pass. It carried five probe runs at
   no cost in prover minutes, which is the only reason S-10 could be established rather than guessed.
2. A pristine `git archive HEAD` export outside the repository, plus the three edited files
   (`certora/conf/FamilyHook.conf`, `certora/conf/RoundManager.conf`, `certora/specs/FamilyHook.spec`).
   Both jobs were submitted from that export, never from the working tree.
3. `contracts/FeeVault.sol` removed from the `files` array of both confs, and the `feeVault` link
   with it. Nothing else in either conf changed; both keep the same solc settings, the same
   `loop_iter`, the same `rule_sanity`, the same Yul sequence and the same autofinder switches.
4. `FamilyHook.spec`: the exact `FeeVault.accrue` entry removed, because it names a contract that is
   no longer in the scene, leaving the `_.accrue(...)` wildcard that was always beside it. The two
   `Sload` hooks and the two rules stated over them commented out for S-10, with a restore note.
   `RoundManager.spec` needed NO change at all: it already summarized the vault.
5. Local type-check to clean on both confs, then one submission each, then the verdicts, the output
   tarballs and the call traces pulled into `private/certora/review-5b/<spec>/`.

**The rule the second pass followed, and it is worth keeping:** when a Prover defect blocks a file,
ask first which scenes actually NEED that file for a claim, rather than which ones happen to compile
it. Two of the three did not need it, and the specs already said so in their own summary tables.

## What the authoring pass said to do when the run happened

1. JDK 21 on the machine FIRST. Two of review-4's six runs went on CVL type errors that only surface
   server-side under `--disable_local_typechecking`, and this pass has a whole set of new CVL.
2. Export a pristine tree (`git archive HEAD`) outside the repository and submit from there.
3. Three initial runs (`FeeVault`, `RoundManager`, `FamilyHook`), then at most three re-runs, in the
   priority order set out in `certora/README.md`.
4. Fill in the verdict column above, update `PROPERTY_MAP.md`, and add the dated row to
   the internal audit ledger and the docs-site audits page.
5. Do not mark a rule verified without also recording its `rule_sanity` result. Two of this project's
   findings so far were rules that reported "not violated" while proving nothing.
