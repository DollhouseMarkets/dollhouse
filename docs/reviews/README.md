# Reviews

Four adversarial reviews were run against the design and the contracts before mainnet. None of them
is a paid human audit; that is still outstanding.

| Document | Date | Scope | Outcome |
|---|---|---|---|
| [`2026-09-10-design-review.md`](2026-09-10-design-review.md) | 2026-09-10 | Independent review of Design Brief v1 (mechanism, fee model, ancestor accounting) | v1 rejected; reconciled into Design Brief v2 |
| [`2026-09-10-contract-review-internal.md`](2026-09-10-contract-review-internal.md) | 2026-09-10 | Internal review of all of `contracts/` at the tranche-2 revision | 23 findings, all fixed |
| [`2026-09-11-contract-review-final.md`](2026-09-11-contract-review-final.md) | 2026-09-11 | Final independent contract review; verdict, disclosure check and unknowns | 11 findings (3 blockers), all fixed |
| [`2026-09-11-contract-review-external.md`](2026-09-11-contract-review-external.md) | 2026-09-11 | Final external adversarial contract review at the tagged revision | 11 findings, all fixed |

Every finding from every review, with the disposition adopted and the test that pins it, is recorded
in [`../attack-log.md`](../attack-log.md). The brief given to reviewers is
[`../REVIEW_PROMPT.md`](../REVIEW_PROMPT.md). The post-fix code has not been independently
re-reviewed.
