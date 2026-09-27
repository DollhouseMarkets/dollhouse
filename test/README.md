# Tests

Five groups, each proving a different kind of claim. Counts are test functions in the files
(`test*`, `invariant*`, `testFork*`, `check_*`, `property_*`), taken from `forge test --list` on
2026-09-26. A forge run reports all of one suite's invariants as a single result, so its result
count is lower than the function count; the per-tier breakdown and the last recorded run are in
`docs/security/PROPERTY_RESULTS.md` section 0.

| Group | Where | What it proves | Count |
|---|---|---|---|
| Unit tests by contract | `test/*.t.sol` | The behaviour of each contract, one file per component, including the regression tests for fixed findings | 326 (321 unit and fuzz tests, 5 invariants), all passing; 322 results in a forge run |
| Properties and invariants | `test/properties/` | Every property of `docs/spec/PROPERTIES.md` with a fuzz or invariant tier, stated as the specification states it | 90 (70 fuzz properties, 16 invariants, 4 single-case tests); 75 results in a forge run, 1 of them the known-divergent SLV-03 skip |
| Fork tests | `test/fork/` | The protocol against the real Uniswap v4 `PoolManager` singleton on a fork of the live chain | 38 |
| Symbolic checks | `test/halmos/` | Bounded proofs over the shipped `FeeVault` and `RoundManager` bytecode and the curve and Fenwick libraries | 34 (32 in the default run) |
| Medusa harness | `test/medusa/` | Protocol-wide properties under coverage-guided fuzzing of the whole deployed stack | 7 properties, 1 harness self-test (a forge test) |

Shared fixtures live in `test/utils/`: `FamilyTestBase.sol` and `RoundTestBase.sol` deploy and wire a
complete stack, `FamilyHandler.sol` drives the invariant runs, and `HostileDoll.sol` is the edge
currency with switches (paused, returns false, fee on transfer, blocklist, gas burning,
re-entrancy) used to prove that no third-party token behaviour can stop a round.

## Unit tests by contract

| File | Component |
|---|---|
| `Round.t.sol` | `RoundManager`: registration, scoring, ending, crowning, genesis adoption |
| `RoundGuards.t.sol` | `RoundManager` guards: bond escrow, forfeit delivery against hostile tokens, re-entrancy, the unlock guard (REN-01) |
| `Schedule.t.sol` | The round schedule, the closing window and the random-end window |
| `HookScore.t.sol` | `FamilyHook` scoring: the score rings, the ring freeze at the published end, registration guards |
| `Swap.t.sol`, `SnipeTax.t.sol`, `Mirrored.t.sol` | `FamilyHook` swap path, the opening snipe tax, the mirrored pool orientation |
| `FeeVault.t.sol` | `FeeVault`: fee split, ledgers, the drawdown bucket, payouts, donations |
| `Bid.t.sol`, `Purse.t.sol`, `Keeper.t.sol` | `BidDeployer` and `Locker`: bid placement, the purse, bounties and draw limits |
| `Router.t.sol`, `RouterGuards.t.sol` | `FamilyRouter`: paths, attribution, guards |
| `EthZap.t.sol` | `EthZap`: the native-ETH entry and exit |
| `Sunset.t.sol`, `Continuation.t.sol`, `RoleTransfer.t.sol` | Sunset, the successor handover and role transfers |
| `CurveMath.t.sol`, `Depth.t.sol`, `Drand.t.sol` | Curve math, behaviour ten links deep, the drand BN254 verifier |
| `DeployConstants.t.sol`, `CodeSize.t.sol`, `DevVesting.t.sol` | The deployed constants, the EIP-170 size limit, the developer vesting wallet |
| `Invariants.t.sol` | Protocol-wide invariants driven by a random-action handler |

```bash
forge test --match-path test/Round.t.sol
```

## Properties and invariants

Results and the property-to-test map: `docs/security/PROPERTY_RESULTS.md`.

```bash
forge test --match-path 'test/properties/*'
```

## Fork tests

Results: `docs/security/FORK_RESULTS.md`. The only input is an RPC endpoint; no key is read.

```bash
RPC_TESTNET=<endpoint> forge test --match-path 'test/fork/*'
```

## Symbolic checks

Results, bounds and what is modelled: `docs/security/halmos.md`.

```bash
FOUNDRY_PROFILE=halmos halmos --root . --forge-build-out out-halmos \
  --contract '^(FeeVaultHalmos|ForfeitHalmos)$' \
  --loop 3 --solver-timeout-assertion 120000 --solver-threads 1
FOUNDRY_PROFILE=halmos halmos --root . --forge-build-out out-halmos \
  --contract '^(CurveMathCheck|FenwickCheck)$' \
  --solver-timeout-assertion 120000 --solver-threads 1
```

## Medusa harness

`MedusaTarget.sol` deploys the whole protocol without cheatcodes and exposes the fuzz action set;
`MedusaTargetSanity.sol` is a forge test that proves the harness really drives the protocol.

```bash
FOUNDRY_PROFILE=medusa medusa fuzz --config scripts/security/medusa.json
forge test --match-path test/medusa/MedusaTargetSanity.sol
```
