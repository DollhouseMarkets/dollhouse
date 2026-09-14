# Property results — F (stateless fuzz) and I (stateful invariant) tiers

Scope: every property of `docs/spec/PROPERTIES.md` carrying tier `F` or `I`, plus the `★`
properties whose only tier is `U` (checked for existing coverage rather than duplicated). The
tests live under `test/properties/` and run with `forge test --match-path 'test/properties/*'`.

A property is **divergent** when the implementation disagrees with the written statement. The
test is kept as the spec states it and its body is disabled through the file's `SKIP_DIVERGENT`
constant (`vm.skip(true)` in a test function; an early `return` in an invariant, which cannot
call a non-view cheatcode), with a `// DIVERGENCE <ID>:` comment naming what the code does.

## 1. Property status

| ID | ★ | tier | test | status | note |
|---|---|---|---|---|---|
| SUP-01 | ★ | F,I | `Supply.prop` `testFuzz_SUP01_supplyOnlyEverFallsByAHoldersOwnBurn`, `testFuzz_SUP01_thereIsNoSecondMint`; `Invariants.prop` `invariant_SUP01_supplyNeverMoves` | pass | the launch dust burn happens inside `createGenesis`, so the post-launch supply is `1e27` less that dust; the test pins the dust and the fixed supply from there |
| SUP-02 | ★ | U,K | existing `Genesis.t.sol::test_genesisSupplyIsConserved`, `DevAllocation.t.sol` | pass | ★U already covered; not duplicated |
| SUP-04 | | I | `invariant_SUP04_noProtocolContractHoldsSupply` | pass | factory, round manager, router and bid deployer hold nothing; the Locker's sub-wei placement dust is immovable and excluded |
| SUP-05 | | U,I,K | `invariant_SUP05_lockedLiquidityIsARatchet` | pass | |
| SUP-08 | | U,F | `Supply.prop` `testFuzz_SUP08_ticksAreDenominatedInTheWholeSupply` | pass | the tick-invariance half (changing `DEV_ALLOCATION_BPS` moves no tick) needs a second deployment per case; covered at U by `GenesisCurve.t.sol` / `DevAllocation.t.sol` |
| FEE-01 | ★ | F | `Fees.prop` `testFuzz_FEE01_oneEdgeFeePerTraversal`, `..._theEdgeFeeDoesNotDependOnDepth`, `..._aRoundTripPaysOneFeePerTraversal` | pass | |
| FEE-02 | | U,K | `Fees.prop` `testFuzz_FEE02_everyLegPaysItsOwnHopFee` | pass | added at F beside the U coverage |
| FEE-04 | | F | `Fees.prop` `testFuzz_FEE04_theSnipeScheduleIsLinearOverThreeSeconds`, `..._genesisIsNeverSniped` | pass | the published formula matches the code exactly when the negative term is taken at true floor division |
| FEE-05 | | F | `Fees.prop` `testFuzz_FEE05_theFeeIsAlwaysTheRateOfTheGross` | pass | each rate is floored independently, so the total is the sum of two floors; it is within 1 wei of the combined rate, as the property allows |
| FEE-08 | ★ | F,I | `Fees.prop` `testFuzz_FEE08_theProtocolFeeIsConserved`; `invariant_FEE08_familyLedgersAreHopFeesOnly` | pass | |
| FEE-10 | | I | `invariant_FEE10_everyEthDestinationIsANamedLedger` | pass | the named destinations never exceed the ETH ledger total; the gap is the sleeve's unclaimable floor residue |
| FEE-11 | ★ | I | `invariant_FEE11_theVaultIsSolvent` | pass | |
| FEE-12 | | F | `Fees.prop` `testFuzz_FEE12_unattributedFeesFallBackToGenesis` | pass | |
| SLV-01 | | F | `Sleeve.prop` `testFuzz_SLV01_ancestorShareMatchesTheWeightFamily` | pass | tolerance `17 + j + j²` WAD units: the floor error of the three coefficients |
| SLV-02 | | F | `Sleeve.prop` `testFuzz_SLV02_onlyAncestorsAreCredited` | pass | |
| SLV-03 | ★ | F,I | `Sleeve.prop` `testFuzz_SLV03_sleeveIsNeverOverAllocated` | **divergent** | at the WAD scale the trees store, the point queries can sum to a few hundred WAD units (≈1e-16 wei) MORE than the sleeve: `c1` is stored as `-floor(5a/M)`, i.e. rounded towards zero, so the negative term of `w` is slightly under-subtracted |
| SLV-03 | ★ | F | `Sleeve.prop` `testFuzz_SLV03_creditedWeiNeverExceedsTheSleeve`, `..._underAllocationHoldsAcrossManySleeves` | pass | at wei granularity — what `claimableAncestor` can ever pay — the sleeve is strictly under-allocated, which is what FEE-11 leans on |
| SLV-04 | | F,I | `Sleeve.prop` `testFuzz_SLV04_pointQueryEqualsBruteForce`, `..._signedRangeAddsMatchBruteForce` | pass | signed intermediates covered |
| SLV-07 | | U | `Sleeve.prop` `testFuzz_SLV07_indexAboveTheCapReverts` | pass | structural half only |
| SCR-01 | | F | `Score.prop` `testFuzz_SCR01_theAccumulatorIntegratesTheNetParentLevel` | pass | |
| SCR-02 | | U,I | `Score.prop` `testFuzz_SCR02_buysRaiseAndSellsLowerTheLevel` | pass | the stateless half; no invariant asserts "no other call moves `acc`" |
| SCR-03 | | F | `Score.prop` `testFuzz_SCR03_aSnipedBuyStillScoresItsPostFeeDelta` | pass | |
| SCR-04 | ★ | F,I | `Score.prop` `testFuzz_SCR04_averageOverIsExact` | pass | swaps spaced into their own coarse slots, as the property's "within the rings' span" requires |
| SCR-05 | | F,I | `Score.prop` `testFuzz_SCR05_aSlotIsWrittenOnceByItsFirstSwap` | pass | |
| SCR-06 | | U,H | `Round.prop` `testFuzz_SCR06_theCoarseRingSpansTheWholeRead` | pass | added at F |
| SCR-09 | | F | `Score.prop` `testFuzz_SCR09_supportSoldBeforeTheWindowDoesNotCount` | pass | needs a round longer than its own closing window (round 3+), otherwise the window covers the whole round |
| SCR-12 | | F | — | not covered | the tie comparator `_beats` is `internal` and no view exposes it; covered indirectly at U by `Round.t.sol::test_submitOrderingAttackCannotWin` |
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
| RND-16 | | I,K | — | not covered | an invariant cannot place a swap (invariant functions are `view` here); the handler trades losers' pools continuously, but nothing asserts tradability directly. Covered at U by `RouterGuards.t.sol` / `Router.prop` `testFuzz_ROU08_...` |
| PAR-01 | | I | `invariant_PAR01_theHeadMovesOnlyAtFinalize` | pass | head moves are counted against finalizing actions |
| PAR-02 | | I | `invariant_RND09_canonicalHistoryIsAppendOnly` | pass | `parentOf(i) == canonical(i-1)` for every i |
| PUR-01 | | - | — | retired (review 3) | there is no `rank`; the purse is not contestable |
| PUR-02 | | F | `Purse.prop` `testFuzz_PUR02_theDestinationIsAlwaysTheTrunk` | pass | restated for review 3: the destination is `canonical(j)`, and a loser's pool receives no bid however well supported it is |
| PUR-03 | | - | — | retired (review 3) | there is no board and no keeper-supplied pair |
| PUR-04 | | F | `Purse.prop` `testFuzz_PUR04_theAmountConserves` | pass | restated for review 3: exactly `amount` leaves the keeper, at least `amount` is locked, nothing is stranded |
| PUR-05 | | F | `Purse.prop` `testFuzz_PUR05_theBucketAndBountyAreUnchanged` | pass | new in review 3: the removal moved nothing on the keeper path |
| PUR-06 | | - | — | retired (review 3) | nothing is measured for the purse at all |
| PUR-07 | | - | — | retired (review 3) | `trailingAverage` still runs, but no payout depends on it |
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
| ROL-05 | | F | `Roles.prop` `testFuzz_ROL05_*` (steward, developer, beneficiary, cancel) | pass | 7-day delay, holder-only announce/cancel, permissionless execute |
| ROL-07 | | F | `Roles.prop` `testFuzz_ROL07_transferSweepsTheAccrualToTheOldRecipient`, `..._onlyTheCurrentRecipientTransfers` | pass | |
| VST-01 | | F | `Vesting.prop` `testFuzz_VST01_totalIsHeldPlusReleased` | pass | |
| VST-02 | | F | `Vesting.prop` `testFuzz_VST02_theScheduleIsTheStatedClosedForm`, `..._theCliffUnlocksItsAccruedShare` | pass | the cliff unlocks ≈8.2%, not zero |
| VST-03 | | F | `Vesting.prop` `testFuzz_VST03_releasedIsMonotoneAndBounded` | pass | |
| VST-04 | | F | `Vesting.prop` `testFuzz_VST04_releaseIsPermissionlessAndPaysTheDelta` | pass | |
| RAN-02 | | F | `Randomness.prop` `testFuzz_RAN02_*` (tampered, junk, wrong round) | pass | against a real `evmnet` beacon |
| RAN-03 | | F | `Randomness.prop` `testFuzz_RAN03_thePinnedBeaconIsAlwaysInTheFuture`, `..._pinningIsMonotoneInTime` | pass | |
| RAN-04 | | U,I | — | not covered | no test asserts that a beacon round consumed by one round cannot settle another; the code has no such check — see spec-gap 11 |
| ROU-01 | | F | `Router.prop` `testFuzz_ROU01_minOutIsEnforced`, `..._aRoundTripReportsItsLastLeg` | pass | |
| ROU-02 | | F | `Router.prop` `testFuzz_ROU02_theRouterIsNeverFeePrivileged` | pass | |
| ROU-04 | | F | `Router.prop` `testFuzz_ROU04_adjacencyIsEnforced`, `..._theEthEdgeOnlyTouchesGenesis`, `..._maxHopsBoundsTheWholeRoute` | pass | |
| ROU-05 | | F | `Router.prop` `testFuzz_ROU05_valueMustMatchThePath`, `..._theRouterHoldsNoEth` | pass | |
| ROU-08 | | U,K | `Router.prop` `testFuzz_ROU08_candidateRoutesFollowTheRoundPhase` | pass | added at F |
| REN-01 | | I | `invariant_REN01_nothingReentersFromInsideAnUnlock`; measured by `test_REN01_whichCallsAreReachableFromInsideAnUnlock`; `Review2.t.sol::test_REN01_*` | pass (**was divergent; closed in code at review-2**) | being inside a `PoolManager` unlock used not to be a state the protocol checked, so `RoundManager.finalize()` was measured executing from inside one. `RoundManager.finalize`, `requestEnd`, `finalizeDeterministic`, `submitScore` and `FeeVault`'s three claim paths now carry `notInsideUnlock`, which reads v4-core's own transient lock flag (`Lock.IS_UNLOCKED_SLOT`) with one `exttload` through the PoolManager's inherited `Exttload`; the keeper entrypoints and `flushForward` reach a nested `poolManager.unlock` and revert `AlreadyUnlocked`. The hook's accrual path is deliberately NOT guarded - it is the one call that is meant to run inside the swap's unlock, on every swap. Evidence and the decision are in `docs/attack-log.md` (review-2) |
| REN-02 | | U,I | — | not covered at I | ledger-before-transfer ordering is asserted at U in `FeeVault.t.sol`; an invariant cannot observe intra-call ordering |
| REN-03 | | F | — | not covered at F | covered at U by `Round.t.sol::test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth` |

## 2. The 14 spec gaps — what the implementation actually does

| # | Gap | What the code does |
|---|---|---|
| 1 | ETH → … → ETH round trip inside one `swapPath` | One protocol fee per traversal of the ETH edge: a round trip pays two, each 1% of that leg's own ETH side (measured, `testFuzz_FEE01_aRoundTripPaysOneFeePerTraversal`). |
| 2 | Purse split rounding | CLOSED by review 3: there is no split. The whole `parentAmount` goes into one bid, under `canonical(j)`. |
| 3 | `MIN_BOUNTY_WEI` mainnet value | There is none in code: it is a constructor argument of `BidDeployer` (`MIN_BOUNTY_WEI`, immutable), 3e14 in the test harness and the testnet row. Both the floor and the 20% ceiling branch are asserted against the deployed value. |
| 4 | Board staleness vs board correctness | CLOSED by review 3: there is no board. |
| 5 | `tFirstAttained` semantics | `averageOver` returns `tLastBefore` = the last score update at or before `tEnd` (`p.tLast`, or the bracketing checkpoint's `tState`) — the LATTER reading, which is what `submitScore` stores and the tie rule compares. |
| 6 | Reads outside the ring's span | `_accumulatorAt` reverts `CheckpointUnavailable` when neither ring brackets `t` (so `averageOver`/`submitScore` revert). `trailingAverage` instead falls back to the OLDEST coarse checkpoint and reports the shorter `coveredSeconds`. |
| 7 | `DURATION_SCALE_DIV` vs `closingWindowFor` | The branch is chosen on the NOMINAL duration and the result is then scaled: `W = (raw ≤ 1 h ? 15 min : raw/4) / DIV`. `registrationFor` clamps on the nominal duration and divides afterwards; `lateEntryUntil` tests `raw ≥ 1 h` and divides afterwards. `randomEndWindowFor` is, since review-2, `max(1, min(RANDOM_END_S, D(n) / 4))`: it is clamped to a QUARTER of the scaled duration and floored at 1 s, so a scaled round can never draw `T_end` at or before its own `tradingStart` and the modulus in `fulfilEnd` is never zero. On mainnet `D(n) >= 15 min`, so `D(n)/4 >= 225 s` and the window is always `RANDOM_END_S` exactly - the clamp is a no-op there. |
| 8 | "No fee on genesis-less paths" | The hook charges the protocol fee iff the pool carries its `isGenesis` flag (set by the factory at registration), not by currency. The post-sunset forwarding branch in `FeeVault.accrue` is the one place that tests the currency (`currency.isAddressZero()`). |
| 9 | `rank` before `finalize` | CLOSED by review 3: there is no `rank`. A generation that has not been crowned has no `canonical(j)`, and `deployAncestor` reverts `UnknownGeneration`. |
| 10 | Developer ledger asymmetry | Real and one-sided: `claimDev` pays the WHOLE `devBalance` to whoever holds the role at claim time, with no sweep on transfer, while `transferCreatorRecipient` sweeps `creatorBalance` into the outgoing recipient's `creatorAccrued`. |
| 11 | Beacon round reuse across rounds | Nothing prevents it. `DrandSource.pin()` returns `id = bytes32(round)`, so two rounds pinning in the same beacon period get the same id and the same signature settles both. Uniqueness is per RoundManager round only (`EndAlreadyRequested` / `EndAlreadySettled`). RAN-04 as written does not hold. |
| 12 | `averageOver` with `t1 == t0` | Reverts `BadScoreWindow` (`tEnd <= start` after clamping `start` to `tradingStart`). |
| 13 | Genesis vesting under continuation | Independent, as assumed: the beneficiary is read once, at genesis, from the ORIGINAL stack's `FeeVault.developer()`; a continuation deploys its own vault with its own developer and mints no allocation. |
| 14 | `hopFeePpm` at its ceiling | Deploying at `MAX_HOP_FEE_PPM = 10_000` is allowed (the constructor only rejects more). At the ceiling, a parent-paying exact-output swap in the first second of a candidate's snipe window has `990_000 + 10_000 = 1_000_000` ppm and reverts `SnipeExactOutputTooLarge` rather than wrapping — FEE-06's behaviour, reachable rather than unreachable. |  The three parent-side rates are never summed on ONE pool: `_collect` takes `protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0` and the snipe tax is zero whenever `tradingStart == 0`, which the hook itself enforces for the genesis pool since review-2 (`GenesisHasNoSnipeWindow`). PROPERTIES 7.14's "100.075%" was arithmetically wrong (990_000 + 10_000 + 10_000 = 101%) and has been corrected there.

## 3. Files

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
| `test/properties/Vesting.prop.t.sol` | 5 |
| `test/properties/Randomness.prop.t.sol` | 5 |
| `test/properties/Router.prop.t.sol` | 9 |
| `test/properties/Invariants.prop.t.sol` (+ `PropHandler.sol`) | 15 invariants (1 divergent) + 1 measurement test |
