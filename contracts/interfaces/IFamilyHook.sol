// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

interface IFamilyHook {
    /// @param registered Set once by the factory; every hook entrypoint rejects unregistered pools.
    /// @param isGenesis True only for the single ETH-paired genesis pool (protocol fee applies).
    /// @param parentIsCurrency0 Which side of the key is the parent (numeraire) currency.
    /// @param initSqrtPriceX96 The exact price the pool must be initialized at.
    /// @param tradingStart Unix time before which swaps revert; 0 means trading is open. It also
    /// FLOORS the scoring window: a round whose closing window reaches back further than the
    /// pool has existed is measured from the pool's own open instead.
    /// @param scoreSlotS Slot size of this pool's COARSE score ring, chosen by the round that
    /// launched it so that {SCORE_COARSE_SLOTS} slots cover the round's closing window plus the
    /// settlement tail. Zero at registration means {FamilyHook} `DEFAULT_SCORE_SLOT_S`.
    /// @param R Running net parent absorbed by this pool (score rate), parent units.
    /// @param tLast Timestamp of the last score accumulation.
    /// @param tObs Timestamp of the last price observation.
    /// @param acc Time-integral of `R` (the score), parent-units-seconds.
    /// @param cumSqrtP Cumulative `sqrtPriceX96 * dt`, the TWAP observation accumulator.
    /// @dev PACKED BY HOT PATH, not by reading order. A scored swap touches exactly four slots:
    ///   slot 0 - every flag and window it READS (one SLOAD, never written after registration);
    ///   slot 1 - `R`/`tLast`, the score rate pair written together by every accumulation;
    ///   slot 2 - `acc`, which needs its own word (see the range note below);
    ///   slot 3 - `cumSqrtP`/`tObs`, written together by every observation.
    /// `initSqrtPriceX96` is read once, in `beforeInitialize`, and is therefore parked last in
    /// its own cold slot rather than stealing 20 bytes of the hot flag slot.
    ///
    /// RANGES. `R` is net parent absorbed: bounded by the parent's total supply, 1e9 * 1e18 =
    /// 1e27 < 2^90, so `int128` has ~37 bits of headroom and `+=` still reverts on overflow
    /// rather than wrapping. `acc` is `R * seconds`: 2^90 * 2^32 = 2^122 of magnitude, which
    /// would fit in `int128` only without headroom, so it keeps a full word. `cumSqrtP` is a
    /// deliberately WRAPPING accumulator (`sqrtPriceX96 * dt`) that is only ever differenced:
    /// truncating it to 192 bits keeps every difference exact as long as the gap between the two
    /// points differenced is under 2^32 seconds (136 years) at the maximum sqrt price.
    struct RegisteredPool {
        bool registered;
        bool isGenesis;
        bool parentIsCurrency0;
        uint64 tradingStart;
        uint32 scoreSlotS;
        int128 R;
        uint64 tLast;
        int256 acc;
        uint192 cumSqrtP;
        uint64 tObs;
        uint160 initSqrtPriceX96;
    }

    /// @notice One entry of a per-pool SCORE RING: the state of the accumulator immediately
    /// BEFORE the first swap of a slot (MECHANISM_v3 sec.3).
    ///
    /// @dev There are TWO such rings per pool, and a round needs both because it is scored on a
    /// CLOSING WINDOW `[T_end - W, T_end]`:
    ///   - the FAST ring, {SCORE_SLOTS} slots of {SCORE_SLOT_S} seconds, covers the span the
    ///     random end can land in, so the `T_end` edge is resolved to 5 seconds;
    ///   - the COARSE ring, {SCORE_COARSE_SLOTS} slots of the pool's own `scoreSlotS`, reaches
    ///     back past `T_end - W` (and past the whole settlement tail), so the far edge - and a
    ///     trailing average over the same `W` at any later time - is resolvable too.
    /// The coarse slot is `ceil((W + tail) / (SCORE_COARSE_SLOTS - 1))`, so the two rings
    /// together are 100 entries whatever `W` is: 22 s resolution on a 15-minute window, 180 s on
    /// a 3-hour one. Reconstruction is EXACT except for a second swap inside the same slot as an
    /// edge, where the pre-swap state is used - which never counts flow later than the edge.
    /// @dev `(acc, R)` is exact for every instant in `[tState, tSwap)`, because `R` is constant
    /// between swaps: `acc(t) = acc + R * (t - tState)`. That is what lets {averageAt}
    /// reconstruct a candidate's score at a `T_end` nobody could know in advance, from a ring
    /// that is only written when a swap actually happens - the gaps need no entries at all.
    /// `tSwap` doubles as the slot tag, so a slot is written at most once however many swaps it
    /// carries, and `tSwap == 0` marks an entry that has never been written.
    /// @param tSwap Timestamp of the FIRST swap of the slot this entry belongs to.
    /// @param tState Timestamp the `(acc, R)` pair below was last updated at.
    /// @param R The absorption rate that stood for the whole of `[tState, tSwap)`.
    /// @param acc The accumulator as of `tState`.
    struct ScoreCheckpoint {
        uint64 tSwap;
        uint64 tState;
        int128 R;
        int256 acc;
    }

    /// @notice One entry of a per-pool TWAP ring (written at most once per `OBS_MIN_SPACING`,
    /// 120 s, in the fast ring and once per `SLOW_OBS_MIN_SPACING`, 3 h, in the slow one).
    /// @dev Every timestamp in this hook - observations, score accumulation, the snipe window and
    /// the trading windows - assumes `block.timestamp` is MONOTONE NON-DECREASING across blocks.
    /// That holds on Ethereum L1 and on the Arbitrum Orbit stack this is deployed to; a chain
    /// whose clock can move backwards would make the `dt` subtractions underflow inside a swap.
    /// @dev One slot: `cumSqrtP` is the same 192-bit wrapping accumulator as
    /// `RegisteredPool.cumSqrtP`, so a ring write is a single SSTORE.
    struct Observation {
        uint64 timestamp;
        uint192 cumSqrtP;
    }

    event PoolRegistered(PoolId indexed poolId, bool isGenesis, uint160 initSqrtPriceX96, uint64 tradingStart);
    event FeeAccrued(
        PoolId indexed poolId,
        Currency indexed currency,
        uint256 hopFee,
        uint256 protocolFee,
        address indexed sender,
        uint256 attribution
    );
    event SnipeTaxed(PoolId indexed poolId, address indexed sender, uint256 taxPpm, uint256 amount);
    event ScoreUpdated(PoolId indexed poolId, int256 acc, int128 R, uint64 tLast);
    /// @notice The successor version's router was resolved after the handover took effect; from
    /// here on this hook trusts its `hookData` for attribution exactly as it trusts its own.
    event SuccessorRouterResolved(address indexed successorRouter);
    /// @notice F2: the handover took effect but the successor did not answer the resolution
    /// within its gas budget. The answer is cached as "no successor router" FOREVER; swaps keep
    /// working and attribution stays with this version's own router.
    event SuccessorRouterUnresolvable();

    error NotFactory();
    error NotPoolManager();
    error PoolNotRegistered();
    error PoolAlreadyRegistered();
    error WrongInitialPrice();
    error OnlyLocker();
    error LiquidityIsLocked();
    error DonationDisabled();
    error TradingNotStarted();
    error HookNotImplemented();
    error InvalidHookAddress();
    error HopFeeTooHigh();
    /// @notice {averageAt} was asked for a time the score ring can no longer reconstruct: every
    /// checkpoint that bracketed it has been overwritten by more than {SCORE_RING_S} of swaps.
    error CheckpointUnavailable();
    /// @notice {averageOver} was asked for an empty or inverted window.
    error BadScoreWindow();
    /// @notice A pool was registered as the genesis pool with a non-zero `tradingStart`. The
    /// genesis pool has no snipe window, and the protocol fee and the snipe tax are mutually
    /// exclusive per pool precisely because of that; see {registerPool}.
    error GenesisHasNoSnipeWindow();

    /// @notice Record a pool the factory has just created. Factory only, once per key.
    /// @dev `isGenesis` implies `tradingStart == 0`: the genesis pool is never sniped, which is
    /// what keeps the parent-side rates from ever summing above 100% on one pool. The hook
    /// enforces it here rather than trusting the factory to keep passing zero.
    function registerPool(
        PoolKey calldata key,
        bool isGenesis,
        uint160 initSqrtPriceX96,
        uint64 tradingStart,
        uint32 scoreSlotS,
        bool parentIsCurrency0
    ) external;

    function poolInfo(PoolId id) external view returns (RegisteredPool memory);

    /// @notice The v4 PoolManager this hook is bound to. Exposed so that the rest of the stack
    /// can read the manager's unlock state without carrying an immutable of its own (REN-01).
    function poolManager() external view returns (IPoolManager);

    /// @notice Score state as of the last swap. The accumulator is NEVER frozen (MECHANISM_v3
    /// sec.1): the round is scored from the ring at `T_end`, and the same accumulator keeps
    /// running afterwards as the public measure of the pool's support.
    function scoreState(PoolId id) external view returns (int256 acc, int128 R, uint64 tLast);

    /// @notice The pool's average net parent absorption over the CLOSING WINDOW
    /// `[tStart, tEnd]` - the score a round is decided on - reconstructed from the checkpoint
    /// rings. `tStart` is floored at the pool's own `tradingStart`, so a window that reaches back
    /// further than the pool has existed simply measures what there is.
    /// @return avg `(acc(tEnd) - acc(tStart)) / (tEnd - tStart)`, in parent units.
    /// @return tLastBefore The last score update at or before `tEnd` - the round's
    /// `tFirstAttained` tie-breaker (L4).
    function averageOver(PoolId id, uint64 tStart, uint64 tEnd) external view returns (int256 avg, uint64 tLastBefore);

    /// @notice Time-weighted average net parent absorption over roughly the last `window`
    /// seconds - a coin's "trailing support" - plus the number of seconds the average actually
    /// covers, exactly as {consult} reports its own coverage. A read-only measure: nothing in
    /// the protocol pays out on it.
    function trailingAverage(PoolId id, uint32 window) external view returns (int256 avg, uint32 coveredSeconds);

    /// @notice One entry of the pool's FAST score ring, by ring index.
    function scoreCheckpoint(PoolId id, uint256 index) external view returns (ScoreCheckpoint memory);

    /// @notice One entry of the pool's COARSE score ring, by ring index.
    function coarseCheckpoint(PoolId id, uint256 index) external view returns (ScoreCheckpoint memory);

    /// @notice Time-weighted average `sqrtPriceX96` over roughly the last `window` seconds, plus
    /// the number of seconds of history that average actually covers (0 when the pool has no
    /// observations and the spot price is reported instead).
    function consult(PoolId id, uint32 window) external view returns (uint160 twapSqrtPriceX96, uint32 coveredSeconds);

    /// @notice As {consult}, but over the SLOW observation ring (F4): an average a short pump
    /// cannot move, used by `BidDeployer` as `min(fast, slow)` when it has enough coverage.
    function consultSlow(PoolId id, uint32 window)
        external
        view
        returns (uint160 twapSqrtPriceX96, uint32 coveredSeconds);

    /// @notice How many price observations this pool has ever written.
    function observationCount(PoolId id) external view returns (uint256);

    /// @notice How many SLOW price observations this pool has ever written.
    function slowObservationCount(PoolId id) external view returns (uint256);
}
