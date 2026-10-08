# Dollhouse: formal property list

## 1. Scope and method

Every property below is derived **only** from the written specification (`docs/spec/PROTOCOL_SPEC.md`,
`docs/DEPLOY_CONSTANTS.md`, the design-analysis reports and the
public documentation site); no contract, test or script source was consulted, so a property the
implementation violates is a finding, not a documentation error to be reconciled away.
Each row carries an ID, a one-sentence quantified statement, a class (*safety*, a bad thing never
happens; *conservation*, a sum is exact; *purity*, a value depends only on the named inputs;
*access*, only the named caller may act; *liveness*, a good thing stays reachable; *arithmetic*, a
closed form holds to a stated tolerance), and one or more verification tiers: `U` unit, `F` stateless
fuzz, `I` stateful invariant (handler-driven), `K` fork test against the real Uniswap v4 `PoolManager`
on chain 46630, `H` Halmos symbolic, `C` Certora rule.
Tier `H` is listed only where a symbolic check exists under `test/halmos/` (reconciled against
the tree on 2026-09-26: FEE-11, SLV-01, SLV-02, SLV-04 and RND-11; `docs/security/halmos.md`
names each check). The Halmos candidates of section 5 that have no check are not claimed as a tier.
Which tests carry each tier, and which tiers have **no automated test**, is recorded in
`docs/security/PROPERTY_RESULTS.md`.
`★` marks the highest-value properties: a violation of any of them is a critical, unrecoverable loss of
funds, supply or history, and each is cheap to state and expensive to discover by testing alone.

## 2. Components and actors

**Components.** `FamilyToken` (fixed-supply ERC-20 clone, burnable by the holder only) · `FamilyFactory`
(genesis adoption and candidate launch, curve derivation, wiring) · `Locker` (sole owner of every
liquidity position; curve placement and bid deposit only, no exit) · `FamilyHook` (singleton: pool
registration, fee collection, score accumulator, score checkpoint rings, TWAP rings, attribution) ·
`RoundManager` (head machine, round schedule, end settlement, submission, finalization, purse
deployment, steward role, sunset and continuation) · `FeeVault` (ledgers, accrual, claims, forwarding
queue, drawdown bucket) · `BidDeployer` (keeper pricing, size caps, bid placement, purse deployment) ·
`FamilyRouter` (multi-hop routing and attribution, no privilege) · `IRandomnessSource` / `DrandSource`
(drand `evmnet` BN254 beacon verifier) · `FamilyLens` (views only) · libraries `CurveMath`,
`StandardCurve`, `FenwickRangeAdd`.

Canonical index 0 is `GENESIS_TOKEN`, an already-graduated, 18-decimal ERC-20 launched
outside this protocol and adopted once, inside `FamilyFactory.wire()`, by the factory-only
`RoundManager.adoptGenesis`. there is no separate, permissionlessly-callable
`adoptGenesis(token)` entry point on the factory any more, and the creator attribution is fixed at
construction, so front-running the adoption is inert: whoever sends the `wire()` transaction, the
outcome is identical. Index 0 has no pool key, no curve and no developer allocation in this
deployment; the chain this protocol prices and charges fees on starts at link one, denominated in
the adopted token ("$DOLL" below). There is no developer allocation of any family token.

**Actors.** *Trader* (swaps directly or through the router) · *Deployer* (sends `wire()`, which
adopts the genesis token once as an inseparable part of the same call; gets the fixed creator
attribution of index 0, which carries no fee stream) · *Creator* (registers candidates,
claims the creator share) · *Keeper* (permissionless caller of `deployAncestor`, `deployEdgeBid`,
`deployHopPot`) · *Steward* (announce/cancel sunset; transfer the steward role) · *Developer* (claim
the 20% edge-currency ledger; transfer the developer role) · *Relayer* (calls `requestEnd`,
`fulfilEnd`, `finalizeDeterministic`, `submitScore`, `finalize`, `flushForward`) · plus the *successor
stack* (a later version's `RoundManager`/`FeeVault`/router) as a semi-trusted, gas-bounded external
party.

## 3. Properties

### 3.1 Supply and liquidity

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ SUP-01 | For every family token created by this protocol (index 1 and deeper; index 0 is external and out of scope), `totalSupply()` equals `1e9·1e18` immediately after `initialize` and is non-increasing forever after, decreasing only by the exact amount a holder passes to `burn` from their own balance. | safety | U,F,I,C | Falsified by any mint path, any burn of another address's balance, or a launch-time supply differing from the constant. |
| ★ SUP-02 | For a candidate token, tokens placed in Locker positions plus dust burned at launch equal `1e9·1e18` exactly. **** every candidate, link one included, sells its whole supply; there is no developer allocation of any kind, at any index. | conservation | U,K | Exact, no tolerance: the dust burn absorbs all rounding. |
| SUP-04 | After adoption, no protocol contract (`FamilyFactory`, `RoundManager`, `FamilyRouter` or `BidDeployer`) ever holds a positive balance of any family token or of the adopted edge token; `FeeVault`'s edge-token balance is bounded below by its own ledgers (`ledgerTotal[EDGE] <= holdings(EDGE)`, FEE-11) and an unsolicited donation into the vault is never sweepable and never credits a ledger. | safety | I | Falsified by any residual factory/locker/vault balance that can be moved, or by a donation becoming claimable. |
| SUP-05 | No call by any caller, in any state, reduces the liquidity of any Locker-owned position; `beforeRemoveLiquidity` reverts unconditionally, including when the caller is the Locker itself. | safety | U,I,K | The ratchet: per-pool locked liquidity is monotone non-decreasing over any handler sequence. |
| SUP-06 | `beforeAddLiquidity` reverts for every sender except the Locker, and `beforeDonate` reverts for every sender. | access | U,K | Donation must be impossible, or the score's "swap deltas only" claim is void. |
| SUP-07 | `beforeInitialize` reverts unless the exact `PoolKey` was pre-registered by the factory, and reverts if the initial sqrt price differs by one wei from the registered `initSqrtPriceX96`. | access | U,K | Pre-initialization poisoning (finding 8). Index 0 has no pool key at all (`poolKeyOf(0)` is zero); this property only ever applies to link one and deeper. |
| SUP-09 | Two different callers of `registerCandidate` for the same round obtain byte-identical curve ranges and `initSqrtPriceX96`; only the recorded creator differs. **** adoption computes no curve and no price, so caller-independence is trivial by construction rather than by identical derivation; there is no caller-dependent field either: `genesisCreator` is now fixed at construction to the deployer, not written by whoever calls `wire()`. | purity | U | Caller-independence (C2). |
| SUP-10 | Adoption succeeds at most once per deployment (`GenesisAlreadyAdopted`), requires the token to have 18 decimals and a nonzero total supply, and is dead (`ContinuationHasGenesis`) on a continuation deployment. | safety | U | |

### 3.2 Fees

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ FEE-01 | **one edge fee per traversal of an edge pool.** A route of any length `L` that traverses one edge pool (a pool whose parent is canonical index 0) pays exactly one protocol fee of `PROTOCOL_FEE_PPM = 10_000` ppm on the $DOLL-side amount of that leg, and zero protocol fee on the other `L−1` legs, in both directions and for every `L ≥ 1`. Every round-one pool is an edge pool forever, computed once by the factory at registration (`isEdge = parent == canonical(0)`). | conservation | U,F,K,C | Falsified by any depth- or leg-count-dependent protocol fee total, or by a second edge pool sharing the fee. |
| FEE-02 | Every family pool charges `hopFeePpm` (deploy 750 ppm) on the parent side of every swap, edge leg included, so a full-line route to index `L` pays one 1% edge fee plus exactly `L` hop fees. | conservation | U,K | Assert per leg: each hop fee is a fraction of that leg's own parent amount, so the total is not a closed form in $DOLL. |
| FEE-03 | `hopFeePpm ≤ MAX_HOP_FEE_PPM = 10_000` is enforced at construction, and no function anywhere changes any fee rate or split after deployment. | safety | U | |
| FEE-04 | The snipe tax on a candidate pool at time `t` is `SNIPE_START_PPM + (SNIPE_END_PPM − SNIPE_START_PPM)·(t − tradingStart)/SNIPE_S` for `t ∈ [tradingStart, tradingStart+3 s)` and exactly 0 for `t ≥ tradingStart + 3 s`; every registered pool, edge pools included, has a real `tradingStart` and no exemption. | arithmetic | U,F,K | 990_000 → 10_000 ppm linearly over 3 s. A late entrant's `tradingStart` is its own registration timestamp. A new round-one pool is BOTH edge and snipe-taxed for its first 3 s; see FEE-06's restatement for how the two coexist. |
| FEE-05 | For a fixed parent-side gross amount, the total fee is identical in exact-input and exact-output mode and on both pool sides: `fee = gross · rate`, where the hook grosses up `basis = poolCost/(1−rate)` whenever it is handed the pool's side. | arithmetic | U,F,K | Tolerance ≤ 1 wei of integer division. Falsified by the `rate/(1+rate)` shape (F9). |
| FEE-06 | **time-based exclusion, not pool-class exclusion.** `protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM : 0`, the edge fee is suppressed for exactly the 3-second snipe window of a new round-one pool, so the two rates are never summed on the same swap; a parent-paying exact-output swap whose remaining summed rates reach or exceed 100% still reverts rather than producing an unbounded or wrapped gross-up. | safety | U | Reachable only in the first instant of the snipe window with `hopFeePpm` at its ceiling, on a non-edge pool (an edge pool suppresses its protocol fee for that same instant). |
| FEE-07 | The increase of the v4 protocol fee observed across a swap is subtracted from the scored amount, so a nonzero v4 protocol-fee controller changes no candidate's score. | safety | U,K | The controller is unset on 46630; set one in the fork harness if possible. |
| ★ FEE-08 | For every swap, `Δdev + Δcreator + ΔcoCredit + Δsleeve + Δreinforce == protocolFee` and `Δreinforcement[parent] == hopFee + snipeFee`, with no other ledger changed and no wei created or destroyed. | conservation | U,F,I,C | Exact: floor division with the last bucket taking the remainder. This is the fee-conservation property. |
| FEE-09 | `DEV_BPS + creatorBps ≤ BPS` and `ancestorBps + reinforceBps == BPS` are checked at construction; at the deploy constants the split is exactly dev 20% / creator 40% / sleeve 20% / reinforcement 20% of each protocol fee. | conservation | U | The test harness runs a different split (DIFF 5); assert the deploy numbers explicitly. |
| FEE-10 | Fees only ever move into `devBalance`, `creatorBalance[token]`, `creatorAccrued[addr]`, the three Fenwick coefficient trees, `reinforcementEdge[j]`, `reinforcementBalance[parent]`, `edgeBidEarmark` and `pendingForward[attribution]`; no other destination exists. | safety | I,C | An exhaustive destination list; falsified by any new sink. Renamed (`reinforcementEth` to `reinforcementEdge`, `genesisBidEarmark` to `edgeBidEarmark`); the set of destinations is unchanged. |
| ★ FEE-11 | For every currency `c` at every instant, `ledgerTotal[c] ≤ holdings(c)`, where `holdings` counts unredeemed ERC-6909 claims plus the real balance and `ledgerTotal` includes `pendingForward`. | safety | I,H,C | Vault solvency. Must hold across forwarding, flushing, claiming, keeper draws and an unsolicited token donation, which SUP-04 states never credits a ledger. |
| FEE-12 | An unattributed swap credits `creator = 0` and `M = 0`, so its whole flywheel share lands on genesis; the developer's 20% is paid on every protocol fee, attributed or not. | conservation | U,F | |
| FEE-13 | On a partially filled exact-input swap the fee is charged on the full `amountSpecified`; this is the only case where fee basis and executed notional differ. | arithmetic | U,K | Disclosed (L1); pinned so a later change is visible. |

### 3.2b Venue lock

Replaces the earlier per-transfer side-tax charge (commit b4e42e0, 2026-10-01). A chain coin
(any family token, index 1 and deeper) can only be traded on its own canonical pool; the fee
itself moved from a transfer-time charge on the coin to a swap-time collection by the hook, on
the parent/$DOLL side of that canonical pool only.

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ VEN-01 | A family token's `transfer`/`transferFrom` reverts `NonCanonicalVenue(from, to, reason, available)` whenever the movement would place or hold the token in a non-canonical venue: (1) an inbound transfer to the `PoolManager` beyond the hook's own canonical allowance for that token, (2) an outbound transfer from the `PoolManager` beyond that allowance, or (3) a transfer to or from any pool-shaped contract (one that answers both `token0()` and `token1()`) that is not the token's registered canonical pool. A plain wallet-to-wallet transfer, or a transfer to or from any non-pool-shaped contract, is never affected. | safety | U,F,I | Falsified by any transfer that lands a chain coin in a second venue without reverting, or by a wallet/non-pool transfer reverting. |
| VEN-02 | The fee that used to be charged on the chain coin's own side of a transfer is now collected entirely by `FamilyHook`, inside the swap, on the parent ($DOLL-denominated) side of that pool; no fee is ever taken from the family-token side and no fee is ever taken outside a swap. | conservation | U,F,K | Restates the old side-tax credit (`contracts/FamilyHook.sol`, "THE CANONICAL CREDIT") in terms of the parent-side collection that replaced it. |

### 3.3 Ancestor sleeve

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| SLV-01 | For `M ≥ 1` and every ancestor `j ∈ [0, M]`, the credited share equals `sleeve · w(j/M) / Z(M)` with `w(r) = 2 − 5r + 4r²` and `Z(M) = (M+1)(5M+4)/(6M)`, within the floor error of the three WAD-scaled coefficients. | arithmetic | U,F,H | Tolerance: strictly under-allocating, a few wei per ancestor per fee. |
| SLV-02 | Every ancestor `0..M` of the attributed token receives a share whenever its floored term is nonzero, and no index outside `[0, M]` is ever credited. | safety | U,F,H,C | Falsified by crediting non-ancestors (finding 3). |
| ★ SLV-03 | The sum of point queries over `[0, M]` is ≤ the sleeve amount for every sleeve and every `M`, never greater; the residue is permanently unclaimable. | conservation | F,I,C | Under-allocation is what makes FEE-11 hold by construction; one over-allocation breaks solvency. |
| SLV-04 | For any sequence of range-adds over `[0, M_k]` and any query index `i`, the Fenwick point query equals the naive summation over a brute-force ledger, exactly. | arithmetic | F,I,H | Signed trees: `c1 < 0`, so intermediate prefix sums legitimately go negative. |
| SLV-05 | `w(0) = 2·w(M)` for every `M ≥ 1`, `w` attains its minimum at `r = 5/8`, and genesis's share decays as `12/(5M)`. | arithmetic | U | Shape property; also the "no fixed genesis floor" claim. |
| SLV-06 | `M == 0` credits genesis alone with the whole sleeve, with no division by zero. | safety | U | |
| SLV-07 | A range-add or point query with index > `MAX_INDEX = 4095` reverts, and registration refuses to create such an index first. | safety | U | Two independent caps (structural 4095, policy `MAX_INDEX`). |

### 3.4 Score and the closing window

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| SCR-01 | The accumulator update is exactly `acc += R·(now − tLast); tLast = now; R += (−parentDelta_pool)`, where `parentDelta_pool` excludes every hook-charged fee and the v4 protocol fee, in all four specified/unspecified × exact-in/exact-out orientations. | arithmetic | U,F,K | Falsified by any double subtraction of the fee (C1). |
| SCR-02 | `R` increases on a net buy and strictly decreases on a net sell, and no transfer, donation, balance change or approval changes `acc` or `R`. | safety | U,I | SUP-06 (donations disabled) is a precondition. |
| SCR-03 | A buy inside the snipe window increases the score by the post-fee pool delta and never makes the score negative; the same buy later in the window scores strictly more. | safety | U,F,K | At 99% + 1% + hop the delta stays positive. |
| ★ SCR-04 | For every `t0 < t1` and every pool, `averageOver(id, t0, t1)` equals `(acc(t1) − acc(t0))/(t1 − t0)` computed from the exact swap history, for any pattern of swaps and gaps within the rings' span, WHENEVER both edges resolve to a bracket or to the live state. Otherwise SCR-14 bounds the answer. | arithmetic | F,I | Exactness is the point of storing pre-swap state per slot. The inexact case is SCR-14, rather than leaving it as a parenthetical: it is reachable on purpose, not only by accident. |
| SCR-05 | A checkpoint slot is written at most once, by the first swap in that slot, and a slot with no swap reconstructs exactly because `R` is constant between swaps. | arithmetic | U,F,I | |
| SCR-06 | The fast ring spans exactly `36 × 5 s = 180 s = RANDOM_END_S`, and the coarse ring's 63 usable slots of `scoreSlotFor(n) = ceil((W + RANDOM_END_S)/63)` span at least `W + RANDOM_END_S`, for every round number `n`. On the mainnet schedule that is `ceil(1080/63) = 18 s` and 63 × 18 = 1134 s of reach; on `DURATION_SCALE_DIV = 5` it is `ceil(360/63) = 6 s`. | arithmetic | U | Ring writes freeze at the pool's published end `T`, so the ring must REACH the scored span but no longer has to SURVIVE churn during settlement. Falsified if any reachable `T_end − W` falls outside the coarse ring. |
| SCR-07 | Two candidates with identical net parent absorbed throughout `[T_end − W, T_end]` receive identical scores regardless of when their pools opened, provided both opened at or before `T_end − W`. | purity | U,K | Late-entry fairness. |
| SCR-08 | A candidate whose pool opened after `T_end − W` is scored from its own `tradingStart` rather than reverting. | liveness | U | Only reachable on a scaled testnet schedule; stated so it is not silently removed. |
| SCR-09 | Parent absorbed and then sold back before `T_end − W` contributes nothing to the score: the window measures a level, not a total. | safety | U,F,K | |
| SCR-10 | POST-BELL FLOW CANNOT CHANGE THE SAMPLED INSTANT OR THE VALUE. No swap with `block.timestamp > T` (the pool's published end, and therefore no swap after `T_end`, which is never later than `T`) writes any checkpoint, so neither the instants `averageOver` resolves the two edges to nor the value it returns can be changed by anything traded after the bell, while such swaps still execute, still pay fees and still move the live accumulator the trailing views read. PRE-BELL dust CAN still shift the FAR edge: `T_end − W` may resolve to a sample at most one coarse slot (`scoreSlotFor(n)`, 18 s against a 900 s window on mainnet) earlier, never later. | safety | U,K | Without the ring freeze, burying the fast ring in dust after the reveal could move the `T_end` edge off the live state onto whichever sample survived; the freeze closes that by construction; the accumulator itself is still never frozen, only the ring writes are. |
| SCR-11 | `submitScore` is permissionless, idempotent per candidate, and reverts outside `[tradingEnd, submitEnd)` or before the end is settled. | safety | U | |
| SCR-12 | The tie rule orders candidates by higher average, then earlier `tFirstAttained`, then lower `uint256(poolId)`, and is a total order: two distinct candidates can never both beat each other. | safety | U,F | `tFirstAttained` is a block timestamp, never a hash. |
| SCR-13 | SCORE AVAILABILITY. For every candidate of a settled round, `submitScore` succeeds at every instant of `[tradingEnd, submitEnd)`, whatever any trader does before, at or after `T_end`. No pattern of swaps can make a round's score unreadable. | liveness | U,I | Falsified by a single swap placed later in `T_end`'s own 5-second slot, and by one-per-slot dust across the fast ring after the reveal. |
| SCR-14 | FALLBACK EXACTNESS BOUND. When an edge `t` has no bracketing checkpoint, `averageOver` evaluates the accumulator EXACTLY at the largest checkpointed `tSwap <= t` across both rings, and divides by the span between the two instants it actually used. The instant used is at most one coarse slot (`scoreSlotFor(n)`, 18 s on mainnet) before `t`, and is never after it. Both instants are RETURNED and are carried in `RoundManager.ScoreSubmitted` (`tStartUsed`, `tEndUsed`), so a fallback resolution is visible in the logs. When the two resolve to the SAME instant the call REVERTS `BadScoreWindow` rather than answering zero; that is unreachable while `closingWindowFor(n) > scoreSlotFor(n)`, which `DeployConstants.t.sol` asserts for `DURATION_SCALE_DIV ∈ {1, 5}`. | arithmetic | U,F | The bound is what keeps SCR-10 true: every reachable sample is stamped at or before `T` and holds a pre-swap state, and no sample stamped after `T` exists at all. |
| SCR-15 | THE FLOOR. Every candidate's pool opens at its own registration (`c.tradingStart = block.timestamp`, at or before `max(r.tradingStart, T − W − RANDOM_END_S)`), and every candidate of a round is scored over the same span `[max(T_end − W, r.tradingStart), T_end]`: `ScoreSubmitted.tStartUsed == max(T_end − W, r.tradingStart)` for all of them. Trading before the round clock is not scored; support bought then and still held counts exactly like the same support bought at the clock. | safety | U,I | `InstantTrading.t.sol`; `Invariants.t.sol::invariant_everyPoolOpensAtRegistrationAndBeforeTheScoredWindow` |

### 3.5 Round lifecycle

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| RND-01 | The whole round `L(n) = min(10 min · 2^floor((n−1)/2), 12 h)`, `registrationFor(n) = clamp(L(n)/5, 3 min, 1 h)/DURATION_SCALE_DIV`, `durationFor(n) = (L(n) − R(n))/DURATION_SCALE_DIV`, `roundLengthFor(n) = registrationFor(n) + durationFor(n)`, `lateEntryUntil(n) = D(n)/3` iff the unscaled `D(n) ≥ 1 h` (from round 7) else 0, `closingWindowFor(n) = CLOSING_WINDOW_S/DURATION_SCALE_DIV` (a flat 15 min on every round), `randomEndWindowFor(n) = max(1, min(180 s, D(n)/4))`, each a pure function of `n` alone. | purity | U,F | No caller, steward or timestamp may perturb any of them. Reproduce the published table row by row. |
| RND-02 | For every `n`, `lateEntryUntil(n) < D(n) − closingWindowFor(n) − RANDOM_END_S`, so no candidate is ever scored over a span beginning before its own pool opened. | arithmetic | U | Must hold at every legal scale divisor. |
| RND-03 | The only reachable transitions are Unlaunched→Idle, Idle→Registration, Registration→Trading (clock), Trading→EndPending (clock), EndPending→Submission (via `fulfilEnd` or `finalizeDeterministic`), Submission→Finalizable (clock, or the last candidate's `submitScore`), Finalizable→Finalized+Idle, plus the sunset announce/cancel pair; no other transition exists and none is privileged. | safety | I,C | A state-machine invariant over a handler calling every external function in every order. |
| RND-04 | `requestEnd()` is callable only at or after `T`, at most once per round, and pins a beacon round whose scheduled production time is strictly in the future at the moment of pinning. | safety | U,K | The unpredictability of `T_end` rests entirely on this. |
| RND-05 | On fulfilment, `tradingEnd = T − (word mod randomEndWindowFor(n))` so `T_end ∈ (T − 180 s, T]` at mainnet constants (`(T − 105 s, T]` on the ten-minute rounds 1–2), and `submitEnd = block.timestamp of fulfilment + 300 s`. | arithmetic | U,K | The submission window starts at settlement, not at `T`. |
| RND-06 | If no verifiable beacon is relayed within `END_TIMEOUT = 30 min` of `T`, anyone may settle `tradingEnd = T` with a loud event, without anyone having called `requestEnd` first; the end can be settled at most once by either path. | liveness | U,K | A round never hangs on the beacon. |
| RND-07 | `finalize()` reverts before the end is settled, and reverts before `submitEnd` unless every candidate registered in the round has submitted (`submittedCount[roundId] == candidateCount`); once either holds it is permissionless, deterministic and idempotent, a second call is a no-op that cannot overwrite the head. | safety | U,I,K | Early finalize cannot exclude a score: all are in. Invariant `invariant_finalizeNeverRunsBeforeEveryScoreOrSubmitEnd` (FamilyHandler ghost recomputes "all submitted" from the candidates' own flags). |
| RND-08 | Round `n+1` cannot open until round `n` is finalized: `openRoundIfIdle` reverts otherwise. | safety | U,I | Also the liveness hazard: nothing advances a round automatically. |
| ★ RND-09 | `canonical[i]` is write-once for every `i`, at most one winner exists per index, the reverse index (`indexOf`, `parentOf`, `isCanonical`) is consistent with it at all times, and the winner branch of `finalize()` is the only writer besides one-shot continuation adoption. | safety | I,C | Append-only history. A violation is unrecoverable. |
| RND-10 | A round crowns a winner iff `hasBest && bestAvg ≥ hUsed`, where `hUsed` was snapshotted when the round opened and cannot move afterwards. | safety | U | |
| RND-11 | **the bond is a $DOLL token transfer, not native value.** On a crowned round the winner's stored bond is refunded to its creator as an ERC-20 transfer, and every other candidate's stored bond is forfeited to `FeeVault.edgeBidEarmark`; forfeited total `= candidateCount · bondAmount − winnerBond`. the forfeit delivery is attempted through a `try`/`catch`, exactly like the refund; a failure books the amount into `RoundManager.pendingForfeits` instead of reverting `finalize()`, and it reaches the earmark later through the permissionless `flushForfeits()`. Finalization never depends on the delivery succeeding. | conservation | U,F,H,K | No third destination for a bond exists; deferral changes only the timing of delivery, never the amount or the destination. |
| RND-12 | `bondFor(i) = min(BOND_BASE << (i / BOND_DOUBLING_EVERY), BOND_MAX)` (an amount of $DOLL, not wei) saturates rather than overflowing for every `i`, and a candidate is refunded/forfeited at the amount it actually posted, never a re-priced one. | arithmetic | U,F | `BOND_DOUBLING_EVERY == 0` means a flat `BOND_MAX`; doubling every 4 links, capped at 64× base. |
| RND-13 | On a failed round `hWad ← max(hWad·9/10, H_MIN_FRAC_WAD)` with `H_MIN_FRAC_WAD = 0.25·H_FRAC_WAD`; on a crowned round `hWad ← H_FRAC_WAD` exactly, so decay compounds only across consecutive failures. | arithmetic | U,F,I | Falsified by any path where `H` persists across a win. |
| RND-14 | `FamilyFactory.registerCandidate` is not payable; it opens the round first (`RegistrationClosed` wins over any allowance problem), then pulls the round's pinned bond by `safeTransferFrom(msg.sender, roundManager, bondAmount)` in the adopted edge token. Registration reverts unless the registration (or late-entry) window is open and the next index is within both depth caps. | access | U,F | Checked twice by design (factory and round manager); both checks must agree. |
| RND-15 | Registration is refused once the next index would exceed `FenwickRangeAdd.MAX_INDEX = 4095` or the immutable policy `MAX_INDEX`, at the door rather than by bricking a later swap. | safety | U | |
| RND-16 | Trading on any pool (canonical, candidate, winner or loser) is never gated after that pool's own `tradingStart`, in any round phase, before or after a sunset. | liveness | I,K | Losers' pools live forever and keep paying hop fees. |

### 3.6 Pairing rights and the trunk

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| PAR-01 | The winner's pairing rights are fixed at `finalize()`; no later call by any actor changes `head` or `headIndex` except a subsequent `finalize()` of a later round. | safety | I,C | No steal window exists. |
| PAR-02 | The canonical sequence is strictly increasing in index and never reordered, re-parented or truncated; `parentOf(i) == canonical(i−1)` for every `i ≥ 1` in a version's own range. | safety | I | |
| PAR-03 | Every candidate pool of a round is priced in the round's recorded `parentToken`/`parentIndex`, immutable from the moment the round opens, so a candidate's route survives the round unchanged. | safety | U,K | Falsified by any route resolving the *current* head (audit 8). |
| PAR-04 | The head creator's 50% season cut applies exactly while the candidate's round is in `Trading`, and 0% thereafter; a losing candidate's creator keeps everything credited during the round. | conservation | U,K | Two regimes, no clawback. |

### 3.7 The purse

The purse is uncontested: a generation's whole share is locked under the trunk coin that won its
round. There is no ranking, which is why the PUR IDs skip 01, 03, 06 and 07.

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| PUR-02 | The destination of `deployAncestor(j, amount)` is `canonical(j)` and nothing else, for every amount and whatever support any sibling has built since the round; a losing sibling never receives purse liquidity. **Two edge cases:** `j == 0` reverts `NoPoolAtIndex` (index 0 is quoted outside this protocol and has no pool to deploy into); `j == 1` is self-funded, `deployEdgeBid()` deploys the generation-0 and generation-1 pots together as one locked $DOLL bid under link one, and `deployAncestor(1, amount)` needs no keeper-supplied tokens at all, since `dollValueOfParent(1, x) == x` exactly. | safety | U,F,K | The destination is not an argument, so there is nothing for a keeper to choose. |
| PUR-04 | Exactly `amount` leaves the keeper, at least `amount` is locked (the difference is the generation's own parent-denominated hop pot topping the bid up), nothing is stranded in the deployer, and the vault stays solvent. | conservation | U,F,K | No rounding split to allocate any more. |
| PUR-05 | The daily drawdown bucket and the bounty rule are unchanged by the purse rule: the bucket falls by exactly the payout, and the bounty is `max(1%, MIN_BOUNTY_DOLL)` under its `MAX_BOUNTY_SHARE_BPS` ceiling. | conservation | U,F,K | The removal must not have moved anything else on the keeper path. Renamed (`MIN_BOUNTY_WEI` to `MIN_BOUNTY_DOLL`). |

### 3.8 Bid deployer and reinforcement

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| BID-01 | Every deposit `BidDeployer` makes lands in a Locker position that is permanently locked, single-sided on the parent side of spot, `BID_WIDTH_SPACINGS = 10` spacings wide, with `tickLower < tickUpper` or a revert; a range straddling spot reverts. | safety | U,F,K | No other deposit destination exists. |
| BID-02 | Each conversion link is priced at the value-minimum of spot, the 1800 s TWAP and the 7-day TWAP, so no price movement can *raise* what a sleeve pays relative to the averages; only a crash lowers it. | safety | U,F,K | Falsified if a 30-minute pump of a thin ancestor pool increases the payout for the same parcel. |
| BID-03 | A pool with fast TWAP coverage below 1800 s, fewer than 2 observations, or a zero TWAP cannot enter a conversion (revert); insufficient *slow* coverage (< 1 day) is not a revert but must be reported in the call's output and event. | safety | U,K | A zero-observation pool must never be a silent pass. |
| BID-04 | The ±300 bps band guard is applied to the target pool `j` only, and to every call that places a bid under `j`. | safety | U,K | |
| ★ BID-05 | $DOLL leaves `FeeVault` on the keeper path only as `payKeeper(msg.sender, payout)` against a `deployerCredit` created in the same call by `consumeAncestorClaim(j, payout)` out of generation `j`'s own ledgers, so no call moves more than generation `j`'s own money and no path transfers value to an EOA except a bounty bounded by BID-06. | safety | I,C | The leash. Also: `FeeVault` never swaps and never places liquidity. |
| BID-06 | `bounty = min(max(dollValue·100/10000, MIN_BOUNTY_DOLL), dollValue·2000/8000)`, so the bounty is never more than 20% of `payout = dollValue + bounty`, and is 1% of `dollValue` wherever neither bound binds. **Exception:** at `deployAncestor(1, ...)`, the self-funded branch where the parent IS the edge currency and the keeper brings no capital, the `MIN_BOUNTY_DOLL` floor does not apply: the bounty is the plain proportional `dollValue·100/10000` with no floor, since there is no capital delivery for a floor to compensate. | arithmetic | U,F | `deployHopPot`'s bounty has the same 1% shape but is paid in the parent token from the same pot. |
| BID-07 | A draw of `payout` from generation `j` succeeds only if `payout ≤ drawableEdge(j)`, a continuously refilling token bucket with cap `10% · claimableEdge(j)` and refill `10% · claimableEdge(j) · dt / 24 h`; there is no instant at which two draws together exceed the cap. | safety | F,I | Falsified by any window-boundary burst (audit 6 measured ≈19%). A bucket whose 10% floors to zero is allowed in full so dust is never stranded. |
| BID-08 | `deployed ≤ bidCap(j) = 2% · max(active-tick-bucket parent reserve, first-curve-range parent capacity)`, and a request above it reverts rather than being silently clamped upward. | safety | U,K | The cold-start fallback must still produce a nonzero, capped size. |
| BID-09 | A parent-denominated pot larger than the remaining room is drawn *partially* (`min(pot, cap − amount)`), never all-or-nothing, on every pot: the ETH sleeve, the hop pot and the forfeited-bond earmark. | liveness | U,K | A pot larger than the cap must not brick a generation forever. |
| BID-10 | `maxParentForDeploy(j)` returns a quote `deployAncestor` accepts, in all three bounty regimes (proportional, flat floor, below-floor 20% cap) and at both knees. | liveness | F,K | A view that under-quotes strands funds in practice. |
| BID-11 | `deployHopPot(j)` deploys generation `j`'s parent-denominated pot with no separate $DOLL entitlement involved at all, for any `j` including the current head. | liveness | U,K | Terminal-generation pot (audit 3). |
| BID-12 | `depositExternalBid` accepts only this version's links, requires exactly matching parent-token amount, creates no ledger entry and pays no bounty. | access | U,K | **** the deposit is a token transfer, not native value; there is no `msg.value` anywhere in the core stack (the only payable entry is the stateless `EthZap` periphery, which converts ETH to $DOLL before calling the router). |
| BID-13 | When generation `j`'s pool belongs to an earlier version, the bid is placed through *that* version's `BidDeployer`/`Locker`, and the TWAP read and the Locker used always belong to the same version. | safety | U,K | Falsified by reading one version's price while placing through another's Locker. |
| BID-14 | Every keeper entrypoint is `nonReentrant`, and every wei or token it draws leaves the vault within the same call, no keeper call leaves a residual credit. | safety | I,C | |

### 3.9 Continuation and handover

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| CON-01 | A continuation adopts the prior head at most once, only in its first `openRoundIfIdle`, and only if the prior's sunset is effective, the prior names this contract as successor, the prior is idle, and the prior is itself a root or already adopted. | safety | U,K,C | There is no instant at which two versions can crown the same canonical index. |
| CON-02 | Before adoption, every canonical read of a continuation delegates to the prior registry, and the continuation can open no round at all. | safety | U | |
| CON-03 | Delegated canonical reads resolve through at most `MAX_CONTINUATION_HOPS = 8` registries and revert rather than looping unboundedly. | safety | U,F | |
| CON-04 | While a version is sunset, a protocol fee on its $DOLL edge is either forwarded in-swap to the successor's vault or queued in `pendingForward[attribution]`; it is never booked to a local ledger under any gas condition. | safety | U,F,K | Falsified if the caller's gas can decide which version receives a fee (audit 4). |
| CON-05 | `flushForward(attribution, max)` moves at most `max` from `pendingForward` to the immediate successor's vault, decrementing `pendingForward` and `ledgerTotal` by exactly the amount delivered, with no recursion and no value created or destroyed. | conservation | U,F,K | A chain of `k` versions completes in exactly `k` flushes. |
| CON-06 | The in-swap forwarding hop is given `min(FORWARD_GAS, gasleft() − BOOK_GAS_RESERVE)` and is skipped entirely when that is zero, so at least `BOOK_GAS_RESERVE` always remains to queue the fee and finish the swap, for every successor behaviour including one that burns all gas it is given. | safety | U,K | Falsified if any successor behaviour can make an edge-pool swap revert or run out of gas. |
| CON-07 | A forwarding attempt that fails at the *full* budget arms a one-shot negative cache and is never retried; one that failed only because the caller's gas was thin does not arm it. | safety | U,K | A hostile successor costs at most one swap's wasted gas, forever. |
| CON-08 | `accrueForwarded` and `receiveForward` accept only a vault of a prior version in this stack's registry chain; `forwardProtocolFee` accepts only `address(this)`. | access | U | |
| CON-09 | No sunset, handover or adoption moves, unlocks or reclaims any liquidity or any wei already credited in the old vault; balances accrued before the handover stay claimable there forever. | safety | U,K,I | The old vault cannot be drained by the successor. |
| CON-10 | Successor-router resolution is a bounded sequence of 30 000-gas staticcalls whose results are validated as clean 32-byte addresses (`word >> 160 == 0`), with both the positive and the negative resolution cached write-once. | safety | U,K | A dirty word or a reverting successor must cost gas, never a revert. |
| CON-11 | Post-sunset, a pool's parent-side hop fee and snipe tax stay with the charging version and never forward. | safety | U | Only the $DOLL edge follows the live version. |

### 3.10 Roles and admin surface

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ ROL-01 | The complete set of caller-gated state-changing functions is: steward `announceSunset`/`cancelSunset`/`announce`+`cancelStewardTransfer`; developer `claimDev`/`announce`+`cancelDeveloperTransfer`; creator `claimCreator`/`transferCreatorRecipient`; plus contract-to-contract authenticity checks between immutable addresses. No other privileged function exists in any contract. | access | I,C | Enumerate the ABI and assert every other state-changing function is permissionless. Falsified by any owner, pause, setter, proxy admin or rescue path.  |
| ROL-02 | `announceSunset` succeeds at most once per deployment, requires code at the successor, requires the deployment to be a root or adopted, and takes effect exactly `sunsetDelay ≥ MIN_SUNSET_DELAY = 1 h` later. | access | U | |
| ROL-03 | `cancelSunset` succeeds at most once in a deployment's life and only strictly before `sunsetAt`; a second announcement is irrevocable. | access | U | |
| ROL-04 | A sunset stops only `openRoundIfIdle`; a round already open still registers, trades, is scored, finalizes and crowns a head. | liveness | U,K | |
| ROL-05 | For each of the two roles, `announce*Transfer(to)` is current-holder-only, refuses `to == address(0)` and refuses to overwrite a pending transfer; `execute*Transfer()` is permissionless and reverts before `announcement + 7 days`; `cancel*Transfer()` is current-holder-only and repeatable. | access | U,F | `RoundManager.ROLE_TRANSFER_DELAY == FeeVault.ROLE_TRANSFER_DELAY == 7 days`. Only steward and developer hold roles. |
| ROL-06 | Executing a role transfer grants exactly the surface the outgoing holder had: no new function becomes callable, no delay shortens, and no round, pool or balance is touched. | safety | U,C | |
| ROL-07 | `transferCreatorRecipient` sweeps the current `creatorBalance[token]` into the *old* recipient's `creatorAccrued` ledger, zeroes it, and refuses `to == address(0)`; a swept accrual survives any number of later transfers. | conservation | U,F | Falsified by handing accrued fees to the new recipient. |
| ROL-08 | `steward == address(0)` is legal and makes sunset (and therefore continuation) permanently impossible. | safety | U | |

### 3.12 Randomness

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| RAN-01 | `fulfil(id, proof)` accepts a 64-byte BN254 G1 signature iff the pairing check against the published `evmnet` G2 group public key succeeds over the message `keccak256(uint64 round, big-endian)` mapped to the curve by RFC 9380 `expand_msg_xmd`/SvdW with the documented domain tag. | safety | U,K | The keccak256 (not sha256) digest is an empirically established, load-bearing fact: assert it against two real beacons. |
| RAN-02 | A signature for any round other than the pinned one, a tampered signature, or a point not on the curve is rejected. | safety | U,F | |
| RAN-03 | `pin()` always records a beacon round whose scheduled production time is strictly after `block.timestamp`, for every call time. | safety | U,F | If this fails, `T_end` becomes knowable before `T`. |
| RAN-04 | A beacon round value already consumed by one round cannot settle a second round, and a given round's end cannot be settled twice by any combination of `fulfilEnd` and `finalizeDeterministic`. | safety | U,I | |
| RAN-05 | The randomness source address is an immutable constructor parameter, no function switches it, and the mock source is distinguishable on-chain by its own flag. | access | U | |
| RAN-06 | Withholding the beacon produces exactly one outcome, `T_end = T`, and never a hung round. | liveness | U,K | The trust statement: no party can bias a round by withholding. |

### 3.13 Router

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ROU-01 | Every exact-in entrypoint reverts unless the final output is ≥ `minOut`, checked after the unlock returns, and a round-trip path reports the last leg's output rather than a netted zero. | safety | U,F,K | |
| ROU-02 | The fees paid by a routed swap equal those paid by an equivalent direct `PoolManager` swap, wei for wei; `hookData` affects only which ledger is credited, never any fee amount. | safety | U,F,K,C | The router is never fee-privileged. |
| ROU-03 | `hookData` attribution is trusted only when the sender is the canonical router or a validly resolved successor router and the data is at least 32 bytes; any other sender's `hookData` credits nothing. | access | U,K | A copycat router is credited nothing. |
| ROU-04 | `swapPath` enforces per-leg adjacency (`to == from+1`, `from == to+1`) starting at index 1 and reverts otherwise; `maxHops` bounds the whole route including a candidate leg. There is no native-ETH sentinel and no leg touching index 0: the router is $DOLL-only. | safety | U,F | |
| ROU-05 | The router has no `receive()` and no `msg.value` path anywhere; every entrypoint takes `amountIn` as an ERC-20 pulled from the caller, so no native value can be parked in it and later swept. | safety | U,F | |
| ROU-06 | Every positive intermediate residual is paid to `to`, and every negative one reverts with a named per-leg error. | conservation | U,K | A route never leaves value in the router. **** there is no native-settle branch and nothing to refund; every leg is an ERC-20 pull of exactly `amountIn`. |
| ROU-08 | `buyCandidate`/`sellCandidate` are refused only while the candidate's round is `Idle` (a candidate's pool opens at its registration, so `Registration` routes like `Trading`), and work forever afterwards, win or lose. | liveness | U,K | |

### 3.14 Reentrancy and ordering

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| REN-01 | No call originating inside a `PoolManager` unlock reaches a state-changing function of `RoundManager` or `FeeVault` except the hook's own accrual/score path; in particular no swap can re-entrantly call `finalize`, `submitScore`, a claim or a keeper entrypoint. | safety | I,C | The strongest ordering property: a handler must attempt every such call from inside a swap and observe a revert or a no-effect. |
| REN-02 | `finalize`, every claim function and every keeper entrypoint are `nonReentrant` and follow checks-effects-interactions: the relevant ledger is zeroed or decremented before any external transfer. | safety | U,I,C | |
| REN-03 | A creator, developer or winner contract that reverts on receiving ETH cannot brick finalization, another party's claim, or another generation's keeper call. | liveness | U,F,K | Push with a pull fallback. |
| REN-04 | Nested `unlock` never occurs: a whole route, a curve placement and a bid deposit each run inside exactly one unlock. | safety | U,K | |
| REN-05 | `unlockCallback` on the router, Locker and vault accepts only the `PoolManager`. | access | U | |

The per-row text above is authoritative for the property count and each property's tiers.

## 4. Fork-test scenarios (K): real `PoolManager`, fork of chain 46630

RPC from `.env` as `RPC_TESTNET`, read-only; every scenario deploys a fresh stack on the fork, so no live
state is mutated.

1. **Genesis adoption and first buy through the router.** Deploy a mock external $DOLL, `adoptGenesis`,
   then assert index 0 has no pool (`FamilyLens.hasPool(0) == false`) and no dev allocation exists
   anywhere. Register the first link-one candidate, crown it, then a router `buyExactIn`: assert the 1%
   edge fee plus the 750 ppm hop fee, the four ledger deltas summing to the protocol fee, and the creator
   credit. Covers SUP-02/04/09/10, FEE-01/02/08, ROU-01/02.
2. **Three-deep path, fee-once.** Crown two links, then `buyExactIn(targetIndex = 2)` and the reverse
   `sellExactIn`: exactly one protocol fee on the edge leg in each direction, three hop fees, and a
   protocol-fee total identical to the one-hop case at the same $DOLL notional. Covers FEE-01/02, ROU-04.
3. **Snipe tax at t+1 s, t+2 s, t+4 s.** Identical buys into a fresh candidate pool at three offsets from
   its own `tradingStart`, in both exact-in and exact-out mode: the linear ppm schedule, parity between
   modes, zero tax at +4 s, and a positive, increasing score contribution. Covers FEE-04/05, SCR-03.
4. **Late entry plus closing-window win.** A scaled long round: candidate A buys steadily from
   `tradingStart`; candidate B registers inside `lateEntryUntil` and buys the same total inside
   `[T_end − W, T_end]`; `requestEnd` → real drand relay → `fulfilEnd` → `submitScore` → `finalize`.
   Assert `T_end ∈ (T − 180 s, T]`, equal scores for equal closing-window support, and that support A sold
   before the window did not count. Covers RND-01/02/04/05, SCR-04/07/09.
5. **Beacon timeout fallback.** Same round, no relay: advance past `END_TIMEOUT`, call
   `finalizeDeterministic`, assert `T_end == T`, the loud event, the submission window opening at the
   fallback call, and that a later `fulfilEnd` is refused. Covers RND-06, RAN-04/06.
6. **Purse deployment.** After a round with a winner and two losers, buy the runner-up hard and dump the
   winner's pool, then `deployAncestor(j, amount)`: the singleton records exactly one liquidity addition,
   into `j`'s own pool, none into either loser's; the event names `canonical(j)`; the amount conserves; and
   the bucket and bounty are unchanged. Covers PUR-02/04/05, BID-01/05.
7. **Keeper pricing and drawdown.** Build 1800 s of TWAP coverage; crash one *conversion* pool's spot and
   assert the payout drops immediately; pump an ancestor pool for 30 minutes and assert the payout does not
   rise; then draw repeatedly to assert the token bucket binds and refills continuously with no boundary
   burst. Covers BID-02/03/04/07.
8. **Continuation handover.** v1's steward announces a sunset (short `sunsetDelay`); after it lands, v2's
   first `openRoundIfIdle` adopts the head. Assert v1 can open no further round, v2 opens at
   `priorIndex + 1`, a link-one edge-pool swap after the handover forwards the $DOLL edge to v2's vault, a
   gas-burning successor queues instead of booking locally and does not revert the swap, and `flushForward`
   delivers the queue one hop per call across three versions. Covers CON-01/04/05/06/07/09.
9. **Locked-liquidity negative test.** Attempt `modifyLiquidity` with a negative delta as the Locker, the
   factory, an EOA and from inside a route's unlock; attempt `donate`; attempt to initialize an
   unregistered key and a registered key at a wrong price. All must revert. Covers SUP-05/06/07, REN-01.
10. **Role transfers under real time.** Announce steward and developer transfers; assert
    execution reverts at `+7 days − 1 s`, succeeds at `+7 days` from any caller, that a cancel takes the
    announcement back, and that nothing new becomes callable after execution. Covers ROL-05/06.

## 5. Halmos candidates (H) ★

Each is chosen because its loops are bounded by a small constant or absent, its inputs are pure integers,
and it touches no external contract.

**Status (2026-09-26).** Only candidate 6 is implemented as written (`FenwickCheck.check_rangeAddMatchesClosedForm`,
`check_rangeAddIsAdditive`, `check_noCreditOutsideRange`); candidate 5 is implemented only in part
(`FenwickCheck.check_sleeveShapeNonNegative`: every share is non-negative at `M = 8`; the
`Σ query(j) ≤ sleeve` bound is not checked symbolically). Candidates 1, 2, 3, 4, 8 and 9 have no
Halmos check. The checks that do run (34, 32 in the default run) are listed in
`docs/security/halmos.md`, and also cover `FeeVault` solvency (FEE-11) and the forfeit path (RND-11).

1. **`snipeTaxPpm(elapsed)`**: pre: `elapsed ≥ 0`. Post: `elapsed == 0 ⇒ 990_000`; `elapsed ≥ 3 ⇒ 0`;
   monotone non-increasing on `[0,3)`; never above 990_000. Pure linear integer math, no loop.
2. **Fee gross-up `feeFor(basis, rate, mode)`**: post: the exact-in and exact-out branches yield the same
   fee for the same *gross* parent amount to within 1 wei, and the exact-out branch reverts iff
   `Σrates ≥ 1e6`. Two straight-line branches, symbolic over `basis` and `rate`.
3. **`bondFor(index)`**: post: monotone non-decreasing; `≤ BOND_MAX` for every `uint256` index; equals
   `BOND_BASE << (index/every)` whenever that is `≤ BOND_MAX`; never reverts or wraps. Shift
   saturation is exactly the overflow class a solver finds and a fuzzer misses.
4. **Schedule functions** `durationFor`/`registrationFor`/`lateEntryUntil`/`closingWindowFor`/
   `randomEndWindowFor`: post: the caps hold for all `n`; `randomEndWindowFor(n) ≥ 1`; and the
   load-bearing relation `lateEntryUntil(n) < durationFor(n) − closingWindowFor(n) − RANDOM_END_S` holds
   for every `n` *and* every legal `DURATION_SCALE_DIV`. Pure functions of one small integer.
5. **Ancestor coefficients `(c0, c1, c2)` from `(sleeve, M)`**: post: `Σ_{j=0..M} query(j) ≤ sleeve`,
   `sleeve − Σ ≤ 3·(M+1)` wei, and `w(0) = 2·w(M)`. Bound `M` to a small symbolic range (≤ 8) and let the
   solver choose `sleeve`; this is the under-allocation guarantee FEE-11 leans on.
6. **Fenwick range-add / point-query equivalence**: post: for a bounded symbolic sequence of range-adds
   (≤ 3) over a bounded tree (≤ 8 leaves), every point query equals the naive sum. Loops are `log N` and
   bounded; the signed arithmetic makes this a strong solver target.
7. Unused.
8. **Token bucket `drawableEdge(j)`**: post: for any two draws at symbolic times `t1 < t2` with symbolic
   amounts, the total drawn over any 24 h span never exceeds `cap + refill(24 h)`, and `available` is never
   above `cap`. This is precisely the property the resetting-window version violated at a boundary.
9. **Tie comparator `_beats(a, b)`**: post: irreflexive, antisymmetric and transitive over symbolic
   triples of `(avg, tFirstAttained, poolId)`. Cheap, and catches a total-order bug fuzzing rarely hits.

## 6. Certora candidates (C)

**Ghost state needed.** `ghostLedgerTotal[currency]` mirroring every ledger write; `ghostFeeCharged`
accumulating the hook's per-swap total; `ghostSleeveDeposited[M]` and `ghostSleeveQueried[j]` over the
Fenwick trees; `ghostLockedLiquidity[poolId]` incremented on every Locker deposit; `ghostCanonicalWrites[i]`
counting writes to each canonical index; and a per-method tag marking which functions carry a caller check.

**Rules and invariants.**
- *Solvency* (FEE-11): invariant `ledgerTotal[c] ≤ holdings(c)` for every currency, preserved by every
  `FeeVault` method: `accrue`, `accrueForwarded`, `receiveForward`, `flushForward`, the three claims, the
  four `onlyBidDeployer` hooks and `redeem`.
- *Fee conservation* (FEE-08): rule, after any `accrue`, the sum of ledger deltas equals
  `hopFee + protocolFee` and no untouched ledger changes.
- *Sleeve under-allocation* (SLV-03): invariant `Σ_j ghostSleeveQueried[j] ≤ Σ_M ghostSleeveDeposited[M]`.
- *Append-only history* (RND-09): invariant `ghostCanonicalWrites[i] ≤ 1` for every `i`; rule, only
  `finalize` and the one-shot adoption path increment it.
- *Liquidity ratchet* (SUP-05): invariant `ghostLockedLiquidity[poolId]` monotone non-decreasing across
  every method of every contract.
- *Supply constancy* (SUP-01): invariant `totalSupply` changes only in `burn`, and only by `msg.sender`'s
  own balance delta.
- *Privileged surface* (ROL-01): a parametric rule over all methods asserting that no method writes `head`,
  `canonical`, `hWad`, a fee rate, a split, a schedule parameter or a liquidity position unless it is one
  of the named writers, and that every caller-checked method writes only its declared variables.
- *Keeper leash* (BID-05): rule, `payKeeper` transfers at most the `deployerCredit` created in the same
  transaction by `consumeAncestorClaim`, and `deployerCredit` is zero at the end of every transaction.
- *Router fee neutrality* (ROU-02): rule, for equal swap parameters, the fee computed with router
  `hookData` equals the fee computed without it.
- *Reentrancy* (REN-01): rule, no `RoundManager` or `FeeVault` state-changing method is reachable while
  the `PoolManager` unlock flag is set, except `FeeVault.accrue` called by the hook.
- *Edge fee suppressed during the snipe window* (FEE-06): rule, `protocolPpm != 0` implies
  `snipePpm == 0` on every pool, for every swap.
- *No sweepable donation* (SUP-04): invariant, a `FeeVault.EDGE` balance in excess of
  `ledgerTotal[EDGE]` is reachable only by an external transfer into the vault, and no method moves
  that excess into any ledger or out to any caller.

**Summaries required.** `PoolManager.swap`, `modifyLiquidity`, `initialize`, `unlock`, `sync`, `settle`,
`take`, `mint`, `burn`, `getSlot0` and `protocolFeesAccrued` must be summarized (NONDET, or a small
two-currency ledger model), as must the BN254 pairing precompile `0x08` (NONDET bool), the drand source
(`pin`/`fulfil` → NONDET word under a pinned-round constraint), and `SqrtPriceMath` /
`LiquidityAmounts` (NONDET under range constraints), the curve math belongs in Halmos, not Certora.

## 7. Gaps in the spec

1. **"One protocol fee per economic trade" is defined only for routes crossing an edge pool once.** The
   spec does not say what an edge → … → edge round trip inside one `swapPath` should pay. FEE-01 assumes
   one fee per traversal, i.e. two for a round trip.
2. **Purse split rounding.** CLOSED: there is no split, so there is no remainder wei to
   allocate.
3. **`MIN_BOUNTY_DOLL` has no stated mainnet value** (a placeholder in `script/Deploy.s.sol`, to be
   calibrated from the graduated Pons launch price at deploy time), so BID-06's floor branch cannot be
   asserted against a number.
4. **Board staleness vs board correctness.** CLOSED: there is no board.
5. **`tFirstAttained` semantics.** The spec calls it both "the moment the final average was first reached"
   and "the last score update at or before `tEnd`". These differ when the average plateaus; SCR-12 uses the
   latter (the actual return value) while the tie rule's intent reads like the former.
6. **Reads outside the ring's span.** The coarse ring is sized for `W + RANDOM_END_S + SUBMIT_S`; the spec
   does not state the behaviour when a pool has been inactive longer than that and `T_end − W` precedes the
   oldest entry. SCR-04's "within the rings' span" is an assumption.
7. **`DURATION_SCALE_DIV` vs `closingWindowFor`.** The divisor is said to scale `D`, `R` and late entry and
   explicitly not `RANDOM_END_S`; it is silent on whether `W` is computed from the scaled or the nominal
   `D`. RND-01 assumes the scaled one. `W` is FLAT - `CLOSING_WINDOW_S / DURATION_SCALE_DIV`, 15 min on every round, so the question of which `D` it is computed from no longer arises for `W` itself. The random-end window is
   `max(1, min(RANDOM_END_S, D(n) / 4))`, so a scaled round can no longer draw `T_end` at or before its
   own `tradingStart`, and the modulus in `fulfilEnd` is never zero. On mainnet rounds 1-2 have
   `D(n) = 420 s`, where the floor binds every time; rounds 3-4 hit the floor only when the random
   offset exceeds 60 s; from round 5 onward the floor never binds.
8. **"No fee on non-edge paths", CLOSED.** The rule is now "protocol fee iff the pool's
   parent is canonical index 0" (`isEdge`), computed once at registration rather than derived from a
   currency comparison; every round-one pool of a version is an edge pool for its whole life. A
   continuation stack has no edge pool of its own, since its own link one is a family pool like any
   other; the $DOLL edge is always charged by the ORIGINAL version's link-one hooks.
9. **`rank` before `finalize`.** CLOSED: there is no `rank`. A generation that has not been
   crowned has no `canonical(j)` and `deployAncestor` reverts `UnknownGeneration`.
10. **Developer ledger asymmetry.** The single developer pot is disclosed as claimable by whoever holds the
    role at claim time, while the creator ledger sweeps on transfer. The spec does not say whether the
    asymmetry is intended; ROL-07 asserts only the creator behaviour.
11. **Beacon round reuse across rounds.** RAN-04 assumes a beacon round pinned by one round cannot settle
    another. The spec says pinning is once *per round* but not that two rounds cannot pin the same beacon
    round, which is reachable when two nominal ends fall in the same beacon period on a scaled schedule.
12. **`averageOver` with `t1 == t0`.** Reachable if `W` scales to zero on an extreme testnet divisor; the
    spec names no behaviour (revert, zero, or spot).
13. Unused.
14. **`hopFeePpm` at its ceiling.** FEE-06's unreachability argument depends on `hopFeePpm` being below
    `MAX_HOP_FEE_PPM`. The spec calls a summed rate at or above 100% unreachable at the deploy constants
    but does not forbid deploying at the ceiling.

    **The mechanism, not just the arithmetic:** A round-one pool is both an edge pool
    (1%) and snipe-taxed (99% for its first 3 s) at once, and the sum would exceed 100% and break
    exact-input accounting, unlike the prior design, where the genesis pool was registered with no
    snipe window at all (`GenesisHasNoSnipeWindow`, now deleted, along with the `nominalEnd == 0` freeze
    exemption: every registered pool, edge pools included, has a real `tradingStart`/`nominalEnd` and
    freezes its rings). The fix is time-based: `protocolPpm = (isEdge && snipePpm == 0) ? PROTOCOL_FEE_PPM
    : 0`, so the edge fee is suppressed for exactly the pool's own 3-second snipe window, and the two
    rates are still never summed on one swap. The real worst case is unchanged in shape:
    `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000`. The measured ceiling case is a
    candidate pool in the first second of its snipe window at `hopFeePpm = MAX_HOP_FEE_PPM`:
    `990_000 + 10_000 = 1_000_000` ppm, which reverts `SnipeExactOutputTooLarge` rather than wrapping
    (`PROPERTY_RESULTS.md` gap 14).
