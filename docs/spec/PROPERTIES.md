# Dollhouse — formal property list

## 1. Scope and method

Every property below is derived **only** from the written specification (`docs/spec/PROTOCOL_SPEC.md`,
`docs/MECHANISM_v3.md`, `docs/DEPLOY_CONSTANTS.md`, `docs/attack-log.md`, the simulation reports and the
public documentation site); no contract, test or script source was consulted, so a property the
implementation violates is a finding, not a documentation error to be reconciled away.
Each row carries an ID, a one-sentence quantified statement, a class (*safety* — a bad thing never
happens; *conservation* — a sum is exact; *purity* — a value depends only on the named inputs;
*access* — only the named caller may act; *liveness* — a good thing stays reachable; *arithmetic* — a
closed form holds to a stated tolerance), and one or more verification tiers: `U` unit, `F` stateless
fuzz, `I` stateful invariant (handler-driven), `K` fork test against the real Uniswap v4 `PoolManager`
on chain 46630, `H` Halmos symbolic, `C` Certora rule.
`★` marks the highest-value properties: a violation of any of them is a critical, unrecoverable loss of
funds, supply or history, and each is cheap to state and expensive to discover by testing alone.

## 2. Components and actors

**Components.** `FamilyToken` (fixed-supply ERC-20 clone, burnable by the holder only) · `FamilyFactory`
(genesis and candidate launch, curve derivation, wiring) · `Locker` (sole owner of every liquidity
position; curve placement and bid deposit only, no exit) · `FamilyHook` (singleton: pool registration,
fee collection, score accumulator, score checkpoint rings, TWAP rings, attribution) · `RoundManager`
(head machine, round schedule, end settlement, submission, finalization, purse deployment, steward role,
sunset and continuation) · `FeeVault` (ledgers, accrual, claims, forwarding queue, drawdown bucket) ·
`BidDeployer` (keeper pricing, size caps, bid placement, purse deployment) · `FamilyRouter` (multi-hop
routing and attribution, no privilege) · `DevVesting` (+ `DevVestingDeployer`) (3% genesis allocation,
cliff then linear) · `IRandomnessSource` / `DrandSource` (drand `evmnet` BN254 beacon verifier) ·
`FamilyLens` (views only) · libraries `CurveMath`, `StandardCurve`, `FenwickRangeAdd`.

**Actors.** *Trader* (swaps directly or through the router) · *Creator* (launches genesis once, registers
candidates, claims the creator share) · *Keeper* (permissionless caller of `deployAncestor`,
`deployGenesisBid`, `deployHopPot`) · *Steward* (announce/cancel sunset; transfer the steward role) ·
*Developer* (claim the 20% ETH ledger; transfer the developer role; `DevVesting` beneficiary) ·
*Relayer* (calls `requestEnd`, `fulfilEnd`, `finalizeDeterministic`, `submitScore`, `finalize`,
`flushForward`) · plus the *successor stack* (a later version's `RoundManager`/`FeeVault`/router) as a
semi-trusted, gas-bounded external party.

## 3. Properties

### 3.1 Supply and liquidity

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ SUP-01 | For every family token, `totalSupply()` equals `1e9·1e18` immediately after `initialize` and is non-increasing forever after, decreasing only by the exact amount a holder passes to `burn` from their own balance. | safety | U,F,I,C | Falsified by any mint path, any burn of another address's balance, or a launch-time supply differing from the constant. |
| ★ SUP-02 | For a candidate token, tokens placed in Locker positions plus dust burned at launch equal `1e9·1e18` exactly, with `devAmount == 0` and `devRecipient == address(0)`. | conservation | U,K | Exact, no tolerance: the dust burn absorbs all rounding. |
| SUP-03 | For the genesis token, tokens placed on the curve equal `1e9·1e18 · (BPS − DEV_ALLOCATION_BPS)/BPS` less burned dust, and exactly `devAllocation()` is held by the `DevVesting` contract when `createGenesis` returns. | conservation | U,K | State against `devAllocation()`, not the literal 3%. |
| SUP-04 | After launch, no address other than the `PoolManager`, the genesis `DevVesting` contract and addresses that acquired tokens by swapping ever holds a positive balance of a family token. | safety | I | Falsified by any residual factory/locker/vault balance that can be moved. |
| SUP-05 | No call by any caller, in any state, reduces the liquidity of any Locker-owned position; `beforeRemoveLiquidity` reverts unconditionally, including when the caller is the Locker itself. | safety | U,I,K | The ratchet: per-pool locked liquidity is monotone non-decreasing over any handler sequence. |
| SUP-06 | `beforeAddLiquidity` reverts for every sender except the Locker, and `beforeDonate` reverts for every sender. | access | U,K | Donation must be impossible, or the score's "swap deltas only" claim is void. |
| SUP-07 | `beforeInitialize` reverts unless the exact `PoolKey` was pre-registered by the factory, and reverts if the initial sqrt price differs by one wei from the registered `initSqrtPriceX96`. | access | U,K | Pre-initialization poisoning (attack-log #8). |
| SUP-08 | The genesis curve's FDV bands (and therefore every tick) are denominated in the full `1e9·1e18` supply while the placed quantities are denominated in `genesisTokensForSale()`; changing `DEV_ALLOCATION_BPS` moves no tick. | purity | U,F | |
| SUP-09 | Two different callers of `createGenesis` obtain byte-identical curve ranges and `initSqrtPriceX96`; only the recorded creator differs. | purity | U,H | Caller-independence (C2). |
| SUP-10 | `createGenesis` succeeds at most once per deployment and never on a continuation deployment. | safety | U | |

### 3.2 Fees

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ FEE-01 | A route of any length `L` that traverses the ETH edge once pays exactly one protocol fee of `PROTOCOL_FEE_PPM = 10_000` ppm on the ETH-side amount of the genesis leg, and zero protocol fee on the other `L−1` legs, in both directions and for every `L ≥ 1`. | conservation | U,F,K,C | "Economic trade" ≡ one traversal of the ETH edge. Falsified by any depth- or leg-count-dependent protocol fee total. |
| FEE-02 | Every family pool charges `hopFeePpm` (deploy 750 ppm) on the parent side of every swap, genesis leg included, so a full-line route to index `L` pays one 1% edge fee plus exactly `L` hop fees. | conservation | U,K | Assert per leg: each hop fee is a fraction of that leg's own parent amount, so the total is not a closed form in ETH. |
| FEE-03 | `hopFeePpm ≤ MAX_HOP_FEE_PPM = 10_000` is enforced at construction, and no function anywhere changes any fee rate or split after deployment. | safety | U | |
| FEE-04 | The snipe tax on a candidate pool at time `t` is `SNIPE_START_PPM + (SNIPE_END_PPM − SNIPE_START_PPM)·(t − tradingStart)/SNIPE_S` for `t ∈ [tradingStart, tradingStart+3 s)` and exactly 0 for `t ≥ tradingStart + 3 s`; it is 0 at all times on the genesis pool. | arithmetic | U,F,H,K | 990_000 → 10_000 ppm linearly over 3 s. A late entrant's `tradingStart` is its own registration timestamp. |
| FEE-05 | For a fixed parent-side gross amount, the total fee is identical in exact-input and exact-output mode and on both pool sides: `fee = gross · rate`, where the hook grosses up `basis = poolCost/(1−rate)` whenever it is handed the pool's side. | arithmetic | U,F,H,K | Tolerance ≤ 1 wei of integer division. Falsified by the `rate/(1+rate)` shape (F9). |
| FEE-06 | A parent-paying exact-output swap whose summed rates reach or exceed 100% reverts rather than producing an unbounded or wrapped gross-up. | safety | U,H | Reachable only in the first instant of the snipe window with `hopFeePpm` at its ceiling. |
| FEE-07 | The increase of the v4 protocol fee observed across a swap is subtracted from the scored amount, so a nonzero v4 protocol-fee controller changes no candidate's score. | safety | U,K | The controller is unset on 46630; set one in the fork harness if possible. |
| ★ FEE-08 | For every swap, `Δdev + Δcreator + ΔcoCredit + Δsleeve + Δreinforce == protocolFee` and `Δreinforcement[parent] == hopFee + snipeFee`, with no other ledger changed and no wei created or destroyed. | conservation | U,F,I,C | Exact: floor division with the last bucket taking the remainder. This is the fee-conservation property. |
| FEE-09 | `DEV_BPS + creatorBps ≤ BPS` and `ancestorBps + reinforceBps == BPS` are checked at construction; at the deploy constants the split is exactly dev 20% / creator 40% / sleeve 20% / reinforcement 20% of each protocol fee. | conservation | U | The test harness runs a different split (DIFF 5); assert the deploy numbers explicitly. |
| FEE-10 | Fees only ever move into `devBalance`, `creatorBalance[token]`, `creatorAccrued[addr]`, the three Fenwick coefficient trees, `reinforcementEth[j]`, `reinforcementBalance[parent]`, `genesisBidEarmark` and `pendingForward[attribution]`; no other destination exists. | safety | I,C | An exhaustive destination list; falsified by any new sink. |
| ★ FEE-11 | For every currency `c` at every instant, `ledgerTotal[c] ≤ holdings(c)`, where `holdings` counts unredeemed ERC-6909 claims plus the real balance and `ledgerTotal` includes `pendingForward`. | safety | I,C | Vault solvency. Must hold across forwarding, flushing, claiming and keeper draws. |
| FEE-12 | An unattributed swap credits `creator = 0` and `M = 0`, so its whole flywheel share lands on genesis; the developer's 20% is paid on every protocol fee, attributed or not. | conservation | U,F | |
| FEE-13 | On a partially filled exact-input swap the fee is charged on the full `amountSpecified`; this is the only case where fee basis and executed notional differ. | arithmetic | U,K | Disclosed (L1); pinned so a later change is visible. |

### 3.3 Ancestor sleeve

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| SLV-01 | For `M ≥ 1` and every ancestor `j ∈ [0, M]`, the credited share equals `sleeve · w(j/M) / Z(M)` with `w(r) = 2 − 5r + 4r²` and `Z(M) = (M+1)(5M+4)/(6M)`, within the floor error of the three WAD-scaled coefficients. | arithmetic | U,F,H | Tolerance: strictly under-allocating, a few wei per ancestor per fee. |
| SLV-02 | Every ancestor `0..M` of the attributed token receives a share whenever its floored term is nonzero, and no index outside `[0, M]` is ever credited. | safety | U,F,C | Falsified by crediting non-ancestors (attack-log #3). |
| ★ SLV-03 | The sum of point queries over `[0, M]` is ≤ the sleeve amount for every sleeve and every `M`, never greater; the residue is permanently unclaimable. | conservation | F,I,H,C | Under-allocation is what makes FEE-11 hold by construction; one over-allocation breaks solvency. |
| SLV-04 | For any sequence of range-adds over `[0, M_k]` and any query index `i`, the Fenwick point query equals the naive summation over a brute-force ledger, exactly. | arithmetic | F,I,H | Signed trees: `c1 < 0`, so intermediate prefix sums legitimately go negative. |
| SLV-05 | `w(0) = 2·w(M)` for every `M ≥ 1`, `w` attains its minimum at `r = 5/8`, and genesis's share decays as `12/(5M)`. | arithmetic | U,H | Shape property; also the "no fixed genesis floor" claim. |
| SLV-06 | `M == 0` credits genesis alone with the whole sleeve, with no division by zero. | safety | U,H | |
| SLV-07 | A range-add or point query with index > `MAX_INDEX = 4095` reverts, and registration refuses to create such an index first. | safety | U | Two independent caps (structural 4095, policy `MAX_INDEX`). |

### 3.4 Score and the closing window

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| SCR-01 | The accumulator update is exactly `acc += R·(now − tLast); tLast = now; R += (−parentDelta_pool)`, where `parentDelta_pool` excludes every hook-charged fee and the v4 protocol fee, in all four specified/unspecified × exact-in/exact-out orientations. | arithmetic | U,F,K | Falsified by any double subtraction of the fee (C1). |
| SCR-02 | `R` increases on a net buy and strictly decreases on a net sell, and no transfer, donation, balance change or approval changes `acc` or `R`. | safety | U,I | SUP-06 (donations disabled) is a precondition. |
| SCR-03 | A buy inside the snipe window increases the score by the post-fee pool delta and never makes the score negative; the same buy later in the window scores strictly more. | safety | U,F,K | At 99% + 1% + hop the delta stays positive. |
| ★ SCR-04 | For every `t0 < t1` and every pool, `averageOver(id, t0, t1)` equals `(acc(t1) − acc(t0))/(t1 − t0)` computed from the exact swap history, for any pattern of swaps and gaps within the rings' span. | arithmetic | F,I,H | Exactness is the point of storing pre-swap state per slot; the only permitted inexactness is a second swap inside an edge slot, which uses the pre-swap state and so never counts flow later than the edge. |
| SCR-05 | A checkpoint slot is written at most once, by the first swap in that slot, and a slot with no swap reconstructs exactly because `R` is constant between swaps. | arithmetic | U,F,I | |
| SCR-06 | The fast ring spans exactly `36 × 5 s = 180 s = RANDOM_END_S`, and the coarse ring's 64 slots of `scoreSlotFor(n) = ceil((W + RANDOM_END_S + SUBMIT_S)/63)` span at least `W + RANDOM_END_S + SUBMIT_S`, for every round number `n`. | arithmetic | U,H | Falsified if any reachable `T_end − W` falls outside the coarse ring. |
| SCR-07 | Two candidates with identical net parent absorbed throughout `[T_end − W, T_end]` receive identical scores regardless of when their pools opened, provided both opened at or before `T_end − W`. | purity | U,K | Late-entry fairness. |
| SCR-08 | A candidate whose pool opened after `T_end − W` is scored from its own `tradingStart` rather than reverting. | liveness | U | Only reachable on a scaled testnet schedule; stated so it is not silently removed. |
| SCR-09 | Parent absorbed and then sold back before `T_end − W` contributes nothing to the score: the window measures a level, not a total. | safety | U,F,K | |
| SCR-10 | No swap with `block.timestamp > T_end` changes any value `submitScore` reads for that round, while such swaps still execute, still pay fees and still update the purse accumulator. | safety | U,K | The accumulator is never frozen; only the read is bounded. |
| SCR-11 | `submitScore` is permissionless, idempotent per candidate, and reverts outside `[tradingEnd, submitEnd)` or before the end is settled. | safety | U | |
| SCR-12 | The tie rule orders candidates by higher average, then earlier `tFirstAttained`, then lower `uint256(poolId)`, and is a total order: two distinct candidates can never both beat each other. | safety | U,F,H | `tFirstAttained` is a block timestamp, never a hash. |

### 3.5 Round lifecycle

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| RND-01 | `durationFor(n) = min(15 min · 2^floor((n−1)/2), 12 h)/DURATION_SCALE_DIV`, `registrationFor(n) = clamp(D(n)/5, 3 min, 1 h)`, `lateEntryUntil(n) = D(n)/3` iff `D(n) ≥ 1 h` else 0, `closingWindowFor(n) = CLOSING_WINDOW_S/DURATION_SCALE_DIV` (a flat 15 min on every round), `randomEndWindowFor(n) = max(1, min(180 s, D(n)/4))` — each a pure function of `n` alone. | purity | U,F,H | No caller, steward or timestamp may perturb any of them. Reproduce the published table row by row. |
| RND-02 | For every `n`, `lateEntryUntil(n) < D(n) − closingWindowFor(n) − RANDOM_END_S`, so no candidate is ever scored over a span beginning before its own pool opened. | arithmetic | U,H | Must hold at every legal scale divisor. |
| RND-03 | The only reachable transitions are Unlaunched→Idle, Idle→Registration, Registration→Trading (clock), Trading→EndPending (clock), EndPending→Submission (via `fulfilEnd` or `finalizeDeterministic`), Submission→Finalizable (clock), Finalizable→Finalized+Idle, plus the sunset announce/cancel pair; no other transition exists and none is privileged. | safety | I,C | A state-machine invariant over a handler calling every external function in every order. |
| RND-04 | `requestEnd()` is callable only at or after `T`, at most once per round, and pins a beacon round whose scheduled production time is strictly in the future at the moment of pinning. | safety | U,K | The unpredictability of `T_end` rests entirely on this. |
| RND-05 | On fulfilment, `tradingEnd = T − (word mod randomEndWindowFor(n))` so `T_end ∈ (T − 180 s, T]` at mainnet constants, and `submitEnd = block.timestamp of fulfilment + 300 s`. | arithmetic | U,K | The submission window starts at settlement, not at `T`. |
| RND-06 | If no verifiable beacon is relayed within `END_TIMEOUT = 30 min` of `T`, anyone may settle `tradingEnd = T` with a loud event, without anyone having called `requestEnd` first; the end can be settled at most once by either path. | liveness | U,K | A round never hangs on the beacon. |
| RND-07 | `finalize()` reverts before `submitEnd` and before the end is settled; thereafter it is permissionless, deterministic and idempotent — a second call is a no-op that cannot overwrite the head. | safety | U,I,K | |
| RND-08 | Round `n+1` cannot open until round `n` is finalized: `openRoundIfIdle` reverts otherwise. | safety | U,I | Also the liveness hazard: nothing advances a round automatically. |
| ★ RND-09 | `canonical[i]` is write-once for every `i`, at most one winner exists per index, the reverse index (`indexOf`, `parentOf`, `isCanonical`) is consistent with it at all times, and the winner branch of `finalize()` is the only writer besides one-shot continuation adoption. | safety | I,C | Append-only history. A violation is unrecoverable. |
| RND-10 | A round crowns a winner iff `hasBest && bestAvg ≥ hUsed`, where `hUsed` was snapshotted when the round opened and cannot move afterwards. | safety | U | |
| RND-11 | On a crowned round the winner's stored bond is refunded to its creator (push, with a `pendingRefund` pull fallback that cannot brick finalization) and every other candidate's stored bond is forfeited to `FeeVault.genesisBidEarmark`; forfeited total `= candidateCount · bondWei − winnerBond`. | conservation | U,F,K | No third destination for a bond exists. |
| RND-12 | `bondFor(i) = min(BOND_BASE_WEI << (i / BOND_DOUBLING_EVERY), BOND_MAX_WEI)` saturates rather than overflowing for every `i`, and a candidate is refunded/forfeited at the amount it actually posted, never a re-priced one. | arithmetic | U,F,H | `BOND_DOUBLING_EVERY == 0` means a flat `BOND_MAX_WEI`; doubling every 4 links, capped at 64× base. |
| RND-13 | On a failed round `hWad ← max(hWad·9/10, H_MIN_FRAC_WAD)` with `H_MIN_FRAC_WAD = 0.25·H_FRAC_WAD`; on a crowned round `hWad ← H_FRAC_WAD` exactly, so decay compounds only across consecutive failures. | arithmetic | U,F,I | Falsified by any path where `H` persists across a win. |
| RND-14 | `registerCandidate` reverts unless `msg.value` equals the round's pinned bond exactly, the registration (or late-entry) window is open, and the next index is within both depth caps. | access | U,F | Checked twice by design (factory and round manager); both checks must agree. |
| RND-15 | Registration is refused once the next index would exceed `FenwickRangeAdd.MAX_INDEX = 4095` or the immutable policy `MAX_INDEX`, at the door rather than by bricking a later swap. | safety | U | |
| RND-16 | Trading on any pool — canonical, candidate, winner or loser — is never gated after that pool's own `tradingStart`, in any round phase, before or after a sunset. | liveness | I,K | Losers' pools live forever and keep paying hop fees. |

### 3.6 Pairing rights and the trunk

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| PAR-01 | The winner's pairing rights are fixed at `finalize()`; no later call by any actor changes `head` or `headIndex` except a subsequent `finalize()` of a later round. | safety | I,C | No steal window exists. |
| PAR-02 | The canonical sequence is strictly increasing in index and never reordered, re-parented or truncated; `parentOf(i) == canonical(i−1)` for every `i ≥ 1` in a version's own range. | safety | I | |
| PAR-03 | Every candidate pool of a round is priced in the round's recorded `parentToken`/`parentIndex`, immutable from the moment the round opens, so a candidate's route survives the round unchanged. | safety | U,K | Falsified by any route resolving the *current* head (audit 8). |
| PAR-04 | The head creator's 50% season cut applies exactly while the candidate's round is in `Trading`, and 0% thereafter; a losing candidate's creator keeps everything credited during the round. | conservation | U,K | Two regimes, no clawback. |

### 3.7 The purse

Review 3 (2026-09-13) made the purse uncontested: a generation's whole share is locked under the
trunk coin that won its round. PUR-01, PUR-03, PUR-06 and PUR-07 are RETIRED with the ranking they
described; PUR-02, PUR-04 and PUR-05 are restated for the new rule.

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| PUR-01 | RETIRED (review 3). Was: `rank(candidateId)` reads trailing support from the hook and accepts no caller-supplied number. There is no `rank`. | - | - | - |
| PUR-02 | The destination of `deployAncestor(j, amount)` is `canonical(j)` and nothing else, for every amount and whatever support any sibling has built since the round; a losing sibling never receives purse liquidity. | safety | U,F,K | The destination is not an argument, so there is nothing for a keeper to choose. |
| PUR-03 | RETIRED (review 3). Was: a deployment reverts unless `{idA, idB}` is exactly the generation's fresh top-2 board. There is no board and no pair. | - | - | - |
| PUR-04 | Exactly `amount` leaves the keeper, at least `amount` is locked (the difference is the generation's own parent-denominated hop pot topping the bid up), nothing is stranded in the deployer, and the vault stays solvent. | conservation | U,F,K | No rounding split to allocate any more. |
| PUR-05 | The daily drawdown bucket and the bounty rule are unchanged by the purse rule: the bucket falls by exactly the payout, and the bounty is `max(1%, MIN_BOUNTY_WEI)` under its `MAX_BOUNTY_SHARE_BPS` ceiling. | conservation | U,F,K | The removal must not have moved anything else on the keeper path. |
| PUR-06 | RETIRED (review 3). Was: the purse window equals the crowning round's closing window. Nothing is measured for the purse at all. | - | - | - |
| PUR-07 | RETIRED (review 3). Was: trailing support is never frozen, so a dumped winner loses its purse. `FamilyHook.trailingAverage` still runs, but no payout depends on it. | - | - | - |

### 3.8 Bid deployer and reinforcement

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| BID-01 | Every deposit `BidDeployer` makes lands in a Locker position that is permanently locked, single-sided on the parent side of spot, `BID_WIDTH_SPACINGS = 10` spacings wide, with `tickLower < tickUpper` or a revert; a range straddling spot reverts. | safety | U,F,K | No other deposit destination exists. |
| BID-02 | Each conversion link is priced at the value-minimum of spot, the 1800 s TWAP and the 7-day TWAP, so no price movement can *raise* what a sleeve pays relative to the averages; only a crash lowers it. | safety | U,F,K | Falsified if a 30-minute pump of a thin ancestor pool increases the payout for the same parcel. |
| BID-03 | A pool with fast TWAP coverage below 1800 s, fewer than 2 observations, or a zero TWAP cannot enter a conversion (revert); insufficient *slow* coverage (< 1 day) is not a revert but must be reported in the call's output and event. | safety | U,K | A zero-observation pool must never be a silent pass. |
| BID-04 | The ±300 bps band guard is applied to the target pool `j` only, and to every call that places a bid under `j`. | safety | U,K | |
| ★ BID-05 | ETH leaves `FeeVault` on the keeper path only as `payKeeper(msg.sender, payout)` against a `deployerCredit` created in the same call by `consumeAncestorClaim(j, payout)` out of generation `j`'s own ledgers, so no call moves more than generation `j`'s own money and no path transfers value to an EOA except a bounty bounded by BID-06. | safety | I,C | The leash. Also: `FeeVault` never swaps and never places liquidity. |
| BID-06 | `bounty = min(max(ethValue·100/10000, MIN_BOUNTY_WEI), ethValue·2000/8000)`, so the bounty is never more than 20% of `payout = ethValue + bounty`, and is 1% of `ethValue` wherever neither bound binds. | arithmetic | U,F,H | `deployHopPot`'s bounty has the same 1% shape but is paid in the parent token from the same pot. |
| BID-07 | A draw of `payout` from generation `j` succeeds only if `payout ≤ drawableEth(j)`, a continuously refilling token bucket with cap `10% · claimableEth(j)` and refill `10% · claimableEth(j) · dt / 24 h`; there is no instant at which two draws together exceed the cap. | safety | F,I,H | Falsified by any window-boundary burst (audit 6 measured ≈19%). A bucket whose 10% floors to zero is allowed in full so dust is never stranded. |
| BID-08 | `deployed ≤ bidCap(j) = 2% · max(active-tick-bucket parent reserve, first-curve-range parent capacity)`, and a request above it reverts rather than being silently clamped upward. | safety | U,K | The cold-start fallback must still produce a nonzero, capped size. |
| BID-09 | A parent-denominated pot larger than the remaining room is drawn *partially* (`min(pot, cap − amount)`), never all-or-nothing, on every pot: the ETH sleeve, the hop pot and the forfeited-bond earmark. | liveness | U,K | A pot larger than the cap must not brick a generation forever. |
| BID-10 | `maxParentForDeploy(j)` returns a quote `deployAncestor` accepts, in all three bounty regimes (proportional, flat floor, below-floor 20% cap) and at both knees. | liveness | F,K | A view that under-quotes strands funds in practice. |
| BID-11 | `deployHopPot(j)` deploys generation `j`'s parent-denominated pot with no ETH entitlement involved at all, for any `j` including the current head. | liveness | U,K | Terminal-generation pot (audit 3). |
| BID-12 | `depositExternalBid` accepts only this version's links, requires exactly matching `msg.value`, creates no ledger entry and pays no bounty. | access | U,K | |
| BID-13 | When generation `j`'s pool belongs to an earlier version, the bid is placed through *that* version's `BidDeployer`/`Locker`, and the TWAP read and the Locker used always belong to the same version. | safety | U,K | Falsified by reading one version's price while placing through another's Locker. |
| BID-14 | Every keeper entrypoint is `nonReentrant`, and every wei or token it draws leaves the vault within the same call — no keeper call leaves a residual credit. | safety | I,C | |

### 3.9 Continuation and handover

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| CON-01 | A continuation adopts the prior head at most once, only in its first `openRoundIfIdle`, and only if the prior's sunset is effective, the prior names this contract as successor, the prior is idle, and the prior is itself a root or already adopted. | safety | U,K,C | There is no instant at which two versions can crown the same canonical index. |
| CON-02 | Before adoption, every canonical read of a continuation delegates to the prior registry, and the continuation can open no round at all. | safety | U | |
| CON-03 | Delegated canonical reads resolve through at most `MAX_CONTINUATION_HOPS = 8` registries and revert rather than looping unboundedly. | safety | U,F | |
| CON-04 | While a version is sunset, a protocol fee on its ETH edge is either forwarded in-swap to the successor's vault or queued in `pendingForward[attribution]`; it is never booked to a local ledger under any gas condition. | safety | U,F,K | Falsified if the caller's gas can decide which version receives a fee (audit 4). |
| CON-05 | `flushForward(attribution, max)` moves at most `max` from `pendingForward` to the immediate successor's vault, decrementing `pendingForward` and `ledgerTotal` by exactly the amount delivered, with no recursion and no value created or destroyed. | conservation | U,F,K | A chain of `k` versions completes in exactly `k` flushes. |
| CON-06 | The in-swap forwarding hop is given `min(FORWARD_GAS, gasleft() − BOOK_GAS_RESERVE)` and is skipped entirely when that is zero, so at least `BOOK_GAS_RESERVE` always remains to queue the fee and finish the swap, for every successor behaviour including one that burns all gas it is given. | safety | U,K | Falsified if any successor behaviour can make a genesis-pool swap revert or run out of gas. |
| CON-07 | A forwarding attempt that fails at the *full* budget arms a one-shot negative cache and is never retried; one that failed only because the caller's gas was thin does not arm it. | safety | U,K | A hostile successor costs at most one swap's wasted gas, forever. |
| CON-08 | `accrueForwarded` and `receiveForward` accept only a vault of a prior version in this stack's registry chain; `forwardProtocolFee` accepts only `address(this)`. | access | U | |
| CON-09 | No sunset, handover or adoption moves, unlocks or reclaims any liquidity or any wei already credited in the old vault; balances accrued before the handover stay claimable there forever. | safety | U,K,I | The old vault cannot be drained by the successor. |
| CON-10 | Successor-router resolution is a bounded sequence of 30 000-gas staticcalls whose results are validated as clean 32-byte addresses (`word >> 160 == 0`), with both the positive and the negative resolution cached write-once. | safety | U,K | A dirty word or a reverting successor must cost gas, never a revert. |
| CON-11 | Post-sunset, a pool's parent-side hop fee and snipe tax stay with the charging version and never forward. | safety | U | Only the ETH edge follows the live version. |

### 3.10 Roles and admin surface

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ★ ROL-01 | The complete set of caller-gated state-changing functions is: steward `announceSunset`/`cancelSunset`/`announce`+`cancelStewardTransfer`; developer `claimDev`/`announce`+`cancelDeveloperTransfer`; beneficiary `announce`+`cancelBeneficiaryTransfer`; creator `claimCreator`/`transferCreatorRecipient`; plus contract-to-contract authenticity checks between immutable addresses. No other privileged function exists in any contract. | access | I,C | Enumerate the ABI and assert every other state-changing function is permissionless. Falsified by any owner, pause, setter, proxy admin or rescue path. |
| ROL-02 | `announceSunset` succeeds at most once per deployment, requires code at the successor, requires the deployment to be a root or adopted, and takes effect exactly `sunsetDelay ≥ MIN_SUNSET_DELAY = 1 h` later. | access | U | |
| ROL-03 | `cancelSunset` succeeds at most once in a deployment's life and only strictly before `sunsetAt`; a second announcement is irrevocable. | access | U | |
| ROL-04 | A sunset stops only `openRoundIfIdle`; a round already open still registers, trades, is scored, finalizes and crowns a head. | liveness | U,K | |
| ROL-05 | For each of the three roles, `announce*Transfer(to)` is current-holder-only, refuses `to == address(0)` and refuses to overwrite a pending transfer; `execute*Transfer()` is permissionless and reverts before `announcement + 7 days`; `cancel*Transfer()` is current-holder-only and repeatable. | access | U,F,H | `RoundManager.ROLE_TRANSFER_DELAY == FeeVault.ROLE_TRANSFER_DELAY == DevVesting.ROLE_TRANSFER_DELAY == 7 days`. |
| ROL-06 | Executing a role transfer grants exactly the surface the outgoing holder had: no new function becomes callable, no delay shortens, and no round, pool or balance is touched. | safety | U,C | |
| ROL-07 | `transferCreatorRecipient` sweeps the current `creatorBalance[token]` into the *old* recipient's `creatorAccrued` ledger, zeroes it, and refuses `to == address(0)`; a swept accrual survives any number of later transfers. | conservation | U,F | Falsified by handing accrued fees to the new recipient. |
| ROL-08 | `steward == address(0)` is legal and makes sunset — and therefore continuation — permanently impossible. | safety | U | |

### 3.11 Developer vesting

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| VST-01 | `total() == token.balanceOf(this) + released` at all times, and equals `devAllocation()` from the end of `createGenesis` until the first release. | conservation | U,F,H | The allocation is never stored as a number. |
| VST-02 | `vested(t) = 0` for `t < start + cliff`; `= total()·(t − start)/duration` for `start + cliff ≤ t < start + duration`; `= total()` for `t ≥ start + duration` — so `vested(start + cliff) = total()·cliff/duration ≈ 8.2%` at mainnet constants, not zero. | arithmetic | U,F,H | The cliff does not unlock zero. |
| VST-03 | `released(t)` is monotone non-decreasing in `t`, never exceeds `total()`, and equals `total()` exactly at and after `start + duration` once a release is called. | safety | F,H,C | |
| VST-04 | `release()` is permissionless and always pays `vested(now) − released` to the *current* beneficiary; a second call with nothing new reverts. | liveness | U,F | |
| VST-05 | No function revokes, claws back, pauses or accelerates the schedule, or changes `start`, `cliff` or `duration`; the only mutable state is `released` and the beneficiary triple. | access | U,C | Structural, not by convention. |
| VST-06 | `start` equals the `block.timestamp` of `createGenesis` and is immutable. | purity | U | |

### 3.12 Randomness

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| RAN-01 | `fulfil(id, proof)` accepts a 64-byte BN254 G1 signature iff the pairing check against the published `evmnet` G2 group public key succeeds over the message `keccak256(uint64 round, big-endian)` mapped to the curve by RFC 9380 `expand_msg_xmd`/SvdW with the documented domain tag. | safety | U,K | The keccak256 (not sha256) digest is an empirically established, load-bearing fact: assert it against two real beacons. |
| RAN-02 | A signature for any round other than the pinned one, a tampered signature, or a point not on the curve is rejected. | safety | U,F | |
| RAN-03 | `pin()` always records a beacon round whose scheduled production time is strictly after `block.timestamp`, for every call time. | safety | U,F,H | If this fails, `T_end` becomes knowable before `T`. |
| RAN-04 | A beacon round value already consumed by one round cannot settle a second round, and a given round's end cannot be settled twice by any combination of `fulfilEnd` and `finalizeDeterministic`. | safety | U,I | |
| RAN-05 | The randomness source address is an immutable constructor parameter, no function switches it, and the mock source is distinguishable on-chain by its own flag. | access | U | |
| RAN-06 | Withholding the beacon produces exactly one outcome, `T_end = T`, and never a hung round. | liveness | U,K | The trust statement: no party can bias a round by withholding. |

### 3.13 Router

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| ROU-01 | Every exact-in entrypoint reverts unless the final output is ≥ `minOut`, checked after the unlock returns, and a round-trip path reports the last leg's output rather than a netted zero. | safety | U,F,K | |
| ROU-02 | The fees paid by a routed swap equal those paid by an equivalent direct `PoolManager` swap, wei for wei; `hookData` affects only which ledger is credited, never any fee amount. | safety | U,F,K,C | The router is never fee-privileged. |
| ROU-03 | `hookData` attribution is trusted only when the sender is the canonical router or a validly resolved successor router and the data is at least 32 bytes; any other sender's `hookData` credits nothing. | access | U,K | A copycat router is credited nothing. |
| ROU-04 | `swapPath` enforces per-leg adjacency (`to == from+1`, `from == to+1`, or the ETH↔0 genesis leg) and reverts otherwise; `maxHops` bounds the whole route including a candidate leg. | safety | U,F | |
| ROU-05 | `msg.value == amountIn` on an ETH-first path and `msg.value == 0` otherwise; the router has no `receive()`, so no ETH can be parked in it and later swept. | safety | U,F | |
| ROU-06 | Every positive intermediate residual is paid to `to`, every negative one reverts with a named per-leg error, and unused ETH on a partially filled first leg is refunded to `msg.sender`. | conservation | U,K | A route never leaves value in the router. |
| ROU-07 | The router (and the Locker) calls `sync(native)` immediately before every native settle, so a foreign `sync(ERC20)` earlier in the same unlock cannot misdirect the settlement. | safety | U,K | |
| ROU-08 | `buyCandidate`/`sellCandidate` are refused only while the candidate's round is in `Registration` or `Idle`, and work forever afterwards, win or lose. | liveness | U,K | |

### 3.14 Reentrancy and ordering

| ID | Statement | Class | Tiers | Notes |
|---|---|---|---|---|
| REN-01 | No call originating inside a `PoolManager` unlock reaches a state-changing function of `RoundManager` or `FeeVault` except the hook's own accrual/score path; in particular no swap can re-entrantly call `finalize`, `submitScore`, a claim or a keeper entrypoint. | safety | I,C | The strongest ordering property: a handler must attempt every such call from inside a swap and observe a revert or a no-effect. |
| REN-02 | `finalize`, every claim function and every keeper entrypoint are `nonReentrant` and follow checks-effects-interactions: the relevant ledger is zeroed or decremented before any external transfer. | safety | U,I,C | |
| REN-03 | A creator, developer or winner contract that reverts on receiving ETH cannot brick finalization, another party's claim, or another generation's keeper call. | liveness | U,F,K | Push with a pull fallback. |
| REN-04 | Nested `unlock` never occurs: a whole route, a curve placement and a bid deposit each run inside exactly one unlock. | safety | U,K | |
| REN-05 | `unlockCallback` on the router, Locker and vault accepts only the `PoolManager`. | access | U | |

**Count: 127 properties** — supply 10, fees 13, sleeve 7, score 12, round 16, trunk 4, purse 7, bid 14,
continuation 11, roles 8, vesting 6, randomness 6, router 8, reentrancy 5. By tier (properties may carry
several): U 108, F 45, I 28, K 57, H 22, C 20.

## 4. Fork-test scenarios (K) — real `PoolManager`, fork of chain 46630

RPC from `.env` as `RPC_TESTNET`, read-only; every scenario deploys a fresh stack on the fork, so no live
state is mutated.

1. **Genesis launch and first buy through the router.** `createGenesis`, then assert the curve ranges,
   `initSqrtPriceX96`, the `DevVesting` balance, the dust burn, and that placed token equals
   `genesisTokensForSale()` minus dust. Then a router `buyExactIn`: assert the 1% ETH-edge fee plus the
   750 ppm hop fee, the four ledger deltas summing to the protocol fee, and the creator credit.
   Covers SUP-02/03/08, FEE-01/02/08, ROU-01/02.
2. **Three-deep path, fee-once.** Crown two links, then `buyExactIn(targetIndex = 2)` and the reverse
   `sellExactIn`: exactly one protocol fee on the genesis leg in each direction, three hop fees, and a
   protocol-fee total identical to the one-hop case at the same ETH notional. Covers FEE-01/02, ROU-04.
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
   `priorIndex + 1`, a genesis-pool swap after the handover forwards the ETH edge to v2's vault, a
   gas-burning successor queues instead of booking locally and does not revert the swap, and `flushForward`
   delivers the queue one hop per call across three versions. Covers CON-01/04/05/06/07/09.
9. **Locked-liquidity negative test.** Attempt `modifyLiquidity` with a negative delta as the Locker, the
   factory, an EOA and from inside a route's unlock; attempt `donate`; attempt to initialize an
   unregistered key and a registered key at a wrong price. All must revert. Covers SUP-05/06/07, REN-01.
10. **Role transfers under real time.** Announce steward, developer and beneficiary transfers; assert
    execution reverts at `+7 days − 1 s`, succeeds at `+7 days` from any caller, that a cancel takes the
    announcement back, and that nothing new becomes callable after execution. Covers ROL-05/06, VST-05.

## 5. Halmos candidates (H) ★

Each is chosen because its loops are bounded by a small constant or absent, its inputs are pure integers,
and it touches no external contract.

1. **`snipeTaxPpm(elapsed)`** — pre: `elapsed ≥ 0`. Post: `elapsed == 0 ⇒ 990_000`; `elapsed ≥ 3 ⇒ 0`;
   monotone non-increasing on `[0,3)`; never above 990_000. Pure linear integer math, no loop.
2. **Fee gross-up `feeFor(basis, rate, mode)`** — post: the exact-in and exact-out branches yield the same
   fee for the same *gross* parent amount to within 1 wei, and the exact-out branch reverts iff
   `Σrates ≥ 1e6`. Two straight-line branches, symbolic over `basis` and `rate`.
3. **`bondFor(index)`** — post: monotone non-decreasing; `≤ BOND_MAX_WEI` for every `uint256` index; equals
   `BOND_BASE_WEI << (index/every)` whenever that is `≤ BOND_MAX_WEI`; never reverts or wraps. Shift
   saturation is exactly the overflow class a solver finds and a fuzzer misses.
4. **Schedule functions** `durationFor`/`registrationFor`/`lateEntryUntil`/`closingWindowFor`/
   `randomEndWindowFor` — post: the caps hold for all `n`; `randomEndWindowFor(n) ≥ 1`; and the
   load-bearing relation `lateEntryUntil(n) < durationFor(n) − closingWindowFor(n) − RANDOM_END_S` holds
   for every `n` *and* every legal `DURATION_SCALE_DIV`. Pure functions of one small integer.
5. **Ancestor coefficients `(c0, c1, c2)` from `(sleeve, M)`** — post: `Σ_{j=0..M} query(j) ≤ sleeve`,
   `sleeve − Σ ≤ 3·(M+1)` wei, and `w(0) = 2·w(M)`. Bound `M` to a small symbolic range (≤ 8) and let the
   solver choose `sleeve`; this is the under-allocation guarantee FEE-11 leans on.
6. **Fenwick range-add / point-query equivalence** — post: for a bounded symbolic sequence of range-adds
   (≤ 3) over a bounded tree (≤ 8 leaves), every point query equals the naive sum. Loops are `log N` and
   bounded; the signed arithmetic makes this a strong solver target.
7. **`vested(t)`** — post: monotone in `t`; zero below the cliff; exactly `total()` at `start + duration`;
   never above `total()`; and `vested(start + cliff)·duration == total()·cliff` exactly. Pure, three
   branches.
8. **Token bucket `drawableEth(j)`** — post: for any two draws at symbolic times `t1 < t2` with symbolic
   amounts, the total drawn over any 24 h span never exceeds `cap + refill(24 h)`, and `available` is never
   above `cap`. This is precisely the property the resetting-window version violated at a boundary.
9. **Tie comparator `_beats(a, b)`** — post: irreflexive, antisymmetric and transitive over symbolic
   triples of `(avg, tFirstAttained, poolId)`. Cheap, and catches a total-order bug fuzzing rarely hits.

## 6. Certora candidates (C)

**Ghost state needed.** `ghostLedgerTotal[currency]` mirroring every ledger write; `ghostFeeCharged`
accumulating the hook's per-swap total; `ghostSleeveDeposited[M]` and `ghostSleeveQueried[j]` over the
Fenwick trees; `ghostLockedLiquidity[poolId]` incremented on every Locker deposit; `ghostCanonicalWrites[i]`
counting writes to each canonical index; and a per-method tag marking which functions carry a caller check.

**Rules and invariants.**
- *Solvency* (FEE-11): invariant `ledgerTotal[c] ≤ holdings(c)` for every currency, preserved by every
  `FeeVault` method — `accrue`, `accrueForwarded`, `receiveForward`, `flushForward`, the three claims, the
  four `onlyBidDeployer` hooks and `redeem`.
- *Fee conservation* (FEE-08): rule — after any `accrue`, the sum of ledger deltas equals
  `hopFee + protocolFee` and no untouched ledger changes.
- *Sleeve under-allocation* (SLV-03): invariant `Σ_j ghostSleeveQueried[j] ≤ Σ_M ghostSleeveDeposited[M]`.
- *Append-only history* (RND-09): invariant `ghostCanonicalWrites[i] ≤ 1` for every `i`; rule — only
  `finalize` and the one-shot adoption path increment it.
- *Liquidity ratchet* (SUP-05): invariant `ghostLockedLiquidity[poolId]` monotone non-decreasing across
  every method of every contract.
- *Supply constancy* (SUP-01): invariant `totalSupply` changes only in `burn`, and only by `msg.sender`'s
  own balance delta.
- *Privileged surface* (ROL-01): a parametric rule over all methods asserting that no method writes `head`,
  `canonical`, `hWad`, a fee rate, a split, a schedule parameter or a liquidity position unless it is one
  of the named writers, and that every caller-checked method writes only its declared variables.
- *Keeper leash* (BID-05): rule — `payKeeper` transfers at most the `deployerCredit` created in the same
  transaction by `consumeAncestorClaim`, and `deployerCredit` is zero at the end of every transaction.
- *Router fee neutrality* (ROU-02): rule — for equal swap parameters, the fee computed with router
  `hookData` equals the fee computed without it.
- *Reentrancy* (REN-01): rule — no `RoundManager` or `FeeVault` state-changing method is reachable while
  the `PoolManager` unlock flag is set, except `FeeVault.accrue` called by the hook.
- *Vesting monotonicity* (VST-03): invariant `released ≤ total()`, `released` non-decreasing.

**Summaries required.** `PoolManager.swap`, `modifyLiquidity`, `initialize`, `unlock`, `sync`, `settle`,
`take`, `mint`, `burn`, `getSlot0` and `protocolFeesAccrued` must be summarized (NONDET, or a small
two-currency ledger model), as must the BN254 pairing precompile `0x08` (NONDET bool), the drand source
(`pin`/`fulfil` → NONDET word under a pinned-round constraint), and `SqrtPriceMath` /
`LiquidityAmounts` (NONDET under range constraints) — the curve math belongs in Halmos, not Certora.

## 7. Gaps in the spec

1. **"One protocol fee per economic trade" is defined only for routes crossing the ETH edge once.** The
   spec does not say what an ETH → … → ETH round trip inside one `swapPath` should pay. FEE-01 assumes one
   fee per traversal, i.e. two for a round trip.
2. **Purse split rounding.** CLOSED by review 3: there is no split, so there is no remainder wei to
   allocate.
3. **`MIN_BOUNTY_WEI` has no stated mainnet value** (testnet 3e14), so BID-06's floor branch cannot be
   asserted against a number.
4. **Board staleness vs board correctness.** CLOSED by review 3: there is no board.
5. **`tFirstAttained` semantics.** The spec calls it both "the moment the final average was first reached"
   and "the last score update at or before `tEnd`". These differ when the average plateaus; SCR-12 uses the
   latter (the actual return value) while the tie rule's intent reads like the former.
6. **Reads outside the ring's span.** The coarse ring is sized for `W + RANDOM_END_S + SUBMIT_S`; the spec
   does not state the behaviour when a pool has been inactive longer than that and `T_end − W` precedes the
   oldest entry. SCR-04's "within the rings' span" is an assumption.
7. **`DURATION_SCALE_DIV` vs `closingWindowFor`.** The divisor is said to scale `D`, `R` and late entry and
   explicitly not `RANDOM_END_S`; it is silent on whether `W` is computed from the scaled or the nominal
   `D`. RND-01 assumes the scaled one. Since review-2 `W` is FLAT - `CLOSING_WINDOW_S / DURATION_SCALE_DIV`, 15 min on every round, so the question of which `D` it is computed from no longer arises for `W` itself. The random-end window is
   `max(1, min(RANDOM_END_S, D(n) / 4))`, so a scaled round can no longer draw `T_end` at or before its
   own `tradingStart`, and the modulus in `fulfilEnd` is never zero. On mainnet `D(n) >= 15 min` and the
   clamp never binds.
8. **"No fee on genesis-less paths."** The spec's rule is "protocol fee iff the pool is the genesis pool",
   which coincides with "iff one side is native ETH" only because genesis is the only ETH-paired pool. A
   continuation stack has no ETH pool of its own; the rule should be restated in terms of the currency.
9. **`rank` before `finalize`.** CLOSED by review 3: there is no `rank`. A generation that has not been
   crowned has no `canonical(j)` and `deployAncestor` reverts `UnknownGeneration`.
10. **Developer ledger asymmetry.** The single developer pot is disclosed as claimable by whoever holds the
    role at claim time, while the creator ledger sweeps on transfer. The spec does not say whether the
    asymmetry is intended; ROL-07 asserts only the creator behaviour.
11. **Beacon round reuse across rounds.** RAN-04 assumes a beacon round pinned by one round cannot settle
    another. The spec says pinning is once *per round* but not that two rounds cannot pin the same beacon
    round, which is reachable when two nominal ends fall in the same beacon period on a scaled schedule.
12. **`averageOver` with `t1 == t0`.** Reachable if `W` scales to zero on an extreme testnet divisor; the
    spec names no behaviour (revert, zero, or spot).
13. **Genesis vesting under continuation.** A continuation cannot call `createGenesis` and so mints no new
    allocation; the spec does not state whether the successor's `FeeVault.developer()` bears any
    relationship to the original vesting beneficiary. Assumed independent.
14. **`hopFeePpm` at its ceiling.** FEE-06's unreachability argument depends on `hopFeePpm` being below
    `MAX_HOP_FEE_PPM`. The spec calls a summed rate at or above 100% unreachable at the deploy constants
    but does not forbid deploying at the ceiling.

    Two corrections to the arithmetic this item used to carry (review-2, from the Certora rule
    `summedRatesStayBelowOne`). First, **the three parent-side rates are never summed on one pool.**
    `_collect` takes `protocolPpm = p.isGenesis ? PROTOCOL_FEE_PPM : 0` and `snipePpm` is zero whenever
    `tradingStart == 0`; the genesis pool is registered with `tradingStart == 0` and, since review-2, the
    hook itself enforces that (`GenesisHasNoSnipeWindow`). So the protocol fee and the snipe tax are
    MUTUALLY EXCLUSIVE per pool, and the real worst case is
    `hopFeePpm + max(PROTOCOL_FEE_PPM, SNIPE_START_PPM) <= 1_000_000`. Second, the figure quoted here was
    wrong: had the three been summed it would be `990_000 + 10_000 + 10_000 = 1_010_000`, i.e. **101%**,
    not 100.075%. The measured ceiling case is a candidate pool in the first second of its snipe window at
    `hopFeePpm = MAX_HOP_FEE_PPM`: `990_000 + 10_000 = 1_000_000` ppm, which reverts
    `SnipeExactOutputTooLarge` rather than wrapping (`PROPERTY_RESULTS.md` gap 14).
