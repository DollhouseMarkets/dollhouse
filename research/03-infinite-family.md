# Infinite Family — Adversarial Review (on-chain reads 2026-09-10 21:55–22:02 UTC, RPC rpc.mainnet.chain.robinhood.com)

Protocol was hours old at observation (genesis pool created 2026-09-10 19:57 UTC).

## 1. Chain and genesis
- **V** Robinhood Chain 4663. Genesis `0xEB4CF9052f917f72E3b8473B3Bdca3e24Be39fd8` "Infinite Family" (INFINITE), totalSupply 1e9.
- **V** Primary pool `0x5abf8697b055dedd160f5937686fdf4d19f89c8cf5a076ddd6145939e70182a6` (Uniswap v4), quote **USDG** `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`; priceUsd 0.00001204, liquidity $8,918.78, FDV $11,687, vol h24 $1,559,099, 6,415 buys/6,104 sells, h1 −87.6%, h24 −69.95%; created 20:05:44 UTC.
- **V** 13 pools listed on DexScreener for genesis; several decoys priced 20×+ higher with <$2k liquidity. Impostor "INFINITE" tokens on Solana/BSC/Base.

## 2. Protocol's own description (infinitefamily.fun)
- Every launch pooled with the launch before it: `USDG ← GENESIS ← #1 ← #2 …`; only the current head may be the numeraire; concurrent launches revert `StaleHead`.
- Supply 1e9, 100% to pool, no team allocation. Curve: $5,000 → $5,000,000 market cap, 99.1% main + 0.9% tail (`{supply:1e9, startMcapUsd:5e3, endMcapUsd:5e6, tickSpacing:8, minTick:-887264, tailTickUpper:887264}`).
- Fees: 1% per swap per pool; 80% → 1% over first 10 s (anti-snipe); 0.95% Flywheel / 0.05% Doppler; "no creator cut, no platform cut". Flywheel converts fees down-chain into genesis and locks; "no withdraw function". Launch cost gas only.

## 3. Contracts, admin, head control
| Role | Address |
|---|---|
| Pad / registry | 0x4f68964b51ed6728ccf3a465e8c576e5cc52d98c |
| Flywheel | 0x6f9b991fa4060b79b0634f3ea03783e9ec91987a |
| Doppler Airlock / tokenFactory / poolInitializer / migrator / governanceFactory | 0xeb7C0347…0862 / 0x1B37D3a7…b69a / 0x4e346895…a544 / 0xba2F330E…5A0e / 0x85f37f74…1aD7 |
| rehypeHook | 0x5F9eB5f6…3215 |
| Uniswap v4 PoolManager | 0x8366a39c…0951 |
| pons.family pool hook | 0xE5e70264…e044 |
| PONS token | 0x39dBED3a2bd333467115dE45665cC57F813C4571 |

- **V** Pad live state: `owner()` = 0x61c3b809faa26cc5526a6f6353dc7d0475259ef2 (Ownable2Step, no timelock); `launchSigner()` = 0xd75142ce5476be7d285ea1163b2d50a9ad8bd824; `launchesOpen()` true; `ownerOnlyGenesis()` false; `launchFee()` 0; `padLpShare()` 0; `launchCount()` 9; `currentNumeraire()` = PONZICHAN; `integrator()` = owner.
- **V "Anyone can launch" is false:** `launch(name, symbol, tokenURI, tickLower, tickUpper, expectedNumeraire, nonce, deadline, signature)` with `BadSignature`/`Expired` → requires off-chain signature from `launchSigner` (rotatable via `setLaunchSigner`). Owner has full kill switch (`setLaunchesOpen`, `setOwnerOnlyGenesis`).
- **V** Owner monetization dials: `setLaunchFee` (FeeTooHigh), `setPadLpShare` (ShareTooHigh), `setIntegrator`, `withdrawFees`. All 0 today, no timelock.
- **V** Head pointer advances only via `launch()` → effectively controlled by `launchSigner`. Current head PONZICHAN launched by the `owner` address.
- **V** Links #1–#9: Airlock `getAssetData` shows dead timelock/governance/migrationPool, NoOpMigrator → LP genuinely non-withdrawable. **Genesis is outside Doppler** (`getAssetData` all zeros) → genesis lock UNVERIFIED.
- Source code unverifiable (explorer behind Cloudflare). No proxy pattern detected (selector scan).

## 4. Fee structure
- **V** Chain pools are v4 dynamic-fee pools (`fee = 0x800000`) with the Doppler initializer as hook.
- **V** Undisclosed ~4% entry toll: site quoting code computes `pons.family ~4% + 1% × N chain pools`; ETH → PONS → genesis → chain. Buying link #9 from ETH ≈ 13% one way.
- Flywheel sells fees down-chain into genesis (sell pressure on every intermediate link); no per-parent fee share.
- **V** Flywheel: `genesis()`, `keeper()` = 0x0, `locked()` = 2,422,224.69 (0.242% supply), `pad()`, `router()`, `setKeeper(address)`, two unidentified selectors (0x8008e7e8, 0xcd7033c4). No withdraw selector matched.

## 5. Chain roster (allLaunches, 9 links)
0 INFINITE (genesis, USDG) 0xEB4CF905…9fd8 · 1 IMG 0x541144F4…102f · 2 JERK 0x79612604…68c9 · 3 INFINITY 0x4cc0a3cF…6914 · 4 NOTHING 0xAe536d52…Ca7f · 5 HIGHER 0xda3b2902…B493 · 6 PEPE 0xe7AEc389…8d08 · 7 CAT 0xC026BFE7…0E88 · 8 MATHSHIT 0x2b40aa45…1a2f · 9 PONZICHAN (head) 0x2da3716e…3703.
- **V Chain dead below #1**: IMG/INFINITE liq $543.95; INFINITY/JERK, NOTHING/HIGHER, HIGHER/PEPE, CAT/PEPE: liquidity null, vol $0; MATHSHIT and PONZICHAN not indexed. ETH-quoted side pools exist (IMG/ETH $7.70) bypassing the chain.

## 6. Social — could not fetch @InfinitefamilyX (402/403). No incidents reported (project ~2 h old).

## 7. Doppler wiring — **V** Airlock records for #1–#9 with poolInitializer 0x4e346895…a544; Airlock owner 0x21e2ce70511e4fe542a97708e89520471daa7a66 (third-party admin key above every family pool).

## Top adversarial findings
1. Permissioned launches presented as permissionless (launchSigner).
2. Undisclosed ~4% PONS entry toll.
3. Owner economic dials despite "no platform cut"; integrator = owner.
4. Genesis not launched through Doppler; lock unverified.
5. Chain integrity broken at depth 9.
6. No verifiable source.

## §41 mapping (brief) — answers
1 head=`currentNumeraire()`; 2 signature-gated; 3 yes (`expectedNumeraire`); 4 `StaleHead`; 5 no on-chain parent price (USD curve placement done off-chain); 6–8 5k→5M USD, 99.1%+0.9% tail, tickSpacing 8; 9–10 1%/pool/hop + 4% PONS toll; 11–12 Flywheel sells down-chain, `setKeeper`; 13–14 unknown slippage, keeper sandwichable in principle; 15 owner dials above; 16 no migration; 17 Doppler initializer holds LP; 18 head only; 19 80%→1% over 10 s; 20 broken at depth 9.
Keep: 1e9/100% curve; head+expectedNumeraire+StaleHead; NoOp migration. Replace: per-hop fee, signature gate, owner dials, free succession, USD curve placement, genesis-only flywheel.
