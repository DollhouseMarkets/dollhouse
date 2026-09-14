# Solidity dependencies (pinned)

Installed with `forge install --no-git --shallow` on 2026-09-10 (Foundry 1.8.1). `--no-git`
strips each library's `.git`, so the commits below were confirmed by re-cloning each repository
into a scratch directory and byte-comparing the source trees (`diff -rq`) against `lib/`.

| Library | Path | Commit | Version |
|---|---|---|---|
| Uniswap v4-core | `lib/v4-core` | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | package 1.0.2 (`main`) |
| Uniswap v4-periphery | `lib/v4-periphery` | `dce236d4e2057422d0791d9a973a58765eb46f65` | `main` |
| forge-std | `lib/forge-std` | `7fdf81f9ceb2f6ebbb8f9f1c6c5274d5bcc9a1f5` | 1.16.2 |
| OpenZeppelin contracts | `lib/openzeppelin-contracts` | `c547cd4d007bd7d887ea56e9086611a79844727d` | 5.7.0 |

`lib/v4-periphery/lib/v4-core` (its own nested copy) and `lib/v4-core/lib/*` are pulled in by
forge; remappings point every import at the top-level `lib/v4-core`, so exactly one
`PoolManager`/`IHooks` type exists in the build.

## Notes on the pinned versions

- **No `BaseHook`.** The pinned v4-periphery no longer ships `BaseHook` (nor
  `src/utils/BaseHook.sol`); the only remaining hook scaffolding lives under
  `src/hooks/permissionedPools`. `FamilyHook` therefore implements `IHooks` directly, with its
  own `onlyPoolManager` modifier and a constructor assertion that the mined address encodes
  exactly the intended permission bits.
- **`HookMiner`** lives in `lib/v4-periphery/test/shared/HookMiner.sol` in this version (not in
  `src/`), hence the `v4-periphery/=lib/v4-periphery/` remapping and test-side import.
- **`ModifyLiquidityParams` / `SwapParams`** are top-level structs in
  `v4-core/src/types/PoolOperation.sol` in this version, not nested in `IPoolManager`.
- `via_ir = true` is required: `FamilyHook.beforeSwap` hits "stack too deep" with the legacy
  code generator.

## Cryptography: no new library dependency (MECHANISM_v3 §3)

The random end verifies drand beacons on chain. **Nothing was vendored for it.**
`contracts/randomness/BN254.sol` is written from the public specifications:

- **RFC 9380** (`hash_to_curve`): `expand_msg_xmd` with keccak256, and the Shallue–van de
  Woestijne map of §6.6.1, under the domain separation tag the beacon's own scheme name
  states — `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_`.
- **EIP-197** (BN254 pairing check, precompile `0x08`) and **EIP-196** (G1 addition, `0x06`).

Randamu's `randomness-solidity` `BLS.sol` — itself descended from the Hubble project's BN254
library — was consulted **for behaviour only** and is cited in the source header. No code from
either is reproduced, so no third-party licence attaches to this repository. The SVDW constants
are asserted against their definitions in `test/Drand.t.sol` rather than trusted, and `c3` is
derived at runtime with the modexp precompile instead of being hardcoded: a wrong constant there
would otherwise be invisible except as "nothing ever verifies".

### Precompiles this deployment now relies on

| Precompile | Used by | Status on the target chain |
|---|---|---|
| `0x02` sha256 | (not used — see below) | — |
| `0x05` modexp | `BN254.sqrt` / `isSquare` / `inv0` | Arbitrum Nitro: present |
| `0x06` ecAdd (alt_bn128) | `BN254.add`, hash-to-curve | Arbitrum Nitro: present |
| `0x08` ecPairing (alt_bn128) | `BN254.verifySingle` | Arbitrum Nitro: present. **The EIP-2537 BLS12-381 precompiles are NOT**, which is why the beacon has to be BN254 (`evmnet`) and not BLS12-381 (`quicknet`) |

### The beacon itself

drand `evmnet`, scheme `bls-bn254-unchained-on-g1`, period 3 s, genesis 1727521075, chain hash
`04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3`. Re-verified live against
`https://api.drand.sh/v2/beacons` and `.../evmnet/info` on **2026-09-11**. Its group public key
is a deploy constant of `DrandSource` and cannot be changed afterwards.

**Empirical finding, recorded because it contradicts the obvious guess:** this chain's UNCHAINED
digest of a round is `keccak256(uint64 round, big-endian)`, not `sha256` — which is consistent
with a chain built to be verified by an EVM. It was established here by verifying real beacons
(`test/Drand.t.sol` carries two of them as fixtures, fetched from the public API), not taken from
documentation.

**Trust statement.** The beacon is public, verifiable and not controlled by Dollhouse. What the
protocol trusts is that a threshold of the League of Entropy does not collude, and that somebody
relays the signature. Neither can bias a round end in Dollhouse's favour: a withheld beacon ends
the round deterministically at `T` after `END_TIMEOUT`, which is the one outcome a late buyer
could already plan for.
