# Final independent contract review — 2026-09-11

Reviewed at the tagged revision: 130/130 tests pass, all runtime sizes under EIP-170 (largest `BidDeployer` 17,663 B). Read-only; two scratch probes were run outside the tree (`Oracle.t.sol`, `Probe2.t.sol`). Dispositions of every finding: `docs/attack-log.md` (section "Final independent contract review").

## 1. Verdict

**NOT READY** for a capped mainnet beta; **READY for paid third-party audit only after the three blockers below are fixed and re-tested.** Blockers: F1 (two trunks on the designed upgrade path), F2 (successor can brick every v1 swap via the 63/64 gas rule — the docs assert the opposite), F3 (keeper conversion rate underflows to zero and strands ancestor ETH at depth ~10; ~30% of edge-fee revenue is dead money by generation 20). After fixes, an acceptable beta cap: steward = multisig, developer = cold address (script needs a `DEVELOPER` env var); bond ≥ 0.01 ETH; ≤ 20 rounds; generation depth ≤ 4 (enforce with a deploy-time `maxIndex` constructor param, not policy); genesis-pool ETH ≤ 20 ETH by promotion policy (no on-chain TVL cap exists); no `announceSunset` during the beta.

## 2. Ranked findings

**F1 — HIGH (blocker). Continuation forks the trunk by construction.** `RoundManager` adopts the prior head once, in the constructor, and `openRoundIfIdle` never re-checks the prior. The designed procedure is: deploy v2 (successor must have code), `announceSunset(v2)`, wait 7 days; v1 keeps crowning during the delay plus its in-flight round. Every v1 win after v2's deploy diverges the chains. Probe `test_twoHeadsDuringSunsetDelay` passed with two different `canonical(1)`. Consequences: v1's post-deploy links are orphaned from v2's router; forwarded edge fees attributed to a v1 index ≥ N+1 are credited by v2 to the wrong creator permanently, not the "one round" disclosed. Nothing prevents v2 rounds before sunset either. Fix: lazy head adoption — in `openRoundIfIdle` when `roundCount == 0 && priorRegistry != 0`, require the prior's sunset effective, `prior.successor() == this`, and prior idle (add `isIdle()`), then read `head/headIndex/priorIndex` at that moment; delegate all reads until adopted. Add a test where v1 crowns after v2 exists.

**F2 — HIGH (blocker). A steward-named successor can permanently brick swaps; the docs claim the opposite.** `FeeVault.accrue` wraps the hop in `try this.forwardProtocolFee(...)` with no gas cap; `forwardProtocolFee` calls `accrueForwarded` unbounded. Under EIP-150 a gas-burning successor leaves 1/64 for `_book` (Fenwick, up to 78 SSTOREs) → the genesis-pool swap reverts for any gas limit. Worse, `FamilyHook._successorRouter` staticcalls `successor.factory()`/`factory.router()` with unbounded gas on every swap of every v1 pool until it caches a non-zero router; a successor whose `factory()` burns gas makes all v1 pools untradeable forever (immutable, no cancel). Fix: `this.forwardProtocolFee{gas: FORWARD_GAS}` (~400k) and `staticcall{gas: 30_000}` in the address/bool helpers; cache the negative result after sunset; consider a steward `cancelSunset()` before effect.

**F3 — HIGH (blocker). `ethPerTokenWad` underflows; deep-generation ETH is stranded.** The chain rate is normalised to 1e18 per link; measured rate(0)=4.76e10, rate(1)=3.05e9, rate(2)=2.32e8 (×0.064–0.076 per link) → zero (`BadConversionRate`) at j≈10–11. Before the revert, precision collapses and `maxParentForDeploy` exceeds supply, so each call is bounded by `bidCap` (2% of the active tick bucket), paying ~1e6 wei per call: `claimableEth(j)` can never be spent. At M=20, 52% of the sleeve goes to gens ≥6 plus all of `reinforcementEth[M]` → ≈30% of every edge fee at depth 20 is permanently locked, paid to no one. Fix (arithmetic): walk the amount through the chain (`ethValue = mulDiv(ethValue, ppt_k, WAD)` starting from `parentAmount`; invert step-wise for `maxParentForDeploy`). Fix (economic, a design decision): a loud, counted fallback for unconvertible sleeve ETH, or re-size the cap against the whole first curve range. Add a chain-of-12 test asserting a non-dust payout.

**F4 — HIGH (economic). 30-minute TWAP drag drains any generation's ETH sleeve.** Same-block sandwiches fail (pre-swap observation), but the band only requires spot within ±3% sqrt of a 1800 s TWAP. Attacker buys `parentAmount` of link j−1 at true price, pumps a thin ancestor pool k by factor F (round trip 2×7.5 bps), waits 30 min, calls `deployAncestor(j, …)` repeatedly in one block until `claimableEth(j)` is exhausted, sells back. Profit ≈ `claimableEth(j)·(1−1/F)` − 0.15% of pump capital, for every j above k. Fix: price at `min(TWAP_30m, TWAP_7d)`; rate-limit `consumeAncestorClaim` per generation (≤10%/day); disclose.

**F5 — MEDIUM. Keeper path liveness decays with depth.** `deployAncestor(j)` requires j+1 pools simultaneously in band with ≥1800 s coverage; P(all in band) shrinks with j. Keep the band on pool j only, or widen it for ancestors.

**F6 — MEDIUM (economic). Threshold is meaningless past generation ~2.** H is 0.15% of the parent's supply; parent tokens are worth ~5–8% of their parent in ETH. Clearing H for 900 s costs (refundable) ≈ $100 at gen 1, ≈ $7 at gen 2, < $1 from gen 3. From gen 3 the bond is the only cost of extending the chain. Disclose; consider H in ETH-equivalent via the chain rate, or a bond that scales.

**F7 — MEDIUM. Keeper economics negative at beta scale.** Live `deployAncestor(1)`: keeper net −1.2e12 wei after gas; `deployGenesisBid` bounty 5.9e10 wei vs ~2.8e12 gas. Bounty = 1% × 2% × active bucket; nobody will call. Raise `MAX_RESERVE_BPS` or size against the first range.

**F8 — MEDIUM. `developer` is hardcoded to the deployer key** in the deploy script, immutable forever. Add `DEVELOPER` env; assert a deliberate address.

**F9 — LOW. Exact-output sell fee basis** is `rate/(1+rate)` of gross vs `rate` of gross on exact-in sells; irrelevant at 750 ppm, halves the snipe tax on sells at t=0 (nobody holds candidate tokens then). Gross up symmetrically.

**F10 — LOW. Sybil/spam.** Candidate ≈ $4 all-in at 0.01 gwei; `candidateIds` returns whole arrays. Raise the mainnet bond; paginate.

**F11 — INFO.** `IFamilyHook.sol` comment says 60 s (code 120); timestamps must be monotone (Nitro: yes); `deployments/46630.json` `deployBlock` is a forge-VM artifact; with `via_ir`, `block.timestamp` is CSE'd across `vm.warp` inside one function.

Verified clean: hook delta neutrality and score = pool delta in all four orientations incl. exact-out gross-up; v4 applies the beforeSwap delta before the pool swap; mint-inside-hook accounting nets to zero; Locker has no exit; finalize CEI + pull refund; bond conservation; submission window; `_isPriorVault` gating; router value checks and residual sweep; Fenwick over-allocation < 1 wei per fee; reentrancy paths guarded.

## 3. Five items
- Strongest economic attack: F4.
- Strongest smart-contract attack: F2.
- Strongest score/winner manipulation: the accepted, disclosed refundable capital rental (0.15%); at depth ≥3 it degenerates to F6 (bond alone buys the slot).
- Weakest assumption: that each link is worth roughly as much as its parent; measured winners land at 6–8% of parent value, and keeper precision, threshold meaning, route impact and "value flows to genesis" all rest on it.
- Most likely catastrophic edge case: F1 at generation N+1 on the first upgrade.

## 4. Spec-vs-code discrepancies
1. "A swap can never fail because of what a later version does" / steward "cannot stop trading" — false (F2).
2. "One canonical trunk"; misattribution "one round long" — false (F1).
3. "Nothing is burned… every fee becomes claimable or locked" — false at depth (F3); gas/usability claims at j=32/128/4096 describe an unreachable regime.
4. TWAP drag understated (F4).
5. "The trader pays the ppm of the parent amount specified or received" — exact-out sells pay `rate/(1+rate)` (F9).
6. "Developer must be set deliberately" — the script cannot (F8).
7. Test count 127 → 130; observation spacing comment 60 s vs 120 s.

## 5. Disclosure check (non-technical user) — missing
(a) from the third generation on, becoming head costs about the bond; (b) each new coin is typically worth 5–8% of the one before it in ETH; (c) roughly a third of fees attributed to deep coins is never paid to anyone (F3, until fixed); (d) ancestor payouts depend on volunteer keepers who currently lose money calling, and the 30-minute average price they are paid at can be gamed; (e) the upgrade switch is irreversible, moves all future edge fees to the new version, and a faulty new version can freeze trading on every old pool; the steward key is a single point of failure; (f) the upgrade as coded creates two competing chains; (g) the developer address can never be changed; (h) Uniswap's fee controller may add up to 0.1% to every pool; (i) score is second-granular.

## 6. Lists
**Claims verified:** score = pool delta (four orientations, snipe window, exact-out gross-up); fee once per ETH edge both directions; 750 ppm; attribution router-only; split exact, 50/50 season cut, loser keeps half; Fenwick exact vs brute force; vault solvency invariant; freeze at T_end, tail extension, submission window, idempotent finalize, pull refund; liquidity unremovable, Locker-only add, donate refused, registered-key-only init; genesis curve in-contract; band+coverage guard; sunset once/7d/steward-only; continuation delegated reads to 8 hops; sizes under EIP-170; 130 tests; live: deploy, genesis, round, finalize, claimDev, both keeper paths. **Assumed:** all USD/volume figures; slot value $17,250; Orbit timestamps monotone and second-granular; pinned v4 commits match live PoolManager bytecode (size-only check); a steward names a benign successor; Sim 3/9 reinforcement conclusions (assume conversion feasible, which F3 falsifies at depth).

**Liveness (chain 46630, 2026-09-11):** Hook↔PoolManager, Hook↔RoundManager score/submit/finalize, Factory↔Locker↔PoolManager, Router attribution incl. candidate sentinel, claimDev, FeeVault↔BidDeployer both paths, TWAP band first-attempt pass. **Never fired:** `announceSunset` and the whole handover (`accrueForwarded`, `forwardProtocolFee`, `_successorRouter`), `depositExternalBid` cross-version, delegated registry reads, `claimRefund` fallback, `claimCreator`, failed-round `finalize` (decay path), `genesisBidEarmark` drawdown, `deployAncestor(j≥2)`, third-party contention, indexers.

**Irreversible actions and guards:** `createGenesis` (once, in-contract curve — verified); curve placement/dust burn (Locker-only — verified); crowning (threshold, window, idempotent — verified; unguarded against a concurrent trunk, F1); bond forfeiture (verified); keeper bids and `depositExternalBid` (band, coverage, cap, ledger-bounded credit — verified; rate manipulable F4; rate underflows F3); ETH claims (verified); `transferCreatorRecipient` (verified); `announceSunset` + forwarding (steward-only, once, code check, prior-chain gating — verified; no cancel, unbounded successor gas F2); deployment (address predictions asserted — verified; developer hardcoded F8).

**Unknowns and how to close:** (1) sunset/handover live — deploy a testnet v2 after F1/F2, wait 7 real days, observe forwarding and a v2 round; (2) cost of a TWAP drag on a thin testnet link — run the F4 scenario; (3) keeper break-even TVL on mainnet gas; (4) depth economics — chain of 12 on testnet, `ethPerTokenWad(j)`, H in ETH, `deployAncestor` at j=8; (5) contention — second EOA racing swaps and keeper calls; (6) mainnet PoolManager bytecode hash vs pinned build; (7) Uniswap protocol-fee controller status on 4663; (8) indexer listing.
