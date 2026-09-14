#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------
# round.sh - drive one full succession round against a live deployment, and open a second.
#
#   ./script/live/round.sh --live    run against RPC_TESTNET, waiting on the real clock
#   ./script/live/round.sh --fork    run against a local anvil fork, warping the clock instead
#
# Reads .env (DEPLOYER_ADDRESS, DEPLOYER_PRIVATE_KEY, RPC_TESTNET) and deployments/<chain>.json.
# Every step prints its tx hash and appends a row to docs/TESTNET_RUN.md.
#
# Round shape (tranche 4/5 contracts): registration 180 s -> trading 900 s -> submit 300 s.
#
# Two things force the ORDER of the steps below, and they are not cosmetic:
#
#  1. THE KEEPER PATHS NEED A 1800 s TWAP. BidDeployer._requireWithinBand refuses a pool whose
#     oracle does not cover the full TWAP_WINDOW (1800 s) or that has fewer than two
#     observations, and observations are only written BY SWAPS, at least OBS_MIN_SPACING
#     (120 s) apart. So the genesis pool gets a deliberate second, tiny buy ~130 s after the
#     first one (step a2), and both keeper calls (step k) run at the very end, >1800 s after the
#     first genesis buy and after candidate A's first trade.
#  2. deployAncestor(1, ...) SPENDS GENERATION 1's OWN ETH, and generation 1 has none until a
#     fee is booked with M >= 1. FeeVault._book credits reinforcementEth[M] and the sleeve at
#     M = terminalIndex - 1 for a canonical trade, so buying the new head (index 1) funds
#     generation 0, not 1. The one thing that funds generation 1 is an ATTRIBUTED CANDIDATE
#     trade after the head change (M = headIndex = 1) - i.e. step (i) buyCandidate in round 2.
#     Hence the order: finalize -> open round 2 -> buy CAND-D -> only then deployAncestor(1).
#
# Candidate trades come in two flavours here, on purpose:
#   - FamilyRouter.buyCandidate/sellCandidate route ETH <-> candidate through the whole
#     canonical chain and are ATTRIBUTED (the candidate's creator and the head's creator are
#     paid, the ancestor sleeve is spread). They are ETH-in / ETH-out only, and they now take a
#     maxHops budget that COUNTS the candidate leg, exactly like the canonical routes.
#   - the bulk of the round-1 absorption is paid for in HEAD TOKENS already held (buying it again
#     with ETH would cost ~0.0017 ETH more than the budget has). That is what
#     FamilyRouter.buyCandidateWithParent(candidateId, parentAmount, minOut, to) is for: one hop,
#     head -> candidate, pulled with transferFrom and attributed through the same candidate
#     sentinel. Those legs used to go through a stock v4 PoolSwapTest
#     (script/live/CandidateSwap.s.sol - retained, but no longer used by this driver) and were
#     UNATTRIBUTED, exactly as any third-party router would be.
#
# Three API facts this driver now has to respect (they did not exist in the first live run):
#
#  3. THE BOND IS PER ROUND, NOT A DEPLOY CONSTANT (F6). `bondFor(targetIndex)` doubles every
#     BOND_DOUBLING_EVERY links up to BOND_MAX_WEI, a round PINS its bond when it opens, and each
#     candidate stores what it actually paid. `registerCandidate` reverts `WrongBond` on anything
#     else, so every registration below reads `RoundManager.currentBond()` immediately before it
#     sends, and the budget projection prices round 1 and round 2 separately with `bondFor`.
#     There is no `constants.bondWei` in deployments/<chain>.json any more.
#  4. THE SLOW (7 DAY) TWAP DOES NOT EXIST ON A FRESH DEPLOY. Every keeper conversion prices each
#     link at whichever of the 30-minute and the 7-day average values it LOWER (F4), but the slow
#     ring only counts once it has SLOW_TWAP_MIN_COVERAGE = 1 day of history, sampled every 3 h.
#     A pool minutes old has none, so `BidDeployer._priceFor` returns `slowUsed == false`, the
#     call is priced on the fast average ALONE and `deployAncestor` emits `SlowTwapUnavailable(j)`.
#     That is the DESIGNED behaviour here, not a failure: this driver prints `consultSlow`
#     coverage for both pools and checks the emitted event rather than treating it as an error.
#  5. A GENERATION'S ETH SLEEVE IS RATE LIMITED (F4). `FeeVault.drawableEth(j)` is claimable
#     capped at DAILY_DRAW_BPS = 10% of what was claimable when the rolling 24 h window opened;
#     `consumeAncestorClaim` reverts `DailyLimitExceeded` past it. `maxParentForDeploy(j)` already
#     sizes against `drawableEth`, so step (k2) stays correct by construction - but the driver now
#     prints claimable vs drawable for both keeper paths so that a short deployment is legible as
#     the rate limit rather than as a missing fee.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

MODE="${1:---fork}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
set -a; . ./.env; set +a

CHAIN_ID=46630
DEPLOY_JSON="deployments/${CHAIN_ID}.json"
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
  *) echo "usage: $0 [--live|--fork]" >&2; exit 2 ;;
esac

# 0.01 gwei, legacy pricing: the chain reports basefee == gas price == 10 gwei/1000
GAS_PRICE=10000000
GASFLAGS="--legacy --gas-price $GAS_PRICE"
SEND="cast send --rpc-url $RPC --private-key $KEY $GASFLAGS"
CALL="cast call --rpc-url $RPC"
MAXU=115792089237316195423570985008687907853269984665640564039457584007913129639935

# ---- deployment addresses --------------------------------------------------------------------
j() { jq -r "$1" "$DEPLOY_JSON"; }
POOL_MANAGER=$(j .poolManager); FACTORY=$(j .factory); HOOK=$(j .hook); LOCKER=$(j .locker)
ROUND_MANAGER=$(j .roundManager); FEE_VAULT=$(j .feeVault); ROUTER=$(j .router); LENS=$(j .lens)
# The keeper/bid half of the treasury (deployer nonce n+2). Every keeper entrypoint - bidCap,
# maxParentForDeploy, deployGenesisBid, deployAncestor, depositExternalBid - lives HERE, not on
# the FeeVault, which now keeps only the ledgers (the two together no longer fit under EIP-170).
BID_DEPLOYER=$(j .bidDeployer)
GENESIS=$(j .genesisToken); GENESIS_POOL=$(j .genesisPoolId)

# ---- budget ----------------------------------------------------------------------------------
# SCALED-UP LIVE RUN. The deployer now holds 0.46 testnet ETH, so the round is sized so that every
# effect is legible on the Blockscout explorer (visible ETH amounts, visible fee accrual, visible
# bid deposits) rather than being dust. The hard ceiling for the whole exercise is 0.12 ETH.
#
# ETH the genesis buy spends. The succession threshold H is 0.15% of the genesis supply as an
# AVERAGE over the trading window (1.5e24 wei-tokens). 0.05 ETH buys several percent of supply, so
# candidate A at a 40% allocation clears H with a wide margin (B at 30% is expected to clear too;
# finalize picks the HIGHEST score, so the round still resolves to one winner and one head change).
# Those genesis tokens are ALSO the keeper's inventory for deployAncestor(1, parentAmount) in (k2).
GENESIS_BUY_ETH=${GENESIS_BUY_ETH:-0.05}
# A second, smaller genesis buy ~130 s later: its purpose is to write the genesis pool's second
# oracle observation, without which BidDeployer._requireWithinBand reverts TwapNotReady(_, 1) for
# both keeper paths (see header note 1). Scaled to 0.0005 ETH so it shows up on the explorer as a
# real trade rather than dust; it is small enough not to move spot out of the +/-3% TWAP band.
SECOND_BUY_ETH=${SECOND_BUY_ETH:-0.0005}
# Round 2: the attributed candidate buy that funds generation 1's ancestor sleeve (header note 2).
# This one routes ETH -> FAM0 -> head -> CAND-D, so it moves the GENESIS pool's spot price as well
# and is the swap most likely to push a pool outside the keeper's TWAP band; wait_for_band below
# polls for convergence instead of reverting with PriceOutOfBand.
ROUND2_BUY_ETH=${ROUND2_BUY_ETH:-0.01}
# Headroom for gas across the whole driver, at $GAS_PRICE (0.01 gwei); ~40M gas total.
GAS_BUDGET_ETH=${GAS_BUDGET_ETH:-0.001}
# Hard ceiling for the whole live exercise, deploy included (the deployer holds 0.46 ETH).
BUDGET_CAP_ETH=${BUDGET_CAP_ETH:-0.12}
# Measured deploy cost on the fork (~21M gas @ 0.01 gwei), counted against the same cap.
DEPLOY_COST_ETH=${DEPLOY_COST_ETH:-0.00025}

declare -a CAND_IDS=()

# ---- helpers ---------------------------------------------------------------------------------
hex2dec() { cast to-dec "$1" 2>/dev/null || echo 0; }  # keep the 0x: an all-digit hex string reads as decimal without it
# token amounts run to ~1e24, which overflows bash 64-bit arithmetic: do big maths in python
bsub() { python -c "import sys;print(int(sys.argv[1])-int(sys.argv[2]))" "$1" "$2"; }
badd() { python -c "import sys;print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
bmin() { python -c "import sys;print(min(int(a) for a in sys.argv[1:]))" "$@"; }
bhalf() { python -c "import sys;print(int(sys.argv[1])//2)" "$1"; }
bmul() { python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2]))" "$1" "$2"; }
bge()  { python -c "import sys;sys.exit(0 if int(sys.argv[1])>=int(sys.argv[2]) else 1)" "$1" "$2"; }
wei()  { cast to-wei "$1"; }

# An explorer link is only meaningful for a LIVE tx: a fork hash exists nowhere but on the local
# anvil, and linking it to the real explorer is how a rehearsal gets mistaken for a deployment.
explorer_cell() { [ "$MODE" = "--live" ] && printf '[tx](%s/%s)' "$EXPLORER" "$1" || printf 'anvil fork - not on chain'; }

log() { # log <step> <txhash> <gas> <effect>
  printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$(explorer_cell "$2")" "$3" "$4" >> "$RUNLOG"
  printf '>> %-34s tx=%s gas=%s\n   %s\n' "$1" "$2" "$3" "$4"
}
note() { printf '| %s | - | - | - | %s |\n' "$1" "$2" >> "$RUNLOG"; printf '>> %-34s %s\n' "$1" "$2"; }

fail() { # fail <step> <txhash-or-> <message>
  printf '| %s | `%s` | - | - | **FAILED**: %s |\n' "$1" "$2" "$3" >> "$RUNLOG"
  echo "!! STEP FAILED: $1: $3" >&2
  [ "$2" != "-" ] && cast run "$2" --rpc-url "$RPC" 2>&1 | tail -30 >&2 || true
  exit 1
}

# send <label> <to> <sig> [args...] ; extra cast flags via $EXTRA. Sets TXHASH / GASUSED.
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

# run a forge script and recover the tx hash + gas of its LAST broadcast tx
forge_script() {
  local label="$1" target="$2"; shift 2
  local out rc
  set +e
  out=$(forge script "$target" --rpc-url "$RPC" --private-key "$KEY" --broadcast --legacy \
        --with-gas-price $GAS_PRICE 2>&1); rc=$?
  set -e
  if [ $rc -ne 0 ]; then fail "$label" "-" "$(echo "$out" | grep -iE 'error|revert' | head -3 | tr '\n' ' ')"; fi
  SCRIPT_OUT="$out"
  local bc="broadcast/$(basename "${target%%:*}")/$CHAIN_ID/run-latest.json"
  TXHASH=$(jq -r '.receipts[-1].transactionHash' "$bc")
  GASUSED=$(hex2dec "$(jq -r '.receipts[-1].gasUsed' "$bc")")
}

now_ts() { cast block latest --rpc-url "$RPC" -f timestamp; }

# Advance to an absolute unix timestamp: warp on the fork, poll the clock when live.
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
    while [ "$(now_ts)" -lt "$target" ]; do sleep 10; done
    echo "   reached $what ($(now_ts))"
  fi
}

bal_eth()  { cast balance "$ME" --rpc-url "$RPC"; }
bal_tok()  { $CALL "$1" 'balanceOf(address)(uint256)' "$ME" | awk '{print $1}'; }
vault_eth(){ $CALL "$POOL_MANAGER" 'balanceOf(address,uint256)(uint256)' "$FEE_VAULT" 0 | awk '{print $1}'; }
round_id() { $CALL "$ROUND_MANAGER" 'roundCount()(uint256)' | awk '{print $1}'; }
cand_count(){ $CALL "$ROUND_MANAGER" 'candidateCount()(uint256)' | awk '{print $1}'; }
head_index(){ $CALL "$ROUND_MANAGER" 'headIndex()(uint256)' | awk '{print $1}'; }
# F6 bond schedule. `currentBond` is what registerCandidate demands RIGHT NOW (the open round's
# pinned bond, or bondFor(headIndex + 1) when no round is open); `bond_for` prices a FUTURE round.
current_bond() { $CALL "$ROUND_MANAGER" 'currentBond()(uint256)' | awk '{print $1}'; }
bond_for()      { $CALL "$ROUND_MANAGER" 'bondFor(uint256)(uint256)' "$1" | awk '{print $1}'; }
# F10 PAGINATED candidate enumeration. `candidateIds(roundId)` still exists for the tiny case, but
# a spammed round can return an array too large for an eth_call, so the driver walks pages. Prints
# one id per line, in registration order.
CAND_PAGE_SIG='candidateIds(uint256,uint256,uint256)(uint256[],uint256)'
cand_ids() { # cand_ids <roundId> [pageSize]
  local rid="$1" limit="${2:-2}" off=0 total=1 out page
  while [ "$off" -lt "$total" ]; do
    out=$($CALL "$ROUND_MANAGER" "$CAND_PAGE_SIG" "$rid" "$off" "$limit")
    # cast prints the array on line 1 and `total` on line 2
    page=$(echo "$out" | sed -n 1p | tr -d '[]' | tr ',' '\n' | sed -E 's/\[[^]]*\]//g' | tr -d ' ' | sed '/^$/d')
    total=$(echo "$out" | sed -n 2p | awk '{print $1}')
    if [ -n "$page" ]; then echo "$page"; fi
    off=$((off + limit))
    if [ "$total" = "0" ]; then break; fi
  done
}
# Active liquidity of canonical link <index>. NOT `PoolManager.getLiquidity` - v4 exposes pool
# state only through `extsload`/StateLibrary, so there is no such external function and calling
# it reverts with empty data. FamilyLens.chainView does the StateLibrary read for us; liquidity
# is the LAST field of LinkView.
# LinkView fields: index, token, parent, creator, poolId, spotSqrtPriceX96, parentReserve,
# tokenReserve, liquidity. The `sed` strips only cast's SCIENTIFIC-NOTATION suffixes
# (`[2.88e26]`), which always start with a digit - a blanket `\[[^]]*\]` would swallow the
# opening bracket of the array itself and everything up to the first `]`.
LINK_SIG='chainView(uint256,uint256)((uint256,address,address,address,bytes32,uint160,uint256,uint256,uint128)[])'
link_field() { $CALL "$LENS" "$LINK_SIG" "$1" "$1" | sed -E 's/\[[0-9][^]]*\]//g' | tr -d '[]()' \
                 | awk -F',' -v n="$2" '{print $n}' | tr -d ' '; }
liq()      { link_field "$1" 9; }
spot()     { link_field "$1" 6; }
# consult() returns (twapSqrtPriceX96, coveredSeconds) on two lines.
twap_of()  { $CALL "$HOOK" 'consult(bytes32,uint32)(uint160,uint32)' "$1" 1800 | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
# The SLOW ring (F4): 64 observations, one per 3 h, differenced over SLOW_TWAP_WINDOW = 7 days.
# BidDeployer floors a link's price with it only once it covers SLOW_TWAP_MIN_COVERAGE = 1 day, so
# on a pool minutes old this reports ~0 s and the keeper path prices on the fast TWAP alone.
SLOW_WINDOW=604800
SLOW_MIN_COVERAGE=86400
slow_twap_of() { $CALL "$HOOK" "consultSlow(bytes32,uint32)(uint160,uint32)" "$1" "$SLOW_WINDOW" | sed -E 's/\[[^]]*\]//g' | tr -d ' '; }
slow_obs()     { $CALL "$HOOK" 'slowObservationCount(bytes32)(uint256)' "$1" | awk '{print $1}'; }
# "does the slow average actually floor this link's price today?" - the exact condition in
# BidDeployer._priceFor. Echoes `used` or `unavailable (<coverage>s of 86400)`.
slow_status() { # slow_status <poolId>
  local s c
  s=$(slow_twap_of "$1" | sed -n 1p); c=$(slow_twap_of "$1" | sed -n 2p)
  if [ "${s:-0}" != "0" ] && [ "${c:-0}" -ge "$SLOW_MIN_COVERAGE" ]; then
    echo "used (slow sqrtP=$s, ${c}s covered)"
  else
    echo "unavailable (${c:-0}s of ${SLOW_MIN_COVERAGE}s slow coverage, slowObs=$(slow_obs "$1")) -> priced on the 1800 s TWAP alone, SlowTwapUnavailable expected"
  fi
}

# BidDeployer._requireWithinBand: coverage must reach the full 1800 s TWAP_WINDOW and spot must be
# within +/-TWAP_BAND_BPS (3%) of the TWAP *sqrt* price. Every keeper call is guarded by this.
band_ok() { # band_ok <canonical index> <poolId>
  local s t c
  s=$(spot "$1"); t=$(twap_of "$2" | sed -n 1p); c=$(twap_of "$2" | sed -n 2p)
  python -c "import sys
s,t,c=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
sys.exit(0 if c>=1800 and t and t*9700<=s*10000<=t*10300 else 1)" "$s" "$t" "$c"
}
# A swap right before a keeper call leaves spot outside the band until the 1800 s TWAP catches
# up. Rather than revert with PriceOutOfBand, wait for it (warped on the fork, real time live).
wait_for_band() { # wait_for_band <canonical index> <poolId> <label>
  local i
  for i in $(seq 1 16); do
    if band_ok "$1" "$2"; then echo "   $3 pool inside the TWAP band (attempt $i)"; return 0; fi
    echo "   $3 pool outside the +/-3% TWAP band (spot=$(spot "$1") twap=$(twap_of "$2" | tr '\n' '/')); waiting 150 s"
    wait_until $(( $(now_ts) + 150 )) "$3 TWAP convergence"
  done
  echo "   !! $3 pool still outside the band after 16 attempts; the keeper call will revert" >&2
  return 1
}
obs()      { $CALL "$HOOK" 'observationCount(bytes32)(uint256)' "$1" | awk '{print $1}'; }
# has_event <txhash> <event signature> - true when the receipt carries that topic0. Used to record
# which branch of a call actually fired (e.g. SlowTwapUnavailable), not to decide success.
has_event() {
  local topic; topic=$(cast keccak "$2")
  cast receipt "$1" --rpc-url "$RPC" --json | jq -e --arg t "$topic" \
    '[.logs[].topics[0]] | index($t) != null' >/dev/null
}
# vnum <sig> [arg] - a FeeVault uint view. The arg is passed ONLY when present: cast rejects an
# empty positional ("encode length mismatch: expected 0 types, got 1") for a no-arg signature.
vnum()     { local s="$1"; shift; $CALL "$FEE_VAULT" "$s" "$@" | awk '{print $1}'; }
# dnum - the same, for the BidDeployer's keeper sizing views (bidCap, maxParentForDeploy).
dnum()     { local s="$1"; shift; $CALL "$BID_DEPLOYER" "$s" "$@" | awk '{print $1}'; }

# Candidate struct field order. F6 inserted `bond` at position 4, which pushed `avg` from 5 to 6:
#   1 roundId, 2 token, 3 creator, 4 bond, 5 submitted, 6 avg, 7 tFirstAttained, 8.. key
CAND_SIG='candidateInfo(uint256)((uint256,address,address,uint256,bool,int256,uint64,(address,address,uint24,int24,address)))'
cand_field() { $CALL "$ROUND_MANAGER" "$CAND_SIG" "$1" | tr -d '()' | cut -d',' -f"$2" | tr -d ' ' | sed -E 's/\[[^]]*\]//g'; }
CAND_TOKEN_F=2; CAND_BOND_F=4; CAND_AVG_F=6
# Round struct field order: openedAt, registrationEnd, tradingStart, tradingEnd, submitEnd,
# finalized, hasWinner, hasBest, hUsed, bondWei (F6, new at 10), parentIndex, parentToken, ...
round_field() { # round_field <roundId> <field-index>
  $CALL "$ROUND_MANAGER" 'roundInfo(uint256)((uint64,uint64,uint64,uint64,uint64,bool,bool,bool,uint256,uint256,uint256,address,uint256,uint256,uint256,int256,uint64,bytes32))' "$1" \
    | tr -d '()' | tr ',' '\n' | sed -n "$2p" | sed -E 's/\[[^]]*\]//g' | tr -d ' '
}
ROUND_BOND_F=10

approve_max() { # approve_max <label> <token> <spender>
  local cur; cur=$($CALL "$2" 'allowance(address,address)(uint256)' "$ME" "$3" | awk '{print $1}')
  if bge "1000000000000000000000000000000" "$cur"; then
    send "$1" "$2" 'approve(address,uint256)' "$3" "$MAXU"
    log "$1" "$TXHASH" "$GASUSED" "approved $3 to move $2"
  fi
}

# ---- projected cost, and the hard abort ------------------------------------------------------
# F6: the bond is per ROUND, so round 1 (competing for headIndex + 1) and round 2 (headIndex + 2)
# are priced separately off the on-chain schedule instead of off a single deploy constant.
H_IDX=$(head_index)
BOND_R1=$(bond_for $((H_IDX + 1))); BOND_R2=$(bond_for $((H_IDX + 2)))
BONDS_TOTAL=$(badd "$(bmul 3 "$BOND_R1")" "$BOND_R2")
PROJ=$(badd "$(wei "$GENESIS_BUY_ETH")" "$(wei "$SECOND_BUY_ETH")" "$(wei "$ROUND2_BUY_ETH")" \
             "$BONDS_TOTAL" "$(wei "$GAS_BUDGET_ETH")" "$(wei "$DEPLOY_COST_ETH")")
CAP=$(wei "$BUDGET_CAP_ETH")
echo "== projected gross ETH cost =="
printf '   %-32s %s\n' "deploy (measured on fork)" "$(wei "$DEPLOY_COST_ETH")"
printf '   %-32s %s\n' "genesis buy" "$(wei "$GENESIS_BUY_ETH")"
printf '   %-32s %s\n' "genesis 2nd (oracle) buy" "$(wei "$SECOND_BUY_ETH")"
printf '   %-32s %s\n' "3 x bondFor($((H_IDX + 1)))=$BOND_R1 + bondFor($((H_IDX + 2)))=$BOND_R2" "$BONDS_TOTAL"
printf '   %-32s %s\n' "round 2 candidate buy" "$(wei "$ROUND2_BUY_ETH")"
printf '   %-32s %s\n' "gas headroom @ $GAS_PRICE wei/gas" "$(wei "$GAS_BUDGET_ETH")"
printf '   %-32s %s wei = %s ETH\n' "TOTAL" "$PROJ" "$(cast from-wei "$PROJ")"
printf '   %-32s %s wei = %s ETH\n' "cap" "$CAP" "$BUDGET_CAP_ETH"
echo "   (returns not netted: 1 bond refunded to the winner, the CAND-C sell, claimDev and the"
echo "    two keeper bounties all come back)"
if bge "$PROJ" "$CAP" && [ "$PROJ" != "$CAP" ]; then
  echo "!! ABORT: projected $PROJ wei exceeds the $CAP wei cap" >&2; exit 3
fi

# ---- start -----------------------------------------------------------------------------------
mkdir -p docs
if [ ! -f "$RUNLOG" ]; then echo "# Testnet run log (chain $CHAIN_ID)" > "$RUNLOG"; fi
{
  echo
  echo "## Live round driver ($MODE) - started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "| step | tx hash | explorer | gas used | observed effect |"
  echo "|---|---|---|---|---|"
} >> "$RUNLOG"

ETH_START=$(bal_eth)
echo "== deployer $ME  balance $(cast from-wei "$ETH_START") ETH =="
if ! bge "$ETH_START" "$PROJ"; then
  echo "!! ABORT: balance $ETH_START wei is below the projected $PROJ wei" >&2; exit 3
fi

# ---- (a) buy genesis --------------------------------------------------------------------------
TOK0=$(bal_tok "$GENESIS"); V0=$(vault_eth)
EXTRA="--value ${GENESIS_BUY_ETH}ether"
send "a. buy genesis" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
EXTRA=""
T_GENESIS_BUY=$(now_ts)
TOK1=$(bal_tok "$GENESIS"); V1=$(vault_eth)
BOUGHT=$(bsub "$TOK1" "$TOK0"); FEE=$(bsub "$V1" "$V0")
log "a. buy genesis ${GENESIS_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
  "received $BOUGHT FAM0 (wei-tokens); fee accrued to the vault: $FEE wei ETH (1% protocol + 750 ppm hop); attributed to canonical index 0"

# ---- (a2) second genesis buy, purely to write the pool's 2nd oracle observation ---------------
wait_until $((T_GENESIS_BUY + 130)) "genesis buy + 130 s (OBS_MIN_SPACING is 120 s)"
EXTRA="--value ${SECOND_BUY_ETH}ether"
send "a2. genesis oracle buy" "$ROUTER" 'buyExactIn(uint256,uint256,address,uint256)' 0 0 "$ME" 4
EXTRA=""
log "a2. genesis oracle buy ${SECOND_BUY_ETH} ETH" "$TXHASH" "$GASUSED" \
  "genesis pool observationCount=$(obs "$GENESIS_POOL") (>=2 is a precondition of every FeeVault keeper path)"

# ---- (b) register 3 candidates ----------------------------------------------------------------
for NAME in CAND-A CAND-B CAND-C; do
  # F6: read the bond the RoundManager wants right now. The first registration opens the round and
  # pins its bond at bondFor(headIndex + 1); the next two must match that pinned value exactly, or
  # `registerCandidate` reverts WrongBond.
  BOND_NOW=$(current_bond)
  EXTRA="--value ${BOND_NOW}wei"
  send "b. register $NAME" "$FACTORY" 'registerCandidate(string,string,string)' "$NAME" "$NAME" "ipfs://$NAME"
  EXTRA=""
  CID=$(( $(cand_count) - 1 )); CAND_IDS+=("$CID")
  log "b. register $NAME" "$TXHASH" "$GASUSED" \
    "candidateId=$CID, bond $BOND_NOW wei escrowed (currentBond(); stored on the candidate as bond=$(cand_field "$CID" $CAND_BOND_F))"
done
RID=$(round_id)
T_START=$(round_field "$RID" 3); T_END=$(round_field "$RID" 4); T_SUBMIT=$(round_field "$RID" 5)
BOND_R=$(round_field "$RID" $ROUND_BOND_F)
H=$($CALL "$ROUND_MANAGER" 'threshold()(uint256)' | awk '{print $1}')
# F10: enumerate the round's candidates through the PAGINATED view (pages of 2) and cross-check it
# against what the registrations returned. An indexer facing a spammed round has no other option.
PAGED_IDS=$(cand_ids "$RID" 2 | tr '\n' ' ' | sed 's/ $//')
if [ "$PAGED_IDS" != "${CAND_IDS[*]}" ]; then
  fail "b. candidateIds pagination" "-" "paginated candidateIds($RID) returned [$PAGED_IDS], expected [${CAND_IDS[*]}]"
fi
note "round $RID opened" "tradingStart=$T_START tradingEnd=$T_END submitEnd=$T_SUBMIT, H=$H (average absorption over TRADING_S=900 s), round bondWei=$BOND_R (F6 schedule), candidateIds via the paginated view (pages of 2) = [$PAGED_IDS]"

# ---- (c) wait for trading start ----------------------------------------------------------------
wait_until "$T_START" "tradingStart"

# ---- (d) buy candidates at +5 s, paying in HEAD (genesis) tokens through the router -------------
wait_until $((T_START + 5)) "tradingStart+5s (past the 3 s snipe-tax window)"
approve_max "d0. approve FAM0 -> router" "$GENESIS" "$ROUTER"
# bps are taken against the CURRENT balance, so the sequence 40% / 50% / 33.33% of what is left
# spends 40% / 30% / 10% of the ORIGINAL genesis holding.
i=0
for spec in "A 4000 40" "B 5000 30" "C 3333 10"; do
  set -- $spec; LETTER=$1; BPS=$2; PCT=$3
  CID=${CAND_IDS[$i]}; i=$((i+1))
  CTOK=$(cand_field "$CID" $CAND_TOKEN_F)
  AMT=$(python -c "import sys;print(int(sys.argv[1])*int(sys.argv[2])//10000)" "$(bal_tok "$GENESIS")" "$BPS")
  CB=$(bal_tok "$CTOK")
  send "d. buy CAND-$LETTER" "$ROUTER" 'buyCandidateWithParent(uint256,uint256,uint256,address)' "$CID" "$AMT" 0 "$ME"
  [ "$LETTER" = "A" ] && T_A_BUY=$(now_ts)
  OUT=$(bsub "$(bal_tok "$CTOK")" "$CB")
  log "d. buy CAND-$LETTER ($PCT% of genesis)" "$TXHASH" "$GASUSED" \
    "spent $AMT FAM0 -> received $OUT CAND-$LETTER (token $CTOK) via FamilyRouter.buyCandidateWithParent (head-token-funded, one hop, transferFrom); ATTRIBUTED through the candidate sentinel; absorption counts toward H=$H"
done

# ---- (e) sell half of C at +60 s, through the ROUTER (attributed, ETH out) ----------------------
wait_until $((T_START + 60)) "tradingStart+60s"
C_ID=${CAND_IDS[2]}; C_TOK=$(cand_field "$C_ID" $CAND_TOKEN_F)
approve_max "e0. approve CAND-C -> router" "$C_TOK" "$ROUTER"
C_HALF=$(bhalf "$(bal_tok "$C_TOK")")
E0=$(bal_eth); V2=$(vault_eth)
send "e. sellCandidate CAND-C" "$ROUTER" 'sellCandidate(uint256,uint256,uint256,address,uint256)' "$C_ID" "$C_HALF" 0 "$ME" 8
E1=$(bal_eth); V3=$(vault_eth)
log "e. sellCandidate half of CAND-C" "$TXHASH" "$GASUSED" \
  "sold $C_HALF CAND-C for ETH through the router (candidate -> head -> ETH); deployer ETH $E0 -> $E1; vault +$(bsub "$V3" "$V2") wei; C's accumulator nets down (sells are untaxed, 1%/1% symmetric); ATTRIBUTED to CAND-C's creator + the head's creator"

# ---- (f) submit scores after T_end, in the order C, B, A ---------------------------------------
wait_until $((T_END + 1)) "tradingEnd"
for idx in 2 1 0; do
  LETTER=$(echo "A B C" | cut -d' ' -f$((idx+1)))
  CID=${CAND_IDS[$idx]}
  send "f. submitScore CAND-$LETTER" "$ROUND_MANAGER" 'submitScore(uint256)' "$CID"
  AVG=$(cand_field "$CID" $CAND_AVG_F)
  log "f. submitScore CAND-$LETTER (id $CID)" "$TXHASH" "$GASUSED" "avg=$AVG vs H=$H -> $(bge "$AVG" "$H" && echo CLEARS || echo below)"
done

# ---- (g) finalize ------------------------------------------------------------------------------
wait_until $((T_SUBMIT + 1)) "submitEnd"
ETH_BEFORE_FIN=$(bal_eth); EARMARK0=$(vnum 'genesisBidEarmark()(uint256)')
send "g. finalize" "$ROUND_MANAGER" 'finalize()'
HEAD=$($CALL "$ROUND_MANAGER" 'head()(address)' | awk '{print $1}')
HEAD_IDX=$($CALL "$ROUND_MANAGER" 'headIndex()(uint256)' | awk '{print $1}')
ETH_AFTER_FIN=$(bal_eth); EARMARK1=$(vnum 'genesisBidEarmark()(uint256)')
log "g. finalize round $RID" "$TXHASH" "$GASUSED" \
  "head=$HEAD canonicalIndex=$HEAD_IDX; deployer ETH $ETH_BEFORE_FIN -> $ETH_AFTER_FIN (winner bond $BOND_R refunded, the amount stored on the winning candidate); genesisBidEarmark $EARMARK0 -> $EARMARK1 (the losers' bonds, forfeited)"

# ---- (h) claim dev fees ------------------------------------------------------------------------
DEVBAL=$(vnum 'devBalance()(uint256)')
if [ "$DEVBAL" != "0" ]; then
  send "h. claimDev" "$FEE_VAULT" 'claimDev(address)' "$ME"
  log "h. claimDev" "$TXHASH" "$GASUSED" "claimed $DEVBAL wei ETH of developer fees to $ME"
else
  note "h. claimDev" "skipped: devBalance == 0"
fi

# ---- (i) open a second round against the new head, and buy its candidate through the router ----
# Round 2 competes for headIndex + 1 = 2, so its bond is bondFor(2) - the same as round 1's until
# the schedule doubles, but read from the chain rather than assumed (F6).
BOND_NOW=$(current_bond)
EXTRA="--value ${BOND_NOW}wei"
send "i. register CAND-D (round 2)" "$FACTORY" 'registerCandidate(string,string,string)' "CAND-D" "CAND-D" "ipfs://CAND-D"
EXTRA=""
CID_D=$(( $(cand_count) - 1 ))
RID2=$(round_id); T_START2=$(round_field "$RID2" 3); BOND_R2_ACTUAL=$(round_field "$RID2" $ROUND_BOND_F)
PAGED_IDS2=$(cand_ids "$RID2" 2 | tr '\n' ' ' | sed 's/ $//')
log "i. register CAND-D (round $RID2)" "$TXHASH" "$GASUSED" \
  "candidateId=$CID_D, parent = the new head $HEAD (index $HEAD_IDX); bond $BOND_NOW wei = currentBond() = round bondWei $BOND_R2_ACTUAL (bondFor($((HEAD_IDX + 1)))); paginated candidateIds($RID2) = [$PAGED_IDS2]"

wait_until $((T_START2 + 5)) "round $RID2 tradingStart+5s"
D_TOK=$(cand_field "$CID_D" $CAND_TOKEN_F)
SLEEVE_BEFORE=$(vnum 'claimableEth(uint256)(uint256)' 1)
EXTRA="--value ${ROUND2_BUY_ETH}ether"
send "i. buyCandidate CAND-D" "$ROUTER" 'buyCandidate(uint256,uint256,address,uint256)' "$CID_D" 0 "$ME" 8
EXTRA=""
T_D_BUY=$(now_ts)
SLEEVE_AFTER=$(vnum 'claimableEth(uint256)(uint256)' 1)
log "i. buyCandidate CAND-D (${ROUND2_BUY_ETH} ETH, router)" "$TXHASH" "$GASUSED" \
  "ETH -> FAM0 -> head -> CAND-D in one unlock; now hold $(bal_tok "$D_TOK") CAND-D; ATTRIBUTED via the candidate sentinel (half the creator share to CAND-D's creator, half to the head's); claimableEth(1) $SLEEVE_BEFORE -> $SLEEVE_AFTER, which is what funds deployAncestor(1); round $RID2 is closed in step (j) below, not left running"

# ---- (j) close round 2 with NO clearing candidate ----------------------------------------------
# Runs 1 and 2 both LEFT round 2 open, which had two costs: `finalize` had never been observed
# taking the else branch, and an open round makes a deployment un-handoverable (a continuation may
# only adopt an IDLE prior - RoundManager.isIdle / _adoptIfContinuation). Both are closed here by
# simply not submitting CAND-D's score: with no submission the round has no `hasBest`, so
# `finalize` crowns nobody, the head does not move, the threshold decays x0.9 and CAND-D's bond is
# forfeited into the genesis earmark like any other loser's.
T_SUBMIT2=$(round_field "$RID2" 5)
wait_until $((T_SUBMIT2 + 1)) "round $RID2 submitEnd (CAND-D deliberately unscored)"
HEAD_B2=$(head_index); EARMARK_B2=$(vnum 'genesisBidEarmark()(uint256)')
H_B2=$($CALL "$ROUND_MANAGER" 'threshold()(uint256)' | awk '{print $1}')
send "j. finalize round $RID2 (no winner)" "$ROUND_MANAGER" 'finalize()'
HEAD_A2=$(head_index); EARMARK_A2=$(vnum 'genesisBidEarmark()(uint256)')
H_A2=$($CALL "$ROUND_MANAGER" 'threshold()(uint256)' | awk '{print $1}')
IDLE=$($CALL "$ROUND_MANAGER" 'isIdle()(bool)' | awk '{print $1}')
if [ "$HEAD_A2" != "$HEAD_B2" ]; then
  fail "j. finalize round $RID2" "$TXHASH" "the head MOVED ($HEAD_B2 -> $HEAD_A2) on a round with no submitted score"
fi
if [ "$IDLE" != "true" ]; then fail "j. finalize round $RID2" "$TXHASH" "isIdle() is $IDLE after finalize"; fi
log "j. finalize round $RID2 (no clearing candidate)" "$TXHASH" "$GASUSED" \
  "no score was submitted, so hasBest=false and finalize took the ELSE branch: head UNCHANGED at index $HEAD_A2, threshold decayed $H_B2 -> $H_A2 (x0.9 per failed round, floor 0.25x), CAND-D's bond forfeited (genesisBidEarmark $EARMARK_B2 -> $EARMARK_A2), isIdle()=$IDLE so this version can now be handed over"

# ---- (k) keeper paths, once every pool's 1800 s TWAP is usable ----------------------------------
HEAD_POOL=$($CALL "$ROUND_MANAGER" 'poolIdOf(uint256)(bytes32)' 1 | awk '{print $1}')
wait_until $((T_GENESIS_BUY + 1810)) "genesis pool TWAP_WINDOW (1800 s) coverage"
wait_until $((T_A_BUY + 1810)) "head pool TWAP_WINDOW (1800 s) coverage"
# _requireWithinBand compares SPOT against the 1800 s TWAP, so coverage is necessary but not
# sufficient: a pool is only back inside the +/-3% band once the whole window post-dates its LAST
# swap. Step (i) buyCandidate routes ETH -> FAM0 -> head -> CAND-D and is therefore the last swap
# on BOTH pools; at the scaled 0.01 ETH size it moves the (thin) head pool ~5% off its average and
# wait_for_band alone cannot poll it back. Wait out one full window from that swap instead.
wait_until $((T_D_BUY + 1810)) "TWAP_WINDOW (1800 s) coverage since the round-2 buy"
SLOW_NOTE=""
for P in "0:genesis:$GENESIS_POOL" "1:head:$HEAD_POOL"; do
  IFS=':' read -r IDX NAME PID <<< "$P"
  echo "   $NAME pool consult(1800) = $(twap_of "$PID" | tr '\n' '/') obs=$(obs "$PID") spot=$(spot "$IDX")"
  # F4, header note 4: report the SLOW ring too. On a deployment this young it cannot have a day
  # of history, so the keeper prices on the fast average alone - expected, and recorded as such.
  ST=$(slow_status "$PID")
  echo "   $NAME pool consultSlow(7d): $ST"
  SLOW_NOTE="$SLOW_NOTE$NAME: $ST. "
  wait_for_band "$IDX" "$PID" "$NAME" || true
done
note "slow (7 day) TWAP status" "$SLOW_NOTE"

# (k1) genesis bid: forfeited bonds + the genesis hop pot, deployed as a locked ETH bid.
# deployGenesisBid(0) asks for NONE of genesis's ETH sleeve: the earmark and the hop pot are
# still drawn, up to whatever the 2%-of-active-reserve size cap allows. That is the small bid.
# The 1% bounty is paid ON TOP of the deposit now, symmetric with deployAncestor: the pots have
# to fund deposit x 1.01, and the size cap bounds the DEPOSIT.
EARMARK=$(vnum 'genesisBidEarmark()(uint256)')
REINF0=$(vnum 'reinforcementEth(uint256)(uint256)' 0)
CLAIM0=$(vnum 'claimableEth(uint256)(uint256)' 0)
# F4 daily drawdown: what generation 0 is OWED vs what it may be drawn for in this 24 h window.
# This call requests NONE of the sleeve, so the limit cannot bind here; both numbers go on the
# record anyway, ahead of the sleeve-spending call in (k2).
DRAW0=$(vnum 'drawableEth(uint256)(uint256)' 0)
echo "   genesis sleeve: claimableEth(0)=$CLAIM0 drawableEth(0)=$DRAW0 (DAILY_DRAW_BPS = 10% per 24 h)"
LOCKER_L_BEFORE=$(liq 0)
EB=$(bal_eth)
send "k1. deployGenesisBid(0)" "$BID_DEPLOYER" 'deployGenesisBid(uint256)' 0
EA=$(bal_eth)
log "k1. deployGenesisBid (keeper)" "$TXHASH" "$GASUSED" \
  "earmark $EARMARK -> $(vnum 'genesisBidEarmark()(uint256)'), genesis reinforcement/sleeve $REINF0/$CLAIM0 (drawableEth(0)=$DRAW0 under the 10%/24 h limit; this call requests none of the sleeve); the Locker placed the drawn ETH as a permanently locked bid below spot; keeper ETH $EB -> $EA (1% bounty, minus gas); genesis active L $LOCKER_L_BEFORE -> $(liq 0) (the bid sits out of range by design)"

# (k1b) AUDIT 3 - generation 1's hop pot, deployed ON ITS OWN. `deployAncestor` can only spend a
# generation's PARENT-denominated hop fees as a top-up beside an ETH-sleeve purchase, so a link
# with no sleeve had no deployment path at all; this one draws the pot alone, pays its bounty in
# the same parent token and touches no ETH. Run BEFORE (k2) so that what it draws is visibly its
# own pot rather than (k2)'s leftovers.
POT1_BEFORE=$(vnum 'reinforcementBalance(address)(uint256)' "$GENESIS")
G_BEFORE=$(bal_tok "$GENESIS"); CAP1=$(dnum 'bidCap(uint256)(uint256)' 1)
echo "   generation 1 hop pot: reinforcementBalance($GENESIS)=$POT1_BEFORE bidCap(1)=$CAP1"
if [ "$POT1_BEFORE" = "0" ]; then
  note "k1b. deployHopPot(1)" "skipped: generation 1's parent-denominated hop pot is empty"
else
  send "k1b. deployHopPot(1)" "$BID_DEPLOYER" 'deployHopPot(uint256)' 1
  log "k1b. deployHopPot(1) (keeper)" "$TXHASH" "$GASUSED" \
    "generation 1's PARENT-denominated hop pot deployed on its own (audit 3): reinforcementBalance(FAM0) $POT1_BEFORE -> $(vnum 'reinforcementBalance(address)(uint256)' "$GENESIS"), keeper paid $(bsub "$(bal_tok "$GENESIS")" "$G_BEFORE") FAM0 as the 1% bounty IN PARENT TOKENS (no ETH moved, bidCap(1)=$CAP1); the rest was locked as a bid below spot in the #1 pool; head pool active L now $(liq 1)"
fi

# (k2) ancestor bid for generation 1: the KEEPER supplies the parent (genesis) tokens and is paid
# their TWAP value + 1% out of generation 1's own ETH.
# maxParentForDeploy(1) is already sized against FeeVault.drawableEth(1), i.e. the F4 10%-per-24 h
# rate limit is baked into it; claimableEth(1) is what generation 1 is owed in total. When the two
# differ the deployment is SHORT BY DESIGN and a keeper comes back tomorrow for the rest.
CLAIM1=$(vnum 'claimableEth(uint256)(uint256)' 1)
DRAW1=$(vnum 'drawableEth(uint256)(uint256)' 1)
DWIN=$($CALL "$FEE_VAULT" 'drawBucket(uint256)(uint64,uint256,uint256)' 1 | sed -E 's/\[[^]]*\]//g' | tr -d ' ' | tr '\n' '/')
MAXP=$(dnum 'maxParentForDeploy(uint256)(uint256)' 1)
CAPP=$(dnum 'bidCap(uint256)(uint256)' 1)
# AUDIT 5 / MIN_BOUNTY_WEI. Run 3's finding was that `maxParentForDeploy` returned 0 whenever
# `drawableEth(j)` was at or below MIN_BOUNTY_WEI (3e14 here) even though `deployAncestor` would
# have accepted the call: its bounty is min(max(1% of the ETH value, MIN_BOUNTY_WEI), 25% of the
# ETH value), so below the floor the bounty is a quarter of the value and ethValue * 1.25 <=
# drawableEth still goes through. The sizing view now inverts all three branches of that bounty
# (BidDeployer._maxEthValueFor) and returns a REAL number at beta scale, so this driver uses the
# view. The hand-sizing below is kept only as a fallback for a view that still reads 0.
MAXP_VIEW="$MAXP"; SIZING="maxParentForDeploy view=$MAXP_VIEW used directly"
if [ "$MAXP" = "0" ] && [ "$DRAW1" != "0" ]; then
  ETHV=$(python -c "import sys;print(int(sys.argv[1])*4*98//500)" "$DRAW1")
  if [ "$ETHV" != "0" ]; then
    MAXP=$(dnum 'parentForEthValue(uint256,uint256)(uint256)' 0 "$ETHV")
    SIZING="maxParentForDeploy view=0, HAND-SIZED bound=$MAXP under the audit-5 bounty floor"
    echo "   maxParentForDeploy(1)=0 because drawableEth(1)=$DRAW1 <= MIN_BOUNTY_WEI=$(dnum 'MIN_BOUNTY_WEI()(uint256)'); hand-sized at ethValue=$ETHV -> parentForEthValue(0,.)=$MAXP"
  fi
fi
PARENT_AMT=$(bmin "$MAXP" "$CAPP" "$(bal_tok "$GENESIS")")
echo "   generation 1 sleeve: claimableEth(1)=$CLAIM1 drawableEth(1)=$DRAW1 drawBucket(updatedAt/available/cap)=$DWIN"
echo "   deployAncestor(1): maxParentForDeploy=$MAXP (drawable-limited) bidCap=$CAPP -> parentAmount=$PARENT_AMT"
if [ "$PARENT_AMT" = "0" ]; then
  note "k2. deployAncestor(1)" "skipped: parentAmount would be 0 (maxParentForDeploy=$MAXP_VIEW bidCap=$CAPP drawableEth(1)=$DRAW1)"
else
  approve_max "k2a. approve FAM0 -> BidDeployer" "$GENESIS" "$BID_DEPLOYER"
  GB=$(bal_tok "$GENESIS"); EB=$(bal_eth)
  send "k2. deployAncestor(1)" "$BID_DEPLOYER" 'deployAncestor(uint256,uint256)' 1 "$PARENT_AMT"
  GA=$(bal_tok "$GENESIS"); EA=$(bal_eth)
  # Header note 4: on a fresh deployment no pool has a day of slow history, so the conversion runs
  # on the 1800 s average alone and the contract SAYS SO with SlowTwapUnavailable(j). Record which
  # branch actually fired instead of letting either pass silently.
  if has_event "$TXHASH" 'SlowTwapUnavailable(uint256)'; then
    SLOW_EV="SlowTwapUnavailable(1) emitted - at least one link had < 1 day of slow history, so the price is the 1800 s TWAP alone (expected on a fresh deploy)"
  else
    SLOW_EV="no SlowTwapUnavailable - every link had >= 1 day of slow history and the conversion was floored by the 7 day average"
  fi
  echo "   $SLOW_EV"
  log "k2. deployAncestor(1, $PARENT_AMT) (keeper)" "$TXHASH" "$GASUSED" \
    "keeper delivered $(bsub "$GB" "$GA") FAM0 and was paid $(bsub "$EA" "$EB") wei ETH net of gas (TWAP value + 1% bounty) out of generation 1's sleeve; sized at parentAmount=$PARENT_AMT ($SIZING; drawableEth(1)=$DRAW1 of claimableEth(1)=$CLAIM1, 10%/24 h limit) and bidCap=$CAPP; $SLOW_EV; the Locker placed the bid below spot in the head pool; head pool active L now $(liq 1)"
fi

# ---- (l) the winner's creator claims their share -------------------------------------------------
# The other half of the lazy-pull claim surface: `claimDev` ran in (h), `claimCreator` never has.
# The head token's creator balance is what this round's own attributed trades booked to it (40% of
# the protocol fee, halved with the challenged head while the round was still Trading).
CREATOR_OF_HEAD=$($CALL "$ROUND_MANAGER" 'creatorOf(address)(address)' "$HEAD" | awk '{print $1}')
CREDITED=$($CALL "$FEE_VAULT" 'creatorRecipient(address)(address)' "$HEAD" | awk '{print $1}')
CBAL=$(vnum 'creatorBalance(address)(uint256)' "$HEAD")
if [ "$CBAL" = "0" ]; then
  note "l. claimCreator(head)" "skipped: creatorBalance($HEAD) == 0"
elif [ "$(echo "$CREDITED" | tr 'A-Z' 'a-z')" != "$(echo "$ME" | tr 'A-Z' 'a-z')" ]; then
  note "l. claimCreator(head)" "skipped: creatorRecipient($HEAD) is $CREDITED, not this key"
else
  EB=$(bal_eth)
  send "l. claimCreator(head)" "$FEE_VAULT" 'claimCreator(address,address)' "$HEAD" "$ME"
  log "l. claimCreator (winner's creator)" "$TXHASH" "$GASUSED" \
    "claimed $CBAL wei ETH of the head token's creator share to $ME (creatorOf($HEAD)=$CREATOR_OF_HEAD, creatorRecipient=$CREDITED); deployer ETH $EB -> $(bal_eth); creatorBalance($HEAD) now $(vnum 'creatorBalance(address)(uint256)' "$HEAD")"
fi

# ---- summary -----------------------------------------------------------------------------------
ETH_END=$(bal_eth)
{
  echo
  echo "Round complete. Deployer ETH: $ETH_START -> $ETH_END wei (net spent $(bsub "$ETH_START" "$ETH_END") wei)."
  echo "Head is now \`$HEAD\` at canonical index $HEAD_IDX. Round $RID2 (CAND-D, id $CID_D) was FINALIZED with no winner, so nothing is open and the deployment is idle."
} >> "$RUNLOG"
echo "== done: net spent $(bsub "$ETH_START" "$ETH_END") wei, head=$HEAD idx=$HEAD_IDX =="
