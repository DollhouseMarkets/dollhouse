# Readiness — the twenty questions

Answers against the code in `contracts/` at the tree that adds MECHANISM_v3 — the adaptive round
schedule, the drand-verified random end, and the then-contestable purse (superseded 2026-09-13, see
`docs/attack-log.md` "Review 3") (**226 tests passing**, 27 suites —
three new: `Schedule.t.sol`, `Drand.t.sol`, `Purse.t.sol`; see `docs/MECHANISM_v3.md` and
`docs/spec/PROTOCOL_SPEC.md` §A/§C/§F/§J/§N for what changed), superseding the 183-test tree that adds
the developer vesting allocation and the steward/developer/beneficiary role-transfer paths (24 suites —
three new there: `DevVesting.t.sol`, `DevAllocation.t.sol`, `RoleTransfer.t.sol`), which itself
superseded the 162-test tree that
closed the gas-optimization pass, which itself superseded the 160-test tree that closed the final
external contract review (itself superseding the 145-test tree that closed the earlier
final independent contract review). The two tests added in the gas-optimization tranche
(`FeeVault.t.sol::test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor`,
`test_deployAncestorAcceptsTheBelowFloorQuote`) close the run-3 sizing-view finding below (§15).
Also against the MID simulation results in
`docs/sim-results-final.md`, the research dossiers, both final independent audits
(`docs/reviews/2026-09-11-contract-review-final.md` and `docs/reviews/2026-09-11-contract-review-external.md`, dispositions in
`docs/attack-log.md`) and the deploy script `script/Deploy.s.sol`. The live testnet run log is
`docs/TESTNET_RUN.md` and the authority on what has actually fired on a public chain is
`research/INTERFACES.md` — read those, not this file, for liveness. Mainnet 4663: nothing deployed.
`OPEN:` marks a blocker that must be closed before mainnet. Section references are to
`docs/spec/PROTOCOL_SPEC.md`.

---

**1. What exactly makes a candidate canonical?**
Exactly one branch of one function: `RoundManager.finalize()` crowns `r.bestCandidateId` if and only
if `r.hasBest && r.bestAvg >= int256(r.hUsed)`, where `bestAvg` is the **closing-window** average
parent absorption over `[T_end − W, T_end]` (MECHANISM_v3 §2, spec §F) and `hUsed` is the threshold
frozen when the round opened. **`T_end` itself is no longer a fixed public timestamp.** It is settled
either by a verified drand relay (`requestEnd()` pins a future beacon round at the nominal end `T`;
`fulfilEnd(proof)` verifies it on chain and derives `T_end = T − (word mod randomEndWindowFor(n))`) or,
if nobody relays one within `END_TIMEOUT = 30 min`, by the disclosed deterministic fallback
`finalizeDeterministic()` (`T_end = T`); `finalize()` itself reverts `EndNotSettled` until one of the
two has run. `W` is `15 min` for rounds of an hour or less and `D(n)/4` for longer ones, the SAME
window for every candidate regardless of when it registered — a late entrant (permitted only on
rounds ≥ 1 hour, during the first third of trading) is scored identically, just with less time to
build the level `W` measures. Crowning writes `canonical[headIndex+1]`, `indexOf`, `isCanonical`,
`parentOf`, `head` and — new — `_roundOfIndex[headIndex+1]`, seeding that generation's purse board
(question below and spec §J) — all write-once, and no other code path writes them. A continuation
deployment copies the prior head once, in `_adoptIfContinuation()` during its first
`openRoundIfIdle`, and only when the prior version is sunset-effective, names it, and is idle; it
never rewrites an index and cannot crown anything before that (audit F1, §A). Evidence:
`Round.t.sol::test_finalizeCrownsWinnerRefundsBondAndForfeitsLosers`,
`Invariants.t.sol::invariant_canonicalHistoryIsAppendOnly`,
`Schedule.t.sol::test_nothingSettlesUntilTheEndIsKnown`, spec §A/§C/§F/§G. Being canonical requires a
*submitted* score: `submitScore` is permissionless but optional, so a qualifying candidate nobody
submits for does not win.

**2. How much does it cost to manipulate that outcome?**
0.15% of the capital cycled — $5 on $3,220 at 2× the honest leader's average absorption, with a 100%
capture rate on every curve tested (Sim 4 on MID). That cost is *exactly* the round-trip hop fee,
`1 − (1 − f_hop)²` at 7.5 bps: the snipe tax is zero after 3 s and the price impact of a
buy-then-sell across a static curve is zero to machine precision. The cheaper shortcuts are closed —
`late_spike` tops the round 0% of the time because one second of capital contributes **1/900** of
itself to the average, and the block-1 sweep pays the 99% tax. Manipulating *which* candidate wins
is therefore cheap; manipulating it *late or cheaply* is not. One class of manipulation that used to
be free is now closed: a buy inside the snipe window can no longer drive a rival's score negative
(C1; `HookScore.t.sol::test_snipeWindowBuyScoresPoolDeltaAndNeverGoesNegative`).

**A new, deliberate manipulation surface arrived with the closing-window rule, and it is disclosed,
not fixed (MECHANISM_v3 §2, Sim 13).** Because the score is an average over `[T_end − W, T_end]`
rather than the whole round, a **window sniper** — capital equal to the leader's, bought at the start
of `W` and simply held — beats a leader who has been spreading buys across the whole round ≈82% of the
time in a 4-hour round and ≈93% of the time in a 15-minute round, whether the end is random or fixed.
This is the rule working exactly as specified (the coin with the highest average at the end wins, and
late money that stays counts fully) rather than a bug, and the design intent behind the rule — the
time average is only a defence against manipulation, not a reward for endurance — is the reason it
is accepted rather than patched. The random end (2.4% → 0.2% flip rate at
the last-second-spike scale, Sim 13) defends only against a *fixed-second* spike; it does nothing
against a sniper who buys and holds the whole window. The disclosed defences are: the window sniper
must actually HOLD capital through `W`, not flash it; nobody knows `T_end` in advance even inside `W`;
and a longer window gives the incumbent's community more time to see the raid coming and respond —
which is why the safe tuning direction, if this is ever revisited, is to lengthen `W`, not shorten it.

**And that number decays with depth, which is why the bond now scales (audit F6) — and here the bond
is a spam/failure guard, not a price, for a winner (audit 10 correction).** `H` is 0.15% of the
*parent's* supply, and a link is worth only 5–8% of its parent in ETH, so clearing the threshold for
the full 900 s costs roughly $100 at generation 1, $7 at generation 2 and **under $1 from
generation 3**. The bond is depth-scaled: `bondFor(targetIndex) = min(base << (targetIndex /
doublingEvery), max)`, testnet 0.001 ETH doubling every 4 links to a 0.064 ETH cap, mainnet target
≈$20 base doubling every 4 to 64× base. The round pins its bond when it opens and every candidate
stores what it paid, so a refund or a forfeiture always uses the amount actually posted
(`Depth.t.sol::test_bondDoublesEveryFourLinksAndIsCapped`,
`test_theBondIsEnforcedRefundedAndForfeitedAtTheScheduledAmount`) — and **the winner gets its own
bond back in full**, at any depth (§C, §G). So the bond is not a binding cost for a genuine,
successful capture at all: a confident attacker who wins with one honest entry pays only the ≈$1–100
of clearing `H` and gets the bond refunded, unchanged by depth. What the doubling schedule actually
prices is **failure and Sybil spam**: every LOSING candidate in a round forfeits its bond, so
registering many junk entries, or attempting and failing a takeover, costs `n × bondFor(...)` — and
that cost rises with depth exactly as intended (a 0.064 ETH cap is ~$250 per failed/Sybil entry). The
honest summary for the UI, corrected from an earlier, false disclosure ("non-refundable bond floor" —
audit 10, §3 below): **the bond is refundable capital, not a price; only losing or Sybil entries pay
it, and from about the third generation on that forfeiture is the main deterrent left against cheap
spam, since clearing `H` itself costs almost nothing.**

**3. Can a wealthy creator cheaply buy the slot?**
Yes, and this is an accepted, disclosed design decision, not an oversight (CONTEXT.md decisions
table; attack-log finding 5). Against an estimated slot value of $17,250 (next round's buy pressure
on the head plus one round of creator fee flow), capture at 0.15% of cycled capital is profitable by
roughly 3,573× for anyone with the float (Sim 4, MID). The only structural fix is a non-refundable
cost — a sunk slice, a lock, or seasoning — all of which were explicitly rejected.

**Correction (audit 10): the bond is refundable capital for a WINNER, not a price, and there is no
"non-refundable bond floor."** An earlier version of this document said there was one; that was
false, and the auditor called it out by name. `RoundManager.finalize()` refunds the winner's own
`Candidate.bond` in full — the amount it actually posted, at the schedule in force when it
registered — and only forfeits the LOSERS' bonds into the genesis-bid earmark. So for a creator who
is essentially certain to win outright with a single, honest entry, the depth-scaled bond schedule
(§C) is **not a cost at all**: it is capital that leaves and comes straight back, exactly like the
capital-rental capture itself. What the doubling schedule actually taxes is **failed or Sybil
attempts** — registering many losing candidates, or a takeover bid that does not clear `H` — because
only a loser's bond is forfeited. It is a spam guard against junk registrations and failed captures,
priced with depth, not a fix for capital-rental capture by a confident winner. The mitigation for
capital rental remains disclosure: the UI must state that the round is a capital-rental auction, that
the bond comes back to a winner, and that a Sybil or failed attempt at depth ≥3 forfeits a bond that
is now worth roughly `bondFor(targetIndex)`, doubling every four links to a cap.

**3b. Can the same capital-rental logic now buy the ancestor purse too (MECHANISM_v3 §1)?**
No, not since review 3 (2026-09-13). A generation's ancestor-sleeve purse is locked, in full, under
`canonical(j)`, the coin that won round `j`. The destination is decided by the round and by nothing
measured afterwards, so there is no ranking for parked capital to move.

The earlier, contested rule split the purse proportionally between a generation's top 2 siblings by
trailing support. Parking capital equal to a sibling's trailing support for one day cost about 15 bps
of friction plus carry and was break-even at the modelled fee flow (breakeven multiple 0.61x),
profitable above it (Sim 11). That attack is closed by removal. The cost of closing it is stated
plainly in `docs/MECHANISM_v3.md` §1 and `docs-site/risks.mdx`: there is no longer any penalty on a
round winner that is dumped, and a sibling that grows far past the winner earns nothing from the
chain's fee stream. Pairing rights were never contestable and still are not (spec §A/§J).

**4. What happens immediately after they win and dump?**
Nothing to the round: the hook froze the score at `T_end` (`ScoreFrozen`), so a post-bell dump moves
the price and not the result (`Round.t.sol::test_tailExtensionAndPostBellFreeze`). The new head's
price falls against its parent; every future descendant inherits the lower mark through the
telescoping price product, while every ancestor is untouched (Sim 8). The next round's bar does not
soften on price, because `threshold()` is a fraction of the head's *supply* — but absorbing that
many parent tokens becomes cheaper in ETH terms, so a crashed head makes the next succession easier
to win in dollar terms. A win also **resets** `hWad` to `H_FRAC_WAD` (§G), so a dumped win does not
leave a lowered bar behind.
**OPEN:** no scenario measures win-then-dump at the moment of succession; Sim 8 dumps a mid-chain
link on a mature chain, which is the adjacent but not identical case.

**5. What happens when an old canonical token later collapses?**
Its pool becomes a routing bottleneck, not a solvency event: locked liquidity can never be removed,
so the curve keeps bidding all the way down and releases embedded parent to sellers as it does
(§K, Sim 8). Sim 3 on MID measures a 99% dump at #6 on a 12-link chain: the full-line route cost
rises from 13.1% to 57.7%, and best-routing through an external ETH market brings it back to 10.8%.
Reinforcement does *not* rescue it — three rounds of sleeve is 0.713% of the link's parent reserve
and moves the drawdown from 94.6% to 94.6% (Sim 3, Sim 9), so the honest description remains "slow
accretion, not a shock absorber". Ancestors are unaffected; descendants inherit the whole drawdown.

**The audit's fixes make that description *more* true, deliberately.** Reinforcement is now rate- and
size-limited on purpose: a generation's ETH sleeve may be drawn down at most **10% of a continuously
refilling token bucket** (`FeeVault.drawableEth`, `drawBucket`, `DailyLimitExceeded`, audit F4,
refined by audit 6 from a resetting window that could burst ≈19% at a boundary) and any one call may
buy at most 2% of `max(active tick bucket, first curve range capacity)` of parent (audit F7). Every
link priced into that call is `min(spot, TWAP_30m, TWAP_7d)` in value terms (audit F4, sharpened by
audit 1), so a crashed conversion pool is priced at the crashed spot, not stale pre-crash averages.
The terminal generation's own parent-denominated hop pot — which used to have no ETH-free deployment
path at all — is now deployable on its own with `deployHopPot(j)` (audit 3). So even a well-funded
sleeve cannot be dumped into a collapsing pool as a rescue — by construction it arrives in slices
over days. Nothing about a collapse is *worse* than before: the sleeve was never a shock absorber,
and the limits exist because a fast drain is an attack (a TWAP drag), not a rescue. What genuinely
improved is that a deep link's sleeve is now spendable **at all**: before audit F3 the conversion
underflowed to zero around generation 10, so the accumulated support for every deeper link could
never be deployed in any amount, in any market condition
(`Depth.t.sol::test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed`). Support for a collapsed
deep link is now slow and capped rather than impossible — and the keeper who deploys it is now paid a
bounty floored at `MIN_BOUNTY_WEI` and capped at 20% of the ETH consumed, rather than a plain 1% that
could be smaller than the gas of the call (audit 5, still a disclosed dead zone at the smallest
sizes).

One consequence to state plainly: a collapsed pool is *thinner*, so its 2% cap is smaller in absolute
terms and support arrives more slowly exactly when it is wanted most. That is accepted and
disclosed — the cap is what stops one call moving a price, and there is no rescue path (§O).

**6. Does downstream trading remain usable at generation 10/20/50?**
Fees stay predictable — one 1% edge fee regardless of depth plus `hops × 7.5 bps`, i.e. 1.75% at 10
links and 8.50% at 100 (Sim 7). Price impact is what breaks: at a constant 0.5%-of-FDV trade the
full-line effective loss rises from 17.14% at 10 links to 67.17% at 100 on MID. Best-route and a
depth cap fix it by handing 100% of deep routes to an external ETH market — which is simultaneously
the fee leak (question 8). Engineering ceilings: `FamilyRouter` paths are O(j), the keeper's
`ethValueOfParent(j, amount)` is O(j) in *static calls only* (~48.5k gas per generation: the
band+consult chain measures ≈140k at j = 1, ≈2.20M at j = 32 and ≈8.63M at j = 128, and a whole live
`deployAncestor(1)` is ≈589k — the old swap-routing version could not have been mined at those
depths at all), and registration refuses past `FenwickRangeAdd.MAX_INDEX = 4095`, which caps the
chain at 4,096 links with a clean revert instead of a bricked swap. A beta deployment additionally
sets `RoundManager.MAX_INDEX` (immutable, `MAX_INDEX` env var, 0 = unlimited on testnet) so the
chain cannot leave the depth range the simulations cover
(`Depth.t.sol::test_maxIndexRefusesTheRoundThatWouldGoPastIt`). The honest ceiling is economic, not
computational: at 5–8% of parent value per link, a pool eleven generations down has a market cap of
dust and the 2% size cap refuses a keeper bid with `SizeCapExceeded` long before gas does
(`Depth.t.sol`, step 4).

**7. Does every user route pay exactly one intended protocol fee?**
Yes, per traversal of the ETH edge — the guarantee the design actually makes after attack-log
finding 2 replaced the transaction-frame model. The 1% (`PROTOCOL_FEE_PPM = 10_000`) is charged by
the hook on the **ETH side of a genesis-pool swap only**, in **both** directions, and never on a
family↔family pool. A routed buy through two links pays it once, on the genesis leg, plus the hop
fee (750 ppm = 7.5 bps at deploy) on both legs
(`Round.t.sol::test_routedBuyChargesProtocolFeeOnlyOnTheGenesisLeg`;
`Invariants.t.sol::invariant_noProtocolFeeOnFamilyPools` asserts that every family currency's whole
vault ledger is hop fee plus snipe tax and never a protocol fee). The fee is charged identically for
exact-in and exact-out, on whichever side the parent currency happens to be (`Swap.t.sol`, three fee
tests). The one way to pay it twice is to construct a path that crosses the genesis pool twice,
which only costs the trader. After a sunset the edge is still *charged* at the same pool by the same
hook — only the *booking* moves to the successor's vault (§J), so what a trader pays is unchanged.

**8. Can anyone bypass or multiply that fee?**
Bypass: yes, by trading a mid-chain link in an external ETH pool — the hook only sees its own pools,
and Sim 7 shows best-route sending 100% of deep routes there. That leak is structural and is the
same mechanism that keeps deep trading usable (Sim 3, Sim 7); on the family side it is bounded by
the hop fee. Bypass within the family: no — the hook charges at the pool, so a direct
`PoolManager.swap` pays exactly what a router call pays, and a copycat router gains nothing but
loses attribution (`Router.t.sol::test_hookDataOnlyTrustedFromTheCanonicalRouter`). The router
cannot be used to dodge value either: `swapPath` requires `msg.value == amountIn` on an ETH route
and `0` otherwise, and the router has **no `receive()`**, so no ETH can be parked in it and spent as
someone else's `amountIn` (M1, `RouterGuards.t.sol::test_routerHeldEthCannotBeSwept`). Multiply:
only by paying the edge fee twice in one path, which benefits nobody.

**9. What assets does every fee recipient actually receive?**

| recipient | asset | how it is delivered |
|---|---|---|
| developer (20% of the protocol fee) | **ETH** | `claimDev(to)`, pull, immutable address |
| creators (40% when attributed) | **ETH** | `claimCreator(token, to)`, pull; recipient right transferable |
| head creator, during a round | **ETH** | the same ledger — half the creator share on a candidate's attributed trades |
| ancestors (20% sleeve) | **no withdrawable balance** — the ETH buys **parent tokens** that become permanently locked bid liquidity under the ancestor's pool | `BidDeployer.deployAncestor(j, parentAmount)`: a keeper delivers the parent tokens, `BidDeployer` pays them out of `j`'s ETH (drawn from `FeeVault` via `consumeAncestorClaim`/`consumeReinforcement`) at the chain's own prices — priced link by link at `min(spot, TWAP_30m, TWAP_7d)` (audit 1), at most `drawableEth(j)` = 10% of a continuously refilling bucket (audit 6), at most `bidCap(j)` of parent |
| immediate-parent reinforcement (20%) | same as above — it is drawn by the same call, or independently via `deployHopPot(j)` with no ETH involved at all (audit 3) | `FeeVault.claimableEth(j) = claimableAncestor(j) + reinforcementEth[j]` |
| hop fees + snipe tax | already **parent-token units**; join the same locked bid with no conversion; the terminal generation's pot — previously undeployable for lack of an ETH entitlement — is now deployable on its own | `FeeVault.reinforcementBalance[parentToken]`, drawn partially up to the size cap via `consumeReinforcement`, or wholly through `BidDeployer.deployHopPot(j)` |
| genesis (index 0) + forfeited bonds | **ETH**, deposited as a locked ETH bid under genesis | `BidDeployer.deployGenesisBid()` / `deployGenesisBid(ethAmount)` |
| keeper | **ETH** (parent token on `deployHopPot`) | `deployAncestor` / `deployGenesisBid`: `max(1% of ethValue, MIN_BOUNTY_WEI)`, capped at 20% of the ETH the call consumes (audit 5), paid **on top of** the deposit, drawn from the pots as `deposited + bounty`; `deployHopPot`: the same 1%-with-a-floor-and-cap rule, paid in the parent token out of the same pot |
| winning creator | **ETH** | the bond it actually posted (`Candidate.bond` = the round's `bondFor(headIndex+1)`) back **in full** — refundable capital, not a price (§2/§3, audit 10 correction) — push with a `claimRefund` pull fallback |

Neither contract **ever swaps** (H1/M3): the keeper brings the tokens to `BidDeployer` and is paid
ETH at `ethValueOfParent(j−1, parentAmount)`; the ETH itself is drawn out of `FeeVault`'s ledgers
through four hooks (`consumeAncestorClaim`, `consumeReinforcement`, `consumeGenesisEarmark`,
`payKeeper`) that accept only `BidDeployer` (`onlyBidDeployer`), leashed by `deployerCredit` so it
can never move more than a generation's own money. Nobody can withdraw reinforcement as cash — it
exists only as liquidity the Locker can never remove, and the Locker accepts a bid only from
`BidDeployer` (`NotBidDeployer`).

**What the ancestor sleeve is worth changed materially across both audit tranches (audit
F3/F4/F5/F7, then audit 1/3/5/6).**

- **Pricing walks the amount, not a rate.** `ethValueOfParent` applies each link's factor as two
  full-precision `mulDiv`s on the *amount*. The old normalised per-link rate lost ~4 significant
  digits per generation and hit zero around `j ≈ 10`, which meant every deeper generation's ETH was
  a ledger entry nobody could ever spend — on the audit's estimate ≈30% of edge-fee revenue at depth
  20, paid to no one. That is fixed and asserted twelve links deep
  (`Depth.t.sol::test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed`).
- **Price per link is `min(spot, TWAP_30m, TWAP_7d)` in value terms (audit F4, sharpened by
  audit 1).** A 30-minute pump still cannot raise what the sleeve pays; a crash in a *conversion*
  pool now lowers the payout immediately instead of paying the pre-crash averages for up to half an
  hour — Run 2 measured the old gap at ≈1.01× the old value for a parcel worth ≈0.1× of it. Without
  a usable 7-day average (< 1 day of slow history) the call is priced on `min(spot, fast average)`
  and emits `SlowTwapUnavailable(j)` (`Keeper.t.sol::test_aThirtyMinutePumpCannotRaiseWhatTheSleevePays`,
  `test_aYoungPoolPricesOnTheFastAverageAndSaysSo`, `test_aCrashedConversionPoolIsPricedAtSpot`).
- **Rate limit is a token bucket, not a resetting window (audit F4, then audit 6).** At most
  `DAILY_DRAW_BPS` = 10% of a generation's claimable ETH, refilling continuously
  (`drawableEth`, `drawBucket`, `DailyLimitExceeded`) — the old resetting-window version let ≈19% out
  in seconds at a boundary; a bucket has no boundary. Keepers must size against `drawableEth`, not
  `claimableEth` (`Keeper.t.sol::test_theDailyDrawdownLimitBindsAndRefills`).
- **Size cap:** 2% of `max(active tick bucket parent reserve, first curve range capacity)`.
- **Bounty floor and cap (audit 5).** `bounty = max(1% of ethValue, MIN_BOUNTY_WEI)`, capped so it
  is never more than 20% of the ETH the call consumes. The first-range size-cap term is what makes an
  uncapped 1% bounty exceed the gas of the call at beta scale — ≈3.8× at 0.01 gwei
  (`Bid.t.sol::test_genesisBidBountyBeatsTheGasOfTheCall`) — but Run 2 still measured gas ≈215× the
  bounty at generation 1 and 121 wei of bounty at generation 8 before the floor; the floor and cap
  narrow the dead zone, they do not close it at the smallest sizes
  (`Keeper.t.sol::test_theBountyFloorIsPaidAtRunTwoSizes`,
  `test_belowTheFloorTheBountyIsCappedAtTwentyPercent`).
- **Band on the target pool only** (coverage still required on every pool in the conversion), so the
  path does not become progressively uncallable with depth.
- **The terminal generation's hop pot has a deployment path now (audit 3).** `deployHopPot(j)`
  deploys generation `j`'s parent-denominated hop pot with **no ETH entitlement involved** — the head
  of the chain used to have no descendant round and therefore no way to ever deploy its accumulated
  hop fees (`Keeper.t.sol::test_theHeadsHopPotDeploysWithNoEthEntitlement`).

So the honest one-line answer for the UI: ancestors receive **permanently locked buy-support, not
cash, delivered slowly by volunteer keepers who are still not reliably profitable at small sizes, and
capped per call and per drawdown bucket**. Tests:
`FeeVault.t.sol::test_devAndCreatorClaims`, `test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid`,
`test_deployAncestorDoesNotSwap`, `test_deployGenesisBidDepositsForfeitedBonds`,
`test_genesisBidDeploysFromTheHopPotAloneAndDrawsPartially`, plus `Keeper.t.sol` and `Depth.t.sol`.

**10. Can accounting grow unbounded with ancestry?**
Not on the hot paths: the ancestor sleeve is three signed Fenwick trees over the generation index,
so a fee is one O(log N) range-add and a payout one O(log N) point query, with no loop over ancestry
on any swap or claim (`FeeVault.t.sol::test_fenwickPointQueriesMatchBruteForceLedger`). Storage grows
by O(log N) slots per fee and the index space is capped at `FenwickRangeAdd.MAX_INDEX = 4095`, with
registration refusing the entry that would exceed it
(`test_registrationRefusesToExceedTheChainDepthLimit`) instead of letting a swap revert later. A
deployment may additionally pin a lower, immutable `RoundManager.MAX_INDEX` at deploy time
(`MAX_INDEX` env var; 0 = unlimited, the testnet value), which `openRoundIfIdle` enforces with
`ChainDepthLimit` (`Depth.t.sol::test_maxIndexRefusesTheRoundThatWouldGoPastIt`). Read paths that
*did* grow without bound are now paginated: `RoundManager.candidateIds(roundId, offset, limit)`
alongside the unpaginated view, so a spammed round cannot make an indexer's `eth_call` exceed the
gas limit (audit F10, `Round.t.sol::test_candidateIdsArePaginated`).

Accounting still grows on the keeper path: `BidDeployer.ethValueOfParent(j, amount)` reads the fast
*and* slow TWAP of every pool `0..j` — but in static calls only, measured at ~48.5k gas per
generation (≈2.20M at j = 32, ≈8.63M at j = 128), unchanged by the gas-optimization pass (which
targeted the four-slot `RegisteredPool`/`Observation` packing and the token-clone launch path, not
this static-call chain). What DID drop post-optimization: a real `deployAncestor(j=1)` call itself,
559,696 gas versus 570,185 before (`docs/DEPLOY_CONSTANTS.md` "Gas (post-optimization)"), and a
keeper can always deploy a smaller slice.
Crucially, precision no longer degrades with depth: the amount is walked with a full-precision
`mulDiv` per factor instead of a normalised rate, so there is no depth at which the arithmetic
silently returns zero (audit F3). Rounding is one-directional: floored Fenwick coefficients leave a
few wei per fee permanently unclaimable, which is what makes `ledgerTotal[c] <= holdings(c)` hold by
construction (`invariant_vaultIsSolvent`).

**11. Can any admin seize liquidity or alter historical economics?**
No. There are three role addresses in the whole system — steward, developer, and the `DevVesting`
beneficiary — and every one of their functions either stops new rounds opening, withdraws a balance
already owed to the caller, or moves who holds the role on a public 7-day delay. None of the three
can touch a pool, a price, a tick, a fee split, a threshold, a curve, liquidity, or history. The
entire privileged surface is **two steward functions on `RoundManager`, plus (added 2026-09-11) a
7-day announce/execute/cancel transfer triple on each of the three role addresses** (§M):

- **`announceSunset(successor)`** — steward only, once (`sunsetAt == 0`), successor must have code,
  effective after `sunsetDelay` — a `RoundManager` constructor parameter, floored at the immutable
  `MIN_SUNSET_DELAY = 1 hours`; mainnet is deployed at 7 days, testnet at 1 hour so a testnet run can
  exercise the whole handover live (audit 2) — no shorten, no second call, no transfer of the role,
  and refused with `NotAdopted()` if this deployment is itself an unadopted continuation (audit 2,
  the transitive-adoption guard, §A)
  (`Sunset.t.sol::test_onlyTheStewardMayAnnounce`, `test_announceIsOnceAndForever`,
  `test_successorMustBeAContract`, `test_zeroStewardMeansNoSunsetIsPossible`,
  `test_theDelayIsSevenDaysAndRoundsOpenThroughout`,
  `Continuation.t.sol::test_sunsetDelayIsAConstructorParameter`,
  `test_adoptionRefusesASunsetButUnadoptedPrior`).
- **`cancelSunset()`** — new in this tranche (audit F2). Steward only, allowed **only strictly
  before `sunsetAt`**, and **once in the lifetime of the deployment** (`sunsetCancelled`): a steward
  who announces a second sunset can no longer take it back. It clears `sunsetAt` and `successor` and
  emits `SunsetCancelled`. It exists because the named successor is otherwise irrevocable and this
  version's vault will forward real fee income to it and its hook will trust its router; if the
  steward discovers during the delay that the successor is broken or hostile, this is the only way
  back. It is deliberately impossible at or after `sunsetAt`, because by then an earlier version may
  already have resolved and cached the handover, and un-sunsetting would split the fee stream
  (`Sunset.t.sol::test_cancelSunsetWorksBeforeTheEffectAndNotAfter`,
  `test_cancelSunsetNeedsAnAnnouncement`).

`address(0)` as steward removes both powers entirely — and the upgrade path with them.
Splitting the treasury into `FeeVault` and `BidDeployer`
adds no fourth power: `BidDeployer` has no admin function of its own — every external entrypoint on
it is permissionless — and its only privilege is the `onlyBidDeployer` gate it holds on the other
side, on `FeeVault`'s four keeper hooks and `Locker.depositBid`, both immutable role checks with no
owner and no setter.

**Three transferable roles, one identical delay (design decision 2026-09-11: single cold-signer
hardware wallets rather than multisigs, with pathways to security upgradability).** The steward
(`RoundManager`), the developer (`FeeVault`), and the `DevVesting` beneficiary each move on their own
`ROLE_TRANSFER_DELAY = 7 days` constant — three separately declared constants with the identical
name and value, one per contract — through the same shape: `announce*Transfer(to)` by the *current*
holder only (`to != address(0)`, one pending transfer at a time), `execute*Transfer()` by **anyone**
once the delay has elapsed (so a lost outgoing key never traps the role), `cancel*Transfer()` by the
current holder, repeatable, at any time before execution. **No new power is created by any of the
six new functions**: the steward's whole surface after a transfer is still `announceSunset` /
`cancelSunset`, answering to whoever now holds the role; the developer's is still `claimDev`; the
beneficiary's is still `release()`'s destination. A transfer is therefore purely "who", never "what".
Disclosed consequence for the developer specifically: the dev ledger is a single balance, not
per-holder, so whatever has *already* accrued is claimable by whoever holds the role **at claim
time** — a transfer hands over the unclaimed balance along with the future stream, and an outgoing
developer should `claimDev` first if that is not wanted. Tests:
`RoleTransfer.t.sol::test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute`,
`test_sunsetPowersFollowTheNewSteward`, `test_onlyTheStewardAnnouncesOrCancelsAndOnePendingAtATime`,
`test_developerTransferWaitsOutTheDelayAndIsPermissionlessToExecute`,
`test_accruedDevBalanceIsClaimableByWhoeverHoldsTheRoleAtClaimTime`,
`test_onlyTheDeveloperAnnouncesOrCancelsAndOnePendingAtATime`,
`DevVesting.t.sol::test_beneficiaryTransferWaitsOutTheDelay`,
`test_onlyTheBeneficiaryAnnouncesOrCancels`, `test_cancelTakesTheAnnouncementBack`.

What the steward **cannot** do: pause or cancel a round; touch a pool, a price or a tick; move or
seize a single wei; change a fee, a split, a threshold or a curve; remove or migrate liquidity;
rewrite history; name a second successor; shorten either delay; cancel a sunset once it has landed,
or cancel twice; transfer the stewardship to a destination it did not itself announce, or skip the
7-day wait; stop trading, claims, bond refunds, keeper deployments or any history read — all of which
keep working forever after the sunset (`test_everythingElseKeepsWorkingAfterTheSunset`). Its *only*
economic effect is that `openRoundIfIdle` stops minting new rounds; a round already open still
trades, is scored, finalizes and crowns a head
(`test_aRoundOpenWhenTheSunsetLandsStillFinishesAndCrowns`). **Correction to the earlier text:** an
older version of this document said the steward could not "transfer the stewardship" at all; that is
now a deliberate, disclosed capability (the delayed transfer above), not an oversight — it replaces
the multisig recommendation for mainnet, not the immutability of the role.

What it *does* do economically: from the moment it takes effect, the 1% ETH edge charged on this
version's genesis pool is **forwarded** to the successor's FeeVault, which books it with the
successor's constants (§J). That is a real consequence of a steward choice, and it is the whole
reason the successor must be named publicly `sunsetDelay` in advance (mainnet 7 days, testnet 1 hour,
audit 2). **It cannot stop trading — and unlike the previous version of this document, that is now true for
the reason stated.** The audit (F2) showed that `try/catch` alone did *not* protect a swap: under
EIP-150 the callee receives 63/64 of the gas, so a successor that merely burns everything it is
given left less than the ~1M gas the local Fenwick booking needs, and every genesis-pool swap
reverted at any gas limit; the hook's unbounded `factory()`/`router()` staticcalls did the same to
every candidate pool, permanently and with no cancel. Three things fix it:

1. the vault's hop runs on `budget = min(FORWARD_GAS = 6,000,000, gasleft − BOOK_GAS_RESERVE =
   1,500,000)` and is **skipped entirely when that is zero**, so ≥1.5M gas is always still in this
   frame to **queue** the fee in `pendingForward` (audit 4 — never book it locally as a fallback) and
   let the swap finish;
2. every leg of the hook's successor-router resolution is a `staticcall{gas: 30_000}` whose result
   is checked (and a dirty-padded word is treated as no answer rather than a reverting `abi.decode`,
   audit 7A), so a hostile successor costs tens of thousands of gas, not everything;
3. a failure **at the full budget** arms a one-shot negative cache on each side (`forwardingFailed`,
   `successorUnresolvable`) so the hostile path is never re-paid; a failure on a caller's thin gas
   budget deliberately does *not* arm it, so an honest handover is not disabled by a stingy caller.

Measured: against a gas-burning successor the first genesis swap stays under 8M gas and every later
swap under 1M, and a candidate-pool swap under 1M
(`Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps`). A broken-but-not-hostile successor still
queues the fee for the next `flushForward` rather than booking it locally
(`Continuation.t.sol::test_aBrokenSuccessorQueuesInsteadOfBookingLocally`), and only a vault in the
caller's own prior-registry chain is accepted at the receiving end
(`test_accrueForwardedOnlyAcceptsAPriorVaultInTheChain`).

**The residual is honest and no longer a total loss (sharpened by audit 4).** Once a negative cache
is armed, every later ETH-edge fee for that pool is **queued** in `pendingForward` instead of being
attempted in-swap — it is never re-booked on the old version's own ledgers as a fallback — and it
stays recoverable forever by anyone's permissionless `flushForward(attribution, max)` call, one hop
at a time, even against a hostile successor's own queue, because a flush only needs a resolvable
successor vault, not a working `forwardProtocolFee`. There is no re-arm and no setter on the negative
cache itself. And after `sunsetAt` there is no way back to a *different* successor at all.
`cancelSunset` is the only escape hatch and it exists only during the `sunsetDelay` window (mainnet 7
days, testnet 1 hour). Everything else in the codebase is either a
contract-to-contract authenticity check between immutable addresses or a recipient claiming a balance
already owed to them. The Locker has no exit and `beforeRemoveLiquidity` reverts for everyone
including the Locker (`test_lockerHasNoExit`, `test_removeLiquidityAlwaysReverts`,
`invariant_lockedPositionsNeverDecrease`). The real residual is at deployment, not after it: whoever
deploys picks the curve, the splits, the hop fee, the genesis unit, the steward, the hook salt, and
the developer allocation's cliff and duration (§17). **Mainnet steward and developer: a single
cold-signer (hardware wallet) address each, per the 2026-09-11 design decision — deliberately not a multisig,
because the 7-day role-transfer delay above is the recoverability mechanism instead**
(`docs/DEPLOY_CONSTANTS.md`).

**12. Can a malicious candidate token enter?**
No — and genesis is no longer the exception. **CLOSED (was OPEN).** Candidates are deployed by
`FamilyFactory` itself, and the hook's `beforeInitialize` refuses any pool key the factory did not
pre-register, at any price other than the registered one, while `beforeAddLiquidity` refuses every
adder except the Locker (`Genesis.t.sol::test_initializeRevertsForUnregisteredKey`,
`test_initializeRevertsAtWrongPrice`, `test_addLiquidityRevertsForNonLocker`). `createGenesis` now
takes only `(name, symbol, uri)`: the ranges and `initSqrtPriceX96` are computed in-contract by the
same `StandardCurve.build` call candidates use, with the immutable `GENESIS_UNIT` standing in for a
parent supply, so the genesis squat that C2 described is impossible — two different callers get a
byte-identical curve (`GenesisCurve.t.sol::test_twoCallersGetAnIdenticalGenesisCurve`,
`test_genesisCurveIsTheStandardShapeInGenesisUnits`). The first caller still takes the genesis
*creator attribution*, which is a fee stream and nothing else. `wire()` additionally refuses any
launch into a half-deployed stack (`test_wireRefusesAHalfDeployedStack`). What remains is a
deploy-time choice, not a race: a wrong `GENESIS_UNIT` or `curveSpec` is permanent.

**13. Can one candidate freeze finalization?**
No. `finalize()` never iterates candidates: it reads the running best that `submitScore` maintained,
and a candidate that never submits is simply ignored. It is `nonReentrant`, idempotent
(`if (r.finalized) return;`) and permissionless, and a winner whose bond refund reverts cannot brick
it — the refund (the bond that candidate actually posted, `w.bond`, with `forfeited =
r.candidateCount · r.bondWei − w.bond`) falls back to `pendingRefund` and is pulled with
`claimRefund(to)`, which is exercised end to end against a creator contract that rejects ETH
(`RoundGuards.t.sol::test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth`,
`Round.t.sol::test_staleFinalizeIsIdempotent`, `test_finalizeCrownsWinnerRefundsBondAndForfeitsLosers`).
The only external calls in `finalize` are the earmark deposit and that refund, both after every
effect is written. The residual is liveness, not freezing: if nobody calls `submitScore` or
`finalize()`, succession stalls until somebody pays the gas — trading is unaffected.

**One new liveness edge, from lazy head adoption (audit F1).** A continuation deployment refuses to
open its first round (`PriorNotHandedOver`) until the prior version is sunset-effective, names it as
`successor()`, and is `isIdle()` — i.e. its last round is *finalized*. So an unfinalized final round
on the old version now blocks succession on the **new** version as well as the old one. Both unblock
with the same permissionless `finalize()` call, and the alternative (adopting a head that could
still move) is exactly the two-trunk bug this closes, so the trade is deliberate. Nothing else is
affected: swaps, fees, claims, refunds and every history read keep working on both versions
(`Continuation.t.sol::test_v2CannotOpenARoundBeforeTheHandover`,
`test_v2AdoptsTheHeadV1CrownedAfterV2WasDeployed`).

**Transitively, the same liveness edge now propagates one link further (audit 2).**
`_adoptIfContinuation` also requires the *prior* registry itself to be a root or already `adopted()`
— an unadopted intermediate (v1 that has itself never opened a round as a continuation of v0) can
neither be adopted through nor start its own sunset clock (`NotAdopted()` on `announceSunset`). This
closes a second fork path (v3 adopting v2's head through a v2 that never really adopted v1's trunk)
at the cost of the same trade: a stalled handover anywhere in the chain now blocks every version
below it from opening a round, not just its immediate successor. Tests:
`Continuation.t.sol::test_v3CannotAdoptThroughAnUnadoptedV2`,
`test_adoptionRefusesASunsetButUnadoptedPrior`.

**A third liveness edge, new with MECHANISM_v3: the `EndPending` phase between trading and
submission.** A round's nominal end `T` no longer settles anything by itself: `submitScore` and
`finalize` both revert `EndNotSettled` until either `fulfilEnd(proof)` (a verified drand relay,
requiring `requestEnd()` to have pinned a beacon round first) or the disclosed
`finalizeDeterministic()` fallback has run. Both are permissionless, so — exactly like `submitScore`
and `finalize` before them — the round does not advance itself; somebody has to pay the gas. The
**timeout is the backstop, not an edge case to worry about**: `finalizeDeterministic()` becomes
callable `END_TIMEOUT = 30 min` after `T` regardless of whether `requestEnd()` was ever called, so a
round can never hang on the beacon indefinitely — the worst case is a round settling 30 minutes later
than it otherwise would have, with no randomness for that round and `RandomEndUnavailable` emitted
loudly. Because a withheld or unrelayed beacon can only ever produce `T_end = T` — the one outcome a
late buyer could already plan for — nobody is incentivized to censor the relay strategically; anyone
motivated to see the round close (a winning creator wanting the bond back, in particular) can simply
call `finalizeDeterministic()` themselves once the timeout has passed. Tests:
`Schedule.t.sol::test_nothingSettlesUntilTheEndIsKnown`,
`test_theDeterministicFallbackIsRefusedBeforeTheTimeout`,
`test_anUnrelayedBeaconEndsTheRoundAtTLoudly`,
`test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd`. **OPEN, same class as the 7-day handover
below:** the drand relay path (`requestEnd`/`fulfilEnd` against a real, live beacon) has never fired
on a public chain — see "Links with liveness evidence / never fired".

**14. How are ties resolved?**
`RoundManager._beats`: higher average first; then the earlier `tFirstAttained` (the last score
update before `T_end`, i.e. when the final average was first reached, supplied by
`FamilyHook.scoreState` as `frozen ? tFrozenAt : tLast`); then the lower `uint256(poolId)`. The rule
is total, deterministic and independent of submission order, which is the point of attack-log
findings 1 and 10 — the grindable hash tie-break of v1 is gone, the pool id is consulted only when
two candidates match on both the average and the attainment second, and a re-submission is a no-op
because the score is a `T_end` snapshot (`Round.t.sol::test_submitOrderingAttackCannotWin`).

**15. How does the protocol survive extreme sells?**
The curve is the buyer of last resort and can never be withdrawn, so a dump walks back down the same
locked ranges it walked up and hands embedded parent back to sellers (§K, Sim 8). Curve shape decides
the path: the wall-like curve produces a genuine discontinuity — a single clip taking 4.0% off FDV at
8.24× trend at 66% of float — but over the whole dump it is the *safer* curve (−77.6% vs −90.9% at
50% of float) and returns 1.46× as much embedded parent. The cliff is fully computable in advance
from the deploy constants by anyone. Reinforcement does not help at realistic budgets (Sim 3, Sim 9),
and there is no pause, no circuit breaker and no rescue (§O).

**16. Does creator compensation remain attractive?**
Conditionally, and only linearly in ETH-edge volume. At the locked split (creator 40%) and $250,000
of edge volume per round, a winning creator takes about $1,000 per launch, $20,000 across 20
generations (Sim 6, Sim 1). Two things changed in the creator's favour and one against:

- **The head-creator season cut.** During a round, an attributed candidate trade splits the creator
  share **50/50** between the candidate's creator and the creator of the head the round is quoted in
  (`RouterGuards.t.sol::test_candidateBuySplitsTheCreatorShareWithTheHeadCreator`). Holding the head
  is therefore an income stream for the whole 15-minute season, not just a title — which is exactly
  why trading was extended from 600 s to 900 s.
- **A losing candidate's creator keeps their half.** The credited balance is never clawed back
  (`test_losingCandidateCreatorKeepsTheirHalf`), so entering a round is not all-or-nothing. Outside
  a round, a canonical link's trades pay 100% to that link's own creator
  (`test_canonicalBuyPaysTheWholeCreatorShareToThatLinksCreator`).
- Against: half the creator share on candidate volume goes to the incumbent, so a candidate's own
  round pays its creator less than a canonical link would at the same volume.

The creator also gets the bond back on a win and keeps a transferable claim right
(`FeeVault.t.sol::test_creatorRecipientIsTransferable`). The split is bound in
`script/Deploy.s.sol`: creator 40% with the remainder 50/50, matching `DEPLOY_CONSTANTS.md`.
**OPEN (minor):** the test suite still asserts the split at creator 10% / 71.43 / 28.57, so the live
numbers are unasserted (spec DIFF 5).

**17. Does developer compensation remain transparent and defensible?**
Yes on both counts, mechanically, and it is now **two disclosed streams, not one** (design decision
2026-09-11: developer compensation should be time-locked — a 3% dev
lock with 1-month cliff then 12-month linear. No clawback, no acceleration. Small enough to not cause
concern but gives me more upside than purely fees").

- **Fees (unchanged mechanism).** `DEV_BPS = 2000` is a public constant, the only thing the developer
  can do is `claimDev(to)` on their own accrued ETH, and every accrual is emitted (`FeeSplit`) as is
  every claim (`DevClaimed`). The developer has no control over liquidity, winners, splits, curves,
  history or the sunset (spec §M — the steward is a separate address). Magnitude: 20% of the 1% edge
  fee, about $10,000 over 20 generations at $250,000 of edge volume per round (Sim 6) — an economic
  right, not a business, which is exactly how the brief describes it. Note that across a sunset the
  developer of the *old* version stops accruing new edge fees (they forward to the successor) while
  everything accrued before stays claimable
  (`Continuation.t.sol::test_v1DevClaimsAccruedBeforeTheHandoverSurviveIt`).
- **A 3% genesis-supply vesting allocation (new).** `DEV_ALLOCATION_BPS = 300` is a public,
  immutable-once-deployed constant on `FamilyFactory`. At `createGenesis`, `devAllocation() =
  FAMILY_TOTAL_SUPPLY * 300 / 10_000` (3% of 1e9) is minted straight into a freshly deployed,
  immutable `DevVesting` contract — never to an EOA directly — with `DevAllocationVested(vesting,
  amount, cliff, duration)` emitted in the same transaction as `GenesisCreated`. **Candidates get
  none: 100% of every candidate supply is locked liquidity**, exactly as before (§B, §B.1). The
  schedule is fixed at deploy and can never be changed, revoked, clawed back or accelerated by
  anyone, developer included: `DevVesting` has no owner, no pause and no function that touches
  `start`/`cliff`/`duration`. Nothing is releasable before the cliff; at the cliff the linear amount
  accrued *since genesis* — `cliff/duration` of the allocation — unlocks in one step (mainnet: 30/365
  ≈ 8.2%, not zero), then it continues linearly to full vesting at `start + duration`. `release()` is
  permissionless and always pays the current beneficiary, which starts as `FeeVault.developer()` at
  genesis and is transferable independently of the fee-claiming developer role (§11) on its own
  identical 7-day delay. Tests: `DevAllocation.t.sol::test_genesisSupplyIsConserved`,
  `test_vestingIsWiredToTheGenesisTokenAndTheDeveloper`, `test_theAllocationVestsOnTheAnnouncedSchedule`,
  `test_candidatesHaveNoAllocationAtAll`, `test_genesisEmitsTheDevAllocationEvent`;
  `DevVesting.t.sol` (schedule to the wei, §B.1).

**Disclosure, stated plainly for the UI:** the developer is compensated by (a) 20% of the protocol's
1% ETH-edge fee, ongoing, and (b) a one-time 3% share of the genesis token's total supply, locked for
one month and then linearly released over the following year with no early exit and no top-up ever.
Both are public, both are immutable in mechanism (only *who holds the role* can move, on a public
7-day delay), and both are visible on-chain the moment genesis is created.

**18. Does genesis benefit without parasitically consuming downstream economics?**
Yes — this was the design review's Q6 concern and Sim 10 settles it arithmetically. Under `w(r) = 2 − 5r + 4r²`
with `Z(M) = (M+1)(5M+4)/(6M)`, genesis takes 34.5% of the ancestor sleeve at M = 5 and 0.240% at
M = 1000, decaying as `12/(5M)`; it is permanently worth exactly 2× the newest ancestor and never
more. The deleted 10% fixed floor is what a funnel would have looked like: 10.2% of every sleeve at
M = 1000, 43× the polynomial's own answer. Genesis's absolute take is the sleeve plus the forfeited
bonds plus the genesis pool's own hop fees, all delivered as locked bid liquidity rather than a
withdrawal, and all three pots are drawn **partially** up to the 2% size cap so none of them can
ever block the others (H2/L5).

**19. Is adding permanent liquidity better than buy-and-burn?**
Yes, but the margin is small at realistic budgets. Given the same $1,000 per round for 20 rounds and
then a 50%-of-float dump on link #7, `SINGLE_SIDED_BID` leaves the link 74.6% down against 76.5% for
`BUY_AND_BURN` and 77.7% for doing nothing, and it adds 10.96% to the parent bid within 50% of spot
— permanent, protocol-owned depth that a burn simply does not create (Sim 9 on MID). `TWO_SIDED`
lands between (75.5%) because half its budget funds its own overhead. Burn also pops the price on
the way in and leaves nothing underneath, which is why the design review had it deleted (attack-log
Q8). The honest caveat is scale: at the 2%-of-active-range per-call cap `BidDeployer` enforces and
fee budgets of this size, the bid is a rounding error against a determined seller.

**20a. Are MECHANISM_v3's own claims (the purse, the adaptive schedule, the random end) simulated too?**
Yes — `docs/sim-results-v3.md` (Sims 11–13, `python -m sim.scenarios_v3 --all`, seed 20260912),
inheriting every curve/fee/threshold number from the MID baseline so the tables sit next to
`docs/sim-results-final.md` unchanged. **Sim 11 (contestable purse, SUPERSEDED 2026-09-13 and not
re-run):** measured against the contested rule, honest drift left a winner 58–60% of the purse across
3/6/12-sibling generations; dumping 50–90% flipped the winner out of first place 70–98% of the time;
parking capital equal to the leader's trailing support for a day was break-even at ≈0.61× the
modelled fee flow. Review 3 fixes the destination at the round result, so neither the dump penalty
nor the parking attack exists any more. **Sim 12 (adaptive duration):** demand and failure-rate behaviour under the D(n)
schedule; the ≥8-hour-round demand-model caveat below is this scenario's own finding, not a contract
bug. **Sim 13 (random end and the closing window):** the random end cuts a fixed-second sniper's flip
rate 2.4% → 0.2% on a 15-minute round (down to 0.00% baseline already on a 12-hour round, so the
random end mainly matters for short rounds); the closing-window rule itself lets a window sniper beat
a spreading leader ≈82–93% of the time, fixed or random end alike — reported as the rule working as
designed, per question 2 above, not a finding to fix. **Disclosed modelling artefact, no constant
change:** at rounds ≥ 8 hours the `∝ √D` demand assumption implies absorbing more parent tokens than
the curve has float for; this is a limitation of Sim 12's demand model, not of the deployed contracts,
and is monitored rather than acted on.

**20. Are all core claims supported by executable simulations?**
Much better than before. `docs/sim-results-final.md` re-runs **every** scenario on the deployed MID
configuration — curve 20/25/35/20, `h = 0.15%`, hop **7.5 bps**, **900 s** trading window,
reset-on-win — with seed 20260910 and a reproduction command per scenario
(`python -m sim.scenarios --all --curve mid --h 0.15 --hop-bps 7.5 --final`). The three gaps flagged
in the previous pass are closed:

- (a) Sims 3, 5, 6, 7, 8, 9 and 10 **have** been re-run on the deploy curve; Sims 8 and 10 are
  unaffected by construction (explicit curve shapes / pure arithmetic).
- (b) The threshold rule now matches: the report's deploy-configuration table states H snaps back to
  H0 on a win "in both the real `RoundConfig` and Sim 2's reduced form", which is what
  `RoundManager.finalize()` does.
- (c) The 7.5 bps hop fee **is** now representable: fees are in ppm and the deploy constant is 750
  ppm, so every Sim 4 / Sim 7 fee figure is computed at the rate the contract charges.

Two verdicts remain negative and are reported as such: reinforcement as a shock absorber is
FALSIFIED (Sim 3/9: 94.6% → 94.6%), and "usable at depth" is FALSIFIED on price impact (Sim 7:
17.14% → 67.17% from 10 to 100 links). Headline MID results at the 900 s window: median winner sells
60.2% of float at 9.0× the threshold (Sim 1); thin demand fails 10.8% of rounds and reaches #20 in
23.1 rounds (Sim 2); a round pumps $16,892 of head demand and +352.1% head FDV (Sim 5); winner score
share 25.6% at N=5 → 5.4% at N=50; the block-1 sweeper still nets +$445/round after the tax (Sim 5).
**OPEN (minor):** Sim 2's *modelling note* inside that report still says "H persists across wins",
contradicting the report's own configuration table — the note is stale text, not a different run,
but it should be corrected so nobody re-derives the old liveness story from it.

**The first final independent contract review, and what it changed.** `docs/reviews/2026-09-11-contract-review-final.md`
(dispositions in `docs/attack-log.md`, "Final
independent contract review") read the tree at the tagged revision and returned **NOT READY for a capped mainnet beta; READY for a
paid third-party audit only after three blockers are fixed and re-tested.** All three were fixed and
re-tested at the following revision (145 tests):

| # | blocker | what shipped |
|---|---|---|
| F1 | continuation forked the trunk — v1 kept crowning during the 7-day delay while v2 had already copied the head, giving two different tokens at the same canonical index | **Lazy head adoption.** v2 reads nothing at construction, delegates every read to v1, and may open its first round only when v1 is sunset-effective, names v2, and is idle. One canonical trunk by construction. |
| F2 | a steward-named successor could **permanently brick every swap** via EIP-150's 63/64 rule; the docs claimed the opposite | **Gas bounds + escape hatch.** `min(FORWARD_GAS 6M, gasleft − 1.5M reserve)` on the vault hop, 30k-gas staticcalls in the hook, one-shot negative caches armed only on a full-budget failure, and a steward `cancelSunset()` before the sunset lands. |
| F3 | the keeper conversion underflowed to zero around generation 10, stranding ~30% of deep edge revenue as unspendable ledger entries | **Amount-walking conversion** (`ethValueOfParent` / `parentForEthValue`, full-precision `mulDiv` per factor), verified on a chain of twelve links. |

Every non-blocker finding was also addressed rather than deferred: F4 (`min(TWAP_30m, TWAP_7d)` +
10%/24 h drawdown), F5 (band on the target pool only), F6 (depth-scaled bond — see question 2/3),
F7 (cap sized against the first curve range so the bounty beats the gas), F8 (`DEVELOPER` and
`STEWARD` required env vars), F9 (symmetric exact-output gross-up on sells), F10 (paginated
`candidateIds`; mainnet bond raise in ROADMAP), F11 (comments and the observation-spacing note).
The auditor's own recommended beta caps are adopted in ROADMAP, and `MAX_INDEX` exists as a
constructor parameter so the depth cap is a deploy constant rather than a policy.

**The second final independent contract review, run externally, and
what it changed.** `docs/reviews/2026-09-11-contract-review-external.md` (dispositions in `docs/attack-log.md`,
"Final external contract review") read the tagged revision — the 145-test tree above, already past the
first final review — and returned **NOT READY for a public beta**, citing four blockers: stale-price
keeper overpayment after a crash, incomplete continuation-adoption safety (a second, deeper fork
path than F1 closed), stranded terminal-generation reinforcement, and fee forwarding whose
destination depended on the gas of the triggering swap. All eleven ranked findings plus the
unranked spec-discrepancy and disclosure items were fixed and re-tested, bringing the suite to
**160 tests**:

| # | finding | what shipped |
|---|---|---|
| 1 | price crash → keeper overpayment; only the target pool was spot-checked | every conversion link priced at `min(spot, TWAP_30m, TWAP_7d)` in value terms |
| 2 | unadopted intermediate continuation could still fork the trunk | transitive adoption check (`PriorNotAdopted`); `announceSunset` refused on an unadopted continuation (`NotAdopted`); `sunsetDelay` made a constructor parameter (mainnet 7 days, testnet 1 hour) so the whole handover is exercisable live |
| 3 | terminal generation's hop pot had no deployment path | permissionless `deployHopPot(j)`, no ETH entitlement required |
| 4 | gas decided which version booked fees; recursion died by v5 | post-sunset fees are never booked locally — forwarded in-swap when the gas budget allows, else queued in `pendingForward`; permissionless `flushForward`, one hop per call, no recursion; tested to six versions |
| 5 | keeper economics negative at small sizes | `MIN_BOUNTY_WEI` floor, capped at 20% of the ETH a call consumes; a disclosed dead zone remains at the smallest sizes |
| 6 | daily allowance was a resetting window (≈19% burst possible) | continuously refilling token bucket (`drawBucket`/`drawableEth`) |
| 7 | dirty-word successor answers reverted `abi.decode`; a successor's `sync(ERC20)` broke native settlement | raw-word validation (no revert on dirty bits); `sync(native)` before every native `settle()` in the router and Locker |
| 8 | losing candidates lost their supported exit and attribution after the round | candidate routes resolve the round's recorded parent forever; 100% attribution to the candidate's own creator post-round |
| 9 | a v4 protocol fee (if the controller enables one) would inflate the score | subtracted from the score via a `beforeSwap`/`afterSwap` snapshot of `protocolFeesAccrued` |
| 10 | "non-refundable bond floor" disclosure was false for winners | corrected: the bond is refundable capital, only losers forfeit it (§2/§3 above) |
| 11 | lens loaded the whole candidate array | already using the paginated `candidateIds(roundId, offset, limit)` overload |
| — | creator-right transfer moved accrued fees and allowed the zero address | transfer sweeps prior accrual to the old recipient's own `creatorAccrued` ledger; zero address refused |

**Four spec claims the first audit called false are corrected in that pass**, not merely softened: "a
steward cannot stop trading" (now true, and §J/§H say *why* — the callee can never be given the gas
the caller still needs); "one canonical trunk" (now enforced by lazy adoption); "nothing is
stranded" (now stated precisely as a rate limit and a size cap, spec §P invariant 9); and the
exact-output sell fee basis. **A fifth, from the second audit, is corrected in this pass:** the
"non-refundable bond floor" language above §3, which was simply false for a winner.

**The verdict itself is not ours to re-issue, for either audit.** Both sets of fixes are covered by
tests (160/160 passing), but **neither has been independently re-audited** — the same process that
found a finding cannot clear it. The correct status remains: every ranked finding from both final
audits is closed and covered by tests; a paid third-party audit is the next gate before mainnet.

---

## Claims verified / assumed

**Verified (against code or an executing test):** the head is written in exactly one place and is
append-only; liquidity is unremovable by anyone including the Locker; only factory-registered keys
initialize, at the registered price; **the genesis curve is computed in-contract and is identical
for any caller**; a half-deployed stack cannot be launched into; the whole supply is locked or
burned at launch; **the score is the pool's own parent delta in all four orientations and inside the
snipe window, never negative**; the score freezes at `T_end` and tail-extends to it; the 1% fee
exists only on the ETH edge, both directions, once per edge leg; exact-in/exact-out fee handling on
both sides; **fees are in ppm and 750 ppm is exactly 7.5 bps**; attribution is trusted only from the
canonical router (or, post-sunset, the successor's) and only for a minted index or a live candidate
id; the split sums exactly to the fee; the candidate season cut is 50/50 and survives a loss; the
Fenwick sleeve matches a brute-force ledger and never over-allocates; the vault is solvent in every
currency; the submission window defeats the ordering attack; finalization is idempotent and has a
pull-refund fallback; the threshold decays ×0.9 to its floor and **resets to H0 on a win**;
**the keeper never swaps, prices the keeper's tokens off the TWAP chain, refuses a TWAP that does
not cover 1800 s or has fewer than two observations, and is capped at 2% of `max(active-range
reserve, first-range capacity)`**; cold pools are sized from their own curve; mirrored orientations
launch, trade, win and take bids; the router refuses mismatched value, holds no sweepable ETH,
reports round-trip output correctly and settles mid-route residuals; **sunset is steward-only, once,
7 days, and changes nothing but new-round minting**; continuation resolves prior indices up to 8
hops and routes, bids and books across versions; a broken successor cannot brick a swap; the whole
deployed stack, `BidDeployer` included, fits under EIP-170 (`CodeSize.t.sol`).

New in that first-audit tranche, each verified by an executing test: **a continuation opens no round
before the handover and adopts the head v1 crowned after v2 was deployed**, so two versions can never
crown the same index (F1); **a gas-burning successor cannot brick a genesis-pool or a candidate-pool
swap**, and both negative caches arm exactly once (F2); **the conversion still prices a real amount
twelve links down where the old normalised rate underflowed to zero**, and a real `deployAncestor(8)`
pays out (F3); **a 30-minute pump cannot raise what the sleeve pays**, a pool without 7-day history is
priced on the fast average and says so, and **a generation's sleeve is drawable at most 10% per
24 h** (F4); **the entry bond doubles every 4 links to a cap and is refunded/forfeited at the amount
actually posted**, and `MAX_INDEX` refuses the round that would go past it (F6 + beta cap); **the
keeper bounty exceeds the gas of the call** at 0.01 gwei (F7); **exact-output sells pay the same fee
basis as exact-in**, both swap modes agree inside and outside the snipe window, and a ≥100% total
rate is refused (F9); **`cancelSunset` works before the effect, never at or after it, and only once
ever** (F2); **candidate ids are paginable** (F10). That tranche reached 145/145 tests.

New in the second (external review) tranche, each verified by an executing test: **every conversion link
is priced at `min(spot, TWAP_30m, TWAP_7d)`**, so a crashed conversion pool is priced at spot (audit
1); **a continuation cannot adopt through an unadopted intermediate, and an unadopted continuation
cannot announce its own sunset**, and `sunsetDelay` is a constructor parameter floored at 1 hour
(audit 2); **`deployHopPot` deploys the terminal generation's hop pot with no ETH entitlement**
(audit 3); **a low-gas post-sunset swap queues the edge fee instead of booking it locally, a
permissionless flush delivers it, and the queue reaches a sixth version through one flush per hop**
(audit 4); **the keeper bounty is floored at `MIN_BOUNTY_WEI` and capped at 20% of the ETH a call
consumes** (audit 5); **the drawdown allowance is a continuously refilling token bucket** (audit 6);
**a successor `sync`ing an ERC-20 cannot break native settlement, and a dirty-word successor answer
is treated as no answer rather than a reverting decode** (audit 7); **candidate routes stay
hop-capped and attributed after the round** (audit 8); **a v4 protocol-fee accrual is subtracted from
the score** (audit 9); **a creator-right transfer leaves what already accrued with the old
recipient and rejects the zero address**. That tranche brought the suite to **160/160** tests
passing, including a 2048-call invariant campaign (6 reverts, all in `forceSuccession`) with
ghost-counter coverage assertions (unchanged from the first tranche).

**Assumed (documentation, modelling or off-chain, not verified against this code):** every USD
figure (genesis FDV $250,000, $4,000/ETH, $250,000 of edge volume per round) is an exogenous
assumption; Sim 4's $17,250 slot value is an estimate, not a measurement; Sim 6's sell-tax
elasticity has no empirical basis and is stated as such; Sim 2's demand model is a reduced-form fit
plus lognormal draws, and its modelling note contradicts its own configuration table on reset-on-win;
that external ETH markets will exist for mid-chain links (Sim 3/7 both depend on it); that Robinhood
Chain's ~100 ms blocks and second-granular timestamps behave as sampled on 2026-09-10; that the
pinned Uniswap v4 commits are the ones that will be live at deploy time; that the deploy script's
address predictions hold at broadcast time (nonce ordering) — `wire()` proves code exists at the
predicted FeeVault/router, not that it is the intended code; that a future steward will name a
successor that behaves *economically* (the handover forwards real fee income to a contract this
deployment never audited — it can no longer brick anything, but it can keep the fee and pay it out
under its own splits); that the audit's own economic figures (each link worth 5–8% of its parent;
threshold cost < $1 from generation 3; ≈30% of deep edge revenue stranded before F3) are correct —
they come from probes on a Foundry chain, not from a live market; and that the three blocker fixes
are correct, since **they have not been re-audited by an independent party**.

## Links with liveness evidence / never fired

Read from `research/INTERFACES.md` and `docs/TESTNET_RUN.md`. **`research/INTERFACES.md` is the
authority and supersedes the table below.** RUN 3 (post-external-review, 2026-09-11) is live on chain 46630 as
TWO deployments — v1 (indices 0-1, now SUNSET) and v2 (indices 2.., live) — with every contract
source-verified (partial) on Blockscout. Run 3 drove the full succession round on v1 (genesis buy,
three candidates, a candidate sale, three `submitScore` calls, `finalize` with a head change,
`claimDev`, `claimCreator`, `deployHopPot`, a second round finalized with NO clearing candidate) and
then the full cross-version handover end to end on chain (`announceSunset`, a real 3600 s delay,
`cancelSunset` on a disposable third stack, lazy adoption, both branches of the ETH-edge forward, a
canonical index crowned by v2 in a pool quoted in v1's token, and both cross-version payout paths
placed by v1's own BidDeployer and Locker) — zero failed steps. Per the Audit Standard,
**never fired = broken**; after Run 3 only ONE link is still in that state (the 7-day slow-TWAP
floor) — down from four in Run 2.

| link | mechanism | join key | last verified live (chain 46630, Run 3) | status |
|---|---|---|---|---|
| FamilyHook ↔ PoolManager | v4 hook callbacks (beforeSwap/afterSwap + return deltas) | PoolId | 0.05 ETH genesis buy; 537,500,000,000,000 wei of fee taken by return delta (1% protocol + 750 ppm hop) | **live** |
| FamilyHook ↔ RoundManager | score accumulator writes per swap; round phase reads | candidate PoolId ↔ roundId | absorption → `submitScore` (avg 1.6519e25 ≥ H 1.5e24) → `finalize` (head → index 1) | **live** |
| Factory ↔ Locker ↔ PoolManager | mint 1e9, initialize pool, place N locked ranges | token address ↔ PoolKey | `createGenesis`, full 1e9-token curve placed with no ETH owed, 1,390,565 gas | **live** |
| FamilyRouter ↔ FeeVault (attribution) | `hookData` trusted only from the canonical router; candidate sentinel credits creator + head creator | canonical index / `CANDIDATE_ATTRIBUTION \| candidateId` | `buyCandidateWithParent`, `sellCandidate`, `buyCandidate` — `claimableEth(1)` 0 → 26,666,666,666,666 wei | **live** |
| FeeVault ↔ developer | lazy pull claim | token address | `claimDev`, 111,020,778,715,507 wei | **live** |
| FeeVault ↔ creators (`claimCreator`) | lazy pull claim on `creatorBalance[token]` | token address | head token's creator claimed 20,000,000,000,000 wei; `creatorBalance(head)` → 0 | **live — gap CLOSED**; `transferCreatorRecipient` / `claimCreatorAccrued` still never fired |
| FeeVault ↔ BidDeployer (the EIP-170 split) | the vault holds the ledgers; `BidDeployer` is its only keeper hook | generation index | `deployGenesisBid` and `deployAncestor` both drew from vault pots and were refused nothing | **live** |
| FeeVault ↔ ancestors | polynomial-rank accumulators; keeper buy-and-lock | generation index | `deployAncestor(1, 1.4822e21)`, paid out of generation 1's own sleeve, bid placed below spot in the #1 pool | **live at j = 1** |
| Keeper hop pot on its own — `deployHopPot(j)` (audit 3) | draws `reinforcementBalance[parent]` alone, up to the size cap; bounty paid IN PARENT TOKENS | generation index → parent token | `deployHopPot(1)`: pot 33,791.0 → 31,043.2 FAM0, keeper paid 27.4786 FAM0 as the 1% bounty, rest locked as a bid | **live — first time ever fired** |
| Audit-5 keeper bounty floor (`MIN_BOUNTY_WEI`) | `bounty = min(max(1%, MIN_BOUNTY_WEI), 25% of the ETH value)`; `maxParentForDeploy` now inverts the piecewise bounty formula exactly, so it quotes the real maximum below the floor instead of 0 | generation index | Run 3 (chain 46630) measured the FINDING live: `maxParentForDeploy(1)` read 0 while `deployAncestor` itself accepted 1.4822e21 parent tokens. **Fixed in code** (`BidDeployer._maxEthValueFor`, `FeeVault.t.sol::test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor`, `test_deployAncestorAcceptsTheBelowFloorQuote`); not yet re-verified live — that needs Run 4 | **fixed in code, live re-verification pending (Run 4)** |
| Keeper ↔ reinforcement / genesis bid | permissionless bounty calls | poolId | `deployGenesisBid(0)` — earmark 3e15 → 0, forfeited bonds of both rounds deployed as a locked bid below spot | **live** |
| RoundManager bond escrow ↔ FeeVault earmark | push refund to the winner; losers' bonds → `depositGenesisBidEarmark` | roundId | `finalize` — 1e15 wei refunded to the winner, 2e15 wei earmarked from two losers | **live** |
| `finalize` with NO clearing candidate | `hasBest == false` → no crown, `hWad ×= 0.9` (floor 0.25×), all bonds forfeited, `isIdle()` true | roundId | v1 round 2: head unchanged at #1, threshold 1.5e24 → 1.35e24, earmark 2e15 → 3e15, `isIdle()` true | **live — gap CLOSED** |
| Hook 1800 s (fast) oracle ↔ BidDeployer band check | `consult(poolId, 1800)` vs spot, ±3% | PoolId | first attempt for every pool in both phases, coverage 1,813-1,833 s, spot == TWAP | **live** |
| Hook 7-day (slow) oracle ↔ BidDeployer price floor | `consultSlow`; used only at ≥1 day of coverage, else `SlowTwapUnavailable` + fast average alone | PoolId | only the UNAVAILABLE branch fired again, coverage 3.0-10.7 ks of the 86.4 ks minimum | **BROKEN until exercised — the only remaining never-fired link** |
| Steward ↔ RoundManager `announceSunset` | steward-only, once, `sunsetDelay` later `openRoundIfIdle` reverts `Sunset(successor)` | successor registry address | v1 named v2, `sunsetDelay` 3600 s; `isSunset()` stayed false the whole hour, flipped true at 1789155939 | **live — no longer broken** |
| Steward ↔ RoundManager `cancelSunset` (F2) | one-shot take-back, only before `sunsetAt`, steward only | — | exercised on the DISPOSABLE v3 stack: `sunsetAt` → 0, `successor` → 0x0, `sunsetCancelled` → true | **live — no longer broken**; deliberately not exercised on v1/v2, whose one shot stays unspent |
| Continuation refusal before handover | `_adoptIfContinuation` requires prior sunset-effective, named, and idle | prior ↔ successor registry | `eth_call`: v2 `registerCandidate` before `sunsetAt` reverted `PriorNotHandedOver` | **live (negative test)** |
| Lazy head adoption (F1) | first round a continuation opens reads and freezes the prior head | prior `headIndex`/`headToken` | v2 `adopted()` false → true, `priorIndex() = 1`, parent = v1's head | **live — no longer broken** |
| Sunset handover — IN-SWAP forward | prior vault hands the ERC-6909 claim to the successor's vault + `accrueForwarded`, within `FORWARD_GAS` | prior vault ↔ successor vault | `ProtocolFeeForwarded` (v1) + `ProtocolFeeReceived` (v2) in one swap; v2 `devBalance` 0 → 2e13 | **live — no longer broken** |
| Sunset handover — QUEUE + `flushForward` | below the gas budget the fee queues in `pendingForward`; anyone flushes it later | attribution index | queued then delivered under attribution 0, and again under attribution 2 (funded v2's generation-1 sleeve) | **live — FINDING: the in-swap branch needs ~1.5M gas of headroom above the swap's own cost, so an ordinary trade always queues; `flushForward` is routine, not an edge case. Only one hop exercised (no v3 in the chain).** |
| Continuation crowns the next index | v2 writes indices above `priorIndex`; `registryOf` resolves ownership per index | canonical index | v2 `head() = canonical(2)`, parent = v1's #1, v1's own `headIndex` still 1 — the trunk continued, did not fork | **live** |
| Cross-version payout — `depositExternalBid` (genesis + ancestor) | a continuation's ETH/parent for a generation whose pool predates it must be placed by the owning version | canonical(j) ↔ prior BidDeployer | `v2.deployGenesisBid()` and `v2.deployAncestor(1, …)`: forwarded to v1's BidDeployer, placed by v1's Locker, neither deployer retained anything | **live — first time ever fired on either path** |
| Frontend / indexer ↔ chain | DexScreener auto-index of v4 pools; GMGN listing | pool address | **never** — the pools exist but no listing has been requested or observed | **BROKEN until exercised** |

Open gaps `research/INTERFACES.md` records: the 7-day slow-TWAP floor (only the `SlowTwapUnavailable`
branch has fired); the `DailyLimitExceeded` refusal itself (the 10%/24h limit bounded call SIZE in
both stacks, so the revert has only fired in unit tests); bond DOUBLING (`bondFor(1) == bondFor(2)`,
the schedule first doubles at index 4); `MAX_INDEX` (all three Run-3 stacks deploy uncapped);
multi-hop `flushForward` (only one hop exists — no v3 continuing v2 — so a second flush has nowhere
to go); and indexer/frontend listing (never requested or observed).

## Irreversible actions and their guards

| irreversible action | guard | verified by |
|---|---|---|
| `createGenesis` — one genesis, forever | `priorRegistry == 0` (`ContinuationHasGenesis`); `_genesisToken == 0`; `registerGenesis` reverts if `head != 0`; **the curve and price are computed in-contract, not supplied** | `Genesis.t.sol::test_genesisIsOnceOnly`; `GenesisCurve.t.sol::test_twoCallersGetAnIdenticalGenesisCurve` |
| Placing the launch curve — permanent, unwithdrawable | Locker-only add; hook rejects all removals; parent side must not be owed | `test_removeLiquidityAlwaysReverts`, `test_lockerHasNoExit`, `invariant_lockedPositionsNeverDecrease` |
| Burning launch dust | computed as the Locker's residual balance after placement, before any trading | `test_supplyIsEntirelyLocked`, `invariant_supplyIsConstant` |
| Crowning a winner — `canonical[i]` is write-once | threshold check; submission window; tie rule; idempotent finalize | `test_submitOrderingAttackCannotWin`, `test_staleFinalizeIsIdempotent`, `invariant_canonicalHistoryIsAppendOnly` |
| Forfeiting losers' bonds to the genesis bid | the round's pinned `bondWei` (depth-scaled `bondFor`), stored per candidate; only the winner is refunded, at the amount it posted; push with a `pendingRefund` / `claimRefund` fallback | `test_finalizeCrownsWinnerRefundsBondAndForfeitsLosers`, `test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth`, `test_deployGenesisBidDepositsForfeitedBonds` |
| Keeper purchase of parent tokens + locked bid deposit | every pool in the conversion must cover the full 1800 s with ≥2 observations (`TwapNotReady`); **each link priced at `min(spot, TWAP_30m, TWAP_7d)`** in value terms (audit 1), with `SlowTwapUnavailable` when there is no 7-day history; ±3% sqrt band on the **target** pool; ≤2% of `max(active-range reserve, first-range capacity)`; payout must be fully covered by `drawableEth(j)`, i.e. **≤10% of `j`'s continuously refilling drawdown bucket** (`DailyLimitExceeded`, audit 6); bounty floored at `MIN_BOUNTY_WEI` and capped at 20% of the ETH consumed (audit 5), only on a completed deposit; **the protocol never swaps, so there is no `minOut` left at zero** | `test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid`, `test_deployAncestorDoesNotSwap`, `test_deployAncestorRevertsOutsideTheTwapBand`, `test_deployRevertsWhenTheTwapIsNotReady`, `test_deployAncestorRespectsSleeveAndSizeCap`, `test_aCrashedConversionPoolIsPricedAtSpot`, `Keeper.t.sol` (all), `Depth.t.sol::test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed` |
| `depositExternalBid` — an irreversible gift of liquidity | same band and size guards; `NotOurLink` unless this version owns the canonical link; exact `msg.value` for a native-ETH parent | `Continuation.t.sol::test_depositExternalBidRefusesAForeignLink`, `test_v2GenesisBidIsPlacedByV1sVault` |
| ETH claims (dev / creator) | CEI: ledger zeroed and `ledgerTotal` decremented before the send; `nonReentrant`; caller identity checked | `test_devAndCreatorClaims`, `invariant_vaultIsSolvent` |
| Transferring a creator recipient right | current holder only; credited balances do not move | `test_creatorRecipientIsTransferable` |
| **`announceSunset(successor)` — once, no shorten; reversible only before it lands** | steward-only; `sunsetAt == 0`; successor must have code; 7-day delay; only effect is that no new round opens. **`cancelSunset()` is the one escape hatch**: steward-only, strictly before `sunsetAt`, once in the deployment's lifetime | `test_onlyTheStewardMayAnnounce`, `test_announceIsOnceAndForever`, `test_successorMustBeAContract`, `test_theDelayIsSevenDaysAndRoundsOpenThroughout`, `test_everythingElseKeepsWorkingAfterTheSunset`, `test_cancelSunsetWorksBeforeTheEffectAndNotAfter`, `test_cancelSunsetNeedsAnAnnouncement` |
| **Adopting the prior trunk (a continuation's one-shot head copy)** | `_adoptIfContinuation` requires the prior to be sunset-effective, to name this contract as `successor()`, and to be `isIdle()`; until then no round can open at all (`PriorNotHandedOver`) and every read delegates | `Continuation.t.sol::test_v2CannotOpenARoundBeforeTheHandover`, `test_v2AdoptsTheHeadV1CrownedAfterV2WasDeployed` |
| **Arming a negative cache (`forwardingFailed` / `successorUnresolvable`)** | armed only on a failure **at the full `FORWARD_GAS` budget** (or, in the hook, after the sunset is effective and the resolution chain returned nothing); there is no re-arm and no setter, so every later ETH-edge fee for that pool then **queues** in `pendingForward` instead of an in-swap forward — recoverable by `flushForward`, not lost, but never re-attempted automatically (audit 4) | `Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps`. **Irreversible by design; a fixed successor cannot be re-adopted, but a queued fee is not stranded.** |
| **Forwarding the ETH edge to a successor's vault** | only after `isSunset()`; successor resolved through the steward-named registry and cached write-once; receiving side accepts only a vault in its own prior-registry chain; **never recurses — a sunset receiver queues for its own flush instead (audit 4)**; **gas-bounded at `min(FORWARD_GAS, gasleft − BOOK_GAS_RESERVE)` and skipped when that is zero**, so `try/catch` plus the reserve means a failure **queues** the fee (never books it locally) instead of reverting the swap — the bound, not the wrapper, is the safety property (audit F2); a queued fee reaches any depth of chain through one permissionless `flushForward` per hop (audit 4) | `test_afterTheHandoverTheEdgeIsBookedByV2AndAttributedToItsCreator`, `test_theEdgeForwardsTwoHopsFromV1ThroughV2ToV3`, `test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt`, `test_theEdgeReachesTheSixthVersionThroughFlushes`, `test_aBrokenSuccessorQueuesInsteadOfBookingLocally`, `test_accrueForwardedOnlyAcceptsAPriorVaultInTheChain` |
| Deployment itself (salt-mined hook, address predictions, initial `developer` / `steward` — both now transferable, see the row below — plus immutable `MAX_INDEX` / bond schedule / `DEV_ALLOCATION_BPS` / vesting cliff and duration) | `wire()` proves the FeeVault and router have **code**; the hook constructor asserts its own address encodes exactly `HOOK_FLAGS`; the deploy script asserts every address prediction against what `new` returned and head continuity on a continuation; **`DEVELOPER` and `STEWARD` are now required env vars**, `DEVELOPER` may not be the broadcasting key unless `ALLOW_DEV_EQ_DEPLOYER=1`, and `STEWARD` has no default because `address(0)` is a legitimate deliberate choice (audit F8); nothing proves the addresses are the *intended* contracts | `test_wireRefusesAHalfDeployedStack`, `DeployConstants.t.sol`. **Still partially unguarded on *identity*: code existence is not code intent.** |
| **Transferring the steward, developer, or `DevVesting` beneficiary role (new, 2026-09-11)** | current-holder-only announce, `to != address(0)`, one pending transfer at a time; permissionless execute only after `ROLE_TRANSFER_DELAY = 7 days`; current-holder-only, repeatable cancel before execution; no new power is created — each role's function surface is identical before and after | `RoleTransfer.t.sol::test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute`, `test_sunsetPowersFollowTheNewSteward`, `test_onlyTheStewardAnnouncesOrCancelsAndOnePendingAtATime`, `test_developerTransferWaitsOutTheDelayAndIsPermissionlessToExecute`, `test_onlyTheDeveloperAnnouncesOrCancelsAndOnePendingAtATime`, `DevVesting.t.sol::test_beneficiaryTransferWaitsOutTheDelay`, `test_onlyTheBeneficiaryAnnouncesOrCancels`, `test_cancelTakesTheAnnouncementBack` |
| **The genesis developer allocation vesting itself (irreversible once genesis is created)** | `DevVesting`'s schedule (`start`/`cliff`/`duration`) has no setter anywhere; the only mutable field is `beneficiary`, moved by the transfer row above; `release()` can never pay more than `vested(now)` | `DevVesting.t.sol::test_everythingVestedAtTheEndAndNeverMore`, `test_badScheduleIsRefused` |

## Unknowns and how to close them

1. **Closed for the happy path AND the handover; a narrow set of branches remain.** Run 3
   (2026-09-11) exercised the full round lifecycle on v1, `finalize` with NO clearing candidate,
   `claimCreator`, `deployHopPot`, and the ENTIRE cross-version handover live (`announceSunset`,
   a real 3600 s delay, `cancelSunset`, lazy adoption, both ETH-edge forward branches, and both
   cross-version payout paths). What has *still not* run live: the 7-day slow-TWAP FLOOR (only
   `SlowTwapUnavailable` has fired — pools qualify after 2026-09-12T18:00Z), the `DailyLimitExceeded`
   revert itself (only the happy-path SIZE bound has fired), bond DOUBLING (2-deep chain, doubling
   starts at index 4), `MAX_INDEX` (all Run-3 stacks are uncapped), and multi-hop `flushForward`
   (only one hop exists — no v3 continuing v2). Close by driving each branch deliberately on testnet
   and recording the tx in `research/INTERFACES.md`. **Mainnet 4663: nothing deployed.**
2. **The stop path has fired — CLOSED.** `announceSunset`, the real 3600 s delay, `isSunset()` /
   `isSunsetEffective()`, and `cancelSunset` (on a disposable third stack, so v1/v2's one-shot hatch
   stays unspent) all ran on chain 46630 in Run 3. Note the delay used was the contract FLOOR
   (3600 s), not the mainnet 7-day value, deliberately, so the handover could be exercised
   live instead of only on a fork; the 604800 s value itself has not been timed live.
3. **`deployments/` holds several artefacts and only one is the current live record.**
   `46630.json` is Run 3 (v2's fields at top level, with `stacks.v1`/`v2`/`v3throwaway` nested
   inside); `46630.run2-stale.json` and `46630.v1-stale.json` are earlier, different contract code,
   and the `46630.fork-rehearsal*.json` files are anvil-fork records — none of these must be read as
   the live deploy record. Close by pruning or clearly marking every non-live file, and by making the
   UI and any indexer read `46630.json` only.
4. **The `developer` and `steward` addresses are now transferable (2026-09-11), not immutable —
   which changes the shape of this risk without removing it.** The script still *requires* both
   (`DEVELOPER`, `STEWARD`) at deploy, refuses a `developer` equal to the broadcasting key unless
   `ALLOW_DEV_EQ_DEPLOYER=1`, and gives `STEWARD` no default, because `address(0)` is a legitimate
   deliberate choice (audit F8). What is new: each role now moves on its own public 7-day
   announce/execute/cancel delay (§11, §M), so a bad initial choice — or a lost key — is recoverable
   without redeploying, but a *compromised* current holder can also announce a hostile transfer that
   only the current holder can cancel within the 7 days. On the current testnet stack both are still
   the deployer key with the escape hatch set — right for a throwaway run, **not** for mainnet, where
   the 2026-09-11 design decision specifies **a single cold-signer (hardware wallet) address for each, not a
   multisig** — the transfer delay is the chosen substitute for key-sharing. Close by passing
   deliberate cold-signer addresses at the mainnet deploy, recording them in `deployments/4663.json`,
   and documenting the 7-day transfer window as a monitored operational surface (a hostile transfer
   announcement is a P1 alert, exactly like a sunset announcement).
5. **The test suite asserts a split the protocol is not deployed with** (creator 10% / 71.43 / 28.57
   vs the deployed 40% / 50 / 50). Close by parameterising the fee-split tests over the deploy
   constants.
6. **Cross-version attribution has two known holes, disclosed rather than fixed** (spec §R): trust
   extends to the immediate successor only, so with three live versions a v3-routed trade is
   unattributed at v1's pools; and the last in-flight round of a sunset version can misattribute
   candidate-sentinel fees for one round. Close by measuring both on testnet, or accept and document
   in the UI.
7. **Patient TWAP dragging is still possible**, though far more expensive than the audit found: a
   drag must now survive the **7-day** average as well as the 30-minute one (every link is priced at
   `min` of the two in value terms), and even then only 10% of a generation's sleeve is drawable per
   24 h. What is *not* measured is the real cost of holding such a manipulation on a thin pool for
   days. Close by attempting a multi-day drag on a low-activity testnet pool and recording the cost
   against the sleeve it unlocks.
8. **Gas ceiling on depth is measured in Foundry, not on-chain** (~48.5k/generation; ≈8.63M for the
   band+consult chain at j = 128). Close by measuring the deepest `buyExactIn` and `deployAncestor(j)`
   that fit in a Robinhood Chain block and publishing that as the practical chain length. The
   *economic* ceiling is separately unmeasured on a real market: `Depth.t.sol` shows that eleven
   links down a pool is too small to absorb even a wei-sized bid inside the 2% cap
   (`SizeCapExceeded`), so the practical maximum useful depth is almost certainly far below the gas
   limit. Close with a deep testnet chain and real liquidity.
9. **Win-then-dump at the moment of succession is unmeasured** (question 4). Close with a scenario
   that dumps the new head immediately after `finalize()` and measures the next round's economics.
10. **No paid third-party audit.** Three independent adversarial passes (the attack-log design review,
    `docs/reviews/2026-09-11-contract-review-final.md`, and `docs/reviews/2026-09-11-contract-review-external.md`) plus 160
    tests are not a commercial audit, and **none of the fixes from either final audit have
    themselves been independently re-audited** — the same pass that found a finding cannot clear it.
    There is still no off switch if a hook bug appears: continuation only helps future pools, not
    bricked ones (§O). Close only with an external audit.
12. **The negative caches (`forwardingFailed` / `successorUnresolvable`) are still only exercised in
    Foundry — the honest handover fired live, the hostile-successor path has not.** Once armed on a
    live deployment, the ETH edge stays with the old version permanently, with no re-arm and no
    setter. Close by exercising a deliberately hostile/gas-burning successor on testnet, and by
    treating a `ProtocolFeeForwardingFailed` / `SuccessorRouterUnresolvable` event as a P1 alert in
    whatever monitoring ships with the UI.
13. **`cancelSunset` has fired — CLOSED.** Exercised on the disposable v3 stack in Run 3:
    `sunsetAt == 0`, `successor == address(0)`, `sunsetCancelled == true` verified, and v1/v2's own
    one-shot hatch was deliberately left unspent.
14. **Lazy adoption has fired — CLOSED, but only across a 3600 s delay, not a real 7-day one.** v2's
    first `registerCandidate` adopted v1's head (`adopted()` false → true, `priorIndex() = 1`) after
    a real, elapsed 3600 s `sunsetDelayS` (the contract floor, used deliberately so the
    handover could run live). The mainnet value is 604800 s and has not itself been timed live.
11. **Indexer / frontend path unbuilt** (DexScreener auto-index, GMGN listing, the 10,000-viewer load
    test in `docs/INFRA_NOTES.md`). Close during the UI phase; the contract-side prerequisites
    (`FamilyLens`, indexer-grade events) exist and are tested (`Round.t.sol::test_lensViews`).
15. **Run 3 finding: the advertised keeper sizing view (`maxParentForDeploy`) reads 0 below the
    bounty floor at beta scale — FIXED in code, not yet re-verified live.** `BidDeployer._maxEthValueFor`
    now inverts the piecewise bounty formula exactly (matching `_bounty`'s three branches), so the
    view quotes the real maximum in every regime instead of 0, and the quote is always accepted by
    `deployAncestor`'s own guard. Tests: `FeeVault.t.sol::test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor`,
    `test_deployAncestorAcceptsTheBelowFloorQuote`. Close by re-deploying (Run 4) and repeating the
    Run 3 `maxParentForDeploy(1)` call live to confirm it now quotes non-zero.
16. **Run 3 finding: the in-swap fee forward needs ~1.5M gas of headroom above the swap's own cost**,
    so an ordinary estimated-gas post-sunset trade always takes the QUEUE branch rather than
    forwarding in-swap. The queue design tolerates this, but it means `flushForward` is routine
    operator work after every sunset, not an edge case. Close by documenting this as an operational
    requirement (an operator must run periodic flushes) rather than an occasional maintenance task.
