# Dollhouse (codename Family Chain) — Protocol Specification

Status: post-audit, pre-mainnet. This document describes **the code in `contracts/` at the tree that
adds the developer vesting allocation and the transferable steward/developer/beneficiary roles**
(design decisions 2026-09-11: 3% genesis dev allocation, 1-month cliff then 12-month linear vesting,
no clawback, no acceleration; single cold-signer steward and developer address, each with a 7-day
announce/execute transfer path, replacing the earlier multisig recommendation), **183 tests, all
passing** across 24 suites — three of them new (`DevVesting.t.sol`, `DevAllocation.t.sol`,
`RoleTransfer.t.sol`) — superseding the 162-test tree that closed the gas-optimization pass, which
itself superseded the 160-test tree that closed the final external contract review
(`docs/reviews/2026-09-11-contract-review-external.md`; dispositions in `docs/attack-log.md`, "Final
external contract review"), which superseded the 145-test tree that closed the earlier
final independent contract review (`docs/reviews/2026-09-11-contract-review-final.md`). Where the code and
`docs/DESIGN_BRIEF_v2.md` / `docs/DEPLOY_CONSTANTS.md` differ, the code is described and the
difference is flagged inline as **[DIFF n]**. `script/Deploy.s.sol` binds the deploy constants; a
testnet deployment (run 4) is the current live record (§T) — see `docs/TESTNET_RUN.md` for the live
run log and `research/INTERFACES.md` for the authority on what has actually fired. Nothing has run on
mainnet 4663.

Contracts: `FamilyToken`, `FamilyFactory`, `FamilyHook`, `Locker`, `RoundManager`, `FeeVault`,
`BidDeployer`, `FamilyRouter`, `FamilyLens`, **`DevVesting`, `DevVestingDeployer`**; libraries
`CurveMath`, `StandardCurve`, `FenwickRangeAdd`; types `CurveRange`, `CurveSegment`; cross-version
interfaces `IPriorRegistry`, `IVersionFactory`, `IBidDeployer`.

**Treasury split (this change).** The keeper/bid machinery — the TWAP band guard, the active-range
size cap, the bid geometry, the cold-start curve fallback and cross-version forwarding — now lives
in its own contract, `BidDeployer`, because `FeeVault` plus the keeper machinery together were
25,550 bytes and could not be deployed under EIP-170 (docs/TESTNET_RUN.md). `FeeVault` keeps the
ledgers, accrual, forwarding and the dev/creator claims, and exposes four tightly scoped hooks —
`consumeAncestorClaim`, `consumeReinforcement`, `consumeGenesisEarmark`, `payKeeper` — that only
`BidDeployer` may call (`onlyBidDeployer`, checked against the immutable `feeVault.bidDeployer()`).
`payKeeper` is leashed by `deployerCredit`: ETH can leave the vault on the keeper path only against
a claim `consumeAncestorClaim` already deducted from a generation's own ledger in the same call, so
`BidDeployer` can never move more than a generation's own money. `BidDeployer` is immutable,
ownerless, ordinary Solidity (no assembly, no proxy), and is the *only* address `Locker.depositBid`
accepts (`NotBidDeployer` otherwise). Every place below that used to say "the vault deploys a bid"
or "the vault buys the keeper's tokens" now means `BidDeployer`; `FeeVault` never swaps and never
places liquidity, before or after this split.

**Sizes** (`forge build --sizes`, runtime bytecode, EIP-170 limit 24,576 B), the whole deployed
stack including a launched genesis and one candidate token, exactly as `CodeSize.t.sol` measures it:

| contract | runtime bytes | margin |
|---|---|---|
| `BidDeployer` | 18,373 | 6,203 |
| `RoundManager` | 13,925 | 10,651 |
| `FamilyFactory` | 13,528 | 11,048 |
| `FeeVault` | 12,402 | 12,174 |
| `FamilyHook` | 9,851 | 14,725 |
| `FamilyRouter` | 8,700 | 15,876 |
| `Locker` | 6,379 | 18,197 |
| `FamilyLens` | 5,735 | 18,841 |
| `FamilyToken` | 1,961 | 22,615 |

Every deployed contract fits comfortably under the limit, `BidDeployer` included — the split leaves
over 6.2 KB of headroom on the largest piece even after the audit fixes, versus the pre-split `FeeVault` at 25,550 B, which
exceeded the limit outright. `CodeSize.t.sol::test_everyDeployedContractFitsUnderEip170` asserts
`0 < size <= 24_576` for every one of these at once, against a stack deployed exactly the way the
deploy script deploys it (`forge test` runs with the contract-size check disabled, which is how the
pre-split regression passed 119 tests and then failed the real deploy — see `docs/TESTNET_RUN.md`).

---

## A. State machine — chain head and rounds

Two coupled machines. The **head** machine is a monotone counter over canonical indices held in
`RoundManager` (`headIndex`, `head`, `canonical(i)`). The **round** machine is a pure function of
`block.timestamp` (`RoundManager.phase(roundId)`), with no scheduler and no keeper: phases turn
over by the clock, and only `finalize()` needs a caller.

| # | State | Transition | Trigger (function) | Who can call | Guards enforced in code |
|---|---|---|---|---|---|
| 1 | Unlaunched | → Idle(head=#0) | `FamilyFactory.createGenesis(name, symbol, uri)` | anyone, once | `wire()` (FeeVault and router must have code, else `NotWired`); `priorRegistry == address(0)` else `ContinuationHasGenesis`; `_genesisToken == address(0)` else `GenesisAlreadyCreated`; `RoundManager.registerGenesis` reverts `GenesisAlreadyRegistered` if `head != 0`; hook `registerPool` is factory-only and one-shot per `PoolId`. **The curve and the initial price are computed in-contract** (§D/§E) |
| 2 | Idle(head=#N) | → Registration(round R) | `FamilyFactory.registerCandidate` → `RoundManager.openRoundIfIdle` | anyone paying the round's bond | `wire()`; `headIndex + 1 <= FenwickRangeAdd.MAX_INDEX` else `FamilyFactory.ChainDepthLimit`; `head != address(0)` else `NoGenesis`; the previous round must be `finalized`; **not sunset** else `Sunset(successor)`; a **continuation** must be able to adopt the trunk else `PriorNotHandedOver`, and — **transitively** — the prior registry itself must be a root or already `adopted()` else `PriorNotAdopted()` (audit 2); `headIndex + 1 <= MAX_INDEX` (when non-zero) else `RoundManager.ChainDepthLimit`; then `msg.value == bondWei` (the round's own `bondFor(headIndex+1)`) else `WrongBond` |
| 3 | Registration | → Registration (more entries) | same | anyone | `block.timestamp < r.registrationEnd` else `RegistrationClosed`; unlimited candidates |
| 3b | Trading (late entry, MECHANISM_v3 §2) | → Trading (new candidate) | `FamilyFactory.registerCandidate` → `RoundManager.addCandidate` | anyone paying the round's pinned bond | permitted **only when `durationFor(n) >= 1 hour`**, and only through `lateEntryUntil(n)` (a third of trading); refused outright on a short round (`RegistrationClosed`); the late entrant's own pool opens and its own 3-second snipe tax starts at THIS moment, not at `tradingStart`; scored over the identical closing window as every other candidate (§F) |
| 4 | Registration | → Trading | none — implicit at `r.registrationEnd` | clock | `FamilyHook.beforeSwap` reverts `TradingNotStarted` while `block.timestamp < p.tradingStart` |
| 5 | Trading | → Trading (scored swaps) | `PoolManager.swap` on a candidate pool, or `FamilyRouter.buyCandidate` / `sellCandidate` | anyone | pool must be `registered`; score updated in `afterSwap`; the accumulator is **never frozen or clamped by this transition** (MECHANISM_v3 §1/§3) — it keeps running past the nominal end as a public support measure (§J) and is read back through the checkpoint rings at whatever `T_end` the random end later settles on |
| 6 | Trading | → EndPending | none — implicit at `r.nominalEnd = T` | clock | nothing swapped after `T` counts toward any candidate's score (`FamilyHook.beforeSwap` still permits the swap — losers and the eventual winner alike trade right through the bell — but scoring reads for this round never look past `T`); `RoundManager.requestEnd()` becomes callable |
| 6b | EndPending | → Submission | `RoundManager.requestEnd()` then `fulfilEnd(proof)` | anyone (permissionless, two separate calls, possibly two different callers) | `requestEnd`: `block.timestamp >= r.nominalEnd`, `r.tradingEnd == 0`, once per round (`EndAlreadyRequested`) — pins a **future** drand round via `IRandomnessSource.pin()` (MECHANISM_v3 §3); `fulfilEnd`: verifies the relayed beacon proof on chain, sets `r.tradingEnd = T − (word mod randomEndWindowFor(n))` and opens the submission window from THIS moment (`r.submitEnd = now + SUBMIT_S`), not from `T` — a beacon that takes 20 minutes to arrive does not eat the window it opens |
| 6c | EndPending | → Submission (fallback) | `RoundManager.finalizeDeterministic()` | anyone | **disclosed fallback**: only after `block.timestamp >= r.nominalEnd + END_TIMEOUT` (30 min) and `r.tradingEnd == 0`; sets `r.tradingEnd = T` deterministically and emits `RandomEndUnavailable` — the randomness is simply absent for that round; needs nobody to have called `requestEnd` first |
| 7 | Submission | → Submission | `RoundManager.submitScore(candidateId)` | anyone (permissionless) | `r.tradingEnd != 0` else `EndNotSettled`; `tradingEnd <= now < submitEnd` else `OutsideSubmissionWindow`; per-candidate idempotent (`c.submitted` → no-op return); reads the candidate's **closing-window** average `[T_end − W, T_end]` out of the hook's checkpoint rings (§F) |
| 8 | Submission | → Finalizable | none — implicit at `r.submitEnd` | clock | `finalize()` reverts `SubmissionWindowOpen` before it; also reverts `EndNotSettled` if `EndPending` was never resolved |
| 9 | Finalizable | → Finalized + Idle(head=#N+1) | `RoundManager.finalize()` | anyone | `r.hasBest && r.bestAvg >= int256(r.hUsed)`; writes `canonical[N+1]`, **resets** `hWad = H_FRAC_WAD`, refunds the winner's bond, forfeits the rest |
| 10 | Finalizable | → Finalized + Idle(head=#N) | `RoundManager.finalize()` | anyone | no best, or `bestAvg < hUsed`: `hWad = max(0.9·hWad, H_MIN_FRAC_WAD)`, **all** bonds forfeited |
| 11 | Finalized | → Finalized (no-op) | `RoundManager.finalize()` | anyone | `if (r.finalized) return;` — idempotent, a stale call can never overwrite the head |
| 12 | any | → Sunset announced | `RoundManager.announceSunset(successor)` | **steward only, once** | `steward != address(0) && msg.sender == steward` else `NotSteward`; `sunsetAt == 0` else `SunsetAlreadyAnnounced`; `successor.code.length != 0` else `SuccessorHasNoCode`; **if this deployment is itself an unadopted continuation, `priorRegistry != address(0) && !adopted` reverts `NotAdopted()` (audit 2 — an unadopted intermediate must not be able to start its own sunset clock)**; takes effect at `now + sunsetDelay` (a constructor parameter — mainnet 7 days, testnet 1 hour, floor `MIN_SUNSET_DELAY = 1 hours`, §C) |
| 12b | Sunset announced | → back to normal | `RoundManager.cancelSunset()` | **steward only, once in the deployment's life** | `msg.sender == steward` else `NotSteward`; `sunsetAt != 0 && block.timestamp < sunsetAt && !sunsetCancelled` else `SunsetNotCancellable`; clears `sunsetAt` and `successor` and sets `sunsetCancelled` forever (`Sunset.t.sol::test_cancelSunsetWorksBeforeTheEffectAndNotAfter`, `test_cancelSunsetNeedsAnAnnouncement`) |
| 13 | Sunset effective | → no further rounds | `openRoundIfIdle` | — | `isSunset()` reverts `Sunset(successor)`, **but only in the "open a new round" branch**: a round already open still registers, trades, is scored, finalizes and crowns a head (`Sunset.t.sol::test_aRoundOpenWhenTheSunsetLandsStillFinishesAndCrowns`) |
| 14 | any | trading on a canonical or losing pool | `PoolManager.swap` | anyone | never gated after `tradingStart`; losers' pools live forever and keep paying hop fees |

**MECHANISM_v3 (design decisions 2026-09-12, `docs/MECHANISM_v3.md`) inserted phases 3b and
6b/6c above** on top of the state machine already described. Nothing about the ORIGINAL phases moved:
registration still opens the round, trading still starts at `registrationEnd`, and `finalize()` is
still the only place the head moves. What changed is (i) a long round (`durationFor(n) >= 1 hour`)
now accepts new candidates during trading itself, and (ii) the fixed public `T_end` of the old design
is now a **nominal** end `T`, with the **true** end settled afterwards by a verifiable drand relay or,
failing that, a disclosed deterministic fallback (§C, §F). Every one of `durationFor`, `registrationFor`,
`lateEntryUntil` and `closingWindowFor` is a pure function of the round number alone
(`Schedule.t.sol::test_theScheduleTableIsExact`), so nobody — steward included — can change any round's
timing after the fact.

Head mutation happens in exactly one place: the winner branch of `finalize()`. There is no other
writer of `_canonical`, `headIndex`, `head`, `_parentOf`, `_indexOf`, `_isCanonical` — except
`_adoptIfContinuation()`, which a **continuation** deployment runs once, inside its first
`openRoundIfIdle`, to copy the prior registry's final head into `_head` / `_headIndex` /
`_priorIndex` (event `ContinuationAdopted`). It is a *copy at a moment the prior head can no longer
move*, never a rewrite of an index.

**[DIFF 1]** The brief lists a standalone `openRound()`. The code has none: a round is opened as a
side effect of the first `registerCandidate`, through the factory-only `openRoundIfIdle()`.

**Continuation (forward upgrade), with LAZY HEAD ADOPTION (audit F1).** A deployment constructed
with `CONTINUE_FROM = priorRegistry` owns indices `priorIndex + 1 ..` only — but it does **not**
read the prior head at construction. The constructor stores `priorRegistry`, checks the prior has a
head at all (`BadContinuation`), emits `ContinuedFrom`, and stops. `adopted` is false, and while it
is false **every** read of this contract — `head()`, `headIndex()`, `priorIndex()` included —
delegates to the prior registry, which is still live and still crowning.

The trunk is adopted in `_adoptIfContinuation()`, called from the first `openRoundIfIdle()`, and
only if all three of the following hold at that instant, else `PriorNotHandedOver`:

1. `prior.isSunsetEffective()` — the prior version's sunset (`sunsetDelay`, mainnet 7 days, testnet
   1 hour) has actually landed, so it can
   never open another round;
2. `prior.successor() == address(this)` — this is the deployment the steward named, not a squatter;
3. `prior.isIdle()` — `roundCount == 0 || rounds[roundCount].finalized`, i.e. the prior has no round
   that could still crown a link.

Only then are `priorIndex`, `headIndex` and `head` written from `prior.headIndex()` /
`prior.headToken()`. **There is therefore no window in which two versions can crown the same
canonical index**, and v2 can open no round at all before the handover. The old constructor-time
adoption forked the trunk at *every* v1 win during the delay; that is the bug this closes. Tests:
`Continuation.t.sol::test_v2CannotOpenARoundBeforeTheHandover`,
`test_v2AdoptsTheHeadV1CrownedAfterV2WasDeployed`.

**Transitive adoption guard (audit 2).** Condition 3 alone left one gap: v1 could be idle and
sunset-effective while itself being an *unadopted* continuation of an even earlier v0 — i.e. a v1
that has never opened a round of its own, only reports idle. v3 could then adopt v2's head through
a v2 that had never actually adopted v1's trunk, forking the canonical history one link further
back. `_adoptIfContinuation` now also requires `prior.priorRegistry() == address(0) ||
prior.adopted()`, else `PriorNotAdopted()`; `announceSunset` refuses the same shape on the deployment
announcing it (`priorRegistry != address(0) && !adopted` → `NotAdopted()`), so an unadopted
intermediate can neither be adopted through nor start its own sunset clock. Tests:
`Continuation.t.sol::test_v3CannotAdoptThroughAnUnadoptedV2`,
`test_adoptionRefusesASunsetButUnadoptedPrior`.

Once adopted, the stack starts at the prior head's index and token.
`createGenesis` is dead in a continuation stack (`ContinuationHasGenesis`,
`Continuation.t.sol::test_v2CannotCreateAGenesis`). Every canonical read
(`canonical`, `poolKeyOf`, `indexOf`, `parentOf`, `creatorOf`, `isCanonical`, `genesisToken`)
first resolves *which* registry owns the entry (`registryOf(index)` / `registryOfToken(token)`,
`ownsToken`) and then delegates, bounded at `MAX_CONTINUATION_HOPS = 8` registries
(`ContinuationDepthLimit`). Tests: `test_v2StartsAtTheInheritedHead`,
`test_delegatedReadsForPriorIndices`, `test_v3ContinuingV2ResolvesPriorIndicesThroughTwoHops`,
`test_v2RoundCrownsLinkTwoQuotedInV1sHead`, `test_routeFromEthAcrossBothVersions`,
`test_lensChainViewSpansVersions`.

**Liveness dependency.** Nothing advances a round automatically. If nobody calls `submitScore`
during the 300 s window, the round finalizes with no winner even if a candidate cleared `H`; if
nobody calls `finalize()`, the chain stays in `Finalizable` forever and no new round can open
(`openRoundIfIdle` requires the previous round `finalized`). Both calls are permissionless and
economically motivated (the winner's creator wants the slot and the bond back), but neither is
guaranteed.

---

## B. Token lifecycle

`FamilyToken` is an OpenZeppelin `ERC20` plus `IBurnableERC20`. `TOTAL_SUPPLY = 1e9 * 1e18`
(file-level constant `FAMILY_TOTAL_SUPPLY`). There is no owner, no minter, no pauser, no
blacklist, no fee-on-transfer, no transfer hook.

**Every family token is an EIP-1167 minimal proxy (`Clones.clone`) of one sealed implementation.**
The implementation is deployed once, at deployer **nonce n+0**, immediately BEFORE the
`FamilyFactory` (nonce n+1), with the factory's predicted address baked in as its `factory`
immutable — a clone has no constructor, so this is the only way every clone can delegatecall to
the same, correct authorization. The implementation's own constructor sets `_initialized = true`
and mints nothing, so it is permanently sealed and holds no supply; a clone starts with empty
storage and is therefore un-initialized until the factory calls it. The factory verifies the link
back in its own constructor (`implementation.factory() == address(this)`, else
`BadTokenImplementation`), so a mismatched implementation/factory pair can never be wired up.

1. `FamilyFactory` clones the implementation (`Clones.clone(tokenImplementation)`) and calls
   `initialize(name, symbol, uri, address(locker), devRecipient, devAmount)` on the clone.
   `initialize` is **factory-only** (`NotFactory`) and **one-shot** (`AlreadyInitialized`): the whole
   fixed supply is minted there, in the clone's own storage — `devAmount` of it to `devRecipient`
   (the genesis `DevVesting` contract) and the rest to the Locker. `name`/`symbol` live in the
   clone's own storage (`_tokenName`/`_tokenSymbol`, read back by `name()`/`symbol()` overrides)
   rather than the ERC20 base's, because the base's constructor — the only place vanilla `ERC20`
   can set them — never runs on a clone.
2. **Genesis only, the developer allocation.** `FamilyFactory.createGenesis` computes
   `devAmount = devAllocation() = FAMILY_TOTAL_SUPPLY * DEV_ALLOCATION_BPS / BPS` (deploy constant
   300 bps = 3%), deploys a fresh, immutable `DevVesting` contract through the one-function
   `DevVestingDeployer` (kept out of the factory's own init code for EIP-3860 — see §T), and mints
   `devAmount` of the genesis token straight to it; `IFeeVault(feeVault).developer()` is snapshotted
   as the vesting contract's initial beneficiary. The remaining **97%**
   (`genesisTokensForSale() = FAMILY_TOTAL_SUPPLY - devAllocation()`) is what actually goes on the
   curve — see §E for how the segment shares apply to that reduced sale supply, not the full 1e9.
   **Every candidate token still gets `devAmount = 0`, `devRecipient = address(0)`: 100% of a
   candidate's supply is locked liquidity, exactly as before.** `DevAllocationVested(vesting, amount,
   cliff, duration)` is emitted once, at genesis, alongside `GenesisCreated`. Tests:
   `DevAllocation.t.sol::test_genesisSupplyIsConserved`,
   `test_vestingIsWiredToTheGenesisTokenAndTheDeveloper`, `test_candidatesHaveNoAllocationAtAll`,
   `test_genesisEmitsTheDevAllocationEvent`.
3. The factory registers the exact `PoolKey` + `initSqrtPriceX96` with the hook, calls
   `PoolManager.initialize`, then `Locker.placeStandardCurve`.
4. The Locker mints the curve positions through `PoolManager.modifyLiquidity` inside one
   `unlock`, settles the token side, and **burns whatever is left**: `dust = token.balanceOf(this);
   IBurnableERC20(token).burn(dust)`. After launch no family supply exists outside locked
   liquidity and the vesting contract — the only token holders are the PoolManager, the `DevVesting`
   contract (genesis only) and traders who bought from the curve.
5. Supply is fixed downward-only afterwards: the public `burn(uint256)` lets any holder destroy
   their own balance. `invariant_supplyIsConstant` asserts constancy over the fuzz campaign,
   because the launch dust burn happens before the handler ever sees the token.

ERC20 semantics are otherwise unchanged; the implementation is the only address EIP-170 binds on
(each clone is 45 runtime bytes), which is why the whole family-token line was moved out of full
per-token deployments (`CodeSize.t.sol::test_everyDeployedContractFitsUnderEip170` asserts both
that the implementation fits under EIP-170 and that every genesis/candidate token is a 45-byte
proxy).

Losing candidates' tokens are never destroyed or reclaimed; their pools remain tradeable forever
with the same locked curve, and keep paying hop fees into their parent's reinforcement pot.

---

## B.1 Developer vesting

`DevVesting` (deployed once per genesis, by `DevVestingDeployer`) is the whole developer allocation:
no owner, no pause, no clawback, no acceleration. Nobody — beneficiary included — can change the
schedule, revoke it, or move a token out ahead of it. The only thing that can ever move is **who**
receives a release, and that moves on the same public 7-day delay as the steward and developer roles
(§M).

**The allocation is not stored as a number.** `total() = token.balanceOf(this) + released`, so it is
always exactly what the contract has ever held; the constructor takes `(token, beneficiary, start,
cliff, duration)` and mints nothing itself — the factory mints `devAmount` to the freshly deployed
contract in the same transaction.

**Schedule, exactly.**

```
vested(t) = 0                                    t <  start + cliff
vested(t) = total() · (t − start) / duration      start + cliff <= t < start + duration
vested(t) = total()                               t >= start + duration
```

The linear accrual is measured **since `start`**, not since the cliff, so the cliff does not unlock
zero: at `t = start + cliff` the vested amount is already `total() · cliff / duration`, the whole
amount that would have accrued linearly over the elapsed cliff period. At the mainnet constants
(`VESTING_CLIFF_S = 30 days`, `VESTING_DURATION_S = 365 days`) the cliff releases `30/365 ≈ 8.2%` of
the allocation in one step, not zero and not a thirteenth — a common mistake this contract's own
`natspec` calls out explicitly. `start` is the genesis creation timestamp (`block.timestamp` at
`createGenesis`), immutable, never re-derived. Tests:
`DevVesting.t.sol::test_nothingVestsBeforeTheCliff`, `test_theCliffUnlocksWhatAccruedSinceStart`,
`test_linearBetweenCliffAndEnd`, `test_everythingVestedAtTheEndAndNeverMore`.

**Release.** `release()` is **permissionless** — `releasable() = vested(now) − released` is paid to
the *current* `beneficiary` regardless of who calls, so there is nothing to gain by calling it for
someone else and no reason to gate it. `NothingToRelease` if there is nothing new to pay. Calling
twice pays only the delta each time (`test_releaseTwicePaysTheDeltaOnly`).

**No clawback, no acceleration — structurally, not by convention.** There is no owner-only function
anywhere in the contract, no pause, no way to revoke unvested tokens back to the factory or the
developer's old address, and no way to speed the schedule up. The only functions that exist are
`release()` (permissionless payout) and the three beneficiary-transfer functions below; nothing else
touches `start`, `cliff`, `duration` or the released/unreleased split.

**Beneficiary transfer — announce → wait `ROLE_TRANSFER_DELAY` (7 days) → execute.** Identical shape
to the steward and developer transfers (§M): `announceBeneficiaryTransfer(to)` — current beneficiary
only, `to != address(0)`, one pending transfer at a time (`TransferPending`) —
`executeBeneficiaryTransfer()` — **permissionless**, callable once `block.timestamp >=
beneficiaryTransferAt`, so an incoming beneficiary can take the role even if the outgoing key is
lost — `cancelBeneficiaryTransfer()` — current beneficiary only, repeatable. This is the "pathway to
security upgradability" required in place of a multisig: a lost key is recoverable before
the cliff without giving anyone power over the schedule itself. Tests:
`DevVesting.t.sol::test_beneficiaryTransferWaitsOutTheDelay`,
`test_onlyTheBeneficiaryAnnouncesOrCancels`, `test_cancelTakesTheAnnouncementBack`,
`test_badScheduleIsRefused`.

---

## C. Round lifecycle — timestamps, phases, functions

**MECHANISM_v3 (design decisions 2026-09-12) supersedes the fixed `TRADING_S = 900` / fixed public
end below with an adaptive schedule and a random true end.** Every value is a pure function of the
round number `n`, computed once (`RoundManager.durationFor/registrationFor/lateEntryUntil/
closingWindowFor/scoreSlotFor`), and — apart from the mainnet-vs-testnet `DURATION_SCALE_DIV`
constructor divisor described below — none of it can be changed after deploy.

**Adaptive duration.** `D(n) = min(15 min × 2^floor((n−1)/2), 12 h)` (`BASE_TRADING_S`,
`MAX_TRADING_S`), `R(n) = clamp(D(n)/5, 3 min, 1 h)` (`MIN_REGISTRATION_S`, `MAX_REGISTRATION_S`):

| Round `n` | `D(n)` | `R(n)` | Late entry |
|---|---|---|---|
| 1–2 | 15 min | 3 min | no |
| 3–4 | 30 min | 6 min | no |
| 5–6 | 1 h | 12 min | first 20 min of trading |
| 7–8 | 2 h | 24 min | first 40 min |
| 9–10 | 4 h | 48 min | first 80 min |
| 11–12 | 8 h | 1 h (cap) | first 2 h 40 min |
| 13+ | 12 h (cap) | 1 h (cap) | first 4 h |

**Late entry.** `lateEntryUntil(n)` returns `D(n)/3` when `D(n) >= LATE_ENTRY_FROM_S = 1 hour`, else 0
(`RegistrationClosed` on a short round). A late entrant posts the round's same pinned bond and its
pool opens the instant it registers (its own 3-second snipe tax runs from that moment, not from
`tradingStart`); it carries no scoring penalty of its own kind — it is scored over the identical
closing window as everyone else and simply has less time to build the level that window measures.

**The closing window `W` — what actually decides a round.** `closingWindowFor(n)` is
`CLOSING_WINDOW_S / DURATION_SCALE_DIV` and **does not depend on `n` at all**: a FLAT 15 minutes on
every round (2026-09-12; it used to be `D(n)/4` above an hour — 2 h → 30 min, 12 h → 3 h). A candidate's score
is its average net parent absorption over **`[T_end − W, T_end]`**, not the whole round — see §F.
Late entry always closes (`D/3`) strictly before the closing window's earliest possible start
(`D − W − RANDOM_END_S`), so no candidate is ever scored over a span that begins before its own pool
opened (`Schedule.t.sol::test_lateEntryAlwaysEndsBeforeTheClosingWindowStarts`).

**Random end, `T_end = T − (r mod randomEndWindowFor(n))`, `RANDOM_END_S = 180`.** The round has a public
nominal end `T = tradingStart + D(n)`. At `T`, anyone calls `requestEnd()`, which pins a **future**
drand round via `IRandomnessSource.pin()` — a round number that has not been produced yet, so nobody,
including the operator, can know `T_end` before `T`. Once that beacon round exists, anyone relays its
signature to `fulfilEnd(proof)`; the source verifies it on chain (§N, `contracts/randomness/`) and
`fulfilEnd` derives `tradingEnd` and opens the 300 s submission window from the moment of fulfilment,
not from `T`. **Timeout fallback, disclosed:** if nobody has relayed a verifiable beacon within
`END_TIMEOUT = 30 min` of `T`, anyone may call `finalizeDeterministic()`, which settles
`T_end = T` and emits `RandomEndUnavailable(roundId, T, submitEnd)` — the randomness is simply
absent for that round; the round always finalizes, it never hangs on the beacon
(`Schedule.t.sol::test_anUnrelayedBeaconEndsTheRoundAtTLoudly`,
`test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd`). `randomEndWindowFor(n) = min(RANDOM_END_S,
D(n))` so a heavily testnet-scaled round shorter than 180 s still draws from its own whole length,
never from a span longer than the round.

**`DURATION_SCALE_DIV`** (mainnet `1`, a `RoundManager` constructor parameter, `ALLOW_SCALED_SCHEDULE`
gate) divides `D`, `R` and the late-entry window uniformly, so a testnet run can exercise a 12-hour
schedule inside minutes; it never scales `RANDOM_END_S` — the random-end span is capped at the
(already scaled) duration instead, floored at 1 (never a zero-length window). Tests:
`Schedule.t.sol::test_theScheduleTableIsExact`, `test_theScheduleIsCappedForever`,
`test_theClosingWindowTable`, `test_anOpenedRoundUsesItsOwnRowOfTheTable`,
`test_lateEntryIsRefusedOnAShortRound`, `test_lateEntryIsAcceptedInTheWindowAndRefusedAfterIt`,
`test_aLateEntrantWithTheSameClosingSupportScoresTheSame`, `test_supportSoldBeforeTheBellDoesNotCount`,
`test_theEndCannotBeRequestedBeforeTheNominalEnd`, `test_theEndIsPinnedOnceAndOnlyOnce`,
`test_theTrueEndFallsInTheLastThreeMinutes`, `test_nothingSettlesUntilTheEndIsKnown`,
`test_theSubmissionWindowStartsAtFulfilment`, `test_theEndCannotBeSettledTwice`,
`test_theDeterministicFallbackIsRefusedBeforeTheTimeout`.

Deploy constants in `RoundManager`: `REGISTRATION_S = 180`, `SUBMIT_S = 300`, decay `9/10` — these
remain the round-1 row of the adaptive schedule above, kept as named constants because they are also
the deploy floors. **`sunsetDelay` is now a constructor parameter, not a fixed
constant (audit 2).** It is set from `SUNSET_DELAY_S` (deploy default 7 days), floored at the
immutable `MIN_SUNSET_DELAY = 1 hours` — the constructor reverts `BadSunsetDelay` below it. Mainnet
is deployed at 7 days; testnet is deployed at 1 hour, precisely so a testnet run can exercise
sunset → handover → adoption → forwarding live instead of waiting a real week (the 7-day handover
had never fired in production). Test: `Continuation.t.sol::test_sunsetDelayIsAConstructorParameter`.

**The bond is depth-scaled (audit F6), not a single constant.** `bondFor(targetIndex) =
min(BOND_BASE_WEI << (targetIndex / BOND_DOUBLING_EVERY), BOND_MAX_WEI)`, with the three parameters
immutable constructor arguments (testnet: base 0.001 ETH, doubling every 4 links, max 0.064 ETH;
`BOND_DOUBLING_EVERY == 0` disables the schedule and makes `BOND_MAX_WEI` the flat bond). The shift
saturates at the cap rather than overflowing, so `bondFor(1_000_000) == BOND_MAX_WEI`. A round pins
its bond when it opens (`r.bondWei = bondFor(headIndex + 1)`), **every candidate stores the bond it
actually paid** (`Candidate.bond`), and the winner's refund and the losers' forfeiture use that
stored amount — a later schedule change (there is none; the parameters are immutable) could never
retroactively re-price a posted bond. `currentBond()` is the value a registrant must send right now:
the open round's `bondWei`, or `bondFor(headIndex + 1)` when the chain is idle. Rationale: a link is
worth 5–8% of its parent in ETH and clearing `H` costs under $1 from generation 3, so **from about
generation 3 the bond is the binding cost of extending the chain** — a flat ETH bond would make
depth free. Tests: `Depth.t.sol::test_bondDoublesEveryFourLinksAndIsCapped`,
`test_theBondIsEnforcedRefundedAndForfeitedAtTheScheduledAmount`.

```
openedAt          = block.timestamp of the first registerCandidate
registrationEnd   = openedAt + registrationFor(n)
tradingStart      = registrationEnd                  (shared by every candidate in the round)
nominalEnd (T)    = tradingStart + durationFor(n)    (public from the moment the round opens)
tradingEnd        = T - (r mod randomEndWindowFor(n))    (T_end, settled by fulfilEnd/finalizeDeterministic, §C above)
submitEnd         = tradingEnd + 300                 (starts at settlement, not at T)
```

Late entrants (round `n` with `durationFor(n) >= 1 hour`) register through `lateEntryUntil(n)` of
trading and get their own `tradingStart = block.timestamp` of registration for snipe-window purposes
only — the round's single `nominalEnd`/`tradingEnd`/closing window `[T_end − W, T_end]` (§F) apply
identically to every candidate regardless of when its own pool opened.

`Round.hUsed` is snapshotted at open (`r.hUsed = threshold()`), so a later decay cannot move the bar
a candidate was competing against. `r.parentIndex` / `r.parentToken` pin the numeraire for the whole
round. Events `RoundOpened` and `TradingStarted` are both emitted at open, because trading start is
a timestamp, not a call.

Functions, in order: `FamilyFactory.registerCandidate` (payable, bond) → swaps on the candidate
pools during `[tradingStart, ∞)` (scored only until `T_end`; `FamilyRouter.buyCandidate` /
`sellCandidate` refuse anything but `Phase.Trading`) → `RoundManager.submitScore` →
`RoundManager.finalize`. Reads for the UI come from `FamilyLens.roundView(roundId, offset, limit)`
(paginated candidates with score, spot price and tokens sold), `FamilyLens.candidateView` and
`FamilyLens.chainView(from, to)` — the last of which spans continuation versions
(`Continuation.t.sol::test_lensChainViewSpansVersions`).

---

## D. Candidate eligibility

There is no whitelist, no signature, no allowlist and no reputation check. The complete set of
conditions for entering a round:

- **Factory-only tokens.** A candidate must be created by `FamilyFactory.registerCandidate`, which
  deploys the `FamilyToken` itself. An externally deployed token can never be a candidate: the
  hook's `beforeInitialize` rejects any `PoolKey` the factory did not pre-register
  (`PoolNotRegistered`) and rejects a registered key initialized at any price other than the
  registered one (`WrongInitialPrice`); `beforeAddLiquidity` rejects any adder except the Locker
  (`OnlyLocker`). A candidate pool is therefore, by construction, a fixed-supply factory token on
  the standard curve at the standard price.
- **Bond.** `msg.value == r.bondWei` (the round's own `bondFor(headIndex + 1)`, §C) or `WrongBond`,
  checked in `FamilyFactory.registerCandidate` against what `openRoundIfIdle` returned and again in
  `addCandidate`. The bond is escrowed in `RoundManager` by `addCandidate{value: msg.value}` and
  stored per candidate.
- **Registration window.** `block.timestamp < r.registrationEnd`, checked twice (in
  `openRoundIfIdle` for a joining registrant and again in `addCandidate`).
- **Chain depth — two independent caps, both refused at the door.** (1) The structural one:
  `FamilyFactory.registerCandidate` requires `headIndex + 1 <= FenwickRangeAdd.MAX_INDEX` (4095),
  else `FamilyFactory.ChainDepthLimit` — the refusal happens at registration instead of bricking a
  swap later (L6, `RoundGuards.t.sol::test_registrationRefusesToExceedTheChainDepthLimit`).
  (2) The policy one: `RoundManager.MAX_INDEX`, an immutable constructor parameter from the
  `MAX_INDEX` env var (`0` = unlimited, the testnet value). `openRoundIfIdle` reverts
  `RoundManager.ChainDepthLimit` when the next index would exceed it, so a **capped beta** keeps the
  chain inside the depth range the simulations cover. It is a deploy constant and can never be
  raised (`Depth.t.sol::test_maxIndexRefusesTheRoundThatWouldGoPastIt`,
  `DeployConstants.t.sol` asserts the testnet value is 0).
- **Wiring.** `wire()` asserts the FeeVault and the router have code before any launch
  (`NotWired`, `GenesisCurve.t.sol::test_wireRefusesAHalfDeployedStack`).
- **Numeraire.** The pool is always `candidate ⇄ current head`. The child address may sort either
  side of the parent, so `tokenIsCurrency0 = token < parent` and both curve orientations are built
  by `StandardCurve.build(..., tokenIsCurrency0)` (`Mirrored.t.sol`).
- **No cap** on entries per round or per address. Sybil entry costs `n × r.bondWei` plus gas.

**Genesis is no longer caller-parameterised** (C2, closed). `createGenesis(name, symbol, uri)` takes
no price, no ranges and no supply argument: the curve and `initSqrtPriceX96` are derived in-contract
by `StandardCurve.build(curveSpec(), GENESIS_UNIT, FAMILY_TOTAL_SUPPLY, TICK_SPACING, false)` — the
identical call `registerCandidate` makes, with the immutable `GENESIS_UNIT` standing in for the
parent supply. Genesis is ETH-paired, so the token is always `currency1`. Whoever calls first gets
the creator attribution **and nothing else**: no caller can move the price a single tick.
`FamilyFactory.genesisCurve()` exposes exactly what will be placed, before genesis exists.
Tests: `GenesisCurve.t.sol::test_twoCallersGetAnIdenticalGenesisCurve`,
`test_genesisCurveIsTheStandardShapeInGenesisUnits`.

---

## E. Curve equations and parameters

**Frame.** `CurveMath` documents both orientations explicitly. With the family token as
`currency1` (always true for genesis, since native ETH is `address(0)` and sorts first), pool price
`P = amount1/amount0 = supply/FDV`, so a *higher* valuation is a *lower* tick, unsold inventory is
`currency1`-only liquidity strictly below spot, and buying is `zeroForOne`. Mirrored
(`tokenIsCurrency0 == true`), higher FDV is a higher tick and inventory sits above spot.

**Closed forms.**

```
sqrtPriceAtFdv(fdv, supply, tokenIsCurrency0=false) = sqrt(supply/fdv) · 2^96
sqrtPriceAtFdv(fdv, supply, tokenIsCurrency0=true)  = sqrt(fdv/supply) · 2^96
fdvAtSqrtPrice = the exact inverse, computed as two FullMath.mulDiv halves to avoid overflow
```

Both revert `InvalidFdvRange` on zero inputs or a price outside `[MIN_SQRT_PRICE, MAX_SQRT_PRICE)`.

**Snapping.** `rangeFromShare` converts an economic segment ("share `s` of supply between `fdvLower`
and `fdvUpper`") into a `CurveRange`. Both tick bounds are floored to the pool's spacing with
`floorToSpacing` (sign-correct: it decrements the quotient for negative non-multiples), so segments
sharing an FDV boundary stay exactly contiguous, with no gap and no overlap. `EmptyRange` if the
snapped bounds collapse. Liquidity is `LiquidityAmounts.getLiquidityForAmount0/1` over
`amount = supply · s / 1e18` — the range holds its share of supply, and the economic identity is
that buying the range out costs `s · sqrt(Fa · Fb)` of parent, evaluated at the *snapped* bounds.
`CurveMath.t.sol::test_buyingOutARangeCostsSqrtFaFb` proves this against a real pool swap.

**Ladder (deploy constant, "MID").** `FamilyFactory` stores a `CurveSegment[]` given at construction
and validated once by `StandardCurve.validate`: shares must sum to exactly `1e18`, and bands must be
ascending and contiguous (`spec[i].fdvRatioLowerWad == spec[i-1].fdvRatioUpperWad`). Bounds are
**multiples of the parent supply**, which is what makes the curve self-similar down the chain.
`script/Deploy.s.sol::standardCurveSpec()` and `FamilyTestBase._standardCurveSpec()` are identical:

| segment | share | FDV band (× parent supply) |
|---|---|---|
| 1 | 20% | 1e-3 → 1e-2 |
| 2 | 25% | 1e-2 → 1e-1 |
| 3 | 35% | 1e-1 → 1 |
| 4 (tail) | 20% | 1 → 100 |

At the threshold a winner has sold ≈38% of supply with ≈11% embedded backing (`DEPLOY_CONSTANTS.md`);
Sim 1 on MID measures a median 60.2% of float sold for the 9.0×-of-threshold *total* absorption an
actual win requires.

**Genesis curve.** The same spec with `GENESIS_UNIT = 1000 ether` in place of a parent supply:
start FDV 1 ETH, ladder to 1,000 ETH, tail to 100,000 ETH. `GENESIS_UNIT` is an immutable factory
constructor parameter, rejected at zero (`BadGenesisUnit`). **The FDV bands stay denominated in the
whole 1e9 supply — the developer allocation does not shrink what "1,000 ETH" or "the tail to 100,000
ETH" means.** What shrinks is the token quantity locked in each range: `StandardCurve.build` is
called with `saleSupply = genesisTokensForSale() = FAMILY_TOTAL_SUPPLY − devAllocation()` (97% of
supply at the 300 bps deploy constant), so each segment's share (20/25/35/20%) is a share of the
97%-of-1e9 actually placed on the curve, not of the full 1e9. Candidates are unaffected:
`registerCandidate` always calls `StandardCurve.build` with `saleSupply == FAMILY_TOTAL_SUPPLY`,
because a candidate has no developer allocation at all (§B).

`StandardCurve.build` returns the ranges plus `initSqrtPriceX96`: exactly the top of the first
range in the genesis frame, and one wei of sqrt price *below* the bottom of the first range in the
mirrored frame, so in both cases every range is strictly out of range on the token-only side and no
parent is ever owed at placement. `tickSpacing = 60`; `POOL_FEE = 0` (all fees are hook-charged).

**Dust burn.** Rounding in `getLiquidityForAmount*` leaves a remainder of the 1e9 supply outside the
positions; `Locker.placeStandardCurve` burns it and reports it
(`CurvePlaced(poolId, rangeCount, tokenPlaced, dustBurned)`).

---

## F. Winner score

The score is computed inside the hook, on swap deltas only — never on transfers, donations
(disabled) or balances.

```
afterSwap:    parentDelta = the SWAPPER's parent-side delta of this swap
_updateScore: acc += R · (now − tLast);  tLast = now;  R += (−parentDelta)
```

**`R` is the pool's own parent delta — the net parent that stays in the pool (C1, fixed).** v4
applies a `beforeSwap` return delta *before* the pool swap, so a parent-side fee skimmed in
`beforeSwap` is already excluded from `parentDelta`; a parent-side fee charged in `afterSwap` is
applied after `delta` is computed and so is likewise not in it. **No fee adjustment is made in
either direction**, and the transient skim slot the previous version used is gone. `R` is `int128`
and signed (sells reduce it); `acc` is its time integral in parent-units·seconds. `p.tLast` is
initialised to `tradingStart` at registration, so the accumulator measures the full synchronized
window, not "since the first swap".

**v4 protocol-fee subtraction from the score (audit 9, conditional).** Uniswap v4's own
protocol-fee controller (§T, an address the protocol does not control) can charge up to a further
`ProtocolFees` cut on top of the pool's own fee, *inside* the same swap, before the hook's `afterSwap`
delta is computed — so if that controller is ever configured on a candidate's pool, the score would
otherwise be inflated by exactly that cut, since it is parent that entered the pool's accounting but
never entered the candidate's own liquidity. `_updateScore` now snapshots
`poolManager.protocolFeesAccrued(parent)` in `beforeSwap` (`_setPreProtocolFees`) and subtracts the
swap's increase, `_protocolFeeTaken(parent) = protocolFeesAccrued(parent) − preSwapSnapshot`, from
`R` in `afterSwap`: `scored = −traderParentDelta − hookFee − v4ProtocolFeeTaken`. On the deploy chain
the controller is unset and this term is always zero; the subtraction is a no-op guard against a
future or third-party configuration change, not a currently-active adjustment. Test:
`HookScore.t.sol::test_aV4ProtocolFeeDoesNotInflateTheScore`.

Exact `R` is pinned in all four orientations and inside the snipe window by `test/HookScore.t.sol`:

| test | what it pins |
|---|---|
| `test_scoreExactInParentSpecified` | `R = amountIn − fee` exactly (the case the old code double-subtracted) |
| `test_scoreExactOutParentSpecified` | `R = −traderParentDelta − fee` |
| `test_scoreExactInParentUnspecified` | the same identity with the fee charged in `afterSwap` |
| `test_scoreExactOutParentUnspecified` | the same identity, mirrored |
| `test_scoreIsAdditiveAcrossOrientations` | buys add, sells subtract, across swaps |
| `test_snipeWindowBuyScoresPoolDeltaAndNeverGoesNegative` | at `tradingStart`, with a 99% snipe tax plus the hop fee, a 1e18 buy scores exactly `0.009e18` — positive, never negative |
| `test_snipeDecayMovesTheScoreNotTheSign` | the same buy 2 s later scores strictly more |

**MECHANISM_v3 (design decisions 2026-09-12) replaces the freeze-at-`T_end`/full-round-average model
below with a closing-window average read out of a checkpoint ring, because `T_end` is no longer known
in advance and the accumulator is never frozen at all — see below and §J for why: the same running
accumulator keeps running after the round as a public support measure.**

**No freeze; the accumulator runs forever.** `_updateScore` keeps accumulating exactly as described
above — buys add, sells subtract, fee-exclusive by construction (C1) — with **no clamp, no freeze,
and no `ScoreFrozen` event tied to any round timing**. There is nothing for a swap after the round's
nominal end `T` to be a no-op against: it simply keeps updating the same accumulator `trailingAverage` reads
from for the rest of the chain's life (§J).

**Checkpoint rings, TWO per pool off the one accumulator (MECHANISM_v3 §3).** Each ring slot holds
the accumulator state immediately BEFORE the first swap of that slot; a slot with no swap needs no
entry, because `R` is constant between swaps and the state is reconstructed exactly. **Fast ring:**
36 slots × 5 s = 180 s, exactly `RANDOM_END_S`, so wherever `T_end` lands inside the last 3 minutes it
resolves to 5-second precision. **Coarse ring:** 64 slots at `scoreSlotFor(n) = ceil((W + RANDOM_END_S
+ END_TIMEOUT + SUBMIT_S) / 63)` each, so the ring reaches back over the whole closing window plus the
whole settlement tail. The `END_TIMEOUT` term is review-2: `fulfilEnd` has no deadline, so a round can
be settled as late as `T + END_TIMEOUT` and its submission window then runs to
`T + END_TIMEOUT + SUBMIT_S`, while the far edge of the window is still `T − W − RANDOM_END_S`.
With `W` flat at 15 min and `END_TIMEOUT = 30 min` the requirement is 900 + 180 + 1800 + 300 = 3180 s on
every round, met by `ceil(3180/63) = 51` s slots and 63 x 51 = 3213 s of ring. The previous sizing
(1380 s, 22 s slots, 1386 s of ring) covered a PROMPT settlement only: a round whose beacon was never
relayed had lost the far edge of its own closing window by the time it could be scored
(`Review2.t.sol::test_aScoreSurvivesAFullBeaconTimeoutOfRingChurn`). The only inexactness is a
second swap inside the same slot as an edge, where the PRE-swap state is used, which never counts flow
LATER than the edge (`Schedule.t.sol::test_theRingReconstructsExactlyAcrossGaps`,
`test_aSlotIsWrittenOnceByItsFirstSwap`).

**`FamilyHook.averageOver(id, tStart, tEnd)` — the closing-window average.** `RoundManager.submitScore`
calls it with `tStart = max(0, T_end − W)`, `tEnd = T_end`; it reconstructs the accumulator state at
both edges from the rings and returns `(avg, tLastBefore)` — `tLastBefore` playing the role
`tFirstAttained` played before: the last real score update at or before `tEnd`, i.e. when the final
average was first reached. A candidate that registered after `T_end − W` (only reachable on a heavily
scaled testnet schedule) scores from its own `tradingStart` rather than reverting
(`Round.t.sol` / `Schedule.t.sol::test_aLateEntrantWithTheSameClosingSupportScoresTheSame`). Support
sold back before the bell does not count toward the average, because the window measures a LEVEL —
what a candidate still holds when the window closes — not a total
(`Schedule.t.sol::test_supportSoldBeforeTheBellDoesNotCount`). `finalize()` still compares
`bestAvg >= int256(hUsed)`: average absorption against `H` in parent tokens, same units as before
(attack-log finding 7), just averaged over `W` instead of the whole round.

**`tFirstAttained`.** `RoundManager.submitScore` takes this directly off `averageOver`'s second
return value (`tLastBefore`): the last score update at or before `T_end`, i.e. the moment the final
average was first reached (L4, documented). It is a block timestamp, not a manipulable hash.

**Tie rule** (`RoundManager._beats`): higher `avg`; then earlier `tFirstAttained`; then lower
`uint256(poolId)`. Deterministic in that order — the pool id is consulted only when both the average
and the attainment second are identical.

**Spike arithmetic.** Because the score is an average over the closing window `W` (a flat 15 min,
§C), adding `x%` to a rival's average needs `x% · W` second-equivalents of capital; one second of
capital contributes `1/W` of itself. At the original fixed 900 s window Sim 4's `late_spike` variant
topped the round 0% of the time at the same cost as the winning strategy; Sim 13 (§S) re-measures the
closing-window rule directly and finds the opposite failure mode still open by design — a **window
sniper** who arrives at the start of `W` with the leader's own capital and holds it wins ≈82–93% of
the time, because the rule rewards whoever is highest AT THE END, not whoever led longest (disclosed
in §R/§U, not a bug).

---

## G. Canonical finalization

`finalize()` is `nonReentrant`, permissionless, deterministic and idempotent. It operates only on
`roundCount` (the newest round); an older unfinalized round cannot exist, because
`openRoundIfIdle` refuses to open a new one until the current one is finalized.

**MECHANISM_v3: `finalize()` first requires the end to be settled.** `r.tradingEnd == 0` reverts
`EndNotSettled` — either `fulfilEnd(proof)` (a verified drand relay, §C) or `finalizeDeterministic()`
(the disclosed 30-minute timeout fallback) must have run first, and `block.timestamp >= r.submitEnd`
must hold measured from whichever of those settled the end, not from the round's nominal end `T`.
Once settled, `finalize()` itself is otherwise unchanged: it still reads only `r.hasBest`/`r.bestAvg`
from `submitScore`'s running best, still writes the head in exactly one branch, and a winning round
now also records that generation's round (`_roundOfIndex[newIndex] = roundId`, §J) so its siblings —
this winner and every candidate that lost the same round — can be found forever from the moment it
crowns.

Order of operations: set `r.finalized = true` (effects first) → decide the winner → mutate the head
or decay `hWad` → emit `RoundFinalized` → then the only two external calls, both value transfers:
`feeVault.depositGenesisBidEarmark{value: forfeited}()` and the winner's bond refund.

**Bond flows.** `forfeited = r.candidateCount · r.bondWei`, minus the winner's own stored `w.bond`
if there is a winner (every candidate of a round pays the same pinned amount, so the two agree). The
winner's creator is refunded by push (`call{value: w.bond}`); if the push fails the amount is
booked to `pendingRefund[creator]` and can be pulled with `claimRefund(to)` — so a reverting creator
contract cannot brick finalization
(`RoundGuards.t.sol::test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth`).
Forfeited bonds become `FeeVault.genesisBidEarmark`, later deposited as a locked ETH bid under
genesis by `deployGenesisBid()`.

**Threshold.** `threshold() = head.totalSupply() · hWad / 1e18`, i.e. `H` is an *average* absorption
in parent tokens. On a failed round `hWad = max(hWad·9/10, H_MIN_FRAC_WAD)`. **On a win
`hWad = H_FRAC_WAD`** — the decay compounds only across *consecutive* failed rounds.
Deploy values: `H_FRAC_WAD = 1.5e15` (0.15% of parent supply) and `H_MIN_FRAC_WAD = 3.75e14`
(0.0375%, i.e. 0.25·h), both `RoundManager` constructor arguments, immutable thereafter
(`Round.t.sol::test_noWinnerDecaysThresholdToTheFloor`).

**[DIFF 3 — narrowed]** `docs/sim-results-final.md` now runs the MID configuration with
`--reset-on-win` (its deploy-configuration table states "H snaps back to H0 on a win, in both the
real `RoundConfig` and Sim 2's reduced form"), so the deployed rule and the simulated rule agree.
Sim 2's own *modelling note* in that file still reads "H persists across wins (brief section 2 only
ever decays it)" — a stale sentence contradicting the report's own configuration table. The liveness
figures quoted in §S are the MID/reset numbers from the summary table.

**L10, accepted and documented.** `H` is a fraction of the head's **live** `totalSupply()`, and
`FamilyToken.burn` is permissionless, so a head holder can lower the next bar by burning. Burning
`x` costs full market value and lowers `H` by only `h·x` (15 bps at deploy) — ~667× the relief
bought — while making every remaining holder richer per token
(`RoundGuards.t.sol::test_burningHeadSupplyLowersThreshold`).

---

## H. Routing

`FamilyRouter` is immutable, permissionless and **not fee-privileged**; it pays exactly the fees a
direct `PoolManager.swap` pays.

- `buyExactIn(targetIndex, minOut, to, maxHops)` — path `[ETH, 0, 1, …, targetIndex]`; requires
  `msg.value != 0` (`WrongValue`).
- `sellExactIn(targetIndex, amountIn, minOut, to, maxHops)` — the reverse path, ending in `ETH`.
- `swapPath(path, amountIn, minOut, to, maxHops)` — an arbitrary list of canonical indices with the
  `ETH` sentinel (`type(uint256).max`) allowed at either end. Adjacency is enforced per leg
  (`to == from+1`, `from == to+1`, or the ETH↔0 genesis leg) else `NonAdjacentPath`.
- `buyCandidate(candidateId, minOut, to, maxHops)` / `sellCandidate(candidateId, amountIn, minOut,
  to, maxHops)` (M4) — the canonical chain plus one extra hop into the candidate's own pool,
  refused only while the candidate's round is still `Registration` or `Idle` (`NotTrading`) — i.e.
  before its pool's own hook gate has opened — and requires `candidateId < candidateCount()`
  (`UnknownCandidate`). **Candidate routes survive the round (audit 8, fixed).** `_candidateRoute`
  resolves the pool's parent from the index the ROUND recorded (`roundManager.roundInfo(c.roundId)
  .parentIndex`), which is immutable once written, not from the *current* head — so a losing
  candidate's pool stays tradeable through this router **forever**, exactly like a canonical link.
  Before this fix the route walked the current head, which after the round is some other token, so
  every post-round candidate route reverted and the only exit was an unattributed third-party swap
  that paid the candidate's creator nothing. Tests:
  `RouterGuards.t.sol::test_buyAndSellCandidateWithEth`, `test_unknownCandidateIsRejected`,
  `test_candidateRoutesAreHopCapped`.
- `buyCandidateWithParent(candidateId, parentAmount, minOut, to)` — the attributed way to absorb a
  candidate with the HEAD token the caller already holds, one hop (`head -> candidate`), pulling
  `parentAmount` from `msg.sender` with `transferFrom` (must be approved to the router first).
  Without it the only *attributed* candidate route was ETH-in, which re-buys the whole canonical
  chain a round participant has already bought; the unattributed alternative (a stock router) pays
  the candidate's creator, the head's creator and the ancestor sleeve nothing. There is no canonical
  chain to walk here and therefore no `maxHops` — the route is one leg. Tests:
  `RouterGuards.t.sol::test_buyCandidateWithParentIsAttributedAndPullsHeadTokens`,
  `test_buyCandidateWithParentCountsTowardTheRoundScore`,
  `test_buyCandidateWithParentRespectsTheTradingWindow`.
- `maxHops` is the caller's depth cap. On the canonical entrypoints, `path.length - 1 > maxHops`
  reverts `TooManyHops`; on `buyCandidate` / `sellCandidate` the candidate leg is **counted**, so the
  whole route (`path.length` hops, canonical legs plus the candidate leg) is checked against the same
  `maxHops` (`RouterGuards.t.sol::test_candidateRoutesAreHopCapped`). There is no protocol-imposed
  maximum; the real ceiling is gas and price impact. `buyCandidateWithParent` takes no `maxHops`: its
  route is always exactly one hop.

**Value checks (M1).** `swapPath` requires `msg.value == amountIn` on an ETH-first path and
`msg.value == 0` otherwise (`WrongValue(sent, expected)`), so `amountIn` can never be spent out of
ETH the router happens to hold (`RouterGuards.t.sol::test_swapPathRequiresMatchingValueOnAnEthRoute`,
`test_swapPathRejectsValueOnATokenRoute`). **There is no `receive()`**: a plain ETH transfer to the
router reverts, so nothing can be parked there to be swept later
(`test_routerHeldEthCannotBeSwept`).

**Settlement.** The whole route runs inside **one** `unlock` (nested unlocks revert in v4). Each leg
is exact-in against the extreme price limit. Both terminal deltas are read *before* either is acted
on (L12), so a round trip (`ETH → … → ETH`) reports the last leg's output rather than its own netted
zero (`test_roundTripPathReportsItsOutput`). Intermediate legs are supposed to net to zero; a
partial fill anywhere in the middle leaves a residue, and `_sweepResiduals` takes every **positive**
residual (including the candidate tail currency) to `to`, while a **negative** one is a named
`IntermediateDeficit(pathIndex, amount)` rather than an opaque `CurrencyNotSettled`
(M5, `test_midRoutePartialFillSettlesEveryCurrency`). Unused ETH on a partially filled first leg is
refunded to `msg.sender` (`RefundFailed` if that call fails). `minOut` is checked after the unlock
returns.

**`sync(native)` before native settlement (audit 7B).** `PoolManager` keeps one transient
"currency-being-settled" snapshot at a time, taken by `sync`. If a successor (or any contract
reachable in the same unlock — another leg of a route, a hook) called `poolManager.sync(someERC20)`
and this router's own leg then tried to `settle()` **native ETH** without re-`sync`ing first, the
manager would credit the ETH against the *stale* ERC-20 snapshot rather than against native currency
— breaking every later native settlement in the same unlock. Both `FamilyRouter` and `Locker` now
call `poolManager.sync(CurrencyLibrary.ADDRESS_ZERO)` immediately before every native `settle()`,
even though syncing native is a no-op for the manager's reserve accounting (it costs one transient
write and closes the hole unconditionally, rather than trying to detect whether some other actor
disturbed the snapshot). Test:
`Sunset.t.sol::test_aSuccessorSyncingAnErc20DoesNotBreakNativeSettlement`.

**Attribution.** `hookData = abi.encode(terminalIndex)`, the family end of the path, or
`CANDIDATE_ATTRIBUTION (1 << 255) | candidateId` for the candidate entrypoints.
`FamilyHook._attribution` trusts it **only** when `hookData.length >= 32` and
`sender == router` **or** `sender == _successorRouter()`. The successor router is resolved lazily —
`factory.roundManager()` → `isSunsetEffective()` → `successor()` → `successor.factory()` →
`.router()` — and **every leg is a `staticcall{gas: STATIC_GAS = 30_000}`** whose result is checked
(`!ok || ret.length != 32` ⇒ `address(0)`), so a successor that reverts, answers nonsense or burns
gas costs the swap at most a few tens of thousands of gas instead of 63/64 of everything (audit F2).
**Dirty-word validation (audit 7A).** A well-formed 32-byte return whose top 96 bits are non-zero
(`0xdead...` padding, or any malformed address encoding) used to be handed to `abi.decode(ret,
(address))`, which **reverts** on a non-zero-padded word — turning every attributed third-party route
into a failing transaction the instant a successor's `router()` answered with dirty bits, however it
did so. Every leg now reads the raw returned `bytes32` and validates it by hand: `word >> 160 != 0`
is treated as "no answer" (`address(0)`) rather than decoded, so a dirty word costs the same as a
`staticcall` failure — a few tens of thousands of gas, no revert. Test:
`Sunset.t.sol::test_aDirtyWordSuccessorCannotBrickRoutes`.
A positive resolution is cached write-once in `successorRouter`; a **negative** one — the sunset is
effective and the chain did not resolve — is cached once in `successorUnresolvable` (event
`SuccessorRouterUnresolvable`), so the resolution is never re-paid on a later swap. Before the
sunset takes effect nothing is resolved and nothing is cached, because the steward may still
`cancelSunset()`. `_successorRouter()` returns `address(0)` until this version's sunset takes
effect. Test: `Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps` (a candidate-pool swap
against a gas-burning successor stays under 1M gas, and the resolution is never retried). A
copycat router passing identical hookData is credited nothing
(`Router.t.sol::test_hookDataOnlyTrustedFromTheCanonicalRouter`,
`Swap.t.sol::test_attributionOnlyFromRouter`). Direct `PoolManager` swaps are fully supported and
pay identical fees; they are simply unattributed.

No best-route logic is on-chain: sourcing the parent from an external venue is expected, and is the
mechanism Sim 3 / Sim 7 rely on to keep deep routes usable.

---

## I. Fee semantics

All fees are charged by the hook on the **parent side** of the swap (native ETH on the genesis
pool). The pool LP fee is 0. **Every rate is in parts per million** (`PPM_DENOM = 1_000_000`),
because 7.5 bps is not representable in integer basis points (L8, closed — the old `hopFeeBps`
[DIFF 4] is gone).

| fee | rate | where | applies to |
|---|---|---|---|
| protocol fee | `PROTOCOL_FEE_PPM = 10_000` (1%) | `_collect`, only if `p.isGenesis` | the ETH side of every genesis-pool swap, entry **and** exit |
| hop fee | `hopFeePpm` (immutable ctor arg; **deploy value 750 ppm = 7.5 bps**, capped at `MAX_HOP_FEE_PPM = 10_000` = 100 bps, else `HopFeeTooHigh`) | `_collect`, every pool | the parent side of every family swap, genesis leg included |
| snipe tax | `SNIPE_START_PPM = 990_000` → `SNIPE_END_PPM = 10_000` linearly over `SNIPE_S = 3` s, then 0 | `_snipeTaxPpm(p.tradingStart)` | candidate pools only (`tradingStart != 0`); genesis is never sniped |

`total = hopFee + protocolFee + snipeFee`, all computed on the same `parentAmount`. Family↔family
swaps pay **no** protocol fee at all (`invariant_noProtocolFeeOnFamilyPools`,
`Round.t.sol::test_routedBuyChargesProtocolFeeOnlyOnTheGenesisLeg`). The test harness deliberately
runs at `HOP_FEE_PPM = 1_000` (10 bps) so the arithmetic is legible in assertions; the deploy
constant is 750 ppm.

**Exact-in / exact-out.** v4 lets a hook take a delta on the specified currency only in
`beforeSwap` and on the unspecified currency only in `afterSwap`, so both paths exist:

- parent is the **specified** currency (exact-in buy paying parent; exact-out sell for parent) —
  charged in `beforeSwap` as a positive specified delta `toBeforeSwapDelta(total, 0)`: skimmed off
  the input on exact-in, added on top on exact-out. The pool therefore only ever sees the net
  parent, which is exactly what §F scores.
- parent is the **unspecified** currency (exact-in sell for parent; exact-out buy paying parent) —
  charged in `afterSwap` as the returned `int128` delta, computed from the actual `BalanceDelta`.

**Rate basis, both modes, both sides (audit F9 — fixed).** Every parent-side rate (snipe, hop,
protocol) is a fraction of the trader's TOTAL parent-side amount, identically in both swap modes.
Where `_collect` is handed the trader's own gross (exact-input paying parent; exact-input sell
receiving parent) the rates apply directly. Where it is handed the **pool's** side of an exact-output
swap — the exact-output buy's pool cost, and the exact-output *sell*'s requested receipt — the basis
is **grossed up first**: `basis = poolCost / (1 − rate)`, fee `= poolCost · rate / (1 − rate)`. The
old code added `poolCost · rate` on top instead, which made the effective rate only `rate / (1 + rate)`
— 49.7% instead of 99% at the snipe start, and half the intended tax on an exact-output sell. A
parent-paying exact-output swap whose rates sum to ≥ 100% has no finite gross-up and is refused with
`SnipeExactOutputTooLarge`; it is unreachable at the deploy constants (99% + 1% + 750 ppm = 100.075%
is reachable only in the first instant of the snipe window on the genesis pool, and only with the
hop fee at its `MAX_HOP_FEE_PPM` ceiling — `SnipeTax.t.sol::test_exactOutRevertsWhenRatesReachOneHundredPercent`).
Covered by `Swap.t.sol::test_buyExactIn_chargesEthSideFees`, `test_sellExactIn_chargesEthSideFees`,
`test_buyExactOut_chargesEthSideFees`, **`test_sellExactOut_chargesTheSameFeeBasisAsExactIn`**, and
`SnipeTax.t.sol::test_snipeTaxIdenticalForExactInAndExactOut`,
`test_afterWindowBothModesPayOnlyTheHopFee`. L1 (documented): on a partially filled exact-in the fee
is taken on the full `amountSpecified`.

**ERC-6909 claims.** The fee is minted to the vault as a PoolManager claim
(`poolManager.mint(feeVault, parent.toId(), total)`), not `take`n — on the input side the manager
does not yet hold the trader's funds and `take` would revert. `FeeVault.redeem(currency)` is
permissionless and converts claims into a real balance with `burn` + `take` inside its own `unlock`;
the claim and keeper paths call it before paying out. `holdings(currency)` = real balance +
unredeemed claims, which is what the solvency invariant is measured against.

**No sell-side asymmetry.** Buys and sells pay the same rates (Sim 6 keeps 1%/1%).
---

## J. Fee recipients

`FeeVault.accrue(currency, parentToken, hopFee, protocolFee, terminalIndex, attributed)` is
hook-only (`NotHook`) and is the single write path into the ledgers from a swap.

**Hop fee and snipe tax** → `reinforcementBalance[parentToken]`, denominated in exactly the currency
a bid under that pool needs (`address(0)` for the genesis/ETH pool), so it never needs converting.
Losing candidate pools feed the same bucket as the head they were parented at. This share **never
forwards across a sunset**: it reinforces a pool only the charging version's Locker can add
liquidity to.

**Protocol fee** splits in `_book`, floor-divided with the last bucket taking the remainder so the
parts sum exactly to the fee (`test_allocationSumsExactly`):

```
dev       = fee · DEV_BPS/1e4                  DEV_BPS = 2000 (20%), a constant
creator   = attributed ? fee · CREATOR_BPS/1e4 : 0      CREATOR_BPS = 4000 (40%) at deploy
rest      = fee − dev − creator
sleeve    = rest · ANCESTOR_BPS/1e4            → Fenwick ancestor sleeve over [0, M]   (20% of fee)
reinforce = rest − sleeve                      → reinforcementEth[M]                    (20% of fee)
```

**Attribution resolution** (`_resolveAttribution`), two shapes:

- a canonical index `i <= headIndex` → credit `canonical(i)`, `M = (i == 0 ? 0 : i − 1)`;
- `CANDIDATE_ATTRIBUTION | candidateId` with `candidateId < candidateCount()` → credit the
  **candidate's own token**. **While the candidate's round is still `Phase.Trading`**, the round's
  recorded parent is a co-creditee of half the creator share (below) and `M = parentIndex`.
  **After the round ends (audit 8)**, there is no contest left to share: `coCreditToken =
  address(0)` and the candidate's own creator takes the **whole** creator share, still with
  `M = parentIndex` pinned to the round's recorded parent — so trading a losing candidate's pool
  post-round is now attributed exactly like trading any canonical link, just against a different
  base token.

Anything else — including the `UNATTRIBUTED = type(uint256).max` sentinel a forwarded-but-untrusted
fee carries — is unattributed: `creator = 0`, `M = 0`, so the whole flywheel share lands on genesis
(`test_unattributedFeesFallBackToGenesis`). The developer's 20% is paid on every protocol fee,
attributed or not.

**Head-creator season cut.** When a co-creditee exists the creator share is split **50/50**:
`coCredit = creator / 2` to the round's parent creator, the remainder to the candidate's creator.
This is reached through `buyCandidate` / `sellCandidate` / `buyCandidateWithParent` while
`roundManager.phase(c.roundId) == Phase.Trading`; once the round ends, the same routes remain
tradeable (audit 8, §H) but pay **100%** to the candidate's own creator, not 50/50, because there is
no longer a contest to share the round's parent with. A **losing** candidate's creator keeps
whatever was credited during the round — nothing is clawed back. Tests:
`RouterGuards.t.sol::test_candidateBuySplitsTheCreatorShareWithTheHeadCreator`,
`test_canonicalBuyPaysTheWholeCreatorShareToThatLinksCreator`,
`test_losingCandidateCreatorKeepsTheirHalf`.

**Ancestor polynomial.** `FenwickRangeAdd` keeps three signed Fenwick trees over the generation
index holding the coefficients of `c0 + c1·j + c2·j²`; a sleeve is one range-add over `[0, M]` and a
payout is one point query — O(log N), with no loop over ancestry. Weights are `w(r) = 2 − 5r + 4r²`
with `r = j/M`, normalised by `Z(M) = (M+1)(5M+4)/(6M)`, so `a = sleeve/Z(M)`, `c0 = 2a`,
`c1 = −5a/M`, `c2 = 4a/M²`, WAD-scaled. The trees **must** be signed: `c1` is negative and tree 1's
intermediate prefix sums legitimately go below zero. `M == 0` is the genesis-only case. Every
division floors, so the point queries sum to slightly *less* than the sleeve; the residue stays in
the vault forever and is never claimable, which keeps solvency true by construction.
`MAX_INDEX = 4095` caps the chain at 4096 links (`IndexOutOfRange`; registration refuses first, §D).
Verified by `test_fenwickPointQueriesMatchBruteForceLedger` and
`test_ancestorWeightShapeAndConservation` (w(0) = 2·w(M), minimum at r = 5/8, never over-allocated).

**Claims.** `claimDev(to)` — `msg.sender == developer` (immutable, no transfer function).
`claimCreator(token, to)` — `msg.sender == creatorRecipient(token)`, which defaults to
`RoundManager.creatorOf(token)` and can be moved with `transferCreatorRecipient(token, to)`.
**Transferring the right sweeps what has already accrued to the OLD recipient's own claimable
balance, not to the new one, and refuses the zero address (fixed, spec discrepancy).** Previously the
transfer silently handed the whole unclaimed `creatorBalance[token]` to the new recipient and
accepted `to == address(0)`, which burned the stream. Now `transferCreatorRecipient` moves only the
FUTURE stream: at the moment of transfer the current `creatorBalance[token]` is added to
`creatorAccrued[currentRecipient]` and zeroed, `to == address(0)` reverts, and the old recipient
claims the swept amount with `claimCreatorAccrued(to)` — a separate, permanently claimable ledger
keyed by the address that held the right at the moment of each transfer, so an OLD recipient's
earlier accrual survives even a later, second transfer. `claimDev`, `claimCreator` and
`claimCreatorAccrued` are all `nonReentrant` and `notInsideUnlock`, zero the relevant ledger before
sending (CEI), decrement `ledgerTotal`, redeem claims, then push ETH. Tests: `test_devAndCreatorClaims`,
`test_creatorRecipientIsTransferable`,
`test_transferringTheCreatorRightLeavesAccruedFeesBehind`.

### The purse (MECHANISM_v3 §1) — `BidDeployer.deployAncestor`

**The ancestor sleeve (§ above) is deployed under exactly one pool: `canonical(j)`, the trunk link
that won round `j`.** Review 3 (maintainer decision 2026-09-13) removed the contest: there is no
ranking, no board, no staleness and no split. A generation is still the round winner plus every
candidate that lost the same round (`RoundManager.roundOfIndex(i)`), and pairing rights and the
season cut still lock at finalization (§A/§G) and stay with the round winner permanently. The purse
now does the same.

**The call is `BidDeployer.deployAncestor(uint256 j, uint256 parentAmount)`.** It reverts
`UnknownGeneration` for `j == 0` (genesis takes ETH directly) or an unminted `j`, prices
`parentAmount` at `min(spot, TWAP30, TWAP7d)` up the chain exactly as before, draws
`ethValue + bounty` from generation `j`'s ETH sleeve inside the daily bucket, and locks the whole
`parentAmount` (plus whatever room the size cap leaves for the generation's own parent-denominated
hop pot) as a bid just below spot in `j`'s pool. It emits
`PurseDeployed(generation, trunk, parentDeposited)` alongside `AncestorDeployed`. The destination is
not an argument: a keeper supplies a generation and an amount and can influence nothing else.

**What the purse is, stated plainly.** A purse deployment is a **permanent buy wall under the coin
that won its round**. The parent tokens bought are locked as a bid range under `canonical(j)` running
from just under spot down to roughly 6% below it (`BID_WIDTH_SPACINGS = 10` tick spacings from the
spot tick), are never withdrawn, and are a bid, not a lock-up: the coin's own holders can sell into
them at those prices at any time. Two limits keep a deployment from being usable as a shove: the
active-range size cap (`MAX_RESERVE_BPS = 200`, 2% of the target range's parent reserve per
deployment) and the vault's 24-hour drawdown bucket (`DAILY_DRAW_BPS = 1000`, 10% of the
generation's accrued ETH per day). This is not a property review 3 introduced: the reinforcement
share (20% of the fee, § fee split) has been deployed as locked bids under the parent from the
start, and making the ancestor sleeve uncontested extends the same property from 20% to 40% of the
fee. Keeping the value on the canonical chain in that form is the intended design outcome.

**Pricing, precisely (correction).** Two different prices are involved and they are not the same
walk. (1) **How much ETH leaves the sleeve** is decided by pricing `parentAmount` along the links
`0..j-1`, each hop at `min(spot, TWAP30, TWAP7d)` (`ethValueOfParent`), the conservative direction
for the vault. (2) **Where the bid sits** is decided by the trunk pool itself: `_requireWithinBand`
requires its spot *sqrt* price to be within `TWAP_BAND_BPS = 300` (3%, about 6% in price terms) of
its OWN 30-minute TWAP, and `_bidTicks` then reads the live spot tick from the PoolManager and
places the range immediately beneath it. The trunk pool's 7-day TWAP does not set the bid.

**Losing siblings.** A loser stays tradable, keeps the creator share of its own pool's fees
(§ creator split, audit 8) and can be bought and sold forever. It never receives purse liquidity.

**Why (MECHANISM_v3 §1).** Keeping the value on the canonical chain, where every deeper generation
trades through it; one sentence to publish instead of five; and a dumped or abandoned trunk coin is
for its own community to take over rather than for the protocol to penalise.

**Previously (review 2, superseded).** `RoundManager.rank(candidateId)` measured a sibling's
trailing support out of the hook into a two-seat board per generation; `purseWeights(j, idA, idB)`
verified the pair, refused a board older than `RANK_MAX_AGE = 6 h` with `BadRanking`, and returned
the weights the purse split by; `deployAncestor` took `(j, amount, idA, idB)` and placed two bids,
emitting `PurseSplit`. All of it is removed in review 3. `FamilyHook.trailingAverage` remains, as a
public view that nothing pays out on.

Tests: `Purse.t.sol::test_thePurseIsDeployedUnderTheTrunkCoin`,
`test_aLosingSiblingNeverReceivesPurseLiquidity`, `test_theDestinationIsNotAKeeperChoice`,
`test_anUnknownGenerationIsRefused`, `test_genesisIsNotAnAncestorDeployment`,
`test_theAmountConserves`, `test_theBountyRuleIsUnchanged`, `test_theDailyBucketStillBounds`;
`properties/Purse.prop.t.sol::testFuzz_PUR02_theDestinationIsAlwaysTheTrunk`,
`testFuzz_PUR04_theAmountConserves`, `testFuzz_PUR05_theBucketAndBountyAreUnchanged`;
`fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing`.

### The keeper model (H1/H2/H3/M2/M3, rewritten) — now `BidDeployer`

**Neither `BidDeployer` nor `FeeVault` ever swaps.** The earlier design routed generation `j`'s ETH
up the chain through the router with `minOut = 0` (j swaps + 2(j+1) consults per call — a gas wall
near generation 60–120 and an unpriceable trade). Instead the **keeper supplies the parent tokens**
and `BidDeployer` buys them at the chain's own TWAP, out of ledgers `FeeVault` already owed
generation `j`:

```
(ethValue, slowMissing) = ethValueOfParent(j − 1, parentAmount)   O(j) view calls, no swap, no unlock
bounty   = max(ethValue · BOUNTY_BPS/1e4, MIN_BOUNTY_WEI)         BOUNTY_BPS = 100 (1%)
bounty   = min(bounty, ethValue · MAX_BOUNTY_SHARE_BPS / (BPS − MAX_BOUNTY_SHARE_BPS))   ≤ 20% of the ETH consumed
payout   = ethValue + bounty
deposit  = parentAmount + consumeReinforcement(parent, cap − parentAmount)
```

**Bounty floor and cap (audit 5).** The plain 1% bounty is negative-sum at small deployment sizes —
Run 2 measured gas ≈215× the bounty at `j = 1` and 121 wei of bounty at `j = 8`. `bounty = max(1% of
ethValue, MIN_BOUNTY_WEI)`, a `BidDeployer` constructor argument (`MIN_BOUNTY_WEI` env var; testnet
`3e14` = 0.0003 ETH), still paid **on top of** the deployment out of the same generation's ETH
entitlement. The floor is capped so it can never eat the whole entitlement: `bounty <= ethValue ·
MAX_BOUNTY_SHARE_BPS / (BPS − MAX_BOUNTY_SHARE_BPS)`, i.e. `bounty` is never more than
`MAX_BOUNTY_SHARE_BPS = 2_000` (20%) of `payout = ethValue + bounty` — algebraically exactly
`bounty <= ethValue · 2000/8000`. **Disclosed dead zone:** where a deployment is small enough that
the floor would be most of it, the 20% cap binds instead and the bounty is 20% of what the call
consumes — more than the nominal 1%, but still below mainnet gas at the smallest sizes, so a keeper
calling at those sizes still loses money and must be funded or skipped; this is disclosed, not
fixed, because the floor cannot be raised further without eating a whole small generation's sleeve.
Tests: `Keeper.t.sol::test_theBountyFloorIsPaidAtRunTwoSizes`,
`test_belowTheFloorTheBountyIsCappedAtTwentyPercent`.

**Pricing walks the AMOUNT, not a rate (audit F3 — fixed).** `ethValueOfParent(j, amount)` starts
with `ethValue = amount` and walks links `k = 0..j`, applying each link's parent-per-token factor as
**two independent full-precision `FullMath.mulDiv`s** — `(Q96/twap)²` when the parent is currency0,
`(twap/Q96)²` when it is currency1 — so neither the square nor a normalised per-link rate is ever
materialised. `parentForEthValue(j, ethValue)` is the same walk inverted step by step.
`ethPerTokenWad(j)` still exists, but only as the convenience view `ethValueOfParent(j, 1e18)`; at
depth it legitimately reverts `BadConversionRate` because one WAD of a deep link really is worth
less than a wei, which is exactly why the keeper paths convert the real amount instead.
The old implementation multiplied a WAD-normalised rate per link, lost ~4 significant digits per
generation and **reached zero around j ≈ 10**, so every deeper generation's ETH sleeve was
permanently unspendable — measured, reproduced and asserted in
`Depth.t.sol::test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed`, which builds a chain of
twelve links, shows the old rate collapsing, shows `ethPerTokenWad(7)` still reverting, and then
runs a real `deployAncestor(8)` that pays a non-dust amount out of generation 8's own sleeve. The
conversion is linear in the amount to within 2 wei at eleven links deep.

**Per-link price: `min(spot, TWAP_30m, TWAP_7d)` in VALUE terms (audit F4, sharpened by audit 1).**
`_priceFor` starts from whichever of the fast average (`consult`, 1800 s) and the slow one
(`consultSlow`, `SLOW_TWAP_WINDOW = 7 days`) values the link **lower** — the *higher* sqrt price when
the parent is currency0, the *lower* when it is currency1 — exactly as F4 fixed it. **Audit 1:** that
alone left a hole. A crash in a *conversion* pool (one of `0..j−1`, not the target) moved neither
average for up to half an hour, so the vault kept paying the old, pre-crash price for a parcel that
was worth a fraction of it — measured at ≈1.01× the old value for a parcel now worth ≈0.1× of it.
`_priceFor` now also reads the pool's own spot price and, if spot values the link *even lower* than
the min of the two averages, uses spot instead — a non-zero spot can only ever **lower** a payout
relative to the averages, so folding it into the same `min` cannot be used to extract more, it can
only close the crash window. A 30-minute pump of a thin ancestor pool still cannot **raise** what the
sleeve pays (the averages still floor it upward); a crash lowers it immediately instead of waiting
for the slow ring to catch up. A pool with less than `SLOW_TWAP_MIN_COVERAGE = 1 day` of slow history
has nothing to floor with: the call is priced on `min(spot, fast average)` and says so loudly —
`ethValueOfParent` returns `slowMissing = true` and `deployAncestor` emits
`SlowTwapUnavailable(j)`. The ±3% band guard is unchanged: it still checks only the **target** pool
`j`, because the min-of-three rule is what bounds every conversion-link price now, not the band.
Tests: `Keeper.t.sol::test_aThirtyMinutePumpCannotRaiseWhatTheSleevePays`,
`test_aYoungPoolPricesOnTheFastAverageAndSaysSo`, `test_aCrashedConversionPoolIsPricedAtSpot`.

- **`BidDeployer.deployAncestor(j, parentAmount)` - permissionless, `nonReentrant` (signature
  narrowed by MECHANISM_v3 §1 in review 3).** Reverts `UnknownGeneration` for `j == 0` (genesis takes
  ETH directly) or an unminted `j`. The keeper must have approved `BidDeployer` (not the
  vault) for `parentAmount` of `canonical(j − 1)`. The whole deposit goes into `j`'s own pool, under
  `canonical(j)`: a caller supplies a generation and an amount and can choose nothing else (previous
  subsection). Every pool `k = 0..j−1` whose price enters the conversion must have a usable TWAP (the coverage
  guard below); **the ±3% band is checked on the TARGET pool `j` only** (audit F5 — requiring j+1
  pools to be simultaneously in band made the path progressively uncallable with depth, and a stale
  ancestor price is already bounded by the min-of-three rule above). A zero final value reverts
  `BadConversionRate`. The payout comes out of `j`'s own ETH
  (`FeeVault.claimableEth(j) = claimableAncestor(j) + reinforcementEth[j]`), bounded by the 24 h
  drawdown allowance `FeeVault.drawableEth(j)`, and that allowance must cover the **whole** payout
  including the bounty, else `TooMuchRequested`. `BidDeployer` draws it via
  `FeeVault.consumeAncestorClaim(j, payout)` (credits `deployerCredit`) and
  `FeeVault.consumeReinforcement(parentToken, cap - parentAmount)`, then pays the keeper with
  `FeeVault.payKeeper(msg.sender, payout)` — both `FeeVault` calls are `onlyBidDeployer`.
- **`BidDeployer.deployHopPot(j)` — the terminal generation's hop pot (audit 3).** The chain's head
  (the newest link, at `MAX_INDEX` or simply the current head) has no descendant round and therefore
  no ETH entitlement of its own to draw a bounty from, so before this its accumulated
  parent-denominated hop fees and snipe tax (`FeeVault.reinforcementBalance[parent]`) could never be
  deployed — permanently, for as long as it stayed the head. `deployHopPot(j)` is permissionless and
  deploys generation `j`'s hop pot **on its own**, with **no ETH entitlement involved at all**:
  `min(pot, bidCap(j))` of the parent-denominated pot is locked as a bid under `j`, and the bounty is
  paid **in the same parent token**, out of the same pot, not in ETH. It works for any generation, not
  only the head, and composes with `deployAncestor`/`deployGenesisBid` (which still draw the
  ETH-denominated pots). Test: `Keeper.t.sol::test_theHeadsHopPotDeploysWithNoEthEntitlement`.
- **Drawdown allowance is a token bucket, not a resetting window (audit F4, then audit 6).** The
  original F4 limit was a resetting 24 h window that snapshotted a base at the window's start —
  which let ≈19% of a generation's ETH out in seconds if a request landed exactly on a window
  boundary (one draw just before the old window closed, another just after the new one opened),
  contradicting the "10% per rolling 24 hours" the docs promised. `FeeVault.drawBucket(j)` /
  `drawableEth(j)` now implement a genuine **token bucket**: `available = min(DAILY_DRAW_BPS/1e4 ·
  claimableEth(j), available + DAILY_DRAW_BPS/1e4 · claimableEth(j) · dt / 24h)`, refilling
  **continuously** rather than snapping to a fixed base at a window edge. A bucket has no boundary to
  sit on, so there is no instant at which two draws can double up. `DAILY_DRAW_BPS = 1_000` (10%) of
  what is claimable **right now**. A request beyond what the bucket holds reverts
  `DailyLimitExceeded(requested, allowed)`. `drawableEth(j)` is the public "how much can be spent
  right now" view a keeper must size against; `drawBucket(j)` exposes `(updatedAt, available, cap)`.
  A dust bucket whose 10% floor-divides to zero is allowed in full, so a few wei can never become
  permanently unspendable. Effect: a price manipulation that survives all three prices in the min
  still cannot drain a generation in one block, or in a burst at a window edge — the attacker must
  hold it for days, continuously. Test: `Keeper.t.sol::test_theDailyDrawdownLimitBindsAndRefills`.
  Test: `Keeper.t.sol::test_theDailyDrawdownLimitBindsAndResets`.
- **Sizing helpers** a keeper must consult first: `bidCap(j)` and `maxParentForDeploy(j)` — the most
  parent `j`'s *drawable* ETH can pay for, bounty included (0 for `j == 0`), computed with the
  inverted walk `parentForEthValue`. The smaller of the two is what goes through; over `bidCap`,
  `SizeCapExceeded(amount, cap)`.
  **Run-3 sizing-view finding — fixed.** `maxParentForDeploy` used to invert `payout = ethValue ×
  1.01` unconditionally, so any `available <= MIN_BOUNTY_WEI` inverted to a negative/zero quote and
  the view reported 0 even when `deployAncestor` itself would accept the call (below the floor the
  bounty is capped at `MAX_BOUNTY_SHARE_BPS` of the total, so e.g. `0.8 × available` is perfectly
  deployable). `_maxEthValueFor` now inverts `payout` **piecewise**, matching `_bounty`'s own three
  branches exactly (`v = available·100/101` proportional, `v = available − m` flat-floor,
  `v = available·4/5` below the floor's own ceiling), so the quote is the real maximum in every
  regime and always satisfies `deployAncestor`'s guard `ethValue + bounty <= available`. Tests:
  `FeeVault.t.sol::test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor` (quotes the true max
  across all three branches and both knees), `test_deployAncestorAcceptsTheBelowFloorQuote` (the
  quote a below-floor allowance produces is fed straight into a real `deployAncestor` call and
  accepted).
- **Size cap (audit F7).** `bidCap(j) = MAX_RESERVE_BPS (2%) × max(active-tick-bucket parent
  reserve, first-curve-range parent capacity)`. The second term is the parent that would buy out the
  whole FIRST range of `j`'s registered launch curve from the current price (zero once the price has
  walked past it, in which case the bucket alone applies). Sizing against the 60-tick active bucket
  alone made the 1% bounty smaller than the gas of the call at beta scale, so nobody would ever
  deploy a bid; the first range is the liquidity a buy actually walks into. The 2% share is
  unchanged, so one call still cannot move a pool.
  `Bid.t.sol::test_genesisBidBountyBeatsTheGasOfTheCall` pins the bounty at ~3.8× the gas cost of
  the call at 0.01 gwei (bounty ≈ 1.79e13 wei vs ≈ 4.67e12 wei of gas for a 467k-gas call).
- **Active-range reserve (H3).** `_parentReserve` prices the parent currency between spot and the
  far edge of the current tick-spacing bucket with `SqrtPriceMath`, not the whole-range virtual
  reserve `L/√P` (which overstates a concentrated book by orders of magnitude,
  `Bid.t.sol::test_activeRangeReserveIsMuchSmallerThanTheVirtualReserve`). A cold pool sits exactly
  at the top tick of its curve with `getLiquidity() == 0`; rather than cap every bid at zero,
  `_coldStartLiquidity` falls back to the first curve range's liquidity, recomputed from the same
  deploy constants (`test_coldPoolIsSizedFromItsCurveAndCanReceiveABid`,
  `test_coldPoolAcceptsALockedBid`, `test_coldPoolStillHasASizeCap`).
- **Partial pot draws (H2/L5).** The pool's own parent-denominated hop pot is drawn **partially**,
  `min(pot, cap − parentAmount)` — never all-or-nothing, so a pot larger than the cap can no longer
  brick the generation forever. `BidDeployer.deployGenesisBid()` / `deployGenesisBid(ethAmount)` do
  the same for index 0 with three independent pots — genesis's ETH sleeve (capped at `ethAmount` in
  the one-argument form), the genesis hop pot and the forfeited-bond earmark — each drawn up to the
  remaining room; any non-empty combination deploys
  (`test_genesisBidDeploysFromTheHopPotAloneAndDrawsPartially`,
  `test_deployGenesisBidDepositsForfeitedBonds`). **The bounty is paid on top of the deposit on BOTH
  keeper paths, never out of it (this change).** The size cap bounds the DEPOSIT: `deposited =
  potTotal · BPS / (BPS + BOUNTY_BPS)` (clamped to the reserve room), `bounty = deposited ·
  BOUNTY_BPS / BPS`, and the three pots are drawn up to `need = deposited + bounty` — the earlier
  version took the bounty *out of* the deployed total, which made `deployAncestor` and
  `deployGenesisBid` disagree about what "1%" meant; both now agree.
- **Coverage and band guard (M2 / audit F5).** `BidDeployer._twap` reverts
  `TwapNotReady(covered, observations)` unless `covered >= TWAP_WINDOW` (1800 s) **and**
  `observationCount >= 2` **and** `twap != 0` — for **every** pool whose price enters a conversion.
  `_requireWithinBand` adds, **on the target pool only**, that spot must sit within
  `±TWAP_BAND_BPS = 300` of the fast TWAP **sqrt** price (≈ ±6.1% in price terms). A
  zero-observation pool is not a silent pass
  (`test_deployRevertsWhenTheTwapIsNotReady`, `test_deployAncestorRevertsOutsideTheTwapBand`).
- **Bid placement.** `Locker.depositBid` (`BidDeployer`-only, `NotBidDeployer` otherwise) places
  `BID_WIDTH_SPACINGS = 10` spacings on the parent-only side of spot, permanently locked. L3: both
  clamp branches re-establish `tickLower < tickUpper` or revert `BidRangeEmpty`
  (`test_bidRangeAlwaysHasWidth`).
- **Gas.** O(j) in *static calls only* (one `poolKeyOf`, `consult`, `consultSlow`,
  `observationCount`, `getSlot0` and `poolInfo` per generation): measured ≈48.5k gas per generation,
  ≈140k for the band+consult chain at j = 1, ≈2.20M at j = 32 and ≈8.63M at j = 128; a whole live
  `deployAncestor(1)` is ≈589k (`test_gas_deployAncestor`, `test_gas_deployAncestorConsultChain`).
  The j = 128 figure describes an arithmetically reachable but economically unreachable regime: a
  link is worth 5–8% of its parent, so at that depth a pool's entire market cap is dust and the 2%
  size cap, not the gas, is what refuses the call (`Depth.t.sol`, step 4).
- `test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid`, `test_deployAncestorDoesNotSwap` and
  `test_deployAncestorRespectsSleeveAndSizeCap` pin the model;
  `Mirrored.t.sol::test_keeperBidOnAMirroredLinkUsesTheElseBranch` covers the upside-down
  orientation.

**`BidDeployer.depositExternalBid(token, parentAmount)`** (`IBidDeployer`) — permissionless,
payable, no bounty and no ledger: a gift of parent liquidity under one of *this version's* links
(`NotOurLink` otherwise, `WrongValue` on a mismatched `msg.value`), subject to the same band and
size guards. It is also the cross-version payout path: when generation `j`'s pool belongs to an
earlier version (whose hook accepts only its own Locker), `deployAncestor` / `deployGenesisBid`
resolve the owning version's `BidDeployer` — `registryOf(j) → factory() → bidDeployer()` — and hand
the tokens to *that* version's `BidDeployer`, whose own Locker places the bid (`AncestorForwarded`).
The same three internal resolvers (`_factoryFor`, `_hookFor`, `_priorDeployerFor`) all walk
`roundManager.registryOf(j)` the same way, so a continuation stack can never read one version's TWAP
while placing a bid through another's Locker. Tests:
`Continuation.t.sol::test_v2GenesisBidIsPlacedByV1sVault`,
`test_deployAncestorForAPriorVersionGenerationGoesThroughV1sVault`,
`test_depositExternalBidRefusesAForeignLink`.

### Sunset handover of the ETH edge

A continuation stack has no ETH-paired pool of its own, so the 1% edge is always *charged* by the
original version's hook on the original genesis pool. From the moment `roundManager.isSunset()` is
true, `accrue` no longer ever books the protocol share locally as a fallback.

**Post-sunset fees are never booked locally (audit 4, rewritten).** The earlier design's fallback was
exactly the bug: whenever the in-swap forwarding hop could not run — thin caller gas, a reverting or
gas-burning successor — the fee was booked in *this* version's vault instead, which meant **the gas
of the swap decided which version received a fee**, and a chain of successors could not complete
inside one swap's gas budget (recursion died by about v5). The fee is now either forwarded in-swap
when the gas budget allows it, or **queued**, never booked here:

```
if (protocolFee != 0 && currency == ETH && roundManager.isSunset()) {
    attribution = attributed ? terminalIndex : UNATTRIBUTED
    budget = forwardingFailed ? 0 : min(FORWARD_GAS, gasleft() − BOOK_GAS_RESERVE)
    if budget != 0:
        try this.forwardProtocolFee{gas: budget}(currency, protocolFee, attribution, MAX_FORWARD_HOPS)
            forwarded = true
        catch:
            arm forwardingFailed if it failed AT the full budget (unchanged from F2)
    if !forwarded:
        pendingForward[attribution] += protocolFee   // QUEUED — never booked locally
}
```

A successful in-swap hop `transfers the ERC-6909 claim` to the successor's vault (resolved once via
`roundManager.successor().factory().feeVault()`, cached write-once in `successorVault`,
`NoSuccessorVault` if it does not resolve or has no code) and calls `accrueForwarded(attribution,
amount, hopsLeft)`. **`accrueForwarded` no longer recurses either (audit 4):** if the receiving
version is *itself* sunset, it queues the amount in its **own** `pendingForward` rather than trying
to hop again inside the same call — `hopsLeft` is accepted only for ABI compatibility and is ignored,
because how far a fee travels is now a matter of how many `flushForward` calls happen, not of one
swap's gas. `accrueForwarded` accepts a caller only if `_isPriorVault(msg.sender)`, i.e. it is the
FeeVault of a version this one continues, found by walking the same registry chain (`NotPriorVault`).
`forwardProtocolFee` is `NotSelf`-gated and exists solely so the in-swap hop can be wrapped in
`try/catch`.

**`flushForward(attribution, max)` — permissionless, one hop per call, no recursion (audit 4).**
Anyone can push up to `max` of what is queued under `attribution` on to the *immediate* successor's
vault, paying the gas themselves: it resolves the successor vault, decrements `pendingForward` and
`ledgerTotal`, redeems the claim into real ETH if it is not already (`redeem`, since this runs outside
a swap and can safely unlock), and calls `receiveForward{value: amount}(attribution)` on the
successor. `receiveForward` is the real-ETH twin of `accrueForwarded` — same booking rule, same
queue-if-still-sunset behaviour, `_isPriorVault`-gated. So a chain of any length completes in **one
`flushForward` per version**, each independently callable and independently paid for; tested end to
end to six versions. `ledgerTotal` counts `pendingForward` too (`pendingForwardTotal` is the
solvency-introspection sum across every attribution): the vault holding a queued fee still **holds**
it, it just does not **own** it, so `ledgerTotal[c] <= holdings(c)` keeps holding by construction even
while a fee is queued. Tests:
`Continuation.t.sol::test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt`,
`test_theEdgeReachesTheSixthVersionThroughFlushes`,
`test_aBrokenSuccessorQueuesInsteadOfBookingLocally`.

**The gas bound is what makes that guarantee true (audit F2 — fixed).** `try/catch` alone did not
protect the swap: under EIP-150 the callee gets 63/64 of the gas, so a successor that simply *burns*
everything it is given could leave too little gas for the rest of the frame — and with it the whole
genesis-pool swap — to finish, at **any** gas limit. The vault now computes

```
budget = min(FORWARD_GAS = 6_000_000, gasleft() − BOOK_GAS_RESERVE = 1_500_000)
```

and **skips the hop entirely when that is zero**. The safety property is the reserve, not the
ceiling: whatever the successor does, ≥1.5M gas is always still here to queue the fee in
`pendingForward` (audit 4, above — never to book it locally) and let the swap finish. The ceiling
only bounds what a hostile successor can waste, and is generous because an honest hop is expensive
(a cold book in the successor, possibly plus one further hop of its own).
A hop that fails **with its full `FORWARD_GAS` budget** arms the one-shot negative cache
`forwardingFailed` (event `ProtocolFeeForwardingFailed`) and is never retried — so a hostile
successor costs at most one swap's worth of wasted gas, forever. A hop that merely ran out of a
*caller's* thin gas budget does **not** arm the cache, because it says nothing about the successor
and must not disable an honest handover. Measured: a genesis buy is ≈439k gas before the handover,
≈443k on the first (resolving) swap after it and ≈440k once cached; against a gas-burning successor
the first attempt stays under 8M and every later swap under 1M
(`Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps`,
`Continuation.t.sol::test_gas_genesisSwapAcrossTheHandover`).

So the claim the audit called false is now true, and this is precisely why: **a swap can never fail
because of what a later version does — not because the call is wrapped, but because the callee can
never be given the gas the caller still needs.** The same bound exists on the hook side as 30k-gas
staticcalls with `successorUnresolvable` (§H). Events: `ProtocolFeeForwarded` /
`ProtocolFeeReceived` / `ProtocolFeeForwardingFailed`.

What **stays** in the charging version's vault: the parent-side hop fee and snipe tax for that pool,
and every balance accrued before the handover (dev, creator, sleeve, reinforcement, bond earmark —
all still claimable and deployable there). **What no longer "stays" is the protocol share on a
forwarding failure** — it queues in `pendingForward` instead (audit 4, above), so a version's vault
never re-acquires a fee it has already surrendered to the successor's ledger just because a hop was
expensive or hostile. No new privilege is created: the successor is the one the steward already named
in the one-shot sunset, and the resolved successor vault/router are cached write-once with no setter.
Tests: `test_afterTheHandoverTheEdgeIsBookedByV2AndAttributedToItsCreator`,
`test_beforeTheHandoverTheEdgeStaysInV1sVaultUnattributed`,
`test_v1DevClaimsAccruedBeforeTheHandoverSurviveIt`,
`test_theEdgeForwardsTwoHopsFromV1ThroughV2ToV3`,
`test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt`,
`test_theEdgeReachesTheSixthVersionThroughFlushes`,
`test_aBrokenSuccessorQueuesInsteadOfBookingLocally`,
`test_accrueForwardedOnlyAcceptsAPriorVaultInTheChain`,
`test_gas_genesisSwapAcrossTheHandover`, `Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps`.

**Genesis** receives the ancestor sleeve like any other link, plus the forfeited bonds; its support
is delivered as protocol-owned locked bid liquidity, never as a withdrawal.

Split values are `FeeVault` constructor arguments validated by `DEV_BPS + creatorBps <= BPS` and
`ancestorBps + reinforceBps == BPS` (of the remainder), with a non-zero `developer` and code checks
on the factory/locker/hook/roundManager (`BadSplit`, `NoCode`). `script/Deploy.s.sol` binds
`CREATOR_BPS = 4000`, `ANCESTOR_BPS = 5000`, `REINFORCE_BPS = 5000` — dev 20% / creator 40% /
ancestor 20% / reinforcement 20% of the fee, exactly the `DEPLOY_CONSTANTS.md` row Sims 1/6/10
measured. **[DIFF 5]** The *test* deployment still uses creator 10% with the remainder at
71.43/28.57 (`FamilyTestBase.CREATOR_BPS/ANCESTOR_BPS/REINFORCE_BPS`), so every fee-split assertion
in `FeeVault.t.sol` is proven at a split the protocol is not deployed with. The arithmetic is
split-agnostic, but the suite does not cover the live numbers.

---

## K. Liquidity ownership

Every position in every family pool is owned by the `Locker`, forever.

- `placeStandardCurve(key, ranges, tokenIsCurrency0)` — factory only (`NotFactory`). Mints each
  range inside one `unlock`, requires that the parent side is never owed (`ParentOwed`, because the
  Locker holds no parent currency), settles the token side, burns the dust.
- `depositBid(key, parentAmount, tickLower, tickUpper)` — `BidDeployer` only (`NotBidDeployer`).
  Orientation is derived from the pool's own tick rather than trusted from the caller: entirely above spot ⇒
  currency0-only, entirely at or below spot ⇒ currency1-only, anything straddling reverts
  `BidStraddlesSpot`. Native ETH requires an exact `msg.value`; an ERC-20 requires `msg.value == 0`.
  The child side must never be owed (`TokenOwed`). L2: the position is priced the way
  `modifyLiquidity` will charge it (`getAmount*Delta` rounded **up**) and one wei is shaved off the
  input if it does not fit, so settlement can never be short; the leftover wei stays in a contract
  that cannot move it out (`Bid.t.sol::testFuzz_bidNeverOwesMoreThanItWasGiven_currency0/1`,
  `test_bidAbsorbsTheRoundingWei`).
- **There is no remove, transfer, sweep or rescue.** The Locker has no function that moves a token
  or a position out; `FamilyHook.beforeRemoveLiquidity` reverts `LiquidityIsLocked` for everyone
  unconditionally, including the Locker itself; `beforeDonate` reverts `DonationDisabled`. Asserted
  by `test_lockerHasNoExit`, `test_removeLiquidityAlwaysReverts`,
  `test_addLiquidityRevertsForNonLocker`, `test_donateReverts` and
  `invariant_lockedPositionsNeverDecrease` (a ratchet across the fuzz run).

Consequence: the launch curve and every keeper bid are permanent protocol-owned depth. Nobody —
including the developer and the steward — can withdraw a unit of liquidity. It also means a
mispriced curve can never be corrected; genesis's curve is now computed in-contract (§D), so the
only remaining way to misprice it is a wrong `GENESIS_UNIT` or `curveSpec` at deployment.

---

## L. Creator rights

A creator **can**: create genesis (once, first caller — attribution only, with no influence over
price or shape); register any number of candidates by paying bonds; receive the bond back on a win,
or pull it from `pendingRefund` with `claimRefund(to)` if the push failed; accrue and claim
`creatorBalance[token]` in ETH for attributed ETH-edge swaps on their canonical link, plus — during
a round — half of the creator share on their *candidate's* attributed trades (the other half goes to
the head's creator), which they keep even if they lose; transfer the future claim right with
`transferCreatorRecipient(token, to)`; and trade their own token like anyone else.

A creator **cannot**: mint, burn other holders' tokens, blacklist, pause, change the curve, change
fees or splits, remove or move liquidity, change the metadata `uri`, influence scoring or
finalization, retract a candidacy, or prevent a rival from registering. Transferring the recipient
right does **not** move balances already credited.

---

## M. Admin rights — the exact privileged surface

There is no owner, admin role, proxy upgrade, pause, parameter setter, timelock or emergency
function anywhere in `contracts/`. **MECHANISM_v3 adds no privileged surface at all**: `requestEnd()`,
`fulfilEnd(proof)`, `finalizeDeterministic()`, and the late-entry
path through `registerCandidate`/`addCandidate` are every one of them permissionless, exactly like
`submitScore`/`finalize` already were — the adaptive schedule, the closing window and the purse split
are pure functions of on-chain state that nobody can steer by calling from a particular address. Four
kinds of address have any privilege at all, and each has a
short, fixed list of things it may do. **The final external review's fixes (deployHopPot, flushForward,
deployAncestor's dead-zone bounty, the token-bucket allowance, transitive-adoption checking,
creator-accrued sweeping, min-of-three pricing, the dirty-word and `sync(native)` guards) add none of
these as functions requiring a role — every one of them is permissionless.** Three of the four
privileged addresses — steward, developer, and the `DevVesting` beneficiary — are now **transferable
on an identical public delay**, added on top of the sunset switch and the dev claim below (design
decision 2026-09-11: a single cold-signer hardware wallet for the steward and the developer, not a
multisig, with pathways to security upgradability if they are needed — this is that pathway).

- **steward → `RoundManager.announceSunset(successor)` / `cancelSunset()`, and
  `announceStewardTransfer(to)` / `executeStewardTransfer()` / `cancelStewardTransfer()`, and
  nothing else.** `announceSunset` is once-only (`sunsetAt == 0`), needs code at the successor, and
  takes effect after `sunsetDelay` (a constructor parameter, floor `MIN_SUNSET_DELAY = 1 hours`;
  mainnet 7 days, testnet 1 hour, audit 2). `cancelSunset` (audit F2) takes an announcement back **before**
  it takes effect — `block.timestamp < sunsetAt`, and usable **once in the lifetime of the
  deployment** (`sunsetCancelled`), so a steward who announces a second sunset can no longer take it
  back. It exists because the named successor is otherwise irrevocable and the steward may discover
  during the delay that it is broken or hostile; it is deliberately impossible at or after
  `sunsetAt`, because by then an earlier version may already have resolved and cached the handover.
  **The steward role itself is transferable** on `RoundManager.ROLE_TRANSFER_DELAY = 7 days`
  (identical constant name and value to `FeeVault`'s and `DevVesting`'s): `announceStewardTransfer(to)`
  — current steward only, `to != address(0)`, one pending transfer at a time (`TransferPending`) —
  `executeStewardTransfer()` — **permissionless**, once `block.timestamp >= stewardTransferAt`, so an
  incoming steward can take the role even if the outgoing key is lost — `cancelStewardTransfer()` —
  current steward only, repeatable. **Nothing new becomes possible when a transfer executes**: the
  role's whole surface is still `announceSunset` / `cancelSunset`, which then answer to the new
  holder. Both original functions still require `steward != address(0)`. Nothing here can pause a
  round, touch a pool, move a wei, name a second successor, or shorten either delay. The only
  economic effect of a sunset is that `openRoundIfIdle` stops minting new rounds. Tests:
  `RoleTransfer.t.sol::test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute`,
  `test_sunsetPowersFollowTheNewSteward`,
  `test_onlyTheStewardAnnouncesOrCancelsAndOnePendingAtATime`.
- **developer → `FeeVault.claimDev(to)`, and `announceDeveloperTransfer(to)` /
  `executeDeveloperTransfer()` / `cancelDeveloperTransfer()`, and nothing else.** `claimDev`
  withdraws only the 20% ETH already accrued to the *current* holder of the role. **The developer
  address is no longer immutable** (superseding the earlier "no transfer function" design): it moves
  on the identical `FeeVault.ROLE_TRANSFER_DELAY = 7 days` announce/execute/cancel triple, with the
  same current-holder-announces / anyone-executes / current-holder-cancels shape as the steward
  above. **Disclosure:** the developer ledger is a single balance, not a per-holder one, so whatever
  has accrued — before or after a transfer — is claimable by **whoever is the developer at claim
  time**; a transfer therefore hands over the unclaimed balance along with the future stream, and the
  outgoing holder should `claimDev` first if that is not intended. Tests:
  `RoleTransfer.t.sol::test_developerTransferWaitsOutTheDelayAndIsPermissionlessToExecute`,
  `test_accruedDevBalanceIsClaimableByWhoeverHoldsTheRoleAtClaimTime`,
  `test_onlyTheDeveloperAnnouncesOrCancelsAndOnePendingAtATime`.
- **the `DevVesting` beneficiary → `release()` is permissionless (anyone may trigger a payout to the
  fixed beneficiary), and `announceBeneficiaryTransfer(to)` / `executeBeneficiaryTransfer()` /
  `cancelBeneficiaryTransfer()` on the identical `DevVesting.ROLE_TRANSFER_DELAY = 7 days`.** This is
  the only privilege the beneficiary has: it cannot change the vesting schedule, clawback anything,
  or accelerate a release — see §B.1. Tests: `DevVesting.t.sol::test_beneficiaryTransferWaitsOutTheDelay`,
  `test_onlyTheBeneficiaryAnnouncesOrCancels`, `test_cancelTakesTheAnnouncementBack`.
- **creators → `FeeVault.claimCreator(token, to)` and `transferCreatorRecipient(token, to)`**, for
  their own token only (unaffected by this change).

**The transfer triple, stated once because it is now used by all three roles above.** Every
`announce*Transfer(to)` is current-holder-only, refuses `to == address(0)`, and refuses to overwrite
a pending transfer (`TransferPending`; cancel first). Every `execute*Transfer()` is **permissionless**
and callable only once `block.timestamp >= *TransferAt`, so a lost outgoing key can never trap the
role. Every `cancel*Transfer()` is current-holder-only and repeatable. The three constants
(`RoundManager.ROLE_TRANSFER_DELAY`, `FeeVault.ROLE_TRANSFER_DELAY`, `DevVesting.ROLE_TRANSFER_DELAY`)
are identical named constants, each `7 days`, verified equal by
`RoleTransfer.t.sol::test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute` (asserts
`roundManager.ROLE_TRANSFER_DELAY() == 7 days`) and the equivalent developer/vesting assertions.

Complete inventory of every external/public function, by caller check:

| contract | function | caller check | privilege |
|---|---|---|---|
| `FamilyFactory` | `createGenesis`, `registerCandidate`, `wire` | **none** | permissionless launch; genesis is once-only and priced in-contract |
| `FamilyFactory` | `curveSpec`, `startFdv`, `genesisCurve`, `genesisToken`, `genesisCreator`, `genesisPoolId`, `wired`, immutables | view | — |
| `FamilyToken` | `burn`, ERC-20 | **none** (own balance only) | holder-initiated burn |
| `FamilyHook` | `registerPool(PoolKey key, bool isGenesis, uint160 initSqrtPriceX96, uint64 tradingStart, uint32 scoreSlotS, bool parentIsCurrency0)` | `== factory` | register a key once; cannot re-register (`PoolAlreadyRegistered`). Since review-2 the hook also enforces `isGenesis => tradingStart == 0` (`GenesisHasNoSnipeWindow`): the genesis pool has no snipe window, which is what keeps the protocol fee and the snipe tax mutually exclusive per pool (§7.14 of `PROPERTIES.md`). The factory already only ever passed zero; the guarantee is now the hook's own |
| `FamilyHook` | `beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`, `beforeDonate` | `== poolManager` | callback authenticity only; the unused `IHooks` entrypoints revert `HookNotImplemented` and their permission bits are not set |
| `FamilyHook` | `poolInfo`, `scoreState`, `consult`, **`consultSlow`**, `observationCount`, **`slowObservationCount`**, `successorRouter`, **`successorUnresolvable`**, `roundManager` | view (`_successorRouter` caches positively *and negatively* on first use, each leg a 30k-gas staticcall) | — |
| `Locker` | `placeStandardCurve` | `== factory` | add locked curve liquidity |
| `Locker` | `depositBid` | `== bidDeployer` | add locked bid liquidity |
| `Locker` / `FeeVault` / `FamilyRouter` | `unlockCallback` | `== poolManager` | callback authenticity only |
| `RoundManager` | `registerGenesis`, `openRoundIfIdle`, `addCandidate` | `== factory` | round bookkeeping |
| `RoundManager` | **`announceSunset`** | **`== steward`, once** | stop opening new rounds after `sunsetDelay` (mainnet 7 days, testnet 1 hour); publish the successor |
| `RoundManager` | **`cancelSunset`** | **`== steward`, once ever, and only before `sunsetAt`** | take an announced sunset back; clears `sunsetAt` and `successor` |
| `RoundManager` | **`announceStewardTransfer`, `cancelStewardTransfer`** | **`== steward`, one pending at a time** | announce/cancel a transfer of the steward role, executable 7 days after announcement |
| `RoundManager` | **`executeStewardTransfer`** | **none** (only once the delay has elapsed) | move the steward role to the announced address |
| `RoundManager` | `submitScore`, `finalize`, `claimRefund` | **none** (`claimRefund` pays `pendingRefund[msg.sender]` only) | permissionless |
| `RoundManager` | **`requestEnd`, `fulfilEnd`, `finalizeDeterministic`** | **none** | pin/relay the drand-derived true end, or settle it deterministically after `END_TIMEOUT` (MECHANISM_v3 §3) |
| `RoundManager` | `durationFor`, `registrationFor`, `lateEntryUntil`, `closingWindowFor`, `scoreSlotFor`, `randomEndWindowFor`, `roundOfIndex` | view | — |
| `RoundManager` | `phase`, `currentPhase`, `roundInfo`, `candidateInfo`, `candidateCount`, `candidateIds(roundId)`, **`candidateIds(roundId, offset, limit)`**, `candidateIdAt`, `threshold`, `thresholdFor`, **`bondFor`, `currentBond`**, `canonical`, `poolKeyOf`, `poolIdOf`, `indexOf`, `isCanonical`, `parentOf`, `creatorOf`, `ownsToken`, `registryOf`, `registryOfToken`, `head`, `headIndex`, `headToken`, `priorIndex`, **`isIdle`, `adopted`**, `genesisToken`, `isSunset`, `isSunsetEffective`, `sunsetAt`, **`sunsetCancelled`**, `successor`, `pendingRefund`, `hWad`, `MAX_INDEX`, **`steward`, `pendingSteward`, `stewardTransferAt`, `ROLE_TRANSFER_DELAY`** | view | — |
| `FeeVault` | `accrue` | `== hook` | ledger write |
| `FeeVault` | `accrueForwarded` | `== a prior vault in this stack's registry chain` (`_isPriorVault`) | book a forwarded ETH-edge fee |
| `FeeVault` | `forwardProtocolFee` | `== address(this)` (`NotSelf`) | one handover hop, `try/catch`-wrapped by `accrue` |
| `FeeVault` | `depositGenesisBidEarmark` | `== roundManager` | earmark forfeited bonds |
| `FeeVault` | **`claimDev`** | **`== developer`** | withdraw the *current* developer's accrued ETH |
| `FeeVault` | **`announceDeveloperTransfer`, `cancelDeveloperTransfer`** | **`== developer`, one pending at a time** | announce/cancel a transfer of the developer role, executable 7 days after announcement |
| `FeeVault` | **`executeDeveloperTransfer`** | **none** (only once the delay has elapsed) | move the developer role to the announced address |
| `FeeVault` | **`claimCreator`, `transferCreatorRecipient`** | **`== creatorRecipient(token)`** | withdraw / assign that token's own accrued ETH; a transfer sweeps what has already accrued to the OLD recipient's `creatorAccrued` ledger and refuses `to == address(0)` |
| `FeeVault` | **`claimCreatorAccrued`** | **none** (pays `creatorAccrued[msg.sender]` only) | pull whatever a creator-right transfer swept to the caller before it moved on |
| `FeeVault` | `redeem` | **none** | permissionless claim-to-balance conversion |
| `FeeVault` | `consumeAncestorClaim`, `consumeReinforcement`, `consumeGenesisEarmark`, `payKeeper` | **`== bidDeployer` (immutable, `NotBidDeployer`)** | draw an already-owed ledger amount into `deployerCredit`, or pay it out; `BidDeployer` can never move more than a generation's own money (the `deployerCredit` leash) |
| `FeeVault` | `claimableAncestor`, `claimableEth`, **`drawableEth`, `drawdownWindow`**, `holdings`, `creatorRecipient`, `ancestorPointQueryWad`, **`forwardingFailed`, `successorVault`**, ledger getters | view | — |
| `BidDeployer` | **`deployAncestor(j, parentAmount)`**, `deployGenesisBid()`, `deployGenesisBid(uint256)`, **`deployHopPot`**, `depositExternalBid` | **none** | permissionless keeper / gift paths (bounty-paid on the first three, none on `depositExternalBid`; `deployHopPot`'s bounty is paid in the parent token, not ETH); `deployAncestor`'s destination is `canonical(j)` and is not an argument (MECHANISM_v3 §1); each call is `nonReentrant` and every wei/token it draws leaves in the same call |
| `BidDeployer` | **`ethValueOfParent`, `parentForEthValue`**, `ethPerTokenWad`, `bidCap`, `maxParentForDeploy` | view | — |
| `FamilyRouter` | `buyExactIn`, `sellExactIn`, `swapPath`, `buyCandidate`, `sellCandidate`, `buyCandidateWithParent` | **none** | attribution only, never fee-privileged; **no `receive()`** |
| `FamilyLens` | `roundView`, `candidateView`, `chainView` | view | — |
| `DevVesting` | `release` | **none** | pay the *current* beneficiary whatever is releasable |
| `DevVesting` | **`announceBeneficiaryTransfer`, `cancelBeneficiaryTransfer`** | **`== beneficiary`, one pending at a time** | announce/cancel a transfer of the right to receive releases, executable 7 days after announcement |
| `DevVesting` | **`executeBeneficiaryTransfer`** | **none** (only once the delay has elapsed) | move the beneficiary right to the announced address |
| `DevVesting` | `total`, `vested`, `releasable`, `beneficiary`, `released`, `pendingBeneficiary`, `beneficiaryTransferAt`, `start`, `cliff`, `duration`, `token`, `ROLE_TRANSFER_DELAY` | view | — |
| `DevVestingDeployer` | `deploy` | **none** | CREATEs a `DevVesting`; only the one instance the factory creates and funds at genesis is ever meaningful (§T) |

Every non-permissionless entry is either a contract-to-contract authenticity check between immutable
addresses fixed at deployment (`factory`, `locker`, `feeVault`, `bidDeployer`, `router`,
`poolManager`, `roundManager`, `hook`) or a recipient claiming a balance the protocol already owes
them. `BidDeployer` itself has **no** caller-checked function at all: every external entrypoint
(`deployAncestor`, both `deployGenesisBid` overloads, `deployHopPot`, `depositExternalBid`) is
permissionless by design, and its only privilege is the `onlyBidDeployer` gate it holds on the *other* side, on
`FeeVault`'s four keeper hooks and `Locker.depositBid` — both immutable role checks, no owner, no
setter, verified by `wire()` before anything can launch. None can move liquidity, change an economic
parameter, alter history, seize another party's balance or stop trading — including `announceSunset`
and `cancelSunset`
(`Sunset.t.sol::test_everythingElseKeepsWorkingAfterTheSunset`, `test_onlyTheStewardMayAnnounce`,
`test_announceIsOnceAndForever`, `test_successorMustBeAContract`,
`test_zeroStewardMeansNoSunsetIsPossible`, `test_theDelayIsSevenDaysAndRoundsOpenThroughout`,
`test_cancelSunsetWorksBeforeTheEffectAndNotAfter`, `test_cancelSunsetNeedsAnAnnouncement`,
`test_aGasBurningSuccessorCannotBrickSwaps`).
`address(0)` as steward is legal and means the deployment can never be sunset — and therefore never
continued.

One residual centralisation: the hook address is CREATE2-mined from a salt supplied to the factory
constructor, and the FeeVault / router addresses are passed in as *predictions*. `wire()` proves
they have code, but not that they are the *intended* code; the deploy script must assert every
address equality and `deployments/46630.json` must record them.

---

## N. Oracle / scoring design

Two independent accumulators live in `FamilyHook.RegisteredPool`.

**Storage is packed by HOT PATH, not by reading order (gas pass).** A scored swap now touches
exactly four slots instead of the pre-optimization layout's larger footprint:

```
slot 0: registered, isGenesis, parentIsCurrency0, frozen, tradingStart, tradingEnd, tFrozenAt   (every flag/window a swap READS; one SLOAD, one SSTORE on freeze)
slot 1: R, tLast                                                                                  (the score-rate pair every accumulation writes together)
slot 2: acc                                                                                        (needs the whole word — see ranges below)
slot 3: cumSqrtP, tObs                                                                             (the observation pair every price update writes together)
[cold]: initSqrtPriceX96                                                                           (read once, in beforeInitialize; parked last so it never steals bytes from the hot flag slot)
```

**Ranges.** `R` is net parent absorbed, bounded by the parent's total supply (1e9 · 1e18 = 1e27 <
2^90), so `int128` keeps ~37 bits of headroom and `+=` still reverts on overflow rather than
wrapping. `acc = R · seconds` reaches ~2^122 of magnitude (2^90 · 2^32), which would fit `int128`
only with zero headroom, so it keeps a full 256-bit word.

**`cumSqrtP` is a deliberately WRAPPING 192-bit accumulator (`uint192`, down from a full word) that
is only ever differenced.** `cumSqrtP += sqrtPriceX96 · dt` is written in `beforeSwap` using the
price that stood **before** the swap, for the whole interval since the previous observation — so a
single swap can never rewrite elapsed time at its own manipulated price. Truncating it to 192 bits
keeps every difference exact as long as the gap between the two points being differenced is under
2^32 seconds (~136 years) at the maximum sqrt price — comfortably inside both the 1800 s fast
window and the 7-day slow window this accumulator feeds. `IFamilyHook.Observation` (`timestamp`,
`cumSqrtP`) shares the same 192-bit field, so **one ring write is a single SSTORE** (one slot: a
`uint64` timestamp plus the `uint192` accumulator).

That one cumulative accumulator feeds **two rings** per pool:
  - the **fast** ring, `OBS_CARDINALITY = 32` entries at `OBS_MIN_SPACING = 120 s` (M2):
    32 × 120 s = 3840 s of span, comfortably covering the 1800 s `TWAP_WINDOW`;
  - the **slow** ring (audit F4), `SLOW_OBS_CARDINALITY = 64` entries at
    `SLOW_OBS_MIN_SPACING = 3 hours`: 64 × 3 h = 8 days of span, so the 7-day
    `SLOW_TWAP_WINDOW` is fully coverable. It shares the same accumulator and is merely sampled
    more rarely, so it costs one extra SSTORE per pool per three hours and gives the keeper path a
    price a 30-minute pump cannot move.

`consult(id, window)` and `consultSlow(id, window)` both return
**`(twapSqrtPriceX96, coveredSeconds)`**: a two-point cumulative average
`(cum(now) − cum(t_ref)) / (now − t_ref)` where `t_ref` is the newest ring entry at least `window`
seconds old, found by **binary search** over the ring (a linear scan of 32 entries would cost ~64
SLOADs, and the keeper path makes one call per generation). Counts are exposed as
`observationCount(id)` / `slowObservationCount(id)`. A pool with no observations returns spot with
**zero coverage**, and `BidDeployer._twap` treats coverage `< TWAP_WINDOW` or `observationCount < 2`
as a `TwapNotReady` revert — the band guard can no longer be silently vacuous. Insufficient *slow*
coverage is not a revert: `_priceFor` falls back to the fast average alone and reports it
(`SlowTwapUnavailable`), because a young pool must still be supportable (§J).

Remaining documented limits, all deliberate:

1. It averages **sqrt price**, so a ±3% band is roughly ±6.1% in price terms.
2. Observations advance only on swaps; a quiet pool's TWAP is stale by construction — and a pool
   that has not accumulated 1800 s of covered history simply cannot be reinforced yet.
3. On a ~100 ms-block chain (`research/onchain-verification.md`) up to ten blocks share a
   `block.timestamp`, so both accumulators integrate zero time across them. Safe for scoring
   (same-second activity is simply not time-weighted), but sub-second manipulation is invisible.
4. A patient attacker can still drag a TWAP, but the cost went up by orders of magnitude (audit
   F4): a drag now has to move the **7-day** average as well, because every link is priced at
   `min(spot, TWAP_30m, TWAP_7d)` in value terms, and even then the 10%-of-bucket drawdown per generation
   (`FeeVault.drawableEth`) means the sleeve can only be taken a tenth at a time, over days. The
   band bounds the per-call price, the 2% size cap bounds the size, and the bounty is paid only on
   a completed deposit.

These are the TWAP rings that price keeper conversions (§J). They are distinct from the **score
checkpoint rings** MECHANISM_v3 adds to `FamilyHook.RegisteredPool` for the closing-window average
(§F): a 36×5 s fast ring covering `RANDOM_END_S` and a 64-slot coarse ring sized per round
(`scoreSlotFor(n)`) covering the closing window plus the settlement tail. Both checkpoint rings share
the SAME `acc`/`R` accumulator the TWAP rings' pool never touches — they checkpoint the score, not the
price — and, unlike the TWAP rings, are never frozen: they run for the lifetime of the pool because
`trailingAverage` (§J) is readable off them long after any round has finalized.

**The one external input the design does add: a public randomness beacon for the round's true end
(MECHANISM_v3 §3), not an oracle for price or score.** `contracts/randomness/DrandSource.sol` verifies
drand `evmnet` (League of Entropy), scheme `bls-bn254-unchained-on-g1`, 3-second period, against
its published BN254 G2 group public key. `pin()` records the first beacon round due at
`block.timestamp + 6 s` or later; `fulfil(id, proof)` checks a 64-byte BN254 **G1** signature with the
**pairing precompile `0x08`** (`ecPairing`, present on Arbitrum Nitro) after mapping the signed
message to a curve point via RFC 9380 `hash_to_curve` (`expand_msg_xmd` with keccak256, the
Shallue–van de Woestijne map, domain tag `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_`) — see
`contracts/DEPENDENCIES.md` for the derivation and the reason `quicknet` (BLS12-381) is not usable
here: the EIP-2537 precompiles it needs do not exist on this chain. **Empirical finding, load-bearing
because it contradicts the obvious guess:** this beacon's unchained digest of a round is
`keccak256(uint64 round, big-endian)`, not `sha256` — established by verifying two real, live beacons
on chain against the published key (`test/Drand.t.sol::test_realBeaconVerifies`,
`test_aSecondRealBeaconVerifies`), not taken from documentation. The word the round consumes is
`keccak256(signature)`. `MockRandomnessSource` (`USE_MOCK_RANDOMNESS=1`) is testnet-only, contains no
cryptography and says so in its own `IS_MOCK` flag; the live `IRandomnessSource` is an immutable
constructor parameter of `RoundManager`, so which source a deployment uses is fixed at deploy, not
switchable afterward. **Trust statement (`contracts/DEPENDENCIES.md`):** the beacon is public,
verifiable and not controlled by Dollhouse; what the protocol trusts is that a threshold of the League
of Entropy does not collude and that somebody relays the signature — and neither can bias a round's
outcome in Dollhouse's favour, because the only thing a withheld beacon produces is the one outcome
(`T_end = T`) a late buyer could already plan for. Tests:
`Drand.t.sol::test_svdwConstantsAreConsistent`, `test_realSignaturesAreOnTheCurve`,
`test_hashToPointLandsOnTheCurve`, `test_realBeaconVerifies`, `test_aSecondRealBeaconVerifies`,
`test_aBeaconForAnotherRoundIsRefused`, `test_aTamperedSignatureIsRefused`,
`test_pinIsAlwaysInTheFuture`, `test_fulfilBeforeTheBeaconExistsIsRefused`, `test_unknownIdIsRefused`.

There is no external oracle, price feed or off-chain input anywhere on the trust path for PRICE or
SCORE — the drand beacon above is consulted only to fix a timestamp, and a withheld beacon still lets
every round finalize deterministically.

---

## O. Emergency behaviour — none, except forward continuation

There is no pause, circuit breaker, guardian, proxy upgrade or state migration. The only escape
hatch is **forward continuation + sunset** (§A, §J): a new version continues the trunk from the old
head, and the steward's one-shot `announceSunset(successor)` stops the old version opening further
rounds `sunsetDelay` later (mainnet 7 days, testnet 1 hour) and hands the ETH-edge fee and
attribution to the successor. It moves no funds,
unlocks no liquidity and rewrites no history.

What a hook bug means in practice, by blast radius:

- **A revert bug in `beforeSwap` / `afterSwap`** bricks *all* trading in every family pool at once —
  the hook is a singleton. Liquidity stays locked and unreachable forever; there is no removal path
  even for the Locker. This is the worst case and it is unmitigated: a successor can host new pools,
  but the old ones stay bricked.
- **A revert in `_updateScore` or `FeeVault.accrue`** has the same effect: both run inside the swap.
  The handover is the one external call on that path, and it is both `try/catch`-wrapped **and
  gas-bounded** (`min(FORWARD_GAS, gasleft − BOOK_GAS_RESERVE)`, plus 30k-gas staticcalls in the
  hook) precisely so a later version cannot brick an earlier version's swaps — the wrapper alone was
  not enough under EIP-150's 63/64 rule (audit F2, §J/§H).
- **A mispriced fee** cannot be corrected; `hopFeePpm` and the splits are immutable.
- **A wrong winner** is permanent: `canonical[i]` is write-once.
- **A stuck round** (nobody submits or finalizes) freezes succession but not trading; the fix is one
  permissionless call.
- **A FeeVault or BidDeployer bug** can strand ETH in the vault, or brick the keeper/bid path
  entirely (e.g. a mis-set `onlyBidDeployer` leash), permanently; there is no rescue path and no
  setter to repoint either address.

Beyond continuation, the only recovery is social. That is a disclosed, accepted risk, and the
strongest argument for a third-party audit before mainnet.

---

## P. Economic invariants

1. Every link's supply is exactly `1e9·1e18` at launch and monotonically non-increasing afterwards
   (holder burns only).
2. 100% of every link's supply is placed as locked liquidity or burned as dust: zero founder, zero
   team, zero pre-sale.
3. Protocol-owned liquidity is a ratchet — it only grows (curve placement, keeper bids, external
   gifts) and can never be withdrawn by anyone.
4. A trader pays the 1% protocol fee exactly once per traversal of the ETH edge, regardless of route
   depth; family↔family hops pay only `hopFeePpm`. A full-line route costs `1% + hops · 7.5 bps`
   (Sim 7: 1.75% at 10 links, 8.50% at 100 links).
5. `dev + creator + ancestorSleeve + reinforcement == protocolFee` exactly, per fee.
6. Ancestor point queries over a sleeve sum to ≤ the sleeve (floored coefficients), never more.
7. `ledgerTotal[c] <= holdings(c)` for every currency at all times, where `holdings` counts
   unredeemed ERC-6909 claims.
8. Genesis's share of the ancestor sleeve decays as `12/(5M)` and is permanently exactly 2× the
   newest ancestor's weight — never more (Sim 10: 34.5% at M=5, 0.240% at M=1000).
9. Every fee becomes either a claimable ETH balance or locked buy-support; nothing is burned and
   nothing is sold down-chain. Across a sunset the ETH edge follows the live version, and the
   parent-side pots stay with the pool they reinforce. **Precisely what can stay undeployed
   (the audit's F3 correction).** The ledger entry itself is never destroyed and never expires: it
   stays claimable for its generation forever. What is bounded is the *rate and size* at which it
   can be converted into locked liquidity. A generation's ETH is undeployable at a given moment
   only when (a) more than `DAILY_DRAW_BPS` = 10% of the window's base has already been drawn in
   the last 24 h — a delay, not a loss; (b) the parent that the remaining ETH would buy exceeds
   `bidCap(j)` = 2% × max(active bucket, first-range capacity) — so it must be deployed in slices
   across calls, or, at extreme depth where the whole pool is worth dust, cannot be deployed at all
   until the pool grows; or (c) no pool on the chain `0..j` has 1800 s of TWAP coverage, which a
   single swap fixes. The arithmetic dead end is gone: the old normalised rate underflowed to zero
   around generation 10 and made *every* deeper generation's sleeve permanently unspendable
   (≈30% of edge revenue at depth 20 by the audit's estimate); the amount-walking conversion has no
   such floor (`Depth.t.sol`). Floored Fenwick coefficients still leave a few wei per fee
   permanently unclaimable in the vault — that is invariant 6 and it is what makes solvency hold by
   construction.
10. `H ≤ 25%` of the standard curve's absorption at the wall FDV (the brief's reachability
    invariant; `sim.curves.assert_threshold_below_max_absorption`). Sim 1 shows it is necessary and
    **not sufficient** — it bounds the average while the round consumes the total (9.0× at MID).
11. Score is refundable: no sunk slice, no lock, no seasoning, so slot capture costs approximately
    the round-trip fee (Sim 4: 0.15% of capital cycled). Disclosed, not mitigated.

---

## Q. Contract invariants and the tests that assert them

| invariant | asserted by |
|---|---|
| **The adaptive schedule table is exact and pure, capped forever at 12 h; `W` is a flat 15 min on every round** | `Schedule.t.sol::test_theScheduleTableIsExact`, `test_theScheduleIsCappedForever`, `test_theClosingWindowIsFlatOnEveryRound`, `test_anOpenedRoundUsesItsOwnRowOfTheTable`; `Review2.t.sol::test_theClosingWindowIsTheSameConstantOnEveryRound`, `test_theScoreRingsStillCoverTheFlatWindowAndItsTail` |
| **The score ring covers the whole closing window plus the settlement tail** | `Schedule.t.sol::test_theScoreRingCoversTheWholeClosingWindowPlusTheTail` |
| **Late entry is refused on a short round, accepted then refused inside its own window, and always ends before the closing window starts** | `Schedule.t.sol::test_lateEntryIsRefusedOnAShortRound`, `test_lateEntryIsAcceptedInTheWindowAndRefusedAfterIt`, `test_lateEntryAlwaysEndsBeforeTheClosingWindowStarts` |
| **A late entrant with the same closing-window support scores the same as an on-time candidate; support sold before the bell does not count** | `Schedule.t.sol::test_aLateEntrantWithTheSameClosingSupportScoresTheSame`, `test_supportSoldBeforeTheBellDoesNotCount` |
| **The checkpoint ring reconstructs exactly across gaps, and a slot is written once by its first swap only** | `Schedule.t.sol::test_theRingReconstructsExactlyAcrossGaps`, `test_aSlotIsWrittenOnceByItsFirstSwap` |
| **The end cannot be requested before the nominal end, is pinned once and only once, and the true end always falls in the last 3 minutes** | `Schedule.t.sol::test_theEndCannotBeRequestedBeforeTheNominalEnd`, `test_theEndIsPinnedOnceAndOnlyOnce`, `test_theTrueEndFallsInTheLastThreeMinutes` |
| **Nothing settles (submits or finalizes) until the end is known; the submission window starts at fulfilment, not at `T`; the end cannot be settled twice** | `Schedule.t.sol::test_nothingSettlesUntilTheEndIsKnown`, `test_theSubmissionWindowStartsAtFulfilment`, `test_theEndCannotBeSettledTwice` |
| **The deterministic fallback is refused before the timeout, and an unrelayed beacon ends the round at `T` loudly, even if nobody ever requested the end** | `Schedule.t.sol::test_theDeterministicFallbackIsRefusedBeforeTheTimeout`, `test_anUnrelayedBeaconEndsTheRoundAtTLoudly`, `test_theFallbackWorksEvenIfNobodyEverRequestedTheEnd` |
| **The drand verifier checks real, live beacons on chain, refuses a wrong round or a tampered signature, and always pins a future round** | `Drand.t.sol::test_svdwConstantsAreConsistent`, `test_realSignaturesAreOnTheCurve`, `test_hashToPointLandsOnTheCurve`, `test_realBeaconVerifies`, `test_aSecondRealBeaconVerifies`, `test_aBeaconForAnotherRoundIsRefused`, `test_aTamperedSignatureIsRefused`, `test_pinIsAlwaysInTheFuture`, `test_fulfilBeforeTheBeaconExistsIsRefused`, `test_unknownIdIsRefused` |
| **The purse is locked under the trunk coin of its generation, in one bid, and a losing sibling never receives purse liquidity** | `Purse.t.sol::test_thePurseIsDeployedUnderTheTrunkCoin`, `test_aLosingSiblingNeverReceivesPurseLiquidity`, `test_theDestinationIsNotAKeeperChoice`, `fork/Purse.fork.t.sol::testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing` |
| **Genesis and an uncrowned generation are refused; the amount conserves; the daily bucket and the bounty rule are unchanged** | `Purse.t.sol::test_genesisIsNotAnAncestorDeployment`, `test_anUnknownGenerationIsRefused`, `test_theAmountConserves`, `test_theDailyBucketStillBounds`, `test_theBountyRuleIsUnchanged` |
| Fixed supply, no mint | `Invariants.t.sol::invariant_supplyIsConstant`; `Genesis.t.sol::test_supplyIsEntirelyLocked` |
| Locker positions never shrink | `Invariants.t.sol::invariant_lockedPositionsNeverDecrease` |
| Only the Locker may add liquidity | `Genesis.t.sol::test_addLiquidityRevertsForNonLocker` |
| Liquidity can never be removed | `Genesis.t.sol::test_removeLiquidityAlwaysReverts`, `test_lockerHasNoExit` |
| Donations refused | `Genesis.t.sol::test_donateReverts` |
| Only factory-registered keys initialize, at the registered price | `Genesis.t.sol::test_initializeRevertsForUnregisteredKey`, `test_initializeRevertsAtWrongPrice`, `test_poolIsRegisteredAndPriced`, `test_registerPoolOnlyFactory` |
| Genesis is once-only | `Genesis.t.sol::test_genesisIsOnceOnly` |
| **Genesis curve is computed in-contract and caller-independent (C2)** | `GenesisCurve.t.sol::test_twoCallersGetAnIdenticalGenesisCurve`, `test_genesisCurveIsTheStandardShapeInGenesisUnits` |
| **A half-deployed stack cannot be launched into** | `GenesisCurve.t.sol::test_wireRefusesAHalfDeployedStack` |
| Curve ranges contiguous and token-only | `Genesis.t.sol::test_curveRangesAreContiguousAndTokenOnly`; `CurveMath.t.sol::test_rangeHoldsItsShare` |
| Curve closed form `s·sqrt(Fa·Fb)` | `CurveMath.t.sol::test_buyingOutARangeCostsSqrtFaFb`, `test_fdvRoundTrip`, `test_higherFdvIsLowerTick` |
| Bond required to register | `Genesis.t.sol::test_registerCandidateRequiresTheBond`; `Round.t.sol::test_registrationEscrowsBondsAndOpensTheRound` |
| Chain-depth limit refused at registration (L6) | `RoundGuards.t.sol::test_registrationRefusesToExceedTheChainDepthLimit` |
| **Bond doubles with depth, is capped, and is refunded/forfeited at the amount actually posted (F6)** | `Depth.t.sol::test_bondDoublesEveryFourLinksAndIsCapped`, `test_theBondIsEnforcedRefundedAndForfeitedAtTheScheduledAmount` |
| **The beta depth cap `MAX_INDEX` refuses the round that would go past it** | `Depth.t.sol::test_maxIndexRefusesTheRoundThatWouldGoPastIt` |
| **Candidate ids are paginable (F10)** | `Round.t.sol::test_candidateIdsArePaginated` |
| Candidate pools gated until `tradingStart` | `Round.t.sol::test_candidatePoolIsGatedUntilTradingStart`; `Swap.t.sol::test_swapRevertsBeforeTradingStart` |
| **Score = the pool's own parent delta, in all four orientations (C1)** | `HookScore.t.sol::test_scoreExactInParentSpecified`, `test_scoreExactOutParentSpecified`, `test_scoreExactInParentUnspecified`, `test_scoreExactOutParentUnspecified`, `test_scoreIsAdditiveAcrossOrientations` |
| **A sniped buy scores the pool delta and never goes negative** | `HookScore.t.sol::test_snipeWindowBuyScoresPoolDeltaAndNeverGoesNegative`, `test_snipeDecayMovesTheScoreNotTheSign` |
| Snipe tax profile (99% at +1 s, none at +4 s) | `Round.t.sol::test_snipeTaxBitesAtOneSecondButNotAtFour` |
| Submission window defeats the ordering attack (attack-log #1) | `Round.t.sol::test_submitOrderingAttackCannotWin` |
| Accumulators clamp at `T_end`; a post-bell dump cannot move a score | `Round.t.sol::test_tailExtensionAndPostBellFreeze` |
| Finalize crowns, refunds the winner, forfeits losers | `Round.t.sol::test_finalizeCrownsWinnerRefundsBondAndForfeitsLosers` |
| Finalize is idempotent; a stale call cannot overwrite | `Round.t.sol::test_staleFinalizeIsIdempotent` |
| **Bond refund has a pull fallback** | `RoundGuards.t.sol::test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth` |
| No-winner closes; threshold decays ×0.9 to the floor | `Round.t.sol::test_noWinnerDecaysThresholdToTheFloor` |
| Burning head supply lowers `H` (L10, documented) | `RoundGuards.t.sol::test_burningHeadSupplyLowersThreshold` |
| Next round is quoted in the new head | `Round.t.sol::test_secondRoundIsQuotedInTheNewHead` |
| ≤1 winner per index; append-only history with consistent reverse index | `Invariants.t.sol::invariant_canonicalHistoryIsAppendOnly` |
| Protocol fee only on the ETH edge, once per edge leg | `Round.t.sol::test_routedBuyChargesProtocolFeeOnlyOnTheGenesisLeg`; `Invariants.t.sol::invariant_noProtocolFeeOnFamilyPools` |
| Fee correct for exact-in and exact-out, on either side | `Swap.t.sol::test_buyExactIn_chargesEthSideFees`, `test_sellExactIn_chargesEthSideFees`, `test_buyExactOut_chargesEthSideFees` |
| **Exact-output SELLS are grossed up to the same fee basis as exact-in (F9)** | `Swap.t.sol::test_sellExactOut_chargesTheSameFeeBasisAsExactIn` |
| **The snipe tax is identical in both swap modes, decays to the hop fee alone, and an exact-output swap at ≥100% total rate is refused** | `SnipeTax.t.sol::test_snipeTaxIdenticalForExactInAndExactOut`, `test_afterWindowBothModesPayOnlyTheHopFee`, `test_exactOutRevertsWhenRatesReachOneHundredPercent` |
| hookData trusted only from the canonical router | `Swap.t.sol::test_attributionOnlyFromRouter`; `Router.t.sol::test_hookDataOnlyTrustedFromTheCanonicalRouter` |
| Allocations sum exactly to the fee | `FeeVault.t.sol::test_allocationSumsExactly` |
| Unattributed fees fall back to the flywheel / genesis | `FeeVault.t.sol::test_unattributedFeesFallBackToGenesis` |
| Fenwick range-add / point-query exact; no ancestry loop | `FeeVault.t.sol::test_fenwickPointQueriesMatchBruteForceLedger` |
| Weight shape and sleeve conservation | `FeeVault.t.sol::test_ancestorWeightShapeAndConservation` |
| Pull claims; no double claim; recipient transfer | `FeeVault.t.sol::test_devAndCreatorClaims`, `test_creatorRecipientIsTransferable` |
| **Candidate trades split the creator share 50/50 with the head creator, during the round only** | `RouterGuards.t.sol::test_candidateBuySplitsTheCreatorShareWithTheHeadCreator`, `test_canonicalBuyPaysTheWholeCreatorShareToThatLinksCreator`, `test_losingCandidateCreatorKeepsTheirHalf` |
| Vault solvency in every currency | `Invariants.t.sol::invariant_vaultIsSolvent` |
| **Keeper model: parent from the keeper, priced by the TWAP chain, no swap** | `FeeVault.t.sol::test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid`, `test_deployAncestorDoesNotSwap` |
| **Sleeve and 2%-of-active-range caps; partial pot draws** | `FeeVault.t.sol::test_deployAncestorRespectsSleeveAndSizeCap`, `test_genesisBidDeploysFromTheHopPotAloneAndDrawsPartially`, `test_deployGenesisBidDepositsForfeitedBonds` |
| **TWAP must actually cover the window and have ≥2 observations (M2)** | `FeeVault.t.sol::test_deployRevertsWhenTheTwapIsNotReady`, `test_deployAncestorRevertsOutsideTheTwapBand` |
| **A 30-minute pump cannot raise, and a crash immediately lowers, what the sleeve pays: every link is priced at `min(spot, TWAP_30m, TWAP_7d)` (F4, audit 1)** | `Keeper.t.sol::test_aThirtyMinutePumpCannotRaiseWhatTheSleevePays`, `test_aCrashedConversionPoolIsPricedAtSpot` |
| **A pool without a 7-day average is priced on the fast one and says so (`SlowTwapUnavailable`)** | `Keeper.t.sol::test_aYoungPoolPricesOnTheFastAverageAndSaysSo` |
| **A generation's ETH sleeve is drawable at most 10% of a continuously refilling token bucket, not a resetting window that could burst ≈19% at a boundary (F4, audit 6)** | `Keeper.t.sol::test_theDailyDrawdownLimitBindsAndRefills` |
| **The conversion still works twelve links down, where the old normalised rate underflowed to zero (F3)** | `Depth.t.sol::test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed` |
| **The keeper bounty exceeds the gas of the call at beta scale (F7)** | `Bid.t.sol::test_genesisBidBountyBeatsTheGasOfTheCall` |
| **Bid arithmetic never owes more than it was given (L2); range always has width (L3)** | `Bid.t.sol::testFuzz_bidNeverOwesMoreThanItWasGiven_currency0/1`, `test_bidAbsorbsTheRoundingWei`, `test_bidRangeAlwaysHasWidth` |
| **Cold pools are sized from their own curve and can still be supported (H3)** | `Bid.t.sol::test_coldPoolIsSizedFromItsCurveAndCanReceiveABid`, `test_coldPoolAcceptsALockedBid`, `test_activeRangeReserveIsMuchSmallerThanTheVirtualReserve`, `FeeVault.t.sol::test_coldPoolStillHasASizeCap` |
| **Mirrored (token-is-currency0) orientation launches, trades, wins and takes a keeper bid** | `Mirrored.t.sol::test_mirroredCandidateLaunchesUpsideDown`, `test_mirroredCandidateTradesAndWins`, `test_keeperBidOnAMirroredLinkUsesTheElseBranch` |
| **Every deployed contract, `BidDeployer` included, fits under the EIP-170 runtime limit** | `CodeSize.t.sol::test_everyDeployedContractFitsUnderEip170` |
| **`Locker.depositBid` and `FeeVault`'s four keeper hooks accept only `BidDeployer`** | `Bid.t.sol`, `FeeVault.t.sol` `NotBidDeployer`/`onlyBidDeployer` assertions |
| **The FeeVault/BidDeployer address-prediction handshake fails loudly if deployed out of order** | `BidDeployer` constructor checks (`NoCode`, `NotWired`), `test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid` setup |
| Router: multi-hop, slippage, depth cap, ETH refund, family-only path | `Router.t.sol::test_buyAndSellThroughThreeLinks`, `test_minOutReverts`, `test_depthCapRejectsTooManyHops`, `test_refundsUnusedEth`, `test_swapPathBetweenFamilyLinks` |
| **Router value checks, no sweepable ETH, round-trip output, mid-route partial fill (M1/M5/L12)** | `RouterGuards.t.sol::test_swapPathRequiresMatchingValueOnAnEthRoute`, `test_swapPathRejectsValueOnATokenRoute`, `test_routerHeldEthCannotBeSwept`, `test_roundTripPathReportsItsOutput`, `test_midRoutePartialFillSettlesEveryCurrency` |
| **Candidate routes exist and are round-gated (M4)** | `RouterGuards.t.sol::test_buyAndSellCandidateWithEth`, `test_unknownCandidateIsRejected` |
| **Sunset is steward-only, once, 7 days, contract-successor, and changes nothing else** | `Sunset.t.sol::test_onlyTheStewardMayAnnounce`, `test_announceIsOnceAndForever`, `test_successorMustBeAContract`, `test_zeroStewardMeansNoSunsetIsPossible`, `test_theDelayIsSevenDaysAndRoundsOpenThroughout`, `test_aRoundOpenWhenTheSunsetLandsStillFinishesAndCrowns`, `test_openingANewRoundRevertsAfterTheSunset`, `test_everythingElseKeepsWorkingAfterTheSunset` |
| **A gas-burning successor cannot brick any swap, and the negative caches are armed exactly once (F2)** | `Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps` |
| **`cancelSunset` works before the effect, never at or after it, and only once ever (F2)** | `Sunset.t.sol::test_cancelSunsetWorksBeforeTheEffectAndNotAfter`, `test_cancelSunsetNeedsAnAnnouncement` |
| **Lazy head adoption: v2 opens no round before the handover, and adopts the head v1 crowned AFTER v2 was deployed (F1)** | `Continuation.t.sol::test_v2CannotOpenARoundBeforeTheHandover`, `test_v2AdoptsTheHeadV1CrownedAfterV2WasDeployed` |
| **Continuation: inherited head, no second genesis, delegated reads up to 8 hops, cross-version routes and bids** | `Continuation.t.sol::test_v2StartsAtTheInheritedHead`, `test_v2CannotCreateAGenesis`, `test_delegatedReadsForPriorIndices`, `test_v3ContinuingV2ResolvesPriorIndicesThroughTwoHops`, `test_v2RoundCrownsLinkTwoQuotedInV1sHead`, `test_routeFromEthAcrossBothVersions`, `test_lensChainViewSpansVersions`, `test_v2GenesisBidIsPlacedByV1sVault`, `test_deployAncestorForAPriorVersionGenerationGoesThroughV1sVault`, `test_depositExternalBidRefusesAForeignLink` |
| **Handover: the edge forwards after sunset, stays before it, queues rather than books locally on a broken successor, and only a prior vault may push it** | `Continuation.t.sol::test_afterTheHandoverTheEdgeIsBookedByV2AndAttributedToItsCreator`, `test_beforeTheHandoverTheEdgeStaysInV1sVaultUnattributed`, `test_v1DevClaimsAccruedBeforeTheHandoverSurviveIt`, `test_theEdgeForwardsTwoHopsFromV1ThroughV2ToV3`, `test_aBrokenSuccessorQueuesInsteadOfBookingLocally`, `test_accrueForwardedOnlyAcceptsAPriorVaultInTheChain` |
| Score and observation accumulators advance | `Swap.t.sol::test_scoreAndObservationAccumulate` |
| Lens views (paginated round, chain view) | `Round.t.sol::test_lensViews` |
| Gas envelopes (logged, not asserted) | `test_gas_createGenesis`, `test_gas_swapBuyExactIn`, `test_gas_roundLifecycle`, `test_gas_routedThreeHopBuy`, `test_gas_deployAncestor`, `test_gas_deployAncestorConsultChain`, `test_gas_announceSunset`, `test_gas_genesisSwapAcrossTheHandover` |
| **A continuation cannot adopt through an unadopted intermediate, and an unadopted continuation cannot announce its own sunset (audit 2)** | `Continuation.t.sol::test_v3CannotAdoptThroughAnUnadoptedV2`, `test_adoptionRefusesASunsetButUnadoptedPrior` |
| **`sunsetDelay` is a constructor parameter, floored at `MIN_SUNSET_DELAY`, mainnet 7 days / testnet 1 hour** | `Continuation.t.sol::test_sunsetDelayIsAConstructorParameter` |
| **A post-sunset swap with too little gas queues the fee instead of booking it locally, and a permissionless flush delivers it; the queue reaches a sixth version through one flush per hop (audit 4)** | `Continuation.t.sol::test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt`, `test_theEdgeReachesTheSixthVersionThroughFlushes`, `test_aBrokenSuccessorQueuesInsteadOfBookingLocally` |
| **Every keeper conversion link is priced at `min(spot, TWAP_30m, TWAP_7d)`, so a crashed conversion pool is priced at spot (audit 1)** | `Keeper.t.sol::test_aCrashedConversionPoolIsPricedAtSpot` |
| **The keeper bounty is floored at `MIN_BOUNTY_WEI` and capped at 20% of the ETH a call consumes (audit 5)** | `Keeper.t.sol::test_theBountyFloorIsPaidAtRunTwoSizes`, `test_belowTheFloorTheBountyIsCappedAtTwentyPercent` |
| **`deployHopPot` deploys the terminal generation's hop pot with no ETH entitlement, permissionless (audit 3)** | `Keeper.t.sol::test_theHeadsHopPotDeploysWithNoEthEntitlement` |
| **The drawdown allowance is a continuously refilling token bucket, not a resetting window (audit 6)** | `Keeper.t.sol::test_theDailyDrawdownLimitBindsAndRefills` |
| **A successor `sync`ing an ERC-20 cannot break the router's or Locker's native settlement (audit 7B)** | `Sunset.t.sol::test_aSuccessorSyncingAnErc20DoesNotBreakNativeSettlement` |
| **A dirty-word successor answer is treated as no answer, not a reverting `abi.decode` (audit 7A)** | `Sunset.t.sol::test_aDirtyWordSuccessorCannotBrickRoutes` |
| **A creator-right transfer leaves what already accrued with the old recipient (`creatorAccrued`/`claimCreatorAccrued`) and rejects the zero address** | `FeeVault.t.sol::test_transferringTheCreatorRightLeavesAccruedFeesBehind` |
| **A v4 protocol-fee accrual (if the controller ever configures one) is subtracted from the score, not counted as absorption (audit 9)** | `HookScore.t.sol::test_aV4ProtocolFeeDoesNotInflateTheScore` |
| **Candidate routes stay hop-capped and attributed after the round, walking the round's recorded parent (audit 8)** | `RouterGuards.t.sol::test_candidateRoutesAreHopCapped` |
| **The vesting schedule releases nothing before the cliff, unlocks the amount accrued since `start` at the cliff, is linear onward, and never pays more than the allocation** | `DevVesting.t.sol::test_nothingVestsBeforeTheCliff`, `test_theCliffUnlocksWhatAccruedSinceStart`, `test_linearBetweenCliffAndEnd`, `test_everythingVestedAtTheEndAndNeverMore`, `test_releaseTwicePaysTheDeltaOnly` |
| **The genesis developer allocation is 3% of supply, minted to the vesting contract, and candidates get none** | `DevAllocation.t.sol::test_genesisSupplyIsConserved`, `test_vestingIsWiredToTheGenesisTokenAndTheDeveloper`, `test_theAllocationVestsOnTheAnnouncedSchedule`, `test_candidatesHaveNoAllocationAtAll`, `test_genesisEmitsTheDevAllocationEvent` |
| **The steward, developer and vesting-beneficiary roles each move on an identical 7-day announce/permissionless-execute/cancel delay, and no new power appears when they do** | `RoleTransfer.t.sol::test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute`, `test_sunsetPowersFollowTheNewSteward`, `test_onlyTheStewardAnnouncesOrCancelsAndOnePendingAtATime`, `test_developerTransferWaitsOutTheDelayAndIsPermissionlessToExecute`, `test_accruedDevBalanceIsClaimableByWhoeverHoldsTheRoleAtClaimTime`, `test_onlyTheDeveloperAnnouncesOrCancelsAndOnePendingAtATime`, `DevVesting.t.sol::test_beneficiaryTransferWaitsOutTheDelay` |
| **The factory's deployment transaction stays under the EIP-3860 initcode limit with the `DevAllocation` argument added** | `CodeSize.t.sol::test_factoryDeploymentTransactionFitsUnderEip3860` |
| **`DevVesting` and `DevVestingDeployer` fit under EIP-170 alongside the rest of the deployed stack** | `CodeSize.t.sol::test_everyDeployedContractFitsUnderEip170` |

`forge test` at the tree that adds MECHANISM_v3 (the adaptive schedule, the random end, the
contestable purse): **226 passed, 0 failed** across **27 suites** — three new: `Schedule.t.sol` (21
tests: the duration/registration/late-entry/closing-window schedule, the checkpoint rings, the
request/fulfil/timeout end lifecycle), `Drand.t.sol` (10 tests: the BN254 verifier against two real,
live beacons plus refusal cases), `Purse.t.sol` (12 tests: ranking, the top-2 split, staleness and
edge weights, all rewritten in review 3 for the uncontested purse) — superseding the 183-test, 24-suite tree below. No existing test was changed, renamed
or removed for this tranche; `RoundManager`, `FamilyHook` and `BidDeployer` each gained the new
functions described in §A/§C/§F/§J, with no behaviour change to anything that predates them.

`forge test` at the tree that adds the developer vesting allocation and the role-transfer paths:
**183 passed, 0 failed** across **24 suites** (Bid 8, **CodeSize 2**, Continuation 24, CurveMath 4,
DeployConstants 3, Depth 4, **DevAllocation 5**, **DevVesting 9**, FeeVault 19, Genesis 13,
GenesisCurve 3, HookScore 8, Invariants 1, Keeper 8, Mirrored 3, **RoleTransfer 6**, Round 13,
RoundGuards 3, Router 7, RouterGuards 15, SnipeTax 2 + SnipeTaxCeiling 1, Sunset 14, Swap 8) —
superseding the 162-test, 21-suite tree that closed the gas-optimization pass. `CodeSize` gains a
second test (`test_factoryDeploymentTransactionFitsUnderEip3860`, §T) alongside the existing
`test_everyDeployedContractFitsUnderEip170`, which now also asserts `DevVesting` and
`DevVestingDeployer` fit under EIP-170. The three new suites are entirely additive — no existing test
was changed, renamed or removed for this tranche — and no behaviour change is intended or observed
outside the new vesting contract and the three new transfer-triple functions on `RoundManager` and
`FeeVault`.

`forge test` at the tree after the gas-optimization pass: **162 passed, 0 failed** across the same
21 suites as the 160-test tree (Bid 8, CodeSize 1, Continuation 24, CurveMath 4, DeployConstants 3,
Depth 4, **FeeVault 19**, Genesis 13, GenesisCurve 3, HookScore 8, Invariants 1, Keeper 8, Mirrored
3, Round 13, RoundGuards 3, Router 7, RouterGuards 15, SnipeTax 2 + SnipeTaxCeiling 1, Sunset 14,
Swap 8), with no behaviour change intended or observed. The two added tests both close the run-3
sizing-view finding (§J, `BidDeployer.maxParentForDeploy`) and land in `FeeVault.t.sol`:
`test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor` (the view's quote is the real maximum
in every branch of the piecewise bounty inverse, not just the proportional one) and
`test_deployAncestorAcceptsTheBelowFloorQuote` (the quote a below-floor allowance produces is fed
straight into a real `deployAncestor` and accepted).

`forge test` at the tree that closes the final external contract review: **160 passed, 0 failed** across the same
21 suites as the 145-test tree (Bid 8, CodeSize 1, **Continuation 24**, CurveMath 4,
DeployConstants 3, Depth 4, **FeeVault 17**, Genesis 13, GenesisCurve 3, **HookScore 8**, Invariants 1,
**Keeper 8**, Mirrored 3, Round 13, RoundGuards 3, Router 7, **RouterGuards 15**, SnipeTax 2 +
SnipeTaxCeiling 1, **Sunset 14**, Swap 8) — no new suite file this tranche, all fifteen new tests land
inside existing suites, one per finding of the final external contract review:

- **`Continuation`** 19 → 24 (+5): the transitive adoption guard
  (`test_v3CannotAdoptThroughAnUnadoptedV2`, `test_adoptionRefusesASunsetButUnadoptedPrior`, audit 2),
  `sunsetDelay` as a constructor parameter (`test_sunsetDelayIsAConstructorParameter`, audit 2), and
  the queue-and-flush forwarding model replacing local booking
  (`test_aLowGasPostSunsetSwapQueuesTheEdgeAndAFlushDeliversIt`,
  `test_theEdgeReachesTheSixthVersionThroughFlushes`, audit 4) — `test_aBrokenSuccessorFallsBackToBookingLocally`
  is renamed `test_aBrokenSuccessorQueuesInsteadOfBookingLocally` to match the new behaviour, not an
  added test.
- **`Keeper`** 3 → 8 (+5): `test_aCrashedConversionPoolIsPricedAtSpot` (min-of-three pricing, audit
  1), `test_theBountyFloorIsPaidAtRunTwoSizes` / `test_belowTheFloorTheBountyIsCappedAtTwentyPercent`
  (`MIN_BOUNTY_WEI` + the 20% ceiling, audit 5), `test_theHeadsHopPotDeploysWithNoEthEntitlement`
  (`deployHopPot`, audit 3) — `test_theDailyDrawdownLimitBindsAndResets` is renamed
  `test_theDailyDrawdownLimitBindsAndRefills` to match the token-bucket allowance (audit 6).
- **`Sunset`** 12 → 14 (+2): `test_aSuccessorSyncingAnErc20DoesNotBreakNativeSettlement`
  (`sync(native)` before native settlement, audit 7B) and
  `test_aDirtyWordSuccessorCannotBrickRoutes` (raw-word validation instead of a reverting
  `abi.decode`, audit 7A).
- **`FeeVault`** 16 → 17 (+1): `test_transferringTheCreatorRightLeavesAccruedFeesBehind`
  (`creatorAccrued` / `claimCreatorAccrued`, zero-address rejected).
- **`HookScore`** 7 → 8 (+1): `test_aV4ProtocolFeeDoesNotInflateTheScore` (audit 9).
- **`RouterGuards`** 14 → 15 (+1): `test_candidateRoutesAreHopCapped`, extended to cover a
  post-round candidate route (audit 8).

Earlier tranches added `Depth.t.sol` (F3/F6, the bond schedule and `MAX_INDEX`), `SnipeTax.t.sol`
(F9), `CodeSize.t.sol` (the EIP-170 regression) and `DeployConstants.t.sol` (the locked deploy
constants); those suite counts are unchanged in this tranche.

**Invariant campaign (M6).** `foundry.toml` sets `runs = 32`, `depth = 64`, `fail_on_revert = false`
— 2048 calls, 6 reverts in the last run. Because a handler that silently swallows every revert can
pass vacuously, `FamilyHandler` maintains **ghost counters** and `InvariantsTest.afterInvariant()`
asserts, at the end of every run, that each path which was *attempted* also *succeeded* at least
once: `deployAttempts → deploysSucceeded`, `successionAttempts → successions`,
`claimAttempts → claims`.

Not asserted anywhere: the "one protocol fee per *transaction*" framing, deliberately abandoned in
attack-log #2 — the guarantee is per ETH-edge traversal, and a path that crosses the genesis pool
twice pays twice.

---

## R. Known unavoidable risks (measured)

Numbers are the MID deploy configuration at the 900 s window (`docs/sim-results-final.md`,
`python -m sim.scenarios --all --curve mid --h 0.15 --hop-bps 7.5 --final`, seed 20260910) unless a
row says otherwise.

| risk | measured number | source |
|---|---|---|
| Refundable score ⇒ cheap slot capture | 100% capture at ≥2× the honest leader's average, cost **$5 on $3,220 cycled = 0.15%**, exactly `1 − (1 − f_hop)²` at 7.5 bps; profitable ≈3,573× against an estimated $17,250 slot value | Sim 4 (MID) |
| Dynastic capture | the `dynastic` variant can end the round with a mark-to-market gain — capture is not even a cost | Sim 4 |
| Last-second spikes | `late_spike` tops the round **0%** of the time; one second of capital contributes 1/900 of itself to the average | Sim 4 |
| Block-1 snipers | the 99% tax prices the sweep, it does not forbid it: 98% of first-second fills with the tax on, mean **+$445/round** P&L (vs $8,110 with the tax off), at $311/round of tax paid | Sim 5 (MID) |
| Win-then-dump | no lock, no seasoning: a winner may sell immediately | design decision |
| Weak old links as routing bottlenecks | after a 99% dump at #6 the full line costs **57.7%** (vs 13.1% healthy); best-routing through an external venue brings it to 10.8% | Sim 3 (MID) |
| Reinforcement is not a shock absorber | three rounds of sleeve = 0.713% of #6's parent reserve, moving a 99%-dump drawdown 94.6% → 94.6%; even at the 2% cap, 94.5% | Sim 3, Sim 9 |
| Embedded parent released on the way down | every descendant of a dumped link inherits the drawdown through the telescoping price product; ancestors untouched | Sim 8 |
| Wall discontinuity | at 66% of float a wall-shaped curve takes **4.0%** off FDV in one clip, 8.24× trend; the cliff is computable in advance from the deploy constants by anyone | Sim 8 |
| External ETH pools bypass the edge fee | BEST and DEPTH_CAPPED(5) send **100%** of quoted deep routes to an external market — the mitigation and the revenue leak are one mechanism | Sim 7 |
| Deep routes degrade on impact, not fees | full-line effective loss rises 17.14% → **67.17%** from 10 to 100 links at a constant 0.5%-of-FDV trade | Sim 7 (MID) |
| Hop fee is the ceiling on chain length | at 7.5 bps a 100-hop route pays 7.5% in hop fees — the same order as the edge fee itself | Sim 7 |
| Curve vs threshold | at h = 0.15% the median MID winner ends the round with 60.2% of float sold, having absorbed 9.0× the threshold in total | Sim 1 (MID) |
| **Closing-window sniper (MECHANISM_v3)** | a **window sniper** — capital equal to the leader's, bought at the start of the closing window `W` and held — beats a leader still spreading its buys ≈82% of the time in a 4-hour round and ≈93% of 15-minute rounds, fixed or random end alike. This is the closing-window rule working exactly as defined (highest average at the end wins; late money that stays counts fully), not a bug, and is disclosed as "a long-time leader can lose to money that arrives for the closing window" | Sim 13, `docs/sim-results-v3.md` |
| **Random end's actual value** | on a 15-minute round the random end cuts a last-second sniper's flip rate 2.4% → 0.2%; spreading a buy across the last 3 minutes instead of dropping it at once keeps 67% of its value and still cuts the flip rate 18.2% → 7.6%. On a 12-hour round a fixed end already flips 0.00%, so the random end mainly protects SHORT rounds — it is kept uniform across all durations for simplicity, not because it matters equally everywhere | Sim 13 |
| **Purse capture by parked capital (MECHANISM_v3), SUPERSEDED 2026-09-13** | measured against the contested purse: parking capital equal to the leader's trailing support for one day was break-even at the modelled fee flow (breakeven multiple 0.61×). Review 3 fixes the destination at the round result, so there is nothing left to park for | Sim 11 |
| **Dump penalty on the purse works (MECHANISM_v3), SUPERSEDED 2026-09-13** | measured against the contested purse: a winner dumping 90% lost the lead 92% of the time. Review 3 removes the penalty deliberately (MECHANISM_v3 §1) | Sim 11 |
| **Sim caveat, disclosed, no constant change** | at rounds ≥ 8 h the demand model (∝ √D) implies absorbing more parent tokens than exist; the reported curve exhaustion at high rounds is a modelling artefact of Sim 12, not a contract behaviour — real rounds are bounded by the parent's actual float. Monitor on mainnet | Sim 12, `docs/sim-results-v3.md` §caveat |
| **Each link is worth a small fraction of its parent** | measured winners land at **5–8% of parent value in ETH**; this is the weakest assumption in the whole design, and keeper precision, threshold meaning, route impact and "value flows to genesis" all rest on it | audit §3 |
| **The threshold stops being a real cost at depth** | `H` is 0.15% of the *parent's supply*, so clearing it for 900 s costs ≈$100 at generation 1, ≈$7 at generation 2 and **< $1 from generation 3**; from there the **bond** is the binding cost of extending the chain, which is why it now doubles every 4 links (§C) | audit F6 |
| **Keeper economics are volunteer economics, and are still negative at small sizes** | the bounty is `max(1% of what is deployed, MIN_BOUNTY_WEI)`, capped at 20% of the ETH a call consumes (audit 5); sized against the first curve range so a `deployGenesisBid` beats the gas of the call at beta scale (≈3.8× at 0.01 gwei), but Run 2 measured gas ≈215× the (pre-fix) bounty at generation 1 and 121 wei of bounty at generation 8 — the floor and cap narrow this but do not eliminate it, nothing *obliges* anyone to call, and an ancestor's sleeve sits idle until somebody does | audit F7, audit 5, `Bid.t.sol::test_genesisBidBountyBeatsTheGasOfTheCall`, `Keeper.t.sol::test_theBountyFloorIsPaidAtRunTwoSizes`, `test_belowTheFloorTheBountyIsCappedAtTwentyPercent` |
| Thin-demand stalling | at 0.20× demand 10.8% of rounds fail and #20 takes 23.1 rounds instead of 20; every chain still gets there | Sim 2 (MID) |
| Creator / developer revenue is linear in edge volume and nothing else | $250k edge volume per round over 20 generations: developer $10,000, creators $20,000 in total | Sim 6 |
| Reinforcement beats burn only narrowly | 74.6% drawdown vs 76.5% (burn) vs 77.7% (nothing), +10.96% parent bid within 50% of spot | Sim 9 (MID) |
| No paid third-party audit | two independent adversarial passes (the final independent contract review + the attack log) and a testnet run, not a commercial audit | `docs/reviews/2026-09-11-contract-review-final.md`, `docs/attack-log.md` |
| Liveness: the **whole upgrade path** has never fired on a public chain | **CLOSED by Run 3 (2026-09-11):** `announceSunset`, a real 3600 s delay, `cancelSunset` (on a disposable stack), lazy adoption, both branches of the ETH-edge handover, and both cross-version payout paths all fired live. Only the 7-day slow-TWAP floor remains never-fired; per the Audit Standard, still reported as broken until it does | `research/INTERFACES.md`, `docs/TESTNET_RUN.md` |
| **Run 3 finding: the advertised keeper sizing view reads 0 below the bounty floor** | `maxParentForDeploy(j)` early-returns 0 whenever `drawableEth(j) <= MIN_BOUNTY_WEI`, which is true at beta sleeve sizes even though `deployAncestor` itself succeeds there (its own bounty floor lets it accept the call). An honest keeper reading only the sizing view would conclude nothing is deployable and never call. Fix pending in the gas pass | Run 3 phase A, `deployAncestor(1, …)`; `research/INTERFACES.md` |
| **Run 3 finding: the in-swap forward needs ~1.5M gas of headroom** | The post-sunset in-swap fee forward only succeeds if the caller supplies ~1.5M gas above what the swap itself uses; an ordinary estimated-gas trade always takes the QUEUE branch instead. The queue is designed for exactly this, but it means post-sunset fees routinely need a permissionless `flushForward` call, and `flushForward` is therefore routine operator work, not an edge case | Run 3 phase B, steps p/q1/q2; `research/INTERFACES.md` |
| No off switch | a hook revert bug bricks every pool permanently (§O); continuation only helps future pools | design decision |

**Plain-language disclosure items (final audit §5, a–i) and their current status.** The auditor
listed nine things a non-technical user must be told and none of which the documentation said.
Each is either fixed in code or is an accepted risk that the UI must state in these words.

| # | what a trader must be told | status |
|---|---|---|
| (a) | **From about the third generation on, becoming the head costs roughly the bond and nothing else** — the absorption threshold costs under a dollar to clear there | **Accepted, mitigated and disclosed.** The bond now doubles every 4 links to a cap (§C, audit F6), so depth is never free; the threshold's decay with depth is structural and is not fixed. |
| (b) | **Each new coin is typically worth only 5–8% of the one before it in ETH** | **Disclosed.** Structural; it is the weakest assumption in the design (row above). |
| (c) | **Roughly a third of the fees attributed to deep coins used to be payable to nobody** | **Fixed (audit F3).** The conversion walks the amount instead of a normalised rate, so no generation's sleeve is arithmetically unspendable; what remains is a *rate* limit and a *size* cap, spelled out in §P invariant 9. |
| (d) | **Ancestor payouts depend on volunteer keepers, and the average price they are paid at can be gamed** | **Partly fixed, rest disclosed (audit F4/F7, sharpened by audit 1/5/6).** Every link is priced at `min(spot, TWAP_30m, TWAP_7d)`, a generation can be drawn down at most 10% of a continuously refilling bucket, and the bounty is floored at `MIN_BOUNTY_WEI` and capped at 20% of the ETH consumed — but nobody is obliged to call, a *patient* drag of both averages is still possible, and at the smallest deployment sizes the bounty (even at the 20% cap) can still be below mainnet gas: a disclosed dead zone, not a fixed one. |
| (e) | **The upgrade switch is irreversible once it takes effect, moves all future edge fees to the new version, and the steward key is a single point of failure** | **Partly fixed, rest accepted (and the 2026-09-11 design decision supersedes the earlier multisig recommendation).** A faulty successor can no longer freeze trading on any old pool (gas-bounded forwarding and 30k-gas staticcalls, audit F2), and the steward can take an announcement back once, before it lands (`cancelSunset`). After it lands it is permanent, the fee redirection is real, and the steward is deliberately a **single cold-signer address, not a multisig** ("Multi-sig and cold developer address are too much to do for this... single cold signer ledger wallet, but add pathways to security upgradability"): the mitigation for the single-key risk is that the steward role itself is now transferable on a public 7-day announce/execute/cancel delay (§M), so a compromised or lost steward key can be replaced without ever needing a multisig, and `address(0)` still removes the power and the upgrade path together for a deployment that wants neither. |
| (f) | **The upgrade as coded created two competing chains** | **Fixed (audit F1).** Lazy head adoption: a continuation opens no round until the prior version is sunset-effective, names it, and is idle, so two versions can never crown the same index (§A). |
| (g) | **The developer address can never be changed** | **Accepted.** It is immutable in `FeeVault` with no setter and no transfer. The deploy script now *requires* a `DEVELOPER` env var and refuses the broadcasting key unless `ALLOW_DEV_EQ_DEPLOYER=1` (audit F8), so it is at least a deliberate choice. |
| (h) | **Uniswap's own protocol-fee controller may add up to 0.1% to every pool** | **Disclosed.** Not ours to control (§T, §U). |
| (i) | **Score is second-granular** | **Disclosed.** The chain's ~100 ms blocks mean up to ten blocks share a timestamp; both accumulators integrate zero time across them (§N limit 3). |

**Final external contract review disclosure additions (`docs/reviews/2026-09-11-contract-review-external.md`) and their status.**

| # | what a trader must be told | status |
|---|---|---|
| (j) | **Winning the round returns the whole bond; a larger bond at depth means more capital tied up for the round, not a higher price** | **Fixed and disclosed.** The prior wording ("non-refundable bond floor") was simply false for winners; `docs/DEPLOY_CONSTANTS.md` and `docs/spec/READINESS.md` are corrected. Only losers forfeit their bond. |
| (k) | **Collected support (hop fees, snipe tax, the ancestor sleeve) may sit undeployed for a long time, and the keepers who deploy it currently lose money at small sizes** | **Partly mitigated, rest disclosed.** `MIN_BOUNTY_WEI` plus the 20% cap (audit 5) close the worst cases (Run 2: gas ≈215× the old bounty at j=1, 121 wei of bounty at j=8) but the disclosed dead zone remains at the smallest deployment sizes. |
| (l) | **After a price crash, a keeper deployment used to be able to overpay for a parcel at close to the pre-crash price** | **Fixed (audit 1).** Every conversion link is priced at `min(spot, TWAP_30m, TWAP_7d)`, so a crash lowers the payout immediately instead of waiting up to 30 minutes for the fast average, and up to 7 days for the slow one. |
| (m) | **A losing candidate's coin used to lose its supported exit — and its creator's fee share — the moment its round ended** | **Fixed (audit 8).** Candidate routes resolve the round's recorded parent forever and pay the candidate's own creator 100% after the round. |
| (n) | **Upgrades used to be able to produce two competing histories, or leave fees permanently stuck with an older version depending on the gas of the swap that triggered them** | **Fixed (audit 1/2/4 in this tranche, on top of F1/F2 earlier).** Transitive adoption checking closes the remaining fork path (audit 2); post-sunset fees are queued and flushed rather than stranded by gas (audit 4). |
| (o) | **Fees can apply to a requested amount that does not fully trade (partial fills)** | **Disclosed, unchanged.** A route that fills half still pays the fee on the whole request (§I L1). |
| (p) | **Transferring creator rights used to transfer the recipient's already-earned, unclaimed balance too** | **Fixed.** A transfer now sweeps what has accrued to the OLD recipient's own claimable ledger (`creatorAccrued`); the new recipient starts from zero and the zero address is refused. |
| (q) | **The block-1 snipe schedule, measured second by second** | **Disclosed.** ≈99%, 66.33%, 33.67%, then 0% at +3 s, plus the hop fee on top throughout (§I). |

**Continuation caveats (disclosed, `docs/DEPLOY_CONSTANTS.md`).**

1. A continuation stack's ancestor Fenwick trees start **empty**. Entitlements for prior-version
   links accrue only from the new version's own fees; nothing is migrated, and the prior version's
   undeployed sleeve stays claimable in the prior version's vault forever.
2. **Attribution trust extends to the immediate successor only.** After the sunset takes effect, a
   version's hook trusts `hookData` from `successor.factory().router()`. With three live versions
   (v1 sunset to v2, v2 sunset to v3), a route driven by v3's router is **unattributed** at v1's
   pools — the fee still forwards all the way to v3, but as an unattributed one, so the creator
   share goes to the flywheel instead of the terminal token's creator.
3. **The last in-flight round of a sunset version can misattribute one round.** A candidate-sentinel
   attribution is resolved against the candidate list of whichever vault finally *books* the fee.
   While a sunset version's last round is still trading (at most one round past `sunsetAt`), its
   candidate ids are read by the successor's registry, where they may name a different candidate or
   none; such a fee is then credited to the wrong candidate's creator or is unattributed. The window
   is one round long and never recurs, because a sunset version opens no further rounds.
4. Cross-version ancestor payouts must go through the owning version's
   `BidDeployer.depositExternalBid` (no bounty, no ledger), resolved `registryOf(j) → factory() →
   bidDeployer()`, because each hook accepts liquidity only from its own Locker. Funds are never
   stranded and the beneficiary is still generation `j`.
5. **A hostile successor costs one swap, not the protocol.** The handover hop is bounded at
   `min(FORWARD_GAS, gasleft − BOOK_GAS_RESERVE)` and the hook's resolution legs at 30k gas each
   (with dirty-word answers treated as no answer, audit 7A), and both arm a one-shot negative cache
   (`forwardingFailed`, `successorUnresolvable`). The consequence is loud but not a loss: once armed,
   every later fee for that pool is **queued** in `pendingForward` rather than attempted in-swap
   (audit 4) — it is never booked on the old version's own ledgers as a fallback, and it stays
   recoverable by anyone's `flushForward` call, even against a hostile successor's queue, forever,
   because `flushForward` only needs a resolvable successor vault, not a working
   `forwardProtocolFee`. There is no re-arm and no setter on the negative cache itself. The steward's
   only protection against a hostile successor *keeping* what it receives is `cancelSunset()`
   **before** the sunset lands.
6. **A continuation stack cannot open a round at all until the handover completes.** If the prior
   version is sunset-effective but its last round is never finalized, `isIdle()` stays false and v2
   reverts `PriorNotHandedOver` indefinitely. `finalize()` is permissionless, so anyone can unblock
   it, but nothing forces them to.

---

## S. Simulations and results

`docs/sim-results-final.md` is the current report: every scenario re-run on the **MID** deploy
configuration (curve 20/25/35/20, `h = 0.15%`, hop 7.5 bps, 900 s trading window, reset-on-win).
`docs/sim-results.md` (SINGLE baseline) and `docs/sim-results-ladder*.md` (the superseded 10/15/35/40
ladder) are kept for comparison only.

| # | scenario | claim under test | verdict | MID headline number |
|---|---|---|---|---|
| 4 | Adversarial succession | slot capture costs ≈ fees | VERIFIED (worse than it sounds) | 100% capture at ≥2× honest average for 0.15% of capital cycled; `late_spike` 0% |
| 1 | Lifecycle GENESIS→#20 | creators/dev earn; ancestors keep receiving | VERIFIED mechanically, conditional on volume | all 20 ancestor indices non-zero; split lands exactly on 20/40/20/20; median winner 60.2% of float sold at 9.0× threshold |
| 2 | 200 Monte Carlo chains per demand regime | decay-with-floor keeps the chain alive without junk wins | VERIFIED | thin demand: 10.8% of rounds fail, #20 in 23.1 rounds, 0.0% junk wins, 6% of chains with no failed round |
| 3 | Bad-link collapse at #6 | best-route + reinforcement mitigates a weak link | best-route VERIFIED / reinforcement **FALSIFIED** | full line 57.7% after the dump vs 10.8% routing around it; reinforcement 94.6% → 94.6% |
| 5 | Candidate war, N = 5…50 | a round creates demand for the head | VERIFIED, nearly N-invariant | $16,892 of head absorbed per round, head FDV +352.1%; winner's score share 25.6% (N=5) → 5.4% (N=50) |
| 6 | Fee equilibrium and sell tax | find the split; report sell-tax sensitivity honestly | split set; sell tax rejected | creator 40%, remainder 50/50; at ε=1.0 a 1%→10% sell fee takes #20 from 20.9 to 30.8 rounds |
| 7 | Route depth 10/20/50/100 | flat fee + best-route keeps deep trading usable | fee VERIFIED / "usable" FALSIFIED at depth | fee 1.75% → 8.50%; impact-driven loss 17.14% → 67.17% |
| 8 | Sell cascade from #10 | the wall is a threshold cascade | VERIFIED in shape, REVERSED in sign | 8.24× trend clip at 66% of float; wall −77.6% vs single −90.9% at 50% float (explicit curve shapes, unaffected by MID) |
| 9 | Reinforcement vs burn | bid liquidity beats burn | VERIFIED, small margin | 74.6% vs 76.5% (burn) vs 77.7% (nothing); +10.96% parent bid within 50% of spot |
| 10 | Genesis economics | no genesis tax funnel | VERIFIED | genesis takes 34.5% of the sleeve at M=5, 0.240% at M=1000; decays as 12/(5M) (pure arithmetic, unaffected by MID) |

No scenario's verdict word flips under MID relative to SINGLE or LADDER. Reproduce with
`python -m sim.scenarios --all --curve mid --h 0.15 --hop-bps 7.5 --final` (seed 20260910;
`--only n` reproduces one scenario exactly). Every table is also a CSV in `docs/results/`, every
figure a PNG in `docs/figures/`.

---

## T. Dependency versions and addresses

**Toolchain.** solc 0.8.26, `evm_version = cancun`, `via_ir = true` (mandatory: `beforeSwap` hits
"stack too deep" with the legacy code generator), optimizer on at 200 runs, `bytecode_hash = none`,
`ffi = false`. Foundry 1.8.1. Fuzz `runs = 256`; invariant `runs = 32`, `depth = 64`,
`fail_on_revert = false`.

**Pinned libraries** (`contracts/DEPENDENCIES.md`; installed `--no-git --shallow`, commits confirmed
by re-cloning each repository and `diff -rq` against `lib/`):

| library | path | commit | version |
|---|---|---|---|
| Uniswap v4-core | `lib/v4-core` | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | package 1.0.2 (`main`) |
| Uniswap v4-periphery | `lib/v4-periphery` | `dce236d4e2057422d0791d9a973a58765eb46f65` | `main` |
| forge-std | `lib/forge-std` | `7fdf81f9ceb2f6ebbb8f9f1c6c5274d5bcc9a1f5` | 1.16.2 |
| OpenZeppelin contracts | `lib/openzeppelin-contracts` | `c547cd4d007bd7d887ea56e9086611a79844727d` | 5.7.0 |

Version-specific facts that shape the code: the pinned v4-periphery has **no `BaseHook`**, so
`FamilyHook` implements `IHooks` directly with its own `onlyPoolManager` modifier and a constructor
assertion that the mined address encodes exactly `HOOK_FLAGS`; `HookMiner` lives in
`lib/v4-periphery/test/shared/HookMiner.sol`, not `src/`; `ModifyLiquidityParams` / `SwapParams` are
top-level structs in `v4-core/src/types/PoolOperation.sol`. Remappings point every import at the
top-level `lib/v4-core`, so exactly one `PoolManager` / `IHooks` type exists in the build.

**Chain addresses** (`research/onchain-verification.md`, verified 2026-09-10 by JSON-RPC):

| item | mainnet 4663 | testnet 46630 |
|---|---|---|
| chain id | `0x1237` | `0xb626` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` (24,009 bytes) | code-identical, 24,009 bytes |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` | — |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` | — |
| UniversalRouter | `0x8876789976decbfcbbbe364623c63652db8c0904` | — |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | — |
| PoolManager owner / protocol-fee controller | `<testnet-addr>` / `<testnet-addr>` | — |

Chain properties: Arbitrum Orbit / Nitro, gas token ETH, ~100 ms average block time.
`block.prevrandao` is unusable as randomness on Orbit (attack-log #6), which is why the trading
window has a fixed, public end.

**MECHANISM_v3 contracts (new, `RUN 6 IN PROGRESS` — not yet deployed anywhere).**
`contracts/randomness/DrandSource.sol` (the live, deploy-default `IRandomnessSource`; verifies drand
`evmnet` on chain, §N/`contracts/DEPENDENCIES.md`) and `contracts/randomness/BN254.sol` (the pairing
and hash-to-curve library it uses, written from public specifications, no vendored dependency, §N)
are deployed once per `RoundManager` construction, referenced by the `RANDOMNESS_SOURCE` env var
(unset deploys a fresh `DrandSource` with the deploy constants above; `USE_MOCK_RANDOMNESS=1` deploys
`MockRandomnessSource` instead, testnet only). **`RoundManagerDeployer`** is a new one-function CREATE
helper, deployed at deployer nonce n+2 immediately before the factory — exactly the same pattern as
`DevVestingDeployer` — because the adaptive schedule and the random-end fields pushed the
`RoundManager`'s own constructor arguments, and therefore the factory's deployment transaction, over
the EIP-3860 initcode limit; moving those bytes into their own transaction restored roughly 13 kB of
headroom. It passes `msg.sender` as the `RoundManager`'s `factory`, so it can only ever produce a
contract wired to its own caller, and the factory verifies that at construction. New env vars:
`RANDOMNESS_SOURCE` (optional), `USE_MOCK_RANDOMNESS` (optional, testnet only), `END_TIMEOUT_S`
(optional, default 30 min, a `RoundManager` constructor parameter), `DURATION_SCALE_DIV` (optional,
default 1 on mainnet; the deploy script refuses any value other than 1 unless
`ALLOW_SCALED_SCHEDULE=1` is also set). `RoundManagerDeployer` will be recorded in
`deployments/<chainid>.json` as `roundManagerDeployer`, and `DrandSource`'s address (or
`MockRandomnessSource`'s) as `randomnessSource`, once run 6 actually deploys. **No addresses exist
yet for any of this** — every run recorded below predates MECHANISM_v3 entirely (fixed 900 s trading,
no drand, no purse deployment) and must not be read as evidence that the schedule, the random end or the
purse have ever executed on any chain.

**Live testnet deployment (chain 46630) — RUN 4 (2026-09-11), current, FINAL gas-optimized
bytecode.** `docs/TESTNET_RUN.md` is the authoritative round log and `research/INTERFACES.md` is
the authority on which links have actually fired — read those, not this file, for confirmed tx
hashes. Run 4 is a single fresh trunk (`continuesFrom = address(0)`) deployed from the gas-pass
build (token clones, packed hook storage, route memoization, the fixed `maxParentForDeploy` sizing
view — 162 tests); it ran one normal round (genesis buy, three candidates, a candidate sale, three
scores, finalize with a head change, `claimDev`, a second round finalized with no winner, both
keeper paths, `claimCreator`) and is idle. **Runs 1, 2, and 3 are all STALE** — earlier bytecode;
their addresses must not be pointed at for anything new. Run 1's record is
`deployments/46630.v1-stale.json`, run 2's is `deployments/46630.run2-stale.json`, run 3's is
`deployments/46630.run3-stale.json`. **Concrete addresses, pool IDs and tx hashes are withheld
from this public tree — see `private/` (untracked) for the canonical deployment records.** The
tables below keep the contract roles and the placeholders `<deployer>` / `<testnet-addr>` /
`<pool-id>` / `<tx>` in their place.

| contract | address |
|---|---|
| tokenImplementation (FamilyToken, EIP-1167 base, deployer nonce n+0) | `<testnet-addr>` |
| factory | `<testnet-addr>` |
| hook | `<testnet-addr>` |
| locker | `<testnet-addr>` |
| roundManager | `<testnet-addr>` |
| feeVault | `<testnet-addr>` |
| bidDeployer | `<testnet-addr>` |
| router | `<testnet-addr>` |
| lens | `<testnet-addr>` |
| genesisToken (FAM0, EIP-1167 clone) | `<testnet-addr>` |
| poolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| genesisPoolId | `<pool-id>` |
| deployer / developer / steward | `<deployer>` (all three — a throwaway testnet key with `ALLOW_DEV_EQ_DEPLOYER=1`; **mainnet: a single cold-signer (hardware wallet) address for both developer and steward, per the 2026-09-11 design decision — not a multisig — relying on the 7-day transfer delay (§M) rather than key-sharing for recoverability**) |
| continuesFrom / startIndex | `address(0)` / `0` — fresh trunk |

Candidate tokens (Run 4, all EIP-1167 clones of `tokenImplementation`): CAND-A — **head, canonical
index 1** — `<testnet-addr>`; CAND-B `<testnet-addr>`;
CAND-C `<testnet-addr>`; CAND-D (round 2, no winner)
`<testnet-addr>`.

**No handover was run on Run 4's bytecode.** Run 3 (functionally identical contracts, one gas pass
earlier) is kept as the **handover evidence**: it is the only run in which
`announceSunset`/`cancelSunset`/the delay/adoption/in-swap forwarding/queue+`flushForward`/cross-
version bids actually fired on chain. Its full record is `deployments/46630.run3-stale.json`
(v1/v2/v3 stacks); the v2 (continuation, live-at-the-time) addresses are kept here for reference:

| item | v2 (Run 3 continuation, handover evidence only — STALE bytecode) |
|---|---|
| factory | `<testnet-addr>` |
| hook | `<testnet-addr>` |
| locker | `<testnet-addr>` |
| roundManager | `<testnet-addr>` |
| feeVault | `<testnet-addr>` |
| bidDeployer | `<testnet-addr>` |
| router | `<testnet-addr>` |
| lens | `<testnet-addr>` |
| head token (CAND-E, canonical index 2) | `<testnet-addr>` |
| continuesFrom / startIndex | Run 3's v1 RoundManager `<testnet-addr>` / `1` |

The artefact records the constants the script bound (same values across runs 3 and 4), including
the depth-scaled bond schedule and the depth cap: `bondBaseWei 1e15`, `bondDoublingEvery 4`,
`bondMaxWei 6.4e16`, `maxIndex 0` (uncapped, the testnet value), alongside `hopFeePpm 750`,
`protocolFeePpm 10000`, `devBps 2000`, `creatorBps 4000`, `ancestorBps 5000`, `reinforceBps 5000`,
`hFracWad 1.5e15`, `hMinFracWad 3.75e14`, `registrationS 180`, `tradingS 900`, `submitS 300`,
**`sunsetDelayS 3600`** (both runs deployed at the contract floor rather than the mainnet 7-day
value, deliberately, so the handover could be exercised live instead of only on a fork —
mainnet must use 604800), `snipeS 3`, `tickSpacing 60`, `genesisUnitWei 1e21`, `supply 1e27`.

`deployments/` also contains `46630.v1-stale.json`, `46630.run2-stale.json`,
`46630.run3-stale.json` (all three of Run 3's stacks), `46630.fork-rehearsal-run4.json`, and older
`46630.fork-rehearsal*.json` files. Those are superseded or **anvil-fork** records — some with stale
constants blocks (`hopFeeBps 10`, `tradingS 600`) — and must not be read as deploy records.

**Gas (post-optimization; `docs/DEPLOY_CONSTANTS.md` is authoritative).** Measured with
`forge test --gas-report` at the deployed settings (`optimizer_runs = 200`, `via_ir = true`,
`evm_version = cancun`); no behaviour change is intended or observed (162/162 tests green).

| Action | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `registerCandidate` | 1,607,652 | 1,275,852 | **−331,800 (−20.6%)** |
| `createGenesis` | 1,390,171 | 1,052,179 | **−337,992 (−24.3%)** |
| Routed 3-hop buy (ETH → #0 → #1 → #2) | 1,403,824 | 1,283,514 | **−120,310 (−8.6%)** |
| Routed 2-link buy (ETH → #0 → #1) | 670,872 | 591,780 | **−79,092 (−11.8%)** |
| Genesis exact-in buy (incl. test router) | 637,029 | 630,650 | −6,379 (−1.0%) |
| Candidate-pool swap during a round (score path) | 495,944 | 489,516 | −6,428 (−1.3%) |
| `submitScore` | 194,151 | 194,157 | +6 |
| `finalize` | 265,154 | 267,820 | +2,666 |
| `deployAncestor(j=1)` | 570,185 | 559,696 | −10,489 |
| `deployGenesisBid` | 448,461 | 443,343 | −5,118 |
| `claimDev` (report avg) | 50,862 | 50,200 | −662 |
| Cross-version 3-hop route | 1,638,865 | 1,478,106 | **−160,759 (−9.8%)** |

Sources: (1) tokens are EIP-1167 clones instead of full deployments (§B); (2) `RegisteredPool` and
the TWAP ring entries are repacked so a scored swap touches four slots and a ring write is one
`SSTORE` (§N); (3) the router resolves each path index's currency once per route instead of once
per use; (4) the gas-capped `isSunsetEffective` probe is cached in transient storage per
transaction; (5) the audit-9 `protocolFeesAccrued` snapshot is skipped when the pool's v4 protocol
fee is zero. `finalize` and `registerCandidate`/`createGenesis` each pay one extra cold `SSTORE`
for `initSqrtPriceX96`/`tFrozenAt` moving out of the hot flag slot — a one-time launch cost traded
against every swap.

**Optimizer runs stay at 200.** `1000` and `10000` were tried: with `via_ir` the pinned `v4-core`
`Pool.swap` fails to compile ("stack too deep") at anything above roughly 210 runs — a dependency
ceiling in the vendored library, not a size one — so 200 is the practical ceiling until `v4-core` is
re-pinned. At 200 runs every contract is well under EIP-170 (largest: `BidDeployer` 20,353 B, 4,223
B of margin) and the factory's init code has 4,680 B of EIP-3860 margin.

**Deploy nonce chain** (`script/Deploy.s.sol`, `FamilyTestBase` mirrors it): every CREATE below
comes from the deployer, in this fixed order, forced by the hook's constructor args referencing the
FeeVault and the router before either exists — `nonce n+0` **`FamilyToken`** (the single sealed
implementation every family token clones, deployed with the factory's *predicted* address baked in
as its `factory` immutable — it must exist before the factory, which verifies the link back in its
own constructor), **`n+1` `DevVestingDeployer`** (a one-function, permissionless helper that CREATEs
the genesis `DevVesting`; deployed here, immediately before the factory, purely for EIP-3860 — the
factory already embeds `Locker`, `FamilyHook` and `RoundManager` in its own init code, and carrying
`DevVesting`'s creation code as well put the factory's deployment transaction over the 49,152-byte
initcode limit, closed and regression-tested by
`CodeSize.t.sol::test_factoryDeploymentTransactionFitsUnderEip3860`), `n+2` `FamilyFactory` (which
itself deploys `Locker` by CREATE and `FamilyHook` by CREATE2, mined against the factory's own
predicted address, verifies `tokenImplementation.factory() == address(this)` else
`BadTokenImplementation`, and — at `createGenesis`, not at construction — calls
`DevVestingDeployer(devVestingDeployer).deploy(...)` to CREATE the one genesis `DevVesting` it ever
funds), `n+3` `FeeVault`, `n+4` `BidDeployer` (the Locker's only depositor and the vault's only
keeper caller), `n+5` `FamilyRouter`, `n+6` `FamilyLens`. Every predictable address (factory, vault,
BidDeployer, router, the Locker predicted off the factory's own nonce 1) is predicted from the
deployer's nonce before anything is sent, and the deploy script asserts every prediction against the
address actually returned by `new`; `tokenImplementation` and `devVestingDeployer` are both recorded
in `deployments/<chainid>.json` alongside the other addresses (`devVesting` — the genesis instance
`DevVestingDeployer` actually created — is recorded too, read back from `factory.devVesting()` after
`createGenesis`).

Constants the deploy script binds (`script/Deploy.s.sol`): `hopFeePpm 750`, `protocolFeePpm 10000`,
`devBps 2000`, `creatorBps 4000`, `ancestorBps 5000`, `reinforceBps 5000`, `hFracWad 1.5e15`,
`hMinFracWad 3.75e14`, `registrationS 180`, **`tradingS 900`**, `submitS 300`,
**`sunsetDelayS`** (mainnet 7 days / `604800`; testnet 1 hour / `3600` — a constructor parameter,
`MIN_SUNSET_DELAY = 1 hours` floor, audit 2), **`roleTransferDelayS`** (7 days / `604800`, a
constant shared by `RoundManager`, `FeeVault` and `DevVesting`, not a per-deployment parameter),
`minBountyWei` (testnet `3e14`, audit 5), `snipeS 3`, `tickSpacing 60`, `genesisUnitWei 1000 ETH`,
`supply 1e27`, **`devAllocationBps 300`, `vestingCliffS`** (mainnet `2592000` / 30 days, testnet
shortened so the cliff and a release can be exercised live), **`vestingDurationS`** (mainnet
`31536000` / 365 days), and — once run 6 deploys MECHANISM_v3 — **`endTimeoutS`** (mainnet `1800`),
**`durationScaleDiv`** (mainnet `1`, refused otherwise without `ALLOW_SCALED_SCHEDULE=1`), and the
resolved `randomnessSource` / `roundManagerDeployer` addresses. Every one of them, plus the bond
schedule and `maxIndex`, is written into `deployments/<chainid>.json`, alongside the new `devVesting`
and `devVestingDeployer` address fields noted above.

**Required environment (audit F8 — the script can no longer pick these for you):**

| var | required? | meaning / guard |
|---|---|---|
| `POOL_MANAGER` | **required** | must have code |
| `DEVELOPER` | **required** | the initial payee of the 20% dev share and of the genesis vesting allocation (§B.1). `require(developer != address(0))`, and the script **refuses the broadcasting deployer key** unless `ALLOW_DEV_EQ_DEPLOYER=1` is also set. **No longer immutable**: it is transferable on `FeeVault`'s 7-day announce/execute/cancel delay (§M). Mainnet: a single cold-signer (hardware wallet) address, by design decision — not a multisig. |
| `STEWARD` | **required, no default** | the only privileged address besides the developer and the vesting beneficiary. `address(0)` is a *legitimate deliberate choice* — it means the deployment can never be sunset and therefore never continued — which is exactly why the variable has no default: "deliberately nobody" must not be confusable with "forgot to set it". Also transferable on `RoundManager`'s 7-day announce/execute/cancel delay (§M). Mainnet: a single cold-signer (hardware wallet) address, by design decision — not a multisig. |
| `MAX_INDEX` | optional, default `0` | the beta depth cap (0 = unlimited, the testnet value). Immutable; can never be raised. |
| `BOND_BASE_WEI` / `BOND_DOUBLING_EVERY` / `BOND_MAX_WEI` | optional | the depth-scaled bond schedule (§C). Testnet defaults 0.001 ETH / 4 / 0.064 ETH. |
| `CONTINUE_FROM` | optional, default `address(0)` | the prior `RoundManager` this deployment continues; must have code. Unset = a fresh trunk, the only mode with a genesis. |
| `ALLOW_DEV_EQ_DEPLOYER` | optional | throwaway testnet runs only. |
| `DEV_ALLOCATION_BPS` / `VESTING_CLIFF_S` / `VESTING_DURATION_S` | optional, default 300 / 30 days / 365 days | the genesis developer allocation and its vesting schedule (§B.1). `DEV_ALLOCATION_BPS = 0` disables the allocation entirely (genesis then sells 100% on the curve, exactly like a candidate). Immutable once deployed — there is no setter anywhere in `DevVesting` or `FamilyFactory`. |
| `RANDOMNESS_SOURCE` | optional | the `IRandomnessSource` `RoundManager` verifies drand relays against; unset deploys a fresh `DrandSource` with the deploy-constant beacon parameters (§N). Immutable once deployed. |
| `USE_MOCK_RANDOMNESS` | optional, **testnet only** | deploys `MockRandomnessSource` instead of `DrandSource` — no cryptography, clearly labelled `IS_MOCK`; the deploy script should refuse it on a mainnet target. |
| `END_TIMEOUT_S` | optional, default `1800` (30 min) | `RoundManager.END_TIMEOUT`, a constructor parameter: the disclosed deterministic-fallback delay after a round's nominal end (§C). |
| `DURATION_SCALE_DIV` | optional, default `1` | divides the adaptive schedule uniformly for a testnet run; the script refuses any value other than 1 unless `ALLOW_SCALED_SCHEDULE=1` is also set. Never scales `RANDOM_END_S`. |

The script asserts every address prediction against the address `new` actually returned, asserts the
mined hook encodes exactly `HOOK_FLAGS`, and on a continuation asserts head continuity against
`CONTINUE_FROM`.

The live round log is `docs/TESTNET_RUN.md`; `research/INTERFACES.md` is the authority on which
links have fired. **Mainnet 4663: not deployed.**

---

## U. Threat model

| attacker class | capabilities | mitigations in code | residual risk |
|---|---|---|---|
| **Whale slot-renter** | ≥2× the honest leader's capital for one round | none by design (no sunk slice, lock or seasoning); the score is time-weighted over 900 s, so the capital must sit for the window | **Accepted and disclosed.** 100% capture for 0.15% of capital cycled (Sim 4). Only a non-refundable cost would change it. |
| **Dynastic incumbent** | repeats the above every round and keeps the position | none | Accepted; the attacker may even profit mark-to-market (Sim 4 `dynastic`). |
| **Last-second spiker** | large capital in the closing seconds | average over the closing window `W`; the window average is read back from checkpoint rings at whatever `T_end` the random end settles on, so a spike inside the window is diluted exactly as before | Arithmetically ineffective at spike scale: 0% win rate at the original 900 s window (Sim 4); the random end additionally cuts a last-second flip rate 2.4% → 0.2% (Sim 13). |
| **Window sniper (MECHANISM_v3, disclosed working-as-designed)** | capital equal to the leader's, bought at the start of the closing window `W` and held through it | none by design — this is the rule (highest average at `T_end` wins); the random end removes the pure last-seconds spike game only | **Accepted and disclosed.** ≈82% win rate in a 4-h round, ≈93% in a 15-min round (Sim 13); the leader's only defences are the random end (nobody knows `T_end` in advance), the requirement to HOLD capital through the window rather than flash it, and the leader's community's time to respond during `W` — longer windows favour defenders, so the safe tuning direction is up. **Re-accepted 2026-09-12 when `W` was flattened to 15 min on every round** (it had been up to 3 h on a 12-hour round, which is the direction Sim 13 calls safer): the random end already removes the last-seconds game, and a window sniper must EXIT into the market it has just pumped — a pool whose only depth is the locked curve and the family's own bids — which Sim 13 does not model at all, so the measured 82–93% is an upper bound on a real edge. Disclosed, not mitigated. |
| **Beacon withholder / non-relayer** | the League of Entropy threshold colludes to withhold a signature, or simply nobody bothers to relay one | `END_TIMEOUT = 30 min` permissionless `finalizeDeterministic()` settles `T_end = T` regardless; the round never hangs | **Accepted and disclosed, and self-defeating for the attacker:** the only achievable outcome of withholding is `T_end = T`, which is exactly the outcome a late buyer could already plan for — a withheld beacon cannot bias a round in anyone's favour, only remove the randomness. Never fired in production (§ Links with liveness evidence). |
| **Purse parker (MECHANISM_v3)** | parked capital equal to a sibling's trailing support to move the top-2 ranking and claim purse share | — | **Closed by removal (review 3, 2026-09-13).** The purse is no longer contestable: a generation's whole share is locked under `canonical(j)`, decided by the round result and by nothing measured afterwards. There is no ranking to move. |
| **Purse-wall seller (review 3, disclosed working-as-designed)** | holders of the round winner sell into the purse's own bid range, so fee-funded liquidity buys them out | none by design, and none intended: the purse is a **permanent buy wall under the coin that won the round**, placed from just under spot to about 6% below it, and being able to sell into it is what makes it support rather than a lock-up. The bounds are the per-deployment size cap (2% of the target range's parent reserve) and the 24-hour drawdown bucket (10% of the generation's accrued ETH), so no single moment can be used to shove the pool | **Accepted and disclosed.** The reinforcement share (20% of the fee) has worked exactly this way since the first version; review 3 extends the same property from 20% to 40% of the fee by making the ancestor sleeve uncontested. Keeping the value on the canonical chain in bid form is the intent. |
| **Block-1 sniper** | the first swap at `tradingStart` | linear snipe tax 99% → 1% over 3 s; proceeds go to the parent's reinforcement pot; the score counts only what the pool absorbed, so a sniped buy scores small and positive | Priced, not prevented: mean +$445/round (Sim 5). |
| **Score-sign attacker (C1)** | one exact-in buy inside the 99% window to drive a rival's `R` negative | closed: `R` is the pool's own parent delta, fee-exclusive by construction; pinned in four orientations and inside the snipe window | Closed (`HookScore.t.sol`). |
| **Genesis squatter (C2)** | watches the factory deploy and front-runs `createGenesis` at a near-zero FDV | closed: the curve and price are computed in-contract from `_curveSpec` + `GENESIS_UNIT`; the caller supplies only name/symbol/uri | Closed. First caller still owns the *creator attribution* for genesis. |
| **Submission-order attacker** | submits a weak score and finalizes atomically | `submitScore` confined to `[T_end, T_end+300)`; `finalize()` refused until `submitEnd`; scores are `T_end` snapshots | Closed (`test_submitOrderingAttackCannotWin`). |
| **Submission griefer** | withholds a rival's `submitScore` or spams submissions | permissionless and per-candidate idempotent; anyone may submit for anyone | Residual: if *nobody* submits, a qualifying round still finalizes with no winner and all bonds are forfeited. |
| **Finalization stalker** | refuses to call `finalize()` | permissionless, idempotent, no deadline | Residual liveness dependency: succession halts until someone pays the gas. Trading continues. |
| **Pool poisoner** | pre-initializes the predictable `PoolKey` | `beforeInitialize` requires factory pre-registration at the exact registered price; the factory registers, initializes and places in one transaction | Closed (attack-log #8). |
| **Malicious candidate token** | tries to enter a non-standard token | tokens are deployed by the factory itself; no external token can be a candidate; genesis is now equally constrained | Closed. |
| **Liquidity thief** | tries to remove, migrate or donate into locked liquidity | `beforeRemoveLiquidity` reverts unconditionally; `beforeAddLiquidity` is Locker-only; `beforeDonate` reverts; the Locker has no exit | Closed permanently, in both directions (a bug is equally unfixable). |
| **Fee dodger** | avoids the 1% edge fee | the hook charges at the pool, not the router; direct `PoolManager` swaps pay identically | Open by construction: external ETH↔link markets pay the family nothing. Bounded only by hop fees on the family side; Sim 7 shows 100% of deep routes going external. |
| **Attribution forger** | passes a fake `terminalIndex` or candidate id | trusted only when `sender == router` or the post-sunset successor router; downgraded when `terminalIndex > headIndex` or `candidateId >= candidateCount` | Closed. A copycat router simply loses attribution. See §R continuation caveats 2–3 for the two cross-version windows. |
| **Router ETH sweeper (M1)** | funds `amountIn` out of ETH parked in the router | `swapPath` value checks; **no `receive()`**; residuals swept to `to`, deficits named | Closed (`RouterGuards.t.sol`). |
| **Keeper sandwicher / TWAP dragger (F4, audit 1/6)** | pumps or crashes a thin ancestor pool, waits out or exploits the 30-minute average, then drains a generation's sleeve at the wrong rate | Five independent brakes: every link is priced at **`min(spot, TWAP_30m, TWAP_7d)`** in value terms, so a pump only minutes old cannot raise the price and a crash lowers the payout immediately instead of waiting for the slow ring (audit 1); every pool in the conversion must cover the full 1800 s with ≥2 observations (`TwapNotReady`); the ±3% sqrt band on the **target** pool; ≤2% of `max(active bucket, first-range capacity)` per call; and a **10%-of-a-continuously-refilling-bucket** drawdown per generation (`DailyLimitExceeded`, audit 6) with no resetting-window boundary to burst at. The protocol never swaps, so there is no `minOut` left at zero, and the bounty is paid only on a completed deposit | Residual: a *patient* attacker who can hold a manipulation across the 7-day average still profits, and must then take the sleeve a tenth of the bucket at a time over days — which is loud, slow and priced. The vacuous-on-a-fresh-pool hole (M2), the unbounded-slippage conversion (M3) and the same-block drain are closed (`Keeper.t.sol`). |
| **Reentrancy / callback abuser** | reenters via native ETH or a callback | `nonReentrant` on `finalize`, `claimRefund`, `claimDev`, `claimCreator`, `claimCreatorAccrued`, **`FeeVault.accrue`** (review-2, F-4: the post-sunset branch hands control to an unknown successor vault, and `ledgerTotal` is credited in full before it does, so no foreign code ever runs against an understated ledger), `deployAncestor`, both `deployGenesisBid` overloads and `depositExternalBid`; CEI throughout; `unlockCallback` restricted to `poolManager`; whole routes in one unlock | No known path; not externally audited. |
| **Unlock interleaver (REN-01)** | opens its own v4 `PoolManager` unlock, swaps with flash accounting still open, and settles a round or pulls a claim in the same frame | `notInsideUnlock` on `RoundManager.finalize`, `requestEnd`, `finalizeDeterministic`, `submitScore` and on `FeeVault`'s three claim paths. The state is v4-core's own transient lock flag (`Lock.IS_UNLOCKED_SLOT`), read with one `exttload` through `PoolManager`'s inherited `Exttload`. The protocol's OWN swap path is deliberately NOT guarded: the hook's `afterSwap` and `FeeVault.accrue` are called from inside the swap's unlock on every swap, and neither touches the round machine or a claim | Closed as stated (`Review2.t.sol::test_REN01_everyGuardedEntrypointRefusesFromInsideAnUnlock`). Residual: an integrator that wants to batch a swap and a `submitScore` inside one unlock of its own must split them into two calls. No protocol path did so. |
| **Bond griefer (F10)** | registers many junk candidates | `bondFor(headIndex + 1)` per entry, forfeited on loss to the genesis bid; both `FamilyLens.roundView` and `RoundManager.candidateIds(roundId, offset, limit)` are paginated, so an unbounded array return can never exceed an `eth_call` gas limit | Cheap at testnet parameters: a spam round costs `n × bondFor(...)` (≈$4 per entry at 0.001 ETH and 0.01 gwei) and inflates read cost. Mitigated by the depth-scaled schedule and by raising the mainnet base bond (ROADMAP); pagination closes the read-side griefing outright (`Round.t.sol::test_candidateIdsArePaginated`). |
| **Ancestry inflator** | grows the chain to make accounting expensive, or spams shallow links because depth is cheap | Fenwick range-add / point-query is O(log N) on swaps and claims; registration refuses past `FenwickRangeAdd.MAX_INDEX = 4095`, and a beta deployment refuses past its own immutable `RoundManager.MAX_INDEX`; the **bond doubles every 4 links** to a cap, so each extra generation costs more (F6) | Residual: `ethValueOfParent(j)` and router paths are **O(j)** in static calls (~48.5k gas/generation) — deep keeper deployments and full-line routes eventually exceed the block gas limit, after which deep links are reachable only via external venues. The economic limit bites first: at ~6% of parent value per link, a deep pool's whole market cap is dust and the 2% size cap refuses the bid with a named error. |
| **Steward (insider)** | one of three role addresses in the protocol (with the developer and the `DevVesting` beneficiary) | `announceSunset` (once, `sunsetDelay` — mainnet 7 days, testnet 1 hour, floor 1 hour — successor must have code, no shorten, no second call; refused on an unadopted continuation, `NotAdopted`, audit 2) and `cancelSunset` (once ever, and only strictly before `sunsetAt`); **the role itself is transferable** on a separate 7-day announce/permissionless-execute/cancel delay (`announceStewardTransfer`/`executeStewardTransfer`/`cancelStewardTransfer`, §M) that changes who holds the role but adds no new power; neither the sunset switch nor the transfer moves funds or unlocks liquidity | Residual: a steward can hand the ETH edge to a successor **they** chose, and once the delay elapses that is permanent. Mainnet: a **single cold-signer address, deliberately not a multisig** (design decision 2026-09-11) — the transfer delay is the recoverability mechanism instead of key-sharing; `address(0)` removes the sunset power and the upgrade path together (but is itself then permanent, since a role that is `address(0)` cannot announce its own transfer either). |
| **Malicious successor (F2, sharpened by audit 4)** | a contract named by the sunset that burns gas, reverts, or is not a deployment at all | **Gas bounds, not just `try/catch`:** the vault's hop runs on `min(FORWARD_GAS = 6M, gasleft − BOOK_GAS_RESERVE = 1.5M)` and is skipped when that is zero, so ≥1.5M gas is always left to **queue** the fee in `pendingForward` (never book it locally, audit 4) and let the swap finish; the hook's resolution legs are `staticcall{gas: 30_000}` each, and a dirty-word return is treated as "no answer" rather than reverting the `abi.decode` (audit 7A). A failure at full budget arms a one-shot negative cache (`forwardingFailed`, `successorUnresolvable`) and is never retried; on `forwardingFailed` every later fee is queued directly with no attempt. `accrueForwarded`/`receiveForward` are `NotPriorVault`-gated and never recurse — a hostile or sunset successor queues for its own flush instead of trying a second hop in the same call. `flushForward` is permissionless, so anyone can pay to push a queue on, one hop per call. `cancelSunset` is the pre-effect escape hatch | Closed for *bricking* (`Sunset.t.sol::test_aGasBurningSuccessorCannotBrickSwaps`, `Sunset.t.sol::test_aDirtyWordSuccessorCannotBrickRoutes`): the swap always finishes and costs at most one hostile attempt. Residual: a successor can *keep* a fee it successfully receives — that is the point of the handover — and pay it out under its own splits; and once a negative cache is armed, every later fee for that pool queues instead of forwarding in-swap (still recoverable by `flushForward`, not lost). |
| **Competing trunk (F1)** | deploys a continuation, or races the incumbent during the sunset delay, to crown a second token at the same canonical index | Lazy head adoption: a continuation adopts nothing at construction, delegates every read to the prior registry, and may open its first round only when the prior version is sunset-effective, names *it* as `successor()`, and is `isIdle()` — otherwise `PriorNotHandedOver` | Closed. There is exactly **one canonical trunk** by construction: the prior head cannot move at the instant it is copied, and the prior version can never open another round. |
| **Developer (insider)** | a named payout address, transferable | `claimDev` withdraws only the accrued 20% ETH under whoever currently holds the role; the role itself moves only on `FeeVault`'s 7-day announce/execute/cancel delay (§M); no other privilege exists | Residual is off-chain: whoever deploys chooses the curve, the splits, the hop fee, the genesis unit, the steward, the hook salt, and the developer allocation's cliff and duration (§B.1). The single-key risk is mitigated the same way as the steward's: a 7-day transfer path instead of a multisig. |
| **`DevVesting` beneficiary (insider)** | the address `release()` pays; not necessarily the same address as `developer` after either transfers | `release()` is permissionless and pays only the current beneficiary; the role moves on `DevVesting`'s own 7-day announce/execute/cancel delay; cannot alter `start`, `cliff`, `duration` or the total allocation (§B.1) | Residual: none beyond the transfer path itself — there is no clawback and no acceleration to abuse, so the worst a hostile beneficiary transfer can do is redirect *future, already-vesting* releases, recoverable by the same delay in reverse. |
| **Protocol-level outsider** | the PoolManager owner / protocol-fee controller on 4663 | none — these are Uniswap's addresses, not ours | Uniswap's v4 protocol fee (capped, controller-set) applies to our pools like any other; we do not control it. |
