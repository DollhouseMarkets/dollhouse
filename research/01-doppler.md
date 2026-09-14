# Doppler Protocol — Architecture Dossier (research, 2026-09-10)

Tags: **V** = VERIFIED (seen in source/docs/deployment file), **U** = UNVERIFIED.

## 1. Repo & docs
- **V** Core contracts: https://github.com/whetstoneresearch/doppler — BUSL-1.1, Foundry, default branch `main`.
- **V** Latest commit on `main` seen: `5754c7ee01f1bdbd6f07c62be721e1223b725ecd`, 26 Aug 2026 ("Merge pull request #548 … zodomo/rehype-integrator").
- **V** Releases page lists only v1.3.0, v1.1.0, v1.0.0 — tags lag `main` significantly.
- **V** Docs: https://docs.doppler.lol (index https://docs.doppler.lol/llms.txt).
- **Naming correction (V):** there is no `UniswapV4MulticurveInitializer.sol` on `main`. `src/initializers/` contains `Doppler.sol`, `DopplerHookInitializer.sol`, `LockableUniswapV3Initializer.sol`, `UniswapV4Initializer.sol`. Multicurve lives in `DopplerHookInitializer` (+ `RehypeDopplerHookInitializer`), backed by `src/libraries/Multicurve.sol`.

## 2. Multicurve initializer (`DopplerHookInitializer`)
- **V** Inherits `ImmutableAirlock, BaseHook, MiniV4Manager, FeesManager, IPoolInitializer` — **the initializer is itself the Uniswap v4 hook** for the pools it creates.
- **V** `InitData { uint24 fee; int24 tickSpacing; int24 farTick; Curve[] curves; BeneficiaryData[] beneficiaries; address dopplerHook; bytes onInitializationDopplerHookCalldata; bytes graduationDopplerHookCalldata; }`
- **V** `Curve { int24 tickLower; int24 tickUpper; uint16 numPositions; uint256 shares; }` — `curveSupply = numTokensToSell * shares / WAD`, split evenly across `numPositions` positions across `[tickLower, tickUpper]`. Shares must sum to exactly 1e18. Curves contiguous; tail curve recommended.
- **V** Hook permissions: beforeInitialize, afterAddLiquidity, afterRemoveLiquidity, afterSwap, afterSwapReturnDelta only.
- **V** `PoolStatus { Uninitialized, Initialized, Locked, Graduated, Exited }`. Non-empty `beneficiaries[]` → `Locked` at init; locked pools cannot be exited/migrated normally.
- **V** The initializer contract holds the v4 positions; beneficiaries only pull fees.
- **V** `NoOpMigrator.migrate()` always reverts `CannotMigrate()`; noOp supported for Multicurve/Lockable V3 only. A Multicurve launch can stay in its v4 pool permanently.

## 3. Custom numeraire
- **V** `Airlock.create()` takes `address numeraire` with no whitelist and no validation. Initializer performs no fee-on-transfer check.

## 4. Hooks & Airlock module system
- Two layers: (a) v4 hooks shipped by Doppler (`Doppler.sol` dutch auction; `DopplerHookInitializer`; `RehypeDopplerHookInitializer`); (b) "Doppler Hooks" (dhooks): `onInitialization/onSwap/onGraduation`, flags in `BaseDopplerHookInitializer`, `onlyInitializer` guard; shipped `SwapRestrictorDopplerHook`.
- **V Third-party custom v4 hook with Multicurve: NOT possible.** Pool hook address is the initializer. `dopplerHook` must be enabled via `setDopplerHookState()` guarded by `msg.sender == airlock.owner()`. Docs: "Doppler Hooks are approved by the protocol multisig."
- **V** Airlock `ModuleState { NotWhitelisted, TokenFactory, GovernanceFactory, PoolInitializer, LiquidityMigrator }`; `setModuleState` onlyOwner; `create()` validates all four modules. Owner capabilities — whitelist modules, `collectProtocolFees`, enable dhooks, mandatory ≥5% fee beneficiary.

## 5. Token template (`DopplerERC20V1`)
- **V** ERC-1167 clone; `initialize()` with vesting/beneficiaries/balance limits. No owner `mint()`, no inflation. No blacklist, but `maxBalanceLimit` and `lockPool/unlockPool` (owner can block transfers to a pool). `burn()` open. Ownable (renounceable).
- **U** 100% supply to curve structurally reachable (zero premint/vesting, `numTokensToSell == initialSupply`).

## 6. Governance
- **V** `NoOpGovernanceFactory.create()` pure, returns `(0xdead, 0xdead)`. Default on supported chains.

## 7. Deployments — Robinhood Chain 4663 (`deployments/4663.md`, commit `bda077cf`, 30 Jun 2026)
| Contract | Address |
|---|---|
| Airlock | 0xeb7c034704ef8dcd2d32324c1545f62fb4ad0862 |
| DopplerHookInitializer (multicurve) | 0x4e3468951d49f2eea976ed0d6e75ffcb44a9a544 |
| RehypeDopplerHookInitializer (17 Aug 2026) | 0x5f9eb5f6726fe88d5e39867967f5b833d2fa3215 |
| UniswapV4Initializer | 0x6cce158b6d1747617fc218592b4d60b239b957ea |
| LockableUniswapV3Initializer | 0xde8886a0019ea060b8378ee37b8a23b8117f29a3 |
| DopplerERC20V1Factory | 0x1b37d3a72082029c44b35b604ea473617580b69a |
| DopplerERC20V1 (impl) | 0x3be8b97fd0e713b5abe0649fa830223b6b4bc599 |
| NoOpGovernanceFactory | 0x85f37f74ef2478a770318bc810177a9835911ad7 |
| GovernanceFactory / TimelockFactory | 0xdeb0447dae3eb177c4dba8bbccca25c8f273b7ef / 0x6076fddfcac0dd980e0350dff5239fec3f86c578 |
| NoOpMigrator | 0xba2f330edb16cd8056f5988d8ce19bbc63475a0e |
| StreamableFeesLockerV2 | 0x7b6147ac3f615bdb764e7ebd5f517dac1ad163b8 |
| SwapRestrictorDopplerHook | 0xc16c826f75338a5ea626f94f8992191b4ce5aba2 |
| Bundler | 0xf45588e8e0b1df9db9ae7e20ece5726ae931357c |
| Quoter | 0xce6cd4e35447e05a39a50a4bcf61f2dcd93a8f0d |

Uniswap v4 on 4663: PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951, PositionManager 0x58daec3116aae6d93017baaea7749052e8a04fa7, Quoter 0x8dc178efb8111bb0973dd9d722ebeff267c98f94, StateView 0xf3334192d15450cdd385c8b70e03f9a6bd9e673b, PositionDescriptor 0x9639443158e8c5efa35bd45287bf2effd3d8dc06, Universal Router 0x8876789976decbfcbbbe364623c63652db8c0904, Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3.

## 8. Fee model
- **V** Airlock protocol fee: 5% of trading fees or 0.1% of proceeds, capped at 20% of trading fees.
- **V** `BeneficiaryData { address beneficiary; uint96 shares; }`, ascending addresses, sum to 1e18, protocol owner ≥ `WAD/20` (5%) when enforced.
- **V** Pull-based streaming via `FeesManager`; `updateBeneficiary`. Rehype: 8-way `FeeDistributionInfo`; immutable `integratorFeeShare`.

## 9. Audits
- **V** OpenZeppelin (Nov 2024), Certora (Nov 2024), Cantina contest; bounty on Cantina. **Audits predate `DopplerHookInitializer`/rehype code (2026).** No post-mortems found.

## 10. Price observation
- **V** No oracle/TWAP in Doppler. `Doppler.sol` tracks `tickAccumulator` (adjustments, not TWAP). Rehype prices via Quoter simulation. On-chain TWAP would require a multisig-approved dhook or a new whitelisted initializer.

## Conclusion for this project
Deployed Doppler cannot host: sender-aware fee-once (needs beforeSwap), synchronized start gate, on-chain scoring. It adds a permanent ≥5% owner cut and a multisig dependency. Use as **reference design only**.
