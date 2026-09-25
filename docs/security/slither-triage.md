# Slither triage

Slither 0.11.6 over `contracts/`, excluding dependencies, tests, scripts and the Certora
harnesses: 76 contracts analysed with 102 detectors, **307 results, every one triaged, 0 open
findings.** Each result is a false positive, informational, or behaviour the protocol has by design.

```bash
FOUNDRY_THREADS=1 slither . --filter-paths "lib/|test/|script/|certora/" --exclude-dependencies
```

## Summary

| Impact | Results | false positive | by design | informational |
|---|---|---|---|---|
| High | 10 | 10 | 0 | 0 |
| Medium | 87 | 85 | 2 | 0 |
| Low | 163 | 20 | 143 | 0 |
| Informational | 47 | 0 | 4 | 43 |
| **Total** | **307** | **115** | **149** | **43** |

## Triage

| Detector | Impact | Count | Disposition | Reason |
|---|---|---|---|---|
| arbitrary-send-erc20 | High | 1 | false positive | `FamilyRouter._settle` pulls from `r.payer`, which only the router's own `_run` encodes, as the `msg.sender` of the route call; `unlockCallback` accepts only the PoolManager. No third-party approval can be pulled. |
| reentrancy-balance | High | 8 | false positive | `EthZap._sell`: `sellForEth` and `sellCandidateForEth` are `nonReentrant`, and `unlockCallback` refuses unless the zap's own lock is held. The balances are snapshotted before the route and measured after it on purpose, so the zap only moves what the route delivered. |
| weak-prng | High | 1 | false positive | `FamilyHook._checkpoint`: `slot % cardinality` is a ring index. The protocol's only randomness is the BLS-verified drand beacon in `DrandSource.fulfil`. |
| divide-before-multiply | Medium | 2 | by design | `CurveMath.floorToSpacing` floors a tick onto the spacing grid, which is the intended truncation. `BidDeployer._edgeBid` takes the bounty from the floored deposit, so deposit plus bounty never exceeds the pots. |
| incorrect-equality | Medium | 17 | false positive | Every comparison is against a zero sentinel or an exact value the contract computes itself: unset timelock timestamps, unset beacon rounds, a zero fee or zero measured output, a ring slot tag. None compares a balance an attacker can move. |
| reentrancy-no-eth | Medium | 7 | false positive | `FamilyHook.afterSwap` calls only the PoolManager and the hook-only `FeeVault.accrue`, and the score update is an additive read-modify-write on storage. `FeeVault.accrue` reaches a successor only through a gas-bounded self-call inside `try`/`catch`. `flushForward` and `RoundManager.finalize` are `nonReentrant`, and `finalize`'s pushes are self-only calls inside `try`. `requestEnd` and `fulfilEnd` call the immutable randomness source, which makes no external call, behind once-per-round flags. |
| uninitialized-local | Medium | 25 | false positive | Solidity zero-initialises locals and zero is the intended starting value: search bounds, accumulators, flags, and structs filled field by field. |
| unused-return | Medium | 36 | false positive | The discarded values are tuple fields the caller does not need (`getSlot0`, `initialize`, `modifyLiquidity`'s fee delta, a pagination total), or returns of calls that either succeed in full or revert (`consumeAncestorClaim`, `depositBid`, `depositExternalBid`, ERC-6909 `transfer`, `settle`). Where an amount matters it is measured from deltas or balances instead. |
| calls-loop | Low | 89 | by design | Every loop runs over a bounded set and calls protocol contracts or the v4 PoolManager: the prior-version registry chain (one hop per deployed version), the links of a route (bounded by the caller's `maxHops`), the parent walk for TWAP pricing (bounded by `MAX_INDEX`), four curve ranges, and view-only lens pages. A revert inside a loop reverts only that call. |
| missing-zero-check | Low | 13 | by design | Constructor arguments set once by the deploy script from addresses it has just deployed or checked; `FamilyFactory.wire` refuses a stack whose vault, router or bid deployer has no code. |
| reentrancy-benign | Low | 8 | false positive | The calls go to immutable protocol contracts or the PoolManager, from paths that are `nonReentrant`, hook-only or self-only inside `try`/`catch`. `V4UnlockGuardProbe.probe` is a deploy-time self-check that holds no value. |
| reentrancy-events | Low | 12 | false positive | Events emitted after calls to immutable protocol contracts, the PoolManager or the immutable randomness source. Event order changes no state. |
| return-bomb | Low | 3 | by design | The static reads of a successor deployment are capped at `STATIC_GAS` (30,000), which bounds the returndata the callee can produce and so the copy cost; any answer other than one clean 32-byte word is treated as no answer. |
| timestamp | Low | 38 | by design | The round schedule, TWAP windows, the snipe tax, the draw bucket and the 7-day timelocks are time-based. A round's end is drawn from the drand beacon, not from the block timestamp. |
| assembly | Informational | 12 | informational | Memory-safe transient-storage reads and writes (the zap's lock, the per-transaction sunset cache, the protocol-fee snapshot), returndata word reads, and the BN254 precompile calls. |
| cyclomatic-complexity | Informational | 3 | informational | `BidDeployer.deployAncestor`, `FamilyRouter.unlockCallback` and `FeeVault.accrue` branch on route shape and fee class. |
| low-level-calls | Informational | 4 | by design | `EthZap._sendEth` reverts on failure; the static reads are gas-capped and validated. |
| naming-convention | Informational | 26 | informational | SCREAMING_CASE immutables and constants, and the `_successor` and `M` parameters. |
| redundant-statements | Informational | 2 | informational | `hopsLeft;` and `spent;` silence unused-variable warnings and have no effect. |

## Every result

Location is the contract and function Slither reports first for the result.

| # | Detector | Impact | Location |
|---|---|---|---|
| 1 | arbitrary-send-erc20 | High | `FamilyRouter._settle` |
| 2 | reentrancy-balance | High | `EthZap._sell` |
| 3 | reentrancy-balance | High | `EthZap._sell` |
| 4 | reentrancy-balance | High | `EthZap._sell` |
| 5 | reentrancy-balance | High | `EthZap._sell` |
| 6 | reentrancy-balance | High | `EthZap._sell` |
| 7 | reentrancy-balance | High | `EthZap._sell` |
| 8 | reentrancy-balance | High | `EthZap._sell` |
| 9 | reentrancy-balance | High | `EthZap._sell` |
| 10 | weak-prng | High | `FamilyHook._checkpoint` |
| 11 | divide-before-multiply | Medium | `BidDeployer._edgeBid` |
| 12 | divide-before-multiply | Medium | `CurveMath.floorToSpacing` |
| 13 | incorrect-equality | Medium | `EthZap._sell` |
| 14 | incorrect-equality | Medium | `EthZap._returnIntermediates` |
| 15 | incorrect-equality | Medium | `FamilyHook._collect` |
| 16 | incorrect-equality | Medium | `FamilyHook._collect` |
| 17 | incorrect-equality | Medium | `FamilyHook._collect` |
| 18 | incorrect-equality | Medium | `FamilyHook._updateScore` |
| 19 | incorrect-equality | Medium | `FamilyHook._checkpoint` |
| 20 | incorrect-equality | Medium | `FeeVault.flushForward` |
| 21 | incorrect-equality | Medium | `FeeVault.executeDeveloperTransfer` |
| 22 | incorrect-equality | Medium | `FeeVault.cancelDeveloperTransfer` |
| 23 | incorrect-equality | Medium | `RoundManager.cancelSunset` |
| 24 | incorrect-equality | Medium | `RoundManager.executeStewardTransfer` |
| 25 | incorrect-equality | Medium | `RoundManager.cancelStewardTransfer` |
| 26 | incorrect-equality | Medium | `DrandSource.status` |
| 27 | incorrect-equality | Medium | `DrandSource.fulfil` |
| 28 | incorrect-equality | Medium | `MockRandomnessSource.fulfil` |
| 29 | incorrect-equality | Medium | `MockRandomnessSource.status` |
| 30 | reentrancy-no-eth | Medium | `FamilyHook.afterSwap` |
| 31 | reentrancy-no-eth | Medium | `FeeVault.accrue` |
| 32 | reentrancy-no-eth | Medium | `FeeVault.flushForward` |
| 33 | reentrancy-no-eth | Medium | `FeeVault.flushForward` |
| 34 | reentrancy-no-eth | Medium | `RoundManager.requestEnd` |
| 35 | reentrancy-no-eth | Medium | `RoundManager.fulfilEnd` |
| 36 | reentrancy-no-eth | Medium | `RoundManager.finalize` |
| 37 | uninitialized-local | Medium | `EthZap._sell` |
| 38 | uninitialized-local | Medium | `FamilyHook._consult` |
| 39 | uninitialized-local | Medium | `FamilyHook._consult` |
| 40 | uninitialized-local | Medium | `FamilyHook.afterSwap` |
| 41 | uninitialized-local | Medium | `FamilyHook._sample` |
| 42 | uninitialized-local | Medium | `FamilyRouter._execute` |
| 43 | uninitialized-local | Medium | `FamilyRouter.unlockCallback` |
| 44 | uninitialized-local | Medium | `FamilyRouter._leg` |
| 45 | uninitialized-local | Medium | `FeeVault.accrue` |
| 46 | uninitialized-local | Medium | `FeeVault.accrue` |
| 47 | uninitialized-local | Medium | `FeeVault.accrue` |
| 48 | uninitialized-local | Medium | `FeeVault.accrue` |
| 49 | uninitialized-local | Medium | `FeeVault.accrue` |
| 50 | uninitialized-local | Medium | `FeeVault.accrue` |
| 51 | uninitialized-local | Medium | `FeeVault.flushForward` |
| 52 | uninitialized-local | Medium | `FeeVault.flushForward` |
| 53 | uninitialized-local | Medium | `Locker._placeCurve` |
| 54 | uninitialized-local | Medium | `Locker._placeCurve` |
| 55 | uninitialized-local | Medium | `Locker._placeCurve` |
| 56 | uninitialized-local | Medium | `Locker.depositBid` |
| 57 | uninitialized-local | Medium | `RoundManager.submitScore` |
| 58 | uninitialized-local | Medium | `RoundManager.submitScore` |
| 59 | uninitialized-local | Medium | `RoundManager.finalize` |
| 60 | uninitialized-local | Medium | `RoundManager.finalize` |
| 61 | uninitialized-local | Medium | `StandardCurve.validate` |
| 62 | unused-return | Medium | `BidDeployer.deployAncestor` |
| 63 | unused-return | Medium | `BidDeployer._placeBid` |
| 64 | unused-return | Medium | `BidDeployer._placeBid` |
| 65 | unused-return | Medium | `BidDeployer.deployHopPot` |
| 66 | unused-return | Medium | `BidDeployer.deployHopPot` |
| 67 | unused-return | Medium | `BidDeployer._placeEdgeBid` |
| 68 | unused-return | Medium | `BidDeployer._placeEdgeBid` |
| 69 | unused-return | Medium | `BidDeployer._drawSleeve` |
| 70 | unused-return | Medium | `BidDeployer.depositExternalBid` |
| 71 | unused-return | Medium | `BidDeployer._requireWithinBand` |
| 72 | unused-return | Medium | `BidDeployer._priceFor` |
| 73 | unused-return | Medium | `BidDeployer._firstRangeParentCapacity` |
| 74 | unused-return | Medium | `BidDeployer._parentReserve` |
| 75 | unused-return | Medium | `BidDeployer._curveRanges` |
| 76 | unused-return | Medium | `BidDeployer._bidTicks` |
| 77 | unused-return | Medium | `EthZap.constructor` |
| 78 | unused-return | Medium | `EthZap._sell` |
| 79 | unused-return | Medium | `EthZap._sell` |
| 80 | unused-return | Medium | `EthZap.unlockCallback` |
| 81 | unused-return | Medium | `EthZap.unlockCallback` |
| 82 | unused-return | Medium | `EthZap.unlockCallback` |
| 83 | unused-return | Medium | `EthZap.unlockCallback` |
| 84 | unused-return | Medium | `FamilyFactory.registerCandidate` |
| 85 | unused-return | Medium | `FamilyHook.beforeSwap` |
| 86 | unused-return | Medium | `FamilyHook._consult` |
| 87 | unused-return | Medium | `FamilyLens.candidateView` |
| 88 | unused-return | Medium | `FamilyLens.chainView` |
| 89 | unused-return | Medium | `FamilyLens.roundView` |
| 90 | unused-return | Medium | `FamilyRouter._settle` |
| 91 | unused-return | Medium | `FeeVault.forwardProtocolFee` |
| 92 | unused-return | Medium | `FeeVault.redeem` |
| 93 | unused-return | Medium | `Locker._placeCurve` |
| 94 | unused-return | Medium | `Locker._placeBid` |
| 95 | unused-return | Medium | `Locker._settle` |
| 96 | unused-return | Medium | `Locker.depositBid` |
| 97 | unused-return | Medium | `Locker.depositBid` |
| 98 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 99 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 100 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 101 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 102 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 103 | calls-loop | Low | `BidDeployer.dollValueOfParent` |
| 104 | calls-loop | Low | `BidDeployer.parentForDollValue` |
| 105 | calls-loop | Low | `BidDeployer.parentForDollValue` |
| 106 | calls-loop | Low | `BidDeployer.parentForDollValue` |
| 107 | calls-loop | Low | `BidDeployer.parentForDollValue` |
| 108 | calls-loop | Low | `BidDeployer._hookFor` |
| 109 | calls-loop | Low | `BidDeployer._hookFor` |
| 110 | calls-loop | Low | `BidDeployer._hookFor` |
| 111 | calls-loop | Low | `BidDeployer._hookFor` |
| 112 | calls-loop | Low | `BidDeployer._hookFor` |
| 113 | calls-loop | Low | `BidDeployer._hookFor` |
| 114 | calls-loop | Low | `BidDeployer._hookFor` |
| 115 | calls-loop | Low | `BidDeployer._hookFor` |
| 116 | calls-loop | Low | `BidDeployer._hookFor` |
| 117 | calls-loop | Low | `BidDeployer._hookFor` |
| 118 | calls-loop | Low | `BidDeployer._twap` |
| 119 | calls-loop | Low | `BidDeployer._twap` |
| 120 | calls-loop | Low | `BidDeployer._twap` |
| 121 | calls-loop | Low | `BidDeployer._twap` |
| 122 | calls-loop | Low | `BidDeployer._twap` |
| 123 | calls-loop | Low | `BidDeployer._twap` |
| 124 | calls-loop | Low | `BidDeployer._twap` |
| 125 | calls-loop | Low | `BidDeployer._twap` |
| 126 | calls-loop | Low | `BidDeployer._twap` |
| 127 | calls-loop | Low | `BidDeployer._twap` |
| 128 | calls-loop | Low | `BidDeployer._priceFor` |
| 129 | calls-loop | Low | `BidDeployer._priceFor` |
| 130 | calls-loop | Low | `BidDeployer._priceFor` |
| 131 | calls-loop | Low | `BidDeployer._priceFor` |
| 132 | calls-loop | Low | `BidDeployer._priceFor` |
| 133 | calls-loop | Low | `EthZap._snapshotIntermediates` |
| 134 | calls-loop | Low | `EthZap._snapshotIntermediates` |
| 135 | calls-loop | Low | `EthZap._snapshotIntermediates` |
| 136 | calls-loop | Low | `EthZap._snapshotIntermediates` |
| 137 | calls-loop | Low | `EthZap._returnIntermediates` |
| 138 | calls-loop | Low | `EthZap._returnIntermediates` |
| 139 | calls-loop | Low | `FamilyLens.candidateView` |
| 140 | calls-loop | Low | `FamilyLens.candidateView` |
| 141 | calls-loop | Low | `FamilyLens.candidateView` |
| 142 | calls-loop | Low | `FamilyLens.chainView` |
| 143 | calls-loop | Low | `FamilyLens.chainView` |
| 144 | calls-loop | Low | `FamilyLens.chainView` |
| 145 | calls-loop | Low | `FamilyLens.chainView` |
| 146 | calls-loop | Low | `FamilyRouter._sweepResiduals` |
| 147 | calls-loop | Low | `FamilyRouter._leg` |
| 148 | calls-loop | Low | `FamilyRouter._leg` |
| 149 | calls-loop | Low | `FamilyRouter._swap` |
| 150 | calls-loop | Low | `FamilyRouter._swap` |
| 151 | calls-loop | Low | `FamilyRouter._currency` |
| 152 | calls-loop | Low | `FeeVault._isPriorVault` |
| 153 | calls-loop | Low | `FeeVault._isPriorVault` |
| 154 | calls-loop | Low | `FeeVault._isPriorVault` |
| 155 | calls-loop | Low | `FeeVault._isPriorVault` |
| 156 | calls-loop | Low | `Locker._placeCurve` |
| 157 | calls-loop | Low | `RoundManager.registryOf` |
| 158 | calls-loop | Low | `RoundManager.registryOf` |
| 159 | calls-loop | Low | `RoundManager.registryOf` |
| 160 | calls-loop | Low | `RoundManager.registryOf` |
| 161 | calls-loop | Low | `RoundManager.registryOf` |
| 162 | calls-loop | Low | `RoundManager.registryOf` |
| 163 | calls-loop | Low | `RoundManager.registryOf` |
| 164 | calls-loop | Low | `RoundManager.registryOf` |
| 165 | calls-loop | Low | `RoundManager.registryOf` |
| 166 | calls-loop | Low | `RoundManager.registryOf` |
| 167 | calls-loop | Low | `RoundManager.registryOf` |
| 168 | calls-loop | Low | `RoundManager.registryOf` |
| 169 | calls-loop | Low | `RoundManager.registryOf` |
| 170 | calls-loop | Low | `RoundManager.registryOf` |
| 171 | calls-loop | Low | `RoundManager.registryOf` |
| 172 | calls-loop | Low | `RoundManager.registryOf` |
| 173 | calls-loop | Low | `RoundManager.registryOf` |
| 174 | calls-loop | Low | `RoundManager.registryOf` |
| 175 | calls-loop | Low | `RoundManager.registryOf` |
| 176 | calls-loop | Low | `RoundManager.registryOf` |
| 177 | calls-loop | Low | `RoundManager.registryOfToken` |
| 178 | calls-loop | Low | `RoundManager.registryOfToken` |
| 179 | calls-loop | Low | `RoundManager.registryOfToken` |
| 180 | calls-loop | Low | `RoundManager.registryOfToken` |
| 181 | calls-loop | Low | `RoundManager.registryOfToken` |
| 182 | calls-loop | Low | `RoundManager.registryOfToken` |
| 183 | calls-loop | Low | `RoundManager.registryOfToken` |
| 184 | calls-loop | Low | `RoundManager.registryOfToken` |
| 185 | calls-loop | Low | `RoundManager.registryOfToken` |
| 186 | calls-loop | Low | `RoundManager.registryOfToken` |
| 187 | missing-zero-check | Low | `FamilyFactory.constructor` |
| 188 | missing-zero-check | Low | `FamilyFactory.constructor` |
| 189 | missing-zero-check | Low | `FamilyFactory.constructor` |
| 190 | missing-zero-check | Low | `FamilyFactory.constructor` |
| 191 | missing-zero-check | Low | `FamilyHook.constructor` |
| 192 | missing-zero-check | Low | `FamilyHook.constructor` |
| 193 | missing-zero-check | Low | `FamilyHook.constructor` |
| 194 | missing-zero-check | Low | `FamilyHook.constructor` |
| 195 | missing-zero-check | Low | `FamilyToken.constructor` |
| 196 | missing-zero-check | Low | `Locker.constructor` |
| 197 | missing-zero-check | Low | `Locker.constructor` |
| 198 | missing-zero-check | Low | `RoundManager.constructor` |
| 199 | missing-zero-check | Low | `RoundManager.constructor` |
| 200 | reentrancy-benign | Low | `FamilyHook.afterSwap` |
| 201 | reentrancy-benign | Low | `FamilyHook._collect` |
| 202 | reentrancy-benign | Low | `FeeVault.accrue` |
| 203 | reentrancy-benign | Low | `FeeVault.flushForward` |
| 204 | reentrancy-benign | Low | `FeeVault.flushForward` |
| 205 | reentrancy-benign | Low | `FeeVault.forwardProtocolFee` |
| 206 | reentrancy-benign | Low | `RoundManager.finalize` |
| 207 | reentrancy-benign | Low | `V4UnlockGuardProbe.probe` |
| 208 | reentrancy-events | Low | `FamilyFactory._adoptGenesis` |
| 209 | reentrancy-events | Low | `FamilyFactory.registerCandidate` |
| 210 | reentrancy-events | Low | `FamilyHook.afterSwap` |
| 211 | reentrancy-events | Low | `FamilyHook._collect` |
| 212 | reentrancy-events | Low | `FeeVault.consumeReinforcement` |
| 213 | reentrancy-events | Low | `FeeVault.consumeEdgeEarmark` |
| 214 | reentrancy-events | Low | `FeeVault.forwardProtocolFee` |
| 215 | reentrancy-events | Low | `FeeVault.redeem` |
| 216 | reentrancy-events | Low | `Locker.placeStandardCurve` |
| 217 | reentrancy-events | Low | `Locker.depositBid` |
| 218 | reentrancy-events | Low | `RoundManager.requestEnd` |
| 219 | reentrancy-events | Low | `RoundManager.fulfilEnd` |
| 220 | return-bomb | Low | `FamilyHook._staticAddress` |
| 221 | return-bomb | Low | `FamilyHook._staticBool` |
| 222 | return-bomb | Low | `FeeVault._staticAddress` |
| 223 | timestamp | Low | `FamilyHook.beforeSwap` |
| 224 | timestamp | Low | `FamilyHook._collect` |
| 225 | timestamp | Low | `FamilyHook._snipeTaxPpm` |
| 226 | timestamp | Low | `FamilyHook._updateScore` |
| 227 | timestamp | Low | `FamilyHook._checkpoint` |
| 228 | timestamp | Low | `FamilyHook.averageOver` |
| 229 | timestamp | Low | `FamilyHook._accumulatorAt` |
| 230 | timestamp | Low | `FamilyHook._sample` |
| 231 | timestamp | Low | `FamilyHook._bracket` |
| 232 | timestamp | Low | `FamilyHook.trailingAverage` |
| 233 | timestamp | Low | `FamilyHook._writeObs` |
| 234 | timestamp | Low | `FamilyHook._consult` |
| 235 | timestamp | Low | `FeeVault._bucket` |
| 236 | timestamp | Low | `FeeVault.flushForward` |
| 237 | timestamp | Low | `FeeVault.forwardProtocolFee` |
| 238 | timestamp | Low | `FeeVault.announceDeveloperTransfer` |
| 239 | timestamp | Low | `FeeVault.executeDeveloperTransfer` |
| 240 | timestamp | Low | `FeeVault.cancelDeveloperTransfer` |
| 241 | timestamp | Low | `RoundManager.addCandidate` |
| 242 | timestamp | Low | `RoundManager.requestEnd` |
| 243 | timestamp | Low | `RoundManager.finalizeDeterministic` |
| 244 | timestamp | Low | `RoundManager.submitScore` |
| 245 | timestamp | Low | `RoundManager.finalize` |
| 246 | timestamp | Low | `RoundManager.phase` |
| 247 | timestamp | Low | `RoundManager.currentBond` |
| 248 | timestamp | Low | `RoundManager.announceSunset` |
| 249 | timestamp | Low | `RoundManager.cancelSunset` |
| 250 | timestamp | Low | `RoundManager.announceStewardTransfer` |
| 251 | timestamp | Low | `RoundManager.executeStewardTransfer` |
| 252 | timestamp | Low | `RoundManager.cancelStewardTransfer` |
| 253 | timestamp | Low | `RoundManager.isSunset` |
| 254 | timestamp | Low | `RoundManager.isIdle` |
| 255 | timestamp | Low | `RoundManager.openRoundIfIdle` |
| 256 | timestamp | Low | `DrandSource.status` |
| 257 | timestamp | Low | `DrandSource.roundAt` |
| 258 | timestamp | Low | `DrandSource.fulfil` |
| 259 | timestamp | Low | `MockRandomnessSource.fulfil` |
| 260 | timestamp | Low | `MockRandomnessSource.status` |
| 261 | assembly | Informational | `EthZap._entered` |
| 262 | assembly | Informational | `FamilyHook._sunsetEffective` |
| 263 | assembly | Informational | `FamilyHook._staticAddress` |
| 264 | assembly | Informational | `FamilyHook._staticBool` |
| 265 | assembly | Informational | `FamilyHook._setPreProtocolFees` |
| 266 | assembly | Informational | `FamilyHook._clearPreProtocolFees` |
| 267 | assembly | Informational | `FamilyHook._protocolFeeTaken` |
| 268 | assembly | Informational | `FeeVault._staticAddress` |
| 269 | assembly | Informational | `BN254.reduce48` |
| 270 | assembly | Informational | `BN254.expmod` |
| 271 | assembly | Informational | `BN254.add` |
| 272 | assembly | Informational | `BN254.verifySingle` |
| 273 | cyclomatic-complexity | Informational | `BidDeployer.deployAncestor` |
| 274 | cyclomatic-complexity | Informational | `FamilyRouter.unlockCallback` |
| 275 | cyclomatic-complexity | Informational | `FeeVault.accrue` |
| 276 | low-level-calls | Informational | `EthZap._sendEth` |
| 277 | low-level-calls | Informational | `FamilyHook._staticAddress` |
| 278 | low-level-calls | Informational | `FamilyHook._staticBool` |
| 279 | low-level-calls | Informational | `FeeVault._staticAddress` |
| 280 | naming-convention | Informational | `BidDeployer.MIN_BOUNTY_DOLL` |
| 281 | naming-convention | Informational | `BidDeployer.EDGE` |
| 282 | naming-convention | Informational | `FamilyFactory.GENESIS_TOKEN` |
| 283 | naming-convention | Informational | `FamilyFactory.DEPLOYER` |
| 284 | naming-convention | Informational | `FeeVault.EDGE` |
| 285 | naming-convention | Informational | `FeeVault.CREATOR_BPS` |
| 286 | naming-convention | Informational | `FeeVault.REINFORCE_BPS` |
| 287 | naming-convention | Informational | `FeeVault.ANCESTOR_BPS` |
| 288 | naming-convention | Informational | `RoundManager.BOND_BASE` |
| 289 | naming-convention | Informational | `RoundManager.BOND_MAX` |
| 290 | naming-convention | Informational | `RoundManager.BOND_DOUBLING_EVERY` |
| 291 | naming-convention | Informational | `RoundManager.MAX_INDEX` |
| 292 | naming-convention | Informational | `RoundManager.H_FRAC_WAD` |
| 293 | naming-convention | Informational | `RoundManager.H_MIN_FRAC_WAD` |
| 294 | naming-convention | Informational | `RoundManager.END_TIMEOUT` |
| 295 | naming-convention | Informational | `RoundManager.DURATION_SCALE_DIV` |
| 296 | naming-convention | Informational | `RoundManager.announceSunset(address)._successor` |
| 297 | naming-convention | Informational | `FenwickRangeAdd.addSleeve(FenwickRangeAdd.Tree,uint256,uint256).M` |
| 298 | naming-convention | Informational | `DrandSource.GENESIS_TIME` |
| 299 | naming-convention | Informational | `DrandSource.PERIOD` |
| 300 | naming-convention | Informational | `DrandSource.SAFETY_S` |
| 301 | naming-convention | Informational | `DrandSource.PK_X1` |
| 302 | naming-convention | Informational | `DrandSource.PK_X0` |
| 303 | naming-convention | Informational | `DrandSource.PK_Y0` |
| 304 | naming-convention | Informational | `DrandSource.PK_Y1` |
| 305 | naming-convention | Informational | `MockRandomnessSource.DELAY_S` |
| 306 | redundant-statements | Informational | `spent` in `FamilyRouter.sol` |
| 307 | redundant-statements | Informational | `hopsLeft` in `FeeVault.sol` |
