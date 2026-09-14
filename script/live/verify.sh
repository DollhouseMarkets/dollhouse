#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# verify.sh - submit every contract of one deployment to Blockscout, with the constructor args
# it was really built with.
#
#   ./script/live/verify.sh deployments/46630.run3-v1.json [<factory creation tx hash>]
#
# Two things make this less than a one-liner, and both cost a live run hours when rediscovered:
#
#  1. `--guess-constructor-args` REFUSES a contract created by a contract ("Fetching of
#     constructor arguments is not supported for contracts created by contracts"), which is
#     Locker, FamilyHook and RoundManager here. Their args are hand-encoded below from the
#     deployment record - every value in them is a deploy constant that the record already keeps.
#  1b. THE TOKEN IMPLEMENTATION IS NOW THE FIRST CONTRACT OF THE CHAIN (deployer nonce n+0, before
#     the factory). It is submitted first below; the candidate tokens are 1167 clones of it and
#     Blockscout answers them with `verified_twin_address_hash` against it.
#  1d. RUN 6 (mechanism v3) ADDS TWO MORE: the `RoundManagerDeployer` at deployer nonce n+2 (the
#     adaptive schedule and the random end pushed the factory's own deployment transaction over
#     the EIP-3860 limit, so the RoundManager is CREATEd by a helper) and the `DrandSource` the
#     random end reads. The RoundManager's constructor gained the `EndRandomness` tuple
#     (source, endTimeout, durationScaleDiv) and is encoded with it below. `BN254` is a library of
#     INTERNAL functions only: it is inlined into `DrandSource` and has no address of its own, so
#     there is nothing to submit for it.
#  1c. RUN 5 ADDED TWO MORE (eleven in total): the `DevVestingDeployer` at deployer nonce n+1, and
#     the `DevVesting` it CREATEd inside the genesis transaction. DevVesting is created by a
#     contract, so its five constructor args are hand-encoded here - four of them are read back
#     off the vesting contract itself (`start`/`cliff`/`duration`/`beneficiary`), which is the
#     only source that cannot drift from what was really deployed.
#  2. The FACTORY's own args contain the mined hook salt and the curve spec, which the record does
#     NOT keep. They are recovered instead from the creation transaction's calldata: everything
#     after the compiled creation code IS the ABI-encoded constructor tail. Pass the factory's
#     deploy tx hash as the second argument (or set FACTORY_TX) to use that path; without it the
#     factory is submitted with no args and will simply fail, loudly.
#
# This chain's verifier queue takes minutes on a via_ir build and the default `--watch` gives up
# first, so every submission polls with `--retries 80 --delay 20` (~27 min per contract). The
# queue is also SHARED: submitting all eight at once makes each of them slower.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

JSON="${1:?usage: verify.sh <deployments/<chain>.json> [<factory creation tx>]}"
FACTORY_TX="${2:-${FACTORY_TX:-}}"
CHAIN_ID=$(jq -r .chainId "$JSON")
VERIFIER_URL="https://explorer.testnet.chain.robinhood.com/api/"
RPC="${RPC_TESTNET}"

j() { jq -r "$1" "$JSON"; }
POOL_MANAGER=$(j .poolManager); FACTORY=$(j .factory); HOOK=$(j .hook); LOCKER=$(j .locker)
ROUND_MANAGER=$(j .roundManager); FEE_VAULT=$(j .feeVault); BID_DEPLOYER=$(j .bidDeployer)
ROUTER=$(j .router); LENS=$(j .lens); TOKEN_IMPL=$(j .tokenImplementation)
VESTING=$(j .devVesting); VESTING_DEPLOYER=$(j .devVestingDeployer); GENESIS=$(j .genesisToken)
DEVELOPER=$(j .developer); STEWARD=$(j .steward); PRIOR=$(j .continuesFrom)
HOP_FEE=$(j .constants.hopFeePpm); H_FRAC=$(j .constants.hFracWad); H_MIN=$(j .constants.hMinFracWad)
BOND_BASE=$(j .constants.bondBaseWei); BOND_EVERY=$(j .constants.bondDoublingEvery)
BOND_MAX=$(j .constants.bondMaxWei); MAX_INDEX=$(j .constants.maxIndex)
SUNSET_DELAY=$(j .constants.sunsetDelayS); MIN_BOUNTY=$(j .constants.minBountyWei)
RM_DEPLOYER=$(j '.roundManagerDeployer // empty'); RANDOMNESS=$(j '.randomnessSource // .constants.randomnessSource')
END_TIMEOUT=$(j .constants.endTimeoutS); SCALE_DIV=$(j .constants.durationScaleDiv)
# drand `evmnet` group key, the four words in the order the API serves them (docs/DEPLOY_CONSTANTS.md;
# identical to script/Deploy.s.sol, which is what the live source was built from).
DRAND_PK='[0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382,0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6,0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b]'
CREATOR_BPS=$(j .constants.creatorBps); ANCESTOR_BPS=$(j .constants.ancestorBps)
REINFORCE_BPS=$(j .constants.reinforceBps)

V() { # V <address> <path:Contract> <abi-encoded-args-or-empty>
  local addr="$1" target="$2" args="${3:-}"
  echo "== $target @ $addr"
  set +e
  forge verify-contract --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" \
    --watch --retries 80 --delay 20 ${args:+--constructor-args "$args"} "$addr" "$target" 2>&1 | tail -6
  set -e
}

enc() { cast abi-encode "$@"; }

# ---- the factory: constructor tail recovered from its creation calldata -----------------------
FACTORY_ARGS=""
if [ -n "$FACTORY_TX" ]; then
  # both strings run to ~50 kB, which is past this platform's argv limit: hand them over as FILES
  TMPD=$(mktemp -d)
  cast tx "$FACTORY_TX" input --rpc-url "$RPC" > "$TMPD/input.hex"
  jq -r '.bytecode.object' out/FamilyFactory.sol/FamilyFactory.json > "$TMPD/code.hex"
  FACTORY_ARGS=$(python -c "
import sys
inp = open(sys.argv[1]).read().strip()[2:]
code = open(sys.argv[2]).read().strip()[2:]
assert inp.startswith(code), 'creation code does not prefix the deploy calldata: wrong build or wrong tx'
print('0x' + inp[len(code):])
" "$TMPD/input.hex" "$TMPD/code.hex")
  rm -rf "$TMPD"
fi

# The token IMPLEMENTATION (deployer nonce n+0): every family token is an EIP-1167 clone of it,
# so verifying it is what gives every candidate token a verified twin. Its only constructor arg is
# the factory's PREDICTED address, which is the factory address in the record.
V "$TOKEN_IMPL" "contracts/FamilyToken.sol:FamilyToken" "$(enc 'constructor(address)' "$FACTORY")"
# The developer allocation half (run 5). The DEPLOYER takes no constructor args at all; the
# DevVesting it created at genesis takes five, read back from the contract so they cannot drift.
VERIFY_ADDRS="$TOKEN_IMPL"
if [ "$VESTING_DEPLOYER" != "null" ] && [ "$VESTING_DEPLOYER" != "0x0000000000000000000000000000000000000000" ]; then
  V "$VESTING_DEPLOYER" "contracts/DevVesting.sol:DevVestingDeployer" ""
  VERIFY_ADDRS="$VERIFY_ADDRS $VESTING_DEPLOYER"
fi
if [ "$VESTING" != "null" ] && [ "$VESTING" != "0x0000000000000000000000000000000000000000" ]; then
  V_BEN=$(cast call --rpc-url "$RPC" "$VESTING" 'beneficiary()(address)' | awk '{print $1}')
  V_START=$(cast call --rpc-url "$RPC" "$VESTING" 'start()(uint64)' | awk '{print $1}')
  V_CLIFF=$(cast call --rpc-url "$RPC" "$VESTING" 'cliff()(uint64)' | awk '{print $1}')
  V_DUR=$(cast call --rpc-url "$RPC" "$VESTING" 'duration()(uint64)' | awk '{print $1}')
  V "$VESTING" "contracts/DevVesting.sol:DevVesting"     "$(enc 'constructor(address,address,uint64,uint64,uint64)' "$GENESIS" "$V_BEN" "$V_START" "$V_CLIFF" "$V_DUR")"
  VERIFY_ADDRS="$VERIFY_ADDRS $VESTING"
fi
V "$FACTORY" "contracts/FamilyFactory.sol:FamilyFactory" "$FACTORY_ARGS"
V "$LOCKER" "contracts/Locker.sol:Locker" \
  "$(enc 'constructor(address,address,address)' "$POOL_MANAGER" "$FACTORY" "$BID_DEPLOYER")"
V "$HOOK" "contracts/FamilyHook.sol:FamilyHook" \
  "$(enc 'constructor(address,address,address,address,address,uint256)' "$POOL_MANAGER" "$FACTORY" "$LOCKER" "$FEE_VAULT" "$ROUTER" "$HOP_FEE")"
# RUN 6: the helper that CREATEd the RoundManager (no constructor args at all), and the randomness
# source behind the random end. A MockRandomnessSource answers `IS_MOCK()`; the real `DrandSource`
# does not, and is submitted with the beacon's own parameters read back off the contract.
if [ -n "$RM_DEPLOYER" ] && [ "$RM_DEPLOYER" != "null" ] && [ "$RM_DEPLOYER" != "0x0000000000000000000000000000000000000000" ]; then
  V "$RM_DEPLOYER" "contracts/RoundManager.sol:RoundManagerDeployer" ""
  VERIFY_ADDRS="$VERIFY_ADDRS $RM_DEPLOYER"
fi
if [ -n "$RANDOMNESS" ] && [ "$RANDOMNESS" != "null" ] && [ "$RANDOMNESS" != "0x0000000000000000000000000000000000000000" ]; then
  if cast call --rpc-url "$RPC" "$RANDOMNESS" 'IS_MOCK()(bool)' >/dev/null 2>&1; then
    echo "== randomness source $RANDOMNESS is a MockRandomnessSource - TESTNET ONLY"
    V "$RANDOMNESS" "contracts/randomness/MockRandomnessSource.sol:MockRandomnessSource"       "$(enc 'constructor(uint64)' "$(cast call --rpc-url "$RPC" "$RANDOMNESS" 'SAFETY_S()(uint64)' | awk '{print $1}')")"
  else
    D_GEN=$(cast call --rpc-url "$RPC" "$RANDOMNESS" 'GENESIS_TIME()(uint64)' | awk '{print $1}')
    D_PER=$(cast call --rpc-url "$RPC" "$RANDOMNESS" 'PERIOD()(uint64)' | awk '{print $1}')
    D_SAF=$(cast call --rpc-url "$RPC" "$RANDOMNESS" 'SAFETY_S()(uint64)' | awk '{print $1}')
    V "$RANDOMNESS" "contracts/randomness/DrandSource.sol:DrandSource"       "$(enc 'constructor(uint64,uint64,uint64,uint256[4])' "$D_GEN" "$D_PER" "$D_SAF" "$DRAND_PK")"
  fi
  VERIFY_ADDRS="$VERIFY_ADDRS $RANDOMNESS"
fi
V "$ROUND_MANAGER" "contracts/RoundManager.sol:RoundManager" \
  "$(enc 'constructor(address,address,address,uint256,uint256,(uint256,uint256,uint256),uint256,address,uint64,(address),(address,uint64,uint64))' \
      "$FACTORY" "$HOOK" "$FEE_VAULT" "$H_FRAC" "$H_MIN" "($BOND_BASE,$BOND_EVERY,$BOND_MAX)" \
      "$MAX_INDEX" "$STEWARD" "$SUNSET_DELAY" "($PRIOR)" "($RANDOMNESS,$END_TIMEOUT,$SCALE_DIV)")"
V "$FEE_VAULT" "contracts/FeeVault.sol:FeeVault" \
  "$(enc 'constructor(address,address,uint256,uint256,uint256)' "$FACTORY" "$DEVELOPER" "$CREATOR_BPS" "$ANCESTOR_BPS" "$REINFORCE_BPS")"
V "$BID_DEPLOYER" "contracts/BidDeployer.sol:BidDeployer" \
  "$(enc 'constructor(address,uint256)' "$FEE_VAULT" "$MIN_BOUNTY")"
V "$ROUTER" "contracts/FamilyRouter.sol:FamilyRouter" "$(enc 'constructor(address)' "$FACTORY")"
V "$LENS" "contracts/FamilyLens.sol:FamilyLens" "$(enc 'constructor(address)' "$FACTORY")"

echo "== verification status =="
for A in $VERIFY_ADDRS "$FACTORY" "$LOCKER" "$HOOK" "$ROUND_MANAGER" "$FEE_VAULT" "$BID_DEPLOYER" "$ROUTER" "$LENS"; do
  curl -s "https://explorer.testnet.chain.robinhood.com/api/v2/smart-contracts/$A" \
    | jq -r --arg a "$A" '"\($a) is_verified=\(.is_verified) partial=\(.is_partially_verified) full=\(.is_fully_verified) name=\(.name)"' 2>/dev/null \
    || echo "$A: no answer"
done
