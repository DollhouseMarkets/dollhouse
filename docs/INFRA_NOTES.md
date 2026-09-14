# Infra notes — scale target: 10,000 concurrent visitors, burst-scalable, no downtime during a round

> Next steps for this plan (load test, indexer, CDN) live in `ROADMAP.md` — not here.

Requirement (2026-09-10): the site must not go down and lose momentum; RPC capacity must scale quickly.

## What the contracts must do (in scope now)
1. **One-call reads.** A `FamilyLens` view contract returns, in a single `eth_call`: current head, round phase + timestamps, and for every candidate in the round `(token, score, reserve, spotPrice, tokensSold)`. Paginated by candidate index for very large rounds. A page load = 1 RPC call, not N.
2. **Indexer-grade events.** Every state change emits an event with all data an indexer needs (`RoundOpened`, `CandidateRegistered`, `TradingStarted`, `ScoreUpdated` (per swap, cheap), `RoundFinalized`, `HeadChanged`, `FeeAccrued`, `Claimed`, `ReinforcementDeployed`). Live leaderboards come from an indexer/WebSocket log stream, not polling.
3. **Deploy scripts write `deployments/<chainId>.json`** (addresses, block numbers, ABIs path) for the frontend and indexer.
4. **No on-chain calls required for display math.** Scores and prices are derivable from events + curve constants off-chain, so an indexer can serve the whole UI from its database if the RPC is saturated.

## Hosting recommendation (UI phase, later)
- **RPC:** Alchemy Robinhood Chain (`https://robinhood-mainnet.g.alchemy.com/v2/{KEY}`, WS available) on a paid tier with autoscaling compute units; public `rpc.mainnet.chain.robinhood.com` as read fallback only. Keep a second provider key ready (e.g., QuickNode/dRPC if they list 4663) for failover behind a tiny proxy.
- **Reads:** an indexer (Ponder or Goldsky subgraph) serving the leaderboard/round API; CDN-cached JSON (1–2 s TTL) for the hot round page so 10k viewers hit the CDN, not the RPC.
- **Writes:** users' wallets sign and broadcast themselves; the site never proxies transactions.
- **Frontend:** static site on Vercel/Cloudflare Pages (global CDN, autoscale by default).
- **Load test before launch:** 10k simulated viewers on the round page + 100 tx/min; verify RPC compute-unit burn and CDN hit ratio.
