# MemePad (memepad.app) and CashCat / letscash.fun — Dossier (research, 2026-09-10)

Headline: neither implements a competition / king-of-the-hill mechanic. Both live on Robinhood Chain 4663.

## A. MemePad (memepad.app)
- **V** Docs https://memepad.app/docs. PadFactory 0x83Dd5cdC33C49066165B0Fe8494cc2c4C730C3E2; EthZap 0xD31819f648a17876837F790776328F1B5b8D8Ae1; $MemePad 0xb89974Bded1b1d57f32331CC63e11A805d73D23A; Uniswap v3 factory 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73.
- **V** "Contracts have not yet been audited by a third-party firm." No public repo found.
- **V** Constant-product AMM inside the token contract; 1e9 supply fully seeded; no dev allocation; mint burned and ownership to dead before first trade; opens at $4,000 mcap, graduates at $6,000 (USD via the quote coin's v3 WETH pool oracle); graduation LP is child/parent, permanently locked; anyone can trigger.
- **V** Pads: a community coin is the quote currency for every launch on its pad; 1% fee in the pad coin, **50% burned / 50% pad treasury**; no platform cut; gas-only creation. Pad eligibility: quote coin must have a real-liquidity Uniswap v3 WETH pool; one pad per coin.
- **V** No competition, no anti-snipe, no lockups, no max-wallet, no time-weighting.

## B. CashCat → letscash.fun
- **V** Rebranded from cashcat.fun; launched 29 Jul 2026; $CASHCAT 0x020bfC650A365f8BB26819deAAbF3E21291018b4 (originally on NOXA). Docs https://letscash.fun/docs. Contract addresses render n/a in docs. Audits announced (Hyacinth, SB Security), none published.
- **V** No bonding curve, no graduation: factory deploys token + seeds Uniswap **v4** pool + locks LP in one tx. Supply 1e9–1e15. Quote ETH or USDG, locked at launch. LP lock enforced in the hook; no unlock function.
- **V** Immutable tax 1/3/5/10% chosen at launch; platform always 0.3%; creator gets the rest (7000/9000/9400/9700 bps). Self-Burn mode: creator's 0.7% buys and burns. Platform 0.3% → 25% CASHCAT buy-burn, 25% buy-treasury, 50% ops.
- **V** Airdrop Vault: hash-committed recipient list, 5-min immutable notice, permissionless batch payout, auto-exclude LP addresses, **contents destroyed after 7 days if never published**.
- **V** Fees accrue in quote asset in the hook; `sweep(poolId)` permissionless; `claim(poolId)`; `collect(to)`; `updateCreator()`; up to 4 fee-split recipients summing to 10,000 bps; per-recipient collect. Keeper functions (`burner.burn`, CASHCAT buys) public with 1% bounty.
- **V** Leaderboard = all-time trader volume ranking; no rounds/prizes.
- Context: NOXA went dark 13 Jul 2026 (~60k launches, ~$12M fees); CASHCAT −33%.

## Mechanisms worth borrowing (verified in use)
1. Parent coin as mandatory quote for every child launch, locked child/parent LP (MemePad).
2. Objective eligibility gate for hosting (MemePad).
3. One pad per coin → single canonical lineage (MemePad).
4. Commit + notice + permissionless execution + destruction-on-abandon (CashCat).
5. Fee rate fixed once at launch with hard ceiling in non-upgradeable hook (CashCat).
6. Self-burn creator mode (CashCat).
7. Permissionless keepers with 1% bounty (CashCat).
8. Per-recipient collect, bps summing exactly (CashCat).
9. Mint burned before first trade, entire supply in curve, zero dev allocation (MemePad).
10. Fee burns the parent, not the child (MemePad).
Gaps: no time-weighted scoring, randomized ends, anti-snipe decay (except Pons), bonds, or sybil heuristics anywhere.
