# Slither triage, V2 changes (2026-09-29)

Per-contract runs with solc 0.8.26 via-ir on VenueOracle, FamilyToken, FamilyFactory and BidDeployer, compared with the accepted baseline. Verdict: 43 new results inside the changed files, 0 true positives.

# Slither triage: new V2 findings vs baseline

Baseline: internal/docs/security/slither.json, 275 detector results (backing
docs/security/slither-triage.md). Compared against per-contract runs for VenueOracle (9),
FamilyToken (1), FamilyFactory (158), BidDeployer (255), keyed on
(check, first-element file, description with line numbers/addresses stripped).

## Summary

| Run | Total | Already known | New in target files | New outside target files |
|---|---|---|---|---|
| VenueOracle | 9 | 0 | 9 | 0 |
| FamilyToken | 1 | 1 | 0 | 0 |
| FamilyFactory | 158 | 68 | 28 | 62 |
| BidDeployer | 255 | 98 | 73 | 84 |

De-duplicated across runs, target-file findings (FamilyFactory.sol, VenueOracle.sol,
FamilyToken.sol, BidDeployer.sol, IVenueOracle.sol, IFamilyFactory.sol) = 43 unique
findings (calls-loop and naming-convention repeat because the FamilyFactory and
BidDeployer runs each pull the other file into its own import tree).

## Triage - target files (43 unique)

### Medium (8)

| Detector | File:line | Verdict |
|---|---|---|
| uninitialized-local | VenueOracle.sol:202 | False positive. lo in _consult is the binary-search lower bound; zero is the intended start (search begins at index 0). Matches baseline uninitialized-local disposition. |
| unused-return | VenueOracle.sol:108, :88 | False positive. getSlot0 tuple fields beyond spot are unused by design (same shape as baseline). |
| uninitialized-local | FamilyFactory.sol:696 (_walkToParent.from) | False positive. from defaults to 0, meaning "walk starts from index 0" when p <= START_WALK_MAX; only reassigned when the walk is capped. Intended zero value. |
| unused-return | FamilyFactory.sol:505 (registerCandidate -> poolManager.initialize) | False positive. initialize reverts on failure or returns the pool's starting tick, which nothing here needs, per the baseline's unused-return pattern. |
| divide-before-multiply | BidDeployer.sol:543 (_edgeBid) | By design. Same shape as the baseline's already-triaged instance: deposited = (potTotal*BPS)/(BPS+BOUNTY_BPS) floors first, bounty = (deposited*BOUNTY_BPS)/BPS is taken from the floored deposit, so deposited+bounty never exceeds potTotal. |
| uninitialized-local | BidDeployer.sol:868 (_curveRanges.basis) | False positive. Zero is the deliberate "unset" sentinel: try/catch fills it from the factory, then if (basis == 0) falls back to live parent supply. |
| unused-return | BidDeployer.sol:608, :591, :387, :858 | False positive. consumeAncestorClaim / depositBid revert-or-succeed (baseline pattern); StandardCurve.build's second tuple field (initSqrtPriceX96) is unused because _curveRanges only needs ranges. |

### Low (13 code paths; several detector hits repeat per call site)

| Detector | File:line | Verdict |
|---|---|---|
| timestamp | VenueOracle.sol:108, :179, :165 | By design. Spacing/staleness comparisons against block.timestamp, same shape as the baseline's timestamp findings (poke spacing, TWAP staleness, round schedule). |
| missing-zero-check | FamilyFactory.sol:303 (_feeVault), :304 (_bidDeployer), :314 (_priorRegistry) | By design. Deploy-time constructor args; wire() (lines 416-417) refuses to operate if feeVault/bidDeployer have no code, and priorRegistry == address(0) is the valid "genesis stack" sentinel checked at line 421 - matches the baseline missing-zero-check disposition exactly. |
| calls-loop | FamilyFactory.sol:729 (_startLinkPrice inside _walkToParent) | By design. Bounded by START_WALK_MAX, same pattern as the baseline's bounded parent-walk calls-loop findings. |
| calls-loop | BidDeployer.sol:663 (_hookFor), :731 (_twap), :267 (dollValueOfParent), :292 (parentForDollValue), :756 (_priceFor) | By design. All are the chain-depth-bounded generation walk (j/k loops capped by MAX_INDEX / FenwickRangeAdd), matching the baseline's calls-loop "parent walk" disposition. |
| reentrancy-benign | FamilyFactory.sol:505 (registerCandidate) | False positive. Every external call in the function (roundManager, poolManager, locker, hook) is an immutable protocol contract; no reentrancy guard needed, per baseline disposition. |
| reentrancy-events | FamilyFactory.sol:505, :427 (_adoptGenesis) | False positive. Events (CurveBasis, GenesisAdopted) are emitted after calls to immutable protocol contracts only; event ordering carries no state, per baseline disposition. |

### Informational (22)

| Detector | Count / location | Verdict |
|---|---|---|
| naming-convention | 15 (VenueOracle POKER_A/POKER_B; FamilyFactory 11 immutables incl. EXPECTED_VENUE_ID, START_*, DEPLOYER, GENESIS_TOKEN, ORACLE_GAS; BidDeployer EDGE, MIN_BOUNTY_DOLL) | Informational. SCREAMING_CASE immutables/constants, same class already accepted in baseline. |
| assembly | 1 (FamilyFactory.sol:664, _oracleCall) | By design/informational. Memory-safe staticcall with a caller-checked gas floor and a minLen guard on the returndata - same shape as the baseline's gas-capped static-read assembly findings. |
| cyclomatic-complexity | 1 (BidDeployer.sol:387, deployAncestor) | Informational. deployAncestor is explicitly one of the three functions the baseline's cyclomatic-complexity triage names as expected to branch on route/fee shape. |

## New findings outside target files (unchanged-import contracts)

These come from FamilyHook.sol, RoundManager.sol, FeeVault.sol and Locker.sol - files
outside the audited V2 diff, pulled in by the FamilyFactory/BidDeployer runs' import trees.
Per the task, these should already be covered by the baseline; none were deep-triaged.

| File | Detectors (count of new results) |
|---|---|
| FamilyHook.sol | weak-prng(1), incorrect-equality(2), reentrancy-no-eth(1), uninitialized-local(1), reentrancy-benign(1), reentrancy-events(1), return-bomb(2), timestamp(7), assembly(2), low-level-calls(2) |
| RoundManager.sol | reentrancy-no-eth(3), uninitialized-local(2), calls-loop(30), reentrancy-benign(1), timestamp(2), naming-convention(2) |
| FeeVault.sol | reentrancy-no-eth(3), uninitialized-local(2), calls-loop(4), reentrancy-benign(4), reentrancy-events(2), return-bomb(1), timestamp(3), assembly(1), low-level-calls(1), naming-convention(1) |
| Locker.sol | unused-return(1), calls-loop(1) |

None of these were read in depth; they map onto detector classes the baseline already
disposes of for these same contracts (weak-prng on FamilyHook._checkpoint, calls-loop on
RoundManager's registry/route walks, reentrancy-* on immutable-only calls, timestamp on the
round schedule), so they read as baseline-covered behaviour whose exact wording did not
survive the digit-stripping match, not new V2 risk. Recommend re-running the comparison
with looser normalisation (drop the whole "#N-N" / "(line N)" segment instead of
digit-substituting in place) before treating any of these as open findings.

## Fast-only start pricing (2026-10-06)

Change: `VenueOracle` gains `tClamped` (set by the constructor seed and every clamped poke), a
constructor unlock guard (`InsideUnlock`) and the fast-only branch in `startPrice`;
`FamilyFactory._quoteStart` prices status 8 with a price (`ORACLE_SLOW_SHORT`). Per-contract runs
(solc 0.8.26 via-ir through the project build, `--exclude-dependencies`, lib/test/script filtered),
keyed as above against the previous runs of the same contracts (VenueOracle 2026-09-29,
FamilyFactory 2026-10-01).

| Run | Total | Previous | New text | Gone text |
|---|---|---|---|---|
| VenueOracle | 9 | 9 | 1 | 1 |
| FamilyFactory | 171 | 172 | 5 | 6 |

| Detector | File:line | Verdict |
|---|---|---|
| timestamp | VenueOracle.sol:176-186 (`startPrice`) | By design. The same finding as before with one more comparison listed: `fastOnly = status == SLOW_SHORT && tClamped < nT - cf` compares stored sample timestamps (the newest clamped sample against the fast window's reference entry), not a deadline; `nT - cf` cannot underflow (`cf = nT - ref.t`). Replaces the previous text of the same finding. |
| timestamp | RoundManager.sol (`finalize`, `phase`) | Not from this change. Text churn from the round-schedule commits (early finalize on `submittedCount`); the previous entries disappear with it. |
| assembly | FamilyToken.sol (`canonicalAllowance`, `_update`, `creditCanonical`) | Not from this change. Text churn from the per-direction venue-lock allowances; the previous `_consume`/`canonicalNet` entries disappear with it. |

No new result inside FamilyFactory.sol. The constructor's new `isInsideUnlock` external read and
the `tClamped` write raise nothing. Verdict: 0 new true positives.
