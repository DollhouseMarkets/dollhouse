# Audit record, review-5

This page lists every assurance method run against the protocol at its current tagged revision
(`review-5`), the result, and the file in this repository that holds it. It covers this revision
only; it is not a history of every review round the protocol has been through.

| Method | Result | Where |
|---|---|---|
| Formal verification | Certora proved 70 rules across the round manager, the hook and the fee vault. No rule was violated. | `certora/RESULTS-review-5.md`, `certora/RESULTS-review-4.md` (the vault's standing verdicts) |
| Automated audit | 8 genuine findings, all fixed before the freeze. | No standalone report file ships in this repository; the findings are fixed in the tagged code. |
| Independent reviews | 11 rounds of manual adversarial review, each finding fixed before the freeze. | fixed in the tagged code |
| Property tests and fuzzing | 71 property and invariant tests passing, plus a fuzz and invariant run of 40,000 calls with 0 reverts. | `docs/security/PROPERTY_RESULTS.md` |
| Fork tests | 30 tests against the live Uniswap v4 pool manager, all passing. | `docs/security/FORK_RESULTS.md` |
| Static analysis | Slither, hand-triaged: 0 findings. | `docs/security/slither-triage.md` |
| Symbolic checks | Halmos, 23 checks, all passing. | `docs/security/halmos-review-5.md` |
| Testnet runs | 8 live runs, including automated round ends driven by an unattended keeper. | evidence held privately |
