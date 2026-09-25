# Certora property map

Every rule and invariant in `certora/specs/`, mapped back to its `docs/spec/PROPERTIES.md` ID.

Verdicts are summarized in `RESULTS.md`. `RoundManager` and `FamilyHook` rows carry the verdicts of
the current specs against the current contracts. `FeeVault` rows describe the current spec, which is
stated in the edge token and has no Prover verdict, next to the verdict each rule had against the
vault with its ledgers in native ETH ("ETH-denominated vault"). `Sleeve.spec` rows carry the verdicts
of its own harness runs.

Status values: **verified** (ran without a violation, and its sanity check passed), **violated**
(ran and produced a counterexample, see `RESULTS.md` for the assessment), **vacuous** (ran, reported
"not violated", but failed its `rule_sanity` vacuity check, so it proves nothing), **timeout**,
**needs harness** (runs only against a harness contract), **not expressible** (cannot be stated in
Certora at all, with the reason and the tier it belongs to), **no verdict** (stated in the current
spec, not yet checked by the Prover), and **disabled** (present in the spec but commented out, with
the reason and the restore condition, so that nothing passes vacuously in its place).

## FeeVault.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| FEE-11, SUP-04 | FeeVault.spec | `solvency` (invariant) | no verdict. States `ledgerTotal[c] + (c == EDGE ? deployerCredit : 0) <= holdings(c)` with `EDGE` the linked edge token, and `holdings` an ERC-20 balance plus unredeemed claims. The INEQUALITY is load-bearing: a donation of the edge currency raises `holdings` and credits nothing, and no path sweeps the difference. ETH-denominated vault: verified on the base, the transient step and 17 / 20 methods; the 3 left are the accrual paths, where the fee claim is minted to the vault by the HOOK before `accrue` is called |
| FEE-10 | FeeVault.spec | `edgeMirrorsAreNonNegative` (invariant; `ethMirrorsAreNonNegative` on the ETH-denominated vault) | no verdict. ETH-denominated vault: **verified (22/22)** |
| FEE-10 | FeeVault.spec | `edgeLedgerDecomposition` (invariant; `ethLedgerDecomposition` on the ETH-denominated vault) | no verdict. The mirrors are `reinforcementEdge`, `edgeBidEarmark` and the `reinforcementBalance[edge]` key. The `accrue` `preserved` block states the caller's convention, `parentToken == edge <=> currency == EDGE`: `_collect` passes no genesis marker. ETH-denominated vault: violated on 2 methods (`accrue`, `forwardProtocolFee`) |
| FEE-08 | FeeVault.spec | `accrueConservesTheFee` | no verdict (stated over the edge mirrors). ETH-denominated vault: **verified**, upper bound only, see note 1 |
| FEE-08 | FeeVault.spec | `accrueMovesLedgerTotalByTheFee` | no verdict (stated over `ledgerTotal[EDGE]`). ETH-denominated vault: **verified** |
| FEE-10 | FeeVault.spec | `onlyAccrualPathsCredit` | no verdict. The enumeration includes `flushForward`: the dead-successor branch calls `_book` and therefore credits the local ledgers out of the queue. ETH-denominated vault: **verified**, against an enumeration without `flushForward` |
| SUP-04 | FeeVault.spec | `onlyAccrualPathsRaiseLedgerTotal` | no verdict. An unsolicited edge-currency transfer into the vault is never sweepable. `ledgerTotal[EDGE]` rises only on the accrual, forward and earmark paths, so a donation cannot make itself claimable, and `solvency`'s inequality is what leaves the surplus unreachable |
| ROL-07 | FeeVault.spec | `creatorTransferIsALedgerMove` | no verdict. ETH-denominated vault: verified |
| FEE-11 | FeeVault.spec | `receiveForwardRefusesAnUndeliveredAmount` | no verdict. `receiveForward(attribution, amount)` is non-payable, so the amount is a CLAIM rather than value that arrived with the call. The contract re-checks `ledgerTotal[EDGE] <= holdings(EDGE)` after crediting and reverts `NotDelivered`; this is that guard |
| RND-11 | FeeVault.spec | `depositEdgeBidEarmarkRefusesAnUndeliveredAmount` | no verdict. The same shape on the forfeit deposit, and it is what makes the RoundManager's try / catch meaningful: a forfeit that did not arrive REVERTS the deposit, which is caught and booked into `pendingForfeits` |
| FEE-10 | FeeVault.spec | `everyEntrypointRefusesNativeValue` | no verdict. There is no `receive()` and no entrypoint is payable, so the vault can never acquire native value it has no code to send out |
| BID-07 | FeeVault.spec | `drawNeverExceedsTheBucket` | no verdict (stated over `drawableEdge`). ETH-denominated vault: verified |
| BID-07 | FeeVault.spec | `bucketNeverExceedsCap` (invariant) | no verdict (stated over `drawableEdge` / `claimableEdge`). ETH-denominated vault: violated on 5, Prover imprecision in the Fenwick `_prefix` walk (the `BWAnd` abstraction) at `loop_iter: 3`, which cannot be raised here. BID-07 holds at U/F |
| PUR-05, BID-07 | FeeVault.spec | `drawNeverExceedsTheGenerationsClaim` | no verdict (stated over `claimableEdge`). ETH-denominated vault: **verified** |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUp` | no verdict. ETH-denominated vault: **verified**; finding F-2, closed in code |
| BID-07 | FeeVault.spec | `twoDrawsCannotDoubleUpAtAnyClock` | no verdict. ETH-denominated vault: **verified** with NO clock precondition (F-2) |
| BID-05 | FeeVault.spec | `payKeeperIsBoundedByDeployerCredit` | no verdict. ETH-denominated vault: verified |
| BID-14 | FeeVault.spec | `deployerCreditSettles` (invariant) | no verdict. ETH-denominated vault: **verified (20/20)** |
| BID-05, FEE-10 | FeeVault.spec | `valueLeavesOnlyOnPayoutMethods` | no verdict. It measures the LINKED edge token's balance of the vault, and `consumeEdgeEarmark` / `deliverForward` are in the declared-payout list |
| BID-05 | FeeVault.spec | `onlyBidDeployerHooks` | no verdict (includes `consumeEdgeEarmark`). ETH-denominated vault: verified |
| CON-05 | FeeVault.spec | `pendingForwardTotalIsTheSum` (invariant) | no verdict. ETH-denominated vault: **verified (20/20)** |
| CON-05 | FeeVault.spec | `flushForwardConserves` | no verdict. Two-sided (finding S-4), keyed to `EDGE`. ETH-denominated vault: **verified** |
| CON-05 | FeeVault.spec | `localBookingRequiresAgedEvidence` | no verdict (keyed to `EDGE`). ETH-denominated vault: **verified** |
| CON-05 | FeeVault.spec | `unresolvedSuccessorIsNeverEvidence` | no verdict. ETH-denominated vault: **verified** |
| CON-05 | FeeVault.spec | `deadEvidenceMovesOnlyOnTheForwardingPaths` | no verdict (`receiveForward` takes two arguments). ETH-denominated vault: **verified** |
| CON-04 | FeeVault.spec | `candidateAttributionsCrossAsUnattributed` | no verdict. ETH-denominated vault: **verified** |
| BID-05, FEE-10 | FeeVault.spec | `noPayoutPathCanBurnTokensAtTheZeroAddress` (`noPayoutPathCanBurnEthAtTheZeroAddress` on the ETH-denominated vault) | no verdict. Stated on `_sendToken`'s `BadRecipient` guard. It carries finding S-5: `require amount > 0` scopes the rule past `payKeeper`'s zero-amount early return |
| CON-04 | FeeVault.spec | `postSunsetFeesAreNeverBookedLocally` | no verdict. ETH-denominated vault: **verified**; `isSunset()` is NONDET, see note 2 |
| FEE-03, ROL-01 | FeeVault.spec | `ratesAndSplitsAreImmutable` | no verdict. `EDGE` is in the immutable list: no call may re-point the vault at another token and make its standing ledgers payable in something else. ETH-denominated vault: verified |
| REN-02 | FeeVault.spec | `claimZeroesBeforePaying` | no verdict. ETH-denominated vault: verified |

## RoundManager.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| RND-09 | RoundManager.spec | `canonicalIsWriteOnce` (invariant) | **verified on the base, the transient step and 15 of 17 methods**; VIOLATED on `adoptGenesis` (C-1) and `finalize` (the rule reads the delegating getters) |
| RND-09 | RoundManager.spec | `onlyFinalizeOrAdoptionWritesHistory` | **verified (17/17 methods)** |
| RND-09, PAR-02 | RoundManager.spec | `historyEntriesAreImmutable` | **verified on 14 of 17 methods**; VIOLATED on `addCandidate`, `adoptGenesis` (C-1) and `finalize`, all with "an existing entry was re-parented" (the delegation item) |
| RND-09 | RoundManager.spec | `historyLengthIsMonotone` | **verified (17/17 methods)** |
| RND-09 | RoundManager.spec | `reverseIndexIsConsistent` (invariant) | **verified on the base, the transient step and 14 of 17 methods**; VIOLATED on `addCandidate`, `adoptGenesis` (C-1) and `finalize` (the delegation item) |
| PAR-01 | RoundManager.spec | `pairingRightsAreWriteOnce` | **verified (17/17 methods)** |
| PAR-01 | RoundManager.spec | `headIndexOnlyGrows` | **verified (17/17 methods)** |
| RND-09, CON-01 | RoundManager.spec | `adoptGenesisIsOnceAndFactoryOnly` | **VIOLATED** - finding **C-1**, a contract finding, fixed in the code (note 13). Latent: the factory constructor refuses a zero or codeless genesis token |
| RND-07 | RoundManager.spec | `finalizeIsIdempotent` | **verified** |
| RND-08 | RoundManager.spec | `noNewRoundBeforeFinalize` | **verified** |
| RND-13 | RoundManager.spec | `thresholdMovesOnlyInFinalize` | **verified (17/17 methods)** |
| RND-11 | RoundManager.spec | `winnersBondIsReturned` | **verified** |
| RND-11 | RoundManager.spec | `losersBondsAreForfeited` | **verified** |
| RND-11 | RoundManager.spec | `addCandidateRefusesAnUnderDeliveredBond` | **verified** |
| RND-12 | RoundManager.spec | `registrationNeverPullsMoreThanTheQuotedBond` | **verified** |
| RND-11 | RoundManager.spec | `finalizeBooksWhatItCouldNotDeliver` | **verified** |
| RND-11 | RoundManager.spec | `pendingForfeitsMoveOnlyOnFinalizeOrFlush` | **verified (17/17 methods)** |
| REN-02 | RoundManager.spec | `flushForfeitsZeroesBeforeDelivering` | **verified** |
| RND-11 | RoundManager.spec | `theBondPushesAreSelfOnly` | **verified** |
| REN-01 | RoundManager.spec | `guardedFactoryEntrypointsCannotBeReentered` | **verified** |
| RND-04, RAN-03 | RoundManager.spec | `requestEndIsOnceAndNotBeforeT` | **verified** |
| RND-05 | RoundManager.spec | `trueEndFallsInsideTheWindow` | **verified** |
| RND-06, RAN-06 | RoundManager.spec | `timeoutFallbackSettlesAtT` | **verified** |
| RND-06, RAN-04 | RoundManager.spec | `endIsSettledAtMostOnce` | **verified** |
| RND-01 | RoundManager.spec | `scheduleIsPureInN` | **verified (17/17 methods)** |
| RND-01 | RoundManager.spec | `scheduleBounds` | **verified** |
| RND-02 | RoundManager.spec | `lateEntryClosesBeforeTheClosingWindow` | **verified** |
| RND-01, SCR-06 | RoundManager.spec | `theCoarseRingCoversTheScoredSpan` | **verified** |
| SCR-14 | RoundManager.spec | `theConstructorsWindowGuardMatchesTheGetters` | **verified** |
| SCR-14 | RoundManager.spec | `theScoredWindowAlwaysExceedsOneCoarseSlot` | **verified** |
| RND-12 | RoundManager.spec | `bondSaturates` | **verified** |
| RND-12 | RoundManager.spec | `bondIsMonotoneInDepth` | **verified** |
| RND-15 | RoundManager.spec | `maxIndexIsRespected` | **verified** |
| RND-03, ROL-01 | RoundManager.spec | `noTransitionIsPrivileged` | **verified on `finalizeDeterministic` and `requestEnd`**; VIOLATED on `claimRefund`, `finalize`, `flushForfeits`, `fulfilEnd`, `pushForfeit`, `pushRefund` (finding **S-12**: the exclusion list is short by the self-only pushes and the per-caller pull claim); **UNKNOWN** on `submitScore`, a timeout |
| RND-03, ROL-02 | RoundManager.spec | `sunsetTouchesNothingElse` | **verified** |
| CON-01 | RoundManager.spec | `adoptionHappensAtMostOnce` | **verified (17/17 methods)** |
| PUR-02 (half) | RoundManager.spec | `canonicalIsWriteOnce` + `historyEntriesAreImmutable` + `onlyFinalizeOrAdoptionWritesHistory` | **the three rules behind this half are verified on 14 to 15 of their 17 methods each and VIOLATED on `adoptGenesis` (C-1), `finalize` and, for two of them, `addCandidate`.** The j = 0 case is exactly the one C-1 breaks |

## Sleeve.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| SLV-01 | Sleeve.spec | `rangeAddThenPointQueryIsTheClosedForm` | needs harness - violated; the counterexample sits exactly ON the bounds (`before = -(2^200 - 1)`, `c1 = -(2^160 - 2)`), which are one power of two looser than the reachable range (tree `< 2^190`, coefficients `< 2^128`) |
| SLV-04 | Sleeve.spec | `pointQueryIsAdditive` | needs harness - violated, same cause as SLV-01 above |
| SLV-06 | Sleeve.spec | `genesisTakesTheWholeSleeveAtMZero` | needs harness - **verified**, with the tree pre-state bounded (`< 2^200`) and the WAD-scaled sleeve bounded (`< 2^160`), which excludes the `unchecked`-accumulator overflow. |
| SLV-05 | Sleeve.spec | `genesisWeightIsTwiceTheTerminalWeight` | needs harness - **violated** (a loose-bound counterexample); bounded to `M <= 64`, a recorded scoping restriction |
| SLV-02 | Sleeve.spec | `everyAncestorShareIsNonNegative` | needs harness - timeout (`loop_iter: 14`) |
| SLV-03 | Sleeve.spec | `sumOfSharesNeverExceedsTheSleeveSmallM` | needs harness - **timeout** (`loop_iter: 14`, non-vacuous; `loop_iter: 12` against the 13-deep Fenwick walk is vacuous). Stated as a delta at WEI granularity. SLV-03 is UNPROVED at this tier |
| SLV-03 | Sleeve.spec | `noShareExceedsTheSleeve` | needs harness - **timeout**, same cause; restated as a delta against the WAD-scaled sleeve |
| SLV-02 | Sleeve.spec | `noIndexOutsideTheRangeIsCredited` | needs harness - **violated**, same loose-bound cause |
| SLV-07 | Sleeve.spec | `indexPastMaxReverts` | needs harness - **verified with no `sleeve > 0` precondition**: the bounds check runs before the zero short-circuit |
| SLV-07 | Sleeve.spec | `reversedRangeReverts` | needs harness, verified|

## FamilyHook.spec

| PROPERTIES ID | spec file | rule / invariant | status |
|---|---|---|---|
| SCR-01, SCR-02 | FamilyHook.spec | `scoreIsMonotoneInNetParentAbsorbed` | **verified** |
| SCR-02 | FamilyHook.spec | `onlyTheSwapPathMovesTheScore` | **verified (3/3 methods)** |
| SUP-06 | FamilyHook.spec | `donationsAreImpossible` | **verified** |
| SUP-05 | FamilyHook.spec | `liquidityIsARatchet` | **verified** |
| SCR-04 | FamilyHook.spec | `averageOverIsTheAccumulatorDifference` | **verified** |
| SCR-14 (SPEC-GAP 7.12) | FamilyHook.spec | `averageOverRevertsOnACollapsedWindow` | **verified** |
| SCR-10 | FamilyHook.spec | `noRingEntryIsWrittenPastTheBell` | **verified (3/3 methods)** |
| SCR-10 | FamilyHook.spec | `endSealIsWriteOnce` | **verified (3/3 methods)** |
| SCR-10 | FamilyHook.spec | `theEndSealIsOnlyLaidPastTheBell` | **verified (3/3 methods)** |
| SCR-13 | FamilyHook.spec | `registerPoolRefusesAPoolWithoutAPublishedEnd` | **verified** |
| SCR-10, SCR-13 | FamilyHook.spec | `everyRegisteredPoolHasAPublishedEnd` | **verified (3/3 methods)** |
| SCR-05 | FamilyHook.spec | `aSlotIsWrittenOnceByItsFirstSwap` | **verified** |
| SCR-06 | FamilyHook.spec | `theFastRingSpansTheRandomEndWindow` | **verified** |
| FEE-04 | FamilyHook.spec | `snipeTaxBounds` | **verified** |
| FEE-04, FEE-06 | FamilyHook.spec | `summedRatesStayBelowOne` | **VIOLATED on its third assertion only** (finding **S-11**: `hopFeePpm` is an unpinned immutable and the Prover may choose 0). The two pairwise FEE-04 bounds are **verified** |
| FEE-04, FEE-06 | FamilyHook.spec | `theEdgeFeeIsSuppressedDuringTheSnipeWindow` | **DISABLED** (finding **S-10**, same cause). NOT EXPRESSIBLE here; falls back to the fuzz and unit tiers |
| FEE-03 | FamilyHook.spec | `feeRatesAreImmutable` | **verified (3/3 methods)** |
| FEE-01 | FamilyHook.spec | `protocolFeeOnlyAtTheEdge` | **DISABLED** (finding **S-10**: the `PoolId` key type of the `Sload` hook cannot be named in CVL at 8.19.2). NOT EXPRESSIBLE here; falls back to `test/properties/Fees.prop.t.sol` and the unit tests |
| FEE-01 | FamilyHook.spec | `beforeSwapIsReachable` (`satisfy`) | **verified** |
| FEE-01 | FamilyHook.spec | `theFeeMintIsReachable` (`satisfy`) | **verified (reachable)**, which is exactly where the FEE-01 ladder stops |
| FEE-01 | FamilyHook.spec | `anyFeeAccrualIsReachable` (`satisfy`) | **VIOLATED (unreachable)** - finding **S-13** |
| FEE-01 | FamilyHook.spec | `someProtocolFeeIsReachable` (`satisfy`) | **VIOLATED (unreachable)** - finding **S-13** |
| FEE-01 | FamilyHook.spec | `oneProtocolFeeAtTheEdgeIsReachable` (`satisfy`) | **VIOLATED (unreachable)** - finding **S-13**. With the vault UNLINKED and no exact summary, three hypotheses for FEE-01 are ruled out; `optimistic_fallback` is the one left |

## Not expressible in these specs

| PROPERTIES ID | reason | belongs to |
|---|---|---|
| FEE-01 (per-route count) | `PoolManager.swap` is summarized NONDET, so the prover never executes legs 2..L of a route; the fee count over a whole `swapPath` cannot be counted inside a single-pool hook proof. | fork (K), FEE-01 already carries tier K |
| ROU-02 | The comparison is "routed swap vs equivalent direct `PoolManager` swap, wei for wei"; both sides require a real PoolManager. Under NONDET both sides are unconstrained and the rule is vacuous. | fork (K) |
| REN-01 (the v4 unlock flag) | "Reachable while the PoolManager unlock flag is set" is a property of the *singleton's* transient lock, which is summarized away. Certora cannot see the flag: the guard is an `exttload` on the summarized PoolManager, so the Prover would have to model that singleton's transient storage. This row is about `notInsideUnlock` only. The OTHER reentrancy guard, the plain `_locked` word on `openRoundIfIdle` / `addCandidate`, IS local to `RoundManager` and is stated as `guardedFactoryEntrypointsCannotBeReentered`. | stateful invariant (I) + fork (K) |
| PUR-02 (the landing step) | That the liquidity actually LANDS under `canonical(j)` is `locker.depositBid(roundManager.poolKeyOf(j), ...)` - an external call from `BidDeployer`, which has no spec or conf of its own, into the Locker and on into the v4 singleton, every entrypoint of which is summarized NONDET. CVL has no event predicate either, so `PurseDeployed` is not a usable witness. A `BidDeployer.spec` summarizing `_.depositBid(...)` into a ghost that records `(key, childToken)` is what would make it expressible. | fork (K): `fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing`, fuzz (F): `properties/Purse.prop.t.sol` |
| PUR-02 ("a loser never receives purse liquidity") | STRUCTURAL, and deliberately not stated as a rule: the destination is a pure function of `j` computed inside the deployer, and there is no rank, no board and no caller-supplied token for a rule to quantify over. | fuzz (F), fork (K), as above |
| SUP-01 (supply constancy) | The family token is an EIP-1167 clone whose implementation is linked at deploy time; the clone has no verifiable bytecode of its own for the Prover to load. | unit / fuzz / stateful invariant (U, F, I) |
| SUP-04 (no protocol contract holds family supply) | SUP-04 has two halves. The vault half (the vault's edge balance is its ledgers plus donations) IS here, as `solvency` plus `onlyAccrualPathsRaiseLedgerTotal`. The other half, that no protocol contract holds family-token supply, quantifies over every contract in the stack and over a clone with no bytecode, so it is not a claim any single-contract proof can make. | stateful invariant (I): `Invariants.prop`, fork (K) |
| RND-11 (the bond reaches the creator) | A loss of coverage at this tier: the bond is an ERC-20 escrow and the edge token cannot be linked in `RoundManager.conf`, because `edgeToken()` is `canonical(0)`, a delegating storage read rather than an immutable. With `transfer` summarized NONDET a recipient's balance does not move, so `winnersBondIsReturned` can only assert what this contract owns (the escrow is released, the pull-fallback credit is never reduced). | unit (U), fork (K) |
| SLV-03 (unbounded `M`) | The sum over `[0, M]` for symbolic `M` is a quantified sum over a symbolic range, which CVL cannot express. Bounded to `M <= 3` here. | Halmos (H) at bounded depth, fuzz (F) at full depth |
| SCR-04 (exact reconstruction) | Requires replaying an arbitrary swap history through both checkpoint rings; the ring walk plus the swap sequence is beyond the loop bound the Prover can discharge. | Halmos (H), stateful invariant (I) |
| BID-01..BID-04, BID-08..BID-13 | TWAP reads, band guards and tick arithmetic all bottom out in `SqrtPriceMath` / `LiquidityAmounts`, which PROPERTIES section 6 summarizes NONDET, the curve math belongs to Halmos, not Certora. | Halmos (H), fork (K) |
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
3. `FeeVault.depositEdgeBidEarmark(uint256)` is summarized NONDET in `RoundManager.spec`; the
   arrival side of a forfeited bond is covered by `onlyAccrualPathsCredit` and
   `depositEdgeBidEarmarkRefusesAnUndeliveredAmount` in `FeeVault.spec`.
4. "`requestEnd` pins a strictly future beacon round" is a property of `IRandomnessSource.pin()`,
   which is summarized NONDET. What is proved here is the once-per-round and not-before-`T` half.
5. The deterministic-fallback branch writes `tradingEnd = nominalEnd` with no beacon word involved.
   With `pin`/`fulfil` summarized, the rule reduces to a documentary assertion plus
   `endIsSettledAtMostOnce`, which is the load-bearing half.
6. `sumOfSharesNeverExceedsTheSleeveSmallM` is written out for `M <= 3` because CVL cannot quantify a
   sum over a symbolic range. The depth-independent half is `noShareExceedsTheSleeve`.
7. Reconstructing `acc` at both window edges from the rings needs the swap history; the rule is
   weakened to the attainment-time bound, which is what `submitScore` reads as `tFirstAttained`.
8. See note 10.
9. `protocolFeeOnlyAtTheEdge` states the per-pool half of FEE-01 ("only if the pool is an edge
   pool"). `_collect` passes `Currency.unwrap(parent)` to the vault unconditionally, so the word the
   vault receives carries no pool class; the predicate has to be read from `p.isEdge` itself, through
   an `Sload` hook, and that hook does not type-check (note 11). The rule is DISABLED and FEE-01's
   per-pool half is NOT EXPRESSIBLE at this tier. It is covered by `test/properties/Fees.prop.t.sol`
   and the unit tests. The per-route count is in the not-expressible table above, for a different
   reason.
10. SCR-05 is stated against the contract's
    own `scoreCheckpoint()` getter either side of a swap, because an `Sstore` hook on the nested ring
    does not type-check (the key resolves to a `PoolId` identity a hook declaration cannot name).
11. A `PoolId` key is an identity a hook declaration cannot name at `certora-cli` 8.19.2, whether the
    mapping is nested or top-level: a plain `mapping(PoolId => uint256)` in the same contract is
    rejected identically, including with `PoolIdLibrary` added to the scene. `FeeVault.spec`'s
    `ledgerTotal[KEY FeeVault.Currency c]` works, because its key type is a file-level value type over
    ADDRESS. **Consequence:** `protocolFeeOnlyAtTheEdge` and
    `theEdgeFeeIsSuppressedDuringTheSnipeWindow` are commented out in the spec with a restore note,
    and FEE-01's per-pool half and FEE-06's time half are covered by `Fees.prop` and the unit tests.
12. The `EDGE` link in `FeeVault.conf` links an immutable of a USER-DEFINED VALUE TYPE (`Currency`
    over `address`) rather than a plain address. The fallback, if the Prover refuses it, is in that
    conf's own header.
13. C-1, a contract finding. The `adoptGenesisIsOnceAndFactoryOnly` counterexample adopts
    `address(0)` against a `_head != address(0)` write-once flag: every write is performed, the event
    is emitted and the flag stays unset, so a second adoption re-seats canonical index 0, the head, the
    index-0 creator and the edge currency. It is LATENT rather than live: the entrypoint is
    `onlyFactory` and `FamilyFactory`'s constructor refuses a zero or codeless genesis token.
    **Fixed in the code**: `RoundManager` carries its own write-once `_genesisAdopted` boolean and
    `adoptGenesis` refuses a zero `token` (`test/Round.t.sol`, `GenesisAdoptionTest`).

## Spec gaps encoded as assumptions

| PROPERTIES 7 item | where | assumption encoded |
|---|---|---|
| 1 - one fee per edge traversal | FamilyHook.spec, FEE-01 block (the per-pool rule is DISABLED, S-10; the ladder is unreachable, S-13) | one fee per traversal, i.e. two for a round trip: `swapPath([0, 1, 0])` ends at index 0 and credits the creator recorded for the adopted genesis token with the creator share of both edge legs |
| 7, `DURATION_SCALE_DIV` vs `closingWindowFor` | RoundManager.spec, `scheduleBounds` | `W` is computed from the **scaled** `D` |
| 8 - "no fee on genesis-less paths" | FamilyHook.spec, FEE-01 block (same caveat as item 1) | the rule is read as "only if the pool is an EDGE pool" (parent is canonical index 0, decided by the factory at registration), not in terms of a currency. There is no native-ETH reading to choose between |
| 12, `averageOver` with `t1 == t0` | FamilyHook.spec, `averageOverRevertsOnACollapsedWindow` | **GAP CLOSED in the code's favour**: the call REVERTS `BadScoreWindow`, because two edges resolving to one instant measure nothing and a zero there is indistinguishable from a real average of zero. The rule asserts the revert and verifies; the precondition that keeps it unreachable is a deploy-time guard, proved in `RoundManager.spec` |
| 14 - `hopFeePpm` at its ceiling | FamilyHook.spec, `summedRatesStayBelowOne` (the partner rule `theEdgeFeeIsSuppressedDuringTheSnipeWindow` is DISABLED, S-10) | **the two pairwise bounds VERIFY and the third assertion is VIOLATED for finding S-11, an unpinned `hopFeePpm` the Prover may choose to be 0.** The rule states `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1e6`, and PROPERTIES 7.14's "100.075%" is arithmetically wrong (990000 + 10000 + 10000 = 101%). The three are never summed because a round-one pool is both edge and freshly opened, and the exclusion is in TIME: `protocolPpm = (p.isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0` |
| - (§J Fenwick residue) | FeeVault.spec, `edgeLedgerDecomposition` | the floored residue stays in the vault and is not subtracted from `ledgerTotal` |
| - (§J donations) | FeeVault.spec, `solvency` + `onlyAccrualPathsRaiseLedgerTotal` | an unsolicited edge-currency transfer into the vault raises `holdings(EDGE)`, credits no ledger and is permitted. Solvency is an inequality in that direction and nothing sweeps the surplus |
