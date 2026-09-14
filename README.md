# Dollhouse — Review Package

Revision under review: `review-1` (2026-09-12). Contracts are frozen at this revision; tests and documentation may still grow.

## What this is

Dollhouse is a permissionless nested-liquidity launchpad on Robinhood Chain (id 4663), built on
Uniswap v4 hooks. Each token round runs a bidding phase followed by a randomized closing window;
winning tokens can spawn further "child" rounds nested underneath them, sharing fees back up the
chain of ancestors.

Status: **pre-audit**. The contracts have been exercised on the Robinhood testnet but are **not
deployed to mainnet**.

## Scope of review

| Contract | Role |
|---|---|
| `FamilyToken` | The ERC-20 issued per round; burnable, fixed supply per genesis. |
| `FamilyFactory` | Deploys token/pool/hook sets for a new round via minimal clones. |
| `Locker` | Holds and releases locked liquidity positions per the vesting/lock schedule. |
| `FamilyHook` | Uniswap v4 hook: fee routing, score accumulation, round-close logic. |
| `RoundManager` (+ `RoundManagerDeployer`) | Orchestrates a round's lifecycle: bidding, scoring, the random end, and handover. |
| `FeeVault` | Collects and distributes protocol/ancestor fee shares. |
| `BidDeployer` | Deploys the bid-side contracts/state for a round's entrants. |
| `FamilyRouter` | User-facing swap/bid entry point with slippage and guard checks. |
| `FamilyLens` | Read-only aggregation/view helper for off-chain consumers. |
| `DevVesting` (+ `DevVestingDeployer`) | 3% genesis developer allocation, cliff + linear vest, no clawback. |
| `DrandSource` + `BN254` library | Verifies drand `evmnet` BLS-BN254 beacon signatures on chain to source the random round-end. |

### Trust assumptions

- **Steward**: a single key, transferable only with a 7-day delay, whose powers are sunset-only
  (it can retire mechanisms, not add new ones or move funds).
- **Randomness beacon**: liveness of the drand `evmnet` network for the random end, with a
  deterministic timeout fallback if a beacon round is not delivered in time.
- **Uniswap v4 `PoolManager`**: the pools, swaps, and liquidity accounting are only as safe as the
  pinned `PoolManager` deployment (see `docs/DEPLOY_CONSTANTS.md`) and its own audited invariants.

## Where to start

1. `docs/spec/PROTOCOL_SPEC.md` — the protocol specification.
2. `docs/MECHANISM_v3.md` — the mechanism design write-up (fees, scoring, closing window, purse).
3. `docs/DEPLOY_CONSTANTS.md` — deployed addresses and constructor parameters referenced by spec.
4. `docs/spec/READINESS.md` — what has and hasn't been validated pre-audit.
5. `docs/attack-log.md` — known attack considerations and how each is mitigated or accepted.
6. `docs/reviews/` — prior internal and external review notes.
7. `docs/ASSURANCE.md` — the dated ledger of every audit, test and tool run against this protocol, with a proof link for each.

## What we most want challenged

- Fee-once accounting at the ETH edge and the hop fee (no double-charging across a chain of pools).
- The score accumulator and its checkpoint rings.
- Closing-window averaging and the random end (manipulation resistance, timeout fallback safety).
- Purse deployment (one bid, under `canonical(j)`) and the Fenwick-tree ancestor sleeve distribution.
- The token-bucket daily limit (bypass, starvation, drift).
- Continuation/handover between rounds (state carried forward correctly, no stuck funds).
- Clone initialization (front-running, re-init, uninitialized-implementation risk).
- Reentrancy around `PoolManager.unlock` and any external call inside a hook callback.
- EIP-170 contract-size boundaries for the largest contracts (`FamilyHook`, `RoundManager`).

## How to build and test

```bash
./scripts/install-deps.sh   # pins lib/ to the exact commits in docs/DEPENDENCIES.md
forge build
forge test
python -m pytest sim/tests
```

`forge test` currently reports **226 passing tests** (0 failing) across 26 test files in `test/`.
The Python
simulation suite (`sim/`) models the fee/score/purse mechanics off-chain; `sim/tests` covers the
core math (curves, CLMM behavior, reinforcement, rounds, family accounting).

## Sims

The `sim/` package and `docs/results/`, `docs/figures/`, `docs/sim-results*.md` files contain
Monte Carlo and scenario studies of the mechanism: fee flow and per-generation accounting
(`sim01`), threshold/survival calibration (`sim02`), reinforcement and route slippage (`sim03`),
capture/strategy economics (`sim04`), demand-side sensitivity (`sim05`), sell-tax sweeps
(`sim06`), external-share and route-depth robustness (`sim07`), cascade and drawdown behavior
(`sim08`–`sim09`), genesis share accounting (`sim10`), and purse/closing-window/sniper dynamics
under the current mechanism version (`sim11`–`sim13`). `docs/sim-results-v3.md` and
`docs/sim-results-final.md` summarize the latest runs; see each script under `sim/scenarios*.py`
for the scenario definitions.

## Testnet

Deployed and exercised on the Robinhood testnet; contract addresses and transaction links are
provided to reviewers separately.

## How to report findings

Use a severity scale of **Critical / High / Medium / Low / Informational**. For each finding,
include:

- `file:line` of the affected code.
- The scenario that triggers it (inputs, state, and sequence of calls).
- The impact (funds at risk, availability, correctness, etc.).
- A suggested fix or mitigation, if you have one.

Where to send findings will be provided by the maintainer separately from this package.

## License

All rights reserved; shared for review only.
