# Halmos symbolic review — review-1

Tool: halmos 0.3.3 (Z3), installed via `uv tool install halmos --python 3.12`.
Date: 2026-09-12. Host: 16 GB Windows 11.

## What changed since the first (inconclusive) attempt

The earlier run recorded in `TOOLING_STATUS.md` failed for two reasons, both now fixed:

1. **`[profile.halmos]`'s `skip` globs matched nothing useful.** Forge's skip matcher lets `*`
   cross a path separator, so `"contracts/*.sol"` swallowed `contracts/libraries/` too and
   `"test/*.t.sol"` swallowed `test/halmos/CurveMathCheck.t.sol`. The profile compiled **zero**
   files. The skip list is now an explicit file-by-file list (see the comment in `foundry.toml`).
2. **Halmos was reading the wrong artifact directory.** `halmos` runs `forge build` with the
   inherited environment (so `FOUNDRY_PROFILE=halmos` did produce the lean build), but it then
   parses `args.forge_build_out`, which defaults to `out` — the full **via-IR** project artifacts.
   That is what drove the ~7 GB resident compile and the Z3 access-violation crash. The fix is to
   pass **`--forge-build-out out-halmos`** explicitly. Without that flag the profile is cosmetic.

The profile also now sets `cache_path = "cache-halmos"`; sharing `cache/` with the default profile
made forge report "No files changed, compilation skipped" against an empty `out-halmos`.

## How to run

```bash
export PATH="$HOME/.local/bin:$HOME/.foundry/bin:$PATH"
export FOUNDRY_PROFILE=halmos FOUNDRY_THREADS=1
halmos --root . --forge-build-out out-halmos \
  --contract '^(CurveMathCheck|FenwickCheck)$' \
  --solver-timeout-assertion 120000 --solver-threads 1 --statistics --no-status
```

## Results

All figures from the run above (`--solver-timeout-assertion 120000`, one solver thread).

| check | property IDs | result | solver time | notes |
|---|---|---|---|---|
| `CurveMathCheck.check_floorToSpacingProd(int24)` | CRV floor-to-spacing (prod config) | **PASS** | 9.84 s (21 paths) | `tickSpacing = 60` = `FamilyFactory.TICK_SPACING`; tick over the whole v4 range incl. negatives |
| `CurveMathCheck.check_floorToSpacingOne(int24)` | CRV floor-to-spacing | **PASS** | 0.04 s (5 paths) | degenerate spacing 1 |
| `CurveMathCheck.check_floorToSpacingTen(int24)` | CRV floor-to-spacing | **PASS** | 6.18 s (21 paths) | |
| `CurveMathCheck.check_floorToSpacingTwoHundred(int24)` | CRV floor-to-spacing | **PASS** | 8.59 s (21 paths) | widest standard v4 spacing |
| `CurveMathCheck.check_sqrtPriceNeverOutOfRange(uint256)` | CRV sqrt-price range guard | **PASS** | 30.68 s (928 paths) | `sqrtPriceAtFdv` either reverts or returns `>= TickMath.MIN_SQRT_PRICE`; no silent out-of-range return |
| `FenwickCheck.check_rangeAddMatchesClosedForm(int256,int256,int256)` | SLV-04 | **PASS** | 3.60 s (37 paths) | `M = 8`, symbolic `c0,c1,c2`; also asserts indices `M+1`, `M+2` stay 0 |
| `FenwickCheck.check_rangeAddIsAdditive(int256,...)` | SLV-04 | **PASS** | 13.24 s (182 paths) | two overlapping range-adds superpose exactly |
| `FenwickCheck.check_noCreditOutsideRange(int256,int256,int256)` | SLV-02 | **PASS** | 1.70 s (16 paths) | range-add over `[3,5]`; indices 0,1,2,6,7,4095 all exactly 0 |
| `FenwickCheck.check_sleeveShapeNonNegative(uint256)` | SLV-01 (wei granularity) | **PASS** | 1.22 s (13 paths) | `addSleeve`'s own coefficient expressions for `M = 8`, symbolic `aWad <= 1e40`; every `query(j) >= 0` |

Total: **9 passed, 0 failed, 77.7 s wall** (build 2.5 s, load 0.03 s, solving 75.1 s).

**No counterexamples.** `test/halmos/Repro.t.sol` was therefore not created.

### TIMEOUT — kept in `test/halmos/CurveMathSlowCheck.t.sol`, excluded from the default run

| check | property IDs | result | solver time | why |
|---|---|---|---|---|
| `check_floorToSpacingAnySpacing(int24,int24)` | CRV floor-to-spacing, any spacing | **TIMEOUT** | 270.8 s of solver time over 23 paths, at `--solver-timeout-assertion 30000` | 256-bit `sdiv`/`smod` by a **symbolic** divisor. Concretising `tickSpacing` is what turns this from 270 s-and-unknown into 10 s-and-PASS, which is why the shipped checks pin the spacing. |
| `check_fdvRoundTrip(uint256)` | CRV FDV round-trip | **TIMEOUT** | no verdict in 10 min wall clock (killed), even with supply concrete at `1e27` and `fdv` bounded to `[1e15, 1e24]` | `FullMath.mulDiv` (512-bit mulmod + modular inverse) composed three deep with OpenZeppelin `Math.sqrt` (unrolled Newton iteration). The *forward* half alone (`check_sqrtPriceNeverOutOfRange`) is 928 paths / 31 s; adding the two inverse `mulDiv`s is past Z3's reach here. `--loop 4` did not help (the loops are already concretely unrolled). |

### Out of scope — not pure library math

Items 3 and 4 of the review brief were **not attempted**, for a structural reason:

- **Round schedule** — `D(n)`, `lateEntryUntil(n)` and `bondFor(n)` are `public view` functions on
  `RoundManager` reading immutables (`BASE_TRADING_S`, `MAX_TRADING_S`, `BOND_BASE_WEI`,
  `BOND_DOUBLING_EVERY`, `BOND_MAX_WEI`), not a pure library. Reaching them symbolically means
  deploying `RoundManager`, which is exactly the heavy contract the lean profile skips.
- **Snipe tax** — `_snipeTaxPpm(uint64)` is an `internal view` function on `FamilyHook`, reading
  the hook's own state. Same problem.

Covering these with Halmos would need a purpose-built pure-library extraction of the schedule
math, which would be a `contracts/` change and is out of scope for this review.

## Caveats

- **`via_ir = false`.** The `[profile.halmos]` build uses the legacy codegen pipeline, while the
  shipped bytecode is compiled **via-IR**. These checks therefore establish the **semantics of the
  library-level math**, not properties of the exact deployed bytecode. Solidity's two pipelines
  agree on integer semantics, but an IR-specific codegen bug would not be caught here. The fuzz,
  invariant and fork suites all run against the via-IR build and remain the authority on the
  shipped artifact.
- **Bounded, not universal.** Fenwick checks are bounded to `M <= 8` and coefficient magnitude
  `1e40`; generation indices are concrete. Tick spacings are concrete. FDV is bounded to
  `[1e15, 1e24]`.
- **`check_sleeveShapeNonNegative` re-states `addSleeve`'s coefficient expressions** rather than
  calling `addSleeve`, because `FullMath.mulDiv` is not symbolically tractable. The expressions are
  copied exactly; `aWad` is treated as an unconstrained input, which is a *superset* of the values
  `mulDiv(sleeve * WAD, 6M, (M+1)(5M+4))` can actually produce. A counterexample from this check
  would have needed a realisability cross-check — there was none.
- SLV-03 (sum of point queries `<=` sleeve) is **not** covered here: it needs the real `addSleeve`
  and therefore `FullMath`. It stays on the fuzz/invariant/Certora side.

## Memory

The whole point of the lean profile is that this now runs nowhere near the memory ceiling.

| phase | observation |
|---|---|
| `FOUNDRY_PROFILE=halmos forge build --force` | 14 source units (3 project libraries + `contracts/types` + v4-core/OZ math deps), **~2 s**. Free physical RAM never dipped below **4.24 GB** — no measurable dip against the ~4.3 GB idle baseline. |
| Halmos run (9 checks, 78 s) | minimum free physical RAM observed **9.39 GB**. No solver crash, no hang on teardown. |
| *(previous attempt, for contrast)* | full via-IR project compile, ~490 s, ~7 GB resident, free RAM into the low hundreds of MB, Z3 subprocess access violation. |

Sampling method: PowerShell loop reading `(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory`
every 5 s for the duration of each command; every command ran under the shared
`$TEMP/dollhouse-forge.lock` with `timeout` and `FOUNDRY_THREADS=1`.
