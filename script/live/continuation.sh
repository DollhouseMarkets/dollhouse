#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# continuation.sh - drive a COMPLETE cross-version handover between two live deployments.
#
#   ./script/live/continuation.sh --live <v1.json> <v2.json> [<throwaway.json>]
#   ./script/live/continuation.sh --fork <v1.json> <v2.json> [<throwaway.json>]
#
# This is the half of the protocol that runs 1 and 2 never touched: `announceSunset`,
# `cancelSunset`, lazy head adoption, the ETH-edge handover (in-swap forward, queue, flush) and
# the two cross-version payout paths. Everything here is READ OFF THE CHAIN and asserted; no step
# is reported as exercised unless its own effect was observed.
#
# The order below is forced by the contracts, not by taste:
#
#  1. `announceSunset(successor)` may only be called by the steward, once, and only on a
#     deployment that is a root or has itself adopted. It does NOT stop the open round - it stops
#     the version from opening a NEW one, `sunsetDelay` seconds later. On this deployment the
#     delay is 3600 s (the contract floor is 1 hour), so the wait is real but affordable.
#  2. A continuation may not open a round until `_adoptIfContinuation` passes: the prior must be
#     sunset-EFFECTIVE, must name this contract as its successor, and must be IDLE. So v1's
#     round 2 has to have been finalized before this script starts (round.sh does that now).
#  3. v2 has NO ETH-paired pool of its own: the ETH edge is still charged by v1's hook on the
#     genesis pool. After the sunset that fee is FORWARDED to v2's vault - inside the swap when
#     the gas budget allows (FeeVault.FORWARD_GAS = 6M above a 1.5M reserve), otherwise queued in
#     `pendingForward[attribution]` for a permissionless `flushForward`. Both branches are
#     exercised here: a normal buy, then a deliberately gas-starved one.
#  4. Generation 1's ETH sleeve in v2 can therefore only be filled by a forwarded, ATTRIBUTED
#     edge whose terminal index is 2 (M = terminalIndex - 1 = 1) or by a candidate trade in a
#     round whose parentIndex is 1. That is what funds v2's `deployAncestor(1, ...)`, whose bid
#     belongs in a V1 POOL and is therefore placed through v1's own BidDeployer
#     (`depositExternalBid`) - the cross-version payout path.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

MODE="${1:---fork}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

V1_JSON="${2:-deployments/46630.run3-v1.json}"
V2_JSON="${3:-deployments/46630.run3-v2.json}"
V3_JSON="${4:-}"

CHAIN_ID=46630
RUNLOG="${RUNLOG:-docs/TESTNET_RUN.md}"
EXPLORER="https://explorer.testnet.chain.robinhood.com/tx"

case "$MODE" in
  --live)
    RPC="$RPC_TESTNET"; KEY="$DEPLOYER_PRIVATE_KEY"; ME="$DEPLOYER_ADDRESS"
    ;;
  --fork)
    RPC="${FORK_RPC:-http://127.0.0.1:8545}"
    KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ME="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    ;;
  *) echo "usage: $0 [--live|--fork] <v1.json> <v2.json> [<throwaway.json>]" >&2; exit 2 ;;
esac

GAS_PRICE=10000000
GASFLAGS="--legacy --gas-price $GAS_PRICE"
SEND="cast send --rpc-url $RPC --private-key $KEY $GASFLAGS"
CALL="cast call --rpc-url $RPC"
MAXU=115792089237316195423570985008687907853269984665640564039457584007913129639935

v1() { jq -r "$1" "$V1_JSON"; }
v2() { jq -r "$1" "$V2_JSON"; }
V1_RM=$(v1 .roundManager); V1_VAULT=$(v1 .feeVault); V1_BD=$(v1 .bidDeployer)
V1_ROUTER=$(v1 .router); V1_HOOK=$(v1 .hook); V1_LOCKER=$(v1 .locker); V1_LENS=$(v1 .lens)
GENESIS=$(v1 .genesisToken); GENESIS_POOL=$(v1 .genesisPoolId); POOL_MANAGER=$(v1 .poolManager)
V2_RM=$(v2 .roundManager); V2_VAULT=$(v2 .feeVault); V2_BD=$(v2 .bidDeployer)
V2_ROUTER=$(v2 .router); V2_FACTORY=$(v2 .factory); V2_HOOK=$(v2 .hook); V2_LOCKER=$(v2 .locker)
V2_LENS=$(v2 .lens)

# ---- sizing -----------------------------------------------------------------------------------
# The post-sunset genesis buy that proves the ETH edge now lands in v2's vault.
FWD_BUY_ETH=${FWD_BUY_ETH:-0.01}
# The same buy again with a starved gas limit, to force the QUEUE branch and then flush it.
QUEUE_BUY_ETH=${QUEUE_BUY_ETH:-0.002}
# The ETH -> #0 -> #1 -> #2 route across both versions. It is also the trade that funds
# generation 1's sleeve in v2 (attribution 2 -> M = 1), i.e. what pays for deployAncestor(1).
ROUTE_ETH=${ROUTE_ETH:-0.03}
GAS_BUDGET_ETH=${GAS_BUDGET_ETH:-0.0015}
BUDGET_CAP_ETH=${BUDGET_CAP_ETH:-0.09}

# ---- helpers (same conventions as round.sh) ---------------------------------------------------
hex2dec() { cast to-dec "$1" 2>/dev/null || echo 0; }
bsub() { python -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$1" "$2"; }
badd() { python -c "import sys;print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
bmin() { python -c "import sys;print(min(int(a) for a in sys.argv[1:]))" "$@"; }
bge()  { python -c "import sys;sys.exit(0 if int(sys.argv[1])>=int(sys.argv[2]) else 1)" "$1" "$2"; }
wei()  { cast to-wei "$1"; }
lc()   { echo "$1" | tr 'A-Z' 'a-z'; }

explorer_cell() { [ "$MODE" = "--live" ] && printf '[tx](%s/%s)' "$EXPLORER" "$1" || printf 'anvil fork - not on chain'; }
log() {
  printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$(explorer_cell "$2")" "$3" "$4" >> "$RUNLOG"
  printf '>> %-36s tx=%s gas=%s\n   %s\n' "$1" "$2" "$3" "$4"
}
note() { printf '| %s | - | - | - | %s |\n' "$1" "$2" >> "$RUNLOG"; printf '>> %-36s %s\n' "$1" "$2"; }
fail() {
  printf '| %s | `%s` | - | - | **FAILED**: %s |\n' "$1" "$2" "$3" >> "$RUNLOG"
  echo "!! STEP FAILED: $1: $3" >&2
  [ "$2" != "-" ] && cast run "$2" --rpc-url "$RPC" 2>&1 | tail -40 >&2 || true
  exit 1
}
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
# try_send - the same, but a revert is RECORDED and the driver continues. Used only for the two
# deliberately-marginal probes (the gas-starved swap, the flush that may have nothing to flush).
try_send() {
  local label="$1"; shift
  local out rc
  set +e
  out=$($SEND ${EXTRA:-} "$@" --json 2>&1); rc=$?
  set -e
  TRY_OK=0
  if [ $rc -ne 0 ]; then TRY_ERR=$(echo "$out" | tail -2 | tr '\n' ' '); return 0; fi
  TXHASH=$(echo "$out" | jq -r .transactionHash)
  GASUSED=$(hex2dec "$(echo "$out" | jq -r .gasUsed)")
  if [ "$(echo "$out" | jq -r .status)" != "0x1" ]; then TRY_ERR="reverted on chain ($TXHASH)"; return 0; fi
  TRY_OK=1
}
now_ts() { cast block latest --rpc-url "$RPC" -f timestamp; }
wait_until() {
  local target="$1" what="$2" now
  now=$(now_ts)
  if [ "$now" -ge "$target" ]; then echo "   (already past $what)"; return; fi
  if [ "$MODE" = "--fork" ]; then
    cast rpc evm_increaseTime $((target - now + 1)) --rpc-url "$RPC" >/dev/null
    cast rpc anvil_mine 1 --rpc-url "$RPC" >/dev/null
    echo "   warped to $what ($(now_ts))"
  else
    echo "   waiting $((target - now))s for $what ..."
    while [ "$(now_ts)" -lt "$target" ]; do sleep 15; done
    echo "   reached $what ($(now_ts))"
  fi
}
bal_eth() { cast balance "$ME" --rpc-url "$RPC"; }
bal_tok() { $CALL "$1" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}'; }
num()  { local a="$1"; shift; local s="$1"; shift; $CALL "$a" "$s" "$@" | awk '{print $1}'; }
addr() { local a="$1"; shift; local s="$1"; shift; $CALL "$a" "$s" "$@" | awk '{print $1}'; }
has_event() { local topic; topic=$(cast keccak "$2")
  cast receipt "$1" --rpc-url "$RPC" --json | jq -e --arg t "$topic" '[.logs[].topics[0]] | index($t) != null' >/dev/null; }
event_from() { # event_from <txhash> <sig> <address> -> true when that address emitted it
  local topic; topic=$(cast keccak "$2"); local a; a=$(lc "$3")
  cast receipt "$1" --rpc-url "$RPC" --json \
    | jq -e --arg t "$topic" --arg a "$a" '[.logs[] | select((.address|ascii_downcase)==$a) | .topics[0]] | index($t) != null' >/dev/null; }

# Pool/TWAP helpers, per VERSION (a prior version's pool must be read through ITS hook).
LINK_SIG='chainView(uint256,uint256)((uint256,address,address,address,bytes32,uint160,uint256,uint256,uint128)[])'
link_field() { $CALL "$V2_LENS" "$LINK_SIG" "$1" "$1" | sed -E 's/\[[0-9][^]]*\]//g' | tr -d '[]()' \
                 | awk -F',' -v n="$2" '{print $n}' | tr -d ' '; }
liq()  { link_field "$1" 9; }
spot() { link_field "$1" 6; }
hook_of() { [ "$1" -le 1 ] && echo "$V1_HOOK" || echo "$V2_HOOK"; }
pool_of() { $CALL "$V2_RM" 'poolIdOf(uint256)(bytes32)' "$1" | awk '{print $1}'; }
twap_of() { $CALL "$(hook_of "$1")" 'consult(bytes32,uint32)(uint160,uint32)' "$(pool_of "$1")" 1800 | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
slow_of() { $CALL "$(hook_of "$1")" 'consultSlow(bytes32,uint32)(uint160,uint32)' "$(pool_of "$1")" 604800 | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
obs_of()  { $CALL "$(hook_of "$1")" 'observationCount(bytes32)(uint256)' "$(pool_of "$1")" | awk '{print $1}'; }
band_ok() {
  local s t c
  s=$(spot "$1"); t=$(twap_of "$1" | sed -n 1p); c=$(twap_of "$1" | sed -n 2p)
  python -c "import sys
s,t,c=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
sys.exit(0 if c>=1800 and t and t*9700<=s*10000<=t*10300 else 1)" "$s" "$t" "$c"
}
wait_for_band() {
  local i
  for i in $(seq 1 16); do
    if band_ok "$1"; then echo "   link #$1 inside the TWAP band (attempt $i)"; return 0; fi
    echo "   link #$1 outside the +/-3% band (spot=$(spot "$1") twap=$(twap_of "$1" | tr '\n' '/')); waiting 150 s"
    wait_until $(( $(now_ts) + 150 )) "link #$1 TWAP convergence"
  done
  echo "   !! link #$1 still outside the band after 16 attempts" >&2
  return 1
}

# ---- preconditions ----------------------------------------------------------------------------
echo "== continuation driver ($MODE) =="
echo "   v1 roundManager $V1_RM  vault $V1_VAULT  bidDeployer $V1_BD"
echo "   v2 roundManager $V2_RM  vault $V2_VAULT  bidDeployer $V2_BD"
PRIOR=$(addr "$V2_RM" 'priorRegistry()(address)')
[ "$(lc "$PRIOR")" = "$(lc "$V1_RM")" ] || { echo "!! v2.priorRegistry=$PRIOR is not $V1_RM" >&2; exit 3; }
V1_IDLE=$(num "$V1_RM" 'isIdle()(bool)')
[ "$V1_IDLE" = "true" ] || { echo "!! v1 has an OPEN round; a continuation can never adopt from it" >&2; exit 3; }
V1_HEAD=$(addr "$V1_RM" 'head()(address)'); V1_HEAD_IDX=$(num "$V1_RM" 'headIndex()(uint256)')
echo "   v1 head #$V1_HEAD_IDX = $V1_HEAD, idle=$V1_IDLE"

BOND_V2=$(num "$V2_RM" 'currentBond()(uint256)')
PROJ=$(badd "$(wei "$FWD_BUY_ETH")" "$(wei "$QUEUE_BUY_ETH")" "$(wei "$ROUTE_ETH")" \
            "$(python -c "print(2*int('$BOND_V2'))")" "$(wei "$GAS_BUDGET_ETH")")
CAP=$(wei "$BUDGET_CAP_ETH")
echo "== projected gross ETH cost (phase B, deploys excluded) =="
printf '   %-34s %s\n' "post-sunset genesis buy" "$(wei "$FWD_BUY_ETH")"
printf '   %-34s %s\n' "gas-starved queue probe" "$(wei "$QUEUE_BUY_ETH")"
printf '   %-34s %s\n' "ETH -> #0 -> #1 -> #2 route" "$(wei "$ROUTE_ETH")"
printf '   %-34s %s\n' "2 x v2 bond (currentBond)" "$(python -c "print(2*int('$BOND_V2'))")"
printf '   %-34s %s\n' "gas headroom @ $GAS_PRICE wei/gas" "$(wei "$GAS_BUDGET_ETH")"
printf '   %-34s %s wei = %s ETH (cap %s)\n' "TOTAL" "$PROJ" "$(cast from-wei "$PROJ")" "$BUDGET_CAP_ETH"
if bge "$PROJ" "$CAP" && [ "$PROJ" != "$CAP" ]; then
  echo "!! ABORT: projected $PROJ wei exceeds the $CAP wei cap" >&2; exit 3
fi

ETH_START=$(bal_eth)
{
  echo
  echo "## Continuation / handover driver ($MODE) - started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "| step | tx hash | explorer | gas used | observed effect |"
  echo "|---|---|---|---|---|"
} >> "$RUNLOG"

# ---- (m) the throwaway stack: announce, then TAKE IT BACK ---------------------------------------
# `cancelSunset` is one-shot and only legal BEFORE `sunsetAt`, so it cannot be demonstrated on a
# deployment that is actually being handed over. A third, disposable stack is deployed for it.
if [ -n "$V3_JSON" ]; then
  V3_RM=$(jq -r .roundManager "$V3_JSON")
  echo "== throwaway stack $V3_RM: announce -> cancel =="
  send "m1. announceSunset (throwaway)" "$V3_RM" 'announceSunset(address)' "$V2_RM"
  V3_AT=$(num "$V3_RM" 'sunsetAt()(uint64)'); V3_SUC=$(addr "$V3_RM" 'successor()(address)')
  log "m1. announceSunset (THROWAWAY stack)" "$TXHASH" "$GASUSED" \
    "steward announced on the disposable stack $V3_RM: successor=$V3_SUC sunsetAt=$V3_AT isSunset()=$(num "$V3_RM" 'isSunset()(bool)') - announced only so that the take-back below has something to take back"
  send "m2. cancelSunset (throwaway)" "$V3_RM" 'cancelSunset()'
  log "m2. cancelSunset (F2 take-back)" "$TXHASH" "$GASUSED" \
    "sunsetAt $V3_AT -> $(num "$V3_RM" 'sunsetAt()(uint64)'), successor $V3_SUC -> $(addr "$V3_RM" 'successor()(address)'), sunsetCancelled=$(num "$V3_RM" 'sunsetCancelled()(bool)'), isSunset()=$(num "$V3_RM" 'isSunset()(bool)'); the one-shot escape hatch is spent - a second announce on this stack can never be cancelled"
else
  note "m. cancelSunset" "skipped: no throwaway deployment json passed"
fi

# ---- (n) v1 announces its sunset in favour of v2 -------------------------------------------------
STEWARD=$(addr "$V1_RM" 'steward()(address)')
[ "$(lc "$STEWARD")" = "$(lc "$ME")" ] || { echo "!! v1 steward is $STEWARD, not $ME" >&2; exit 3; }
DELAY=$(num "$V1_RM" 'sunsetDelay()(uint64)')
send "n. announceSunset(v2)" "$V1_RM" 'announceSunset(address)' "$V2_RM"
SUNSET_AT=$(num "$V1_RM" 'sunsetAt()(uint64)')
log "n. v1 announceSunset(v2 RoundManager)" "$TXHASH" "$GASUSED" \
  "steward $STEWARD named successor $(addr "$V1_RM" 'successor()(address)'); sunsetDelay=$DELAY s, sunsetAt=$SUNSET_AT, isSunset()=$(num "$V1_RM" 'isSunset()(bool)') RIGHT NOW - v1 still opens rounds until then; v2.adopted()=$(num "$V2_RM" 'adopted()(bool)') (adoption is lazy, at v2's first round)"

# a continuation may not open a round while the prior is still live - assert the refusal BEFORE
# the delay expires, since after it the same call must succeed
set +e
PREOPEN=$(cast call --rpc-url "$RPC" --from "$ME" --value "$BOND_V2" "$V2_FACTORY" \
  'registerCandidate(string,string,string)' "PRE" "PRE" "ipfs://PRE" 2>&1)
set -e
if echo "$PREOPEN" | grep -qi "PriorNotHandedOver\|0x$(cast keccak 'PriorNotHandedOver()' | cut -c3-10)"; then
  note "n2. v2 registerCandidate BEFORE sunsetAt" "refused with PriorNotHandedOver, as specified (eth_call, nothing sent)"
else
  note "n2. v2 registerCandidate BEFORE sunsetAt" "refused: $(echo "$PREOPEN" | tail -1 | cut -c1-200)"
fi

# ---- (o) wait out the delay ---------------------------------------------------------------------
wait_until $((SUNSET_AT + 2)) "v1 sunsetAt (delay $DELAY s)"
EFF=$(num "$V1_RM" 'isSunsetEffective()(bool)')
[ "$EFF" = "true" ] || fail "o. sunset effective" "-" "isSunsetEffective() is still $EFF at $(now_ts) vs sunsetAt $SUNSET_AT"
note "o. v1 sunset EFFECTIVE" "isSunset()=$(num "$V1_RM" 'isSunset()(bool)') isSunsetEffective()=$EFF at chain time $(now_ts) (announced $SUNSET_AT); from here v1 opens no new round and its genesis-pool ETH edge belongs to v2"

# ---- (p) the ETH edge crosses the handover -------------------------------------------------------
# A genesis buy through V2's ROUTER: v1's hook trusts the successor's router for attribution after
# the sunset, so this is an ATTRIBUTED trade whose fee v1's vault must hand to v2's vault.
V1_DEV_B=$(num "$V1_VAULT" 'devBalance()(uint256)'); V2_DEV_B=$(num "$V2_VAULT" 'devBalance()(uint256)')
V1_PENDING_B=$(num "$V1_VAULT" 'pendingForwardTotal()(uint256)')
TOK_B=$(bal_tok "$GENESIS")
# The in-swap hop is only ATTEMPTED when `gasleft - BOOK_GAS_RESERVE` is still positive when
# the fee is booked (FeeVault._forwardBudget), i.e. the transaction has to carry ~1.5M gas MORE
# than the swap itself needs. An ESTIMATED gas limit never does - the fork rehearsal queued even
# an ordinary buy - so this one asks for headroom on purpose. That single number is the whole
# difference between the two branches of the handover, and both are exercised here.
EXTRA="--value ${FWD_BUY_ETH}ether --gas-limit ${FWD_GAS_LIMIT:-4000000}"
send "p. post-sunset genesis buy (v2 router)" "$V2_ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
EXTRA=""
T_FWD_BUY=$(now_ts)
V1_DEV_A=$(num "$V1_VAULT" 'devBalance()(uint256)'); V2_DEV_A=$(num "$V2_VAULT" 'devBalance()(uint256)')
FWD_EV="no ProtocolFeeForwarded from v1's vault"
if event_from "$TXHASH" 'ProtocolFeeForwarded(address,uint256,uint256)' "$V1_VAULT"; then
  FWD_EV="ProtocolFeeForwarded emitted BY V1'S VAULT inside the swap"
elif event_from "$TXHASH" 'ProtocolFeeQueued(uint256,uint256,uint256)' "$V1_VAULT"; then
  FWD_EV="ProtocolFeeQueued by v1's vault (the in-swap hop did not fit its gas budget)"
fi
RECV_EV="no ProtocolFeeReceived on v2's vault"
event_from "$TXHASH" 'ProtocolFeeReceived(address,uint256,uint256)' "$V2_VAULT" \
  && RECV_EV="ProtocolFeeReceived ON V2'S VAULT (accrueForwarded), successorVault cached as $(addr "$V1_VAULT" 'successorVault()(address)')"
if [ "$V1_DEV_A" != "$V1_DEV_B" ]; then
  fail "p. handover" "$TXHASH" "v1's devBalance moved $V1_DEV_B -> $V1_DEV_A: the edge was booked by the SUNSET version"
fi
log "p. post-sunset genesis buy ${FWD_BUY_ETH} ETH via v2's router" "$TXHASH" "$GASUSED" \
  "bought $(bsub "$(bal_tok "$GENESIS")" "$TOK_B") FAM0 on v1's genesis pool. $FWD_EV; $RECV_EV. v1 devBalance UNCHANGED at $V1_DEV_A (the sunset version booked nothing), v2 devBalance $V2_DEV_B -> $V2_DEV_A; v1 pendingForwardTotal $V1_PENDING_B -> $(num "$V1_VAULT" 'pendingForwardTotal()(uint256)')"

# ---- (q) the QUEUE branch, on purpose, then the flush ---------------------------------------------
# FeeVault._forwardBudget gives the hop `min(FORWARD_GAS, gasleft - BOOK_GAS_RESERVE)` and skips it
# entirely below that reserve, so a swap sent with a thin gas limit QUEUES the fee instead. That is
# the branch a real trader hits, and the one `flushForward` exists for.
wait_until $((T_FWD_BUY + 130)) "OBS_MIN_SPACING before the second buy"
PEND_B=$(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 0)
EXTRA="--value ${QUEUE_BUY_ETH}ether --gas-limit ${QUEUE_GAS_LIMIT:-1900000}"
try_send "q1. gas-starved genesis buy" "$V2_ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
EXTRA=""
if [ "$TRY_OK" = "1" ]; then
  PEND_A=$(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 0)
  QEV="no ProtocolFeeQueued - the hop still fitted the thin budget and forwarded in-swap"
  event_from "$TXHASH" 'ProtocolFeeQueued(uint256,uint256,uint256)' "$V1_VAULT" && QEV="ProtocolFeeQueued(attribution=0) emitted by v1's vault"
  log "q1. gas-starved post-sunset buy (${QUEUE_BUY_ETH} ETH)" "$TXHASH" "$GASUSED" \
    "sent with an explicit gas limit so that FeeVault._forwardBudget returns 0: $QEV; v1 pendingForward(0) $PEND_B -> $PEND_A, pendingForwardTotal $(num "$V1_VAULT" 'pendingForwardTotal()(uint256)')"
else
  note "q1. gas-starved post-sunset buy" "the probe did not land: $TRY_ERR (the thin gas limit is a probe, not a protocol path; the queue is exercised by q2 only if something is queued)"
fi
PEND_NOW=$(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 0)
if [ "$PEND_NOW" != "0" ]; then
  V2_DEV_B=$(num "$V2_VAULT" 'devBalance()(uint256)')
  send "q2. flushForward(0)" "$V1_VAULT" 'flushForward(uint256,uint256)' 0 "$MAXU"
  FEV="no ProtocolFeeForwarded"; event_from "$TXHASH" 'ProtocolFeeForwarded(address,uint256,uint256)' "$V1_VAULT" && FEV="ProtocolFeeForwarded"
  REV="no receiveForward"; event_from "$TXHASH" 'ProtocolFeeReceived(address,uint256,uint256)' "$V2_VAULT" && REV="ProtocolFeeReceived on v2's vault (receiveForward, real ETH not a claim)"
  log "q2. flushForward(0) (permissionless)" "$TXHASH" "$GASUSED" \
    "pushed $PEND_NOW wei of the queued edge one hop: $FEV / $REV; v1 pendingForward(0) $PEND_NOW -> $(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 0), pendingForwardTotal $(num "$V1_VAULT" 'pendingForwardTotal()(uint256)'); v2 devBalance $V2_DEV_B -> $(num "$V2_VAULT" 'devBalance()(uint256)')"
else
  note "q2. flushForward(0)" "nothing queued (pendingForward(0) == 0): every post-sunset edge so far was forwarded INSIDE the swap, which is the happy path of the same handover"
fi

# ---- (r) v2 opens its first round and crowns #2 ---------------------------------------------------
BOND_NOW=$(num "$V2_RM" 'currentBond()(uint256)')
BOND_1=$(num "$V2_RM" 'bondFor(uint256)(uint256)' 1); BOND_2=$(num "$V2_RM" 'bondFor(uint256)(uint256)' 2)
BOND_4=$(num "$V2_RM" 'bondFor(uint256)(uint256)' 4)
declare -a V2_CANDS=()
for NAME in CAND-E CAND-F; do
  EXTRA="--value ${BOND_NOW}wei"
  send "r. register $NAME (v2)" "$V2_FACTORY" 'registerCandidate(string,string,string)' "$NAME" "$NAME" "ipfs://$NAME"
  EXTRA=""
  CID=$(( $(num "$V2_RM" 'candidateCount()(uint256)') - 1 )); V2_CANDS+=("$CID")
  log "r. register $NAME (v2 round 1)" "$TXHASH" "$GASUSED" \
    "candidateId=$CID on v2, bond $BOND_NOW wei; v2.adopted()=$(num "$V2_RM" 'adopted()(bool)') priorIndex=$(num "$V2_RM" 'priorIndex()(uint256)') - the FIRST registration is what adopted v1's head; parent token = $(addr "$V2_RM" 'head()(address)')"
done
RID=$(num "$V2_RM" 'roundCount()(uint256)')
ROUND_SIG='roundInfo(uint256)((uint64,uint64,uint64,uint64,uint64,bool,bool,bool,uint256,uint256,uint256,address,uint256,uint256,uint256,int256,uint64,bytes32))'
round_field() { $CALL "$V2_RM" "$ROUND_SIG" "$1" | tr -d '()' | tr ',' '\n' | sed -n "$2p" | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
T_START=$(round_field "$RID" 3); T_END=$(round_field "$RID" 4); T_SUBMIT=$(round_field "$RID" 5)
PARENT_TOK=$(round_field "$RID" 12); PARENT_IDX=$(round_field "$RID" 11)
H=$(num "$V2_RM" 'threshold()(uint256)')
note "v2 round $RID opened" "parentIndex=$PARENT_IDX parentToken=$PARENT_TOK (v1's head), bondWei=$(round_field "$RID" 10) = bondFor(2)=$BOND_2 (bondFor(1)=$BOND_1, identical until index 4 where it doubles to $BOND_4 - BOND_DOUBLING_EVERY=4), H=$H re-based on #1's supply, tradingStart=$T_START submitEnd=$T_SUBMIT"

CAND_SIG='candidateInfo(uint256)((uint256,address,address,uint256,bool,int256,uint64,(address,address,uint24,int24,address)))'
cand_field() { $CALL "$V2_RM" "$CAND_SIG" "$1" | tr -d '()' | cut -d',' -f"$2" | tr -d ' ' | sed -E 's/\[[^]]*\]//g'; }

wait_until $((T_START + 5)) "v2 tradingStart+5s"
E_ID=${V2_CANDS[0]}; F_ID=${V2_CANDS[1]}
E_TOK=$(cand_field "$E_ID" 2)
CUR=$($CALL "$V1_HEAD" 'allowance(address,address)(uint256)' "$ME" "$V2_ROUTER" | awk '{print $1}')
if bge "1000000000000000000000000000000" "$CUR"; then
  send "r0. approve #1 -> v2 router" "$V1_HEAD" 'approve(address,uint256)' "$V2_ROUTER" "$MAXU"
  log "r0. approve #1 -> v2 router" "$TXHASH" "$GASUSED" "approved $V2_ROUTER to move v1's head token $V1_HEAD"
fi
PAY=$(python -c "import sys;print(int(sys.argv[1])*40//100)" "$(bal_tok "$V1_HEAD")")
EB=$(bal_tok "$E_TOK")
send "r1. buy CAND-E with #1 tokens" "$V2_ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "$E_ID" "$PAY" 0 "$ME"
log "r1. buy CAND-E (40% of the #1 holding)" "$TXHASH" "$GASUSED" \
  "spent $PAY of v1's head token #1 -> received $(bsub "$(bal_tok "$E_TOK")" "$EB") CAND-E ($E_TOK) in a V2 POOL whose parent is a V1 TOKEN; v2's hook took the hop fee (reinforcementBalance($V1_HEAD)=$(num "$V2_VAULT" 'reinforcementBalance(address)(uint256)' "$V1_HEAD")); absorption counts toward H=$H"

wait_until $((T_END + 1)) "v2 tradingEnd"
send "r2. submitScore CAND-E" "$V2_RM" 'submitScore(uint256)' "$E_ID"
AVG=$(cand_field "$E_ID" 6)
log "r2. submitScore CAND-E (id $E_ID)" "$TXHASH" "$GASUSED" "avg=$AVG vs H=$H -> $(bge "$AVG" "$H" && echo CLEARS || echo below); CAND-F (id $F_ID) is deliberately left unscored so its bond forfeits"
wait_until $((T_SUBMIT + 1)) "v2 submitEnd"
EM_B=$(num "$V2_VAULT" 'genesisBidEarmark()(uint256)')
send "r3. finalize v2 round $RID" "$V2_RM" 'finalize()'
LINK2=$(addr "$V2_RM" 'head()(address)'); IDX2=$(num "$V2_RM" 'headIndex()(uint256)')
[ "$IDX2" = "2" ] || fail "r3. finalize" "$TXHASH" "v2 headIndex is $IDX2, expected 2"
CANON2=$(addr "$V2_RM" 'canonical(uint256)(address)' 2)
[ "$(lc "$CANON2")" = "$(lc "$LINK2")" ] || fail "r3. finalize" "$TXHASH" "canonical(2)=$CANON2 != head $LINK2"
log "r3. finalize v2 round $RID -> #2 crowned" "$TXHASH" "$GASUSED" \
  "v2 head=$LINK2 index=$IDX2; canonical(2)=$CANON2, parentOf(#2)=$(addr "$V2_RM" 'parentOf(address)(address)' "$LINK2") (v1's #1), registryOf(2)=$(addr "$V2_RM" 'registryOf(uint256)(address)' 2), registryOf(1)=$(addr "$V2_RM" 'registryOf(uint256)(address)' 1), v1 headIndex still $(num "$V1_RM" 'headIndex()(uint256)') and v1.canonical(2)=$(addr "$V1_RM" 'canonical(uint256)(address)' 2); CAND-F's bond forfeited into v2's genesisBidEarmark $EM_B -> $(num "$V2_VAULT" 'genesisBidEarmark()(uint256)')"

# ---- (s) a canonical ETH route that crosses both versions ------------------------------------------
L2_B=$(bal_tok "$LINK2"); SLEEVE_B=$(num "$V2_VAULT" 'claimableEth(uint256)(uint256)' 1)
EXTRA="--value ${ROUTE_ETH}ether"
send "s. route ETH -> #0 -> #1 -> #2" "$V2_ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 2 0 "$ME" 8
EXTRA=""
T_ROUTE=$(now_ts)
SLEEVE_A=$(num "$V2_VAULT" 'claimableEth(uint256)(uint256)' 1)
PEND2=$(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 2)
SFWD="the edge reached v2 INSIDE the swap"
[ "$PEND2" != "0" ] && SFWD="the edge was QUEUED in v1 under attribution 2 ($PEND2 wei), and is flushed in (s2)"
log "s. route ETH -> #0 -> #1 -> #2 (${ROUTE_ETH} ETH, v2 router)" "$TXHASH" "$GASUSED" \
  "one unlock across THREE pools owned by TWO versions (legs 1-2 are v1 pools under $V1_HOOK, leg 3 is a v2 pool under $V2_HOOK); received $(bsub "$(bal_tok "$LINK2")" "$L2_B") #2; the ETH edge was charged by v1's hook on the GENESIS pool and attributed to terminal index 2 - $SFWD; v2 claimableEth(1) $SLEEVE_B -> $SLEEVE_A"

# (s2) the attribution that actually funds the keeper path. `_book` credits reinforcementEth[M] and
# the Fenwick sleeve at M = terminalIndex - 1, so ONLY an attribution-2 fee funds generation 1 -
# and a QUEUED fee funds nothing at all until somebody pays the gas to push it one hop.
if [ "$PEND2" != "0" ]; then
  send "s2. flushForward(2)" "$V1_VAULT" 'flushForward(uint256,uint256)' 2 "$MAXU"
  REV="no ProtocolFeeReceived on v2's vault"
  event_from "$TXHASH" 'ProtocolFeeReceived(address,uint256,uint256)' "$V2_VAULT" && REV="ProtocolFeeReceived on v2's vault (receiveForward - real ETH, redeemed out of the PoolManager first)"
  log "s2. flushForward(2) -> generation 1's sleeve" "$TXHASH" "$GASUSED" \
    "pushed $PEND2 wei queued under attribution 2 one hop: $REV; v2 booked it with ITS OWN constants at M = 2 - 1 = 1, so claimableEth(1) $SLEEVE_A -> $(num "$V2_VAULT" 'claimableEth(uint256)(uint256)' 1) (reinforcementEth(1)=$(num "$V2_VAULT" 'reinforcementEth(uint256)(uint256)' 1), drawableEth(1)=$(num "$V2_VAULT" 'drawableEth(uint256)(uint256)' 1)); v1 pendingForward(2) now $(num "$V1_VAULT" 'pendingForward(uint256)(uint256)' 2)"
else
  note "s2. flushForward(2)" "nothing queued under attribution 2: the edge reached v2 inside the swap itself"
fi

# ---- (t) cross-version payouts ---------------------------------------------------------------------
wait_until $((T_ROUTE + 1810)) "TWAP_WINDOW (1800 s) coverage since the cross-version route"
for I in 0 1 2; do
  echo "   link #$I consult(1800)=$(twap_of "$I" | tr '\n' '/') obs=$(obs_of "$I") spot=$(spot "$I") slow=$(slow_of "$I" | tr '\n' '/')"
  wait_for_band "$I" || true
done

# (t1) v2's OWN forfeited bond is generation-0 ETH, and generation 0 is a V1 pool: v2's BidDeployer
# must hand it to v1's BidDeployer, which places the bid with v1's Locker.
EM=$(num "$V2_VAULT" 'genesisBidEarmark()(uint256)')
if [ "$EM" = "0" ]; then
  note "t1. v2 deployGenesisBid" "skipped: v2's genesisBidEarmark is 0"
else
  L0_B=$(liq 0); V1BD_B=$(cast balance "$V1_BD" --rpc-url "$RPC"); EB=$(bal_eth)
  send "t1. v2 deployGenesisBid()" "$V2_BD" 'deployGenesisBid()'
  FW="NO AncestorForwarded"; has_event "$TXHASH" 'AncestorForwarded(uint256,address,uint256)' && FW="AncestorForwarded(0, v1 BidDeployer) emitted by v2"
  XB="NO ExternalBidDeposited"; event_from "$TXHASH" 'ExternalBidDeposited(uint256,address,uint256)' "$V1_BD" && XB="ExternalBidDeposited emitted BY V1'S BidDeployer"
  log "t1. v2 deployGenesisBid -> v1's BidDeployer (cross-version)" "$TXHASH" "$GASUSED" \
    "v2's earmark $EM -> $(num "$V2_VAULT" 'genesisBidEarmark()(uint256)') was deployed as a locked ETH bid under GENESIS, a v1 pool: $FW; $XB; v1's BidDeployer kept nothing ($V1BD_B -> $(cast balance "$V1_BD" --rpc-url "$RPC")); keeper ETH $EB -> $(bal_eth) (1% bounty minus gas); genesis active L $L0_B -> $(liq 0) (the bid sits out of range by design)"
fi

# (t2) the same rule for a non-genesis prior-version generation.
CLAIM1=$(num "$V2_VAULT" 'claimableEth(uint256)(uint256)' 1)
DRAW1=$(num "$V2_VAULT" 'drawableEth(uint256)(uint256)' 1)
MINB=$(num "$V2_BD" 'MIN_BOUNTY_WEI()(uint256)')
MAXP=$(num "$V2_BD" 'maxParentForDeploy(uint256)(uint256)' 1)
CAPP=$(num "$V2_BD" 'bidCap(uint256)(uint256)' 1)
MAXP_VIEW="$MAXP"
if [ "$MAXP" = "0" ] && [ "$DRAW1" != "0" ]; then
  ETHV=$(python -c "import sys;print(int(sys.argv[1])*4*98//500)" "$DRAW1")
  [ "$ETHV" != "0" ] && MAXP=$(num "$V2_BD" 'parentForEthValue(uint256,uint256)(uint256)' 0 "$ETHV")
fi
PARENT_AMT=$(bmin "$MAXP" "$CAPP" "$(bal_tok "$GENESIS")")
echo "   v2 generation 1: claimableEth=$CLAIM1 drawableEth=$DRAW1 MIN_BOUNTY_WEI=$MINB maxParentForDeploy=$MAXP_VIEW bidCap=$CAPP -> parentAmount=$PARENT_AMT"
if [ "$PARENT_AMT" = "0" ]; then
  note "t2. v2 deployAncestor(1)" "skipped: parentAmount would be 0 (claimableEth(1)=$CLAIM1 drawableEth(1)=$DRAW1 maxParentForDeploy=$MAXP_VIEW bidCap=$CAPP)"
else
  CUR=$($CALL "$GENESIS" 'allowance(address,address)(uint256)' "$ME" "$V2_BD" | awk '{print $1}')
  if bge "1000000000000000000000000000000" "$CUR"; then
    send "t2a. approve FAM0 -> v2 BidDeployer" "$GENESIS" 'approve(address,uint256)' "$V2_BD" "$MAXU"
    log "t2a. approve FAM0 -> v2 BidDeployer" "$TXHASH" "$GASUSED" "approved $V2_BD to move $GENESIS"
  fi
  GB=$(bal_tok "$GENESIS"); EB=$(bal_eth); L1_B=$(liq 1)
  send "t2. v2 deployAncestor(1, $PARENT_AMT)" "$V2_BD" 'deployAncestor(uint256,uint256)' 1 "$PARENT_AMT"
  FW="NO AncestorForwarded"; has_event "$TXHASH" 'AncestorForwarded(uint256,address,uint256)' && FW="AncestorForwarded(1, $V1_BD) emitted by v2's BidDeployer"
  XB="NO ExternalBidDeposited"; event_from "$TXHASH" 'ExternalBidDeposited(uint256,address,uint256)' "$V1_BD" && XB="ExternalBidDeposited(1) emitted BY V1'S BidDeployer - v1's Locker placed the bid in v1's #1 pool"
  SL="no SlowTwapUnavailable (every link had >= 1 day of slow history)"; has_event "$TXHASH" 'SlowTwapUnavailable(uint256)' && SL="SlowTwapUnavailable(1) emitted - priced on the 1800 s average alone"
  log "t2. v2 deployAncestor(1) -> v1's BidDeployer (cross-version)" "$TXHASH" "$GASUSED" \
    "keeper delivered $(bsub "$GB" "$(bal_tok "$GENESIS")") FAM0 (a v1 token) to V2's BidDeployer and was paid $(bsub "$(bal_eth)" "$EB") wei net of gas out of V2's generation-1 sleeve (claimableEth(1)=$CLAIM1, drawableEth(1)=$DRAW1, MIN_BOUNTY_WEI=$MINB, maxParentForDeploy view=$MAXP_VIEW, bidCap=$CAPP); $FW; $XB; $SL; #1 pool active L $L1_B -> $(liq 1); neither deployer kept anything (v2 BidDeployer holds $($CALL "$GENESIS" 'balanceOf(address)(uint256)' "$V2_BD" | awk '{print $1}') FAM0, v1 BidDeployer $($CALL "$GENESIS" 'balanceOf(address)(uint256)' "$V1_BD" | awk '{print $1}'))"
fi

# ---- summary ---------------------------------------------------------------------------------------
ETH_END=$(bal_eth)
{
  echo
  echo "Handover complete. Deployer ETH: $ETH_START -> $ETH_END wei (net spent $(bsub "$ETH_START" "$ETH_END") wei)."
  echo "v1 is sunset (sunsetAt $SUNSET_AT, successor $(addr "$V1_RM" 'successor()(address)')), head of the trunk is \`$LINK2\` at canonical index $(num "$V2_RM" 'headIndex()(uint256)') owned by v2."
} >> "$RUNLOG"
echo "== done: net spent $(bsub "$ETH_START" "$ETH_END") wei; trunk head #$(num "$V2_RM" 'headIndex()(uint256)') = $LINK2 =="
