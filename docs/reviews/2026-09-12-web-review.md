# Web app review — 2026-09-12 (read-only, at contract tag `review-1`)

Scope: every seam between `web/` and the chain or external data — RPC transport, wallet and chain gating, ABIs and argument order against `contracts/*.sol`, attribution data, the drand and spot-price fetches, transaction guards, polling cost at 10,000 concurrent visitors, and privacy of addresses in the bundle. No commands were run against the chain and nothing was built.

## Findings, ranked

### F1 — CRITICAL. A write can be sent on whatever chain the wallet is on; funds are lost.
`useTx.write` calls `writeContractAsync` with no `chainId` (`src/actions/useTx.ts`). Every action hook passes only address/abi/functionName/args/value. In the installed wagmi, `writeContract` resolves the connector client with `assertChainId: false` and passes `chain: null` to viem, which disables viem's chain assertion; the client's chain is the wallet's current chain, and this wagmi version does not simulate inside `writeContract`.

Scenario: wallet connected on Ethereum mainnet. The header offers "Switch to Robinhood" but nothing gates the trade button (`canSend` checks `isConnected` only). The quote path is safe (it simulates on the configured public client) so the trader gets no quote, ticks "Send without a minimum", clicks Buy. The transaction goes to Ethereum with `to` = the Robinhood router address and `value` = the amount. That address has no code on Ethereum, so the transaction succeeds as a plain transfer. The ETH is gone with no revert; the status panel then links to the wrong explorer.

### F2 — CRITICAL (privacy). Testnet addresses ship inside every production bundle.
`showAddresses()` gates rendering only. The address book is a module-level constant compiled into the JS (`src/contracts/addresses.ts`) with all chain-46630 addresses, the deploy block and the genesis pool id. Devtools on a public beta reads them; one explorer hop from the factory gives the deployer. `sync-contracts.mjs` strips `deployer`/`developer`/`steward` but not `devVestingDeployer`, and it emits every chain it finds rather than the active one, so a mainnet build produced on a machine that still has the testnet record ships the testnet stack too. `web/README.md` also tells a builder to commit the generated files, against `.gitignore` and the privacy rule.

### F3 — HIGH. The polling design will not survive beta; the stated batching is a no-op.
`wagmi.ts` sets `batch: { multicall: true }`, but neither chain definition declares `contracts.multicall3`. viem throws `ChainDoesNotSupportContract`, catches it internally, and silently falls back to one `eth_call` per read; wagmi's `readContracts` does the same. Per open tab: the round page issues about 6 calls/s (a hard-coded 3 s interval, not the phase-aware one); the chain page mounts one `useRound` per link inside `PurseStandings`, about 25 calls/s per visitor. At 10,000 visitors that is 60,000–250,000 calls/s against a single public RPC URL with no fallback. `useWatcher` polls logs at 4/8/8 s and calls `invalidateQueries()` with no key filter, so any swap by anyone invalidates every cached query on every client, including reads documented as read-once; `useTx` does the same on every receipt. react-query retries once and `refetchInterval` keeps firing on error, so a rate-limited client keeps hammering at full cadence.

### F4 — HIGH. RPC failure is indistinguishable from "does not exist".
`useRound` and `useChainState` return `error` and no page reads it. With a rate-limited or down RPC the round page says "No candidates in this round yet", the coin page "No canonical link #N yet", the candidate page "Unknown candidate". No global RPC-health banner; nothing is logged.

### F5 — HIGH. The snipe tax is never shown where money is spent, and the no-quote path sends `minOut = 0` into it.
The hook charges 99% → 1% linearly over the first 3 s of a candidate pool's trading. The trade panel shows a hard-coded "Fee: 1% + hops"; the snipe warning exists only on the disclosures page. `protocolFeePpm`, `hopFeePpm` and `snipeS` are all in the address book but unused. Scenario: a late entrant's pool opens at registration; a user clicks Get quote a second before `tradingStart`, the simulation reverts, the quote helper swallows it, the panel offers "Send without a minimum", the trader buys at dt≈0 with `minOut = 0` and pays a 99% tax after being told the fee was 1%.

### F6 — MEDIUM. The unsafe production configuration is the default.
Unset or unparseable `VITE_CHAIN_ID` silently selects testnet 46630. `vercel.json` sets no env and nothing pins the production value. `VITE_SHOW_ADDRESSES=1` is an undocumented production-capable override absent from `.env.example`.

### F7 — MEDIUM. No CSP, no frame-ancestors, no SRI.
`index.html` loads a Google Fonts stylesheet without integrity; `vercel.json` sets no security headers. Runtime origins: the RPC, `api.coinbase.com`, `api.drand.sh`, WalletConnect relay and verify hosts, Google Fonts. A money-moving dapp with no frame-ancestors can be framed for approval clickjacking. No secrets are in the bundle (verified: only `VITE_CHAIN_ID`, `VITE_RPC_URL`, `VITE_SHOW_ADDRESSES`, `VITE_WALLETCONNECT_PROJECT_ID`, `VITE_DOCS_URL`, `VITE_X_URL` are read; a WalletConnect project id is public by design).

### F8 — MEDIUM. The purse path dead-ends, and the deploy button submits a stale maximum.
Two screens tell the visitor to "call `rank`" but no `rank` action exists in the app; `purseWeights` reverts once the board is older than `RANK_MAX_AGE` (6 h), so a stale generation's purse cannot be deployed from the UI. Separately, the earnings page passes a 15 s-stale TWAP-band ceiling as the deploy amount; any price move between poll and inclusion reverts `deployAncestor`, and the keeper cannot choose a smaller amount.

### F9 — MEDIUM. The candidate page's support bar reads a field that is zero until the round is over.
It divides the submitted score (0 during trading) by the threshold, so every live candidate reads 0% while the round page shows the correct live trailing average for the same coin.

### F10 — MEDIUM. Every countdown, deadline and staleness check uses the browser clock.
Nothing reads `block.timestamp`. A client 60 s fast shows late entry closed while it is open; a client 60 s slow shows a live countdown after registration has closed and its registration reverts.

### F11 — LOW/MEDIUM. "Bond refund" is a button with no reading behind it.
The value renders as a literal dash and Claim is always enabled; `claimRefund` reverts when nothing is pending.

### F12 — LOW. Chain constants duplicated in copy instead of read.
"the whole 15 minutes" (wrong when D(n) > 1 h), fallbacks of 900/180 s before the read lands, a re-declared `RANK_MAX_AGE`, the hard-coded fee line, hard-coded supply and split on the launch review screen.

### F13 — LOW. A token address renders in a tooltip without the `showAddresses()` gate; `web/README.md` says the USD price is CoinGecko when the code calls Coinbase.

### F14 — LOW. Two silent fallbacks on the random-end path.
A failed or not-yet-loaded `isMock` read maps to "real drand", so a transient RPC failure on the mock source makes the relay fetch a nonsense round from `api.drand.sh`. The beacon proof is validated as hex but not as 64 bytes, which `DrandSource.fulfil` requires, so a malformed response costs the relayer a reverted transaction instead of a client-side error.

## Seam inventory (one hop past each)

| Boundary | Other side | Verdict |
|---|---|---|
| Router ABI ↔ `FamilyRouter.sol` | `buyExactIn`, `sellExactIn`, `buyCandidate`, `buyCandidateWithParent`, `sellCandidate` | Argument order and arity match exactly |
| `hookData` attribution | Built inside the router, decoded by the hook only when `sender == router` | No UI seam; correct by design |
| `registerCandidate` | `msg.value != bondWei` reverts; UI sends a ≤15 s-stale `currentBond()` | Cannot overpay; can revert on a round boundary; not phase-gated |
| `deployGenesisBid` overloads | zero-arg and one-arg both exist; UI passes no args | Resolves by arity |
| drand HTTP | `api.drand.sh/v2/beacons/evmnet/rounds/{n}` → `.signature` → `fulfilEnd(bytes)` | Beacon and scheme match; URL shape unverified; length not checked (F14) |
| Coinbase spot | `.data.amount`, 5 s abort, null on failure | Display-only; never reaches a transaction argument |
| Deployment JSON → bundle | strips three role keys, emits all chains | F2 |
| Wallet / chain | `writeContract` with no `chainId` | F1 |
| RPC transport | one URL, no fallback, no backoff | F3 |

## Claims verified / assumed
Verified: router argument order; attribution is contract-built; three role keys stripped; ETH/USD display-only with abort; drand proof passed unmodified; bond cannot be overpaid; generated files git-ignored; no secrets in the bundle; `RANK_MAX_AGE`/`SNIPE_S`/`SNIPE_START_PPM` match the UI's stated numbers; with no mainnet deployment record all reads self-disable.
Assumed and disproved: multicall batching (F3); "read once" for randomness (F3); the 1% fee shown before confirming is a string, not a read (F5); the README's CoinGecko claim (F13); `showAddresses()` keeps testnet addresses out of a build (F2). Unproven: that the production host sets `VITE_CHAIN_ID` (F6); that a multicall3 exists on 4663/46630.

## Links with liveness evidence / never fired
Nothing in the app has run against mainnet 4663. No in-repo liveness evidence exists for any link (RPC transport, wallet write path, WalletConnect, drand fetch → `fulfilEnd`, spot fetch, keeper deployments, claims, `claimRefund`, `submitScore`, `finalize`, `requestEnd`, `finalizeDeterministic`). Provably never fired: `rank` (no caller). Unreachable in production config: the populated contracts table (only on 4663, which has no deployment).

## Irreversible actions and their guards
| Action | Guard before confirming | Verdict |
|---|---|---|
| buys (ETH or parent) | simulated `minOut`, slippage select, fee text | fee text hard-coded; no snipe warning; no deadline; no chain guard |
| sells | same plus allowance | same gaps |
| `approve(router, MAX)` | none | silent infinite allowance, no revoke UI |
| `registerCandidate` | bond amount + five-bullet review | best-guarded path; not phase-gated |
| claims / `release` | amount shown, disabled at zero | adequate |
| `claimRefund` | none | F11 |
| keeper deployments | amounts shown; stale maximum submitted | F8 |
| permissionless round actions | no user funds beyond gas | OK; deterministic end correctly labelled as the fallback |

There is no client-side degraded mode: no maintenance flag, no read-failure banner. There are no tests under `web/`, so nothing asserts "no transaction on the wrong chain", "no address rendered off 4663", or "no transaction without a quote or an explicit acknowledgement".

## Unknowns and how to close them
1. Whether the drand v2 URL returns a 64-byte signature — one request against it and against the v1 form; compare the round with `DrandSource.roundAt`.
2. Whether multicall3 exists on 4663/46630 — `eth_getCode` at `0xcA11bde05977b3631167028862bE2a173976CA11`.
3. What `VITE_*` values the production host sets — pin them in a checked-in deploy config.
4. Public RPC quotas — ask the provider, then measure one tab and multiply.
5. Whether the wrong-chain write actually lands with the installed wallet — a burner on Sepolia with a trivial amount, before any beta.
6. Whether the generated ABIs match the current contracts — rebuild, resync, diff.
7. Whether the explorer hosts are live — one HEAD each.

## Top 5 fixes before beta
1. Pin `chainId` on every write and block submit buttons when the wallet chain differs, with an inline switch control (F1).
2. Bundle only the active chain and only what the UI needs; fail the build when `VITE_CHAIN_ID` is unset; grep `dist/` for addresses as a CI gate (F2, F6).
3. Cut read load an order of magnitude: declare multicall3 if it exists, share one round lookup in `PurseStandings`, phase-aware polling, key-scoped invalidation, a fallback RPC with backoff (F3).
4. Surface read failures with a global banner; compute the fee line from chain constants; show the snipe warning inside the first 3 s and refuse the no-minimum path there (F4, F5).
5. Add the `rank` action; let the keeper choose an amount; use the live trailing average on the candidate page; read the pending refund before enabling Claim (F8, F9, F11).

## Dispositions — 2026-09-12 (implementation pass)

Scope of this pass: the Top 5 fixes before beta, plus F7, F11, F13 and F14. Verified with
`tsc -b --force` (clean), `npm run build` (passes, including the new `dist/` address gate),
`vitest run` (9 passing), and a dev run against chain 46630 with Playwright screenshots of
`/`, `/round` and `/chain` at 1440x900 — 0 console errors on each. No contract, test or
Certora file was touched and `forge` was not run.

### Facts established

- **multicall3 — PRESENT ON BOTH CHAINS.** `eth_getCode 0xcA11bde05977b3631167028862bE2a173976CA11`
  returns 3808 bytes of code on **4663** and on **46630**. Both chain definitions in
  `web/src/config.ts` now declare `contracts.multicall3` (no `blockCreated`), so
  `batch: { multicall: true }` is real rather than a silently caught
  `ChainDoesNotSupportContract`. Unknown 2 in the list above is closed.
- **RPC choice.** `https://rpc.chain.robinhood.com`, the mainnet URL the app shipped with,
  **does not resolve**. The working mainnet endpoint is
  `https://rpc.mainnet.chain.robinhood.com` (answers `eth_chainId` with `0x1237` = 4663);
  the chain definition was corrected. Testnet stays
  `https://rpc.testnet.chain.robinhood.com` (`0xb626` = 46630). There is one public endpoint
  per chain, so the transport is `fallback([VITE_RPC_URL, public URL])` when the override is
  set and the public URL alone when it is not — never the same host listed twice, which
  would only double the load on a rate-limited provider.

### Per finding

| Finding | Disposition |
|---|---|
| **F1** wrong-chain write | **Fixed.** `useTx.write` is now the single write entry point and pins `chainId: activeChain.id` through `pinChain` (`src/lib/tx.ts`), overriding anything a caller passes. Every submit button — TradePanel buy/sell/quote/approve, Launch register, Earnings claims + release + keeper deploys + rank, Round finalize + submitScore, Chain rank, RandomEnd request/relay/deterministic-end — is disabled unless the wallet chain matches, with an inline "Switch to &lt;chain&gt;" control (`ChainGuard`, `useSwitchChain`) next to it. Asserted by `src/lib/tx.test.ts`: `pinChain` always yields a `chainId`, and `canSend` is false on the wrong chain and while the wallet reports no chain. |
| **F2 / F6** testnet addresses in the bundle, unsafe default config | **Fixed.** `sync-contracts.mjs` emits ONLY the chain in `VITE_CHAIN_ID` (read from the process env, then `web/.env.local`, then `web/.env` — Vite's own precedence) and exits non-zero with the fix spelled out when it is unset. Role accounts are stripped explicitly (`deployer`, `developer`, `steward`, `devVestingDeployer`, `roundManagerDeployer`), and an address key the script does not classify is now a hard error rather than a silent pass-through. `config.ts` has no default chain: a missing or unknown `VITE_CHAIN_ID` throws at startup. New `web/scripts/check-dist.mjs` greps `dist/` for 20-byte address literals and fails the build unless each is the active stack, the PoolManager it contains, Multicall3 or the zero address (one documented exception: a 40-hex secp256k1 GLV constant in `@noble/curves`); it is the last step of `npm run build`. `web/README.md` corrected: do **not** commit the generated files, Coinbase not CoinGecko, `VITE_CHAIN_ID` required, `VITE_SHOW_ADDRESSES` documented as debug-only. `.env.example` rewritten with no testnet default. |
| **F3** polling / batching | **Fixed.** multicall3 declared (see above). `PurseStandings` no longer mounts a `useRound` per row: the chain page makes one `useRoundSummaries` call — one `useReadContracts` of `roundView` for every needed round plus one multicall for the labels — and passes the result down. `roundView` now uses the phase-aware `pollInterval` instead of a hard-coded 3 s. `useWatcher` and `useTx` invalidate by key prefix and contract address (`src/lib/queryKeys.ts`), never the whole cache, and never the `staleTime: Infinity` wiring reads. Transport is `fallback([...])` with per-URL `retryCount`/`retryDelay`, react-query retries with exponential backoff, and a 429/5xx opens a 30 s circuit breaker in a shared wrapper that also exposes `rpcHealth` (`src/lib/rpc.ts`). |
| **F4** read failure indistinguishable from "does not exist" | **Fixed.** Global `RpcBanner` in `App`, shown whenever a core hook reports `error` or the breaker is open. `/round` renders "Candidates cannot be read right now", `/coin/:index` "Link #N cannot be read right now" and `/candidate/:id` "This candidate cannot be read right now" instead of the three existence claims. Breaker trips are logged to the console. |
| **F5** snipe tax unseen, `minOut = 0` into it | **Fixed.** The fee line is computed from `deployConstants.protocolFeePpm`, `hopFeePpm` and the route's hop count (`src/lib/fees.ts`), not a string. When the target is a candidate inside `snipeS` seconds of `tradingStart` — or before it — a red warning states the current tax (99% to 1% linear, mirroring `FamilyHook._snipeTaxPpm`) and the "Send without a minimum" checkbox is disabled outright; `canSend` refuses that path independently of the checkbox. |
| **F7** no CSP / frame-ancestors | **Fixed.** `vercel.json` sets `Content-Security-Policy` (`connect-src` naming both RPC hosts, `api.coinbase.com`, `api.drand.sh` and the WalletConnect relay/verify hosts; `frame-ancestors 'none'`; `base-uri 'self'`; `object-src 'none'`), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`. No policy relaxation was needed: the Vite build emits no inline script and no inline modulepreload, so `script-src 'self'` is sufficient (verified against `dist/index.html`). `style-src` keeps `'unsafe-inline'` because the app styles elements with the React `style` prop. **Not done: SRI on the Google Fonts stylesheet** (the URL serves content-negotiated CSS, so a fixed hash would break it); still open. |
| **F8** purse dead-end, stale deploy maximum | **Fixed.** `rank(candidateId)` added to `useKeeperActions`, with a Rank button in both places whose copy told users to call it: `PurseStandings` (chain page) and the keeper table (earnings page). The deploy form now takes an amount input defaulting to 95% of `maxParentForDeploy` and refuses anything above it. |
| **F9** support bar reads a field that is zero while trading | **Fixed.** The candidate page uses `useCandidateScore`, the same source the round page uses: the hook's `trailingAverage` over the closing window while trading and `averageOver` once the true end is known, with a submitted score taking precedence. |
| **F10** browser clock everywhere | **Open.** Out of scope for this pass. Nothing reads `block.timestamp`; every countdown, deadline and staleness check is still client-clock based, including the new snipe-window warning. |
| **F11** bond refund with no reading behind it | **Fixed.** `useEarnings` reads `RoundManager.pendingRefund(address)`; the amount is displayed and Claim is disabled at zero (and while the read has not landed — "nothing pending" and "not known yet" are kept apart). |
| **F12** chain constants duplicated in copy | **Partially fixed.** The hard-coded fee line is gone (F5). Still open: "the whole 15 minutes" on the candidate page, the 900/180 s fallbacks before the reads land, the re-declared `RANK_MAX_AGE` in `usePurse.ts`, and the hard-coded supply and fee split on the launch review screen. |
| **F13** ungated address tooltip; README's CoinGecko claim | **Fixed.** The round page's trade-column tooltip is behind `showAddresses()`; README says Coinbase. (`ConnectWallet` still shows the connected user their own address, which is theirs to see.) |
| **F14** silent fallbacks on the random-end path | **Fixed.** `useRandomness().isMock` is tri-state — `true`, `false`, or `undefined` until known — and only a genuine contract revert (not a transport failure) is read as "real drand". The relay button stays disabled, with an explanation, until it is known. `fetchBeaconProof` rejects any signature that is not exactly 64 bytes with a user-facing message naming the length it got. |

### Still open after this pass

1. **F10** (browser clock) and the remainder of **F12** (hard-coded constants in copy) — untouched.
2. **SRI** on the Google Fonts stylesheet (F7) — not applied; see above.
3. **Liveness.** Nothing here changes the fact that no link in this app has fired against
   mainnet 4663. The wrong-chain guard is asserted by a unit test only; unknown 5 above
   (does a wrong-chain write actually land with the installed wallet?) still needs a burner
   wallet on a foreign chain before beta. The new circuit breaker, the `rank` call, the
   `claimRefund` path and the drand length check have likewise never fired in production.
4. **Unknown 1** (does the drand v2 URL return a 64-byte signature?) is now *enforced*
   client-side but still not *observed*: no request was made to `api.drand.sh` in this pass.
5. **Unknown 4** (public RPC quotas) — the read load is cut by roughly an order of magnitude
   on the chain page and the breaker bounds the failure mode, but no quota has been measured.
6. `dist/` and `src/contracts/addresses.ts` remain git-ignored and were regenerated locally
   for chain 46630; nothing was committed.
