# Mechanism addendum v3 (design decisions 2026-09-12) — intentional choices, to be implemented before the paid audit and acknowledged in the public docs

Supersedes the corresponding parts of `docs/DESIGN_BRIEF_v2.md` and `docs/DEPLOY_CONSTANTS.md`. Everything not mentioned here is unchanged.

## 1. The purse goes to the trunk (maintainer decision 2026-09-13)

Design decision: the purse is **no longer contestable**. Each generation's share of later fees is deployed, in full, as locked bid liquidity under the **trunk coin that won that round**. There is no top-2 split, no ranking and no board.

- **Pairing rights** (which coin the next round is priced in) belong to the round winner and **lock at finalization**. No steal window. The trunk remains a straight line of round winners; nothing ever moves "back up".
- **The season cut** (the head creator's 50% of the creator share on candidate trades during the round it hosts) stays with the trunk coin, uncontested.
- **The purse** = a generation's share of the ancestor sleeve (the fee flow from every later trade). At each keeper deployment it is bought at the chain's own TWAPs and locked as bids just below spot under `canonical(j)`, the coin that won round `j`, and nowhere else. `deployAncestor(j, amount)` takes a generation and an amount; the destination is not an argument and not a keeper choice.
- **What the purse IS: a permanent buy wall under the coin that won the round.** A deployment buys the parent token at the chain's own prices and locks it as a bid range under `canonical(j)`, from just under spot down to roughly 6% below it. The liquidity is locked forever and is never withdrawn, and it is a *bid*: the coin's holders can sell into it, at those prices, whenever they choose. It is sized so it cannot be used as a shove: at most 2% of the pool's active-range depth per deployment, and at most 10% of that generation's accrued ETH per 24 hours. This is not new behaviour introduced by review 3. The reinforcement share (20% of the fee) has been deployed exactly this way from the start; making the ancestor sleeve uncontested extends the same property from 20% to 40% of the fee. Keeping value on the canonical chain, in that form, is the intended outcome, not a side effect.
- **How the price is set, precisely.** The ETH the sleeve pays is priced along the links `0..j-1`, each hop taken at `min(spot, 30-minute TWAP, 7-day TWAP)`, which is the conservative direction for the vault. The TRUNK pool that receives the bid is not priced by that walk: it is band-checked, its spot sqrt price required to be within `TWAP_BAND_BPS = 3%` of its OWN 30-minute TWAP (about 6% in price terms), and the bid's tick range is then taken from its live spot. So the walk decides how much ETH leaves the sleeve, and the destination pool's own live price decides where the bid sits.
- **The losers keep their own coins.** A sibling that lost the round stays tradable, keeps the creator share of its own pool's fees, and can be as successful as its community makes it. What it does not have is a claim on the chain's fee stream.
- **Why.** Three reasons, in the order they weigh:
  1. **Keep as much value as possible on the canonical chain.** Every later generation is priced through the trunk. Liquidity locked under the trunk is liquidity every deeper coin trades against; liquidity locked under a losing sibling is stranded on a branch nothing else routes through.
  2. **It is simpler to understand.** "Each round's share of later fees is locked as liquidity under the coin that won it" is one sentence with no measurement, no window, no staleness and no ranking transaction in it. The contested version needed all five to be stated honestly.
  3. **A dumped or abandoned trunk coin is its community's problem to solve, not the protocol's to punish.** The contest existed to penalise a winner that got dumped. In practice that penalty moves money off the canonical chain at exactly the moment the chain needs depth, and a coin whose holders have walked away is far more likely to be taken over and revived by its own community than to be fixed by redirecting fees to a sibling.
- **Previously (review 2, superseded).** The purse was contestable forever among a generation's siblings: `RoundManager.rank(candidateId)` measured a sibling's trailing support out of the hook and kept a two-seat board per generation, `purseWeights` handed the keeper the split, and each deployment divided the purse proportionally between the top 2, with third and below receiving nothing. That machinery (`rank`, the board, `purseWeights`, `RANK_MAX_AGE`, `BadRanking` and the `PurseSplit` event) is removed in review 3. The trailing average itself stays as a public view on the hook; nothing pays out on it.
- Consequences (disclosed): the winner of a round keeps its generation's purse whatever happens to it afterwards, and a sibling that grows far past the winner still earns nothing from the chain's fee stream. That is the price of keeping the value on the trunk.

## 2. Adaptive round duration (based only on the round number; nobody can influence it)

Design decision: 15 minutes, doubling every 2 rounds, capped at 12 h. Longer rounds get a proportionally longer registration window, plus an open-entry period covering roughly the first third of trading (only once rounds reach an hour), where a coin may enter knowing it is at a time disadvantage.

| Round n | Trading duration D(n) | Registration R(n) | Late entry |
|---|---|---|---|
| 1–2 | 15 min | 3 min | no |
| 3–4 | 30 min | 6 min | no |
| 5–6 | 1 h | 12 min | first 20 min of trading |
| 7–8 | 2 h | 24 min | first 40 min |
| 9–10 | 4 h | 48 min | first 80 min |
| 11–12 | 8 h | 1 h (cap) | first 2 h 40 min |
| 13+ | 12 h (cap) | 1 h (cap) | first 4 h |

- `D(n) = min(15 min × 2^floor((n−1)/2), 12 h)`; `R(n) = clamp(D(n)/5, 3 min, 1 h)`; late entry allowed iff `D(n) ≥ 1 h`, during the first `D(n)/3` of trading.
- **Scoring = closing-window average (2026-09-12).** The winner is the coin with the highest market cap at the end, smoothed against manipulation: the score is the average net parent absorbed (≡ market cap in parent units for identical curves) over the closing window `[T_end − W, T_end]`, with **`W = 15 min` on EVERY round** (`RoundManager.CLOSING_WINDOW_S`, divided by `DURATION_SCALE_DIV` on a testnet run). Design decision: the coin with the highest market cap should win, and the time average exists only as a defence against market and oracle manipulation; 15 minutes is the window. **Revision 2026-09-12:** the window used to widen with the round (`D(n)/4` above an hour: 2 h → 30 min, 12 h → 3 h). It is now flat, so the round number changes only how long a coin has to build support, never the yardstick that support is measured with, and the published rule is one number instead of a table.
- A late entrant's pool opens the moment it registers (its own 3-second snipe tax applies from that moment) and is scored over the **same closing window as everyone else**; its only handicap is less time to reach a high level — having less time to market a token and find buyers *is* the time penalty. No own-window or full-window averaging; the earlier 1.5×/2× late-burst caveats do not apply.
- Trade-off (disclosed): a coin can lead for hours and lose to one pumped and held through the closing window plus the unknown final 3 minutes; leaderboards are public, so late money knows what to beat. Defences: the random end, the fact that capital must be held rather than flashed, and the leader's community's time to respond. Longer windows favour defenders; the safe tuning direction is up.

  The maintainer's reasoning for taking the window flat anyway (2026-09-12): **the random end already removes the last-seconds game, and a window sniper must exit into the market it just pumped, which the simulation does not model.** Sims 11-13 measure the sniper's win rate but not what it costs to get back out of a position the size of the leader's, in a pool whose only depth is the locked curve and the family's own bids; the modelled edge is therefore an upper bound on a real one. The trade-off above stands as written and is still disclosed.
- Round number n is the canonical index being contested; the schedule is a pure function of n, stored as deploy constants, and cannot be changed by anyone.
- Rationale: early rounds must show the system working within ~20 minutes; mature rounds sustain engagement and fees for longer; a 5-minute registration on a 12-hour round would starve good coins of the chance to enter.

## 3. Random end inside the last 3 minutes (requirement: on-chain provable, genuinely random, not a predictable algorithm)

Constraint (final audit F6): a contract cannot keep a secret; anything computable before the end is knowable before the end; Arbitrum's `prevrandao` is a constant and block hashes are sequencer-influenced.

Pattern that satisfies the requirement — **retrospective random end**:
- The round has a public nominal end `T`. Nobody trades after `T` counts.
- Research result (2026-09-12): Chainlink VRF, Pyth Entropy and Supra dVRF are **not deployed** on chain 4663/46630; `prevrandao` is the constant 1 and block hashes are sequencer-influenced on Arbitrum Nitro. The provable source available without a vendor is **drand** (League of Entropy public beacon): at `T` the round manager pins a **future** drand round number `R` (the first round scheduled after `T` plus a safety margin); nobody can know that round's value before it is produced. After `T`, anyone relays the beacon's BLS signature for round `R` and the contract verifies it on-chain against the beacon's public key; the random word is the signature hash.
- Implementation must first verify: which drand beacon is live and verifiable on this EVM (evmnet on BN254 via the pairing precompile, or quicknet on BLS12-381 if EIP-2537 precompiles exist on Robinhood's ArbOS), and use a reviewed verifier library. If none is verifiable here, the randomness source stays a pluggable `IRandomnessSource` with a clearly labelled testnet mock, a deterministic fallback, and the choice disclosed.
- The provider returns a verifiable random word `r` a few blocks later. The actual end is `T_end = T − (r mod 180 s)`.
- The hook keeps, for every candidate pool, a ring of score checkpoints `(acc, R, t)` covering the last 3 minutes (one entry per 5 s, 36 entries, written only when a swap happens in that slot; gaps are reconstructed exactly because `R` is constant between swaps). `submitScore` evaluates each candidate's average at `T_end` from the ring.
- Nobody, including the operator, can know `T_end` before `T`; last-second buying in the final 3 minutes is a gamble that may fall after the true end.
- Fallbacks (disclosed): if the provider has not fulfilled within `VRF_TIMEOUT` (e.g., 30 min), anyone may finalize with `T_end = T` (deterministic; the randomness is simply absent for that round). The provider's liveness and honesty are a trust assumption and are named in the docs.
- Fallback trust statement for the docs: the random end depends on the drand beacon being produced and relayed; if it is not relayed within the timeout, the round ends at `T` deterministically. The beacon is public, verifiable and not controlled by Dollhouse.

## 4. What the public docs must say (every decision here is intentional and must be documented as such)

- Why the purse goes to the trunk coin and nowhere else (value stays on the canonical chain; one sentence to understand; a dumped coin is its community's to revive).
- What a losing sibling does and does not get: its own coin, tradable, with its creator share; no claim on the chain's fee stream.
- Why rounds get longer as the chain matures, the exact schedule, and why late entry exists for long rounds with a stated handicap.
- Why the end is random within the last 3 minutes, how the randomness is produced and verified, and what happens if the provider fails.
- That all of these are fixed numbers in the contracts that no one can change.

## 5. Implementation checklist (before the paid audit)
1. Hook: keep the accumulator running after the round; checkpoint ring covering `W + 3 min`; expose `averageOver(poolId, tStart, tEnd)` and `trailingAverage(poolId, W)`. Review 3: `trailingAverage` is a public view only; no payout depends on it.
2. RoundManager: duration/registration schedule; late-entry registration during the open-entry window (pool opens at registration); closing-window scoring `averageOver(poolId, T_end − W, T_end)`; randomness request at `T`, fulfilment callback storing `T_end`, timeout fallback.
3. FeeVault/BidDeployer: per-generation purse deployment locks the generation's accrued support as bids under `canonical(j)`, the trunk coin, in full. `deployAncestor(j, amount)`; no ranking inputs, no split.
4. Sims: purse dynamics (Sim 11: comeback and dump scenarios, SUPERSEDED by the review 3 decision, see `docs/sim-results-v3.md`), adaptive duration vs demand (Sim 12), random-end value (Sim 13: late-buy expected loss).
5. Tests for every rule; testnet run 6 with a long round configured short (constants are deploy params on testnet) and a live random end.
6. Docs: Mintlify pages `how-a-round-works`, `tokenomics`, `why-competition` (+ new `intentional-choices`), `risks`; `DEPLOY_CONSTANTS.md`; `PROTOCOL_SPEC.md`; `READINESS.md`.

## 6. Simulation findings (Sims 11–13, `docs/sim-results-v3.md`, 2026-09-12) — to disclose
- **Random end** (Sim 13): 15-min round, last-second sniper's flip rate 2.4% → 0.2%; spreading over the last 3 min keeps 67% of value and flips 18.2% → 7.6%. In a 12-h round a fixed-end sniper already flips 0.00%, so the random end mainly protects short rounds; it is kept uniform for simplicity.
- **Closing-window rule, re-run (Sims 11–13, 2026-09-12)**: late entry is equal by construction (asserted in tests). A **window sniper** — capital equal to the leader's, bought at the start of the closing window and held — beats a leader still spreading its buys ≈82% of the time in a 4-h round and ≈93% of 15-min rounds, fixed or random end alike; this is the rule working as defined (highest market cap at the end wins; late money that stays counts fully), not manipulation, and it is disclosed as "a long-time leader can lose to money that arrives for the closing window". The random end only removes the last-seconds spike game (2.4% → 0.2%). Purse parking over the shorter window is marginally profitable (+$1.74 on ≈$15 of friction at generation 10's scale) — disclosed.
- **Purse capture by parked capital** (Sim 11, SUPERSEDED 2026-09-13): parking capital equal to the leader's trailing support for one day costs ≈15 bps friction + carry and was break-even at the modelled fee flow (breakeven multiple 0.61×), profitable above it. The review 3 purse has nothing to park for: the destination is fixed at the round result, so this attack no longer exists.
- **Dump penalty works** (Sim 11, SUPERSEDED 2026-09-13): a winner dumping 90% lost the lead 92% of the time and was out of the money 84%. Review 3 removes the penalty deliberately; see §1's third reason.
- **Sim caveat**: at rounds ≥ 8 h the demand assumption (∝ √D) implied absorbing more parent tokens than exist; the reported curve exhaustion at high rounds is a modelling artefact — real rounds are bounded by the parent's float. Monitor on mainnet; no constant change.
