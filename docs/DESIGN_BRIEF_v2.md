# Family Chain — Design Brief v2 (post-design-review reconciliation; basis for simulation and contracts)

> Superseded in places by `docs/attack-log.md` fixes and the post-review contract changes; constants in `docs/DEPLOY_CONSTANTS.md`; decisions in `CONTEXT.md`.

Date: 2026-09-10. Supersedes v1. Changes are listed in `docs/attack-log.md`. Target: Robinhood Chain 4663 (testnet 46630), Uniswap v4 PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`.

## 0. Summary
One canonical trunk GENESIS → #1 → #2 → …. Each link's only launch liquidity is a permanently locked Uniswap v4 pool paired against its predecessor (genesis against native ETH). Succession is a 10-minute synchronized market competition among identical-curve candidates quoted in the current head; the highest average parent absorption above a threshold wins. Traders pay a 1% protocol fee only when ETH enters or leaves the family; internal hops pay a tiny pool fee. Fees split: developer 20%, creator (sim-set), flywheel to all ancestors (U-shaped, OG-heavy) plus immediate-parent reinforcement, delivered as parent-token buy support. No admin, no upgrade, no pause, no founder allocation.

## 1. Contracts
- **FamilyToken** — fixed supply 1e9e18 minted once to the Locker; ERC20 only; holder `burn`; nothing else.
- **FamilyFactory** — sole creator. `createGenesis(meta)` once (numeraire ETH). `openRound()`/`registerCandidate(roundId, meta)` (numeraire = head). Pre-registers the exact PoolKey + initial sqrtPrice with the hook, deploys token, initializes pool, transfers supply to Locker, Locker places the standard curve. Bond (fixed ETH constant) escrowed in RoundManager.
- **Locker** — holds all positions forever. `placeStandardCurve(pool)` (Factory only) and `depositBid(pool, parentAmount, rangeBelowSpot)` (FeeVault keeper path only). No remove function. Positions are minted via PoolManager `modifyLiquidity` with the Locker as the only allowed caller (hook-enforced).
- **FamilyHook** (singleton for every family pool; pool LP fee = 0):
  - `beforeInitialize`: only Factory-registered keys at the registered price.
  - `beforeAddLiquidity`: only Locker. `beforeRemoveLiquidity`: revert always. `beforeDonate`: revert.
  - `beforeSwap`: revert on candidate pools before `tradingStart`; snipe tax multiplier (99% → 1% over the first 3 s of a candidate's trading; per-pool `tradingStart`).
  - `afterSwap`: (a) hop fee `f_hop` on the parent side (retained to FeeVault balance, protocol-owned); (b) if the pool is the genesis/ETH pool: protocol fee 1% on the ETH side (exact from deltas; input or output, whichever is ETH), credited to FeeVault with attribution: if `sender == FamilyRouter`, hookData = terminal token id (trusted only then), else attribution = flywheel/genesis; (c) score accumulator update for candidate pools during `[tradingStart, T_end]`: `acc += R × (t − t_last)`, `R += netParentIn`; (d) cumulative price observation `cumSqrtP += sqrtP × dt` for the keeper TWAP; (e) emits `ScoreUpdated`, `FeeAccrued`.
- **RoundManager** — state machine, registry, `submitScore`, `finalize`, head pointer, history. No owner.
- **FeeVault** — ETH-only protocol fee ledger + per-pool parent-token hop-fee ledger; splits; Fenwick ancestor accounting; pull claims; keeper `deploy(generation)` with 1% bounty.
- **FamilyRouter** — permissionless, immutable convenience executor: `buy(tokenId, minOut)` / `sell(tokenId, minOut)` executing the canonical route in one unlock, passing the terminal token id as hookData for attribution. Not fee-privileged.
- **FamilyLens** — batched views for UI/indexer.

## 2. Round lifecycle (on demand)
Idle(head=#N) → `openRound()` by anyone with the first `registerCandidate` → Registration 3 min (unlimited entries, each pays bond in ETH, pool created gated) → Trading exactly 10 min from `registrationEnd` (all candidates share `tradingStart`; snipe tax first 3 s) → Submission window 5 min: anyone calls `submitScore(candidateId)` (O(1): `avg = (acc + R×(T_end − t_last)) / D`; stores `(avg, tFirstAttained)` and updates best) → `finalize()` after window: if `bestAvg ≥ H_current` → winner = best; head = winner; index N+1; bond refunded to winner's creator; losers' bonds deposited as ETH bid under genesis. Else no winner; `H_current = max(0.9 × H_current, H_min)`. Idle. Idempotent; stale rounds cannot overwrite.
Tie: higher avg; then earlier `tFirstAttained` (block timestamp at which the candidate's running average first reached its final value — computed as the last update time before T_end); then lower poolId.

## 3. Curve, score, threshold
- Standard curve (relative to parent supply P = 1e9): start FDV ratio `a0`, contiguous ranges with shares; concrete values set by Sim 4/8 (candidate family: `[(s1, a0·P, a1·P), (s2, a1·P, a2·P), (s3, a2·P, a3·P), tail]`). Deploy constants; identical for every candidate; genesis uses the same shape with ETH units scaled by a deploy constant.
- Score = ∫ R(t) dt from tradingStart to T_end, R = cumulative net parent absorbed via swaps; average `Score/D` compared with `H`.
- `H = h × P` parent tokens (deploy constant h), decaying ×0.9 per failed round with floor `0.25 h P`; invariant `H ≤ 0.25 × absorption(curve, wallFDV)`.
- Disclosed: score is refundable; slot capture costs ≈ fees (Sim 4 numbers in README).

## 4. Fees
- `f_hop` (deploy constant, 5–10 bps target) on every family swap, parent side, to FeeVault as protocol-owned reinforcement budget for that pool's parent.
- Protocol fee 1% on the ETH side of every genesis-pool swap (entry or exit). Split: developer 20%; creator of attributed terminal token `c%` (Sim 6; if unattributed → flywheel); flywheel remainder = ancestor sleeve `(2 − 5r + 4r²)` weights over ancestors 0..M of the terminal token (M = 0 → genesis only) + immediate-parent reinforcement sleeve (Sim 6 sets split).
- Claims: pull-based per recipient; developer and creators withdraw ETH; ancestor/reinforcement balances are deployed by keeper `deploy(j)`: buys up the chain to token j−1 (ETH for j = 0) within ±3% of each pool's 30-min TWAP, deposits as bid under j via Locker, size ≤ 2% of j's parent reserve per call, 1% bounty on verified deposit.

## 5. Invariants (tests/fuzz)
Token supply fixed; no mint; Locker positions never removed; only Locker adds; only Factory-registered pools initialize; ≤1 winner/index; winner from valid round; finalize deterministic, permissionless, idempotent; no-winner closes; protocol fee charged exactly once per ETH-edge swap and never on family↔family swaps; allocations ≤ collected per currency; no double claim; Fenwick point claims sum ≤ range adds; no loops over ancestry in swap/claim; accumulators clamp at T_end; gen-1 singleton; no privileged functions.

## 6. Known risks (disclose)
Refundable score → cheap slot capture / dynastic capture; win-then-dump; weak old links as routing bottlenecks; embedded parent released on the way down; external ETH pools for mid-chain tokens bypass the edge fee (bounded by hop fee); last-second spikes; unaudited until external audit.
