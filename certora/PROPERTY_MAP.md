# Certora property map

Every rule and invariant in `certora/specs/`, mapped back to its `docs/spec/PROPERTIES.md` ID.
Status values, as of the **review-3** run (`certora/RESULTS-review-3.md`; every spec has now been run
against the contracts at review-3, the uncontested purse):
**verified** (ran and was not violated, and its sanity check passed), **violated** (ran and produced
a counterexample — see RESULTS for the assessment), **vacuous** (ran, reported "not violated", but
failed its `rule_sanity` vacuity check, so it proves nothing), **timeout**, **needs harness** (runs only
against a harness contract), **not expressible** (cannot be stated in Certora at all, with the
reason and the tier it belongs to).

The `<TODO link>` placeholders are gone: every conf is now runnable as-is.

## FeeVault.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| FEE-11 | FeeVault.spec | `solvency` (invariant) | **verified on the base, the transient step and 17 / 20 methods** (review-3). The `deployerCredit` carve-out closed `payKeeper`, the rule's own review-2 counterexample. The remaining 3 (`accrue`, `accrueForwarded`, `receiveForward`) are spec-scoping: the fee claim is minted to the vault by the HOOK before `accrue` is called, outside this proof and behind a summary |
| FEE-10 | FeeVault.spec | `ethMirrorsAreNonNegative` (invariant, new at review-3) | **verified (22/22)** - every ETH-side mirror is non-negative in every reachable state; this is the claim review-2 tried to conjoin into the decomposition and could not discharge there |
| FEE-10 | FeeVault.spec | `ethLedgerDecomposition` (invariant) | violated (**2 methods**, was 10) - the review-2 regression is reverted and each mirror is tied to its storage word (absolute mirrors for the scalar ledgers, `Sload` pins for the mapping sums). `accrue`: the Prover pairs a non-ETH currency with `parentToken == address(0)`, which the hook cannot produce. `forwardProtocolFee`: `ghostAncestorClaimed` starts negative on a path that reads no key, so no pin fires |
| FEE-08 | FeeVault.spec | `accrueConservesTheFee` | **verified** — upper bound only, see note 1 |
| FEE-08 | FeeVault.spec | `accrueMovesLedgerTotalByTheFee` | **verified** |
| FEE-10 | FeeVault.spec | `onlyAccrualPathsCredit` | **verified** |
| ROL-07 | FeeVault.spec | `creatorTransferIsALedgerMove` | verified |
| BID-07 | FeeVault.spec | `drawNeverExceedsTheBucket` | verified |
| BID-07 | FeeVault.spec | `bucketNeverExceedsCap` (invariant) | violated (3) + timeout (1), was 4 - unchanged diagnosis: Prover imprecision in the Fenwick `_prefix` walk (the `BWAnd` abstraction) at `loop_iter: 3`, which cannot be raised here. BID-07 holds at U/F |
| PUR-05, BID-07 | FeeVault.spec | `drawNeverExceedsTheGenerationsClaim` (new at review-3) | **verified** - the generation half of the keeper draw bound, which the UNCONTESTED purse rests on: one call now deploys a whole generation's share, and this is what stops it drawing another generation's ETH |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUp` | **verified** - surfaced finding F-2, now **closed in code**; see `twoDrawsCannotDoubleUpAtAnyClock` |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUpAtAnyClock` (new) | **verified** - the F-2 fix confirmed: the same claim with NO well-formedness precondition on the clock |
| BID-05 | FeeVault.spec | `payKeeperIsBoundedByDeployerCredit` | verified |
| BID-14 | FeeVault.spec | `deployerCreditSettles` (invariant) | **verified (20/20)** - unblocked by narrowing the successor summary to `HAVOC_ECF`, which F-4 gated |
| BID-05, FEE-10 | FeeVault.spec | `valueLeavesOnlyOnPayoutMethods` | **verified (20/20)** - same |
| BID-05 | FeeVault.spec | `onlyBidDeployerHooks` | verified |
| CON-05 | FeeVault.spec | `pendingForwardTotalIsTheSum` (invariant) | **verified (20/20)** - same |
| CON-05 | FeeVault.spec | `flushForwardConserves` | **verified** — post-state read from the write-log mirrors |
| CON-04 | FeeVault.spec | `postSunsetFeesAreNeverBookedLocally` | **verified** — `isSunset()` is NONDET, see note 2 |
| FEE-03, ROL-01 | FeeVault.spec | `ratesAndSplitsAreImmutable` | verified |
| REN-02 | FeeVault.spec | `claimZeroesBeforePaying` | verified |
| (F-4) | FeeVault.spec | the seven sub-goals blocked by the `HAVOC_ALL` successor summary (`solvency`, `bucketNeverExceedsCap`, `deployerCreditSettles`, `valueLeavesOnlyOnPayoutMethods`, `pendingForwardTotalIsTheSum`) | **unblocked at review-2**: `FeeVault.accrue` is now `nonReentrant` and credits `ledgerTotal` in full before the hop, which was the stated reason `HAVOC_ECF` was not applied blind (RESULTS review-1b, mechanism 5). Narrow `accrueForwarded` / `receiveForward` from `HAVOC_ALL` to `HAVOC_ECF` and re-run: the callee can no longer be modelled as rewriting this vault's own storage, and these rules should become inductive |

## RoundManager.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| RND-09 | RoundManager.spec | `canonicalIsWriteOnce` (invariant) | verified on 15 / 17 - the 2 left (`finalize`, `registerGenesis`) are spec-scoping: while `!adopted`, `headIndex()` DELEGATES to the prior registry, so `i > headIndex() => writes[i] == 0` compares a local write at index 6029 against a delegated head of 6027. The conjunct wants the LOCAL `_headIndex` |
| RND-09 | RoundManager.spec | `onlyFinalizeOrAdoptionWritesHistory` | **verified** |
| RND-09, PAR-02 | RoundManager.spec | `historyEntriesAreImmutable` | violated (**3 / 14**, was 15/15) - **the `_.ownsToken` pin worked**. The residual is spec-scoping: the counterexample's entry is `address(0)`, an empty slot inside the history length, and `addCandidate` then writes `_creatorOf[0x0]` for a candidate token the Prover also picked as `address(0)`. With that excluded, the residual is the DELEGATION one: `canonical` / `parentOf` / `creatorOf` all delegate while `!adopted`, and these three methods can flip the delegation decision mid-rule |
| RND-09 | RoundManager.spec | `historyLengthIsMonotone` | **verified** |
| RND-09 | RoundManager.spec | `reverseIndexIsConsistent` (invariant) | violated (**3 / 17**, was 16/17) - same story: the `ownsToken` pin worked, the residual is the zero-address entry |
| PAR-01 | RoundManager.spec | `pairingRightsAreWriteOnce` | **verified at review-3** (re-run) - it took **spec-writing defect S-3, found this pass**: `isHeadWriter` named `finalize` and `openRoundIfIdle` and MISSED `registerGenesis`, the third and last writer of `_head` / `_headIndex`. The contract is right; the rule was asserting something it never claimed |
| PAR-01 | RoundManager.spec | `headIndexOnlyGrows` | **verified at review-3** (re-run) - the residual pre-state was an EMPTY registry (`_head == 0`) with `_headIndex == MAX_UINT256`, which no constructor or writer can produce; restating that pairing discharges it |
| RND-07 | RoundManager.spec | `finalizeIsIdempotent` | **verified** at review-2 |
| RND-08 | RoundManager.spec | `noNewRoundBeforeFinalize` | verified |
| RND-13 | RoundManager.spec | `thresholdMovesOnlyInFinalize` | **verified** |
| RND-11 | RoundManager.spec | `winnersBondIsReturned` | verified |
| RND-11 | RoundManager.spec | `losersBondsAreForfeited` | verified — arrival side is FeeVault.spec, see note 3 |
| RND-04, RAN-03 | RoundManager.spec | `requestEndIsOnceAndNotBeforeT` | **verified at review-2 with a FULLY ARBITRARY `pin()`** (review-1b had to require it non-zero) - finding F-3 is closed in code and confirmed here |
| RND-05 | RoundManager.spec | `trueEndFallsInsideTheWindow` | **verified** |
| RND-06, RAN-06 | RoundManager.spec | `timeoutFallbackSettlesAtT` | verified — documentary assertion, see note 5 |
| RND-06, RAN-04 | RoundManager.spec | `endIsSettledAtMostOnce` | verified |
| RND-01 | RoundManager.spec | `scheduleIsPureInN` | verified |
| RND-01 | RoundManager.spec | `scheduleBounds` | **verified** — SPEC-GAP 7.7 encoded (scaled `W`) |
| RND-02 | RoundManager.spec | `lateEntryClosesBeforeTheClosingWindow` | verified |
| RND-12 | RoundManager.spec | `bondSaturates` | verified |
| RND-12 | RoundManager.spec | `bondIsMonotoneInDepth` | **verified** at review-2 - `BOND_DOUBLING_EVERY` pinned to its deploy constant (4). SCOPING RESTRICTION: proved at the deployed schedule, not for every `doublingEvery` |
| RND-15 | RoundManager.spec | `maxIndexIsRespected` | **verified** at review-2 |
| RND-03, ROL-01 | RoundManager.spec | `noTransitionIsPrivileged` | violated (3) + timeout (**1**: `submitScore`) - the `rank` timeout is gone with `rank` itself (review 3). ROL-01's substance is carried by `sunsetTouchesNothingElse` and (in `FeeVault.spec`) `onlyBidDeployerHooks` |
| RND-03, ROL-02 | RoundManager.spec | `sunsetTouchesNothingElse` | verified |
| CON-01 | RoundManager.spec | `adoptionHappensAtMostOnce` | **verified** |
| PUR-02 (half) | RoundManager.spec | `canonicalIsWriteOnce` + `historyEntriesAreImmutable` + `onlyFinalizeOrAdoptionWritesHistory` | the half of PUR-02 this tier can falsify, since the purse destination IS `canonical(j)` and is not an argument: it is fixed once the round crowns it. The landing step (`Locker.depositBid` into the summarized singleton) is in the not-expressible table below |

## DevVesting.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| VST-02 | DevVesting.spec | `nothingVestsBeforeTheCliff` | verified |
| VST-02 | DevVesting.spec | `everythingVestsAtTheEnd` | **verified** at review-2 |
| VST-02, VST-03 | DevVesting.spec | `vestedNeverExceedsTotal` | verified |
| VST-03 | DevVesting.spec | `vestedIsMonotoneInTime` | verified |
| VST-02 | DevVesting.spec | `theCliffUnlocksWhatAccruedSinceStart` | verified |
| VST-03 | DevVesting.spec | `releasedIsMonotone` | verified |
| VST-03 | DevVesting.spec | `releasedNeverExceedsTotal` (invariant) | **TAUTOLOGY, proves nothing** - SANITY_FAIL at review-2 on every sub-goal. `total()` is DEFINED as `balance + released`, so the invariant reduces to `released <= balance + released`. VST-03 is carried by `releasedIsMonotone`, `everythingVestsAtTheEnd` and `vestedNeverExceedsTotal` |
| VST-03 | DevVesting.spec | `onlyReleaseMovesReleased` | verified |
| VST-04 | DevVesting.spec | `releasePaysTheDeltaToTheCurrentBeneficiary` | **verified** at review-2 |
| VST-03 | DevVesting.spec | `releasedEqualsTotalAfterDuration` | **verified** at the review-2 re-run - `total()` is now read BEFORE `release()`, because OZ `safeTransfer` is an unresolved low-level call the Prover AUTO-havocs, and the clock is bounded to uint64 |
| VST-03 | DevVesting.spec | `releasedNeverExceedsVested` | **verified at review-3** - the allocation is bound BEFORE `release()`, exactly as `releasedEqualsTotalAfterDuration` does, because OZ `safeTransfer` is an unresolved low-level call the Prover AUTO-havocs |
| VST-05 | DevVesting.spec | `scheduleStorageIsImmutable` | verified |
| VST-05 | DevVesting.spec | `nothingReducesClaimableExceptRelease` | **verified** at review-2 |
| VST-05 | DevVesting.spec | `noAcceleration` | verified — SPEC-GAP: unsolicited transfers raise `total()` |
| ROL-05 | DevVesting.spec | `announceIsBeneficiaryOnly` | verified |
| ROL-05 | DevVesting.spec | `executeWaitsOutTheDelay` | verified |
| ROL-06 | DevVesting.spec | `roleTransferTouchesNothingElse` | verified |

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
| SLV-07 | Sleeve.spec | `reversedRangeReverts` | needs harness — verified|

## FamilyHook.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| SCR-01, SCR-02 | FamilyHook.spec | `scoreIsMonotoneInNetParentAbsorbed` | verified |
| SCR-02 | FamilyHook.spec | `onlyTheSwapPathMovesTheScore` | **verified** |
| SUP-06 | FamilyHook.spec | `donationsAreImpossible` | verified |
| SUP-05 | FamilyHook.spec | `liquidityIsARatchet` | verified |
| SCR-04 | FamilyHook.spec | `averageOverIsTheAccumulatorDifference` | verified — weakened, see note 7 |
| — (SPEC-GAP 7.12) | FamilyHook.spec | `averageOverHandlesTheDegenerateWindow` | violated — **spec-vs-code divergence, kept**: the code reverts `BadScoreWindow` (PROPERTIES 7.12) |
| SCR-05 | FamilyHook.spec | `aSlotIsWrittenOnceByItsFirstSwap` | **verified at review-3**, after TWO preconditions: no checkpoint from the future (`cpBefore.tSwap <= e.block.timestamp`) and a uint64 clock. The second one is the finding: a `block.timestamp` that is a MULTIPLE of 2^64 truncates to 0 inside `_checkpoint` and stamps the slot lower than it found it |
| SCR-06 | FamilyHook.spec | `theFastRingSpansTheRandomEndWindow` | verified |
| FEE-04 | FamilyHook.spec | `snipeTaxBounds` | verified |
| FEE-04, FEE-06 | FamilyHook.spec | `summedRatesStayBelowOne` | **verified** — SPEC-GAP 7.14 restated: the protocol fee and the snipe tax are mutually exclusive per pool, and 7.14's own arithmetic is wrong |
| FEE-03 | FamilyHook.spec | `feeRatesAreImmutable` | **verified** |
| FEE-01 | FamilyHook.spec | `protocolFeeOnlyOnTheGenesisPool` | not violated but **VACUOUS** - the counter it reads has no writer, because the spec's `_.accrue` summary never fires on the vault call (review-3 rungs 0 / 0.5 / 1 below). FEE-01's per-pool half stays UNPROVED |
| FEE-01 | FamilyHook.spec | `beforeSwapIsReachable` (`satisfy`, new at review-3) | **verified** - rung 0: `beforeSwap` does execute to completion under the present summaries |
| FEE-01 | FamilyHook.spec | `theFeeMintIsReachable` (`satisfy`, new at review-3) | **verified** - rung 0.5: execution reaches `poolManager.mint(feeVault, ...)` inside `_collect`, i.e. past the `equals(specified, parent)` early return AND with a non-zero total. The fee path is live |
| FEE-01 | FamilyHook.spec | `anyFeeAccrualIsReachable` (`satisfy`) | **violated** - rung 1, and with rungs 0 / 0.5 verified the loss is now localised to ONE call: the vault call one line after the mint is modelled as an unresolved AUTO summary, so the `_.accrue` summary never fires and the counter has no writer. A spec summary-matching defect, not unreachable code |
| FEE-01 | FamilyHook.spec | `someProtocolFeeIsReachable` (`satisfy`, new) | **violated** - rung 2 (`> before` instead of `== before + 1`) |
| FEE-01 | FamilyHook.spec | `oneProtocolFeeAtTheEthEdgeIsReachable` (`satisfy`) | **violated** - rung 3 of the reachability ladder |
| FEE-04 | FamilyHook.spec | `registerPoolRefusesAGenesisSnipeWindow` | **verified at review-2** (new) - the F-1 guard stated directly, independent of any starting storage |
| FEE-04 | FamilyHook.spec | `genesisIsNeverSniped` | **verified at review-2** - finding F-1 closed in code (`GenesisHasNoSnipeWindow`) and the rule restated as the inductive step it always was |

## Not expressible in these specs

| PROPERTIES ID | reason | belongs to |
|---|---|---|
| FEE-01 (per-route count) | `PoolManager.swap` is summarized NONDET, so the prover never executes legs 2..L of a route; the fee count over a whole `swapPath` cannot be counted inside a single-pool hook proof. | fork (K) — FEE-01 already carries tier K |
| ROU-02 | The comparison is "routed swap vs equivalent direct `PoolManager` swap, wei for wei"; both sides require a real PoolManager. Under NONDET both sides are unconstrained and the rule is vacuous. | fork (K) |
| REN-01 | "Reachable while the PoolManager unlock flag is set" is a property of the *singleton's* transient lock, which is summarized away. Certora cannot see the flag. Still not expressible here at review-2, even though the CODE now checks it: the guard is an `exttload` on the summarized PoolManager, so the Prover would have to model that singleton's transient storage. | stateful invariant (I) + fork (K) |
| PUR-02 (the landing step) | That the liquidity actually LANDS under `canonical(j)` is `locker.depositBid(roundManager.poolKeyOf(j), ...)` - an external call from `BidDeployer`, which has no spec or conf of its own, into the Locker and on into the v4 singleton, every entrypoint of which is summarized NONDET. CVL has no event predicate either, so `PurseDeployed` is not a usable witness. A `BidDeployer.spec` summarizing `_.depositBid(...)` into a ghost that records `(key, childToken)` is what would make it expressible. | fork (K): `fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing`, fuzz (F): `properties/Purse.prop.t.sol` |
| PUR-02 ("a loser never receives purse liquidity") | STRUCTURAL, and deliberately not stated as a rule: the destination is a pure function of `j` computed inside the deployer, and since review 3 there is no rank, no board and no caller-supplied token for a rule to quantify over. | fuzz (F), fork (K), as above |
| SUP-01 (supply constancy) | The family token is an EIP-1167 clone whose implementation is linked at deploy time; the clone has no verifiable bytecode of its own for the Prover to load. | unit / fuzz / stateful invariant (U, F, I) |
| SLV-03 (unbounded `M`) | The sum over `[0, M]` for symbolic `M` is a quantified sum over a symbolic range, which CVL cannot express. Bounded to `M <= 3` here. | Halmos (H) at bounded depth, fuzz (F) at full depth |
| SCR-04 (exact reconstruction) | Requires replaying an arbitrary swap history through both checkpoint rings; the ring walk plus the swap sequence is beyond the loop bound the Prover can discharge. | Halmos (H), stateful invariant (I) |
| BID-01..BID-04, BID-08..BID-13 | TWAP reads, band guards and tick arithmetic all bottom out in `SqrtPriceMath` / `LiquidityAmounts`, which PROPERTIES section 6 summarizes NONDET — the curve math belongs to Halmos, not Certora. | Halmos (H), fork (K) |
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
3. `FeeVault.depositGenesisBidEarmark` is summarized NONDET in `RoundManager.spec`; the arrival side
   of a forfeited bond is covered by `onlyAccrualPathsCredit` in `FeeVault.spec`.
4. "`requestEnd` pins a strictly future beacon round" is a property of `IRandomnessSource.pin()`,
   which is summarized NONDET. What is proved here is the once-per-round and not-before-`T` half.
5. The deterministic-fallback branch writes `tradingEnd = nominalEnd` with no beacon word involved.
   With `pin`/`fulfil` summarized, the rule reduces to a documentary assertion plus
   `endIsSettledAtMostOnce`, which is the load-bearing half.
6. `sumOfSharesNeverExceedsTheSleeveSmallM` is written out for `M <= 3` because CVL cannot quantify a
   sum over a symbolic range. The depth-independent half is `noShareExceedsTheSleeve`.
7. Reconstructing `acc` at both window edges from the rings needs the swap history; the rule is
   weakened to the attainment-time bound, which is what `submitScore` reads as `tFirstAttained`.
8. (superseded — see note 10.)
9. `protocolFeeOnlyOnTheGenesisPool` states the per-pool half of FEE-01 ("iff the pool is the genesis
   pool"), over the `parentToken` the hook hands the vault — `p.isGenesis ? address(0) : parent` — so
   that word IS the flag. It is **not violated but vacuous**: the `satisfy` beside it cannot be
   discharged, i.e. the Prover cannot construct one fee-charging swap under the current summaries, so
   FEE-01's per-pool half is unproved. The per-route count is in the not-expressible table above.
10. Note 8 above is obsolete: `ghostSlotWrites` is gone. SCR-05 is now stated against the contract's
    own `scoreCheckpoint()` getter either side of a swap, because an `Sstore` hook on the nested ring
    does not type-check (the key resolves to a `PoolId` identity a hook declaration cannot name).

## Spec gaps encoded as assumptions

| PROPERTIES 7 item | where | assumption encoded |
|---|---|---|
| 1 — one fee per ETH-edge traversal | FamilyHook.spec, FEE-01 block | one fee per traversal, i.e. two for a round trip |
| 7 — `DURATION_SCALE_DIV` vs `closingWindowFor` | RoundManager.spec, `scheduleBounds` | `W` is computed from the **scaled** `D` |
| 8 — "no fee on genesis-less paths" | FamilyHook.spec, FEE-01 block | the rule is read as "iff the pool is the genesis pool", not "iff one side is native ETH" |
| 12 — `averageOver` with `t1 == t0` | FamilyHook.spec, `averageOverHandlesTheDegenerateWindow` | does not revert; returns the instantaneous level |
| 14 — `hopFeePpm` at its ceiling | FamilyHook.spec, `summedRatesStayBelowOne` | **corrected in review-1b**: the rule states `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1e6`, because `_collect` never sums all three on one pool — the protocol fee needs `isGenesis` and the snipe tax needs `tradingStart != 0`, and, since review-2, the HOOK makes those mutually exclusive (`GenesisHasNoSnipeWindow`) rather than the factory alone. PROPERTIES 7.14's "100.075%" is arithmetically wrong (990000+10000+10000 = 101%). |
| — (§B.1 `total()` definition) | DevVesting.spec, `noAcceleration` | an unsolicited transfer in raises `total()` and is permitted |
| — (§J Fenwick residue) | FeeVault.spec, `ethLedgerDecomposition` | the floored residue stays in the vault and is not subtracted from `ledgerTotal` |
