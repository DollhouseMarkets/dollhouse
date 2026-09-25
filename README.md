# Dollhouse

Dollhouse is a permissionless launchpad on Robinhood Chain where every new coin trades against the
coin before it, forming one chain of linked pools that starts at $DOLL. Anyone can enter a coin in
a timed round; the coin with the highest average market cap over the round's closing window becomes
the next link in the chain, and the round's true end is settled at a random moment inside its final
three minutes by the drand public beacon. A coin that loses its round keeps trading. Trading fees
pay each pool's creator and are locked back into the chain as buy support under every coin that
came before. All liquidity the protocol places is locked forever, and no key can withdraw it or
change how the protocol behaves.

## Contracts

| Contract | What it does |
|---|---|
| `FamilyHook` | The Uniswap v4 hook behind every pool in the chain: collects fees, applies the opening snipe tax, records the score checkpoints a round is judged from, and refuses any liquidity removal. |
| `FeeVault` | The fee ledger in $DOLL: books every fee to its recipients and pays creator and developer claims. |
| `RoundManager` | Runs the rounds: opens them, escrows entry bonds in $DOLL, settles the random end, scores candidates and crowns the winner. |
| `BidDeployer` | Turns collected fees into permanently locked buy support under link one and under each crowned coin, paying the caller a small bounty. |
| `FamilyFactory` | Registers candidates, deploys their tokens and pools, and adopts $DOLL as the first coin of the chain. |
| `FamilyRouter` | Buys and sells along the chain in one transaction, paying exactly the fees a direct pool swap pays. |
| `EthZap` | Lets a trader enter or leave the chain with ETH by swapping through $DOLL's own market. |
| `Locker` | Holds every liquidity position the protocol places, forever; it has no function that removes liquidity. |
| `FamilyToken` | The fixed-supply token of each coin, minted once straight into its locked liquidity. |
| `FamilyLens` | Read-only, batched views for apps and indexers. |
| `DrandSource` | Verifies the drand beacon's signature on chain, which sets each round's random end. |

## Fees

- **1%** on the $DOLL side of every swap in a link-one pool, charged once per trade. It is split
  **40%** to the pool's creator, **40%** locked as buy-support bids under the chain, and **20%** to
  the developer.
- **0.075%** on every swap in every pool, locked as buy support under that pool's parent.

## Addresses

The mainnet contract addresses are listed in `deployments/4663.json` and on the documentation site.

## Audit record

The audit record is [`docs/security/README.md`](docs/security/README.md): every assurance method,
its result and the file that holds it. It covers formal verification with the Certora Prover
(`certora/RESULTS.md`), an automated audit with V12, 12 independent reviews, unit, property and
invariant tests, fork tests against the live Uniswap v4 `PoolManager`, symbolic checks with Halmos,
static analysis with Slither and fuzzing with Medusa.

## Build and test

```bash
./scripts/install-deps.sh   # pins lib/ to the exact commits in contracts/DEPENDENCIES.md
forge build
forge test --no-match-path 'test/fork/*'
# on a memory-constrained machine:
# FOUNDRY_THREADS=1 forge test --threads 1 --no-match-path 'test/fork/*'

# property tests, deep run
FOUNDRY_THREADS=1 FOUNDRY_FUZZ_RUNS=5000 FOUNDRY_INVARIANT_RUNS=400 FOUNDRY_INVARIANT_DEPTH=100 \
  forge test --threads 1 --match-path 'test/properties/*'
```

Fork tests (`test/fork/`) need an RPC endpoint; the command is in `docs/security/FORK_RESULTS.md`.

## Repository layout

- `contracts/`: the protocol.
- `test/`: unit, property, fork, symbolic and Medusa tests; `test/README.md` describes each group.
- `script/`: the deploy scripts (`Deploy.s.sol`, `DeployZap.s.sol`, `DeployVesting.s.sol`) and the
  artefact-key checker (`check-artefact-keys.mjs`).
- `scripts/`: `install-deps.sh` and the Medusa configuration (`security/medusa.json`).
- `docs/spec/`: the protocol specification (`PROTOCOL_SPEC.md`, `PROPERTIES.md`).
- `docs/security/`: the audit record and its tool summaries.
- `certora/`: the formal verification specs, configs and results.
- `docs/DEPLOY_CONSTANTS.md`: every deploy-time constant and its value.

## Reporting a finding

Report findings to the X account [@DollHouseMkts](https://x.com/DollHouseMkts), or through this
repository's issues. For each finding, include:

- `file:line` of the affected code.
- The scenario that triggers it: the inputs, state and sequence of calls.
- The impact: funds at risk, availability, correctness, or something else.
- A suggested fix or mitigation, if you have one.

## License

Business Source License 1.1 (`BUSL-1.1`, see `LICENSE`): source-available, non-production use
permitted, production use reserved to the licensor until the change date (2029-09-14), after which
the work converts to MIT.
