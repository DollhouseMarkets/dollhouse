# Property results: F (stateless fuzz) and I (stateful invariant) tiers

Scope: every property of `docs/spec/PROPERTIES.md` carrying tier `F` or `I`, plus the `★`
properties whose only tier is `U` (checked for existing coverage rather than duplicated). The
tests live under `test/properties/` and run with `forge test --match-path 'test/properties/*'`.

A property is **divergent** when the implementation disagrees with the written statement. The
test is kept as the spec states it and its body is disabled through the file's `SKIP_DIVERGENT`
constant (`vm.skip(true)` in a test function; an early `return` in an invariant, which cannot
call a non-view cheatcode), with a `// DIVERGENCE <ID>:` comment naming what the code does.

## 0. Full-suite run

`FOUNDRY_THREADS=1 forge test --threads 1 --no-match-path 'test/{fork,halmos,properties,medusa}/**'`
(unit tier) plus `--match-path 'test/properties/**'` (property tier): **395 tests passed, 0
failed, 1 skipped** (396 total, 51 suites); the one skip is
`testFuzz_SLV03_sleeveIsNeverOverAllocated`, the symbolic case the forge tier does not run (Halmos
owns it). The fork tier (`test/fork/*`, needs an RPC
endpoint) is recorded separately and passed 38 of 38.

Properties restated for external genesis / $DOLL-only accounting, all passing at this run:

- **FEE-01** ("one edge fee per traversal of an edge pool"), `Fees.prop`
  `testFuzz_FEE01_oneEdgeFeePerTraversal`, `..._theEdgeFeeDoesNotDependOnDepth`,
  `..._aRoundTripPaysOneFeePerTraversal`.
- **FEE-06** (time-based exclusion: `protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM :
  0`), new suite `Fees.prop` `FeesEdgeWindowPropTest`:
  `testFuzz_FEE06_theEdgeFeeIsSuppressedWhileTheSnipeTaxRuns`,
  `..._exactOutputPricesThroughTheWholeWindow`.
- **SUP-04** (no protocol contract holds family supply; the vault's $DOLL holdings are bounded
  below by its ledgers, plus donations, and a donation is never sweepable), `invariant_SUP04_noProtocolContractHoldsSupply` and the vault-solvency invariant under FEE-11.
- **PUR-02** (destination is `canonical(j)`, with `j = 0` refusing `NoPoolAtIndex` and `j = 1`
  self-funded through `deployEdgeBid()`/`dollValueOfParent(1, x) == x`), `Purse.prop`
  `testFuzz_PUR02_theDestinationIsAlwaysTheTrunk`, extended for the two new edge cases.

Rows below for `SUP-02/03/08`, `FEE-01/02/12`, `FEE-10` and `PUR-02` that name `createGenesis` or
a genesis curve record the result against an in-protocol genesis launch; index 0 is now an adopted
external token, and the restated properties above cover that path. `SUP-03` has no successor test:
there is no genesis curve.

## 1. Property status

| ID | ★ | tier | test | status | note |
|---|---|---|---|---|---|
| SUP-01 | ★ | F,I | `Supply.prop` `testFuzz_SUP01_supplyOnlyEverFallsByAHoldersOwnBurn`, `testFuzz_SUP01_thereIsNoSecondMint`; `Invariants.prop` `invariant_SUP01_supplyNeverMoves` | pass | the launch dust burn happens inside `createGenesis`, so the post-launch supply is `1e27` less that dust; the test pins the dust and the fixed supply from there |
| SUP-02 | ★ | U,K | existing `Genesis.t.sol::test_genesisSupplyIsConserved`, `DevAllocation.t.sol` | pass | ★U already covered; not duplicated |
| SUP-04 | | I | `invariant_SUP04_noProtocolContractHoldsSupply` | pass | factory, round manager, router and bid deployer hold nothing; the Locker's sub-wei placement dust is immovable and excluded. Restated for the $DOLL-denominated vault: `ledgerTotal[EDGE] <= holdings(EDGE)` (FEE-11) and an unsolicited donation credits no ledger and is never sweepable |
| SUP-05 | | U,I,K | `invariant_SUP05_lockedLiquidityIsARatchet` | pass | |
| SUP-08 | | U,F | `Supply.prop` `testFuzz_SUP08_ticksAreDenominatedInTheWholeSupply` | pass | the tick-invariance half (changing `DEV_ALLOCATION_BPS` moves no tick) needs a second deployment per case; covered at U by `GenesisCurve.t.sol` / `DevAllocation.t.sol` |
| FEE-01 | ★ | F | `Fees.prop` `testFuzz_FEE01_oneEdgeFeePerTraversal`, `..._theEdgeFeeDoesNotDependOnDepth`, `..._aRoundTripPaysOneFeePerTraversal` | pass | restated: "one edge fee per traversal of an edge pool" (`isEdge = parent == canonical(0)`), not "the ETH edge", the tests were renamed to `dollIn`/edge-pool terms |
| FEE-02 | | U,K | `Fees.prop` `testFuzz_FEE02_everyLegPaysItsOwnHopFee` | pass | added at F beside the U coverage |
| FEE-04 | | F | `Fees.prop` `testFuzz_FEE04_theSnipeScheduleIsLinearOverThreeSeconds`, `..._asettledEdgePoolIsNeverSnipedAgain` | pass | the published formula matches the code exactly when the negative term is taken at true floor division; restated since every pool, edge pools included, now has a snipe window during its own first 3 s |
| FEE-05 | | F | `Fees.prop` `testFuzz_FEE05_theFeeIsAlwaysTheRateOfTheGross` | pass | each rate is floored independently, so the total is the sum of two floors; it is within 1 wei of the combined rate, as the property allows |
| ★ FEE-06 | | F | `Fees.prop` `FeesEdgeWindowPropTest` `testFuzz_FEE06_theEdgeFeeIsSuppressedWhileTheSnipeTaxRuns`, `..._exactOutputPricesThroughTheWholeWindow` | pass | restated: `protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0`, the edge fee is suppressed, never summed, during a round-one pool's own 3-second snipe window |
| FEE-08 | ★ | F,I | `Fees.prop` `testFuzz_FEE08_theProtocolFeeIsConserved`; `invariant_FEE08_familyLedgersAreHopFeesOnly` | pass | |
| FEE-10 | | I | `invariant_FEE10_everyEthDestinationIsANamedLedger` | pass | the named destinations never exceed the edge-currency ledger total; the gap is the sleeve's unclaimable floor residue. Ledgers renamed (`reinforcementEth` to `reinforcementEdge`, `genesisBidEarmark` to `edgeBidEarmark`); the invariant name is unchanged in the test file |
| FEE-11 | ★ | I | `invariant_FEE11_theVaultIsSolvent` | pass | |
| FEE-12 | | F | `Fees.prop` `testFuzz_FEE12_unattributedFeesFallBackToIndexZero` | pass | renamed (was `..._FallBackToGenesis`); the fallback is still index 0 of the sleeve, now the externally adopted token |
| SLV-01 | | F | `Sleeve.prop` `testFuzz_SLV01_ancestorShareMatchesTheWeightFamily` | pass | tolerance `17 + j + j²` WAD units: the floor error of the three coefficients |
| SLV-02 | | F | `Sleeve.prop` `testFuzz_SLV02_onlyAncestorsAreCredited` | pass | |
| SLV-03 | ★ | F,I | `Sleeve.prop` `testFuzz_SLV03_sleeveIsNeverOverAllocated` | **divergent** | at the WAD scale the trees store, the point queries can sum to a few hundred WAD units (≈1e-16 wei) MORE than the sleeve: `c1` is stored as `-floor(5a/M)`, i.e. rounded towards zero, so the negative term of `w` is slightly under-subtracted |
| SLV-03 | ★ | F | `Sleeve.prop` `testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`, `..._underAllocationHoldsAcrossManySleeves` | pass | at wei granularity (what `claimableAncestor` can ever pay) the sleeve is strictly under-allocated, which is what FEE-11 leans on |
| SLV-04 | | F,I | `Sleeve.prop` `testFuzz_SLV04_pointQueryEqualsBruteForce`, `..._signedRangeAddsMatchBruteForce` | pass | signed intermediates covered |
| SLV-07 | | U | `Sleeve.prop` `testFuzz_SLV07_indexAboveTheCapReverts` | pass | structural half only |
| SCR-01 | | F | `Score.prop` `testFuzz_SCR01_theAccumulatorIntegratesTheNetParentLevel` | pass | |
| SCR-02 | | U,I | `Score.prop` `testFuzz_SCR02_buysRaiseAndSellsLowerTheLevel` | pass | the stateless half; no invariant asserts "no other call moves `acc`" |
| SCR-03 | | F | `Score.prop` `testFuzz_SCR03_aSnipedBuyStillScoresItsPostFeeDelta` | pass | |
| SCR-04 | ★ | F,I | `Score.prop` `testFuzz_SCR04_averageOverIsExact` | pass | swaps spaced into their own coarse slots, as the property's "within the rings' span" requires. RESTATED: exactness is claimed only when both edges resolve to a bracket or to the live state; the inexact case is SCR-14 |
| SCR-13 | | U,I | `HookScore.t.sol` `test_aSecondSwapInTheBellsOwnSlotCannotDenyTheScore`, `test_aRingBuriedUnderPostBellDustStillAnswers`, `test_theFarEdgeOfTheWindowIsAlwaysResolvable`; `HookScore.t.sol` `test_postRevealDustCannotSelectADifferentScore`; Medusa `property_SCR13_scoreIsAlwaysSubmittable` | pass (new) | FAILED before the fix: a swap placed later in `T_end`'s own 5-second slot made `submitScore` revert `CheckpointUnavailable` for every candidate of the round. Availability is unchanged: the freeze removes the fallback's REACH into post-bell state, not the fallback itself |
| SCR-14 | | U,F | `HookScore.t.sol` `test_postBellFlowStillCannotMoveTheScore` (the never-after-`t` half); `test_aRingBuriedUnderPostBellDustStillAnswers` (the exactness half: the fallback reproduces the pre-dust average to the wei); `HookScore.t.sol` `test_farEdgeDriftIsAtMostOneCoarseSlot` (the DRIFT BOUND itself) | pass (restated) | the one-coarse-slot bound is now MEASURED, not merely argued: `averageOver` return `tStartUsed`/`tEndUsed`, so the instants actually used are readable and the test asserts the far edge is at or before `T_end - W` and within `scoreSlotFor(n)` of it. `BadScoreWindow` replaces a silent zero when the two edges collapse (F6), which `DeployConstants.t.sol` shows unreachable on both accepted schedule divisors |
| SCR-05 | | F,I | `Score.prop` `testFuzz_SCR05_aSlotIsWrittenOnceByItsFirstSwap` | pass | |
| SCR-06 | | U,H | `Round.prop` `testFuzz_SCR06_theCoarseRingSpansTheWholeRead`; `Schedule.t.sol` `test_theScoreRingsCoverTheFlatWindowAndTheRandomEnd`; `Schedule.t.sol` `test_theScoreRingCoversTheWholeClosingWindow` | pass (restated) | added at F. RESTATED (F1): the requirement is `W + RANDOM_END_S` (1080 s on mainnet, 18 s slots, 1134 s of reach), not `W + RANDOM_END_S + END_TIMEOUT + SUBMIT_S` - ring writes freeze at the pool's published end, so the ring must REACH the scored span and no longer has to SURVIVE churn during settlement |
| SCR-09 | | F | `Score.prop` `testFuzz_SCR09_supportSoldBeforeTheWindowDoesNotCount` | pass | needs a round longer than its own closing window (round 3+), otherwise the window covers the whole round |
| SCR-12 | | F | - | not covered | the tie comparator `_beats` is `internal` and no view exposes it; covered indirectly at U by `Round.t.sol::test_submitOrderingAttackCannotWin` |
| RND-01 | | F | `Round.prop` `testFuzz_RND01_scheduleIsAPureFunctionOfTheRoundNumber` | pass | asserted at the deployed `DURATION_SCALE_DIV`; see spec-gap 7 |
| RND-02 | | U,H | `Round.prop` `testFuzz_RND02_lateEntryEndsBeforeTheClosingWindowStarts` | pass | added at F |
| RND-03 | | I | `invariant_RND03_phasesNeverGoBackwards` | pass | monotonicity of the phase machine over any action sequence |
| RND-07 | | U,I,K | existing `Round.t.sol::test_staleFinalizeIsIdempotent` | pass | not duplicated at I |
| RND-08 | | U,I | `invariant_RND08_onlyOneRoundIsEverOpen` | pass | |
| RND-09 | ★ | I | `invariant_RND09_canonicalHistoryIsAppendOnly` | pass | write-once, no gaps, reverse index consistent |
| RND-11 | | F | `Round.prop` `testFuzz_RND11_bondsAreRefundedOrForfeited` | pass | |
| RND-12 | | F | `Round.prop` `testFuzz_RND12_bondScheduleSaturates`, `..._bondIsMonotone` | pass | |
| RND-13 | | F,I | `Round.prop` `testFuzz_RND13_thresholdDecaysOnlyAcrossFailures`; `invariant_RND13_theThresholdStaysInItsBand` | pass | |
| RND-14 | | F | `Round.prop` `testFuzz_RND14_registrationRequiresTheExactBond` | pass | |
| RND-16 | | I,K | - | not covered | an invariant cannot place a swap (invariant functions are `view` here); the handler trades losers' pools continuously, but nothing asserts tradability directly. Covered at U by `RouterGuards.t.sol` / `Router.prop` `testFuzz_ROU08_...` |
| PAR-01 | | I | `invariant_PAR01_theHeadMovesOnlyAtFinalize` | pass | head moves are counted against finalizing actions |
| PAR-02 | | I | `invariant_RND09_canonicalHistoryIsAppendOnly` | pass | `parentOf(i) == canonical(i-1)` for every i |
| PUR-02 | | F | `Purse.prop` `testFuzz_PUR02_theDestinationIsAlwaysTheTrunk` | pass | restated: the destination is `canonical(j)`, and a loser's pool receives no bid however well supported it is. It covers `j = 0` (`NoPoolAtIndex`) and `j = 1` (self-funded via `deployEdgeBid()`, `dollValueOfParent(1, x) == x`) as covered cases |
| PUR-04 | | F | `Purse.prop` `testFuzz_PUR04_theAmountConserves` | pass | restated: exactly `amount` leaves the keeper, at least `amount` is locked, nothing is stranded |
| PUR-05 | | F | `Purse.prop` `testFuzz_PUR05_theBucketAndBountyAreUnchanged` | pass | new: the removal moved nothing on the keeper path |
| BID-01 | | F | `Bid.prop` `testFuzz_BID01_bidsAreSingleSidedAndLocked` | pass | ten spacings wide, strictly on the parent side of spot |
| BID-02 | | F | `Bid.prop` `testFuzz_BID02_theConversionNeverPaysAboveSpot`, `..._theConversionIsLinearInTheAmount` | pass | the min-of-three is asserted through its consequence (never above spot, linear in size); the 30-minute-pump case is the existing `Keeper.t.sol` test |
| BID-05 | ★ | I | `invariant_BID05_theKeeperLeashIsNeverSlack` | pass | `deployerCredit == 0` outside a keeper call, and the deployer holds no ETH |
| BID-06 | | F | `Bid.prop` `testFuzz_BID06_theBountyIsTheStatedShape` | pass | all three branches; the keeper is paid value + bounty |
| BID-07 | | F,I | `Bid.prop` `testFuzz_BID07_theDrawdownBucketBindsAndRefills` | pass | bucket never above cap, second draw refused, continuous refill |
| BID-10 | | F,K | `Bid.prop` `testFuzz_BID10_theQuoteIsAcceptedAsIs` | pass | |
| BID-14 | | I | `invariant_BID05_theKeeperLeashIsNeverSlack` | pass | no residual credit after any keeper call |
| CON-02 | | U | `Continuation.prop` `testFuzz_CON02_noRoundBeforeTheHandover` | pass | added at F |
| CON-03 | | F | `Continuation.prop` `testFuzz_CON03_delegatedReadsAreHopBounded` | pass | one-hop delegation asserted; the 8-hop bound is a constant check (a real 9-deep stack is a K scenario) |
| CON-04 | | F | `Continuation.prop` `testFuzz_CON04_thePostSunsetEdgeNeverBooksLocally` | pass | also pins CON-11 (the hop fee stays with the charging version) |
| CON-05 | | F | `Continuation.prop` `testFuzz_CON05_flushMovesExactlyWhatItSays` | pass | partial flushes included |
| CON-09 | | U,K,I | `Continuation.prop` `testFuzz_CON09_theOldVaultKeepsWhatItEarned` | pass | asserted at F rather than by a two-stack handler |
| ROL-01 | ★ | I | `invariant_ROL01_thePrivilegedSurfaceIsUnreachable` | pass | no action of the handler moves a role, a sunset or a successor |
| ROL-05 | | F | `Roles.prop` `testFuzz_ROL05_*` (steward, developer, cancel) | pass | 7-day delay, holder-only announce/cancel, permissionless execute |
| ROL-07 | | F | `Roles.prop` `testFuzz_ROL07_transferSweepsTheAccrualToTheOldRecipient`, `..._onlyTheCurrentRecipientTransfers` | pass | |
| RAN-02 | | F | `Randomness.prop` `testFuzz_RAN02_*` (tampered, junk, wrong round) | pass | against a real `evmnet` beacon |
| RAN-03 | | F | `Randomness.prop` `testFuzz_RAN03_thePinnedBeaconIsAlwaysInTheFuture`, `..._pinningIsMonotoneInTime` | pass | |
| RAN-04 | | U,I | - | not covered | no test asserts that a beacon round consumed by one round cannot settle another; the code has no such check, see spec-gap 11 |
| ROU-01 | | F | `Router.prop` `testFuzz_ROU01_minOutIsEnforced`, `..._aRoundTripReportsItsLastLeg` | pass | |
| ROU-02 | | F | `Router.prop` `testFuzz_ROU02_theRouterIsNeverFeePrivileged` | pass | |
| ROU-04 | | F | `Router.prop` `testFuzz_ROU04_adjacencyIsEnforced`, `..._theEthEdgeOnlyTouchesGenesis`, `..._maxHopsBoundsTheWholeRoute` | pass | |
| ROU-05 | | F | `Router.prop` `testFuzz_ROU05_valueMustMatchThePath`, `..._theRouterHoldsNoEth` | pass | |
| ROU-08 | | U,K | `Router.prop` `testFuzz_ROU08_candidateRoutesFollowTheRoundPhase` | pass | added at F |
| REN-01 | | I | `invariant_REN01_nothingReentersFromInsideAnUnlock`; measured by `test_REN01_whichCallsAreReachableFromInsideAnUnlock`; `RoundGuards.t.sol::test_REN01_*` | pass (**was divergent; closed in code**) | being inside a `PoolManager` unlock used not to be a state the protocol checked, so `RoundManager.finalize()` was measured executing from inside one. `RoundManager.finalize`, `requestEnd`, `finalizeDeterministic`, `submitScore` and `FeeVault`'s three claim paths now carry `notInsideUnlock`, which reads v4-core's own transient lock flag (`Lock.IS_UNLOCKED_SLOT`) with one `exttload` through the PoolManager's inherited `Exttload`; the keeper entrypoints and `flushForward` reach a nested `poolManager.unlock` and revert `AlreadyUnlocked`. The hook's accrual path is deliberately NOT guarded - it is the one call that is meant to run inside the swap's unlock, on every swap. Closed in code |
| REN-02 | | U,I | - | not covered at I | ledger-before-transfer ordering is asserted at U in `FeeVault.t.sol`; an invariant cannot observe intra-call ordering |
| REN-03 | | F | - | not covered at F | covered at U by `Round.t.sol::test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth` |

## 2. The 14 spec gaps: what the implementation actually does

| # | Gap | What the code does |
|---|---|---|
| 1 | edge → … → edge round trip inside one `swapPath` | One protocol fee per traversal of an edge pool: a round trip pays two, each 1% of that leg's own $DOLL side (measured, `testFuzz_FEE01_aRoundTripPaysOneFeePerTraversal`). Restated in terms of `isEdge` rather than "the ETH edge", there is no native ETH anywhere in this stack. |
| 2 | Purse split rounding | CLOSED: there is no split. The whole `parentAmount` goes into one bid, under `canonical(j)`. |
| 3 | `MIN_BOUNTY_DOLL` mainnet value | There is none in code: it is a constructor argument of `BidDeployer` (`MIN_BOUNTY_DOLL`, immutable, renamed from `MIN_BOUNTY_WEI`), a placeholder in `script/Deploy.s.sol` to be calibrated from the graduated Pons price at deploy. Both the floor and the 20% ceiling branch are asserted against the deployed value. |
| 4 | Board staleness vs board correctness | CLOSED: there is no board. |
| 5 | `tFirstAttained` semantics | `averageOver` returns `tLastBefore` = the last score update at or before `tEnd` (`p.tLast`, or the bracketing checkpoint's `tState`), the LATTER reading, which is what `submitScore` stores and the tie rule compares. |
| 6 | Reads outside the ring's span | `_accumulatorAt` first tries the live state, then a bracketing checkpoint, then the EXACT-SAMPLE FALLBACK: the largest checkpointed `tSwap <= t` across both rings, evaluated at that `tSwap`. `averageOver` divides by the span between the two instants it actually used, and reverts `CheckpointUnavailable` only when the rings hold nothing at or before the edge. `trailingAverage` goes through the same helper, falls back to the OLDEST coarse checkpoint (evaluated at its `tSwap`, not extrapolated to the requested edge) when even that finds nothing, and returns `(0, 0)` before the pool's `tradingStart`. Without it, a read with no bracketing checkpoint would revert. |
| 7 | `DURATION_SCALE_DIV` vs `closingWindowFor` | The branch is chosen on the NOMINAL duration and the result is then scaled: `W = (raw ≤ 1 h ? 15 min : raw/4) / DIV`. `registrationFor` clamps on the nominal duration and divides afterwards; `lateEntryUntil` tests `raw ≥ 1 h` and divides afterwards. `randomEndWindowFor` is `max(1, min(RANDOM_END_S, D(n) / 4))`: it is clamped to a QUARTER of the scaled duration and floored at 1 s, so a scaled round can never draw `T_end` at or before its own `tradingStart` and the modulus in `fulfilEnd` is never zero. On mainnet `D(n) >= 15 min`, so `D(n)/4 >= 225 s` and the window is always `RANDOM_END_S` exactly - the clamp is a no-op there. |
| 8 | "No fee on non-edge paths", CLOSED | The hook charges the protocol fee iff the pool carries its `isEdge` flag (`parent == canonical(0)` at registration, renamed from `isGenesis`), suppressed for exactly the pool's own 3-second snipe window (`protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0`). Nothing in the fee test is keyed to currency; the currency-comparison branch that used to live in the post-sunset forwarding path is gone with native ETH. |
| 9 | `rank` before `finalize` | CLOSED: there is no `rank`. A generation that has not been crowned has no `canonical(j)`, and `deployAncestor` reverts `UnknownGeneration`. |
| 10 | Developer ledger asymmetry | Real and one-sided: `claimDev` pays the WHOLE `devBalance` to whoever holds the role at claim time, with no sweep on transfer, while `transferCreatorRecipient` sweeps `creatorBalance` into the outgoing recipient's `creatorAccrued`. |
| 11 | Beacon round reuse across rounds | Nothing prevents it. `DrandSource.pin()` returns `id = bytes32(round)`, so two rounds pinning in the same beacon period get the same id and the same signature settles both. Uniqueness is per RoundManager round only (`EndAlreadyRequested` / `EndAlreadySettled`). RAN-04 as written does not hold. |
| 12 | `averageOver` with `t1 == t0` | Reverts `BadScoreWindow` (`tEnd <= start` after clamping `start` to `tradingStart`). A second degenerate case: when both edges fall back to the SAME sample instant, the measured span is zero and the call returns `(0, tLastBefore)` rather than reverting - availability is the point of the fallback, and a candidate scoring zero is never flattered by it. |
| 14 | `hopFeePpm` at its ceiling | Deploying at `MAX_HOP_FEE_PPM = 10_000` is allowed (the constructor only rejects more). At the ceiling, a parent-paying exact-output swap in the first second of a candidate's snipe window has `990_000 + 10_000 = 1_000_000` ppm and reverts `SnipeExactOutputTooLarge` rather than wrapping, FEE-06's behaviour, reachable rather than unreachable. The MECHANISM here changed, not just the arithmetic: an edge pool is both edge-fee-eligible and snipe-taxed for its own first 3 s, and the two rates would sum past 100% if summed, so `protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0` suppresses the edge fee for that window instead of exempting the pool from snipe tax entirely (the prior `GenesisHasNoSnipeWindow` exemption and the `nominalEnd == 0` freeze exemption are both deleted; every pool now publishes a real end and freezes). The three parent-side rates are still never summed on ONE pool, and the real worst case is unchanged: `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000`. |

## 3. Files

Counts below are for the current tree.

| File | Tests |
|---|---|
| `test/properties/Supply.prop.t.sol` | 3 |
| `test/properties/Fees.prop.t.sol` | 9 |
| `test/properties/Sleeve.prop.t.sol` | 8 (1 divergent-skipped) |
| `test/properties/Score.prop.t.sol` | 6 |
| `test/properties/Round.prop.t.sol` | 8 |
| `test/properties/Purse.prop.t.sol` | 3 |
| `test/properties/Bid.prop.t.sol` | 6 |
| `test/properties/Continuation.prop.t.sol` | 5 |
| `test/properties/Roles.prop.t.sol` | 6 |
| `test/properties/Randomness.prop.t.sol` | 5 |
| `test/properties/Router.prop.t.sol` | 9 |
| `test/properties/Invariants.prop.t.sol` (+ `PropHandler.sol`) | 15 invariants (1 divergent) + 1 measurement test |

## 4. Deep run

Deep fuzz and invariant pass over nine property suites: `Fees.prop`, `Purse.prop`, `Invariants.prop` (with the
donation handler), `Bid.prop`, `Round.prop`, `Router.prop`, `Roles.prop`, `Continuation.prop` and
`Score.prop`. Settings: `FOUNDRY_FUZZ_RUNS=5000
FOUNDRY_INVARIANT_RUNS=400 FOUNDRY_INVARIANT_DEPTH=100`. Run one file at a time, single-threaded:

```bash
FOUNDRY_THREADS=1 FOUNDRY_FUZZ_RUNS=5000 FOUNDRY_INVARIANT_RUNS=400 FOUNDRY_INVARIANT_DEPTH=100 \
  forge test --threads 1 --match-path test/properties/<File>.prop.t.sol -vv
```

| File | Tests | Fuzz runs | Invariant runs × depth | Calls | Wall time | Result |
|---|---|---|---|---|---|---|
| `Fees.prop.t.sol` | 11 | 5000 | - | - | 65s | pass |
| `Purse.prop.t.sol` | 5 | 5000 | - | - | 39s | pass |
| `Invariants.prop.t.sol` (+ `PropHandler.sol`, donation handler) | 16 invariants + 1 measurement test | - | 400 × 100 | 40,000 | 104s | pass |
| `Bid.prop.t.sol` | 6 | 5000 | - | - | 31s | pass |
| `Round.prop.t.sol` | 8 | 5000 | - | - | 73s | pass |
| `Router.prop.t.sol` | 9 | 5000 | - | - | 38s | pass |
| `Roles.prop.t.sol` | 5 | 5000 | - | - | 7s | pass |
| `Continuation.prop.t.sol` | 5 | 5000 | - | - | 1628s (27.1 min) | pass |
| `Score.prop.t.sol` | 6 | 5000 | - | - | 71s | pass |

**Total: 71 tests (including the 16-invariant bundle and its measurement test), 0 failed, 0
skipped. Total forge wall time across the nine files: 2,056s (~34.3 minutes).**

`Continuation.prop.t.sol` deploys a full second or third protocol stack inside several of its fuzz
cases (`CON05` alone runs at a mean 58.1M gas per call), which is why it takes 27.1 minutes. No
contract or test-harness finding turned up in this run.

### SCR-10: the sampled instant

`HookScore.t.sol::test_theRingIsByteIdenticalAfterPostBellDust` and
`test_postRevealDustCannotSelectADifferentScore` raise SCR-10 from "no post-bell swap changes the
VALUE" to "no post-bell swap changes the INSTANT the edge resolves to, either". Burying the fast ring after the reveal must not move the `T_end` edge by a sample. What remains, and is now stated rather than implied, is a PRE-bell far-edge dilution
of at most one coarse slot (18 s against a 900 s window, 2.0%), which SCR-14 bounds and
`test_farEdgeDriftIsAtMostOneCoarseSlot` measures.
