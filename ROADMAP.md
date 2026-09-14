# ROADMAP.md — the only roadmap (updated 2026-09-12)

Completed work is logged in `PROGRESS.md`; do not add "done" items here. Decisions in force live in `CONTEXT.md`.

## Done since the last roadmap pass
Mechanism v3 (adaptive schedule, drand random end, late entry, purse; 226 tests); dev vesting + role transfer tranche; testnet run 6; review package tooling; neutral-voice rewrite; the privacy move of testnet identifiers into `private/`; contract tag `review-1` frozen with the full security-tooling pass (74 property tests, 31 fork tests, full suite 300, deep fuzz, Slither, Halmos, Medusa, two Certora rounds); the web chain-seam audit and fix tranche; the site-wide brand/story design pass. Detail in `PROGRESS.md`.

## Status 2026-09-12 (end of day)
Done at tag `review-1`: contract freeze; 74 spec-derived property tests (F/I) green; 31 fork tests against the real testnet PoolManager green; full suite 300 pass; deep fuzz 5000 runs / 200×100 invariants green; Slither run and hand-triaged (0 findings, 3 accepted risks); Halmos 9 symbolic checks pass (2 heavy checks parked as known timeouts); Medusa 5 properties held over 165k calls/300s; Certora two prover rounds run (no genuine bug, 21 non-success rules classified, review-2 items queued); review export passes the identity scan (316 files); web chain-seam audit done with fixes (14 findings, 2 open, 1 pending test). Open: review-2 Certora fixes; `FEE-01` restatement; `bondIsMonotoneInDepth` timeout fix; V12 run (needs the review GitHub account); friends' review; two open web findings (F10, F12) and the wrong-chain wallet test.

## Owner-side pending (blocking the items below until provided)
- WalletConnect project id (`VITE_WALLETCONNECT_PROJECT_ID`).
- V12 starter credit (support asked; scope `contracts/FeeVault.sol` + `contracts/FamilyHook.sol`).
- Friends' review findings.
- RPC/hosting accounts: Alchemy, Vercel, an indexer, DNS for dollhouse.markets.
- A preview review of the site (`cd web && npm run dev`).

## Checklist added 2026-09-12 (launch readiness beyond the contracts)
- [ ] **Friends' review**: repo is live (private, Dollhouse org); send the link + the private testnet-links note + the review guide pointer. Collect findings into `docs/attack-log.md`.
- [ ] **V12**: starter credit not applied to the account or the org; support asked. Scope when it lands: `contracts/FeeVault.sol` + `contracts/FamilyHook.sol` (libraries as context). Fallback if refused: Savant ($75 credit) on FeeVault alone.
- [ ] **review-2 contract fixes (from Certora review-1, all latent, no loss constructible):** enforce `isGenesis ⇒ tradingStart == 0` inside `FamilyHook.registerPool` (today only the factory guarantees it); replace the `updatedAt == 0` drawdown sentinel and the `randomId != 0` request guard with explicit booleans so a zero value can never be mistaken for "unset"; add a reentrancy lock around `FeeVault.accrue`'s call to the successor vault and update `ledgerTotal` before it. Also: fix PROPERTIES §7.14 arithmetic (101%, rates never summed on one pool); FEE-01's per-pool half is unproved (vacuous `satisfy`) — restate; `bondIsMonotoneInDepth` timeout → pin `BOND_DOUBLING_EVERY`; re-run the three specs after the second-round edits (from WSL, JDK 19+; result fetch needs a browser-like User-Agent).
- [x] **Certora prover** on the spec-derived CVL (free minutes): two rounds run; results in `certora/RESULTS-review-1.md`. review-2 (8 runs) done: `FeeVault` 17/20, `RoundManager` 20/26 fully verified, bond monotonicity proved; `SLV-03` (loop-bound timeout) and `FEE-01` (per-pool, unreachable under summaries) remain unproved; one rule (ledger decomposition) regressed by the pass, fix queued; results in `certora/RESULTS-review-2.md`.
- [x] **Frontend audit**: seams between `web/` and the chain audited and fixed (`docs/reviews/2026-09-12-web-review.md`, 14 findings). Open: browser-clock countdown drift (F10), duplicated constants (F12), and a real wrong-chain wallet test still needed before beta.
- [x] **Slither re-run at review-3**: 272 results, 0 findings; purse-related rows removed with the code, one new deploy-time-probe row dispositioned false positive; review-1 triage preserved.
- [x] **Independent diff review of review-3**: no contract defect found; wrong-pool deposit structurally impossible; two keeper findings fixed (scan every crowned generation for a deployable purse; do not spend the per-generation budget on a mined revert); purse reframed in docs as a permanent buy wall under the winner (just under spot to ~6% below, ≤2% of depth per deployment, ≤10% of accrued ETH per day) extending reinforcement's effective share from 20% to 40% of the fee; sleeve pricing description corrected (`min(spot, TWAP30, TWAP7d)` along links 0..j-1; trunk pool band-checked ~3% against its own 30-minute TWAP).
- [ ] **Certora review-3**: re-run the spec against the review-3 contracts (purse rules removed) now that Slither and the diff review are clean; in progress as of 2026-09-13.
- [ ] **Certora review-4**: fold review-2's still-open items (`SLV-03` loop-bound proof, `FEE-01` per-pool restatement, the regressed ledger-decomposition rule) plus any review-3 findings into one pass before cutting the `review-3` tag.
- [ ] **RPC and hosting** (from `docs/INFRA_NOTES.md`): dedicated RPC (Alchemy Robinhood Chain, paid tier, autoscaling) with the public RPC as read fallback and a second provider key for failover; an indexer (Ponder or Goldsky) plus CDN-cached round JSON (1–2 s TTL) so viewers hit the CDN, not the RPC; static site on Vercel or Cloudflare Pages; users sign and broadcast their own transactions. Load test: 10k simulated viewers + 100 tx/min before launch. Accounts to create under the Dollhouse identity: Alchemy, Vercel, indexer provider, domain DNS (dollhouse.markets).
- [ ] **Local site**: `cd web && npm install && npm run dev` → http://localhost:5173 (reads addresses from `private/deployments/46630.json`; testnet addresses show only on chain 46630 or with `VITE_SHOW_ADDRESSES=1`).

## [NEXT]
- [ ] **Next revision constants and site**: bond flat 0.008 ETH at every depth (`BOND_BASE_WEI` = 0.008 ETH, doubling disabled: `BOND_MAX_WEI` = base) with docs, sims and the site copy updated; a public "chain treasury" page listing every purse and hop-pot deployment (coin, amount, date, explorer link) with running totals per coin and chain-wide, plus a support-ladder graphic on the coin page and an explorer link per deployment.

- [ ] **Keeper service** (infrastructure, before beta): an always-on process under the Dollhouse identity that, per round, calls the end request at the published end, fetches the drand beacon and relays it, submits scores, finalizes, and deploys a crowned generation's purse once; gas-only cost (testnet run 6 driver is the model). UI: default state "waiting for the beacon"; the manual relay button appears only after a couple of minutes without progress.
- [ ] **Hero buttons** (owner direction 2026-09-12, pending confirmation): fixed labels "Enter the round" and "Buy $DOLL"; launch stays in the nav. **Fee diagram**: the 1% as one bar split into four proportional segments with recipient icons, placed at the ETH edge of the nested rings.
 — security pipeline, in order
1. [x] **Freeze tag `review-1`** — done, with the full tooling pass.
2. [x] **Property tests** (74, `test/properties/`) and **fork tests** (31, `test/fork/`) — done.
3. [x] **Automated tools run alone, in sequence, then triaged once**: Slither, Halmos, deep fuzz, Medusa — all done (see Status above). V12-class run from the review account is still open (owner-side pending).
4. **Friends' review** from the fresh review account — open, waiting on the maintainer.
5. [x] **Halmos** on the target properties — 9 checks pass, 2 heavy checks parked as known timeouts.
6. [x] **Certora spec** written from the protocol spec — two rounds run; review-2 fixes queued (checklist above).
7. **Consolidate, cut a new tag (`review-2`), then the paid audit** — open, next up once review-2 fixes and the friends'/V12 reviews land.

## [ALSO NEXT] — carried open items
- **Purse live test (review 3, pre-live gate):** ONE `deployAncestor(j, amount)` landing on chain, with `PurseDeployed(j, canonical(j), amount)` in the receipt and the bid visible under the trunk coin's pool. The old contested purse was exercised manually on run 6; the uncontested rule has never fired anywhere — the pre-live gate requires this to run once with a funded generation and confirm the keeper proposes it unprompted, before mainnet.
- **Slow-TWAP floor live check** (the only never-fired path): call `deployAncestor(j, amount)` once a live pool clears 86,400 s of coverage and confirm `SlowTwapUnavailable` no longer fires and the 7-day price is used; record in `research/INTERFACES.md`.
- **`MIN_BOUNTY_WEI` mainnet value**: pick and record the mainnet figure (testnet used a scaled-down floor).
- **`RANDOM_END_S` is not scaled by `DURATION_SCALE_DIV` on testnet** — note only; this is a testnet-harness fact, not a mainnet parameter to change.
- **`DevVestingDeployer` verification record**: resubmit for a green check on its own address (see `docs/TESTNET_RUN.md`).
- **Domain / Vercel / Mintlify** setup for the public site and docs.
- **Clean brand assets**: finish the cartoon-doll kit across every screen.
- **Mainnet deployment inputs:** steward = a multisig (`STEWARD`), developer = a cold address (`DEVELOPER`), `MAX_INDEX` for the beta (auditor: ≤ 4), bond base ≈ $20 in ETH (`BOND_BASE`, doubling every 4 links, max 64×), genesis-pool ETH cap by policy (≤ 20 ETH), no `announceSunset` during the beta, ≤ 20 rounds.
- **Full-match verification:** set `bytecode_hash = "ipfs"` in `foundry.toml` for the mainnet build so Blockscout reports a full (not partial) match; re-verify on testnet first.
- **Website, documentation, first-week launch plan and artwork** (in parallel) including the **disclosures page copy** (facts from `docs/DEPLOY_CONSTANTS.md` "Measured, disclosed risks" and the auditor's items (a)–(i) in `docs/reviews/2026-09-11-contract-review-final.md` §5).

## [SOON]
- **Website**: functional app exists under `web/` (testnet). Pending the cartoon-style brand kit; then apply it via `web/src/styles/tokens.css` + character art, re-screenshot, deploy to Vercel/Cloudflare Pages, point at mainnet addresses after launch.
- **Docs**: Mintlify site under `docs-site/`; copy review, connect the Mintlify GitHub app, and add the $DOLL artwork.
- Re-run the one-hour handover (`script/live/continuation.sh`) on the run-4 (gas-optimized) bytecode so the handover evidence matches the final contracts.
- Depth economics on testnet: run a chain to #12, record `ethValueOfParent` per link, bond schedule in ETH, and a `deployAncestor(8)`; confirm keeper break-even at three pool sizes on mainnet gas.
- Contention test: a second EOA racing swaps, submits and keeper calls during a live round.
- Confirm mainnet PoolManager bytecode hash equals the pinned v4-core build; check the Uniswap protocol-fee controller status on 4663.
- Infra per `docs/INFRA_NOTES.md`: Alchemy paid tier, indexer (Ponder/Goldsky), CDN caching, 10k-viewer load test — once a UI exists.
- GMGN/DexScreener listing request for the mainnet genesis pool.

## [LATER]
- UI: head/next-link countdown, leaderboard from `FamilyLens` + indexer, chain visualization, disclosures, creator claim page, keeper page.
- Fix `sim/clmm.py` overlapping-position walk (worked around by `flatten_pool`); re-run Sims 3/9 with realistic edge-volume assumptions before quoting reinforcement effects publicly.
- Creator fee-destination options (receive / buy-and-burn / treasury), deferred from v1.

## [MAYBE]
- v2 continuation with mechanism changes learned from mainnet (sunset v1 with 7-day notice).
- Asymmetric edge fee (e.g., 1% buy / 2% sell) only if real elasticity data ever supports it (Sim 6: sign unknowable a priori).
- Threshold measured in ETH terms (rejected for now in favour of the depth-scaled bond).
