#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# run7.sh - drive the trader side of a live run and leave every round END to the keeper.
#
#   ./script/live/run7.sh --live    against RPC_TESTNET, waiting on the real clock
#   ./script/live/run7.sh --fork    against a local anvil fork, warping the clock
#
# HOW THIS DIFFERS FROM run6.sh, AND WHY
#
# run6.sh drove the whole mechanism from one script: it registered, traded, AND called
# `requestEnd`, `fulfilEnd`, `submitScore`, `finalize`, `rank` and `deployAncestor` itself. That
# proved the mechanism, but it proved nothing about the thing a real deployment depends on - that
# NOBODY has to press those buttons. Every one of those calls is permissionless, and the keeper
# service (`keeper/keeper.mjs`) exists to make them for free.
#
# So this driver does ONLY what a user does:
#
#   a.  buy genesis (and a second, spaced buy so the genesis pool has two oracle observations)
#   b.  register candidates                        -> this is what opens a round
#   d.  trade them: a buy each, one SELL out to ETH, and a spaced second buy per pool
#   w.  WAIT, and watch the chain settle itself
#
# It never calls requestEnd, fulfilEnd, finalizeDeterministic, submitScore, finalize, rank or
# deployAncestor. `await_keeper` below only READS `roundInfo`, once every POLL_S seconds, and
# writes down when each transition it sees actually happened. If the keeper is not running, or
# has run out of gas, this driver simply times out and says so - which is exactly the honest
# outcome, because a chain that nobody keeps does not move.
#
# THE ONE COLLISION TO KNOW ABOUT. On a testnet run the keeper is usually given the SAME key as
# the driver (there is only one funded wallet), so two senders share one nonce. The keeper acts
# at the published end T and, with ENABLE_PURSE=1, again just after a round finalizes - which is
# exactly when this driver registers the next round. `send` therefore RETRIES a send that failed
# with a nonce/replacement error (those never reach the chain), and `keeper_quiet` waits for the
# keeper's log to go idle before the driver takes its turn. On a real deployment the keeper has
# its own wallet and neither is needed.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

MODE="${1:---fork}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

CHAIN_ID=46630
# PRIVACY: live addresses, tx hashes and the deployer address stay OUT of the tracked tree, so
# the deployment record and this driver's log live under `private/` (gitignored) when it exists.
DEFAULT_DEPLOY_JSON="deployments/${CHAIN_ID}.json"
[ -f "private/deployments/${CHAIN_ID}.json" ] && DEFAULT_DEPLOY_JSON="private/deployments/${CHAIN_ID}.json"
DEPLOY_JSON="${DEPLOY_JSON:-$DEFAULT_DEPLOY_JSON}"
RUNLOG="${RUNLOG:-private/TESTNET_RUN.md}"
EXPLORER="https://explorer.testnet.chain.robinhood.com/tx"
# the keeper's JSON log, read only to tell whether it is mid-transaction (see keeper_quiet)
KEEPER_LOG="${KEEPER_LOG:-}"

case "$MODE" in
  --live) RPC="$RPC_TESTNET"; KEY="$DEPLOYER_PRIVATE_KEY"; ME="$DEPLOYER_ADDRESS" ;;
  --fork)
    RPC="${FORK_RPC:-http://127.0.0.1:8545}"
    KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ME="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    ;;
  *) echo "usage: $0 [--live|--fork]" >&2; exit 2 ;;
esac

GAS_PRICE=10000000                       # 0.01 gwei, legacy pricing (this chain's basefee)
SEND="cast send --rpc-url $RPC --private-key $KEY --legacy --gas-price $GAS_PRICE"
CALL="cast call --rpc-url $RPC"
MAXU=115792089237316195423570985008687907853269984665640564039457584007913129639935

# ---- deployment addresses --------------------------------------------------------------------
j() { jq -r "$1" "$DEPLOY_JSON"; }
FACTORY=$(j .factory); HOOK=$(j .hook); ROUND_MANAGER=$(j .roundManager)
FEE_VAULT=$(j .feeVault); ROUTER=$(j .router); BID_DEPLOYER=$(j .bidDeployer)
GENESIS=$(j .genesisToken); GENESIS_POOL=$(j .genesisPoolId)
RANDOMNESS=$(j '.randomnessSource // .constants.randomnessSource')

# ---- budget ----------------------------------------------------------------------------------
# Everything that leaves the key: one genesis buy (the only real capital in the run), a tiny
# second genesis buy for the oracle, the bonds, and gas. Bonds come back for the winners; the
# losers' forfeit into the genesis earmark. NOTE the keeper pays its own gas out of the same
# wallet on a shared-key testnet run, which is why GAS_BUDGET_ETH is larger here than in run 6.
SKIP_GENESIS=${SKIP_GENESIS:-0}
START_ROUND=${START_ROUND:-1}
LAST_ROUND=${LAST_ROUND:-3}
GENESIS_BUY_ETH=${GENESIS_BUY_ETH:-0.03}
SECOND_BUY_ETH=${SECOND_BUY_ETH:-0.0005}
GAS_BUDGET_ETH=${GAS_BUDGET_ETH:-0.004}
BUDGET_CAP_ETH=${BUDGET_CAP_ETH:-0.06}
DEPLOY_COST_ETH=${DEPLOY_COST_ETH:-0.00032}
SELL_BPS=${SELL_BPS:-500}                # of the seller's candidate holding
POLL_S=${POLL_S:-5}                      # how often await_keeper re-reads the round
KEEPER_SLACK_S=${KEEPER_SLACK_S:-420}    # grace on top of END_TIMEOUT + SUBMIT_S before giving up

# ---- helpers ---------------------------------------------------------------------------------
hex2dec() { cast to-dec "$1" 2>/dev/null || echo 0; }
bsub() { python -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$1" "$2"; }
badd() { python -c "import sys;print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
bmul() { python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2]))" "$1" "$2"; }
bbps() { python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2])//10000)" "$1" "$2"; }
bge()  { python -c "import sys;sys.exit(0 if int(sys.argv[1])>=int(sys.argv[2]) else 1)" "$1" "$2"; }
wei()  { cast to-wei "$1"; }

explorer_cell() { [ "$MODE" = "--live" ] && printf '[tx](%s/%s)' "$EXPLORER" "$1" || printf 'anvil fork - not on chain'; }
log() { # log <step> <txhash> <gas> <effect>
  printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$(explorer_cell "$2")" "$3" "$4" >> "$RUNLOG"
  printf '>> %-40s tx=%s gas=%s\n   %s\n' "$1" "$2" "$3" "$4"
}
note() { printf '| %s | - | - | - | %s |\n' "$1" "$2" >> "$RUNLOG"; printf '>> %-40s %s\n' "$1" "$2"; }
fail() {
  printf '| %s | `%s` | - | - | **FAILED**: %s |\n' "$1" "$2" "$3" >> "$RUNLOG"
  echo "!! STEP FAILED: $1: $3" >&2
  exit 1
}
check() { [ "$1" = "0" ] || fail "$2" "-" "$3"; }

# `send` retries a send that never reached the chain. A shared-key run races the keeper for the
# nonce; those errors are recognisable and the transaction provably did not land, so a retry is
# safe. Anything else fails the run rather than being resent blindly.
send() { # send <label> <to> <sig> [args...]; extra cast flags via $EXTRA
  local label="$1"; shift
  local out rc attempt
  for attempt in 1 2 3 4 5 6; do
    set +e
    out=$($SEND ${EXTRA:-} "$@" --json 2>&1); rc=$?
    set -e
    if [ $rc -eq 0 ]; then break; fi
    if echo "$out" | grep -qiE 'nonce|replacement|already known|mempool|underpriced'; then
      echo "   $label: nonce race with the keeper (attempt $attempt), retrying in 8 s"
      sleep 8; continue
    fi
    fail "$label" "-" "$(echo "$out" | tail -3 | tr '\n' ' ')"
  done
  [ $rc -eq 0 ] || fail "$label" "-" "still racing after 6 attempts: $(echo "$out" | tail -2 | tr '\n' ' ')"
  TXHASH=$(echo "$out" | jq -r .transactionHash)
  GASUSED=$(hex2dec "$(echo "$out" | jq -r .gasUsed)")
  [ "$(echo "$out" | jq -r .status)" = "0x1" ] || fail "$label" "$TXHASH" "reverted on chain"
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

# Wait for the keeper to finish whatever it is doing, so the driver's next transaction does not
# race it for the shared nonce. A keeper with nothing to do writes "action":"none" every tick.
keeper_quiet() {
  if [ -z "$KEEPER_LOG" ] || [ ! -f "$KEEPER_LOG" ]; then sleep 3; return 0; fi
  local i
  for i in $(seq 1 40); do
    if tail -2 "$KEEPER_LOG" | grep -q '"action":"none"'; then return 0; fi
    sleep 3
  done
  echo "   (keeper still busy after 120 s; proceeding - send() will retry a nonce race)"
}

bal_eth()  { cast balance "$ME" --rpc-url "$RPC"; }
bal_tok()  { $CALL "$1" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}'; }
round_id() { $CALL "$ROUND_MANAGER" 'roundCount()(uint256)' | awk '{print $1}'; }
cand_count(){ $CALL "$ROUND_MANAGER" 'candidateCount()(uint256)' | awk '{print $1}'; }
head_index(){ $CALL "$ROUND_MANAGER" 'headIndex()(uint256)' | awk '{print $1}'; }
head_token(){ $CALL "$ROUND_MANAGER" 'head()(address)' | awk '{print $1}'; }
threshold() { $CALL "$ROUND_MANAGER" 'threshold()(uint256)' | awk '{print $1}'; }
current_bond() { $CALL "$ROUND_MANAGER" 'currentBond()(uint256)' | awk '{print $1}'; }
bond_for()  { $CALL "$ROUND_MANAGER" 'bondFor(uint256)(uint256)' "$1" | awk '{print $1}'; }
obs()       { $CALL "$HOOK" 'observationCount(bytes32)(uint256)' "$1" | awk '{print $1}'; }

# REVIEW 2 Round struct: 1 openedAt, 2 registrationEnd, 3 tradingStart, 4 lateEntryEnd,
# 5 nominalEnd, 6 tradingEnd, 7 submitEnd, 8 finalized, 9 hasWinner, 10 hasBest,
# 11 endRequested (NEW: run 6 had to infer it from randomId), 12 randomId, 13 hUsed, 14 bondWei,
# 15 parentIndex, 16 parentToken, 17 candidateCount, 18 bestCandidateId, 19 winnerCandidateId,
# 20 bestAvg, 21 bestAttained, 22 bestPoolId
ROUND_SIG='roundInfo(uint256)((uint64,uint64,uint64,uint64,uint64,uint64,uint64,bool,bool,bool,bool,bytes32,uint256,uint256,uint256,address,uint256,uint256,uint256,int256,uint64,bytes32))'
round_field() { $CALL "$ROUND_MANAGER" "$ROUND_SIG" "$1" | tr -d '()' | tr ',' '\n' | sed -n "$2p" \
                  | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
R_REGEND_F=2; R_TSTART_F=3; R_LATE_F=4; R_NOMEND_F=5; R_TEND_F=6; R_SUBEND_F=7
R_FINAL_F=8; R_HASWIN_F=9; R_ENDREQ_F=11; R_RANDID_F=12; R_BOND_F=14; R_WINNER_F=19

CAND_SIG='candidateInfo(uint256)((uint256,address,address,uint256,bool,uint64,int256,uint64,(address,address,uint24,int24,address)))'
cand_field() { $CALL "$ROUND_MANAGER" "$CAND_SIG" "$1" | tr -d '()' | cut -d',' -f"$2" | tr -d ' ' | sed -E 's/\[[^]]*\]//g'; }
CAND_TOKEN_F=2; CAND_SUBMITTED_F=5; CAND_TSTART_F=6; CAND_AVG_F=7
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

# ---- projected cost, and the hard abort ------------------------------------------------------
# The projection covers what is STILL TO COME, not what a full run would have cost: a resumed
# driver (SKIP_GENESIS=1, START_ROUND=n) has already paid for the genesis position and for the
# rounds behind it, and its remaining balance is smaller by exactly that. Projecting the whole run
# against a mid-run balance aborts a resume that is comfortably inside budget - which is what the
# first resume of this run did.
H_IDX=$(head_index)
BONDS_TOTAL=0
for k in $(seq "$START_ROUND" "$LAST_ROUND"); do
  N=2; [ "$k" = 3 ] && N=3
  BONDS_TOTAL=$(badd "$BONDS_TOTAL" "$(bmul "$N" "$(bond_for $((H_IDX + 1 + k - START_ROUND)))")")
done
G_BUY=0; G_BUY2=0
if [ "$SKIP_GENESIS" != "1" ]; then G_BUY=$(wei "$GENESIS_BUY_ETH"); G_BUY2=$(wei "$SECOND_BUY_ETH"); fi
PROJ=$(badd "$G_BUY" "$G_BUY2" "$BONDS_TOTAL" "$(wei "$GAS_BUDGET_ETH")")
CAP=$(wei "$BUDGET_CAP_ETH")
echo "== projected REMAINING gross ETH cost (run 7, rounds $START_ROUND..$LAST_ROUND) =="
printf '   %-34s %s\n' "genesis buy" "$G_BUY"
printf '   %-34s %s\n' "genesis 2nd (oracle) buy" "$G_BUY2"
printf '   %-34s %s\n' "bonds" "$BONDS_TOTAL"
printf '   %-34s %s\n' "gas (driver AND keeper)" "$(wei "$GAS_BUDGET_ETH")"
printf '   %-34s %s wei = %s ETH\n' "REMAINING TOTAL" "$PROJ" "$(cast from-wei "$PROJ")"
printf '   %-34s %s wei (deploy was %s)\n' "whole-run cap" "$CAP" "$(wei "$DEPLOY_COST_ETH")"
if bge "$PROJ" "$CAP" && [ "$PROJ" != "$CAP" ]; then
  echo "!! ABORT: projected $PROJ wei exceeds the $CAP wei cap" >&2; exit 3
fi

# ---- start -----------------------------------------------------------------------------------
mkdir -p "$(dirname "$RUNLOG")"
[ -f "$RUNLOG" ] || echo "# Testnet run log (chain $CHAIN_ID) - PRIVATE, not for the tracked tree" > "$RUNLOG"
{
  echo
  echo "## Run 7 driver - KEEPER-DRIVEN ($MODE) - started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "| step | tx hash | explorer | gas used | observed effect |"
  echo "|---|---|---|---|---|"
} >> "$RUNLOG"

ETH_START=$(bal_eth)
echo "== balance $(cast from-wei "$ETH_START") ETH =="
bge "$ETH_START" "$PROJ" || { echo "!! ABORT: balance below the projection" >&2; exit 3; }

SCALE=$($CALL "$ROUND_MANAGER" 'DURATION_SCALE_DIV()(uint64)' | awk '{print $1}')
ENDTO=$($CALL "$ROUND_MANAGER" 'END_TIMEOUT()(uint64)' | awk '{print $1}')
SUBS=$($CALL "$ROUND_MANAGER" 'SUBMIT_S()(uint64)' | awk '{print $1}')
d() { $CALL "$ROUND_MANAGER" "$1" "${2:-}" | awk '{print $1}'; }
note "schedule (DURATION_SCALE_DIV=$SCALE)" \
  "durationFor(1..4)=$(d 'durationFor(uint256)(uint64)' 1)/$(d 'durationFor(uint256)(uint64)' 2)/$(d 'durationFor(uint256)(uint64)' 3)/$(d 'durationFor(uint256)(uint64)' 4) s, registrationFor(1/3)=$(d 'registrationFor(uint256)(uint64)' 1)/$(d 'registrationFor(uint256)(uint64)' 3) s, lateEntryUntil(1/3)=$(d 'lateEntryUntil(uint256)(uint64)' 1)/$(d 'lateEntryUntil(uint256)(uint64)' 3) s (0 = no late entry until D >= 1 h unscaled, i.e. round 5), closingWindowFor(1/3)=$(d 'closingWindowFor(uint256)(uint64)' 1)/$(d 'closingWindowFor(uint256)(uint64)' 3) s, randomEndWindowFor(1/3)=$(d 'randomEndWindowFor(uint256)(uint64)' 1)/$(d 'randomEndWindowFor(uint256)(uint64)' 3) s = max(1, min(RANDOM_END_S=180, D/4)), REVIEW 2's quarter-duration clamp: a heavily scaled round can no longer draw its end at or before tradingStart, SUBMIT_S=$SUBS s, END_TIMEOUT=$ENDTO s, randomness=$RANDOMNESS"

# ---- (a) buy genesis ---------------------------------------------------------------------------
if [ "$SKIP_GENESIS" = "1" ]; then
  note "a/a2. genesis buys SKIPPED (resume mode)" \
    "this deployment already holds its genesis position and its genesis pool has $(obs "$GENESIS_POOL") oracle observations (>= 2 is a precondition of every keeper path); head is #$(head_index)"
else
  TOK0=$(bal_tok "$GENESIS")
  EXTRA="--value ${GENESIS_BUY_ETH}ether"
  send "a. buy genesis" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
  EXTRA=""
  T_GENESIS_BUY=$(now_ts)
  log "a. buy genesis ${GENESIS_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
    "received $(bsub "$(bal_tok "$GENESIS")" "$TOK0") FAM0 (wei-tokens); the only real capital in the run"
  wait_until $((T_GENESIS_BUY + 130)) "genesis buy + 130 s (OBS_MIN_SPACING is 120 s)"
  EXTRA="--value ${SECOND_BUY_ETH}ether"
  send "a2. genesis oracle buy" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
  EXTRA=""
  log "a2. genesis oracle buy ${SECOND_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
    "genesis pool observationCount=$(obs "$GENESIS_POOL") (>= 2 is a precondition of every keeper path)"
fi

# ---- watching the keeper -----------------------------------------------------------------------
# The ONLY thing this function does is read. It records WHEN each transition it is waiting for was
# first visible on chain, which is what the run's evidence table is built from.
declare -a ROUND_SUMMARY=()
await_keeper() { # await_keeper <rid> <n> <t_nom> <id...>
  local rid="$1" n="$2" t_nom="$3"; shift 3
  local ids=("$@") ncand=$#
  local deadline=$((t_nom + ENDTO + SUBS + KEEPER_SLACK_S))
  local t_req=0 t_settled=0 t_final=0 seen_sub=0
  local endreq tend fin now rid_hex
  T_END=0
  echo "== round $rid: the driver is DONE. Watching the keeper until $deadline (T + $((deadline - t_nom)) s) =="
  while :; do
    now=$(now_ts)
    if [ "$t_req" = "0" ]; then
      endreq=$(round_field "$rid" $R_ENDREQ_F)
      if [ "$endreq" = "true" ]; then
        t_req=$now
        rid_hex=$(round_field "$rid" $R_RANDID_F)
        note "r$n.w keeper requestEnd SEEN" \
          "endRequested=true first seen at $t_req = T + $((t_req - t_nom)) s; randomId=$rid_hex -> drand evmnet round $($CALL "$RANDOMNESS" 'roundOf(bytes32)(uint64)' "$rid_hex" | awk '{print $1}'). THE DRIVER DID NOT SEND THIS."
      fi
    fi
    if [ "$t_settled" = "0" ]; then
      tend=$(round_field "$rid" $R_TEND_F)
      if [ "$tend" != "0" ]; then
        t_settled=$now; T_END="$tend"
        local win; win=$($CALL "$ROUND_MANAGER" 'randomEndWindowFor(uint256)(uint64)' "$rid" | awk '{print $1}')
        check "$([ "$tend" -le "$t_nom" ] && [ "$tend" -ge $((t_nom - win)) ] && echo 0 || echo 1)" \
          "r$n T_end window" "T_end=$tend is outside [T-$win, T]"
        note "r$n.w keeper settled the end SEEN" \
          "tradingEnd=$tend first seen at $t_settled; T=$t_nom, T_end=$tend, offset = $((t_nom - tend)) s, window = $win s: T-$win <= T_end <= T HOLDS. submitEnd=$(round_field "$rid" $R_SUBEND_F). THE DRIVER DID NOT SEND THIS."
      fi
    fi
    if [ "$t_settled" != "0" ] && [ "$seen_sub" -lt "$ncand" ]; then
      local c k=0
      for c in "${ids[@]}"; do [ "$(cand_field "$c" $CAND_SUBMITTED_F)" = "true" ] && k=$((k + 1)); done
      if [ "$k" -gt "$seen_sub" ]; then
        seen_sub=$k
        note "r$n.w keeper submitScore SEEN ($k/$ncand)" \
          "$k of $ncand candidates carry a score at $now (T + $((now - t_nom)) s). THE DRIVER DID NOT SEND THESE."
      fi
    fi
    fin=$(round_field "$rid" $R_FINAL_F)
    if [ "$fin" = "true" ]; then t_final=$now; break; fi
    if [ "$now" -ge "$deadline" ]; then
      note "r$n.w KEEPER TIMED OUT" \
        "round $rid was not finalized by $deadline (T + $((deadline - t_nom)) s, i.e. END_TIMEOUT=$ENDTO + SUBMIT_S=$SUBS + $KEEPER_SLACK_S s of slack). endRequested=$(round_field "$rid" $R_ENDREQ_F) tradingEnd=$(round_field "$rid" $R_TEND_F) finalized=false. The driver did NOT intervene."
      fail "r$n.w await keeper" "-" "keeper did not finalize round $rid within the deadline"
    fi
    sleep "$POLL_S"
  done
  local hidx haswin
  hidx=$(head_index); haswin=$(round_field "$rid" $R_HASWIN_F)
  note "r$n.w keeper finalize SEEN" \
    "finalized=true first seen at $t_final = T + $((t_final - t_nom)) s; hasWinner=$haswin winnerCandidateId=$(round_field "$rid" $R_WINNER_F); headIndex now $hidx, head=$(head_token); threshold now $(threshold). THE DRIVER DID NOT SEND THIS."
  ROUND_SUMMARY+=("round $rid (n=$n): T=$t_nom T_end=$T_END (T-$((t_nom - T_END))s) | keeper requestEnd +$((t_req - t_nom))s, settled +$((t_settled - t_nom))s, finalize +$((t_final - t_nom))s | hasWinner=$haswin head=#$hidx")
}

# ---- the round driver: registration and trading ONLY -------------------------------------------
run_round() { # run_round <n> <flavour> <bps...>   flavour: plain | obs2
  local n="$1" flavour="$2"; shift 2
  if [ "$n" -lt "$START_ROUND" ]; then echo ">> round $n skipped: START_ROUND=$START_ROUND"; return 0; fi
  local bps=("$@") ncand=$#
  local parent_idx parent_tok rid i letter bond
  keeper_quiet
  parent_idx=$(head_index); parent_tok=$(head_token)
  local -a ids=()

  # (1) registration - this is what OPENS the round
  for ((i = 0; i < ncand; i++)); do
    letter="R${n}-$((i + 1))"
    bond=$(current_bond)
    EXTRA="--value ${bond}wei"
    send "r$n.b register $letter" "$FACTORY" 'registerCandidate(string,string,string)' "$letter" "$letter" "ipfs://$letter"
    EXTRA=""
    ids+=("$(( $(cand_count) - 1 ))")
    log "r$n.b register $letter" "$TXHASH" "$GASUSED" \
      "candidateId=${ids[-1]}, bond $bond wei (currentBond() = bondFor($((parent_idx + 1)))), parent = #$parent_idx $parent_tok"
  done
  rid=$(round_id)
  local t_reg t_start t_late t_nom H
  t_reg=$(round_field "$rid" $R_REGEND_F); t_start=$(round_field "$rid" $R_TSTART_F)
  t_late=$(round_field "$rid" $R_LATE_F);  t_nom=$(round_field "$rid" $R_NOMEND_F)
  H=$(threshold)
  note "round $rid (n=$n) opened" \
    "registrationEnd=$t_reg tradingStart=$t_start nominalEnd(T)=$t_nom lateEntryEnd=$t_late (0 = no late entry at this duration); D=$((t_nom - t_start)) s, W=$($CALL "$ROUND_MANAGER" 'closingWindowFor(uint256)(uint64)' "$rid" | awk '{print $1}') s, H=$H, bondWei=$(round_field "$rid" $R_BOND_F)"

  # (2) trading
  wait_until $((t_start + 5)) "round $rid tradingStart + 5 s (past the 3 s snipe tax)"
  approve_max "r$n.d0 approve #$parent_idx -> router" "$parent_tok" "$ROUTER"
  local p0 amt ctok cb
  p0=$(bal_tok "$parent_tok")
  for ((i = 0; i < ncand; i++)); do
    ctok=$(cand_field "${ids[$i]}" $CAND_TOKEN_F)
    amt=$(bbps "$p0" "${bps[$i]}")
    cb=$(bal_tok "$ctok")
    send "r$n.d buy id${ids[$i]}" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "${ids[$i]}" "$amt" 0 "$ME"
    log "r$n.d buy id${ids[$i]} (${bps[$i]} bps of the #$parent_idx holding)" "$TXHASH" "$GASUSED" \
      "spent $amt of #$parent_idx -> received $(bsub "$(bal_tok "$ctok")" "$cb") candidate tokens (single hop, attributed)"
  done

  # (2b) ONE SELL. A round with only buys never exercises the sell side: the fee split, the
  # oracle and the round's own scoring all see a one-way book otherwise.
  #
  # `sellCandidate` ALWAYS walks the whole way out - candidate -> #parentIndex -> ... -> #0 -> ETH
  # - and `maxHops` is a CAP on that path, not a place to stop early (FamilyRouter: `if
  # (path.length > maxHops) revert TooManyHops()`). The path is `parentIndex + 2` long, so the cap
  # has to be at least that; asking for one hop reverts `TooManyHops`, which is exactly what the
  # first attempt of this run did. The proceeds are ETH, and the whole route is attributed.
  local last=${ids[-1]} eb
  ctok=$(cand_field "$last" $CAND_TOKEN_F)
  approve_max "r$n.s0 approve candidate id$last -> router" "$ctok" "$ROUTER"
  amt=$(bbps "$(bal_tok "$ctok")" "$SELL_BPS")
  eb=$(bal_eth)
  send "r$n.s sell id$last" "$ROUTER" 'sellCandidate(uint256,uint256,uint256,address,uint256)' "$last" "$amt" 0 "$ME" $((parent_idx + 2))
  log "r$n.s SELL id$last ($SELL_BPS bps of the holding)" "$TXHASH" "$GASUSED" \
    "sold $amt candidate tokens out through #$parent_idx .. #0 into ETH (path length $((parent_idx + 2)), attributed); wallet ETH moved $(bsub "$(bal_eth)" "$eb") wei, net of the gas this very transaction paid"

  # (2c) a second, spaced buy per candidate, so every sibling pool carries the two oracle
  # observations a bid target needs - and so the keeper's `rank` has something to read
  if [ "$flavour" = "obs2" ]; then
    wait_until $((t_start + 130)) "round $rid tradingStart + 130 s (second observation per sibling)"
    for ((i = 0; i < ncand; i++)); do
      amt=$(bbps "$p0" 200)
      send "r$n.d2 top-up id${ids[$i]}" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "${ids[$i]}" "$amt" 0 "$ME"
      log "r$n.d2 second buy id${ids[$i]} (200 bps)" "$TXHASH" "$GASUSED" \
        "second swap > 120 s after the first: sibling pool observationCount=$(obs "$(cand_pool_id "${ids[$i]}")") (a bid target needs >= 2)"
    done
  fi

  # (3) hands off. Everything from here is the keeper's.
  await_keeper "$rid" "$n" "$t_nom" "${ids[@]}"
}

run_round 1 plain 4000 2500
run_round 2 plain 4000 2500
run_round 3 obs2  4000 2500 1200

# ---- summary -------------------------------------------------------------------------------------
ETH_END=$(bal_eth)
{
  echo
  echo "Run 7 complete (driver side). Wallet ETH: $ETH_START -> $ETH_END wei (net $(bsub "$ETH_START" "$ETH_END") wei, BOTH senders - the keeper shares the key on a testnet run)."
  for row in "${ROUND_SUMMARY[@]}"; do echo "- $row"; done
  echo "Head is \`$(head_token)\` at canonical index $(head_index). Every round end was settled by the keeper; this driver sent no requestEnd, fulfilEnd, submitScore, finalize, rank or deployAncestor."
} >> "$RUNLOG"
printf '== done: net %s wei, head=%s idx=%s ==\n' "$(bsub "$ETH_START" "$ETH_END")" "$(head_token)" "$(head_index)"
for row in "${ROUND_SUMMARY[@]}"; do echo "   $row"; done
