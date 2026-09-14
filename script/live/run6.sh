#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# run6.sh - drive the MECHANISM v3 surface (docs/MECHANISM_v3.md) against a live deployment:
# the adaptive schedule, the drand random end, late entry and the contestable top-2 purse.
#
# HISTORICAL. Steps m1/m1b/m2b below drive `rank` / `purseWeights` / `PurseSplit`, which were
# removed in review 3 (2026-09-13): the purse is now locked under the coin that won the round and
# `deployAncestor(j, amount)` takes no ids. This script is kept as the record of run 6 and will
# not run against a review-3 deployment.
#
#   ./script/live/run6.sh --fork    against a local anvil fork, warping the clock
#   ./script/live/run6.sh --live    against RPC_TESTNET, waiting on the real clock
#
# Reads .env (DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY, RPC_TESTNET) and deployments/<chain>.json.
# Every step prints its tx hash and appends a row to $RUNLOG (docs/TESTNET_RUN.md by default).
#
# WHAT IS NEW HERE, AND WHY THE SHAPE OF THE RUN IS WHAT IT IS
#
#  1. THE SCHEDULE IS ADAPTIVE AND READ OFF THE CHAIN. D(n) = min(15 min x 2^floor((n-1)/2), 12 h),
#     R(n) = clamp(D(n)/5, 3 min, 1 h), late entry iff D(n) >= 1 h. Every one of those is divided
#     by the deploy parameter DURATION_SCALE_DIV, which this run sets to 5: rounds 1-2 trade for
#     180 s with a 36 s registration, rounds 3-4 for 360 s / 72 s, and rounds 5-6 for 720 s / 144 s
#     WITH late entry open for the first 240 s of trading. Nothing below reads a constant: every
#     timestamp comes from `roundInfo`.
#
#  2. RANDOM_END_S (180 s) IS NOT SCALED - MECHANISM_v3 sec.3 says so and `randomEndWindowFor`
#     caps it at the scaled duration instead. At DURATION_SCALE_DIV = 5 the scaled duration is
#     >= 180 s for every round, so the window is the FULL 180 s in all five rounds and the
#     assertion below is T - 180 <= T_end <= T. For rounds 1-2, whose whole trading period is
#     exactly 180 s, that means the true end can land anywhere in the round, including seconds
#     after it opened: the candidate buys therefore go in as early as the 3 s snipe tax allows
#     (+5 s), and a round that ends before them is a REAL outcome (no winner, threshold decays)
#     which this driver records rather than hides.
#
#  3. THE DRAND RELAY. At T anyone calls `requestEnd()`, which pins the first `evmnet` round due
#     at least DRAND_SAFETY_S (6 s) in the future; the beacon for it does not exist yet. This
#     driver then fetches that round's 64-byte BLS signature from
#     `https://api.drand.sh/v2/beacons/evmnet/rounds/<round>` and relays it to `fulfilEnd(proof)`,
#     which VERIFIES it on chain against the beacon's immutable G2 key (BN254 pairing precompile).
#     If the relay cannot be completed, the driver waits out END_TIMEOUT and calls
#     `finalizeDeterministic()` - the disclosed fallback - and records which branch fired.
#
#     ON THE FORK the clock is warped forward round by round and soon runs AHEAD of the real one,
#     so the round `pin()` chooses does not exist on the real beacon yet. Verification is PURE, so
#     the rehearsal keeps the real cryptography and re-points only the pin: it first tries the
#     honest path (the pinned round, which is published while the fork clock still lags) and, when
#     that round is not out yet, `anvil_setStorageAt` writes a REAL, already-published round into
#     `DrandSource.roundOf[id]` (the mapping is slot 0) and relays THAT round's genuine signature
#     through the genuine on-chain verifier. Live, no such thing ever happens.
#
#  4. THE PURSE NEEDS A GENERATION WITH >= 3 SIBLINGS, AN ETH SLEEVE AND QUIET POOLS.
#     - >= 3 siblings: round 3 registers three candidates (its 72 s registration window is the
#       first one wide enough to do that comfortably).
#     - an ETH sleeve: `FeeVault._book` credits generation M = terminalIndex - 1, so what funds
#       generation 3 is an ATTRIBUTED, ETH-FUNDED candidate trade made while the head is #3 -
#       i.e. the routed `buyCandidate` in round 4 (step d of that round).
#     - quiet pools: `_placeBid` band-checks EVERY target pool against its own 1800 s TWAP, and
#       `ethValueOfParent` band-checks every link of the conversion. The round-4 routed buy is the
#       last swap on pools #0-#3; round 5 is deliberately funded in PARENT tokens only, so by the
#       time the purse step runs (>= 1800 s later) every pool involved is quiet and spot == TWAP.
#     - two observations per sibling pool: OBS_MIN_SPACING is 120 s and observations are only
#       written by swaps, so each of round 3's three candidates is bought TWICE, at +5 s and
#       +130 s.
#
#  5. THE BOARD IS THE ONLY THING THAT DECIDES THE SPLIT. `rank(candidateId)` is permissionless
#     and READS the trailing average out of the hook; `deployAncestor(j, amount, idA, idB)`
#     re-verifies the pair against `purseWeights` and refuses anything else. All three siblings
#     are ranked here, so the third one is observed to be OFF the board and to receive nothing.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

MODE="${1:---fork}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

CHAIN_ID=46630
# PRIVACY (design decision 2026-09-12): live testnet addresses, tx hashes and the deployer address
# are kept OUT of the tracked tree. The deployment record and this driver's run log therefore live
# under `private/` (gitignored) whenever it exists, and fall back to the tracked paths otherwise.
DEFAULT_DEPLOY_JSON="deployments/${CHAIN_ID}.json"
[ -f "private/deployments/${CHAIN_ID}.json" ] && DEFAULT_DEPLOY_JSON="private/deployments/${CHAIN_ID}.json"
DEPLOY_JSON="${DEPLOY_JSON:-$DEFAULT_DEPLOY_JSON}"
RUNLOG="${RUNLOG:-private/TESTNET_RUN.md}"
EXPLORER="https://explorer.testnet.chain.robinhood.com/tx"
DRAND_API="https://api.drand.sh/v2/beacons/evmnet"

case "$MODE" in
  --live)
    RPC="$RPC_TESTNET"; KEY="$DEPLOYER_PRIVATE_KEY"; ME="$DEPLOYER_ADDRESS"
    ;;
  --fork)
    RPC="${FORK_RPC:-http://127.0.0.1:8545}"
    KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ME="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    ;;
  *) echo "usage: $0 [--live|--fork]" >&2; exit 2 ;;
esac

GAS_PRICE=10000000                       # 0.01 gwei, legacy pricing (this chain's basefee)
GASFLAGS="--legacy --gas-price $GAS_PRICE"
SEND="cast send --rpc-url $RPC --private-key $KEY $GASFLAGS"
CALL="cast call --rpc-url $RPC"
MAXU=115792089237316195423570985008687907853269984665640564039457584007913129639935

# ---- deployment addresses --------------------------------------------------------------------
j() { jq -r "$1" "$DEPLOY_JSON"; }
POOL_MANAGER=$(j .poolManager); FACTORY=$(j .factory); HOOK=$(j .hook); LOCKER=$(j .locker)
ROUND_MANAGER=$(j .roundManager); FEE_VAULT=$(j .feeVault); ROUTER=$(j .router); LENS=$(j .lens)
BID_DEPLOYER=$(j .bidDeployer); GENESIS=$(j .genesisToken); GENESIS_POOL=$(j .genesisPoolId)
RANDOMNESS=$(j '.randomnessSource // .constants.randomnessSource')

# ---- budget ----------------------------------------------------------------------------------
# Everything that leaves the key: one genesis buy (the only real capital in the run), a tiny
# second genesis buy for the oracle, one ETH-funded candidate buy in round 4 (which is what funds
# generation 3's sleeve), the bonds, and gas. Bonds come back for the five winners; the losers'
# forfeit into the genesis earmark.
# RESUME MODE. A driver that died mid-run (or a deployment that already has a head) is continued
# rather than restarted: SKIP_GENESIS=1 leaves the genesis buys alone and START_ROUND=n skips the
# rounds that have already happened. The round numbers below ARE the chain's round numbers, so the
# schedule a resumed run sees is the real one.
SKIP_GENESIS=${SKIP_GENESIS:-0}
START_ROUND=${START_ROUND:-1}
GENESIS_BUY_ETH=${GENESIS_BUY_ETH:-0.03}
SECOND_BUY_ETH=${SECOND_BUY_ETH:-0.0005}
ROUND4_BUY_ETH=${ROUND4_BUY_ETH:-0.008}
GAS_BUDGET_ETH=${GAS_BUDGET_ETH:-0.002}
BUDGET_CAP_ETH=${BUDGET_CAP_ETH:-0.08}
DEPLOY_COST_ETH=${DEPLOY_COST_ETH:-0.00032}  # 31,543,015 gas, measured on the fork

# ---- helpers (shared with round.sh; kept identical where they are the same) -------------------
hex2dec() { cast to-dec "$1" 2>/dev/null || echo 0; }
bsub() { python -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$1" "$2"; }
badd() { python -c "import sys;print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
bmin() { python -c "import sys;print(min(int(a) for a in sys.argv[1:]))" "$@"; }
bmul() { python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2]))" "$1" "$2"; }
bbps() { python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2])//10000)" "$1" "$2"; }
bge()  { python -c "import sys;sys.exit(0 if int(sys.argv[1])>=int(sys.argv[2]) else 1)" "$1" "$2"; }
wei()  { cast to-wei "$1"; }

explorer_cell() { [ "$MODE" = "--live" ] && printf '[tx](%s/%s)' "$EXPLORER" "$1" || printf 'anvil fork - not on chain'; }

log() { # log <step> <txhash> <gas> <effect>
  printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$(explorer_cell "$2")" "$3" "$4" >> "$RUNLOG"
  printf '>> %-38s tx=%s gas=%s\n   %s\n' "$1" "$2" "$3" "$4"
}
note() { printf '| %s | - | - | - | %s |\n' "$1" "$2" >> "$RUNLOG"; printf '>> %-38s %s\n' "$1" "$2"; }

fail() { # fail <step> <txhash-or-> <message>
  printf '| %s | `%s` | - | - | **FAILED**: %s |\n' "$1" "$2" "$3" >> "$RUNLOG"
  echo "!! STEP FAILED: $1: $3" >&2
  [ "$2" != "-" ] && cast run "$2" --rpc-url "$RPC" 2>&1 | tail -30 >&2 || true
  exit 1
}
check() { # check <condition-result 0/1> <step> <message>
  [ "$1" = "0" ] || fail "$2" "-" "$3"
}

# send <label> <to> <sig> [args...]; extra cast flags via $EXTRA. Sets TXHASH / GASUSED.
send() {
  local label="$1"; shift
  local out rc
  set +e
  out=$($SEND ${EXTRA:-} "$@" --json 2>&1); rc=$?
  set -e
  if [ $rc -ne 0 ]; then fail "$label" "-" "$(echo "$out" | tail -3 | tr '\n' ' ')"; fi
  TXHASH=$(echo "$out" | jq -r .transactionHash)
  GASUSED=$(hex2dec "$(echo "$out" | jq -r .gasUsed)")
  local status; status=$(echo "$out" | jq -r .status)
  if [ "$status" != "0x1" ]; then fail "$label" "$TXHASH" "reverted on chain"; fi
}
# try_send: the same, but a revert is an ANSWER rather than the end of the run. Sets TRY_RC.
try_send() {
  local label="$1"; shift
  local out rc
  set +e
  out=$($SEND ${EXTRA:-} "$@" --json 2>&1); rc=$?
  set -e
  TRY_OUT="$out"; TRY_RC=$rc; TXHASH="-"; GASUSED=0
  if [ $rc -eq 0 ]; then
    TXHASH=$(echo "$out" | jq -r .transactionHash)
    GASUSED=$(hex2dec "$(echo "$out" | jq -r .gasUsed)")
    [ "$(echo "$out" | jq -r .status)" = "0x1" ] || TRY_RC=1
  fi
  return 0
}

now_ts() { cast block latest --rpc-url "$RPC" -f timestamp; }

wait_until() { # wait_until <timestamp> <what>
  local target="$1" what="$2" now
  now=$(now_ts)
  if [ "$now" -ge "$target" ]; then echo "   (already past $what)"; return; fi
  if [ "$MODE" = "--fork" ]; then
    cast rpc evm_increaseTime $((target - now + 1)) --rpc-url "$RPC" >/dev/null
    cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
    echo "   warped to $what ($(now_ts))"
  else
    echo "   waiting $((target - now))s for $what ..."
    while [ "$(now_ts)" -lt "$target" ]; do sleep 5; done
    echo "   reached $what ($(now_ts))"
  fi
}

bal_eth()  { cast balance "$ME" --rpc-url "$RPC"; }
bal_tok()  { $CALL "$1" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}'; }
round_id() { $CALL "$ROUND_MANAGER" 'roundCount()(uint256)' | awk '{print $1}'; }
cand_count(){ $CALL "$ROUND_MANAGER" 'candidateCount()(uint256)' | awk '{print $1}'; }
head_index(){ $CALL "$ROUND_MANAGER" 'headIndex()(uint256)' | awk '{print $1}'; }
head_token(){ $CALL "$ROUND_MANAGER" 'head()(address)' | awk '{print $1}'; }
canonical() { $CALL "$ROUND_MANAGER" 'canonical(uint256)(address)' "$1" | awk '{print $1}'; }
threshold() { $CALL "$ROUND_MANAGER" 'threshold()(uint256)' | awk '{print $1}'; }
current_bond() { $CALL "$ROUND_MANAGER" 'currentBond()(uint256)' | awk '{print $1}'; }
bond_for()  { $CALL "$ROUND_MANAGER" 'bondFor(uint256)(uint256)' "$1" | awk '{print $1}'; }
obs()       { $CALL "$HOOK" 'observationCount(bytes32)(uint256)' "$1" | awk '{print $1}'; }
twap_of()   { $CALL "$HOOK" 'consult(bytes32,uint32)(uint160,uint32)' "$1" 1800 | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
vnum()      { local s="$1"; shift; $CALL "$FEE_VAULT" "$s" "$@" | awk '{print $1}'; }
dnum()      { local s="$1"; shift; $CALL "$BID_DEPLOYER" "$s" "$@" | awk '{print $1}'; }

# v3 Round struct: 1 openedAt, 2 registrationEnd, 3 tradingStart, 4 lateEntryEnd, 5 nominalEnd,
# 6 tradingEnd, 7 submitEnd, 8 finalized, 9 hasWinner, 10 hasBest, 11 randomId, 12 hUsed,
# 13 bondWei, 14 parentIndex, 15 parentToken, 16 candidateCount, 17 bestCandidateId,
# 18 winnerCandidateId, 19 bestAvg, 20 bestAttained, 21 bestPoolId
ROUND_SIG='roundInfo(uint256)((uint64,uint64,uint64,uint64,uint64,uint64,uint64,bool,bool,bool,bytes32,uint256,uint256,uint256,address,uint256,uint256,uint256,int256,uint64,bytes32))'
round_field() { $CALL "$ROUND_MANAGER" "$ROUND_SIG" "$1" | tr -d '()' | tr ',' '\n' | sed -n "$2p" \
                  | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
R_REGEND_F=2; R_TSTART_F=3; R_LATE_F=4; R_NOMEND_F=5; R_TEND_F=6; R_SUBEND_F=7
R_RANDID_F=11; R_BOND_F=13

# v3 Candidate struct: 1 roundId, 2 token, 3 creator, 4 bond, 5 submitted, 6 tradingStart,
# 7 avg, 8 tFirstAttained, 9.. key
CAND_SIG='candidateInfo(uint256)((uint256,address,address,uint256,bool,uint64,int256,uint64,(address,address,uint24,int24,address)))'
cand_field() { $CALL "$ROUND_MANAGER" "$CAND_SIG" "$1" | tr -d '()' | cut -d',' -f"$2" | tr -d ' ' | sed -E 's/\[[^]]*\]//g'; }
CAND_TOKEN_F=2; CAND_BOND_F=4; CAND_TSTART_F=6; CAND_AVG_F=7
# The candidate's PoolKey is fields 9..13 (currency0, currency1, fee, tickSpacing, hooks); its id
# is keccak256 of the ABI encoding, which `cast` can do without a helper contract.
cand_pool_id() {
  local c0 c1 fee ts hooks
  c0=$(cand_field "$1" 9); c1=$(cand_field "$1" 10); fee=$(cand_field "$1" 11)
  ts=$(cand_field "$1" 12); hooks=$(cand_field "$1" 13)
  cast keccak "$(cast abi-encode 'f((address,address,uint24,int24,address))' "($c0,$c1,$fee,$ts,$hooks)")"
}

approve_max() { # approve_max <label> <token> <spender>
  local cur; cur=$($CALL "$2" 'allowance(address,address)(uint256)' "$ME" "$3" | awk '{print $1}')
  if bge "1000000000000000000000000000000" "$cur"; then
    send "$1" "$2" 'approve(address,uint256)' "$3" "$MAXU"
    log "$1" "$TXHASH" "$GASUSED" "approved $3 to move $2"
  fi
}

# ---- the drand relay --------------------------------------------------------------------------
drand_latest_round() { curl -s --max-time 20 "$DRAND_API/rounds/latest" | jq -r .round 2>/dev/null; }
drand_signature() { # drand_signature <round> -> 64-byte hex, empty when the round is not out yet
  # a round that has not been produced answers with a non-JSON error body, which is an ANSWER
  curl -s --max-time 20 "$DRAND_API/rounds/$1" | jq -r '.signature // empty' 2>/dev/null || true
}
drand_time_of() { # drand_time_of <round>
  local g p
  g=$($CALL "$RANDOMNESS" 'GENESIS_TIME()(uint64)' | awk '{print $1}')
  p=$($CALL "$RANDOMNESS" 'PERIOD()(uint64)' | awk '{print $1}')
  python -c "import sys;print(int(sys.argv[1])+int(sys.argv[2])*int(sys.argv[3]))" "$g" "$p" "$1"
}
# FORK ONLY: re-point the pinned id at a real, already-published beacon round. `roundOf` is the
# first (and only) storage variable of DrandSource, so its slot is keccak256(id . uint256(0)).
fork_repoint_pin() { # fork_repoint_pin <id> -> echoes the round it now points at
  local id="$1" r slot
  r=$(( $(drand_latest_round) - 2 ))
  slot=$(cast index bytes32 "$id" 0)
  cast rpc anvil_setStorageAt "$RANDOMNESS" "$slot" "$(cast to-uint256 "$r")" --rpc-url "$RPC" >/dev/null
  echo "$r"
}

# ---- projected cost, and the hard abort ------------------------------------------------------
H_IDX=$(head_index)
BONDS_TOTAL=0
for k in 1 2 3 4 5; do
  N=2; [ "$k" = 3 ] && N=3; [ "$k" = 5 ] && N=3
  BONDS_TOTAL=$(badd "$BONDS_TOTAL" "$(bmul "$N" "$(bond_for $((H_IDX + k)))")")
done
PROJ=$(badd "$(wei "$GENESIS_BUY_ETH")" "$(wei "$SECOND_BUY_ETH")" "$(wei "$ROUND4_BUY_ETH")" \
             "$BONDS_TOTAL" "$(wei "$GAS_BUDGET_ETH")" "$(wei "$DEPLOY_COST_ETH")")
CAP=$(wei "$BUDGET_CAP_ETH")
echo "== projected gross ETH cost (run 6) =="
printf '   %-34s %s\n' "deploy (measured on the fork)" "$(wei "$DEPLOY_COST_ETH")"
printf '   %-34s %s\n' "genesis buy" "$(wei "$GENESIS_BUY_ETH")"
printf '   %-34s %s\n' "genesis 2nd (oracle) buy" "$(wei "$SECOND_BUY_ETH")"
printf '   %-34s %s\n' "round 4 ETH candidate buy (sleeve)" "$(wei "$ROUND4_BUY_ETH")"
printf '   %-34s %s\n' "bonds, 5 rounds (2/2/3/2/3)" "$BONDS_TOTAL"
printf '   %-34s %s\n' "gas headroom @ $GAS_PRICE wei/gas" "$(wei "$GAS_BUDGET_ETH")"
printf '   %-34s %s wei = %s ETH\n' "TOTAL" "$PROJ" "$(cast from-wei "$PROJ")"
printf '   %-34s %s wei = %s ETH\n' "cap" "$CAP" "$BUDGET_CAP_ETH"
if bge "$PROJ" "$CAP" && [ "$PROJ" != "$CAP" ]; then
  echo "!! ABORT: projected $PROJ wei exceeds the $CAP wei cap" >&2; exit 3
fi

# ---- start -----------------------------------------------------------------------------------
mkdir -p "$(dirname "$RUNLOG")"
if [ ! -f "$RUNLOG" ]; then echo "# Testnet run log (chain $CHAIN_ID) - PRIVATE, not for the tracked tree" > "$RUNLOG"; fi
{
  echo
  echo "## Run 6 driver - mechanism v3 ($MODE) - started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "| step | tx hash | explorer | gas used | observed effect |"
  echo "|---|---|---|---|---|"
} >> "$RUNLOG"

ETH_START=$(bal_eth)
echo "== deployer $ME  balance $(cast from-wei "$ETH_START") ETH =="
if ! bge "$ETH_START" "$PROJ"; then
  echo "!! ABORT: balance $ETH_START wei is below the projected $PROJ wei" >&2; exit 3
fi
SCALE=$($CALL "$ROUND_MANAGER" 'DURATION_SCALE_DIV()(uint64)' | awk '{print $1}')
ENDTO=$($CALL "$ROUND_MANAGER" 'END_TIMEOUT()(uint64)' | awk '{print $1}')
note "schedule (DURATION_SCALE_DIV=$SCALE)" \
  "durationFor(1..6)=$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 1 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 2 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 3 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 4 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 5 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'durationFor(uint256)(uint64)' 6 | awk '{print $1}') s, registrationFor=$($CALL "$ROUND_MANAGER" 'registrationFor(uint256)(uint64)' 1 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'registrationFor(uint256)(uint64)' 3 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'registrationFor(uint256)(uint64)' 5 | awk '{print $1}') s, lateEntryUntil(5)=$($CALL "$ROUND_MANAGER" 'lateEntryUntil(uint256)(uint64)' 5 | awk '{print $1}') s, closingWindowFor(1/5)=$($CALL "$ROUND_MANAGER" 'closingWindowFor(uint256)(uint64)' 1 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'closingWindowFor(uint256)(uint64)' 5 | awk '{print $1}') s, randomEndWindowFor(1/5)=$($CALL "$ROUND_MANAGER" 'randomEndWindowFor(uint256)(uint64)' 1 | awk '{print $1}')/$($CALL "$ROUND_MANAGER" 'randomEndWindowFor(uint256)(uint64)' 5 | awk '{print $1}') s (RANDOM_END_S is NOT scaled), SUBMIT_S=$($CALL "$ROUND_MANAGER" 'SUBMIT_S()(uint64)' | awk '{print $1}') s, END_TIMEOUT=$ENDTO s, randomness=$RANDOMNESS"

# ---- (a) buy genesis ---------------------------------------------------------------------------
if [ "$SKIP_GENESIS" = "1" ]; then
  T_GENESIS_BUY=$(( $(now_ts) - 1810 ))
  note "a/a2. genesis buys SKIPPED (resume mode)"     "this deployment already holds its genesis position and its genesis pool already has $(obs "$GENESIS_POOL") oracle observations (>= 2 is a precondition of every keeper path); head is #$(head_index)"
else
  TOK0=$(bal_tok "$GENESIS")
  EXTRA="--value ${GENESIS_BUY_ETH}ether"
  send "a. buy genesis" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
  EXTRA=""
  T_GENESIS_BUY=$(now_ts)
  log "a. buy genesis ${GENESIS_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
    "received $(bsub "$(bal_tok "$GENESIS")" "$TOK0") FAM0 (wei-tokens); this is the only real capital in the run and the keeper inventory for the purse step"

  wait_until $((T_GENESIS_BUY + 130)) "genesis buy + 130 s (OBS_MIN_SPACING is 120 s)"
  EXTRA="--value ${SECOND_BUY_ETH}ether"
  send "a2. genesis oracle buy" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
  EXTRA=""
  log "a2. genesis oracle buy ${SECOND_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
    "genesis pool observationCount=$(obs "$GENESIS_POOL") (>= 2 is a precondition of every keeper path)"

fi

# ---- the round driver --------------------------------------------------------------------------
# run_round <n> <flavour> <bps...>   flavour: plain | purse | ethbuy | late
declare -a ROUND_SUMMARY=()
# RESUME MODE (see SKIP_GENESIS/START_ROUND above): the purse step can also be driven on its own
# against a chain whose rounds are already finished, by naming the generation, the round that
# crowned it and its sibling candidate ids in the environment.
declare -a PURSE_IDS=(${PURSE_IDS:-})
PURSE_GEN=${PURSE_GEN:-0}
PURSE_ROUND=${PURSE_ROUND:-0}
T_ETH_BUY=${T_ETH_BUY:-0}

run_round() {
  local n="$1" flavour="$2"; shift 2
  if [ "$n" -lt "$START_ROUND" ]; then
    echo ">> round $n ($flavour) skipped: START_ROUND=$START_ROUND"
    return 0
  fi
  local bps=("$@")
  local ncand=${#bps[@]}
  local parent_idx parent_tok rid
  parent_idx=$(head_index); parent_tok=$(head_token)
  local -a ids=()
  local nreg=$ncand
  [ "$flavour" = "late" ] && nreg=$((ncand - 1))

  # (1) registration ---------------------------------------------------------------------------
  local i letter bond
  for ((i = 0; i < nreg; i++)); do
    letter=$(printf '%s%d' "R${n}-" $((i + 1)))
    bond=$(current_bond)
    EXTRA="--value ${bond}wei"
    send "r$n.b register $letter" "$FACTORY" 'registerCandidate(string,string,string)' "$letter" "$letter" "ipfs://$letter"
    EXTRA=""
    ids+=("$(( $(cand_count) - 1 ))")
    log "r$n.b register $letter" "$TXHASH" "$GASUSED" \
      "candidateId=${ids[-1]}, bond $bond wei (currentBond() = bondFor($((parent_idx + 1)))), parent = #$parent_idx $parent_tok"
  done
  rid=$(round_id)
  local t_reg t_start t_late t_nom
  t_reg=$(round_field "$rid" $R_REGEND_F); t_start=$(round_field "$rid" $R_TSTART_F)
  t_late=$(round_field "$rid" $R_LATE_F);  t_nom=$(round_field "$rid" $R_NOMEND_F)
  local H; H=$(threshold)
  note "round $rid (n=$n) opened" \
    "registrationEnd=$t_reg tradingStart=$t_start nominalEnd(T)=$t_nom lateEntryEnd=$t_late (0 = no late entry at this duration); D=$((t_nom - t_start)) s, R=$((t_reg - $(round_field "$rid" 1))) s, W=$($CALL "$ROUND_MANAGER" 'closingWindowFor(uint256)(uint64)' "$rid" | awk '{print $1}') s, H=$H, bondWei=$(round_field "$rid" $R_BOND_F)"

  # (2) trading --------------------------------------------------------------------------------
  wait_until $((t_start + 5)) "round $rid tradingStart + 5 s (past the 3 s snipe tax)"
  approve_max "r$n.d0 approve #$parent_idx -> router" "$parent_tok" "$ROUTER"
  local p0; p0=$(bal_tok "$parent_tok")
  local amt ctok cb
  for ((i = 0; i < nreg; i++)); do
    ctok=$(cand_field "${ids[$i]}" $CAND_TOKEN_F)
    if [ "$flavour" = "ethbuy" ] && [ "$i" = "0" ]; then
      # the ONE ETH-funded, attributed candidate trade of the run: ETH -> #0 -> ... -> #n -> CAND,
      # which is what credits generation (headIndex) with an ETH sleeve for the purse step
      cb=$(bal_tok "$ctok")
      EXTRA="--value ${ROUND4_BUY_ETH}ether"
      send "r$n.d buy id${ids[$i]} (ETH)" "$ROUTER" 'buyCandidate(uint256,uint256,address,uint256)' "${ids[$i]}" 0 "$ME" 8
      EXTRA=""
      T_ETH_BUY=$(now_ts)
      log "r$n.d buyCandidate id${ids[$i]} (${ROUND4_BUY_ETH} ETH, routed)" "$TXHASH" "$GASUSED" \
        "ETH -> #0 -> ... -> #$parent_idx -> candidate in one unlock; received $(bsub "$(bal_tok "$ctok")" "$cb") tokens; ATTRIBUTED via the candidate sentinel, so the ETH fee books to generation $parent_idx: claimableEth($parent_idx) = $(vnum 'claimableEth(uint256)(uint256)' "$parent_idx")"
    else
      amt=$(bbps "$p0" "${bps[$i]}")
      cb=$(bal_tok "$ctok")
      send "r$n.d buy id${ids[$i]}" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "${ids[$i]}" "$amt" 0 "$ME"
      log "r$n.d buy id${ids[$i]} (${bps[$i]} bps of the #$parent_idx holding)" "$TXHASH" "$GASUSED" \
        "spent $amt of #$parent_idx -> received $(bsub "$(bal_tok "$ctok")" "$cb") candidate tokens (single hop, attributed)"
    fi
  done

  # (2b) the purse round buys each sibling a SECOND time, >= OBS_MIN_SPACING later, so that every
  # sibling pool has the two observations `_requireWithinBand` demands of a bid target
  if [ "$flavour" = "purse" ]; then
    wait_until $((t_start + 130)) "round $rid tradingStart + 130 s (second observation per sibling)"
    for ((i = 0; i < nreg; i++)); do
      amt=$(bbps "$p0" 200)
      send "r$n.d2 top-up id${ids[$i]}" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "${ids[$i]}" "$amt" 0 "$ME"
      log "r$n.d2 second buy id${ids[$i]} (200 bps)" "$TXHASH" "$GASUSED" \
        "second swap > 120 s after the first: sibling pool observationCount=$(obs "$(cand_pool_id "${ids[$i]}")") (a bid target needs >= 2)"
    done
  fi

  # (2c) LATE ENTRY: register after registrationEnd, inside lateEntryEnd. Its pool opens NOW and
  # its own 3 s snipe tax starts NOW; it is scored over the SAME closing window as everyone else.
  if [ "$flavour" = "late" ]; then
    check "$([ "$t_late" != "0" ] && echo 0 || echo 1)" "r$n late entry" "lateEntryEnd is 0: this round's duration does not offer late entry"
    wait_until $((t_start + 30)) "round $rid tradingStart + 30 s (late-entry window is open until $t_late)"
    local now_l; now_l=$(now_ts)
    check "$([ "$now_l" -gt "$t_reg" ] && [ "$now_l" -lt "$t_late" ] && echo 0 || echo 1)" \
      "r$n late entry" "now=$now_l is not strictly inside (registrationEnd=$t_reg, lateEntryEnd=$t_late)"
    letter="R${n}-LATE"
    bond=$(current_bond)
    EXTRA="--value ${bond}wei"
    send "r$n.b register $letter (LATE)" "$FACTORY" 'registerCandidate(string,string,string)' "$letter" "$letter" "ipfs://$letter"
    EXTRA=""
    local late_id; late_id=$(( $(cand_count) - 1 )); ids+=("$late_id")
    local late_start; late_start=$(cand_field "$late_id" $CAND_TSTART_F)
    log "r$n.b register $letter (LATE ENTRY)" "$TXHASH" "$GASUSED" \
      "registered at $(now_ts), i.e. $(( $(now_ts) - t_reg )) s AFTER registrationEnd=$t_reg and inside lateEntryEnd=$t_late; SAME bond $bond wei; its candidate.tradingStart=$late_start (its own pool opens now, not at the round's start) vs the round's tradingStart=$t_start"
    wait_until $((late_start + 5)) "late entrant's own snipe window (+5 s)"
    ctok=$(cand_field "$late_id" $CAND_TOKEN_F); cb=$(bal_tok "$ctok")
    amt=$(bbps "$p0" "${bps[-1]}")
    send "r$n.d buy id$late_id (LATE)" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "$late_id" "$amt" 0 "$ME"
    log "r$n.d buy the LATE entrant id$late_id (${bps[-1]} bps)" "$TXHASH" "$GASUSED" \
      "the late entrant TRADES: spent $amt of #$parent_idx -> $(bsub "$(bal_tok "$ctok")" "$cb") tokens; it is scored over the same closing window as the two coins that registered at the open"
  fi

  # (3) the random end -------------------------------------------------------------------------
  wait_until "$t_nom" "round $rid nominal end T=$t_nom"
  send "r$n.e requestEnd" "$ROUND_MANAGER" 'requestEnd()'
  local rand_id drand_round
  rand_id=$(round_field "$rid" $R_RANDID_F)
  drand_round=$($CALL "$RANDOMNESS" 'roundOf(bytes32)(uint64)' "$rand_id" | awk '{print $1}')
  log "r$n.e requestEnd (T=$t_nom)" "$TXHASH" "$GASUSED" \
    "pinned randomId=$rand_id -> drand evmnet round $drand_round, due at $(drand_time_of "$drand_round"); the beacon for it DOES NOT EXIST YET"

  local relay_round="$drand_round" sig="" settled="" t_end
  if [ "$MODE" = "--fork" ]; then
    # A fork's clock is its own. While it still LAGS real time the pinned round is already
    # published and the rehearsal is exact; once warping has pushed it PAST real time the pinned
    # round does not exist yet, and the rehearsal keeps the real cryptography by re-pointing the
    # pin at a real, already-published round (header note 3). Try the honest path first.
    if [ -z "$(drand_signature "$drand_round" || true)" ]; then
      relay_round=$(fork_repoint_pin "$rand_id")
      note "r$n.e FORK ONLY: pin re-pointed"         "the fork clock has run past real time, so evmnet round $drand_round does not exist yet: anvil_setStorageAt DrandSource.roundOf[$rand_id] = $relay_round, a REAL, already-published round. The signature relayed below is the genuine beacon and is checked by the genuine on-chain pairing verifier; only the CHOICE of round is synthetic."
    else
      note "r$n.e fork clock still behind real time"         "the pinned evmnet round $drand_round is already published, so the rehearsal relays exactly what a live run would"
    fi
  else
    wait_until $(( $(drand_time_of "$drand_round") + 2 )) "drand round $drand_round to be produced"
  fi
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    sig=$(drand_signature "$relay_round" || true)
    [ -n "$sig" ] && break
    echo "   drand round $relay_round not served yet (attempt $attempt); retrying in 3 s"
    sleep 3
  done

  if [ -n "$sig" ]; then
    try_send "r$n.f fulfilEnd" "$ROUND_MANAGER" 'fulfilEnd(bytes)' "0x$sig"
    if [ "$TRY_RC" = "0" ]; then
      settled="drand"
      t_end=$(round_field "$rid" $R_TEND_F)
      log "r$n.f fulfilEnd (drand round $relay_round)" "$TXHASH" "$GASUSED" \
        "relayed the 64-byte BLS signature \`0x$sig\`, VERIFIED on chain against the evmnet G2 key (BN254 pairing precompile); T_end=$t_end = T - $((t_nom - t_end)) s; submitEnd=$(round_field "$rid" $R_SUBEND_F)"
    else
      note "r$n.f fulfilEnd FAILED" "$(echo "$TRY_OUT" | tail -2 | tr '\n' ' ')"
    fi
  else
    note "r$n.f fulfilEnd skipped" "the drand API served no signature for round $relay_round"
  fi

  if [ -z "$settled" ]; then
    # the disclosed fallback: after END_TIMEOUT anyone ends the round deterministically at T
    wait_until $((t_nom + ENDTO + 5)) "END_TIMEOUT ($ENDTO s) after T"
    send "r$n.f2 finalizeDeterministic" "$ROUND_MANAGER" 'finalizeDeterministic()'
    settled="timeout"
    t_end=$(round_field "$rid" $R_TEND_F)
    log "r$n.f2 finalizeDeterministic" "$TXHASH" "$GASUSED" \
      "no verifiable beacon within END_TIMEOUT=$ENDTO s: RandomEndUnavailable, T_end=$t_end = T exactly (the randomness is simply absent for this round)"
  fi

  # the assertion the whole random end rests on
  local win; win=$($CALL "$ROUND_MANAGER" 'randomEndWindowFor(uint256)(uint64)' "$rid" | awk '{print $1}')
  check "$([ "$t_end" -le "$t_nom" ] && [ "$t_end" -ge $((t_nom - win)) ] && echo 0 || echo 1)" \
    "r$n T_end window" "T_end=$t_end is outside [T-$win, T] = [$((t_nom - win)), $t_nom]"
  note "r$n T_end in window" \
    "T=$t_nom, T_end=$t_end, offset = $((t_nom - t_end)) s, window = randomEndWindowFor($rid) = $win s (RANDOM_END_S = 180 is NOT divided by DURATION_SCALE_DIV): T-$win <= T_end <= T HOLDS. Settled by: $settled."

  # (4) scores and finalize --------------------------------------------------------------------
  local cid avg
  for ((i = ncand - 1; i >= 0; i--)); do
    cid=${ids[$i]}
    send "r$n.g submitScore id$cid" "$ROUND_MANAGER" 'submitScore(uint256)' "$cid"
    avg=$(cand_field "$cid" $CAND_AVG_F)
    log "r$n.g submitScore id$cid" "$TXHASH" "$GASUSED" \
      "avg over [T_end - W, T_end] = $avg vs H=$H -> $(bge "$avg" "$H" && echo CLEARS || echo below); candidate.tradingStart=$(cand_field "$cid" $CAND_TSTART_F)"
  done
  local t_sub; t_sub=$(round_field "$rid" $R_SUBEND_F)
  wait_until $((t_sub + 1)) "round $rid submitEnd"
  local head_before; head_before=$(head_index)
  send "r$n.h finalize" "$ROUND_MANAGER" 'finalize()'
  local head_after; head_after=$(head_index)
  log "r$n.h finalize round $rid" "$TXHASH" "$GASUSED" \
    "headIndex $head_before -> $head_after, head=$(head_token); threshold now $(threshold)"
  ROUND_SUMMARY+=("round $rid (n=$n, $flavour): D=$((t_nom - t_start))s T=$t_nom T_end=$t_end (T-$((t_nom - t_end))s, $settled, drand round $relay_round) head $head_before->$head_after")

  if [ "$flavour" = "purse" ]; then
    if [ "$head_after" -gt "$head_before" ]; then
      PURSE_GEN=$head_after; PURSE_ROUND=$rid; PURSE_IDS=("${ids[@]}")
    else
      note "r$n purse generation" "round $rid crowned NOBODY, so there is no generation with 3 siblings to contest; the purse step will be skipped"
    fi
  fi
}

# rounds 1-4 quick, round 5 with late entry. The bps are fractions of the parent holding at the
# start of the round, so the first candidate of every round is the one expected to win.
run_round 1 plain   4000 2500
run_round 2 plain   4000 2500
run_round 3 purse   4000 2500 1200
run_round 4 ethbuy  0    2500
run_round 5 late    4000 2500 1500

# ---- (m) THE CONTESTABLE PURSE ------------------------------------------------------------------
if [ "$PURSE_GEN" = "0" ]; then
  note "m. purse" "SKIPPED: no generation with three siblings was crowned"
else
  J=$PURSE_GEN
  PARENT=$(canonical $((J - 1)))
  echo "== purse: generation $J, siblings ${PURSE_IDS[*]} (round $PURSE_ROUND), parent #$((J - 1)) $PARENT =="
  # every pool the conversion prices, plus every bid target, must cover 1800 s and sit inside the
  # +/-3% band; the last swap that touched #0..#$((J)) was the round-4 routed buy
  wait_until $((T_ETH_BUY + 1810)) "1800 s of TWAP coverage since the last routed ETH buy"

  # (m1) rank all three siblings. `rank` READS the trailing average out of the hook - a caller
  # supplies an id and nothing else - and keeps a running top 2.
  for cid in "${PURSE_IDS[@]}"; do
    send "m1. rank id$cid" "$ROUND_MANAGER" 'rank(uint256)' "$cid"
    log "m1. rank id$cid (generation $J)" "$TXHASH" "$GASUSED" \
      "trailing support read from the hook over purseWindow($J)=$($CALL "$ROUND_MANAGER" 'purseWindow(uint256)(uint32)' "$J" | awk '{print $1}') s (the SAME closing window round $PURSE_ROUND was scored on)"
  done
  BOARD=$($CALL "$ROUND_MANAGER" 'board(uint256)((bool,uint64,uint256,int256),(bool,uint64,uint256,int256))' "$J")
  ID_A=$(echo "$BOARD" | sed -n 1p | tr -d '()' | cut -d',' -f3 | tr -d ' ')
  ID_B=$(echo "$BOARD" | sed -n 2p | tr -d '()' | cut -d',' -f3 | tr -d ' ')
  AVG_A=$(echo "$BOARD" | sed -n 1p | tr -d '()' | cut -d',' -f4 | tr -d ' ' | sed -E 's/\[[^]]*\]//g')
  AVG_B=$(echo "$BOARD" | sed -n 2p | tr -d '()' | cut -d',' -f4 | tr -d ' ' | sed -E 's/\[[^]]*\]//g')
  THIRD=""
  for cid in "${PURSE_IDS[@]}"; do
    [ "$cid" != "$ID_A" ] && [ "$cid" != "$ID_B" ] && THIRD="$cid"
  done
  WA=$($CALL "$ROUND_MANAGER" 'purseWeights(uint256,uint256,uint256)(uint256,uint256)' "$J" "$ID_A" "$ID_B" | sed -n 1p | awk '{print $1}')
  WB=$($CALL "$ROUND_MANAGER" 'purseWeights(uint256,uint256,uint256)(uint256,uint256)' "$J" "$ID_A" "$ID_B" | sed -n 2p | awk '{print $1}')
  note "m1. board(generation $J)" \
    "top 2 = id$ID_A (avg $AVG_A) and id$ID_B (avg $AVG_B); the THIRD sibling id$THIRD is OFF the board and gets nothing. purseWeights($J, $ID_A, $ID_B) = ($WA, $WB) -> the purse splits $WA : $WB"
  # the negative half: a pair that is NOT the board is refused
  set +e
  BADPAIR=$($CALL "$ROUND_MANAGER" 'purseWeights(uint256,uint256,uint256)(uint256,uint256)' "$J" "$ID_A" "$THIRD" 2>&1)
  set -e
  note "m1b. purseWeights refuses a bad pair" \
    "purseWeights($J, $ID_A, $THIRD) (the leader plus the UNRANKED third) reverts: $(echo "$BADPAIR" | tr '\n' ' ' | cut -c1-160)"

  # (m2) deployAncestor(j, amount, idA, idB): the keeper delivers parent tokens and is paid the
  # TWAP value + the bounty out of generation j's own ETH sleeve; the parent tokens are split
  # between the two ranked siblings and locked as bids under each.
  CLAIMJ=$(vnum 'claimableEth(uint256)(uint256)' "$J"); DRAWJ=$(vnum 'drawableEth(uint256)(uint256)' "$J")
  MAXP=$(dnum 'maxParentForDeploy(uint256)(uint256)' "$J"); CAPJ=$(dnum 'bidCap(uint256)(uint256)' "$J")
  AMT=$(bmin "$MAXP" "$CAPJ" "$(bal_tok "$PARENT")")
  echo "   claimableEth($J)=$CLAIMJ drawableEth($J)=$DRAWJ maxParentForDeploy=$MAXP bidCap=$CAPJ -> amount=$AMT"
  if [ "${AMT:-0}" = "0" ]; then
    note "m2. deployAncestor($J)" "SKIPPED: sizing is zero (claimableEth=$CLAIMJ drawableEth=$DRAWJ maxParentForDeploy=$MAXP bidCap=$CAPJ)"
  else
    approve_max "m2a. approve #$((J - 1)) -> BidDeployer" "$PARENT" "$BID_DEPLOYER"
    TOK_A=$(cand_field "$ID_A" $CAND_TOKEN_F); TOK_B=$(cand_field "$ID_B" $CAND_TOKEN_F)
    TOK_C=$(cand_field "$THIRD" $CAND_TOKEN_F)
    LA0=$($CALL "$POOL_MANAGER" 'balanceOf(address,uint256)(uint256)' "$LOCKER" 0 | awk '{print $1}')
    PB_A=$(bal_tok "$TOK_A"); PARENT_BEFORE=$(bal_tok "$PARENT"); ETH_BEFORE=$(bal_eth)
    # the size cap is enforced PER TARGET POOL, on that pool's own book, so a split can exceed a
    # sibling's cap where the whole amount would have fit the canonical pool: halve and retry
    OK=1
    for try in 1 2 3 4 5; do
      try_send "m2. deployAncestor($J)" "$BID_DEPLOYER" 'deployAncestor(uint256,uint256,uint256,uint256)' "$J" "$AMT" "$ID_A" "$ID_B"
      if [ "$TRY_RC" = "0" ]; then OK=0; break; fi
      echo "   deployAncestor at amount=$AMT failed ($(echo "$TRY_OUT" | tail -1 | cut -c1-120)); halving"
      AMT=$(python -c "import sys;print(int(sys.argv[1])//2)" "$AMT")
      [ "$AMT" = "0" ] && break
    done
    if [ "$OK" != "0" ]; then
      note "m2. deployAncestor($J)" "FAILED at every size tried: $(echo "$TRY_OUT" | tail -2 | tr '\n' ' ' | cut -c1-200)"
    else
      log "m2. deployAncestor($J, $AMT, $ID_A, $ID_B)" "$TXHASH" "$GASUSED" \
        "THE PURSE IS SPLIT: keeper delivered $(bsub "$PARENT_BEFORE" "$(bal_tok "$PARENT")") of #$((J - 1)) and was paid $(bsub "$(bal_eth)" "$ETH_BEFORE") wei net of gas out of generation $J's own sleeve (claimableEth=$CLAIMJ, drawableEth=$DRAWJ); PurseSplit(idA=$ID_A, idB=$ID_B) weights $WA:$WB; bids locked under sibling $TOK_A and sibling $TOK_B; the third sibling $TOK_C received NOTHING"
      note "m2b. PurseSplit event" "$(cast receipt "$TXHASH" --rpc-url "$RPC" --json | jq -r --arg t "$(cast keccak 'PurseSplit(uint256,uint256,uint256,uint256,uint256)')" '[.logs[] | select(.topics[0] == $t)] | .[0] | "topics=\(.topics) data=\(.data)"' 2>/dev/null || echo 'not decoded')"
    fi
  fi

  # (m3) the genesis bid, which also sweeps the forfeited bonds of five rounds
  EARMARK=$(vnum 'genesisBidEarmark()(uint256)')
  try_send "m3. deployGenesisBid(0)" "$BID_DEPLOYER" 'deployGenesisBid(uint256)' 0
  if [ "$TRY_RC" = "0" ]; then
    log "m3. deployGenesisBid(0)" "$TXHASH" "$GASUSED" \
      "forfeited bonds + the genesis hop pot deployed as a locked ETH bid: genesisBidEarmark $EARMARK -> $(vnum 'genesisBidEarmark()(uint256)')"
  else
    note "m3. deployGenesisBid(0)" "skipped/failed: $(echo "$TRY_OUT" | tail -1 | cut -c1-160)"
  fi
fi

# ---- summary -------------------------------------------------------------------------------------
ETH_END=$(bal_eth)
{
  echo
  echo "Run 6 complete. Deployer ETH: $ETH_START -> $ETH_END wei (net spent $(bsub "$ETH_START" "$ETH_END") wei)."
  for row in "${ROUND_SUMMARY[@]}"; do echo "- $row"; done
  echo "Head is \`$(head_token)\` at canonical index $(head_index); purse generation $PURSE_GEN, siblings ${PURSE_IDS[*]:-none}."
} >> "$RUNLOG"
printf '== done: net spent %s wei, head=%s idx=%s ==\n' "$(bsub "$ETH_START" "$ETH_END")" "$(head_token)" "$(head_index)"
for row in "${ROUND_SUMMARY[@]}"; do echo "   $row"; done
