# Certora Prover results

Formal verification of `RoundManager`, `FamilyHook` and `FeeVault` with the Certora Prover. Every
rule below is stated in `certora/specs/` and mapped to its `docs/spec/PROPERTIES.md` ID in
`certora/PROPERTY_MAP.md`.

- Prover: `certora-cli 8.19.2`. Compiler: solc `0.8.26`, `via_ir`, optimizer 200 runs, EVM `cancun`.
- Settings: `rule_sanity: basic` on every job, and no rule reported verified below failed its
  vacuity check. Configurations are in `certora/conf/`.

| Contract | Spec | Rules verified |
|---|---|---|
| `RoundManager` | `certora/specs/RoundManager.spec` | **31** of 36 |
| `FamilyHook` | `certora/specs/FamilyHook.spec` | **17** of the 21 run (23 authored, 2 disabled) |
| `FeeVault` | `certora/specs/FeeVault.spec` | **22** of 26 |
| **Total** | | **70** |

## RoundManager (`RoundManager.spec`): 31 verified

| Rule | Meaning |
|---|---|
| `onlyFinalizeOrAdoptionWritesHistory` | Only `finalize`, `openRoundIfIdle` (continuation adoption) and `adoptGenesis` write canonical history. |
| `historyLengthIsMonotone` | The canonical chain never shrinks. |
| `pairingRightsAreWriteOnce` | The head a candidate pairs against is written once per index and never rewritten. |
| `headIndexOnlyGrows` | The head index never decreases. |
| `finalizeIsIdempotent` | A second `finalize` of the same round changes nothing. |
| `noNewRoundBeforeFinalize` | A new round cannot open until the previous one is finalized. |
| `thresholdMovesOnlyInFinalize` | The winning threshold `H` changes only inside `finalize`. |
| `winnersBondIsReturned` | The winner's bond leaves escrow as a refund to its creator. |
| `losersBondsAreForfeited` | A loser's bond is forfeited, not refunded. |
| `addCandidateRefusesAnUnderDeliveredBond` | Registration reverts unless the full bond actually arrived in escrow. |
| `registrationNeverPullsMoreThanTheQuotedBond` | Registration never takes more than the bond quoted for that depth. |
| `finalizeBooksWhatItCouldNotDeliver` | Every forfeit `finalize` cannot deliver is booked as pending, never lost. |
| `pendingForfeitsMoveOnlyOnFinalizeOrFlush` | The held-forfeit ledger changes only in `finalize` and `flushForfeits`. |
| `flushForfeitsZeroesBeforeDelivering` | `flushForfeits` clears the ledger before any external call. |
| `theBondPushesAreSelfOnly` | `pushRefund` and `pushForfeit` are callable only by the contract itself. |
| `guardedFactoryEntrypointsCannotBeReentered` | `openRoundIfIdle` and `addCandidate` cannot be re-entered. |
| `requestEndIsOnceAndNotBeforeT` | The random end is requested once, and never before the published end `T`. |
| `trueEndFallsInsideTheWindow` | The settled end lies inside the random-end window before `T`. |
| `timeoutFallbackSettlesAtT` | The deterministic fallback settles the round at `T`. |
| `endIsSettledAtMostOnce` | A round's end is settled at most once, by beacon or by fallback. |
| `scheduleIsPureInN` | The round schedule depends only on the round number. |
| `scheduleBounds` | Every schedule getter stays within its stated bounds. |
| `theCoarseRingCoversTheScoredSpan` | The coarse checkpoint ring covers the closing window plus the random-end window, tightly. |
| `theConstructorsWindowGuardMatchesTheGetters` | The constructor's window guard computes the same values as the schedule getters. |
| `theScoredWindowAlwaysExceedsOneCoarseSlot` | The closing window is always longer than one coarse slot. |
| `lateEntryClosesBeforeTheClosingWindow` | Late entry always closes before the closing window opens. |
| `bondSaturates` | The bond never exceeds `BOND_MAX`. |
| `bondIsMonotoneInDepth` | The bond never falls as the chain gets deeper. |
| `maxIndexIsRespected` | No round opens past `MAX_INDEX`. |
| `sunsetTouchesNothingElse` | `announceSunset` changes no head, index, round count or threshold. |
| `adoptionHappensAtMostOnce` | A continuation adopts its prior version at most once. |

Not verified (5):

- `adoptGenesisIsOnceAndFactoryOnly`: counterexample on `adoptGenesis(address(0), ...)`, which left
  the once-only guard unset. A contract finding: `adoptGenesis` now carries a dedicated adoption
  flag and refuses the zero address (unit tests `test_adoptGenesisRefusesTheZeroAddress` and
  `test_adoptGenesisRevertsOnASecondCall`).
- `canonicalIsWriteOnce`, `historyEntriesAreImmutable`, `reverseIndexIsConsistent`: verified on
  every method except `adoptGenesis` (the same finding) and `finalize` / `addCandidate`, where the
  rules read the delegating getters that answer from the prior registry before adoption.
- `noTransitionIsPrivileged`: counterexamples on entrypoints that are caller-specific by design
  (`pushRefund`, `pushForfeit`, `claimRefund`) and on calls the spec summarizes nondeterministically;
  timeout on `submitScore`.

## FamilyHook (`FamilyHook.spec`): 17 verified

| Rule | Meaning |
|---|---|
| `scoreIsMonotoneInNetParentAbsorbed` | A pool's score rises with the parent tokens it absorbs, and only with them. |
| `onlyTheSwapPathMovesTheScore` | Only the swap callbacks change the score state. |
| `donationsAreImpossible` | `beforeDonate` always reverts. |
| `liquidityIsARatchet` | `beforeRemoveLiquidity` always reverts: locked liquidity never leaves. |
| `averageOverIsTheAccumulatorDifference` | The window average is exactly the accumulator difference over the sampled instants. |
| `averageOverRevertsOnACollapsedWindow` | A collapsed scoring window reverts `BadScoreWindow` rather than returning a value. |
| `aSlotIsWrittenOnceByItsFirstSwap` | Each checkpoint slot is written once, by the first swap in it. |
| `theFastRingSpansTheRandomEndWindow` | The fast checkpoint ring spans the whole random-end window. |
| `snipeTaxBounds` | The snipe tax starts at 99% and falls to 1% within `SNIPE_S`. |
| `feeRatesAreImmutable` | Hop, protocol and snipe rates never change. |
| `beforeSwapIsReachable` | `beforeSwap` is reachable (sanity rung). |
| `theFeeMintIsReachable` | The fee mint to the vault is reachable (sanity rung). |
| `registerPoolRefusesAPoolWithoutAPublishedEnd` | A candidate pool cannot be registered without a published end. |
| `everyRegisteredPoolHasAPublishedEnd` | Every registered pool has a published end. |
| `noRingEntryIsWrittenPastTheBell` | No checkpoint ring is written after the pool's published end. |
| `endSealIsWriteOnce` | The end seal never changes once laid. |
| `theEndSealIsOnlyLaidPastTheBell` | The end seal is laid only by the first swap after the published end. |

Not verified (4 run, 2 disabled):

- `summedRatesStayBelowOne`: the two assertions carrying the rate bounds are verified; the third
  fails only at `hopFeePpm == 0`, a value the rule leaves unconstrained (deployed: 750 ppm).
- `anyFeeAccrualIsReachable`, `someProtocolFeeIsReachable`, `oneProtocolFeeAtTheEdgeIsReachable`:
  `satisfy` rules; the Prover does not reach the vault's `accrue` call under this configuration.
  The one-fee-per-traversal property (FEE-01) is covered by the unit, fuzz and fork tiers.
- `protocolFeeOnlyAtTheEdge`, `theEdgeFeeIsSuppressedDuringTheSnipeWindow`: disabled, because the
  storage hook they need cannot name the `PoolId` key type in CVL. Covered by the unit and fuzz
  tiers.

## FeeVault (`FeeVault.spec`): 22 verified

These verdicts are for the vault with its ledgers held in native ETH, before the ledgers were
re-denominated into the edge token. The current `FeeVault.spec` restates the same rules in the edge
token (30 rules) and has no Prover verdict; its properties are checked symbolically over the current
vault bytecode by the Halmos checks recorded in `docs/security/`.

| Rule | Meaning |
|---|---|
| `ethMirrorsAreNonNegative` | Every ledger mirror is non-negative. |
| `accrueConservesTheFee` | One `accrue` credits exactly the hop and protocol fee, split across dev, creator, sleeve, reinforcement and hop. |
| `accrueMovesLedgerTotalByTheFee` | `accrue` raises the ledger total by at most what it was handed. |
| `onlyAccrualPathsCredit` | No method outside the accrual and queue paths increases any ledger. |
| `creatorTransferIsALedgerMove` | `transferCreatorRecipient` moves value between two ledgers and changes their sum by nothing. |
| `drawNeverExceedsTheBucket` | A draw never exceeds the daily token bucket. |
| `drawNeverExceedsTheGenerationsClaim` | A draw for generation `j` never exceeds `j`'s own claimable sleeve. |
| `twoDrawsCannotDoubleUp` | Two draws in the same instant cannot together exceed one bucket. |
| `twoDrawsCannotDoubleUpAtAnyClock` | The same, at every block timestamp. |
| `payKeeperIsBoundedByDeployerCredit` | `payKeeper` pays at most the credit created in the same call. |
| `deployerCreditSettles` | No residual keeper credit remains at rest. |
| `valueLeavesOnlyOnPayoutMethods` | Value leaves the vault only on a declared payout path. |
| `onlyBidDeployerHooks` | The four leashed hooks are callable by `BidDeployer` alone. |
| `pendingForwardTotalIsTheSum` | The forward-queue total equals the sum of its entries. |
| `flushForwardConserves` | A flush lowers the ledger by exactly what it delivered, or not at all. |
| `localBookingRequiresAgedEvidence` | A queued fee is booked locally only against dead-successor evidence already `DEAD_SUCCESSOR_DELAY` old. |
| `unresolvedSuccessorIsNeverEvidence` | A successor that did not resolve never counts as evidence of a dead one. |
| `deadEvidenceMovesOnlyOnTheForwardingPaths` | Only the forwarding paths can start or clear the dead-successor clock. |
| `candidateAttributionsCrossAsUnattributed` | A candidate's fee crosses a handover as unattributed. |
| `postSunsetFeesAreNeverBookedLocally` | After a sunset, fees are queued for the successor, never booked locally. |
| `ratesAndSplitsAreImmutable` | Fee rates and split shares never change. |
| `claimZeroesBeforePaying` | `claimDev` zeroes the balance before paying. |

Not verified (4):

- `solvency`, `ethLedgerDecomposition`: counterexamples only on the accrual paths, where the fee is
  minted to the vault by the hook before `accrue` runs, outside this spec's scene.
- `bucketNeverExceedsCap`: counterexamples from Prover imprecision in the Fenwick prefix walk at the
  configured loop bound; the property holds at the unit and fuzz tiers.
- `noPayoutPathCanBurnEthAtTheZeroAddress`: counterexample `payKeeper(address(0), 0)`, which returns
  without sending anything; the spec now requires a non-zero amount.
