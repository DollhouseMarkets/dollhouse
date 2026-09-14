# Pons V2, Uniswap v4 oracles/hooks, Robinhood Chain — Dossier (research, 2026-09-10)

## PART A — Pons V2 (docs.ponsfamily.com/v2)
- **V** Robinhood Chain 4663 only; v2 contracts shipped 3 Aug 2026.
- **V** Constant-product quote `amountOut = inAmount*reserveOut/(reserveIn+inAmount)`; phantom quote reserve is virtual and never withdrawable.
- **V** `reserved = supply × phantomQuote ÷ (phantomQuote + threshold)`; default threshold **4.2 ETH**; supply 1e9 minted entirely to curve. **U** 1.68 ETH phantom (only found on pez.family sibling docs) → 28.57% reserved if true.
- **V** Graduation = permanently locked full-range Uniswap v4 position; nobody can pull it; two-step automated migration anyone can push.
- **V** Fees charged in the pricing asset, never in the launch token. Snipe tax 99% → 0 exponentially over first 5 s (~25% at 1 s, ~3% at 2 s).
- **V** Pair assets: only assets Pons approved (owner-gated). Economics per asset (phantom reserve in quote-asset units). Reported approved: USDG, NVDA, AAPL, HOOD (press).
- **V** Fee: standard trading fee shared pons/creator/buyback + optional creator tax fixed at launch (capped). Same rate on-curve and post-graduation. `feeBps`, `creatorTaxBps`. Secondary: 1% fee, 70/30 creator/protocol; launch fee 0.0005 ETH; 80% of protocol fees → PONS TWAP buyback+burn.
- **V** Pull-based FeeEscrow: `balanceOf(recipient)`, `balanceOfToken(recipient, token)`; `transferCreatorFeeRecipient(token, newRecipient)` does not move credited balances. Escrow 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e. Buyback vault 5-year vesting 0x42df2a798f82289E177311362e8f5ccC45c1219c.
- **V** Immutable: supply, pricing, pairing asset, tax cannot be raised.
- **V** Repo https://github.com/ponsdotdev/ponsfamily (`contractsV2/`: PonsV2LaunchFactory, PonsV2BondingCurve, PonsV2LauncherToken, PonsV2MemeHook, PonsV2BuybackVault). Factory 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e; Meme Hook 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044; Launch Locker 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952; V1 factory 0xA5aAb3F0c6EeadF30Ef1D3Eb997108E976351feB.
- **V** v4 pool `fee = 0`; hook charges the fee on the unspecified currency of the swap and records it against the pool.
- **V** Audits in progress (SB Security, Dingbats, Pashov), none closed: "Treat v2 as unaudited." Public launches closed: `canLaunch(address)`. "There is no pons API in the trust path."
- **V** "Reaching graduation is not a signal of quality. It only means the curve sold out."

## PART B — Uniswap v4 price observation / hooks
- **V** v4 core has no built-in oracle. Reference: `TruncGeoOracle.sol` + `TruncatedOracle.sol` (v4-periphery `trunc-oracle` branch); `GeomeanOracle.sol` (`example-contracts` branch). v3-style ring buffer (65535), ticks stored, `MAX_ABS_TICK_MOVE = 9116` per block (~2.49× cap); pools must be full-range with locked liquidity.
- **V** 14 permission flags in last 14 address bits; `BEFORE_INITIALIZE=1<<13`, `AFTER_INITIALIZE=1<<12`, `BEFORE_SWAP=1<<7` confirmed; the rest (afterSwap 6, beforeDonate 5, afterDonate 4, beforeSwapReturnDelta 3, afterSwapReturnDelta 2, afterAddLiquidityReturnDelta 1, afterRemoveLiquidityReturnDelta 0; beforeAddLiquidity 11, afterAddLiquidity 10, beforeRemoveLiquidity 9, afterRemoveLiquidity 8) to confirm from `Hooks.sol`.
- **V** Return-delta flags require their action flag. `DYNAMIC_FEE_FLAG` set at pool creation; `updateDynamicLPFee` or `OVERRIDE_FEE_FLAG` in beforeSwap return.
- **V** Inside a hook `msg.sender` = PoolManager; `sender` param = caller of `PoolManager.swap()` (router), not the EOA; `IMsgSender(sender).msgSender()` only if router implements it. `hookData` is caller-supplied → untrusted.
- **V** Fees on input via `beforeSwap`+`beforeSwapReturnDelta` (BeforeSwapDelta); on output via `afterSwap`+`afterSwapReturnDelta`. LP fee vs protocol fee (PoolManager owner, capped) vs hook fee (return deltas).

## PART C — Robinhood Chain
- **V** Mainnet chain ID **4663** (0x1237), testnet **46630**; mainnet live 1 Jul 2026; Arbitrum Orbit/Nitro, blob DA, FCFS sequencing, ERC-4337 first-class; gas token ETH.
- **V** RPC https://rpc.mainnet.chain.robinhood.com, https://rpc.testnet.chain.robinhood.com; Alchemy https://robinhood-mainnet.g.alchemy.com/v2/{KEY}; sequencer https://sequencer.mainnet.chain.robinhood.com; feed wss://feed.mainnet.chain.robinhood.com.
- **V** Explorers: https://robinhoodchain.blockscout.com (Cloudflare-gated for scripts); testnet https://explorer.testnet.chain.robinhood.com; https://hoodscan.pro.
- Block time ~100 ms (secondary; Orbit default 250 ms).
- **V** L1: Rollup 0x23A19d23e89166adedbDcB432518AB01e4272D94, SequencerInbox 0xBd0D173EEb87D57A09521c24388a12789F33ba96, Bridge 0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3; L2 Multicall 0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1.
- **V** Uniswap v2/v3/v4/UniswapX live since 2 Jul 2026 (v4 addresses in 01-doppler.md). Native venues: Rialto, Lighter; RFQ via 0x/1inch Fusion/LiFi.
- **V** Stock Tokens: ERC-20, 18 dec, **ERC-8056 `uiMultiplier`** corporate-action scaling (`balanceOfUI`, `UIMultiplierUpdated`); Chainlink feeds; no on-chain transfer allowlist found (jurisdictional restrictions app-layer). Unsuitable as raw-unit numeraire.
- **V** Launchpads on 4663: Pons (~60% volume), Long.xyz (~25%), PAIR, Bankr, Pools.trade (Uniswap Labs, 0.25% fee compounding into locked liquidity), hood.fun, Bags, Flap; Noxa halted 11–13 Jul 2026. Daily launchpad volume >$600M (CoinDesk Research, Sept 2026, secondary).
