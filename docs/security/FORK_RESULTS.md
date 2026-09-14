# Fork results — K tier (real Uniswap v4 `PoolManager`, chain 46630)

Scope: the fork-test scenarios of `docs/spec/PROPERTIES.md` sec.4. The tests live under
`test/fork/` and run with

```
RPC_TESTNET=<endpoint> forge test --match-path 'test/fork/*'
```

Every scenario deploys a **fresh** stack into the fork — the deploy-script constants, the real
singleton, and nothing else pre-existing. No live state is mutated and no address from a local
`.env` or key store is read: the only environment variable used is `RPC_TESTNET`, and when it is
absent every test in the tier reports `SKIP` instead of failing.

## 1. What was forked

| item | value |
|---|---|
| chain id | 46630 |
| `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `PoolManager` `address.codehash` | `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626` |
| recorded run, chain height | ~118 017 927 – 118 029 620 (2026-09-12) |
| stack constants | `script/Deploy.s.sol` testnet row: hop 750 ppm, creator 40 %, sleeve 20 %, reinforcement 20 %, dev allocation 3 %, bond 0.001–0.064 ETH, `DURATION_SCALE_DIV = 60`, `SUNSET_DELAY_S = 1 h`, `END_TIMEOUT_S = 30 min` |
| randomness | labelled `MockRandomnessSource`, as a testnet deploy uses when `RANDOMNESS_SOURCE` is unset |

**On pinning.** The public endpoint serves only a short window of historical *state*. A block a
few thousand blocks back is answered for some reads and rejected with
`error code -32000: metadata is not found` for others, which aborts a fork test outright (observed
twice against a hard pin at 118 017 927, roughly 8 000 blocks / a few minutes old). A hard-coded
pin is therefore not reproducible in practice on this endpoint, so `ForkBase` takes the fork at
the **latest** block unless `FORK_BLOCK` is set (use it with an archive endpoint to replay a
recorded run). Identity of the singleton is pinned instead by the code hash above, which
`testFork_poolManagerIdentity` asserts on every run — that is the value a reviewer should compare.

## 2. Scenario status

| scenario (sec.4) | property IDs | test | status |
|---|---|---|---|
| 1. Genesis launch and first buy | SUP-02, SUP-03, SUP-08, FEE-01, FEE-02, FEE-08, FEE-13, ROU-01, ROU-02 | `Genesis.fork.t.sol` — `testFork_SUP03_genesisSupplyIsPlacedOrVested`, `testFork_SUP02_candidatePlacesTheWholeSupply`, `testFork_SUP07_poolIsInitializedAtTheRegisteredPrice`, `testFork_FEE01_firstRoutedBuyChargesOneEdgeFee`, `testFork_FEE13_feeBasisIsTheFullSpecifiedAmount` | pass |
| 2. Three-deep path, fee-once | FEE-01, FEE-02, ROU-03, ROU-04 | `Path.fork.t.sol` — `testFork_FEE01_threeDeepPathChargesOneEdgeFee`, `testFork_FEE01_theEdgeFeeDoesNotDependOnDepth`, `testFork_FEE02_everyLegPaysItsOwnHopFee`, `testFork_ROU04_reverseRouteChargesOneEdgeFee`, `testFork_ROU03_aRouteWithoutTheEdgePaysNoProtocolFee` | pass |
| 3. Snipe tax at +1 s / +2 s / +4 s | FEE-04, FEE-05, SCR-03 | `Snipe.fork.t.sol` — `testFork_FEE04_snipeTaxFollowsTheLinearSchedule`, `testFork_FEE04_genesisIsNeverSniped`, `testFork_FEE05_parityBetweenExactInAndExactOut`, `testFork_SCR03_snipedBuysStillScoreAndScoreMoreLater` | pass |
| 4. Late entry plus closing-window win | RND-04, RND-05, RND-07, RND-11, SCR-07, SCR-09, SCR-10 | `Round.fork.t.sol` — `testFork_SCR07_lateEntrantMatchesAnEqualClosingWindowLevel`, `testFork_RND04_theEndIsDrawnInsideItsWindow`, `testFork_SCR10_swapsAfterTheEndDoNotMoveTheSubmittedScore`, `testFork_RND11_forfeitedBondsLandInTheEarmark` | pass, with one leg not runnable: **the real drand relay**. A pinned or latest fork cannot produce a beacon for a round pinned inside the fork, and no relayer submits into a local fork, so the end is settled through the labelled mock source. The verifier itself is exercised against real beacons at the unit tier (`test/Drand.t.sol`). |
| 5. Beacon timeout fallback | RND-06, RAN-06 | `Round.fork.t.sol` — `testFork_RND06_beaconTimeoutFallback` | pass |
| 6. Purse split | PUR-01, PUR-03, PUR-04, PUR-07, BID-01, BID-05 | `Purse.fork.t.sol` — `testFork_PUR01_rankingIsPermissionlessAndTakesOnlyAnId`, `testFork_PUR04_thePurseIsSplitAndRankThreeGetsNothing`, `testFork_PUR03_theBoardIsVerifiedAndExpires`, `testFork_PUR07_aDumpedWinnerLosesThePurseButNotTheTrunk` | pass |
| 7. Keeper pricing and drawdown | BID-02, BID-03, BID-04, BID-07 | — | **not run in this tier.** The scenario is a pure clock-and-oracle exercise (30 min of TWAP per assertion, then repeated draws); it touches the singleton only through the same `getSlot0`/observation reads scenario 6 already drives on the real contract. Covered at U and F by `Keeper.t.sol` and `test/properties/`. |
| 8. Continuation handover | CON-01, CON-04, CON-05, CON-06 | `Continuation.fork.t.sol` — `testFork_CON01_theSuccessorAdoptsTheHeadAtTheHandover`, `testFork_CON04_theEdgeIsForwardedToTheSuccessorVault`, `testFork_CON05_beforeTheHandoverTheEdgeStaysWithTheIncumbent` | pass for the adoption and forwarding legs. **Not run here:** the gas-burning successor (CON-07) and the three-version `flushForward` queue (CON-09), which need stand-in contracts and no singleton behaviour at all; both are covered at U by `test/Continuation.t.sol`. |
| 9. Locked-liquidity negative tests | SUP-05, SUP-06, SUP-07, REN-01 | `Genesis.fork.t.sol` — `testFork_SUP05_lockedLiquidityCannotBeRemoved`, `testFork_SUP06_addLiquidityAndDonateAreRefused`, `testFork_SUP07_unregisteredKeyAndWrongPriceAreRefused` | pass |
| 10. Role transfers under real time | ROL-04, ROL-05 | `Continuation.fork.t.sol` — `testFork_ROL05_theStewardRoleMovesOnlyOnItsPublicDelay` | pass for the steward role. **Not run here:** the developer and vesting-beneficiary transfers (ROL-06, VST-05), which touch no pool; covered at U by `RoleTransfer.t.sol` and `DevVesting.t.sol`. |

Recorded run: **31 tests, 31 passed, 0 failed, 0 skipped**, 74 s of test time (142 s wall
including compilation), single-threaded.

## 3. Differences against the local mock-based tiers

1. **`block.number` is not the chain height.** Inside the fork `block.number` reports the
   settlement layer's reference height (e.g. 11 688 236 while the fork was created at
   118 017 927), so it cannot be used to identify what was forked and must never be used as a
   clock. Every schedule in the system is denominated in `block.timestamp`, which behaves
   normally — but any future code that reasons in blocks would be wrong on this chain.
2. **Historical state is not durably available.** See the pinning note above. Consequence for
   reviewers: the K tier must be run against a live endpoint, and a failure that mentions
   `metadata is not found` is an endpoint problem, not a property violation.
3. **Everything else matched.** The fee arithmetic, the gross-up in both swap modes, the hook
   gate on `beforeInitialize` / `beforeAddLiquidity` / `beforeRemoveLiquidity` / `beforeDonate`,
   the curve placement and dust burn, the score accumulator, the purse split and the
   cross-version fee forwarding all produced the same numbers on the real singleton as on the
   locally constructed one. No assertion needed loosening for the fork, and the only assertion
   that was rewritten during development (the parent-token balance of the singleton after a purse
   deployment) was rewritten because it was a wrong statement about ERC-6909 claim accounting,
   not because of a fork difference.
