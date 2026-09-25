# Halmos symbolic checks

Tool: halmos 0.3.3 (Z3 and yices), installed via `uv tool install halmos --python 3.12`.
Host: 16 GB Windows 11.

## Scope

The edge-token `certora/specs/FeeVault.spec` has no Certora Prover verdict (`certora/RESULTS.md`).
Its properties are the two delivery guards, the donation gap, the payout guard, the two-sided queue
conservation and the ledger decomposition.

These checks restate those properties as Halmos checks over **the real `FeeVault` bytecode**, and
add the `RoundManager.finalize` forfeit path (RND-11). The bounds below are real and are stated per
check.

## What changed in `[profile.halmos]`

The earlier lean profile compiled pure libraries only. `FeeVault` and `RoundManager` drag in
`FamilyFactory`, `FamilyHook` and the rest of the stack, so two things had to change:

1. **`contracts/FeeVault.sol` and `contracts/RoundManager.sol` are no longer in `skip`.** Their
   imports (factory, hook, locker, token) compile as dependencies regardless of the skip list.
2. **`via_ir = true` and the optimizer are on.** `FamilyHook._collect` does not compile at all
   under legacy codegen ("stack too deep"). The lean
   file set still builds in **22 s** with a free-RAM dip of about 400 MB, so this costs nothing
   that matters.

With the second change these checks run on bytecode built by the same pipeline as the shipped
artifact. The library checks were re-run under the changed profile to confirm nothing regressed;
see "Library checks under this profile" below.

## How to run

```bash
export PATH="$HOME/.local/bin:$HOME/.foundry/bin:$PATH"
export FOUNDRY_PROFILE=halmos FOUNDRY_THREADS=1
halmos --root . --forge-build-out out-halmos \
  --contract '^(FeeVaultHalmos|ForfeitHalmos)$' \
  --loop 3 --solver-timeout-assertion 120000 --solver-threads 1 --statistics --no-status
```

Both flags are mandatory (`--forge-build-out out-halmos`, and
`FOUNDRY_PROFILE=halmos`). Two operational notes learned here:

- **Never run a bare `forge build` in this profile.** Halmos needs the `ast` field in the
  artifacts and runs its own build to get it; a plain `forge build` overwrites `out-halmos` without
  it, and the next Halmos run reports "No tests" with a `KeyError: 'ast'` warning per artifact. The
  fix is `rm -rf out-halmos cache-halmos` and letting Halmos build.
- **Halmos can leave orphans.** A wall-clock `timeout` kills the launcher, not the Python child or
  its `yices-smt2`. Every run here was wrapped so that surviving `halmos`/`yices`/`z3` processes are
  killed by Windows PID afterwards.

Every run was taken under the shared `$TEMP/dollhouse-forge.lock` mkdir mutex (stale after 40
minutes), one check at a time, `--solver-threads 1`, with free physical RAM sampled before each
check and a 2.5 GB floor to wait on.

## Results: `test/halmos/FeeVaultHalmos.t.sol`

All 18 checks, `--loop 3`, `--solver-timeout-assertion 120000`, one solver thread.

| check | property IDs | result | paths | solver time |
|---|---|---|---|---|
| `check_receiveForwardKeepsSolvencyWhenLive(uint256,uint256,uint256)` | FEE-11, SUP-04 | **PASS** | 35 | 1.48 s |
| `check_receiveForwardKeepsSolvencyWhenSunset(uint256,uint256,uint256)` | FEE-11, CON-05 | **PASS** | 5 | 0.12 s |
| `check_depositEdgeBidEarmarkKeepsSolvency(uint256,uint256)` | RND-11, FEE-11 | **PASS** | 4 | 0.07 s |
| `check_undeliveredDepositAlwaysReverts(uint256,uint256)` | RND-11, FEE-11 | **PASS** | 4 | 0.07 s |
| `check_donationCreditsNoLedger(uint256,uint256)` | SUP-04, FEE-11 | **PASS** | 73 | 11.20 s |
| `check_claimDevNeverReachesTheZeroAddress(address,uint256)` | FEE-10 (payout guard) | **PASS** | 29 | 1.35 s |
| `check_claimCreatorNeverReachesTheZeroAddress(address,uint256)` | FEE-10 | **PASS** | 24 | 1.02 s |
| `check_claimCreatorAccruedNeverReachesTheZeroAddress(address,uint256)` | FEE-10 | **PASS** | 25 | 1.13 s |
| `check_payKeeperNeverReachesTheZeroAddress(address)` | FEE-10, BID-05 | **PASS** | 4 | 0.38 s |
| `check_zeroAddressPayoutsAlwaysRevert()` | FEE-10 | **PASS** | 1 | 0.29 s |
| `check_flushForwardConservesTwoSided(uint256,uint256,uint256,bool)` | CON-05 | **PASS** | 23 | 1.60 s |
| `check_failedFlushLeavesTheQueueIntact(uint256,uint256)` | CON-05 | **PASS** | 7 | 0.38 s |
| `check_decompositionAfterASecondFee(uint256)` | FEE-10 | **PASS** | 68 | 8.51 s |
| `check_decompositionAfterAForfeitDeposit(uint256)` | FEE-10, RND-11 | **PASS** | 69 | 5.34 s |
| `check_decompositionAfterClaimDev(uint256)` | FEE-10 | **PASS** | 62 | 4.68 s |
| `check_decompositionAfterAKeeperDraw()` | FEE-10, BID-05 | **PASS** | 1 | 0.54 s |
| `check_decompositionAfterAQueuedFee(uint256)` | FEE-10, CON-05 | **PASS** | 66 | 5.27 s |
| `check_oneBookedFeeDecomposesExactly(uint256)` | FEE-08, FEE-10 | **PASS** | 37 | 1.85 s |

Total: **18 passed, 0 failed, 45.3 s of solver time.** Wall time per check was 2 to 13 s after the
first invocation (31 s, which includes the build).

## Results: `test/halmos/ForfeitHalmos.t.sol`

| check | property IDs | result | paths | solver time |
|---|---|---|---|---|
| `check_forfeitBookedEqualsDeliveredPlusPending(uint256,bool)` | RND-11 | **PASS** | 7 | 0.36 s |
| `check_forfeitOnACrownedRound(uint256,bool)` | RND-11 | **PASS** | 8 | 0.55 s |
| `check_aFailedForfeitIsHeldInFull(uint256)` | RND-11 | **PASS** | 5 | 0.23 s |
| `check_flushForfeitsDeliversOrReverts(uint256,bool)` | RND-11 | **PASS** | 7 | 0.33 s |
| `check_flushForfeitsNeverDeliversTwice(uint256)` | RND-11 | **PASS** | 5 | 0.25 s |

Total: **5 passed, 0 failed, 1.72 s of solver time.**

**No counterexamples anywhere in this pass.** No contract change was made and none was needed.

## Non-vacuity

A check whose every path reverts passes for the wrong reason. Both suites were probed by adding a
deliberate `assert(false)` at the end of the check body and re-running:

- `ForfeitHalmos.check_forfeitBookedEqualsDeliveredPlusPending` → **FAIL**, 2 counterexamples.
- `FeeVaultHalmos.check_receiveForwardKeepsSolvencyWhenLive` → **FAIL**, 8 counterexamples.

Both assertions are therefore reached on live, non-reverting paths. The probe was removed
afterwards; the committed files contain no `assert(false)`.

The forfeit suite also pins its own branch selection: `check_forfeitBookedEqualsDeliveredPlusPending`
asserts that an honest token puts the WHOLE forfeit in the earmark and a lying one puts the whole
forfeit in `pendingForfeits`, which a vacuous run could not distinguish.

## What is modelled and what is real

**Real:** `FeeVault` and `RoundManager` are the shipped contracts, deployed and executed as
bytecode. `finalize`, `flushForfeits`, `pushForfeit`, `receiveForward`, `depositEdgeBidEarmark`,
`flushForward`, `deliverForward`, `_book`, `_sendToken`, the Fenwick sleeve and the drawdown bucket
are all the real implementations. The fee split constants are the PRODUCTION ones from
`script/Deploy.s.sol` (creator 4000, ancestor 5000, reinforce 5000), not the test-base ones.

**Modelled:** the environment each contract reads.

- `FamilyFactory`, `RoundManager` (in the vault suite), `FamilyHook`, the v4 `PoolManager` and the
  prior-version registry are replaced by the smallest contracts answering the same ABI. The
  PoolManager reports the unlock flag as false and **zero ERC-6909 claims**, so `holdings` is the
  real ERC-20 balance and `redeem` is a no-op. The claim half of `holdings` is covered at the fuzz,
  invariant and fork tiers, not here.
- The edge currency is a permissive mock ERC-20 that **accepts a transfer to `address(0)`**. That is
  deliberate: it is what makes the zero-address checks test the vault's own guard rather than the
  token's.
- In `ForfeitHalmos` the vault is a mock that reproduces `depositEdgeBidEarmark`'s delivery guard.
  The two contracts name each other at construction, so one of the two addresses has to exist
  first; the REAL vault's version of that same guard is proved on real bytecode by
  `check_depositEdgeBidEarmarkKeepsSolvency` and `check_undeliveredDepositAlwaysReverts`.
- `ForfeitHalmos`'s edge token has a symbolic `honest` switch: a dishonest token returns `true` from
  `transfer` and moves nothing, which is exactly the failure shape the try/catch exists for.
- `RoundManagerForfeitHarness` writes the round record directly (`candidateCount` candidates each
  holding `bondAmount`, the matching `bondEscrow`, a closed submission window) because driving a
  round there through the real entrypoints means registering candidates, deploying their tokens and
  settling a beacon end, none of which is symbolically tractable. `finalize()` then runs unmodified
  on that pre-state. **This is an assumed pre-state, not a reachable-state proof**: the checks say
  what `finalize` does from that record, not that only such records exist.

## Bounds

Every bound below was forced by a measured timeout, not chosen for comfort.

- **Amounts are bounded to `2^96` wei** (about 7.9e28), stated as a bit mask rather than a decimal
  comparison because a power-of-two bound is a mask for the solver. Bonds in `ForfeitHalmos` the
  same.
- **The ancestor depth is `M = 0`.** `FenwickRangeAdd.addSleeve` routes through `FullMath.mulDiv`
  for `M > 0`, which Z3 cannot discharge. Attribution stays fully
  symbolic: every index above `headIndex()` and every candidate id resolves to "unattributed",
  which is also `M = 0`. Depths `M > 0` are covered at the fuzz, invariant and unit tiers.
- **The decomposition is stated WAD-SCALED.** The sleeve lives in the Fenwick trees at `WAD`
  precision and `claimableAncestor` divides it back down; a decomposition written through
  `claimableEdge` asks the solver to invert a 256-bit division by `1e18` on top of the four constant
  divisions of the fee split, and it produced no verdict in ten minutes at any amount bound tried.
  Multiplying the whole relation by `WAD` leaves only multiplications. The WAD-side statement is
  **strictly stronger**, because the raw point query is the UNFLOORED sleeve.
- **`check_decompositionAfterAKeeperDraw`, `check_payKeeperNeverReachesTheZeroAddress` and
  `check_zeroAddressPayoutsAlwaysRevert` pin the fee to a concrete 1,000e18.** In the first two the
  drawn amount is `min(bucket, claimableEdge)`, so the division is inside the CONTRACT's control
  flow where no restatement can lift it out; the third is four sequential payout attempts and
  reached 309 paths without discharging. In all three the claim is about the destination or the
  post-draw decomposition, and what stays symbolic is the part the claim is about.
- **`CANDIDATES = 3` is concrete** in `ForfeitHalmos`: the count only ever multiplies the bond.
- `--loop 3`. No loop bound was actually reached: the Fenwick walks and the registry walk are all
  concretely indexed here, and Halmos reported an empty `bounds: []` on every check.

## Measured timeouts, kept out of the shipped checks

These are recorded so the bounds above are not mistaken for preferences. None is in the committed
files; each was the formulation that had to be replaced.

| formulation | result | why it was replaced |
|---|---|---|
| One five-way symbolic `which % 5` switch over the call set | **no verdict in 600 s** | a symbolic `%` is a 256-bit division, and the function carried every branch's state at once. Split into five checks, each 5 to 9 s. |
| `assert(dev + creator + claimableEdge(0) == amount)` (unscaled) | **TIMEOUT at 120 s assertion budget**, 244 s of model time | inverting `(x * 1e18) / 1e18` over 256 bits. Restated WAD-scaled: 1.85 s. |
| `assert(ancestorPointQueryWad(0) >= 0)` | **TIMEOUT**, 122 s of model time | proving `sleeve * 1e18 < 2^255` from a 96-bit bound. The sign is covered by the equality that follows it. |
| Four payouts with a symbolic recipient in one check | **no verdict in 600 s**, 309 paths | split to one payout path per check, each 0.4 to 1.4 s. |
| Keeper draw and decomposition with a symbolic fee | **no verdict in 600 s** | fee pinned; see the bound above. |

## Library checks under this profile

The library checks were re-run under the changed profile (`via_ir = true`, optimizer on, the
vault and round manager in the compile set):

```
FOUNDRY_PROFILE=halmos halmos --root . --forge-build-out out-halmos \
  --contract '^(CurveMathCheck|FenwickCheck)$' \
  --solver-timeout-assertion 120000 --solver-threads 1 --statistics --no-status
```

**9 passed, 0 failed, 68.1 s wall.** Every check keeps its earlier verdict; path counts moved
slightly (886 rather than 928 on `check_sqrtPriceNeverOutOfRange`, 128 rather than 182 on
`check_rangeAddIsAdditive`) because the bytecode is now IR-compiled. `CurveMathSlowCheck` remains
excluded from the default run and remains a known timeout.

## Memory

| phase | observation |
|---|---|
| `halmos` build of the lean set (60 source units, via-IR) | 22 s; free physical RAM dipped about 400 MB |
| The 23 checks, one at a time | minimum free physical RAM observed **5.2 GB**; no solver crash |

Sampling: free physical RAM read from `Win32_OperatingSystem.FreePhysicalMemory` before and after
each check, with a 2.5 GB floor the runner waits on. Nothing came near it.

## Caveats

- **Bounded, not universal.** Amounts to `2^96`, ancestor depth to `M = 0`, candidate count 3, three
  checks on a concrete fee. Each bound is stated above with the timeout that forced it.
- **The environment is modelled.** A property here is a property of `FeeVault` and `RoundManager`
  GIVEN a factory, hook, pool manager, registry and token that behave as the mocks do. The mocks are
  deliberately permissive where that strengthens the claim (a token that accepts the zero address, a
  token that lies about delivery) and deliberately trivial where the real thing is covered elsewhere
  (no ERC-6909 claims).
- **`ForfeitHalmos` assumes its pre-state.** See "What is modelled and what is real".
- **This does not close the Certora gap, it covers it.** `FeeVault.spec` still has no verdict. What
  these checks give is a machine-checked statement of the same properties over the same bytecode,
  under bounds the specification would not have needed.
