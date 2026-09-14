#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# vesting.sh - exercise the DEVELOPER VESTING and the three ROLE-TRANSFER surfaces of a live
# deployment. Added for RUN 5, the first deployment that mints a developer allocation.
#
#   ./script/live/vesting.sh --live pre     assertions + announce/cancel, run right after deploy
#   ./script/live/vesting.sh --live post    poll releasable() past the cliff, then release()
#   ./script/live/vesting.sh --fork pre|post|exec
#
# Phases, and why they are separate:
#
#   pre   Everything that must be true BEFORE the cliff, so it can only run in the window between
#         `createGenesis` and `start + cliff`: the allocation landed in the vesting contract and
#         NOT on the curve, releasable() is 0, and a real release() TRANSACTION reverts (a
#         negative test with a tx hash, not an eth_call). Then announce/cancel on all three role
#         transfers - RoundManager.steward, FeeVault.developer, DevVesting.beneficiary.
#   post  After `start + cliff`: poll releasable() until it turns non-zero, release(), and check
#         the paid amount against the schedule ((t - start)/duration of the allocation).
#   exec  FORK ONLY, and the script refuses --live for it: the EXECUTE half of each role transfer
#         is gated on ROLE_TRANSFER_DELAY = 7 days, which a testnet run cannot wait out. The fork
#         warps the 7 days and executes all three, so the delay, the permissionless execute and
#         the role actually moving are observed - on anvil, which is NOT liveness evidence.
#
# The transfer target is a FRESH THROWAWAY address generated per run (`cast wallet new`); its key
# is discarded unread. That is safe for `pre` because every announcement is CANCELLED in the same
# phase, and safe for `exec` because it happens only on a fork.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

MODE="${1:---fork}"
PHASE="${2:-pre}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

CHAIN_ID=46630
DEPLOY_JSON="${DEPLOY_JSON:-deployments/${CHAIN_ID}.json}"
RUNLOG="${RUNLOG:-docs/TESTNET_RUN.md}"
EXPLORER="https://explorer.testnet.chain.robinhood.com/tx"

case "$MODE" in
  --live)
    RPC="$RPC_TESTNET"; KEY="$DEPLOYER_PRIVATE_KEY"; ME="$DEPLOYER_ADDRESS"
    if [ "$PHASE" = "exec" ]; then echo "!! the execute paths are 7-day gated: fork only" >&2; exit 2; fi
    ;;
  --fork)
    RPC="${FORK_RPC:-http://127.0.0.1:8545}"
    KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ME="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    ;;
  *) echo "usage: $0 [--live|--fork] [pre|post|exec]" >&2; exit 2 ;;
esac
case "$PHASE" in pre|post|exec) ;; *) echo "usage: $0 [--live|--fork] [pre|post|exec]" >&2; exit 2 ;; esac

GAS_PRICE=10000000
GASFLAGS="--legacy --gas-price $GAS_PRICE"
SEND="cast send --rpc-url $RPC --private-key $KEY $GASFLAGS"
CALL="cast call --rpc-url $RPC"

j() { jq -r "$1" "$DEPLOY_JSON"; }
FACTORY=$(j .factory); LOCKER=$(j .locker); ROUND_MANAGER=$(j .roundManager)
FEE_VAULT=$(j .feeVault); POOL_MANAGER=$(j .poolManager); GENESIS=$(j .genesisToken)
VESTING=$(j .devVesting); VESTING_DEPLOYER=$(j .devVestingDeployer); DEVELOPER=$(j .developer)
SUPPLY=$(j .constants.supply); ALLOC_BPS=$(j .constants.devAllocationBps)
CLIFF_S=$(j .constants.vestingCliffS); DURATION_S=$(j .constants.vestingDurationS)
ROLE_DELAY=$(j .constants.roleTransferDelayS)

if [ "$VESTING" = "null" ] || [ "$VESTING" = "0x0000000000000000000000000000000000000000" ]; then
  echo "!! $DEPLOY_JSON has no devVesting: this deployment has no developer allocation" >&2; exit 3
fi

# ---- helpers (same shapes as round.sh) --------------------------------------------------------
hex2dec() { cast to-dec "$1" 2>/dev/null || echo 0; }
bsub() { python -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$1" "$2"; }
badd() { python -c "import sys;print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
beq()  { python -c "import sys;sys.exit(0 if int(sys.argv[1])==int(sys.argv[2]) else 1)" "$1" "$2"; }
lc()   { echo "$1" | tr 'A-Z' 'a-z'; }
explorer_cell() { if [ "$MODE" = "--live" ]; then printf '[tx](%s/%s)' "$EXPLORER" "$1"; else printf 'anvil fork - not on chain'; fi; }
log() { printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$(explorer_cell "$2")" "$3" "$4" >> "$RUNLOG"
        printf '>> %-38s tx=%s gas=%s\n   %s\n' "$1" "$2" "$3" "$4"; }
note() { printf '| %s | - | - | - | %s |\n' "$1" "$2" >> "$RUNLOG"; printf '>> %-38s %s\n' "$1" "$2"; }
fail() { printf '| %s | `%s` | - | - | **FAILED**: %s |\n' "$1" "$2" "$3" >> "$RUNLOG"
         echo "!! STEP FAILED: $1: $3" >&2; exit 1; }
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
    while [ "$(now_ts)" -lt "$target" ]; do sleep 15; done
    echo "   reached $what ($(now_ts))"
  fi
}
bal_tok() { $CALL "$2" 'balanceOf(address)(uint256)' "$1" | awk '{print $1}'; }
vcall()   { local s="$1"; shift; $CALL "$VESTING" "$s" "$@" | awk '{print $1}'; }
acall()   { local a="$1" s="$2"; shift 2; $CALL "$a" "$s" "$@" | awk '{print $1}'; }

mkdir -p docs
{
  echo
  echo "## Run 5 dev-vesting / roles driver ($MODE $PHASE) - started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "| step | tx hash | explorer | gas used | observed effect |"
  echo "|---|---|---|---|---|"
} >> "$RUNLOG"

V_TOKEN=$(vcall 'token()(address)'); V_BENEF=$(vcall 'beneficiary()(address)')
V_START=$(vcall 'start()(uint64)'); V_CLIFF=$(vcall 'cliff()(uint64)'); V_DUR=$(vcall 'duration()(uint64)')
ALLOC=$(acall "$FACTORY" 'devAllocation()(uint256)')
FOR_SALE=$(acall "$FACTORY" 'genesisTokensForSale()(uint256)')

# =============================================================================================
if [ "$PHASE" = "pre" ]; then
# =============================================================================================
  # ---- (v1) the allocation landed in the vesting contract, and NOT on the curve ---------------
  V_BAL=$(bal_tok "$VESTING" "$GENESIS")
  PM_BAL=$(bal_tok "$POOL_MANAGER" "$GENESIS")
  LK_BAL=$(bal_tok "$LOCKER" "$GENESIS")
  EXPECT_ALLOC=$(python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2])//10000)" "$SUPPLY" "$ALLOC_BPS")
  EXPECT_CURVE=$(bsub "$SUPPLY" "$EXPECT_ALLOC")
  SUPPLY_NOW=$(acall "$GENESIS" 'totalSupply()(uint256)')
  # `Locker.placeStandardCurve` BURNS the tick-rounding remainder ("all supply must live inside the
  # locked positions"), so the curve is genesisTokensForSale() MINUS that dust and the dust leaves
  # totalSupply rather than sitting in the Locker. Both facts are asserted.
  DUST=$(bsub "$FOR_SALE" "$(badd "$PM_BAL" "$LK_BAL")")
  beq "$V_BAL" "$EXPECT_ALLOC" || fail "v1. allocation" "-" "DevVesting holds $V_BAL, expected $EXPECT_ALLOC ($ALLOC_BPS bps of $SUPPLY)"
  beq "$V_BAL" "$ALLOC"        || fail "v1. allocation" "-" "DevVesting holds $V_BAL but factory.devAllocation() says $ALLOC"
  beq "$FOR_SALE" "$EXPECT_CURVE" || fail "v1. curve" "-" "genesisTokensForSale()=$FOR_SALE, expected supply-allocation=$EXPECT_CURVE"
  beq "$LK_BAL" 0 || fail "v1. curve" "-" "the Locker still holds $LK_BAL: the rounding remainder was not burned"
  beq "$SUPPLY_NOW" "$(badd "$V_BAL" "$PM_BAL")" || fail "v1. curve" "-" "totalSupply $SUPPLY_NOW != vesting $V_BAL + curve $PM_BAL"
  python -c "import sys;sys.exit(0 if 0 <= int(sys.argv[1]) < 10**9 else 1)" "$DUST" || fail "v1. curve" "-" "burned curve dust $DUST is not a rounding remainder"
  PCT_CURVE=$(python -c "import sys;print('%.8f' % (100*int(sys.argv[1])/int(sys.argv[2])))" "$PM_BAL" "$SUPPLY")
  PCT_ALLOC=$(python -c "import sys;print(int(sys.argv[1])/100)" "$ALLOC_BPS")
  note "v1. allocation vs curve (eth_call)" \
    "DevVesting $VESTING holds $V_BAL FAM0 = $ALLOC_BPS bps = ${PCT_ALLOC}% of the $SUPPLY genesis supply, and equals factory.devAllocation() exactly. genesisTokensForSale() = $FOR_SALE = supply - allocation (97%), and the Locker curve inside the PoolManager holds $PM_BAL = ${PCT_CURVE}% of nominal supply: 97% MINUS $DUST wei-tokens of tick-rounding dust, which Locker.placeStandardCurve BURNED (Locker balance 0, totalSupply $SUPPLY_NOW = vesting + curve). The allocation is NOT on the curve, and no family supply sits outside locked liquidity except the vesting contract."
  note "v1b. vesting parameters (eth_call)" \
    "token()=$V_TOKEN (the genesis token), beneficiary()=$V_BENEF (= FeeVault.developer() = $DEVELOPER), start()=$V_START (the genesis block timestamp), cliff()=$V_CLIFF s, duration()=$V_DUR s, total()=$(vcall 'total()(uint256)'), released()=$(vcall 'released()(uint256)'), ROLE_TRANSFER_DELAY=$(vcall 'ROLE_TRANSFER_DELAY()(uint64)') s; CREATEd in the genesis tx by DevVestingDeployer $VESTING_DEPLOYER"
  if [ "$(lc "$V_TOKEN")" != "$(lc "$GENESIS")" ]; then fail "v1b" "-" "vesting token is $V_TOKEN, not the genesis $GENESIS"; fi
  if [ "$(lc "$V_BENEF")" != "$(lc "$DEVELOPER")" ]; then fail "v1b" "-" "beneficiary $V_BENEF is not the developer $DEVELOPER"; fi
  beq "$V_CLIFF" "$CLIFF_S" || fail "v1b" "-" "cliff $V_CLIFF != recorded $CLIFF_S"
  beq "$V_DUR" "$DURATION_S" || fail "v1b" "-" "duration $V_DUR != recorded $DURATION_S"

  # ---- (v2) nothing is releasable before the cliff, and a real release() TRANSACTION reverts ---
  NOW=$(now_ts); REL=$(vcall 'releasable()(uint256)'); VEST_NOW=$(vcall 'vested(uint64)(uint256)' "$NOW")
  beq "$REL" 0 || fail "v2. releasable before the cliff" "-" "releasable() is $REL, expected 0 at t=$NOW < start+cliff=$((V_START + V_CLIFF))"
  beq "$VEST_NOW" 0 || fail "v2. vested before the cliff" "-" "vested($NOW) is $VEST_NOW, expected 0"
  # A NEGATIVE test WITH EVIDENCE: send it with a fixed gas limit so the node mines the revert
  # instead of refusing it at estimation, and record the failed tx hash.
  set +e
  OUT=$(cast send --rpc-url "$RPC" --private-key "$KEY" $GASFLAGS --gas-limit 200000 \
        "$VESTING" 'release()' --json 2>&1); RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    RTX=$(echo "$OUT" | jq -r .transactionHash); RST=$(echo "$OUT" | jq -r .status)
    RGAS=$(hex2dec "$(echo "$OUT" | jq -r .gasUsed)")
    if [ "$RST" = "0x1" ]; then fail "v2. release() before the cliff" "$RTX" "release() SUCCEEDED before the cliff"; fi
    beq "$(bal_tok "$VESTING" "$GENESIS")" "$V_BAL" || fail "v2. release() before the cliff" "$RTX" "the vesting balance moved on a reverted release()"
    log "v2. release() before the cliff (NEGATIVE)" "$RTX" "$RGAS" \
      "status $RST - REVERTED as designed (DevVesting.NothingToRelease): t=$NOW is before start+cliff=$((V_START + V_CLIFF)), releasable()=0, vested($NOW)=0, released()=$(vcall 'released()(uint256)'); the vesting balance is UNCHANGED at $V_BAL and the beneficiary was paid 0"
  else
    note "v2. release() before the cliff (NEGATIVE)" \
      "the node refused the transaction: $(echo "$OUT" | grep -oiE 'NothingToRelease|execution reverted.*' | head -1) - releasable()=0 and vested($NOW)=0 at t=$NOW < start+cliff=$((V_START + V_CLIFF)); nothing moved and the beneficiary was paid 0"
  fi

  # ---- (v3) the three role transfers: announce -> assert -> cancel -> assert -------------------
  # `cast wallet new` prints its human-readable form on STDERR; take the JSON and read ONLY the
  # address out of it, so the private key is never echoed anywhere.
  THROWAWAY=$(cast wallet new --json 2>/dev/null | jq -r '.data[0].address')
  if [ -z "$THROWAWAY" ] || [ "$THROWAWAY" = "null" ]; then echo "!! could not generate a throwaway address" >&2; exit 4; fi
  note "v3. throwaway transfer target" \
    "$THROWAWAY - a fresh address generated for this run with \`cast wallet new\`; its private key is discarded unread. Every announcement below is CANCELLED in the same phase, so it never holds any role."

  # steward, on the RoundManager
  send "r1. announceStewardTransfer" "$ROUND_MANAGER" 'announceStewardTransfer(address)' "$THROWAWAY"
  PS=$(acall "$ROUND_MANAGER" 'pendingSteward()(address)'); PA=$(acall "$ROUND_MANAGER" 'stewardTransferAt()(uint64)')
  if [ "$(lc "$PS")" != "$(lc "$THROWAWAY")" ]; then fail "r1" "$TXHASH" "pendingSteward is $PS, expected $THROWAWAY"; fi
  log "r1. announceStewardTransfer (RoundManager)" "$TXHASH" "$GASUSED" \
    "pendingSteward 0x0 -> $THROWAWAY, stewardTransferAt=$PA = now + ROLE_TRANSFER_DELAY ($ROLE_DELAY s = 7 days); steward() is STILL $(acall "$ROUND_MANAGER" 'steward()(address)') - the role does not move until executeStewardTransfer(), which cannot be called for 7 days"
  send "r2. cancelStewardTransfer" "$ROUND_MANAGER" 'cancelStewardTransfer()'
  PS2=$(acall "$ROUND_MANAGER" 'pendingSteward()(address)'); PA2=$(acall "$ROUND_MANAGER" 'stewardTransferAt()(uint64)')
  beq "$PA2" 0 || fail "r2" "$TXHASH" "stewardTransferAt is $PA2 after cancel, expected 0"
  log "r2. cancelStewardTransfer (RoundManager)" "$TXHASH" "$GASUSED" \
    "pendingSteward $THROWAWAY -> $PS2, stewardTransferAt $PA -> $PA2; steward() unchanged at $(acall "$ROUND_MANAGER" 'steward()(address)'). Unlike cancelSunset, this take-back is NOT one-shot"

  # developer, on the FeeVault
  send "r3. announceDeveloperTransfer" "$FEE_VAULT" 'announceDeveloperTransfer(address)' "$THROWAWAY"
  PD=$(acall "$FEE_VAULT" 'pendingDeveloper()(address)'); PDA=$(acall "$FEE_VAULT" 'developerTransferAt()(uint64)')
  if [ "$(lc "$PD")" != "$(lc "$THROWAWAY")" ]; then fail "r3" "$TXHASH" "pendingDeveloper is $PD, expected $THROWAWAY"; fi
  log "r3. announceDeveloperTransfer (FeeVault)" "$TXHASH" "$GASUSED" \
    "pendingDeveloper 0x0 -> $THROWAWAY, developerTransferAt=$PDA (now + 7 days); developer() is STILL $(acall "$FEE_VAULT" 'developer()(address)'), so claimDev keeps paying the current holder for the whole delay"
  send "r4. cancelDeveloperTransfer" "$FEE_VAULT" 'cancelDeveloperTransfer()'
  PDA2=$(acall "$FEE_VAULT" 'developerTransferAt()(uint64)')
  beq "$PDA2" 0 || fail "r4" "$TXHASH" "developerTransferAt is $PDA2 after cancel, expected 0"
  log "r4. cancelDeveloperTransfer (FeeVault)" "$TXHASH" "$GASUSED" \
    "pendingDeveloper -> $(acall "$FEE_VAULT" 'pendingDeveloper()(address)'), developerTransferAt $PDA -> $PDA2; developer() unchanged at $(acall "$FEE_VAULT" 'developer()(address)')"

  # beneficiary, on the DevVesting
  send "r5. announceBeneficiaryTransfer" "$VESTING" 'announceBeneficiaryTransfer(address)' "$THROWAWAY"
  PB=$(vcall 'pendingBeneficiary()(address)'); PBA=$(vcall 'beneficiaryTransferAt()(uint64)')
  if [ "$(lc "$PB")" != "$(lc "$THROWAWAY")" ]; then fail "r5" "$TXHASH" "pendingBeneficiary is $PB, expected $THROWAWAY"; fi
  log "r5. announceBeneficiaryTransfer (DevVesting)" "$TXHASH" "$GASUSED" \
    "pendingBeneficiary 0x0 -> $THROWAWAY, beneficiaryTransferAt=$PBA (now + 7 days); beneficiary() is STILL $(vcall 'beneficiary()(address)') and the SCHEDULE is untouched - a beneficiary transfer moves who release() pays, never what or when it pays"
  send "r6. cancelBeneficiaryTransfer" "$VESTING" 'cancelBeneficiaryTransfer()'
  PBA2=$(vcall 'beneficiaryTransferAt()(uint64)')
  beq "$PBA2" 0 || fail "r6" "$TXHASH" "beneficiaryTransferAt is $PBA2 after cancel, expected 0"
  log "r6. cancelBeneficiaryTransfer (DevVesting)" "$TXHASH" "$GASUSED" \
    "pendingBeneficiary -> $(vcall 'pendingBeneficiary()(address)'), beneficiaryTransferAt $PBA -> $PBA2; beneficiary() unchanged at $(vcall 'beneficiary()(address)'), releasable() still $(vcall 'releasable()(uint256)')"
  echo "== pre phase done; cliff at $((V_START + V_CLIFF)), in $(( V_START + V_CLIFF - $(now_ts) )) s =="
fi

# =============================================================================================
if [ "$PHASE" = "post" ]; then
# =============================================================================================
  CLIFF_AT=$((V_START + V_CLIFF))
  wait_until $((CLIFF_AT + 5)) "the vesting cliff (start $V_START + cliff $V_CLIFF)"
  # poll the VIEW, not just the clock: releasable() turning non-zero is the contract's own answer
  REL=0
  for i in $(seq 1 40); do
    REL=$(vcall 'releasable()(uint256)')
    if [ "$REL" != "0" ]; then break; fi
    echo "   releasable() still 0 at $(now_ts) (attempt $i); waiting 15 s"
    wait_until $(( $(now_ts) + 15 )) "releasable() > 0"
  done
  if [ "$REL" = "0" ]; then fail "v4. release" "-" "releasable() is still 0 past the cliff at $(now_ts)"; fi
  TOTAL=$(vcall 'total()(uint256)'); RELEASED0=$(vcall 'released()(uint256)')
  BEN=$(vcall 'beneficiary()(address)')
  B0=$(bal_tok "$BEN" "$GENESIS"); VB0=$(bal_tok "$VESTING" "$GENESIS")
  note "v4a. cliff reached" \
    "releasable() 0 -> $REL at $(now_ts) (cliff at $CLIFF_AT = start $V_START + $V_CLIFF s); total()=$TOTAL, released()=$RELEASED0, beneficiary=$BEN"
  send "v4. release()" "$VESTING" 'release()'
  T_REL=$(cast block "$(cast receipt "$TXHASH" --rpc-url "$RPC" --json | jq -r .blockNumber)" --rpc-url "$RPC" -f timestamp)
  B1=$(bal_tok "$BEN" "$GENESIS"); VB1=$(bal_tok "$VESTING" "$GENESIS")
  PAID=$(bsub "$B1" "$B0")
  # the schedule, recomputed off-chain: allocation * (t - start) / duration, and the amount the
  # cliff itself unlocks, allocation * cliff / duration.
  EXPECT=$(python -c "import sys;a,t,s,d=(int(x) for x in sys.argv[1:]);print(a*(t-s)//d)" "$TOTAL" "$T_REL" "$V_START" "$V_DUR")
  AT_CLIFF=$(python -c "import sys;a,c,d=(int(x) for x in sys.argv[1:]);print(a*c//d)" "$TOTAL" "$V_CLIFF" "$V_DUR")
  beq "$PAID" "$EXPECT" || fail "v4. release()" "$TXHASH" "paid $PAID, the schedule says $EXPECT at t=$T_REL"
  beq "$(vcall 'released()(uint256)')" "$PAID" || fail "v4. release()" "$TXHASH" "released() is $(vcall 'released()(uint256)') after paying $PAID"
  beq "$(bsub "$VB0" "$VB1")" "$PAID" || fail "v4. release()" "$TXHASH" "the vesting balance fell by $(bsub "$VB0" "$VB1"), not $PAID"
  PCT=$(python -c "import sys;print('%.4f' % (100*int(sys.argv[1])/int(sys.argv[2])))" "$PAID" "$TOTAL")
  log "v4. release() past the cliff" "$TXHASH" "$GASUSED" \
    "released $PAID FAM0 (wei-tokens) to beneficiary $BEN = ${PCT}% of the $TOTAL allocation. FORMULA CHECK: allocation x (t - start)/duration = $TOTAL x ($T_REL - $V_START)/$V_DUR = $EXPECT, EXACTLY the amount paid. The cliff itself unlocks allocation x cliff/duration = $TOTAL x $V_CLIFF/$V_DUR = $AT_CLIFF; this call landed $((T_REL - V_START - V_CLIFF)) s after the cliff, which is the whole of the excess. released() $RELEASED0 -> $(vcall 'released()(uint256)'), vesting balance $VB0 -> $VB1, releasable() now $(vcall 'releasable()(uint256)')"
  echo "== release done: $PAID of $TOTAL =="
fi

# =============================================================================================
if [ "$PHASE" = "exec" ]; then
# =============================================================================================
  # FORK ONLY. Each of the three EXECUTE entrypoints is gated on ROLE_TRANSFER_DELAY = 7 days.
  # Announce, prove the call still refuses just before the delay, warp it out, then execute.
  # `cast wallet new` prints its human-readable form on STDERR; take the JSON and read ONLY the
  # address out of it, so the private key is never echoed anywhere.
  THROWAWAY=$(cast wallet new --json 2>/dev/null | jq -r '.data[0].address')
  if [ -z "$THROWAWAY" ] || [ "$THROWAWAY" = "null" ]; then echo "!! could not generate a throwaway address" >&2; exit 4; fi
  note "e0. throwaway transfer target (FORK ONLY)" \
    "$THROWAWAY - here the roles really do move to it, on the local anvil. A fork tx hash is NOT liveness evidence."
  for T in "steward:$ROUND_MANAGER:announceStewardTransfer(address):executeStewardTransfer():stewardTransferAt()(uint64):steward()(address)" \
           "developer:$FEE_VAULT:announceDeveloperTransfer(address):executeDeveloperTransfer():developerTransferAt()(uint64):developer()(address)" \
           "beneficiary:$VESTING:announceBeneficiaryTransfer(address):executeBeneficiaryTransfer():beneficiaryTransferAt()(uint64):beneficiary()(address)"; do
    IFS=':' read -r ROLE ADDR ANN EXE ATSIG HOLDSIG <<< "$T"
    HOLD0=$(acall "$ADDR" "$HOLDSIG")
    send "e. announce $ROLE" "$ADDR" "$ANN" "$THROWAWAY"
    AT=$(acall "$ADDR" "$ATSIG")
    log "e. announce $ROLE transfer (fork)" "$TXHASH" "$GASUSED" "pending -> $THROWAWAY, effective at $AT (now + $ROLE_DELAY s)"
    wait_until $((AT - 60)) "$ROLE transfer delay minus 60 s"
    set +e
    EARLY=$(cast call --rpc-url "$RPC" "$ADDR" "$EXE" --from "$ME" 2>&1); ERC=$?
    set -e
    if [ $ERC -eq 0 ]; then fail "e. $ROLE early execute" "-" "$EXE succeeded BEFORE the delay elapsed"; fi
    note "e. $ROLE execute 60 s early (NEGATIVE, fork)" \
      "refused: $(echo "$EARLY" | grep -oiE 'TransferNotReady|execution reverted.*' | head -1) - the 7-day delay is enforced"
    wait_until $((AT + 1)) "$ROLE ROLE_TRANSFER_DELAY (7 days) elapsed"
    send "e. execute $ROLE" "$ADDR" "$EXE"
    HOLD1=$(acall "$ADDR" "$HOLDSIG")
    if [ "$(lc "$HOLD1")" != "$(lc "$THROWAWAY")" ]; then fail "e. execute $ROLE" "$TXHASH" "holder is $HOLD1, expected $THROWAWAY"; fi
    beq "$(acall "$ADDR" "$ATSIG")" 0 || fail "e. execute $ROLE" "$TXHASH" "transferAt not cleared"
    log "e. execute $ROLE transfer (fork)" "$TXHASH" "$GASUSED" \
      "$ROLE $HOLD0 -> $HOLD1 after the full $ROLE_DELAY s (7 days) warped on anvil; pending cleared, transferAt -> 0. The execute is PERMISSIONLESS - it has no sender check at all, so the incoming holder can finish the move itself"
  done
  echo "== fork-only execute paths done =="
fi
