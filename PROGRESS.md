# PROGRESS.md — changelog

## 2026-09-13 — the purse is no longer contestable (review 3)

Maintainer decision: each generation's share of later fees is deployed, in full, as locked bid
liquidity under the trunk coin that won that round. No top-2 split, no ranking, no board. The
reasoning is in `docs/MECHANISM_v3.md` §1: keep as much value as possible on the canonical chain,
make the rule one sentence, and leave a dumped or abandoned trunk coin to its own community rather
than penalising it through the protocol.

- **Contracts.** `RoundManager` loses `rank`, `board`, `purseWeights`, `purseWindow`, the `Rank`
  struct, `_board`, `RANK_MAX_AGE`, `BadRanking`, `NotACrownedRound` and the `Ranked` event;
  `BidDeployer.deployAncestor(j, amount)` drops the id pair and the split and emits
  `PurseDeployed(generation, trunk, parentDeposited)` in place of `PurseSplit`. Pricing, the daily
  bucket, the size cap and the `max(1%, MIN_BOUNTY_WEI)` bounty are untouched. Sizes fell:
  `RoundManager` 21,050 -> 19,132 B, `RoundManagerDeployer` 23,051 -> 21,112 B, `BidDeployer`
  22,755 -> 21,188 B.
- **Tests.** `test/Purse.t.sol` (8) and `test/properties/Purse.prop.t.sol` (3) rewritten around the
  new rule, with the losing siblings' pools asserted to receive exactly zero bids; the rank cases
  removed from `Review2.t.sol`, `PropHandler`, `Invariants.prop.t.sol`, `Keeper.t.sol`,
  `FeeVault.t.sol`, `Depth.t.sol`, `Bid.prop.t.sol` and the fork suite. Totals in
  `docs/security/full-suite-review-3.txt`.
- **Keeper.** The ranking epochs, the `Ranked` log scan and `RANK_MAX_AGE` are gone; the purse path
  is "one `deployAncestor(j, amount)` per crowned generation, inside the daily gas cap", with the
  send budget now keyed by generation. `replay.mjs` re-runs the run-7 generation and asserts one
  action in a simulated day.
- **Web.** `PurseStandings` is a per-link purse line (accrued, locked under this coin, last
  deployment); the Rank buttons and the `rank` action are gone; the Chain explainer says "each
  round's share of later fees is locked as liquidity under the coin that won it".
- **Docs.** `MECHANISM_v3` §1 rewritten with a "previously" note, `PROTOCOL_SPEC` §J, `PROPERTIES`
  PUR rows (01/03/06/07 retired, 02/04/05 restated), `DEPLOY_CONSTANTS`, `PROPERTY_RESULTS`, six
  `docs-site` pages, `attack-log.md` "Review 3", and Sim 11 marked superseded (not re-run).
- **Deliberately removed protection:** the dump penalty on a round winner. A winner that is sold
  off keeps its generation's purse, and a sibling that grows past it earns nothing from the chain.
  Disclosed on `docs-site/risks.mdx` and in `intentional-choices`.

### Independent diff review of review-3 (2026-09-13)
No contract defect found; a wrong-pool deposit is structurally impossible under the new rule. Two
keeper findings fixed: scan every crowned generation for a deployable purse (not just the latest),
and do not spend the per-generation send budget on a mined revert. Framing added to the docs: the
purse is a permanent buy wall under the winner (priced just under spot to about 6% below, at most
2% of depth per deployment and 10% of accrued ETH per day), which extends a property the
reinforcement share already had, from 20% to 40% of the fee. The pricing description was also
corrected: the sleeve is priced along links 0..j-1 at `min(spot, TWAP30, TWAP7d)`; the trunk pool is
band-checked about 3% against its own 30-minute TWAP.

### Slither re-run at review-3
272 results, 0 findings; the purse-related rows from review-2 are gone (code removed), one new row
(a deploy-time probe) triaged as a false positive; the review-1 triage otherwise carries forward
unchanged.

### Certora review-2
8 runs, no genuine bug. `FeeVault` 17/20 and `RoundManager` 20/26 rules fully verified; bond
monotonicity proved. `SLV-03` vacuity traced to the loop bound (still unproved — times out).
`FEE-01` per-pool remains unproved (unreachable under the current summaries). One rule (ledger
decomposition) regressed by the review-2 pass itself; the fix is queued. Full results:
`certora/RESULTS-review-2.md`. Certora review-3 (re-run against the review-3 contracts) is in
progress.

### Testnet and friends status (2026-09-13)
Testnet run 7 (review-2 code) and the live keeper run are already recorded (see 2026-09-12 entry
below); purse deployment under the review-3 rule (`deployAncestor(j, amount)` with no split) has
never fired on any chain — the roadmap's pre-live gate requires exercising it once with a funded
generation and confirming the keeper proposes it unprompted. Friends hold the `review-2` package
and have been told the purse code is being removed; the `review-3` tag and export follow the
Certora review-3 run. Owner-side pending is unchanged: WalletConnect id, V12 credit, hosting
accounts, friends' findings.


## 2026-09-12 — website, docs, run 5, naming, design reversal
- Testnet run 5 reconciled: the driver had survived an earlier interruption and completed; `release()` fired live and paid exactly `3e25 × 4067/7200` FAM0; role transfers announced and cancelled on all three roles; one harmless duplicate `finalize()` documented. Balance 0.1237 ETH.
- Web scaffold: Vite + React 18 + TypeScript + react-router + wagmi v2 + viem; ABI/address sync from `out/` and `deployments/46630.json`; data hooks (chain, round, coin, earnings, keeper, ETH/USD), actions (trade, candidate trades, launch, submit/finalize, claims, vesting release, keeper), eight routes; every read verified against the live testnet.
- Gothic visual pass from an external design export (extraction spec, doll SVGs, all screens) then a polish pass (formatting, candidate names, mobile nav, ETH price source).
- The gothic direction was scrapped as too heavy ("leaning way too hard into gothic/horror"); target is cartoonish styled dolls (pump.fun / Azuki / Pons); gothic assets removed; site reset to a neutral token-driven baseline (`web/src/styles/tokens.css`), all functionality intact, zero console errors on every page at 1440/400.
- Naming: launchpad **Dollhouse**, genesis token **$DOLL**; deploy script defaults updated.
- Mintlify docs site (`docs-site/`, 18 pages, links validated, no returns language): basics, rounds ("your buys are your votes"), chain, flywheel, why competition (Infinite Family origin), tokenomics incl. 3% vesting, the $DOLL page (case and counter-case), using, risks, audits, contracts, FAQ, glossary.
- Docs updated: `docs/DESIGN_BRIEF_UI.md` (new visual direction), `design/EXTRACTION.md` (superseded), CONTEXT/ROADMAP/memory.

### Status additions
| Feature | Status |
|---|---|
| Website (functional) | done on testnet; neutral placeholder theme; awaiting the cartoon brand kit |
| Public docs | drafted in Mintlify; review and deploy pending |
| Dev vesting + role transfers | live on testnet (run 5); execute paths fork-only (7-day delay) |

## 2026-09-12 — mechanism v3, review package, privacy move
- **Mechanism v3**: closing-window scoring, an adaptive duration/registration/late-entry schedule keyed off the round number, a drand-verified random round end (BN254 pairing check on chain, five-of-five in range on the live run), a top-2 contestable purse split by trailing support with the third sibling excluded (SUPERSEDED 2026-09-13), and permissionless late entry into an open round; 226 tests.
- **Brand pivot**: cartoon-styled dolls (pump.fun / Azuki / Pons references) replacing the earlier gothic direction; naming settled on Dollhouse / $DOLL.
- **Web app**: page set covers trade, launch, chain view, earnings, keeper actions and vesting; full-bleed hero scene added from the brand mock with overlaid copy and parallax; on-chain addresses are hidden off mainnet.
- **Public docs**: Mintlify site continues to track the mechanism and tokenomics changes.
- **Testnet run 6**: mechanism v3 exercised live for the first time — adaptive schedule, five drand-verified random ends, late entry, top-2 purse split (that purse rule was superseded on 2026-09-13); the deterministic timeout fallback has still never fired on chain; keeper bounty economics remain negative at testnet scale (disclosed dead zone, not fixed).
- **Review package tooling**: an allowlisted export script (`scripts/export-public.py`) with an identity/vendor scan, a pinned-dependency installer, a reviewer guide (`docs/REVIEW_GUIDE.md`) and a maintainer runbook (`docs/REVIEW_PACKAGE.md`).
- **Neutral-voice rewrite**: exported docs and code comments passed to a neutral engineering voice; `docs/reviews/` holds the internal, external and final contract-review records.
- **Spec-derived property list**: `docs/spec/PROPERTIES.md` (127 properties) drafted from the protocol spec; `test/properties/` in progress.
- **Security tooling status** (`docs/security/TOOLING_STATUS.md`): Slither and Halmos deferred for memory reasons on this machine; Medusa found no fuzzing targets on the current harness; a deep-fuzz smoke pass is green.
- **Privacy move**: testnet deployer/addresses/tx hashes moved out of the tracked tree into `private/` (gitignored); tracked docs now point there instead of publishing identifiers.

## 2026-09-12 (continued) — review freeze, full test tiers, web chain-seam audit

- **Contract tag `review-1` frozen.** Review repository is live and private under the Dollhouse GitHub organisation; export tool `scripts/export-public.py` produces `~/dollhouse-review` (316 files, identity/vendor scan clean); `private/TESTNET_LINKS.md` holds reviewer-facing testnet links.
- **Property tests**: 74 spec-derived properties (`test/properties/`) all pass; results in `docs/security/PROPERTY_RESULTS.md`.
- **Fork tests**: 31 tests against the real PoolManager on the testnet fork (`test/fork/`); results in `docs/security/FORK_RESULTS.md`. Finding: `block.number` inside a fork reports the settlement layer's height, not the rollup's — the protocol uses timestamps only, so this does not affect correctness, but it is now documented so a future `block.number` use is not added by mistake.
- **Full suite**: 300 tests pass. Deep fuzz: 5000 runs / 200×100 invariant depth, green.
- **Slither**: run alone and hand-triaged (`docs/security/slither-triage.md`) — 0 findings, 3 accepted risks.
- **Halmos**: 9 symbolic checks pass on a lean `[profile.halmos]` (`docs/security/halmos-review-1.md`). Root causes of the earlier failures identified: forge's `--skip` globs cross directory boundaries and can silently exclude targets; Halmos reads compiled artifacts via `--forge-build-out`, which defaults to `out` and must match the active build. Two heavy checks are parked as known timeouts, not passing and not failing.
- **Medusa**: cheatcode-free harness `test/medusa/MedusaTarget.sol`; 165k calls in a 300 s run; 5 properties held (`docs/security/medusa-review-1.txt`).
- **Certora**: specs written from the protocol spec (`certora/`); two prover rounds run on the free tier (`certora/RESULTS-review-1.md`). No genuine bug found; 21 non-success rules classified (spec scoping, summaries, documented divergences). Four latent-risk items plus doc corrections queued for review-2 (already tracked on `ROADMAP.md`). `FEE-01`'s per-pool half is unproved (a vacuous `satisfy`) and needs restating. A re-run of the second-round spec edits is still pending. Operational notes for next time: run from WSL with JDK 19+, and the result-fetch step needs a browser-like User-Agent or it is rejected.
- **Web chain-seam audit**: `docs/reviews/2026-09-12-web-review.md`, 14 findings, all fixed except two disclosed and one queued (below). Fixes landed: chain id pinned on every write with a switch guard; single-chain bundle with a post-build address gate (`web/scripts/check-dist.mjs`); real multicall3 batching on chains 4663 and 46630; fallback RPC with a circuit breaker and scoped cache invalidation; an RPC-outage banner; fee and snipe-tax display sourced from chain constants instead of hardcoded copies; refund reading; CSP headers; the mainnet RPC hostname corrected. Open: browser-clock countdowns drift from chain time (F10); some constants are still duplicated between chain reads and copy (F12); a real wrong-chain wallet test is still needed before beta.
- **Web design pass**: full-screen hero built from the clean brand scene with an overlaid header and the live slogan "Nested. Locked. Earned." on the sign; one row of phase-aware action buttons; homepage cohesion pass (larger wordmark and wallet pill at the gutters, contract-address caption moved into normal flow, unframed art, a static example-chain image `web/public/brand/chain-example.png`, a black fee band showing four figures only). Site-wide story pass: `StoryBand`, `SignBoard`, `Skyline`/`SkylineDivider` components, ledger-style tables, a per-page mascot pose, and a stepper launch flow. Branded chain ticker under the header (`web/src/components/ChainTicker.tsx`, `header.css`). Round page countdown rebuilt as the page's hero with random-end and late-entry copy. Bond amount now reads off the Launch sign. One shared control treatment for form inputs. Chain explainer rewritten in plain language with a fee-flow SVG. Round-length copy corrected in the app and across six `docs-site/` pages (adaptive schedule, closing window).
- **Wallet**: single "Connect Wallet" button; browser wallet only until a WalletConnect project id exists.
- **Owner-side pending, tracked on the roadmap**: WalletConnect project id (`VITE_WALLETCONNECT_PROJECT_ID`); V12 starter credit (support asked; scope is `FeeVault` + `FamilyHook`); friends' review findings; RPC/hosting accounts (Alchemy, Vercel, an indexer, DNS for dollhouse.markets); a preview review of the site (`cd web && npm run dev`).
- **Operational notes**: this is a 16 GB machine — one compiler process at a time behind `$TEMP/dollhouse-forge.lock` (`FOUNDRY_THREADS=1`), node builds behind `$TEMP/dollhouse-web.lock`; orphaned `yices-smt2`/vite/esbuild processes must be killed after tool runs (`scripts/security/README.md`). The working session is moving from VS Code to a lighter terminal client, so nothing in the docs or scripts should assume an IDE is present.

## Changelog

- **2026-09-10** Scaffold: research dossiers, decisions, design brief v1, infra notes.
- **2026-09-10** External design audit, attack log, design brief v2, sim engine (clmm, curves) with tests.
- **2026-09-10** Sim: family graph, routing, fee allocator, reinforcement, rounds, agents, metrics (131 tests).
- **2026-09-10** Contracts tranche 1: FamilyToken, FamilyHook, Locker, FamilyFactory, CurveMath + Foundry tests (24 tests).
- **2026-09-10** Sim: scenario runner, ten scenarios run, results + figures (147 tests).
- **2026-09-10** Sim: ladder curve recalibration, threshold reset on win, deploy constants locked.
- **2026-09-10** Contracts tranche 2: RoundManager, FeeVault (Fenwick), FamilyRouter, FamilyLens, candidate pools, invariants (54 tests).
- **2026-09-10** Pre-audit contract review recorded (2 critical, 3 high, 6 medium, 12 low) with dispositions.
- **2026-09-10** Sim: final MID-curve baseline for all scenarios; spec + readiness drafts; deploy scripts and fork rehearsal.
- **2026-09-10** Contracts: fix all pre-audit findings (C1 score, C2 genesis curve, H1 keeper model, H2/H3 caps, M1–M6, L1–L12); 91 tests.
- **2026-09-10** Contracts tranche 4: steward sunset (7-day, one-shot) and forward continuation across versions; 110 tests.
- **2026-09-10** Sim + docs: 15-minute trading window, creator economics decision, final MID results at 900 s.
- **2026-09-10** Docs: PROGRESS.md changelog and consolidation headers.
- **2026-09-10** Contracts tranche 5: sunset handover of ETH edge, 50/50 head-creator season cut, 15-min window (119 tests); docs system (CONTEXT/ROADMAP/README/original brief).
- **2026-09-10** Spec delta pass to final code (`PROTOCOL_SPEC.md`, `READINESS.md`); fix Sim 2 reset-on-win note.
- **2026-09-10** Testnet: live deploy blocked by EIP-170 (FeeVault 25,550 B); full fork rehearsal green; `round.sh` rewritten for final API.
- **2026-09-10** Contracts: split BidDeployer out of FeeVault (EIP-170), bounty symmetry, candidate route caps, `buyCandidateWithParent`, code-size and deploy-constant tests (127 tests).
- **2026-09-10** Spec: BidDeployer split, router candidate signatures, size table, 127 tests.
- **2026-09-10** Testnet 46630: live deployment (9 contracts verified), full round end to end, keeper paths; `research/INTERFACES.md` all verified live except sunset.
- **2026-09-10** Spec: live testnet addresses in section T.
- **2026-09-10** Docs: partial findings from the first external contract-review attempt recorded.
- **2026-09-10** Hook: exact-output fees (snipe/hop/protocol) as a fraction of the trader's total payment; SnipeTax tests (130 tests).
- **2026-09-10** Docs: final independent audit report and dispositions.
- **2026-09-11** Contracts: fix final-audit findings F1–F11 (lazy continuation adoption, gas-bounded handover + `cancelSunset`, mulDiv chain walk, dual TWAP + daily limit, depth-scaled bond, `maxIndex`, `DEVELOPER`/`STEWARD` env); 145 tests.
- **2026-09-11** Spec: final-audit fixes reflected (lazy adoption, gas-bounded handover, dual TWAP, depth bond, chain-depth cap); 145 tests.
- **2026-09-11** Testnet 46630 run 2: final code deployed and verified, full live round, earmark drawdown and daily limit fired live.
- **2026-09-11** Docs: CONTEXT, PROGRESS, ROADMAP, README, DEPLOY_CONSTANTS consolidated.
- **2026-09-11** Docs: manual audit prompt for an external tool or a paid auditor.
- **2026-09-11** Docs: external final audit (manual run) recorded.
- **2026-09-11** Docs: dispositions for the manually run external audit; roadmap: 1-hour testnet handover instead of 7 days.
- **2026-09-11** Contracts: fix external final-audit findings 1-11 (min-of-three keeper pricing, transitive adoption guard, `deployHopPot`, `MIN_BOUNTY_WEI`, token-bucket allowance, pending-forward queue + flush, creator transfer semantics, dirty-word/sync containment, v4 protocol fee in score, loser exits, lens pagination, `sunsetDelay` param); 160 tests.
- **2026-09-11** Roadmap: pre-audit gas pass (token clones, score packing, optimizer).
- **2026-09-11** Roadmap: gas pass moved to NEXT item 2, before the paid audit.
- **2026-09-11** Spec: manual external-audit fixes reflected; readiness corrected (bond refundable to winners); 160 tests.
- **2026-09-11** Testnet 46630 run 3: post-audit code, full round + live 1h sunset/cancel/adoption/forwarding/flush/v2 round/cross-version bids; INTERFACES rebuilt.
- **2026-09-11** Spec: run 3 addresses and liveness (only the slow-TWAP floor never fired).
- **2026-09-11** Gas pass: token clones (-21% register, -24% genesis), packed hook storage, route memoization, sizing-view fix; 162 tests.
- **2026-09-11** Spec: gas pass (clones, packed storage, nonce chain, gas table); 162 tests.
- **2026-09-11** Testnet 46630 run 4: gas-optimized final bytecode, verified, full round; sizing view fixed on chain.

---

## Completed (detailed)

### Research
Four dossiers in `research/`: `01-doppler.md` (Doppler protocol architecture, VERIFIED/UNVERIFIED tags), `02-pons-v4-robinhood.md` (Pons V2 mechanics + Uniswap v4 oracles/hooks on Robinhood Chain), `03-infinite-family.md` (adversarial on-chain review of Infinite Family, read hours after its genesis), `04-memepad-cashcat.md` (MemePad/CashCat structural comparison — neither has a competition mechanic). On-chain verification of Robinhood Chain mainnet/testnet RPCs, Uniswap v4 PoolManager address and bytecode parity: `research/onchain-verification.md`.

### Design decisions
All decisions and their reasoning are recorded in `CONTEXT.md` §4 (link, not restated here) — launch primitive, genesis, round timing, score, threshold, win cost/snipe tax, bond, fees, fee split, ancestor weighting, payout delivery, curve shape, routing, admin/continuation, scope, external-tool usage.

### External design audit
`docs/reviews/2026-09-10-design-review.md` (independent design review) found 10 numbered findings plus Q2/Q5/Q6/Q8 against `docs/DESIGN_BRIEF_v1.md`; **verdict: reject v1**. Every finding was reconciled into `docs/DESIGN_BRIEF_v2.md`, resolution-by-resolution logged in `docs/attack-log.md`.

### Simulation suite
`sim/` modules: family graph, routing, fee allocator, reinforcement, rounds, agents, metrics, clmm/curves engine, scenario runner. 154 tests across the suite build-up. 10 scenarios (Sim 1–10) run at `full` scale against three curve baselines — SINGLE, LADDER, and the locked MID config (`docs/sim-results-final.md`). No scenario's verdict word flips between baselines.

### Contracts tranche 1–4
- **Tranche 1**: FamilyToken, FamilyHook, Locker, FamilyFactory, CurveMath — 24 tests.
- **Tranche 2**: RoundManager, FeeVault (Fenwick ancestor accounting), FamilyRouter, FamilyLens, candidate pools, invariants — 54 tests.
- **Pre-audit findings fix**: fixed all findings from `docs/reviews/2026-09-10-contract-review-internal.md` — 91 tests.
- **Tranche 4**: steward sunset (7-day, one-shot) + forward continuation across versions — 110 tests.

### Pre-audit review
`docs/reviews/2026-09-10-contract-review-internal.md`: an independent architecture-level review of `contracts/` at tranche 2 (54 tests) found **2 critical, 3 high, 6 medium, 12 low** — all fixed (91 tests).

### Deploy script + fork rehearsal
`docs/TESTNET_RUN.md`: `script/Deploy.s.sol` run to completion on an anvil fork of testnet 46630. `script/live/round.sh --fork` reached step (b) before a coordinator HOLD stopped further work. **No live broadcast to chain 46630 at this point.**

### Docs system
README.md, CONTEXT.md, PROGRESS.md, ROADMAP.md established per the project's documentation standard (`CONTEXT.md` §9).

---

## Completed 2026-09-10/11 (detailed)

### Contracts tranche 5 (2026-09-10)
Sunset handover of the ETH-edge fee to a named successor's vault, 50/50 head-creator/candidate-creator season cut, 15-minute (900 s) trading window (extended from 10 minutes to lengthen head-creator season income) — 119 tests. Docs system stood up in the same tranche: CONTEXT.md/ROADMAP.md/README.md/the original design brief.

### BidDeployer split for EIP-170 (2026-09-10; live deploy initially blocked)
A real testnet deploy attempt was blocked because `FeeVault` alone compiled to 25,550 bytes, over the 24,576-byte EIP-170 limit; full fork rehearsal stayed green and `round.sh` was rewritten for the final API. Fix: `BidDeployer` split out of `FeeVault` to hold the whole keeper/bid path (TWAP band, size cap, bid geometry, cross-version forwarding), leaving `FeeVault` with ledgers/accrual/claims only. Added bounty symmetry, candidate route caps, `buyCandidateWithParent`, and code-size + deploy-constant tests — 127 tests. First successful live deployment on testnet 46630 followed the same day: 9 contracts verified, one full round end to end including both keeper paths; `research/INTERFACES.md` links all marked verified live except sunset. Spec updated with live addresses.

### Exact-output fee basis fix (2026-09-10)
Hook fee (snipe/hop/protocol) is now charged as a fraction of the trader's TOTAL parent-side payment identically in both swap modes, on both the buy and sell side (see `docs/DEPLOY_CONSTANTS.md` "Snipe tax" row for the exact math). Previously the exact-output path grossed the fee up on top instead of computing it as a fraction of the true total cost, which understated the effective rate (e.g. 49.7% instead of 99% at the snipe start on parent-paying exact-output buys, and `rate/(1+rate)` instead of `rate` on exact-output sells). SnipeTax parity tests added — 130 tests.

### Final independent audit (2026-09-10)
The independent final contract review was completed; findings and dispositions are in `docs/reviews/2026-09-11-contract-review-final.md` and `docs/attack-log.md`.

- **F1** (high, blocker) — continuation forks the trunk during the 7-day sunset delay (constructor-time head adoption never re-checks the prior). FIX: lazy head adoption in `openRoundIfIdle` (prior sunset effective, `successor == this`, prior idle); v2 opens no round before adoption.
- **F2** (high, blocker) — a gas-burning successor could permanently brick every v1 swap; docs claimed the opposite. FIX: `forwardProtocolFee{gas: FORWARD_GAS}` (~400k)/`staticcall{gas: 30_000}` helpers with a negative-resolution cache, plus a steward `cancelSunset()` before effect.
- **F3** (high, blocker) — `ethPerTokenWad` underflowed to zero by generation ~10, stranding deep-generation ETH permanently. FIX: walk the amount through the chain with a full-precision `mulDiv` per link, inverted step-wise.
- **F4** (high, economic) — the 30-minute TWAP alone could be pumped to drain a generation's ETH sleeve. FIX: price at `min(TWAP_30m, TWAP_7d)` via a slow observation ring, plus a ≤10%/24h drawdown limit per generation.
- **F5** (medium) — keeper liveness decayed with chain depth (band required on all j+1 pools). FIX: band check moved to the target pool only; coverage still required everywhere.
- **F6** (medium, economic) — threshold H is near-meaningless past generation ~2 (bond is the only real cost). Decision: depth-scaled bond, disclosed.
- **F7** (medium) — keeper bounty below gas cost at beta scale. FIX: size cap widened against the first curve range's capacity.
- **F8** (medium) — developer address was hardcoded to the deployer key. FIX: `DEVELOPER`/`STEWARD` env vars, required, with an equality guard.
- **F9** (low) — exact-output sells under-taxed by `rate/(1+rate)` instead of `rate`. FIX: symmetric gross-up (see fee basis fix above).
- **F10** (low) — spam/sybil cost ≈ $4, unpaginated candidate list. FIX: paginated `candidateIds` view.
- **F11** (info) — stale comment (60 s vs 120 s observation spacing), timestamp-monotonicity note, `deployBlock` logging artifact. FIX: comments corrected, documented.

All 11 fixed (2026-09-11) — 145 tests; spec updated to match. **None of the fixes have been re-audited** (see Known bugs, and CONTEXT.md §9 checklist below).

### Testnet run 1 (stale, superseded) and run 2 (final code, live) — 2026-09-11
Full detail in `docs/TESTNET_RUN.md`; deployment record `deployments/46630.json` (run 2, current) vs `deployments/46630.v1-stale.json` (run 1, pre-F1–F11-fix code, addresses different, must not be used).

- **Run 1** (early code, 2026-09-11 03:50–04:52 UTC): deployer/steward/developer all `<deployer>`; 0.05877 ETH spent; one full round, head moved genesis → CAND-A (index 0 → 1); sunset never exercised.
- **Run 2** (final code, 2026-09-11 07:09–07:58 UTC): same deployer/steward/developer; 0.058772 ETH spent. Addresses (chain 46630, from `deployments/46630.json`): FamilyFactory `<testnet-addr>`, FamilyHook `<testnet-addr>`, Locker `<testnet-addr>`, RoundManager `<testnet-addr>`, FeeVault `<testnet-addr>`, BidDeployer `<testnet-addr>`, FamilyRouter `<testnet-addr>`, FamilyLens `<testnet-addr>`, genesis FamilyToken (FAM0) `<testnet-addr>`. All 8 non-token contracts report `is_verified/is_partially_verified = true, is_fully_verified = false` on Blockscout — a PARTIAL match only, because `foundry.toml` sets `bytecode_hash = "none"` so no metadata hash exists to match on; every byte of runtime code matched regardless (run 1's "full match" claim was corrected as wrong for the same reason).
 - Headline effects (from `docs/TESTNET_RUN.md`): genesis buy accrued 537,500,000,000,000 wei (1.075% = 1% protocol + 750 ppm hop) to spec; CAND-A/CAND-B cleared H (11.2x / 8.3x), CAND-C did not (0.47x, deliberately halved mid-round); head moved genesis → CAND-A (`<testnet-addr>`), canonical index 0 → 1; F6 depth-scaled bond schedule live (0.001 ETH at index 1/2, per-round `bondFor`); F10 paginated `candidateIds` exercised (pages of 2); dev claim 111,020,778,715,507 wei; **`genesisBidEarmark` FIRED for the first time** (2,000,000,000,000,000 → 1 wei — the forfeited bonds were actually deployed, closing a gap run 1 left open); **F4 daily drawdown limit fired and bound live** (`drawableEth(1)` = 10% of what was claimable when the window opened = 2,666,666,666,666 wei, strictly less than `bidCap(1)`, so the keeper is capped by the rate limit and must return the next day for the rest); F4 slow (7-day) TWAP still reported `SlowTwapUnavailable` (pools minutes old, 3,208–3,541 s of the required 86,400 s coverage) — **the slow-TWAP floor itself has still never fired**, by design, since no pool is a day old yet; both keeper TWAP-band calls passed on the first attempt.
 - **Not exercised in either run:** sunset/`announceSunset`/`cancelSunset`/handover (fork-only, per Audit Standard counted as "never fired = broken"); the slow-TWAP floor actually flooring a price; finalize-with-no-clearer; multi-EOA contention; indexer listing.

### Spec/readiness updates
Spec updates covered the delta pass to final code (pre-tranche-5-fixes baseline), the BidDeployer split, live testnet addresses, and the final-audit fixes reflected — `docs/spec/PROTOCOL_SPEC.md` and `docs/spec/READINESS.md` now track the final, audited-and-fixed code (145 tests) plus live testnet run 2 addresses.

### Docs system
README.md/CONTEXT.md/PROGRESS.md/ROADMAP.md maintained in place per `CONTEXT.md` §9; `docs/attack-log.md`, `docs/reviews/2026-09-11-contract-review-final.md`, `docs/TESTNET_RUN.md`, `docs/DEPLOY_CONSTANTS.md` added/updated as the corresponding work landed.

### Manually run external final audit (`docs/reviews/2026-09-11-contract-review-external.md`, 2026-09-11) and fix tranche
An independent external contract review audited the tree at that point. **Verdict: NOT READY for a public beta.** 11 numbered findings plus disclosure additions; all 11 fixed, spec updated (160 tests). Dispositions in `docs/attack-log.md` "External final audit (manually run)":

- **1** (high) — a price crash let the keeper be overpaid because only the target pool was spot-checked. FIX: every conversion link priced at `min(spot, TWAP_30m, TWAP_7d)` in value terms; crash regression test.
- **2** (high) — an unadopted intermediate continuation could still fork the trunk. FIX: adoption requires the immediate prior to be a root or already `adopted()`; `announceSunset` on an unadopted continuation reverts; v1→v2→v3 overlap test.
- **3** (medium) — the terminal generation's hop pot had no deployment path (permanent at `MAX_INDEX`). FIX: permissionless `deployHopPot(j)`, 1% bounty paid in the parent token.
- **4** (medium) — gas decided which version booked fees; forwarding recursion died by v5. FIX: post-sunset fees are never booked locally — forwarded in-swap when the gas budget allows, else queued in `pendingForward` with a permissionless `flushForward`; per-version hop, no recursion; tested to six versions.
- **5** (medium) — keeper economics were negative at depth. FIX: `MIN_BOUNTY_WEI` floor from the generation's ETH entitlement, capped at 20% of the ETH consumed; dead zones below the floor disclosed, not eliminated.
- **6** (medium) — the "10%/24h" daily limit was a resetting window (~19% could leak out at a boundary). FIX: token-bucket allowance, continuous refill, 10% cap.
- **7** (medium) — successor containment gaps: a dirty 32-byte return word reverted every attributed third-party route; a successor's `sync(ERC20)` broke subsequent native `settle`. FIX: validate upper bits before decoding; `sync(native)` before native settlement in router and Locker.
- **8** (medium) — losing candidates had no exit or attribution after the round. FIX: candidate routes work post-round via the recorded round parent, 100% attribution to the candidate's own creator.
- **9** (medium, conditional) — an enabled v4 protocol fee would inflate the absorption score. FIX: subtract the increase of `protocolFeesAccrued(parent)` across the swap.
- **10** (medium) — the "non-refundable bond floor" disclosure was false for winners. FIX: docs corrected — winners always get the bond back; only losers forfeit.
- **11** (low) — the lens loaded the whole candidate array. FIX: paginated overload used.
- Also fixed in the same tranche: creator-right transfer no longer moves already-accrued fees or accepts the zero address; **`sunsetDelay` became a `RoundManager` constructor parameter** (`SUNSET_DELAY_S` env var, mainnet default 7 days, contract floor `MIN_SUNSET_DELAY` = 1 hour) so testnet could exercise the full sunset → handover → adoption → forwarding path live instead of waiting a week.

### Testnet run 3 (2026-09-11) — post-audit code, first live handover
Full detail in `docs/TESTNET_RUN.md`; record `deployments/46630.run3-stale.json` (all three Run-3 stacks; the v2 continuation is also referenced from `deployments/46630.json` as `handoverEvidence`). Deploy window 2026-09-11T17:41Z–20:49Z, block range 117,595,148–117,672,571; deployer/steward/developer all `<deployer>`; **0.101847 ETH spent** (cap 0.2, projected 0.11219). Three stacks: v1 (root trunk, indices 0-1), v2 (the continuation, live-at-the-time, indices 2..), v3 (disposable, used only to exercise `cancelSunset` without spending v1's one-shot hatch). One full round on v1 plus a live 1-hour (`SUNSET_DELAY_S=3600`) sunset → `cancelSunset` (on the disposable v3) → sunset effective → lazy adoption → a full v2 round → in-swap forward and queue+`flushForward` of post-sunset fees → cross-version keeper bids (v2's keeper deployments funded through v1's own BidDeployer/Locker for v1-era generations). **Every previously "never fired = broken" line of `research/INTERFACES.md` except the 7-day slow-TWAP floor now has a live tx hash.**

### Gas pass (2026-09-11) — 162 tests
Token clones (EIP-1167 `Clones.clone` of one sealed `FamilyToken` implementation instead of a full deploy per token), packed `RegisteredPool`/TWAP-ring storage (a scored swap touches four slots, a ring write is one `SSTORE`), route memoization (router resolves each path index's currency once per route), transient-storage caching of the `isSunsetEffective` gas-capped probe, and the audit-9 `protocolFeesAccrued` snapshot skipped when the pool's v4 protocol fee is zero. Fixed the audit-5 `maxParentForDeploy` sizing view, which previously returned 0 at beta scale. Optimizer stays at `runs = 200` — `via_ir` makes the pinned `v4-core` `Pool.swap` fail to compile above ~210 runs, a dependency ceiling not a size one.

| Action | Before | After | Delta |
|---|---:|---:|---:|
| `registerCandidate` | 1,607,652 | 1,275,852 | −331,800 (−20.6%) |
| `createGenesis` | 1,390,171 | 1,052,179 | −337,992 (−24.3%) |
| Routed 3-hop buy (ETH → #0 → #1 → #2) | 1,403,824 | 1,283,514 | −120,310 (−8.6%) |
| Routed 2-link buy (ETH → #0 → #1) | 670,872 | 591,780 | −79,092 (−11.8%) |
| Genesis exact-in buy | 637,029 | 630,650 | −6,379 (−1.0%) |
| Candidate-pool swap during a round | 495,944 | 489,516 | −6,428 (−1.3%) |
| `submitScore` | 194,151 | 194,157 | +6 |
| `finalize` | 265,154 | 267,820 | +2,666 |
| `deployAncestor(j=1)` | 570,185 | 559,696 | −10,489 |
| `deployGenesisBid` | 448,461 | 443,343 | −5,118 |
| `claimDev` | 50,862 | 50,200 | −662 |
| Cross-version 3-hop route | 1,638,865 | 1,478,106 | −160,759 (−9.8%) |

### Testnet run 4 (2026-09-11) — final gas-optimized bytecode, current live deployment
Full detail in `docs/TESTNET_RUN.md`; record `deployments/46630.json`. A single fresh trunk (`continuesFrom = address(0)`) built from the gas-pass code (162 tests). Deploy window 2026-09-11T22:39:53Z–23:40:47Z, block range 117,719,519–117,743,628; deployer/steward/developer all `<deployer>`; **0.058470 ETH spent** (cap 0.1, projected 0.06575). **All nine contracts (the new `tokenImplementation` included) verified on Blockscout on the FIRST submission attempt** (`~9 minutes for all nine) — unlike run 3, which needed up to five resubmissions for `FeeVault`/`BidDeployer`; still only a PARTIAL match (`bytecode_hash = "none"`, see Known issues). Candidate tokens now resolve as genuine `proxy_type = eip1167` clones of `tokenImplementation` instead of "twin-matched" guesses. One full round (genesis buy, three candidates registered, a candidate sale, three scores, `finalize` with a head change genesis→CAND-A, `claimDev`, a second round finalized with no winner, both keeper paths — `deployGenesisBid`/`deployHopPot`/`deployAncestor`, `claimCreator`) and is now idle. **No handover was run on this bytecode** — Run 3 already exercised the whole cross-version handover on functionally identical contracts, so it is kept as handover evidence instead of repeated.

Gas, Run 4 vs Run 3 (same driver, same sizes, same gas price) — headline wins hold on chain:

| step | Run 3 gas | Run 4 gas | Δ |
|---|---:|---:|---:|
| `createGenesis` | 1,390,565 | 1,055,400 | −24.1% |
| `registerCandidate` (first of a round) | 1,612,417 | 1,273,425 | −21.0% |
| `registerCandidate` (subsequent) | 1,445,284 / 1,445,179 | 1,111,320 / 1,111,396 | −23.1% |
| routed buy `buyCandidateWithParent` (A/B/C) | 504,142 / 452,858 / 436,185 | 490,311 / 439,356 / 422,736 | −2.7 / −3.0 / −3.1% |
| `sellCandidate` | 649,310 | 602,271 | −7.2% |
| `finalize` with a winner | 309,167 | 312,083 | +0.9% |
| ERC20 `approve` on a family token | 50,869 | 55,325 | +8.8% (the clone's delegatecall) |
| deploy, whole stack | 23,979,126 (6 txs) | 24,305,384 (7 txs) | +1.4% |

The whole-stack deploy costs slightly more (+1.4%) because the new 926,186-gas token-implementation deploy more than eats the factory tx's own 5.5% drop — the pass trades ~0.3M gas of one-off deploy cost for ~340k gas saved on every registration, which pays for itself inside two rounds. **The audit-5 sizing view is fixed and confirmed on chain**: `maxParentForDeploy(1)` returned 1,512,409,954,242,719,994,720 (run 3: 0 at the same scale), and the driver used the view directly with no hand sizing.

---

## Current status of every major feature

| Feature | Status | File |
|---|---|---|
| Research dossiers | done | `research/01-doppler.md`, `02-pons-v4-robinhood.md`, `03-infinite-family.md`, `04-memepad-cashcat.md`, `onchain-verification.md` |
| Design decisions | done | `CONTEXT.md` §1, §4 |
| External design audit (1st of 3) | done | `docs/reviews/2026-09-10-design-review.md`, `docs/attack-log.md` |
| Design brief v2 | done | `docs/DESIGN_BRIEF_v2.md` |
| Simulation suite (154 tests, 10 scenarios) | done | `sim/`, `docs/sim-results-final.md` |
| Contracts (all tranches, BidDeployer split, F1–F11 fixes, external final-audit fixes 1-11, gas pass) | done | `contracts/`, 162 tests |
| Deploy script | done | `script/Deploy.s.sol` |
| Final independent audit (substitute review pass) | done | `docs/reviews/2026-09-11-contract-review-final.md`, `docs/attack-log.md` |
| Final audit fixes (F1–F11) | done | this tranche, 145 tests |
| Manually run external final audit (2nd of 3, 11 findings) | done | `docs/reviews/2026-09-11-contract-review-external.md` |
| External final-audit fix tranche (findings 1-11 + `sunsetDelay` param) | done | this tranche, 160 tests |
| Gas pass (clones, packing, memoization, sizing-view fix) | done | this tranche, 162 tests, `docs/DEPLOY_CONSTANTS.md` |
| Spec updates (`PROTOCOL_SPEC.md`/`READINESS.md`) | done, tracks final gas-pass code and run-4 addresses | `docs/spec/PROTOCOL_SPEC.md`, `docs/spec/READINESS.md` |
| Live testnet deployment | done (run 4, final gas-optimized bytecode, current) | `deployments/46630.json`, `docs/TESTNET_RUN.md` |
| Live round run (registration → trading → finalize → keeper paths) | done, on run 4 bytecode | `docs/TESTNET_RUN.md` |
| Sunset/handover (F1/F2, external-audit-finding-2/4 fixes) | done live, on **run 3** bytecode only — **not re-run on run 4** | `docs/TESTNET_RUN.md` "Run 3", `deployments/46630.run3-stale.json` |
| Slow (7-day) TWAP floor (F4) | **still never fired live** — needs a pool ≥1 day old; next possible after 2026-09-12T18:00Z | `docs/TESTNET_RUN.md` |
| External contract review (final) | done, 11 findings, all fixed | `docs/reviews/2026-09-11-contract-review-external.md` |
| Paid/independent 3rd-party audit | not started | — |
| Infra plan (UI phase) | done (plan only, not built) | `docs/INFRA_NOTES.md` |
| UI | functional on testnet, cartoon brand pass in progress | `web/` |
| Mainnet deployment | not started, awaiting mainnet inputs | — |
| Contract tag `review-1` | frozen; export live and clean | `scripts/export-public.py`, `~/dollhouse-review` |
| Property tests (F/I) | done, 74 tests green | `test/properties/`, `docs/security/PROPERTY_RESULTS.md` |
| Fork tests (K) | done, 31 tests green | `test/fork/`, `docs/security/FORK_RESULTS.md` |
| Full suite / deep fuzz | 300 tests pass; 5000 runs / 200×100 invariants green | `docs/security/` |
| Slither | done, 0 findings, 3 accepted risks | `docs/security/slither-triage.md` |
| Halmos | done, 9 checks pass, 2 known timeouts parked | `docs/security/halmos-review-1.md` |
| Medusa | done, 5 properties held over 165k calls / 300 s | `docs/security/medusa-review-1.txt` |
| Certora | two rounds run, no genuine bug, review-2 items queued | `certora/RESULTS-review-1.md` |
| Web chain-seam audit + fixes | done, 14 findings, 2 disclosed open items | `docs/reviews/2026-09-12-web-review.md` |
| Friends' review, V12 run, paid audit | not started, waiting on owner-side accounts | `ROADMAP.md` |

---

## Known bugs or issues discovered (not fixed)

- **2026-09-11** The 7-day slow-TWAP floor (F4 fix) has **still never fired live**, on either run 3 or run 4 — every testnet pool is at most hours old, so `consultSlow` never covers the required 86,400 s and every keeper call is priced on the 30-minute TWAP alone (min-of-three since the manual external-audit fix). The genesis pool's earliest possible coverage is 2026-09-12T18:00Z (86,400 s after its first observation); the branch that actually floors a price with the slow average remains unexercised until then. `docs/TESTNET_RUN.md`.
- **2026-09-11** The sunset/successor handover is proven live only on **run 3's bytecode** (`announceSunset`, `cancelSunset`, the 1-hour delay, lazy adoption, in-swap forward, queue+`flushForward`, cross-version bids all fired with tx hashes) — it has **not been re-run on run 4's** gas-optimized bytecode, deliberately, to avoid spending another stack and another hour of chain time on functionally identical contracts. Per the Audit Standard, this is disclosed as evidence one build old, not as fired on the current live code. `docs/TESTNET_RUN.md` "Run 4 / Not exercised".
- **2026-09-11** Blockscout verification on testnet 46630 is PARTIAL, not full, for every contract in every run (`is_fully_verified = false`, including the run-4 `tokenImplementation`) because `foundry.toml` sets `bytecode_hash = "none"`, leaving no metadata hash to match on; every byte of runtime code matched regardless. Run 4 improved reliability (all nine passed on the first submission, vs up to five resubmissions for `FeeVault`/`BidDeployer` on run 3) but the match is still only partial. `docs/TESTNET_RUN.md`.
- **2026-09-11** Ordinary post-sunset trades take the QUEUE branch (`pendingForward` + a manual `flushForward`), not the in-swap forward, whenever the successor call's gas budget is thin relative to `FORWARD_GAS`; `flushForward` is therefore a routine, expected step of the handover flow, not a rare fallback. Disclosed so it isn't mistaken for a failure mode. `docs/DEPLOY_CONSTANTS.md` "Post-sunset fee forwarding".
- **2026-09-11** Keeper economics (`deployAncestor`/`deployGenesisBid`/`deployHopPot`) have a disclosed dead zone below `MIN_BOUNTY_WEI`/the 20%-of-consumed cap: at small deployment sizes the bounty binds at 20% of what the call consumes, still under mainnet gas cost, and run 2 measured gas ≈215× the bounty at generation 1 and 121 wei of bounty at generation 8. Mitigated by the external-audit-finding-5 floor, not eliminated. `docs/DEPLOY_CONSTANTS.md` "Keeper deployment".
- **2026-09-11** Whole-stack deploy cost is now +1.4% higher after the gas pass (23,979,126 → 24,305,384 gas) — the new 926,186-gas token-implementation deploy more than eats the factory tx's own 5.5% drop. A one-off cost that pays for itself inside two rounds via the ~340k-gas-per-registration saving; disclosed so the deploy-cost line isn't read as a regression. `docs/TESTNET_RUN.md` "GAS: Run 4 vs Run 3".
- **2026-09-11** The independent final contract review was completed externally; findings and dispositions are in `docs/reviews/`.
- **2026-09-11** `deployments/46630.json`'s `deployBlock` field is a `forge script` VM artifact (11,684,890 for run 4), not the real live deploy block (117,719,519). Nothing on chain depends on it; the real blocks are recorded separately in `docs/TESTNET_RUN.md`'s deploy-transaction tables.
- **2026-09-10** Simulation engine's `clmm` overlapping-position walk has a known limitation; worked around by `flatten_pool`, not fixed. `sim/clmm.py`.
- **2026-09-11** The competition threshold H is near-free to clear from generation 3 on (F6) — bond is the only real cost of extending the chain past that depth. Mitigated, not eliminated, by the depth-scaled bond (`bondFor`); disclosed per the F6 decision. `docs/DEPLOY_CONSTANTS.md` "Bond" row.
- **2026-09-10** Continuation-stack caveats (empty Fenwick trees on a new version, sunset ETH-edge handover edge cases, one-round attribution window during sunset handover) — disclosed in `docs/DEPLOY_CONSTANTS.md`, not resolved, inherent to the forward-continuation design.
- **2026-09-10** Block-1 snipers are still net-profitable after the 99% snipe tax on steep curves (Sim 5 finding, `docs/sim-results-final.md`).
- **2026-09-10** Reinforcement (ancestor/parent buy support) is slow accretion, not a shock absorber — moves a 99%-dump drawdown from 49.8% to 49.7% at realistic budgets (Sim 3/9). Disclosed, a design limitation to communicate in UI copy, not a bug per se.
- **2026-09-12** Web: browser-clock countdowns can drift from chain time (F10, open) and some constants are duplicated between chain reads and copy instead of a single source (F12, open); a real wrong-chain wallet test is still needed before beta. `docs/reviews/2026-09-12-web-review.md`.
- **2026-09-12** Certora review-1: `FEE-01`'s per-pool half is unproved (a vacuous `satisfy`, not a pass) and needs restating; `bondIsMonotoneInDepth` times out and needs `BOND_DOUBLING_EVERY` pinned to converge; four latent-risk items plus doc corrections are queued for review-2 (not yet fixed): guarantee `isGenesis ⇒ tradingStart == 0` inside `FamilyHook.registerPool` itself rather than relying on the factory; replace the `updatedAt == 0` drawdown sentinel and the `randomId != 0` request guard with explicit booleans; add a reentrancy lock around `FeeVault.accrue`'s call to the successor vault and update `ledgerTotal` before it. `certora/RESULTS-review-1.md`, `ROADMAP.md`.
- **2026-09-12** `RANDOM_END_S` is not scaled by `DURATION_SCALE_DIV` on testnet — a testnet-harness fact, not a mainnet parameter to change, but disclosed so it isn't mistaken for a live bug. `ROADMAP.md`.
- **2026-09-12** Keeper bounty economics remain negative at testnet scale (disclosed dead zone from the external-audit-finding-5 floor, not fixed) — carried forward from the run-6 finding.

### 2026-09-12 (evening): review-2
- Contracts tagged `review-2`: hook-enforced no snipe window on genesis; explicit flags replace zero sentinels (drawdown bucket, end request); vault accrual reentrancy-locked with accounting complete before the successor hop and `ledgerTotal <= holdings` at every point; unlock guard (`V4UnlockGuard`, pool manager lock slot via `exttload`) on round transitions, claims and keeper entrypoints, bound at wiring, self-checked at deploy, verified live against the testnet pool manager (fork test); random-end window clamped to a quarter of the round; sleeve bound check before the zero return; flat 15-minute closing window on every round; score ring sized for the full settlement tail including `END_TIMEOUT` (51 s slots, 3213 s reach on mainnet) after an independent diff review found the old sizing let a rival roll the leader's history out of the ring during a delayed relay; max index defaults to and is capped at the Fenwick limit. Full suite 322 pass (fork excluded), 31 fork tests, sizes under EIP-170 (largest 23,051 B).
- Independent diff review of review-2 (`docs/attack-log.md` "Review 2" and "Review 2b"): one high (ring reach), two medium, three low, all fixed; no irreversible action added.
- Sims re-run under the flat window (193 sim tests); Certora WSL runbook; keeper service (`keeper/`, 19 decision tests, dry run on testnet); web: fixed hero buttons, proportional fee bar, beacon-wait state, demo mode with 17 states and contact sheets, paired market-cap/score cell, uniform Chain-page avatars with flow arrows, flat-window copy.
- Export rebuilt at `~/dollhouse-review` (323 files, scan clean). Testnet deployment is still the review-1 code (run 6); a review-2 redeploy (run 7) is recommended before reviewers test live.
