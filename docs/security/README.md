# Audit record

Every assurance method run against the protocol, its result, and the file in this repository that
holds it.

| Method | Result | Where |
|---|---|---|
| Formal verification | Certora proved 70 rules across the round manager, the hook and the fee vault, and every finding raised during verification was fixed before deployment. | `certora/RESULTS.md` |
| Automated audit | V12: 8 findings, all fixed. | fixed in the code, with regression tests in `test/` |
| Independent reviews | 12 independent reviews of the code; every finding fixed. | fixed in the code, with regression tests in `test/` |
| Unit tests | 326 test functions across the contract test files (321 unit and fuzz tests, 5 invariants), all passing; a forge run reports them as 322 results because the 5 invariants report as one. | `test/README.md` |
| Property and invariant tests | 90 test functions: 70 fuzz properties, 16 invariants and 4 single-case tests (75 results in a forge run, one of them the known-divergent SLV-03 skip), plus a deep invariant run of 40,000 calls. | `docs/security/PROPERTY_RESULTS.md` |
| Fork tests | 38 tests against the live Uniswap v4 `PoolManager`. | `docs/security/FORK_RESULTS.md` |
| Symbolic checks | Halmos: 34 checks, 32 of them in the default run and passing, over the `FeeVault` and `RoundManager` bytecode and the curve and Fenwick libraries. | `docs/security/halmos.md` |
| Static analysis | Slither: 307 results, every one triaged, 0 open findings. | `docs/security/slither-triage.md` |
| Fuzzing | Medusa: 7 protocol-wide properties held over 213,798 calls, 0 failures. | `docs/security/medusa.md` |
| Testnet runs | 8 end-to-end runs, including automated round ends. | - |

How to run each test group: `test/README.md`.
