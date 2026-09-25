# Audit record

Every assurance method run against the protocol, the result, and the file in this repository that
holds it.

| Method | Result | Where |
|---|---|---|
| Formal verification | Certora proved 70 rules across the round manager, the hook and the fee vault. No rule was violated. | `certora/RESULTS.md` |
| Automated audit | 8 genuine findings, all fixed. | fixed in the code |
| Independent reviews | 11 rounds of manual adversarial review, each finding fixed. | fixed in the code |
| Property tests and fuzzing | 71 property and invariant tests passing, plus a fuzz and invariant run of 40,000 calls with 0 reverts. | `docs/security/PROPERTY_RESULTS.md` |
| Fork tests | 30 tests against the live Uniswap v4 pool manager, all passing. | `docs/security/FORK_RESULTS.md` |
| Static analysis | Slither, hand-triaged: 0 findings. | `docs/security/slither-triage.md` |
| Symbolic checks | Halmos, 23 checks, all passing. | `docs/security/halmos-review-5.md` |
| Testnet runs | 8 live runs, including automated round ends driven by an unattended keeper. | Robinhood Chain testnet |
