# Contract review brief

A self-contained brief for an independent reviewer — human or automated. Clone the repository,
check out the revision under review, and work read-only: no file may be modified, and the
deliverable is a written report.

---

You are reviewing the Family Chain launchpad, an open-source Solidity project, before a paid
third-party audit and a small public beta on Robinhood Chain (Uniswap v4). Do not modify any file;
produce a written report only. You may run `forge build --sizes` and `forge test` (Foundry 1.8.1;
dependencies are vendored in `lib/`).

Read in this order: `CONTEXT.md` section 4 (decisions in force; the refundable score, no sunk cost and no sell lock are accepted, disclosed decisions, not findings, unless the disclosure is inaccurate), `docs/DEPLOY_CONSTANTS.md`, `docs/spec/PROTOCOL_SPEC.md`, `docs/spec/READINESS.md`, `docs/attack-log.md`, `docs/reviews/2026-09-10-contract-review-internal.md`, `docs/reviews/2026-09-11-contract-review-final.md` (the previous review; its eleven findings are fixed, verify the fixes), every file in `contracts/`, `script/Deploy.s.sol`, `script/live/round.sh`, the tests in `test/` (especially `test/utils/FamilyHandler.sol`, `test/Invariants.t.sol`, `test/Continuation.t.sol`, `test/Sunset.t.sol`, `test/Keeper.t.sol`, `test/Depth.t.sol`), the deployment record under `deployments/` for the network under review, `docs/TESTNET_RUN.md`, `research/INTERFACES.md`. Uniswap v4 core is at `lib/v4-core/src` (`PoolManager.sol`, `libraries/Hooks.sol`, `types/BeforeSwapDelta.sol`, `libraries/CurrencyDelta.sol`).

Find anything that could cause an incorrect outcome: loss or freezing of trader or protocol funds; violation of the stated invariants (1% fee charged only when ETH enters or leaves the family, liquidity permanently locked, at most one canonical winner per index and one trunk across versions, vault and BidDeployer solvency, no privileged control beyond the steward's `announceSunset`/`cancelSunset`); wrong winner or attribution; keeper payouts that can be gamed or that strand fees; gas or precision failure at high generation counts; and any statement in the spec or the disclosed-risks list that the code does not actually satisfy.

Report format (Markdown, under 4,000 words):
1. Verdict: READY for a paid third-party audit and a capped public beta (state the caps), or NOT READY with blockers.
2. Ranked findings, most severe first: file and line, concrete scenario (inputs and state leading to the wrong outcome), minimal fix, and whether an existing test should have caught it.
3. The single most consequential economic weakness, smart-contract weakness, score/winner-selection weakness, weakest assumption, and most likely catastrophic edge case with the generation number where it bites.
4. Spec-versus-code discrepancies.
5. Disclosure check for a non-technical reader: what is missing from the known-risks list.
6. Four lists: claims verified vs assumed; links with live evidence vs never fired; irreversible actions and their guards; unknowns and how to close each.
Be concrete and quantitative; do not soften findings.
