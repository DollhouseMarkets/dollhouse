# Medusa fuzzing

Medusa 1.5.1 over `test/medusa/MedusaTarget.sol`, a cheatcode-free deployment of the whole protocol
(factory, hook, router, fee vault, bid deployer, locker, round manager and a real v4 `PoolManager`)
that exposes the fuzz action set: register, trade, sell, settle the end, submit scores, finalize and
deploy bids. Configuration: `scripts/security/medusa.json` (one worker, call sequences of 100,
block timestamps advanced by up to an hour per call).

```bash
FOUNDRY_PROFILE=medusa medusa fuzz --config scripts/security/medusa.json
```

## Result

300 seconds: **213,798 calls, 2,242 call sequences, 6,166 branches covered, 0 failures.** All 7
properties held, and all 39 assertion tests passed (46 tests in total).

| Property | ID | Result |
|---|---|---|
| `property_FEE11_vaultIsSolvent` | FEE-11 | held |
| `property_FEE08_familyLedgersAreHopFeesOnly` | FEE-08 | held |
| `property_SUP01_supplyNeverMoves` | SUP-01 | held |
| `property_RND09_canonicalHistoryIsAppendOnly` | RND-09 | held |
| `property_BID05_keeperLeashIsNeverSlack` | BID-05 | held |
| `property_SCR13_scoreIsAlwaysSubmittable` | SCR-13 | held |
| `property_NOETH_stackHoldsNoEth` | - | held |

`test/medusa/MedusaTargetSanity.sol` is a forge test that proves the harness really drives the
protocol: under it a candidate registers, a round finalizes and crowns link one, and buys go through.
