# Dollhouse: Review Package

Dollhouse is a permissionless nested-liquidity launchpad on Robinhood Chain, built as its own
Uniswap v4 hook. The first coin, $DOLL, launches on Pons V2 and is adopted once as canonical
index 0; every coin after it is bought and sold only against its parent, never against the
index-0 token directly. A timed round decides which coin becomes the next link in the chain: the
winner is whichever candidate has the highest average market cap over the round's closing
window, with the round's true end settled afterward at a random moment inside the final three
minutes, sourced from the drand public beacon. A coin that loses its round keeps trading; it is
not shut down, it simply gets no further share of the chain's fee stream. Every swap on the
$DOLL side of the first link pays a 1% edge fee, and every swap anywhere in the chain pays a
0.075% hop fee to its immediate parent; both are split 40% to the pool's creator, 20% to the
protocol, 20% to a locked buy-support position under the whole ancestor chain, and 20% back into
the pool itself. All liquidity this protocol places is locked forever; there is no way for any
key to withdraw it, and there is no admin role that can change how the protocol behaves.

## Revision under review

`review-5` (2026-09-15). Contracts are frozen at this tag; tests and documentation may still
grow around it.

Status: **pre-launch**. The contracts have been exercised on the Robinhood testnet, across eight
separate testnet runs, but are not deployed to mainnet.

## Scope of review

| Contract | Role |
|---|---|
| `FamilyToken` | Fixed-supply ERC-20 minted once, per launched coin, straight into that coin's locked liquidity curve. No owner, no minter beyond initialization. |
| `FamilyFactory` | The only contract that can create a family pool: registers a candidate, deploys its token, pre-registers the pool with the hook, and adopts $DOLL as canonical index 0 inside `wire()`, once. |
| `RoundManager` (+ its deployer) | The round state machine: opens rounds, escrows bonds in $DOLL, requests and settles the random end, scores candidates, finalizes the winner, and holds any forfeited bond that could not be delivered until it is flushed. |
| `FamilyHook` | The single Uniswap v4 hook behind every pool in the chain: collects fees, applies the snipe tax on a pool's opening seconds, keeps the score checkpoint rings a round is judged from, freezes and seals those checkpoints at a round's end, and enforces the unlock guard around every swap. |
| `FeeVault` | The protocol's fee ledger in the edge token ($DOLL): claims, cross-version forwarding on a handover, and the evidence trail proving a forward was or was not delivered. |
| `BidDeployer` | Turns the vault's ledgers into permanently locked buy-support: the link-one bid deployment and each generation's ancestor-sleeve deployment, each paying the caller a small bounty for the gas. |
| `Locker` | Holds every locked liquidity position the protocol ever places, forever. It has no function that removes liquidity or moves tokens out. |
| `FamilyRouter` | The $DOLL-only entry point for multi-hop buys and sells along the chain; not fee-privileged, it pays exactly the fees a direct pool swap would. |
| `FamilyLens` | Read-only, batched views for indexers and front ends. Holds no state and has no privileges. |
| `DrandSource` + `BN254` | Verifies the drand `evmnet` beacon's BLS signature on chain, which is what sources the round's random end. |

Out of scope for this package: the website and the keeper. The keeper is an off-chain operator
service that calls the protocol's own permissionless entrypoints; it is not part of the protocol
and holds no privilege over any outcome, and its source is not included in this package.

## Where to start

1. `docs/spec/PROTOCOL_SPEC.md`: the design reference for this revision, in full, including the
   state machine, token lifecycle, round lifecycle and candidate eligibility, each with the exact
   guard conditions in the code.
2. `docs/spec/PROPERTIES.md`: the formal property list the spec implies.
3. The contracts themselves, in this order: `FamilyFactory`, `RoundManager`, `FamilyHook`,
   `FeeVault`, `BidDeployer`.

## What has been checked

A compact summary, by method, with the file that holds each result, is in
`docs/security/README.md`. Highlights:

- **Eleven rounds of review**, including fully independent passes (a second reader working
  from the diff alone), with every finding fixed before the freeze.
- **346 unit and property tests passing, 0 failed, 1 skipped**, across 52 suites, plus
  **30 fork tests** run separately against the real Uniswap v4 `PoolManager` on testnet.
- **71 deep property and invariant tests**, 0 failed, run at 5,000 fuzz runs and a 400x100
  invariant depth across the nine property suites (`docs/security/PROPERTY_RESULTS.md`).
- **Static analysis with Slither**: every High and Medium row, and every reentrancy Low, has
  been hand-triaged to zero findings and three disclosed, accepted risks
  (`docs/security/slither-triage.md`).
- **Symbolic execution with Halmos**: 23 checks over the real `FeeVault` and `RoundManager`
  bytecode, 23 passed, 0 failed, no counterexamples (`docs/security/halmos-review-5.md`).
- **Formal verification with the Certora Prover**: `RoundManager` has 31 of 36 rules verified and
  `FamilyHook` 17 of the 21 that ran, at this revision. `FeeVault.spec` has **no verdict at all**:
  every submission against it fails inside the Prover itself while loading the scene, before any
  rule is checked, across six independently measured workarounds; that gap is why the Halmos pass
  above exists, restating the same properties as machine-checked claims over the real vault
  bytecode instead. Full detail, including the one contract finding this pass produced and its
  fix, is in `certora/RESULTS-review-5.md`, with the vault's last fully verified numbers in
  `certora/RESULTS-review-4.md`.
- **An automated audit** returned 8 genuine findings, all fixed before the freeze.
- **Eight testnet runs**, the later ones driven end to end by an always-on keeper with no person
  calling any round entrypoint, exercising registration, trading, the snipe window, the random
  end, scoring, finalization, forfeiture, bid deployment and claims live.

## How to run

```bash
./scripts/install-deps.sh   # pins lib/ to the exact commits in contracts/DEPENDENCIES.md
forge build
forge test                  # single-threaded on a memory-constrained machine:
                             # FOUNDRY_THREADS=1 forge test --threads 1 --no-match-path 'test/fork/*'

# spec-derived property tests, deep run
FOUNDRY_THREADS=1 FOUNDRY_FUZZ_RUNS=5000 FOUNDRY_INVARIANT_RUNS=400 FOUNDRY_INVARIANT_DEPTH=100 \
  forge test --threads 1 --match-path 'test/properties/*'

# fork tests against the real Uniswap v4 PoolManager (needs a testnet RPC)
RPC_TESTNET=<endpoint> forge test --match-path 'test/fork/*'

# Halmos symbolic checks
FOUNDRY_PROFILE=halmos FOUNDRY_THREADS=1 halmos --root . --forge-build-out out-halmos \
  --contract '^(FeeVaultHalmos|ForfeitHalmos)$' --loop 3 \
  --solver-timeout-assertion 120000 --solver-threads 1 --statistics --no-status
```

## Layout of this repository

- `contracts/`: the protocol.
- `test/`: unit, property and fork tests.
- `script/`: the deploy script (`Deploy.s.sol`) and its artefact-key checker
  (`check-artefact-keys.mjs`). Operator and testnet-driver scripts are not included in this
  package.
- `docs/spec/`: the protocol specification (`PROTOCOL_SPEC.md`, `PROPERTIES.md`).
- `docs/security/`: the audit record for this revision (`README.md`) and its underlying tool
  summaries (`PROPERTY_RESULTS.md`, `FORK_RESULTS.md`, `slither-triage.md`,
  `halmos-review-5.md`).
- `certora/`: the formal verification specs, configs and results (`README.md`,
  `PROPERTY_MAP.md`, `RESULTS-review-5.md`, `RESULTS-review-4.md`, `specs/`, `conf/`,
  `harness/`).
- `docs/DEPLOY_CONSTANTS.md`: a standalone reference document at the repository root of `docs/`.

## Reporting a finding

Report findings to the X account [@DollHouseMkts](https://x.com/DollHouseMkts), or through this
repository's issues once it is public. For each finding, include:

- `file:line` of the affected code.
- The scenario that triggers it: the inputs, state and sequence of calls.
- The impact: funds at risk, availability, correctness, or something else.
- A suggested fix or mitigation, if you have one.

There is no bounty program at this time.

## License

Business Source License 1.1 (see `LICENSE`): source-available, non-production use permitted,
production use reserved to the licensor until the change date (2029-09-14), after which the work
converts to MIT. Shared for review; the contracts carry `BUSL-1.1` SPDX headers.
