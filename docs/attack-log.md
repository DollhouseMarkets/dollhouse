# Attack log — independent design review (2026-09-10) → reconciliation into DESIGN_BRIEF_v2

Full report: `docs/reviews/2026-09-10-design-review.md`. Verdict on v1: reject. Each finding below lists the resolution adopted in v2.

| # | Finding (sev) | Resolution in v2 |
|---|---|---|
| 1 | First submitter can submit+finalize atomically and exclude a better candidate (critical) | Submission window `[T_end, T_end + 5 min)`; `finalize()` only after the window; `submitScore` permissionless for any candidate; scores snapshot at T_end; deterministic tie rule (earliest time the winning average was first reached via stored `(score, tAttained)`; then lower poolId). |
| 2 | Transaction-wide fee frame (first-leg or largest-leg) is defeated by dust prefix / leg splitting; hook has no tx-end callback (critical) | **Fee model replaced.** Protocol fee 1% is charged by the hook only on swaps whose counter-currency is native ETH (the genesis pool = the family's ETH edge), on entry and on exit. Family↔family hops pay only the per-hop pool fee. No transaction frames, no waivers, no privileged sender. A FamilyRouter exists solely to attribute the edge fee to the terminal token's creator (trusted hookData only when `sender == FamilyRouter`); direct PoolManager swaps still pay the same fee, attributed to the flywheel. |
| 3 | Global birth-snapshot accumulators credit non-ancestors; multi-currency fees cannot share accumulators (critical) | Beneficiaries of a fee = ancestors `0..M` of the terminal token (M = its parent's index). Range-add / point-query Fenwick trees over generation index, three trees for the polynomial coefficients (O(log N)); `M = 0` handled as genesis-only. Single fee currency (ETH) by construction of finding 2. |
| 4 | "Buy beneficiary then bid below spot" uses the wrong asset; hook fees don't auto-compound (high) | Support for ancestor j = deposit **j's parent token** (j−1, or ETH for genesis) as single-sided bid liquidity below spot in j's pool, via the Locker. Keeper converts ETH by buying up the chain to j−1 (buy pressure on 0..j−1), then deposits. Compounding language removed; hop fees accrue to the FeeVault as ETH/parent balances and are deployed by the same keeper path. |
| 5 | Refundable capital rental buys the slot for ≈ fees (high) | Accepted, disclosed risk (no sunk slice / lock / seasoning). Documented as a capital-rental auction; Sim 4 quantifies; disclosure text required in UI. |
| 6 | Secret end impossible; Arbitrum `prevrandao` = 1 (high) | Fixed public end: trading window exactly 10 minutes. Randomized end deleted. |
| 7 | Threshold unit mismatch; missing oracle history at gen 1; genesis-TWAP floor unreachable after parent crash; decay attackable; supply-fraction bond not stable (high) | Compare **average absorption** `Score/D` with `H` (parent tokens). Genesis-TWAP floor deleted. `H = h × parentSupply` with h fixed at deploy; decay ×0.9 per failed round down to `H_min = 0.25 × H` (not to zero); reachability invariant: `H ≤ 25% × standard-curve absorption at the wall FDV`. Bond = fixed ETH amount (deploy constant, e.g. 0.005 ETH), refunded to winner, forfeited by losers as ETH bid under genesis. |
| 8 | Predictable PoolKey can be pre-initialized to poison launches (high) | Hook enables `beforeInitialize`; only pools whose key was pre-registered by the Factory (with exact initial sqrtPrice) may initialize; all other hook entries reject unregistered pools. |
| 9 | Keeper buy-and-lock deployments are sandwichable (high) | Hook maintains a cheap cumulative-price observation per pool (afterSwap); keeper deployments must execute within ±3% of the pool's 30-min TWAP, size-capped per call to ≤ 2% of pool parent reserve, bounty paid only after a verified deposit. |
| 10 | Median cap does not stop decisive spikes; "earliest attainment" undefined; hash ties grindable (medium) | Median cap deleted; score = plain integral of net parent absorbed to T_end (tail-extended). Spike cost is documented: adding x% to a rival's average needs x%·D seconds-equivalent of capital for ≥1 s. Tie rule as in #1. |
| Q2 | Nested unlock reverts; native ETH reentrancy; specified/unspecified currency; partial fills; direct transfers/`sync` are not swaps | Router executes whole route in one unlock; CEI + reentrancy guard on claims; fee taken on the ETH side whichever is unspecified/specified (computed from actual deltas); score uses swap deltas only. |
| Q5 | Gen-1 divide-by-zero; depth costs | Singleton case; per-hop fee sized in Sim 7 (0.05–0.1%). |
| Q6 | U-shape = genesis tax funnel with the fixed floor | Adopt `w(r) = 2 − 5r + 4r²`, `Z(M) = (M+1)(5M+4)/(6M)`; **no fixed genesis floor**; separate immediate-parent reinforcement sleeve kept. |
| Q8 | Delete list | Deleted: secret end, tx-wide exemptions, fixed genesis floor, chained TWAP threshold, creator buy-and-burn option (v2 later), auto-compounding language, spike-immunity claim. |

Design decisions this changes: randomized end → fixed 10 min; "1% once per transaction" → "1% when ETH enters or leaves the family, internal rotations pay hop fee only"; no fixed genesis floor (OG weight is 2× the newest link by the polynomial); bond in ETH. Recorded 2026-09-10.

# Final independent contract review (`docs/reviews/2026-09-11-contract-review-final.md`, at the tagged revision) → dispositions

| # | Finding (sev) | Disposition |
|---|---|---|
| F1 | Continuation forks the trunk during the 7-day sunset delay (high, blocker) | FIX: lazy head adoption in v2's first `openRoundIfIdle` (prior sunset effective, `successor == this`, prior idle); v2 rounds impossible before adoption; test with a v1 win after v2 deploy. |
| F2 | Gas-burning successor bricks every v1 swap; docs claimed the opposite (high, blocker) | FIX: `forwardProtocolFee{gas: 400k}`, `staticcall{gas: 30k}` helpers, negative-resolution cache, steward `cancelSunset()` before effect; gas-burner tests. Docs corrected. |
| F3 | `ethPerTokenWad` underflows by generation ~10; deep-generation ETH stranded (high, blocker) | FIX: walk the amount through the chain with `mulDiv` per link; step-wise inversion; chain-of-12 test with non-dust payout at j=8/11. |
| F4 | 30-min TWAP drag drains undeployed sleeve ETH (high, economic) | FIX: price at `min(TWAP_30m, TWAP_7d)` via a slow observation ring; ≤10%/day drawdown per generation; disclosed. |
| F5 | Keeper liveness decays with depth (medium) | FIX: band on target pool only; coverage still required for pricing. |
| F6 | Threshold meaningless past generation ~2; bond is the only cost (medium, economic) | DESIGN DECISION (2026-09-11): keep-and-disclose vs depth-scaled bond vs ETH-equivalent H. Disclosed regardless. |
| F7 | Keeper bounty below gas at beta scale (medium) | FIX: cap sized against the first curve range's capacity (2% of that), bounty stays 1%; test bounty ≥ 3× gas at 0.01 gwei. |
| F8 | Developer hardcoded to deployer in script (medium) | FIX: `DEVELOPER` and `STEWARD` env vars required. |
| F9 | Exact-output sells under-taxed by `rate/(1+rate)` (low) | FIX: symmetric gross-up; parity test. |
| F10 | Spam cost ≈ $4; unpaginated candidate list (low) | FIX: paginated view; mainnet bond raised (ROADMAP). |
| F11 | Comment/observation spacing; timestamp monotonicity; deployBlock artifact (info) | FIX comments; documented. |
| — | Beta caps recommended by the review | Adopted into ROADMAP: steward multisig, cold developer address, bond ≥ 0.01 ETH, ≤ 20 rounds, `maxIndex` ≤ 4 (new constructor param), genesis ETH ≤ 20 by policy, no sunset during beta. |
| — | Disclosure gaps (a)–(i) | Added to `docs/DEPLOY_CONSTANTS.md` "Measured, disclosed risks" and to the UI copy list in ROADMAP. |

# Final external contract review (`docs/reviews/2026-09-11-contract-review-external.md`, at the tagged revision) → dispositions

| # | Finding (sev) | Disposition |
|---|---|---|
| 1 | Price crash → keeper overpayment; only the target pool was spot-checked (high) | FIX: every conversion link priced at `min(spot, TWAP30, TWAP7d)` in value terms; crash regression test. |
| 2 | Unadopted intermediate continuation can fork the trunk (high) | FIX: adoption requires the immediate prior to be a root or `adopted()`; `announceSunset` on an unadopted continuation reverts; v1→v2→v3 overlap test. |
| 3 | Terminal generation's hop pot has no deployment path (medium) | FIX: permissionless `deployHopPot(j)` (parent-token bounty 1%). |
| 4 | Gas decides which version books fees; recursion dies by v5 (medium) | FIX: post-sunset fees are never booked locally — forwarded in-swap when budget allows, else queued in `pendingForward`; permissionless `flushForward` with the caller's gas; per-version hop (no recursion); 6-version test. |
| 5 | Keeper economics negative (medium) | FIX: `MIN_BOUNTY_WEI` from the generation's ETH entitlement (capped 20% of ETH consumed); dead zones disclosed. |
| 6 | Daily limit is a resetting window (≈19% burst) (medium) | FIX: token-bucket allowance (continuous refill, cap 10% of E). |
| 7 | Successor containment: dirty 32-byte word reverts decode; `sync(ERC20)` breaks native settle (medium) | FIX: validate upper bits before decoding; `sync(native)` before native settle in router and Locker. |
| 8 | Losers can't exit via router after the round; no attribution (medium) | FIX: candidate routes work post-round via the recorded round parent; attribution 100% to the candidate's creator after the round. |
| 9 | v4 protocol fee (if enabled) inflates the score (medium) | FIX: subtract the increase of `protocolFeesAccrued(parent)` across the swap. |
| 10 | "Non-refundable bond floor" disclosure false for winners (medium) | FIX docs: winners get the bond back; the schedule scales capital tied up. |
| 11 | Lens loads the whole candidate array (low) | FIX: paginated overload. |
| — | Creator-right transfer moves accrued fees / allows zero address | FIX: accrued balance stays with the old recipient; zero rejected. |
| — | Sibling losers' hop fees pooled per parent; partial-fill fee on requested amount; Fenwick sub-wei carry; "pump cannot raise payment" ≈1.07% | Documented in DEPLOY_CONSTANTS / spec. |
| — | 7-day handover never fired live | A 7-day wait is impractical on testnet. `sunsetDelay` becomes a constructor parameter (mainnet 7 d, testnet 1 h) so run 3 exercises sunset → handover → v2 round live. |
| — | Disclosure additions | Added to DEPLOY_CONSTANTS pointers and ROADMAP disclosure-copy item. |

# Mechanism v3 (design decisions 2026-09-12, `docs/MECHANISM_v3.md`) → new surfaces and the tests covering them

Four new attack/liveness surfaces, none of them privileged, added on top of the tree above (226
tests, 27 suites; three new: `Schedule.t.sol`, `Drand.t.sol`, `Purse.t.sol`). Each row names the
surface, why it exists, and the tests that pin its behaviour — see `docs/spec/PROTOCOL_SPEC.md`
§A/§C/§F/§J/§N for the full mechanics.

| # | New surface | Why it exists | Tests covering it |
|---|---|---|---|
| V3-1 | **Late entry** — a new candidate may register and open its own pool during trading itself, on any round with `durationFor(n) >= 1 hour`, through the first third of trading | A 3-minute-to-1-hour registration window in front of a 12-hour round would starve good coins of the chance to enter at all | `Schedule.t.sol::test_lateEntryIsRefusedOnAShortRound`, `test_lateEntryIsAcceptedInTheWindowAndRefusedAfterIt`, `test_lateEntryAlwaysEndsBeforeTheClosingWindowStarts`, `test_aLateEntrantWithTheSameClosingSupportScoresTheSame` |
| V3-2 | **Closing-window scoring** — every candidate's score is its average absorption over `[T_end − W, T_end]` (`W` = 15 min or `D(n)/4`) instead of the whole round, with the accumulator never frozen and read back through a two-ring checkpoint structure | Design decision: the coin with the highest market cap should win, and the time average is only a defence against manipulation. Disclosed consequence, not a bug: a **window sniper** (leader-equal capital, bought at the start of `W` and held) beats a spreading leader ≈82–93% of the time (Sim 13); the random end and the requirement to hold capital, not flash it, are the only defences | `Schedule.t.sol::test_theClosingWindowTable`, `test_theScoreRingCoversTheWholeClosingWindowPlusTheTail`, `test_theRingReconstructsExactlyAcrossGaps`, `test_aSlotIsWrittenOnceByItsFirstSwap`, `test_supportSoldBeforeTheBellDoesNotCount` |
| V3-3 | **Random end via drand relay** — the round's true end is settled after the fact by a verified beacon signature, or by a disclosed 30-minute deterministic timeout if nobody relays one | A contract cannot keep a secret; `prevrandao` is a constant and block hashes are sequencer-influenced on this chain (attack-log #6, unchanged). drand `evmnet` (BN254, pairing precompile `0x08`) is the provable source that is actually verifiable here; `quicknet` (BLS12-381) is not, because the EIP-2537 precompiles it needs do not exist on this chain | `Drand.t.sol` (10 tests: real-beacon verification, wrong-round and tampered-signature refusal, future-only pinning); `Schedule.t.sol::test_theEndCannotBeRequestedBeforeTheNominalEnd`, `test_theEndIsPinnedOnceAndOnlyOnce`, `test_theTrueEndFallsInTheLastThreeMinutes`, `test_nothingSettlesUntilTheEndIsKnown`, `test_theSubmissionWindowStartsAtFulfilment`, `test_theEndCannotBeSettledTwice`, `test_theDeterministicFallbackIsRefusedBeforeTheTimeout`, `test_anUnrelayedBeaconEndsTheRoundAtTLoudly`, `test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd` |
| V3-4 (SUPERSEDED 2026-09-13, see "Review 3" below) | **Contestable purse ranking** — a generation's ancestor-sleeve share is split proportionally between the top 2 siblings by trailing support (a permissionless, per-candidate `rank()` call feeding a running top-2 board), instead of going to a single target pool | Design decision: the purse is up for grabs, split proportionally between only the top 2 siblings, with no guaranteed trunk share, so a dumped winner can lose to a sibling and an underdog can grow into the money later; ranking is deliberately O(1) per call so a spammed round's purse cannot be made permanently undeployable | `Purse.t.sol` (12 tests: ranking order, third-sibling displacement, refusing an uncrowned candidate, the purse window matching the round's own closing window, the proportional split, dump-and-lose-the-purse, stale-board refusal, unranked-generation weights) |

Disclosed, not fixed, by design: the window sniper (V3-2) and purse-parking (V3-4) are both measured
in `docs/sim-results-v3.md` (Sims 11–13) and stated as accepted trade-offs in
`docs/spec/PROTOCOL_SPEC.md` §R/§U, not as findings awaiting remediation.

# Static analysis (Slither) at review-1 (2026-09-12)

Full run and per-row dispositions: `docs/security/slither-triage.md` (275 results across 102
detectors; 6 High, 75 Medium, 147 Low, 47 Informational). Hand triage covered every High row, every
Medium row, and every Low `reentrancy-*` row, each read against the cited source.

| # | Finding (severity) | Location | Failure scenario | Suggested fix | Status |
|---|---|---|---|---|---|
| — | **No findings.** Every High and Medium row, and every Low reentrancy row, resolved to a false positive or to an already-disclosed accepted risk. | — | — | — | none open |

Settled with evidence, for the record (none of these is a finding):

- `arbitrary-send-erc20` at `FamilyRouter.sol:430` — the `from` of `safeTransferFrom` is the
  `payer` field of the unlock payload, and the only encoder is `_run`
  (`abi.encode(..., msg.sender, attribution)`); `unlockCallback` accepts no caller but the
  PoolManager, and the PoolManager calls back only the address that called `unlock`. `from` is
  therefore always the original caller, and no third party's approval can be pulled.
- `arbitrary-send-eth` at `BidDeployer.sol:858` / `FeeVault.sol:911` — recipients are the keeper
  itself (bounty), the immutable BidDeployer, or a claimant's own zeroed ledger entry; amounts are
  bounded by `drawn != need`, `deployerCredit`, and the per-generation drawdown bucket.
- `arbitrary-send-eth` at `FeeVault.sol:456` (`flushForward`) — recipient is the steward-named
  successor's vault, amount bounded by `pendingForward`. Carried as accepted risk; disclosed in
  `docs/spec/READINESS.md` (privileged surface) and `docs/spec/PROTOCOL_SPEC.md` (sunset handover).
- `uninitialized-state` `_board` at `RoundManager.sol:297` — a mapping, so uninitialised by
  construction; the only writer is the permissionless `rank()`, and every reader refuses an unset
  entry (`if (!a.set) revert BadRanking()`). An unranked generation's purse reverts rather than
  paying out at a wrong number; the `RANK_MAX_AGE = 6 h` freshness requirement is specified.
- `weak-prng` at `FamilyHook.sol:637` — `slot % cardinality` is a checkpoint ring index, tagged by
  `cp.tSwap / slotS == slot`. The protocol's only randomness is the BLS-verified drand beacon.
- All `reentrancy-*` rows — no `reentrancy-eth` row was produced. The external calls are the
  PoolManager (unlock pattern), the immutable randomness source, the immutable Locker / hook /
  factory / BidDeployer / FeeVault, or the steward-named successor vault inside a `try/catch` that
  rolls back and queues the fee. Every ERC-20 call target is a `FamilyToken` clone of this (or a
  prior) version's immutable implementation — "no function other than ERC20 plus holder-initiated
  `burn`", no transfer hook, no callback — so **no non-factory token can ever be a call target**.
  `finalize`, `flushForward`, `claim*` and every BidDeployer entry point are `nonReentrant`.

Still `needs review` and out of this pass's scope: `calls-loop` (74), `missing-zero-check` (15),
`return-bomb` (2) and the informational detectors (17).

---

## 2026-09-12 — Formal verification (Certora) at review-1

First execution of the spec-derived CVL in `certora/`. Full write-up, with job URLs and the
counterexample for every violation, in `certora/RESULTS-review-1.md`; per-rule status in
`certora/PROPERTY_MAP.md`. Prover `certora-cli 8.19.2`, solc 0.8.26, `rule_sanity: basic`.

All five specs now type-check and have live jobs. DevVesting and Sleeve completed locally; FeeVault,
RoundManager and FamilyHook outran the local client and their verdicts live at their job URLs.

Findings, all **status: open**:

1. **SLV-03 is unproved, not proved.** `Sleeve.spec`'s two conservation rules
   (`sumOfSharesNeverExceedsTheSleeveSmallM`, `noShareExceedsTheSleeve`) report "not violated" but
   FAIL their `rule_sanity` vacuity check — their preconditions are unsatisfiable, so they discharge
   nothing. The claim "the ancestor shares never over-allocate the sleeve" currently has no formal
   evidence at any depth. Highest-value item for review-2.
2. **`FenwickRangeAdd.addSleeve` does not bound `M` when `sleeve == 0`.** `indexPastMaxReverts`
   violated with `sleeve = 0`, `M = 4097 > MAX_INDEX`: the `if (sleeve == 0) return;` short-circuit
   runs before `rangeAdd`'s `r > MAX_INDEX` check, so the call is a silent no-op instead of a
   revert. Nothing is credited (`noIndexOutsideTheRangeIsCredited` verified), so this is a
   spec-vs-code divergence rather than a loss of funds — but the short-circuit should be a
   documented choice, not an accident.
3. **`FamilyHook.registerPool`'s documented signature does not match the deployed one.** The spec,
   written from `docs/`, had `(PoolKey, uint160, bool, bool, uint32)`; the contract takes
   `(PoolKey, bool isGenesis, uint160 initSqrtPriceX96, uint64 tradingStart, uint32 scoreSlotS,
   bool parentIsCurrency0)`. Six parameters, different order. The documentation is wrong, not the
   code — but it is the kind of drift that makes every downstream claim about registration suspect
   until reconciled in `docs/spec/PROTOCOL_SPEC.md`.
4. **Three Sleeve rules and two DevVesting rules assume state the Prover does not give them.**
   `rangeAddThenPointQueryIsTheClosedForm`, `everyAncestorShareIsNonNegative` and
   `genesisTakesTheWholeSleeveAtMZero` assume an empty Fenwick tree; `everythingVestsAtTheEnd` and
   `releasedEqualsTotalAfterDuration` assume the constructor's guards on `start`/`cliff`/`duration`.
   Parametric and standalone rules both start from arbitrary storage. Spec-writing errors, no
   contract bug, but the properties they were meant to carry are unproved until restated.

Timeouts: `genesisWeightIsTwiceTheTerminalWeight` (SLV-05) at 417 s.

Already fixed in this pass (spec-writing errors, no rule weakened): `releasable()` mis-declared
`envfree` though it reads `block.timestamp`; DevVesting's parametric rules ranging over the linked
`FamilyToken`'s methods as well as its own; CVL's reserved `old` and `hook` identifiers;
`ledgerTotal` hooks typed `address` instead of the v4 `Currency`; `afterSwap` typed `int256`
instead of `BalanceDelta`; `RegisteredPool`/`ScoreCheckpoint` qualified to `IFamilyHook`.

Toolchain note, not a protocol finding: the Prover substitutes its own Yul optimiser sequence for
solc's and drops the full inliner, which makes `FeeVault`, `RoundManager` and `FamilyHook` fail to
compile with "stack too deep" under settings foundry builds cleanly. The confs pass solc's default
sequence back. Anyone reproducing this should read `certora/README.md` first.

### 2026-09-12 (same pass) — FeeVault / RoundManager / FamilyHook verdicts not retrieved

**Status: open. No violations to report for these three, and no clean bill either — treat all three
as unrun.**

All three jobs type-checked, uploaded and began proving. Their result tables could not be collected
afterwards: Certora's result endpoints authenticate with a per-job read key (the `anonymous…Key` query parameter) that the server
returns once, in the response to the submit call, and that `certora-cli` 8.19.2 prints only on the
failure path. These runs did not fail that way, so the key was never surfaced, and the only local
copy lives in the `.certora_internal/` scratch tree that has to be cleared between runs. `CERTORAKEY`
is rejected (403) on those endpoints and the CLI exposes no job-listing API. Job URLs are recorded in
`certora/RESULTS-review-1.md`; the verdicts are reachable only from a logged-in session.

Consequence for the security pipeline: **FEE-08/10/11, BID-05/07/14, CON-04/05, RND-01..15, PAR-01,
CON-01, SCR-01..06 and FEE-01/03/04 have no Certora evidence yet.** The review-1 entry above should
not be read as covering them.

Spec-writing errors from review-1 fixed in this pass (no re-run yet, so the properties remain
unproved until review-2):

- `Sleeve.spec` — SLV-01, SLV-02 and SLV-06 restated as deltas across the range-add instead of
  absolute point-query values, since the Prover starts from an arbitrary Fenwick tree. SLV-06 also
  tightened to the exact amount spec J names.
- `Sleeve.spec` — SLV-07's `indexPastMaxReverts` now requires `sleeve > 0`, isolating it from the
  zero-sleeve short-circuit finding above.
- `Sleeve.spec` — the two SLV-03 rules used `2^128` as a bound; **`^` is not exponentiation in CVL**,
  so the bound did not mean what it read as. Replaced with the decimal value. This is the prime
  suspect for those rules coming back vacuous and is the first thing review-2 should confirm.
- `DevVesting.spec` — VST-02/VST-03's end-of-schedule rules now restate the constructor's guards
  (`duration != 0`, `cliff <= duration`, no `uint64` overflow of `start + cliff` / `start +
  duration`), which arbitrary-storage rules do not get for free.

---

## 2026-09-12 — Formal verification (Certora) at review-1b: the three big specs retrieved and re-run

Review-1 left `FeeVault`, `RoundManager` and `FamilyHook` recorded as **unrun**. Their verdicts have
now been retrieved, every non-SUCCESS rule assessed against the contract from the Prover's own call
traces, the spec defects fixed, and all three re-run. Full write-up, per-rule tables and evidence in
`certora/RESULTS-review-1.md` ("Review-1b"); statuses in `certora/PROPERTY_MAP.md`.

| Spec | non-SUCCESS before | non-SUCCESS after |
|---|---|---|
| FeeVault | 13 / 29 | 7 / 29 |
| RoundManager | 17 / 30 | 10 / 30 |
| FamilyHook | 8 / 15 | 4 / 15 |

**No GENUINE BUG.** Every one of the 38 original failures, and every one of the 21 that remain, is a
spec-scoping defect, a spec-writing defect, a documented spec-vs-code divergence, or a deliberate
over-approximation in a summary. The consequence for the pipeline is the opposite of review-1's: the
statement "FEE-08/10/11, BID-05/07/14, CON-04/05, RND-01..15, PAR-01, CON-01, SCR-01..06 and
FEE-01/03/04 have no Certora evidence" in the review-1 entry above **no longer holds** — most of them
now do, with the exceptions named below.

Four root causes explain almost all of it, each confirmed from a call trace: parametric rules ranging
over the whole linked scene; `HAVOC_ALL`/`AUTO` summaries wiping non-persistent ghosts; immutables
being havoc'd so constructor guards were not available; and `NONDET` summaries of *view* reads
re-randomising between two reads of the same state.

### Findings, all **status: open**

1. **F-1 — `FamilyHook.registerPool` does not enforce `isGenesis => tradingStart == 0`.**
   *Scenario.* `registerPool` stores whatever the factory hands it, checking only
   `msg.sender == factory`. If a genesis pool were ever registered with a non-zero `tradingStart`,
   that pool would carry both the 1% protocol fee and the 99% snipe tax at once; `_collect` would
   compute `totalPpm = hopFeePpm + 10_000 + 990_000 >= PPM_DENOM` and every parent-paying
   exact-output swap in its first three seconds would revert `SnipeExactOutputTooLarge`.
   *Why it is not live.* `FamilyFactory.createGenesis` is the only caller that ever passes
   `isGenesis = true`, and it always passes `tradingStart = 0` (`FamilyFactory.sol:300`);
   `createCandidate` always passes `isGenesis = false` (`:388`). FEE-04 therefore holds in the
   deployed system — by the factory's discipline, not by the hook's.
   *Evidence.* `genesisIsNeverSniped` is left **violated** rather than quietly given the factory's
   precondition. *Fix.* One line in `registerPool`; it also turns the rule into a passing invariant.

2. **F-2 — sentinel collision in the drawdown token bucket.** `Drawdown.updatedAt == 0` means
   "untouched generation, full bucket" (`FeeVault.sol:804`) and the same field is written with
   `uint64(block.timestamp)` (`:842`). *Scenario.* At any `block.timestamp` congruent to 0 mod 2^64
   the first draw stores `updatedAt = 0`, re-arming the sentinel, and a second draw in the same block
   sees a fully refilled bucket — the Prover's counterexample drew 3114 against an allowance of 3113.
   *Why it is not live.* A live `block.timestamp` is neither 0 nor 2^64. Excluded by a
   well-formedness precondition, not by weakening BID-07. *Fix.* A separate `initialised` flag, or
   store `updatedAt + 1`.

3. **F-3 — sentinel collision in the end-request guard.** `requestEnd`'s once-per-round guard is
   `r.randomId != bytes32(0)`, and the id stored is whatever `randomness.pin()` returns. *Scenario.*
   A zero beacon id silently disarms the guard and the end can be requested twice for one round.
   *Why it is not live.* `DrandSource.pin()` returns `bytes32(round)`, so this needs beacon round 0.
   Same shape as F-2, and adjacent to the already-recorded RAN-04 divergence (nothing prevents one
   beacon round settling two RoundManager rounds — `PROPERTY_RESULTS.md` §2 gap 11).
   *Fix.* `if (randomId == bytes32(0)) revert BadBeaconId();`.

4. **F-4 — `FeeVault.accrue` hands control to an unknown successor with no reentrancy lock held.**
   *Scenario.* On the post-sunset path `accrue` → `this.forwardProtocolFee` →
   `IFeeVault(successor).accrueForwarded`. `accrue` is **not** `nonReentrant`, and at the moment
   foreign code runs, `reinforcementBalance[parentToken]` has been credited while
   `ledgerTotal[currency]` has not. *No loss was constructed*: the window leaves `ledgerTotal`
   understated (which satisfies the solvency bound more easily, not less), the claims pay only from
   their own ledgers, the consumption hooks are `onlyBidDeployer`, and a reentrant `flushForward`
   would have to `redeem` through `poolManager.unlock` from inside the hook's own unlock and would
   revert into the `try/catch` that already wraps the hop. *Fix.* Mark `accrue` `nonReentrant`, or
   move the `ledgerTotal[currency] +=` above the forwarding hop. Either would also let
   `FeeVault.spec` narrow the successor summary from `HAVOC_ALL` to `HAVOC_ECF`, which is what
   currently blocks seven FeeVault sub-goals from ever being inductive.

### Documentation defect found while doing this

**`docs/spec/PROPERTIES.md` §7 item 14 is arithmetically wrong and describes a case the code cannot
reach.** It says the summed parent-side rate reaches "100.075% at the hop-fee ceiling";
`990_000 + 10_000 + 10_000` is `1_010_000`, i.e. 101%. More importantly the three rates are never
summed on a real pool: `_collect` takes `protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0` while
`snipePpm` is 0 whenever `tradingStart == 0`, and the factory makes those two conditions mutually
exclusive. The real worst case is `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000`,
which now verifies as `summedRatesStayBelowOne`. This matches what `PROPERTY_RESULTS.md` §2 gap 14
measured (`990_000 + 10_000` on a candidate pool, reverting `SnipeExactOutputTooLarge`). §7.14 should
be corrected.

### What is still NOT covered, and why

- **FEE-01 (per-pool half) is UNPROVED.** `protocolFeeOnlyOnTheGenesisPool` comes back "not violated"
  but its `satisfy` companion `oneProtocolFeeAtTheEthEdgeIsReachable` **cannot be discharged** — the
  Prover cannot construct one fee-charging swap under the current summaries — so the verdict is
  vacuous. In review-1 that `satisfy` "passed" only because a havoc could move a counter nothing
  fed. This is the one verdict that got worse, and it is the honest one.
- **SCR-05, FEE-11 (`solvency`), FEE-10 (`ethLedgerDecomposition`), BID-07 (`bucketNeverExceedsCap`),
  BID-14, CON-05, RND-09, PAR-01, RND-07, RND-15, RND-03** have fixes applied after the review-1b run
  and **not yet re-run**; treat them as unproved until review-2 re-runs all three specs.
- **RND-12 (`bondIsMonotoneInDepth`)** still times out on the symbolic shift in `bondFor`. Pinning
  `BOND_DOUBLING_EVERY` to its deploy constant is what would make it tractable.
- **SLV-03** is still unproved (review-1 vacuity, `Sleeve.spec` not re-run in this pass).

---

## 2026-09-12 - review-2 contract fixes

Every item below was a **latent** observation from the review-1/1b formal pass: none was reachable on
a live chain, none was a loss anyone could construct, and each rested on the discipline of a single
caller or on a value that a live EVM cannot take. They are fixed anyway, so that the guarantee comes
from the contract rather than from an argument about its callers. Findings are in
`certora/RESULTS-review-1.md`; per-rule status in `certora/PROPERTY_MAP.md`.

| # | Change | Where | Regression test |
|---|---|---|---|
| F-1 | `isGenesis => tradingStart == 0` is enforced by the hook, not only by the factory. New error `GenesisHasNoSnipeWindow` | `FamilyHook.registerPool`, `IFamilyHook` | `Review2.t.sol::test_F1_aGenesisPoolCannotBeRegisteredWithASnipeWindow` |
| F-2 | The drawdown bucket's "untouched generation" is an explicit `Drawdown.initialised` flag instead of `updatedAt == 0`, and the refill clock is read in the same `uint64` domain the field is stored in, so a truncated clock cannot refill a spent bucket | `FeeVault.Drawdown`, `FeeVault._bucket`, `FeeVault.consumeAncestorClaim` | `Review2.t.sol::test_F2_theBucketBehavesIdenticallyOnFirstUseAndAfter`, `..._aStoredZeroTimestampIsNotReadAsAnUntouchedBucket` |
| F-3 | The once-per-round end-request guard is an explicit `Round.endRequested` flag instead of `randomId != bytes32(0)`, so a source returning a zero id cannot disarm it. `fulfilEnd`'s "not requested" test reads the same flag | `RoundManager.Round`, `RoundManager.requestEnd`, `RoundManager.fulfilEnd` | `Review2.t.sol::test_F3_theEndCannotBeRequestedTwice`, `..._aZeroRequestIdStillClosesTheRound` |
| F-4 | `FeeVault.accrue` is `nonReentrant`, and `ledgerTotal[currency]` is credited **in full before** the post-sunset hop hands control to an unknown successor vault (the protocol share is given back only after the hop has actually moved the claim out) | `FeeVault.accrue`, `IFeeVault.accrue` | `Review2.t.sol::test_F4_aHostileSuccessorCannotReenterTheAccrualPath` |
| 5 | `randomEndWindowFor(n) = max(1, min(RANDOM_END_S, D(n) / 4))`. A no-op on mainnet (`D(n) >= 15 min`, so `D(n)/4 >= 225 s`); it stops a heavily scaled testnet round from drawing `T_end` at or before its own `tradingStart`, and keeps the modulus in `fulfilEnd` defined | `RoundManager.randomEndWindowFor` | `Review2.t.sol::test_theRandomEndWindowIsUnchangedOnTheMainnetSchedule`, `Review2ScaledScheduleTest::test_theRandomEndWindowIsAQuarterOfAScaledRound`, `..._theWindowIsNeverZeroAndNeverMoreThanAQuarter`; `Round.prop.t.sol::testFuzz_RND01_...` |
| 6 | `addSleeve` checks `M > MAX_INDEX` **before** its `sleeve == 0` short-circuit, so an out-of-range index always reverts instead of being a silent no-op for a zero sleeve (SLV-07 as written) | `FenwickRangeAdd.addSleeve` | `Review2.t.sol::test_anOutOfRangeSleeveIndexAlwaysReverts` |
| W (flat closing window) | `closingWindowFor(n)` returns the constant `CLOSING_WINDOW_S = 15 min` divided by `DURATION_SCALE_DIV`, for every `n`. It used to be `D(n)/4` above an hour (2 h -> 30 min, 12 h -> 3 h). Maintainer decision, not a formal finding | `RoundManager.CLOSING_WINDOW_S`, `RoundManager.closingWindowFor` | `Review2.t.sol::test_theClosingWindowIsTheSameConstantOnEveryRound`, `..._theScoreRingsStillCoverTheFlatWindowAndItsTail`; `Schedule.t.sol::test_theClosingWindowIsFlatOnEveryRound`; `DeployConstants.t.sol`; `Round.prop.t.sol::testFuzz_RND01_...` |
| REN-01 | `notInsideUnlock` on `RoundManager.finalize`, `rank`, `requestEnd`, `finalizeDeterministic`, `submitScore` and on `FeeVault.claimDev` / `claimCreator` / `claimCreatorAccrued`. See the decision note below | new `contracts/libraries/V4UnlockGuard.sol`; `RoundManager`, `FeeVault`, `IFamilyHook.poolManager()` | `Review2.t.sol::test_REN01_theGuardReadsV4sOwnLockSlot`, `..._everyGuardedEntrypointRefusesFromInsideAnUnlock`, `..._theGuardChangesNothingOutsideAnUnlock` |

### REN-01 - the decision and the evidence for it

The property says nothing may re-enter the protocol from inside a `PoolManager` unlock;
`PROPERTY_RESULTS.md` recorded it as **divergent**, because being inside an unlock was not a state
the protocol checked (`RoundManager.finalize()` was measured executing from inside one).

Evidence gathered before choosing:

1. **The state is readable, cheaply.** v4-core keeps it in one transient slot,
   `Lock.IS_UNLOCKED_SLOT = bytes32(uint256(keccak256("Unlocked")) - 1)`
   (`lib/v4-core/src/libraries/Lock.sol`), and `PoolManager` inherits `Exttload`
   (`lib/v4-core/src/PoolManager.sol:80`), so one `exttload` reads it from outside. The constant is
   asserted against that definition in `Review2.t.sol::test_REN01_theGuardReadsV4sOwnLockSlot`.
2. **No protocol path reaches a guarded entrypoint from inside an unlock.** The four unlocks in the
   tree are `FamilyRouter` (route), `Locker` (curve and bid placement) and `FeeVault.redeem`. A
   tree-wide search finds **no internal caller at all** of `finalize`, `rank`, `requestEnd`,
   `finalizeDeterministic`, `submitScore` or any `claim*`; `BidDeployer` touches only
   `consumeAncestorClaim`, `consumeReinforcement`, `consumeGenesisEarmark` and `payKeeper`, none of
   which is guarded.
3. **The hook's own path is deliberately left alone.** `FamilyHook.afterSwap` and `FeeVault.accrue`
   run inside the swap's unlock on every single swap. Guarding those would break the protocol, and
   they are exactly the calls the property does not mean; neither touches the round machine or a
   claim. `test/HookScore.t.sol` and `test/Swap.t.sol` are unaffected.
4. **Two of the three claim paths were already half-guarded, inconsistently.** `claimDev`,
   `claimCreator` and `claimCreatorAccrued` call `redeem`, which calls `poolManager.unlock` and
   therefore already reverted `AlreadyUnlocked` from inside an unlock - but only when the vault held
   unredeemed ERC-6909 claims (`redeem` returns early at `claims == 0`). The guard makes that
   failure unconditional and loud instead of incidental.

So the guard was added. `RoundManager` holds no `PoolManager` reference of its own and gets one
through `hook.poolManager()` (a new getter on `IFamilyHook`, backed by the existing immutable), which
avoids a constructor change and its blast radius across the deploy script, the test harnesses and the
deployment records. `FeeVault` already holds the manager.

**Residual, disclosed:** an integrator that wants to batch a swap and a `submitScore` (or a claim)
inside one unlock of its own must now split them into two calls. Nothing in the protocol, the
scripts or the site did that.

### The flat closing window - ring coverage and the accepted risk

`scoreSlotFor(n) = ceil((W + RANDOM_END_S + END_TIMEOUT + SUBMIT_S) / 63)` derives the coarse ring's
spacing FROM `W` and the settlement tail, so shrinking `W` cannot leave the ring short. The
`END_TIMEOUT` term is review-2b below; the numbers, unscaled, with `END_TIMEOUT = 30 min`:

| | `W` | requirement `W + 180 + 1800 + 300` | coarse slot | coverage `63 x slot` |
|---|---|---|---|---|
| old sizing, rounds 1-6 | 900 s | (1380 s: tail without `END_TIMEOUT`) | 22 s | 1386 s |
| old sizing, round 13+ | 10,800 s | (11,280 s) | 180 s | 11,340 s |
| **every round, now** | **900 s** | **3180 s** | **51 s** | **3213 s** |

So the requirement is one number on every row, and it is the WORST case rather than the prompt one.
The fast ring is untouched: 36 x 5 = 180 s, exactly
`RANDOM_END_S`, which is what it exists to cover. Late entry closes at `D/3` and the window opens at
`D - W - 180`; a smaller `W` widens that margin on every round, so RND-02 gets easier, not harder.

The disclosed risk is unchanged in kind and larger in degree: a **window sniper** - capital equal to
the leader's, bought at the start of `W` and held - wins ~82% of a 4-hour round and ~93% of a 15-min
round (Sim 13), and a shorter window is the direction the simulation calls less safe. The maintainer's
reasoning for taking it anyway: **the random end already removes the last-seconds game, and a window
sniper must exit into the market it just pumped, which the simulation does not model.** Sim 13 scores
the position at the bell and never prices the exit out of a position the size of the leader's, in a
pool whose only depth is the locked curve and the family's own bids. The measured 82-93% is therefore
an upper bound on a real edge. Recorded in `docs/MECHANISM_v3.md` section 2 and in the threat model.

### Documentation corrected in the same pass

- `PROPERTIES.md` 7.14 - the "100.075%" figure was wrong (it would be 101%), and the three
  parent-side rates are never summed on one pool; the real bound is
  `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000`.
- `PROPERTIES.md` 7.7 - records the new random-end clamp.
- `PROTOCOL_SPEC.md` - `registerPool`'s full six-parameter signature is now written out (Certora
  review-1 finding #10, where the drafted CVL had a different arity and order), the claim paths are
  described as `notInsideUnlock`, and the threat model gains an "unlock interleaver" row and the F-4
  ordering note.
- `DEPLOY_CONSTANTS.md` - the random-end row and the `DURATION_SCALE_DIV` row carry the clamp, and
  state plainly that it is a no-op on mainnet; the scoring-window row and the checkpoint-ring row carry
  the flat `W` and its new ring numbers.
- `MECHANISM_v3.md` section 2 - the scoring bullet is the flat window, with the revision note; the
  risk trade-off paragraph is kept and the maintainer's reasoning added under it.
- `PROTOCOL_SPEC.md` section C/F - `W` is defined as the constant; the spike arithmetic, the ring
  coverage, the behaviour table and the threat model's window-sniper row are updated.
- `PROPERTIES.md` RND-01 and 7.7 - the flat `W`.
- `certora/specs/RoundManager.spec` - `CLOSING_WINDOW_S` declared envfree and `scheduleBounds` now
  asserts `closingWindowFor(n) == CLOSING_WINDOW_S / DURATION_SCALE_DIV` for every `n`.

### Verification

Full suite (fork tests excluded, they need an RPC): **316 passed, 0 failed, 1 skipped, 317 total** across 43 suites in 271 s. The one skip is SLV-03 at WAD granularity, the divergence this pass did not touch. REN-01's invariant was un-skipped and passes as the property states it. `test/Review2.t.sol` adds 15 tests. Sizes and the full record: `docs/security/full-suite-review-2.txt`. Largest deployed contracts: `RoundManagerDeployer` 22,741 B, `BidDeployer` 22,282 B, `RoundManager` 20,800 B - all under EIP-170.

**Open:** `sim/scenarios_v3.py` still models the OLD `W = D/4` rule (`window_for_duration`, `W_LONG_CAP_D_S`) and Sims 11-13 in `docs/sim-results-v3.md` were run against it. The simulation was deliberately not touched in this pass; re-running it against the flat window is a follow-up, and the window-sniper figures quoted in the docs are the old-rule ones.

## Review 2b - the independent review of commit `6fdd972`

Seven items, each mapped to the change that closes it and the test that holds it closed. Nothing
here was exploitable by an external caller as deployed except item 1, which needed only a late
beacon; the rest are defence in depth, deploy-time binding and documentation drift.

| # | Finding | Change | Test |
|---|---|---|---|
| 1 (high) | **Score ring reach.** `scoreSlotFor(n)` sized the coarse ring for a tail of `RANDOM_END_S + SUBMIT_S`, but `fulfilEnd` has no deadline: a round can be settled at `T + END_TIMEOUT` by `finalizeDeterministic`, which opens the submission window from THAT moment. The worst-case read span is `W + RANDOM_END_S + END_TIMEOUT + SUBMIT_S` (3180 s), against 63 x 22 = 1386 s of ring. A round whose beacon was never relayed, with one swap per slot in the gap, lost the far edge of its own closing window and `submitScore` reverted `CheckpointUnavailable` - the round could not be scored at all | `RoundManager.scoreSlotFor` now adds the `END_TIMEOUT` immutable: 51 s slots, 3213 s of reach on the mainnet schedule. Stale comments fixed in `FamilyHook.DEFAULT_SCORE_SLOT_S`, `RoundManager.Round.tradingEnd`, `PROTOCOL_SPEC.md` C/F (including `T_end = T - (r mod randomEndWindowFor(n))`) and the table above | `Review2.t.sol::test_aScoreSurvivesAFullBeaconTimeoutOfRingChurn` (the negative case: one swap per coarse slot for the whole `[T, T + END_TIMEOUT]` gap, then `finalizeDeterministic`, then `submitScore` at the last second of the window, equal to the average measured at `T`), `test_aScoreSurvivesASubmissionWindowOfRingChurnAfterAPromptFulfil`, `test_theScoreRingsCoverTheFlatWindowAndItsWholeTail`, `Schedule.t.sol::test_theScoreRingCoversTheWholeClosingWindowPlusTheTail` |
| 2 (medium) | **Unguarded paths.** `fulfilEnd` and `claimRefund` were the two state-changing entrypoints without `notInsideUnlock`, so the REN-01 property was asserted over an incomplete probe set | Both carry `notInsideUnlock` now; the property handler probes them | `Review2.t.sol::test_REN01_everyGuardedEntrypointRefusesFromInsideAnUnlock` (fulfilEnd, claimRefund, deployGenesisBid), `properties/PropHandler.sol` REN-01 probe set, `Invariants.prop.t.sol::invariant_REN01_nothingReentersFromInsideAnUnlock` with an accurate comment |
| 3 (medium) | **Fail-open slot.** `V4UnlockGuard` pins v4-core's internal lock slot as a constant. Against a manager whose slot differs the read answers `false` forever and every `notInsideUnlock` in the stack is a silent no-op - nothing anywhere proved the guard was bound to the DEPLOYED manager | `FamilyFactory.wire` now exercises the read and refuses to wire unless it works and answers `false` outside an unlock (`GuardNotBound`). `V4UnlockGuardProbe` opens a throwaway unlock and asserts the read answers `true` inside it; `script/Deploy.s.sol` runs it after deployment, reverts the deploy if it fails, logs `renGuardBound` and records it in the artefact's constants | `Review2.t.sol::test_REN01_theGuardIsBoundToTheDeployedPoolManager`, `test_REN01_wiringRevertsWhenTheGuardCannotReadTheManager`, and `test/fork/UnlockGuard.fork.t.sol::testFork_theUnlockGuardIsBoundToTheLiveManager` against the live singleton (skips without `RPC_TESTNET`) |
| 4 (low) | **Transient overstatement.** The protocol share was refunded to `ledgerTotal` AFTER the ERC-6909 transfer to the successor returned, so for the whole of the successor's call the claim had left while the ledger still counted it: `ledgerTotal > holdings` in exactly the window where foreign code reads the vault | `FeeVault.forwardProtocolFee` debits the ledger in the instruction BEFORE `poolManager.transfer`; `accrue` no longer refunds afterwards. F-4's "never understate" is unchanged: the debit and the holding move (and roll back) together | `Review2.t.sol::test_F4_aHostileSuccessorCannotReenterTheAccrualPath`, which now reads the victim's ledger and holdings from INSIDE the hop and asserts `ledgerTotal <= holdings` there |
| 5 (low) | **`MAX_INDEX` vs the Fenwick sleeve.** `maxIndex == 0` meant "unlimited", but the ancestor sleeve is three Fenwick trees over `FenwickRangeAdd.MAX_INDEX` + 1 = 4096 generations: a link crowned above 4095 could never be paid at all | The `RoundManager` constructor treats 0 as the Fenwick cap and reverts `BadMaxIndex` above it; the depth check is now a plain comparison | `Depth.t.sol::test_theDepthCapIsTheSleevesAndCannotBeDeployedPastIt` (both branches), `DeployConstants.t.sol` |
| 6 (low) | **Keeper entrypoints.** `deployAncestor`, `deployHopPot`, both `deployGenesisBid` overloads and `depositExternalBid` drew vault ledgers and read TWAP bands before reaching the nested unlock that would have refused them | All five carry `notInsideUnlock` and a `BidDeployer.InsideUnlock` error of their own | `Review2.t.sol::test_REN01_everyGuardedEntrypointRefusesFromInsideAnUnlock` (`deployGenesisBid`) |
| 7 (info) | **Drift.** `web/src/components/RandomEnd.tsx` derived "requested" from `!!round.randomId`, which a source returning a zero id would read as "never requested"; `SKIP_DIVERGENT` in `Round.prop.t.sol` was unused | The web reads the contract's own `endRequested` flag (already in the bundled `roundInfo` ABI, so no ABI regeneration is needed now - the usual `npm run sync` still has to run after the NEXT deploy); the unused constant is gone | typed in `web/src/data/useRound.ts` (`RoundInfo.endRequested`) and the demo fixtures |
## Review 3 - the purse is no longer contestable (2026-09-13)

Not a finding. A maintainer design decision, logged here because it REMOVES a protection that this
log previously recorded as working, and anyone reading the tree needs to see that stated plainly.

### What changed

Each generation's share of later fees (its slice of the ancestor sleeve) is now deployed, in full,
as locked bid liquidity under `canonical(j)` - the trunk coin that won round `j`. There is no
top-2 split, no ranking and no board.

Contracts:

- `RoundManager`: removed `rank(candidateId)`, `board(i)`, `purseWeights(i, idA, idB)`,
  `purseWindow(i)`, the `Rank` struct, the `_board` mapping, the `RANK_MAX_AGE` constant, the
  `Ranked` event and the `BadRanking` / `NotACrownedRound` errors. `roundOfIndex(i)` stays: the
  generation's siblings are still findable forever.
- `BidDeployer`: `deployAncestor(uint256 j, uint256 parentAmount)` (was
  `(j, parentAmount, idA, idB)`). `PurseSplit` is replaced by
  `PurseDeployed(generation, trunk, parentDeposited)`. `_purseSplit`, `_hasBoard`, `_bidTargetKey`
  and `_bidTargetToken` are gone; the single `_placeBid` call now takes `poolKeyOf(j)` and
  `canonical(j)` directly.
- Unchanged on the same path: the `min(spot, TWAP30, TWAP7d)` pricing walk, the +/-3% band on the
  target pool, the active-range size cap, the vault's daily drawdown bucket, the
  `max(1%, MIN_BOUNTY_WEI)` bounty under its `MAX_BOUNTY_SHARE_BPS` ceiling, the reinforcement
  top-up and the cross-version forwarding of a bid whose pool belongs to an earlier version.
- `script/Deploy.s.sol` no longer records `rankMaxAgeS`; `docs/DEPLOY_CONSTANTS.md` loses the row.

Sizes fell (runtime, EIP-170 limit 24,576): `RoundManager` 21,050 -> 19,132 B,
`RoundManagerDeployer` 23,051 -> 21,112 B, `BidDeployer` 22,755 -> 21,188 B.

### What the purse IS, said plainly

A purse deployment is a **permanent buy wall under the coin that won its round**. The generation's
ETH share buys parent tokens and locks them as a bid range under `canonical(j)`, running from just
under spot down to roughly 6% below it (10 tick spacings). It is never withdrawn, and it is a bid:
the coin's own holders can sell into it, at those prices, whenever they want. Two bounds keep one
deployment from being a shove rather than support: at most 2% of the target range's parent reserve
per deployment (`MAX_RESERVE_BPS`), and at most 10% of the generation's accrued ETH per 24 hours
(`DAILY_DRAW_BPS`).

None of that is new in review 3. The reinforcement share (20% of the fee) has been deployed as
locked bids under the parent coin since the first version; making the ancestor sleeve uncontested
extends the same property from 20% to 40% of the fee. Keeping value on the canonical chain, in bid
form under the trunk, is the intended outcome of the change and not a side effect of it.

**Pricing, corrected.** Earlier wording here read as if one price did both jobs. It does not. The
ETH that leaves the sleeve is priced along the links `0..j-1`, each hop at
`min(spot, 30-minute TWAP, 7-day TWAP)` - the conservative direction for the vault. The trunk pool
that receives the bid is handled separately: its spot sqrt price is band-checked to within about 3%
of its OWN 30-minute TWAP (roughly 6% in price terms), and the bid's tick range is then taken from
its live spot. The walk decides the size; the destination pool's live price decides the placement.

### What protection was removed, and why

**The dump penalty on a round winner.** Under the contested purse, a winner that was sold off lost
its share of the generation's purse to a sibling that held support (Sim 11: a 90%-dumping winner
lost the lead in 92% of trials and was out of the money in 84%). That is gone. A winner keeps its
generation's purse whatever happens to it afterwards, and a sibling that grows far past the winner
earns nothing from the chain's fee stream.

The reasoning, in the order it weighs (full text in `docs/MECHANISM_v3.md` §1):

1. **Value stays on the canonical chain.** Every later generation is priced through the trunk, so
   liquidity locked under a trunk link is liquidity every deeper coin trades against. Liquidity
   locked under a losing sibling sits on a branch nothing routes through, and the penalty moved it
   there at exactly the moment the chain needed depth.
2. **One sentence instead of five.** The contested rule needed a measurement, a window, a
   staleness bound, a ranking transaction and a tie policy to be stated honestly.
3. **A dumped or abandoned trunk coin is its community's to revive**, not the protocol's to
   penalise.

### What the removal also closes

- **The purse parker** (`PROTOCOL_SPEC.md` §U, Sim 11): parking capital in a sibling's pool to move
  the top-2 ranking and take purse share was break-even at the modelled fee flow and profitable
  above it, defended only by the length of the trailing window. There is no ranking to move, so the
  attack does not exist. The threat-model row is now "closed by removal".
- **The run-7 keeper leak** (`keeper/README.md` "First live run"): the keeper re-sent `rank(id)`
  forever for a sibling that could never take a seat on a two-seat board. The whole ranking path is
  gone; the purse path is one `deployAncestor(j, amount)` per crowned generation, budgeted at one
  send and inside the daily gas cap.
- Two spec gaps close with it: "purse split rounding" (there is no split) and "board staleness vs
  board correctness" (there is no board). `PROPERTIES.md` §7 records both.

### Properties

PUR-01, PUR-03, PUR-06 and PUR-07 are RETIRED with the ranking they described. PUR-02, PUR-04 and
PUR-05 are restated for the new rule and are covered at F:

- PUR-02, the destination is always `canonical(j)` and a loser never receives purse liquidity:
  `properties/Purse.prop.t.sol::testFuzz_PUR02_theDestinationIsAlwaysTheTrunk`.
- PUR-04, the amount conserves: `..._testFuzz_PUR04_theAmountConserves`.
- PUR-05, the daily bucket and the bounty rule are unchanged: `..._testFuzz_PUR05_theBucketAndBountyAreUnchanged`.

### Tests

`test/Purse.t.sol` (8 tests) and `test/properties/Purse.prop.t.sol` (3) were rewritten. The
headline negative case is `test_aLosingSiblingNeverReceivesPurseLiquidity`: the runner-up is bought
hard and the winner's own pool is dumped - exactly the state that moved the purse under the old
rule - and the `Locker.BidDeposited` log shows one bid, into the trunk pool, and none into either
loser's. `fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing` asserts
the same thing against the real singleton, counting `ModifyLiquidity` per pool.

Rank cases were removed from `Review2.t.sol` (the REN-01 probe list), `properties/PropHandler.sol`
(`propRank` and the reentry probe), `properties/Invariants.prop.t.sol`, `test/Keeper.t.sol`,
`test/FeeVault.t.sol`, `test/Depth.t.sol`, `test/properties/Bid.prop.t.sol`,
`test/utils/RoundTestBase.sol`, `test/utils/FamilyHandler.sol` and `test/medusa/MedusaTarget.sol`.
Nothing else was changed.

Full suite and sizes: `docs/security/full-suite-review-3.txt`. Keeper: `node --test`, 23 tests at the time of the change, 29 after the independent review below.

### Independent review of the review-3 diff (2026-09-13)

A separate read of the review-3 diff found **no contract defect**: the destination, the pricing
walk, the band, the size cap, the drawdown bucket and the bounty rule all behave as specified. Two
KEEPER defects and one framing gap were found and are fixed here.

- **F1 (liveness, keeper).** `purseSnapshot` gated on `roundOfIndex(headIndex) == roundId`, so the
  keeper only ever looked at a generation crowned by the round it was watching. A sleeve fills for
  as long as the chain trades past a generation, and the 10%-per-day bucket means a single
  generation usually takes several days to deploy in full, so every older funded sleeve was
  unreachable: the keeper looked once, found the head empty, and never looked again. Fixed: the
  snapshot scans `1..headIndex` in one batched read and proposes the first generation with
  deployable ETH whose bounty clears `MIN_BOUNTY_WEI`, still inside the one-send-per-generation
  budget and the daily gas cap. Tests: `keeper.test.mjs` "F1: an older generation with a funded
  sleeve is proposed, not the empty head" plus three siblings.
- **F4 (budget, keeper).** A purse transaction that was MINED but REVERTED consumed the
  generation's single send, retiring that sleeve for the life of the process on one unlucky block.
  Fixed: `noteSend`/`notePurseGas` run only behind a successful receipt; a reverted one logs
  `event: "revert"` with the decoded reason where the node gives one, `budgetConsumed: false`, and
  takes the normal 30 s backoff. Tests: `keeper.test.mjs` "F4: a mined-but-reverted purse tx spends
  no budget and no gas allowance" and its success counterpart.
- **F5 (web).** The chain page summed only `PurseDeployed` and so understated the liquidity locked
  under a coin, leaving out `HopPotDeployed`, which locks parent tokens under the same coin. The
  figure is now split into "from later trades" and "from hop fees", and the page says when the
  500,000-block log lookback truncates the sums.
- **F2/F3 (framing).** The "permanent buy wall" statement and the pricing correction above.

### Unknowns from that review

Listed as unknowns, not as findings, with what would close each:

- **Reinforcement writers for a fresh generation.** A newly crowned generation's parent-denominated
  hop pot has no measured fill rate; it is not known how often a fresh generation has enough in it
  for `deployHopPot` to be worth a keeper's gas. Closed by a live run that records hop-pot balances
  per generation over a full round cycle.
- **Live fill quality.** No purse bid has ever been placed on any chain, so how much of a bid range
  actually gets traded against, and at what prices, is unmeasured. Closed by the first live
  `deployAncestor` plus the swap history against that range.
- **Band tightness against a 30-minute pump.** The 3% sqrt band is checked against the target pool's
  own 30-minute TWAP. Whether that is tight enough against a patient manipulator who moves a thin
  pool and waits out the window is disclosed in `PROTOCOL_SPEC.md` but not measured. Closed by a
  simulation of a sustained 30-minute push against a pool at beta depth.
- **External `PurseSplit` consumers.** `PurseSplit` was removed in favour of `PurseDeployed`. No
  indexer, explorer or third party outside this tree is known to have consumed it, but that was
  checked only within this repository. Closed by a log scan of the testnet deployments for
  non-protocol readers of the old topic.

### Not covered

The uncontested purse has never been deployed on any chain. The live test to pass is ONE
`deployAncestor(j, amount)` with `PurseDeployed(j, canonical(j), amount)` in the receipt
(`ROADMAP.md` "[ALSO NEXT]"). Under rule 6 of the audit standard, that link is reported as broken
until it fires.

## Formal verification (Certora) at review-2

All five specs run against the contracts at tag `review-2`. Full per-rule assessment, with the
Prover's own call traces as evidence, is in `certora/RESULTS-review-2.md`; per-rule status is in
`certora/PROPERTY_MAP.md`. Job links (without their read keys) and artefacts are under
`private/certora/` (gitignored); no key of any kind is in a tracked file.

**No GENUINE CONTRACT BUG was found, and there are no new open findings against the contracts.**
Every non-SUCCESS is a spec-scoping or spec-writing defect, a Prover-tractability limit, or a
divergence `docs/security/PROPERTY_RESULTS.md` already records.

### The review-2 contract fixes, now checked formally

| Fix | Evidence | Verdict |
|---|---|---|
| F-1 `GenesisHasNoSnipeWindow` | `genesisIsNeverSniped` (restated as the inductive step) and the new `registerPoolRefusesAGenesisSnipeWindow` | both **verified**; review-1b had left the first deliberately failing |
| F-2 `Drawdown.initialised` | the new `twoDrawsCannotDoubleUpAtAnyClock` - the review-1b rule with its `wellFormedTime(e)` precondition **removed** | **verified** for every clock the Prover can pick, 0 and 2^64 included |
| F-3 `Round.endRequested` | `requestEndIsOnceAndNotBeforeT`, with the `pin()` summary relaxed to a fully arbitrary `bytes32` | **verified**; a zero beacon id can no longer disarm the guard |
| F-4 `accrue` is `nonReentrant` and credits before the hop | the successor summary narrowed `HAVOC_ALL` -> `HAVOC_ECF`, which review-1 gated on exactly this fix | **worked**: `deployerCreditSettles`, `pendingForwardTotalIsTheSum` and `valueLeavesOnlyOnPayoutMethods` went from 3 + 3 + 4 failing methods to fully verified |
| fix 6 `addSleeve` bounds-checks `M` first | `indexPastMaxReverts` with `sleeve > 0` removed | **verified**; SLV-07 now proves as written |

Also newly verified: `bondIsMonotoneInDepth` (RND-12, timed out twice before - pinning
`BOND_DOUBLING_EVERY` to its deploy constant made it tractable, so RND-12 is proved at the deployed
schedule rather than for every `doublingEvery`), `maxIndexIsRespected` (RND-15) and
`finalizeIsIdempotent` (RND-07). RoundManager is at 20 of 26 rules fully verified, FeeVault at 17 of
20, FamilyHook at 13 of 18.

### Open, and all of it about the SPECS rather than the contracts

- **S-1 (process).** A `loop_iter` below a data structure's real depth silently makes rules
  **vacuous** under `optimistic_loop`, because the "the loop has exited" assumption becomes
  unsatisfiable on exactly the paths that matter. `Sleeve.conf` carried `loop_iter: 12` against a
  13-deep Fenwick walk (`_add` steps `1, 2, 4, ... 4096` while `i <= 4097`), and that - not the
  `2^128` literal review-1 suspected - is why SLV-03's two rules came back "not violated" but
  sanity-failed in review-1 and again in review-2's first run. At `loop_iter: 14` they are
  non-vacuous and **time out**, so **SLV-03 is still unproved in Certora**; it passes at the fuzz
  tier at wei granularity (`Sleeve.prop::testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`), and the
  WAD-scale over-allocation remains the documented divergence it already was. Any conf whose subject
  walks a tree, a ring or a list should derive `loop_iter` from that structure's size.
- **S-2 (process).** `DevVesting.releasedNeverExceedsTotal` is a **tautology** - `total()` is defined
  as `balance + released` - and has been reported as verified since review-1 while proving nothing.
  Marked as such in the spec and in `PROPERTY_MAP.md`; VST-03's real content is carried by three
  other rules that do pass.
- **FEE-01's per-pool half is still unproved, and review-2 says exactly why.** A new rung-1
  `satisfy` shows that **no** fee accrual at all is reachable through `beforeSwap` under the present
  summaries, so `protocolFeeOnlyOnTheGenesisPool`'s "not violated" is vacuous coverage. It is not a
  fee-counting problem and not a missing link. Per-route counting stays a fork-tier property.
- **Five of RoundManager's six remaining failures are one missing summary.** `_.ownsToken` is the
  single delegated prior-registry read with no consistent-read summary; `parentOf`, `creatorOf`,
  `isCanonical` and `indexOf` all route through it, so two reads of the same getter in the same state
  disagree. One line per getter closes it. Not re-run: the run budget was spent.
- **`solvency` (FEE-11) is true but not inductive as stated.** Base, transient step and 16 of 20
  methods verify; the remaining four need the `deployerCredit` carve-out in the invariant
  (`ledgerTotal[c] + (c == ETH ? deployerCredit : 0) <= holdings(c)`), because `payKeeper` moves ETH
  that `consumeAncestorClaim` has already debited from the ledger.

The full review-3 action list is at the end of `certora/RESULTS-review-2.md`.

**Environment note.** Part-way through this pass the repository working tree was being edited by
another process (`contracts/`, `test/`, `keeper/`), and HEAD moved past the `review-2` tag. Because
the Prover compiles whatever is on disk at submission time, every job after that point was submitted
from a pristine `git archive review-2` export outside the repository, with the exported `contracts/`
byte-compared against `git show review-2:` first. Nothing in the Certora results describes those
concurrent edits.

## Formal verification (Certora) at review-3

All five specs run against the contracts at **review-3** (the uncontested purse). Full per-rule
assessment, with the Prover's own call traces as evidence, is in `certora/RESULTS-review-3.md`;
per-rule status is in `certora/PROPERTY_MAP.md`. Job links (without their read keys) and artefacts
are under `private/certora/` (gitignored); no key of any kind is in a tracked file. Every job was
submitted from a pristine `git archive HEAD` export outside the repository, so nothing being edited
in the working tree could reach a run.

**No GENUINE CONTRACT BUG was found, and there are no new open findings against the contracts.**

### The purse change, formally

The purse machinery the specs referenced was one line - `rank(uint256)` in `RoundManager.spec`'s
methods block - and it is removed. No rule, ghost or hook mentioned the board, the weights, the
window or the rank age, so nothing else had to go. PUR-02 splits in two: the half this tier can
falsify - that `canonical(j)`, which IS the destination, is fixed once the round crowns it - is
proved by `canonicalIsWriteOnce`, `historyEntriesAreImmutable` and
`onlyFinalizeOrAdoptionWritesHistory`; the half that says the liquidity LANDS in `poolKeyOf(j)` runs
through `Locker.depositBid` into the summarized v4 singleton and is **not expressible** without a
`BidDeployer.spec` of its own (CVL has no event predicate, so `PurseDeployed` is not a witness
either). It stays the fork test it already was. PUR-05's keeper-draw bound is now proved on both
sides: the daily bucket (`drawNeverExceedsTheBucket`) and, new this pass, the generation's own claim
(`drawNeverExceedsTheGenerationsClaim`) - which is what the uncontested purse rests on, since one
call now deploys a whole generation's share.

### The review-3 checklist, closed

- **`_.ownsToken` pinned** (plus `_.isIdle`). RoundManager's failing SUB-GOALS fell from 40 to 12;
  `historyEntriesAreImmutable` went 15/15 to 3/14 and `reverseIndexIsConsistent` 16/17 to 3/17, and
  the re-run discharged `headIndexOnlyGrows` and `pairingRightsAreWriteOnce` outright - 22 of 26
  rules now fully verified. The diagnosis review-2 made from a call trace was exactly right.
- **`solvency` carve-out.** `payKeeper`, the rule's own counterexample, now verifies; 17 of 20
  methods plus the base and the transient step pass. The three left are the other half of the same
  review-2 diagnosis (the fee claim is minted by the hook, outside this proof).
- **`ethLedgerDecomposition` regression reverted.** 10 failing methods down to 2, by tying each
  mirror to its storage word (absolute mirrors for the scalar ledgers, `Sload` pins for the mapping
  sums) instead of asserting non-negativity out of thin air. The re-run also proved the
  non-negativity of every ETH-side mirror as its OWN invariant (`ethMirrorsAreNonNegative`), which is
  the claim review-2 could not discharge inline - though assuming it inside the decomposition did not
  move the last two methods, and that is a review-4 item rather than a closed one.
- **SCR-05 proved** (`aSlotIsWrittenOnceByItsFirstSwap`), after a second precondition the first
  re-run's counterexample demanded: a `block.timestamp` that is a MULTIPLE of 2^64 truncates to 0
  inside `_checkpoint` and stamps a slot lower than it found it. Same family as finding F-2.
- **VST-03's `releasedNeverExceedsVested` proved**, by binding the allocation before `release()`.
- **FEE-01 localised to one call.** Two new `satisfy` rungs show that `beforeSwap` runs to
  completion AND reaches `poolManager.mint` inside `_collect` - so the fee path is live - while the
  vault call one line later is modelled as an unresolved AUTO summary, which means the spec's
  `_.accrue` summary never fires and the accrual counter has no writer. FEE-01's per-pool half is
  still unproved, but it is now a one-line spec experiment away rather than a mystery.

### Open, and all of it about the SPECS rather than the contracts

- **S-3 (new).** `isHeadWriter` in `RoundManager.spec` enumerated two of the three writers of
  `_head` / `_headIndex` and missed `registerGenesis`, the factory-only genesis seat - so
  `pairingRightsAreWriteOnce` was asserting something the contract never claimed. The contract is
  right; the spec was wrong. It was invisible until the `ownsToken` pin cleared the noise in front
  of it, which is the lesson: a residual modelling failure can hide a real spec defect behind it.
- **SLV-03 still unproved.** Bounding the Fenwick pre-state to 2^200 and the coefficients to 2^160
  proved `genesisTakesTheWholeSleeveAtMZero` for the first time, but the remaining counterexamples
  sit exactly ON those bounds and three rules still time out. One power of two tighter (the range a
  sleeve bounded by the vault's ETH can actually reach) is the next step.
- **The rest** is unchanged in kind from review-2: the `bucketNeverExceedsCap` Fenwick imprecision,
  the `averageOver` degenerate-window divergence that is deliberately kept, and one `submitScore`
  timeout.

## 2026-09-13 - mainnet bond flattened

Design decision, not a defect: the depth-doubling bond schedule (F6) was disabling depth-cost
economics only past generation 3, and priced spam the same way a flat bond would. Mainnet now
deploys `BOND_MAX_WEI == BOND_BASE_WEI` (0.008 ETH), so `bondFor` clamps to the same amount at
every depth; the contract's shift-overflow guard (`scaled >> doublings != BOND_BASE_WEI`) already
made this safe without any change to `contracts/`. Testnet keeps the doubling schedule so that
path of the contract is still exercised live. `test_mainnetBondIsFlatAtEveryDepth` pins
`bondFor(0)`, `bondFor(4)`, `bondFor(24)` and `bondFor(4095)` to the same value.
