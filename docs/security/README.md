# Audit record

Every assurance method run against the protocol, its result, and the file in this repository that
holds it.

| Method | Result | Where |
|---|---|---|
| Formal verification | Certora proved 70 rules across the round manager, the hook and the fee vault, and every finding raised during verification was fixed before deployment. | `certora/RESULTS.md` |
| Automated audit | V12: 8 findings, all fixed. | fixed in the code, with regression tests in `test/` |
| Independent reviews | 12 independent reviews of the code; every finding fixed. | fixed in the code, with regression tests in `test/` |
| Unit tests | 322 tests across the contract test files (317 unit and fuzz tests, 5 invariants), all passing. | `test/README.md` |
| Property and invariant tests | 89 tests: 70 fuzz properties, 16 invariants and 3 measurements, plus a deep invariant run of 40,000 calls. | `docs/security/PROPERTY_RESULTS.md` |
| Fork tests | 38 tests against the live Uniswap v4 `PoolManager`. | `docs/security/FORK_RESULTS.md` |
| Symbolic checks | Halmos: 32 checks passing over the `FeeVault` and `RoundManager` bytecode and the curve and Fenwick libraries. | `docs/security/halmos.md` |
| Static analysis | Slither: 307 results, every one triaged, 0 open findings. | `docs/security/slither-triage.md` |
| Fuzzing | Medusa: 7 protocol-wide properties held over 213,798 calls, 0 failures. | `docs/security/medusa.md` |
| Testnet runs | 8 end-to-end runs, including automated round ends. | - |

How to run each test group: `test/README.md`.
