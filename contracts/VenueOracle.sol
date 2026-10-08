// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IVenueOracle} from "./interfaces/IVenueOracle.sol";
import {V4UnlockGuard} from "./libraries/V4UnlockGuard.sol";

/// @title VenueOracle
/// @notice Time-weighted average of the external ETH/$DOLL venue's sqrt price, fed by two fixed
/// pokers (keeper and cold backup). No owner, no setters: every parameter is a constant or an
/// immutable.
///
/// @dev Invariants:
/// - READS. Only {poke} reads the venue. {consult}, {startPrice} and {latest} read stored
///   samples only, so a swap earlier in the same transaction cannot move them.
/// - ACCESS. Only POKER_A / POKER_B may poke, and never inside a PoolManager unlock, so no one can
///   sample a price they moved and will move back inside their own unlock.
/// - WEIGHTING. `cum += last * dt` with `last` the PREVIOUS stored sample (left endpoint): the
///   interval [t_i, t_i+1] is priced by sample i, the newest sample has zero weight, and a time
///   jump is priced by the sample before it.
/// - LIMITER. Each stored sample is the spot clamped to +-MAX_STEP_BPS of the previous stored
///   sample. It clamps, never rejects, so a real move is followed (10x in price: at most 39
///   pokes). The constructor seed is the only unclamped sample; it and every clamped sample set
///   `tClamped`, and fast-only pricing needs `tClamped` before the fast window's reference entry.
/// - WRAP. `cum` is uint192 and wraps (unchecked); it is only ever differenced, which is exact
///   mod 2^192 while the true sum between two ring entries stays below 2^192, i.e. for spans
///   under 2^32 s at any sqrtP < 2^160.
/// - RINGS. Both rings are written from the one accumulator, each on its own spacing;
///   cardinality x spacing >= window + spacing (64 x 60 >= 660, 64 x 1800 >= 88200).
/// - COVERAGE. Short history is reported (covered < window, status bits), never passed off as a
///   full window; no path divides by zero.
/// - TIME. Timestamps only (block.number is the parent chain's on Arbitrum-family chains);
///   `block.timestamp` is assumed non-decreasing. Same-second pokes are spaced out (no dt = 0
///   sample).
contract VenueOracle is IVenueOracle {
    using StateLibrary for IPoolManager;

    uint256 public constant FAST_CARD = 64;
    uint64 public constant FAST_SPACING_S = 60;
    uint256 public constant SLOW_CARD = 64;
    uint64 public constant SLOW_SPACING_S = 1800;
    uint32 public constant FAST_WINDOW_S = 600;
    uint32 public constant SLOW_WINDOW_S = 86400;
    uint256 public constant MAX_STEP_BPS = 300;
    uint64 public constant MAX_AGE_S = 1800;
    /// @notice How old the newest sample may be for {startPrice} to still answer with the
    /// averages when staleness is the only thing wrong (status == STALE). Older than this, or no
    /// data at all, and it answers (0, status): the factory then opens on its constant fallback.
    uint64 public constant STALE_GRACE_S = 86400;

    uint8 internal constant NO_DATA = 1;
    uint8 internal constant STALE = 2;
    uint8 internal constant FAST_SHORT = 4;
    uint8 internal constant SLOW_SHORT = 8;

    IPoolManager public immutable poolManager;
    PoolId public immutable venueId;
    address public immutable POKER_A;
    address public immutable POKER_B;

    struct Observation {
        uint64 t;
        uint192 cum;
    }

    /// @dev Running accumulator and the time of the newest stored sample (one slot).
    uint192 internal cum;
    uint64 internal tLast;
    /// @dev Newest stored sample, clamped streak and the two ring counts (one slot). Counts only
    /// grow; an entry's slot is `index % CARD`.
    uint160 internal last;
    uint32 internal streak;
    uint32 internal fastCount;
    uint32 internal slowCount;
    /// @dev Time of the newest clamped sample; the constructor seed counts as one (it is never
    /// checked against a previous sample). Gates fast-only pricing in {startPrice} (own slot).
    uint64 internal tClamped;

    Observation[64] internal fastObs;
    Observation[64] internal slowObs;

    error VenueNotNative();
    error VenueNotInitialized();
    error VenueNoLiquidity();
    error ZeroPoker();

    /// @dev Same venue checks as EthZap: native ETH as currency0, initialised, in-range liquidity.
    /// Seeds the first sample from spot, unclamped (there is no previous sample to clamp to), and
    /// never inside a PoolManager unlock (no seeding a price the deployer moved and moves back).
    constructor(IPoolManager _poolManager, PoolKey memory venueKey, address pokerA, address pokerB) {
        if (Currency.unwrap(venueKey.currency0) != address(0)) revert VenueNotNative();
        if (pokerA == address(0) || pokerB == address(0)) revert ZeroPoker();
        if (V4UnlockGuard.isInsideUnlock(address(_poolManager))) revert InsideUnlock();
        PoolId id = venueKey.toId();
        (uint160 spot,,,) = _poolManager.getSlot0(id);
        if (spot == 0) revert VenueNotInitialized();
        if (_poolManager.getLiquidity(id) == 0) revert VenueNoLiquidity();

        poolManager = _poolManager;
        venueId = id;
        POKER_A = pokerA;
        POKER_B = pokerB;

        uint64 nowTs = uint64(block.timestamp);
        last = spot;
        tLast = nowTs;
        tClamped = nowTs; // the seed is unverified: it blocks fast-only pricing while in the window
        fastObs[0] = Observation({t: nowTs, cum: 0});
        slowObs[0] = Observation({t: nowTs, cum: 0});
        fastCount = 1;
        slowCount = 1;
        emit Poked(spot, spot, false, 0);
    }

    /// @inheritdoc IVenueOracle
    function poke() external returns (bool written) {
        if (msg.sender != POKER_A && msg.sender != POKER_B) revert NotPoker();
        if (V4UnlockGuard.isInsideUnlock(address(poolManager))) revert InsideUnlock();

        uint64 nowTs = uint64(block.timestamp);
        uint64 t0 = tLast; // never 0: the constructor seeds a sample
        if (nowTs - t0 < FAST_SPACING_S) return false;

        (uint160 spot,,,) = poolManager.getSlot0(venueId);
        if (spot == 0) {
            emit PokeSkipped(1);
            return false;
        }
        if (poolManager.getLiquidity(venueId) == 0) {
            emit PokeSkipped(2);
            return false;
        }

        uint160 prev = last;
        uint192 c = cum;
        // left endpoint: the elapsed interval is priced by the previous stored sample
        unchecked {
            c += uint192(uint256(prev) * uint256(nowTs - t0));
        }

        // one step, rounded down, either way: |stored - prev| <= prev * MAX_STEP_BPS / 1e4 exactly
        uint256 step = uint256(prev) * MAX_STEP_BPS / 1e4;
        uint256 lo = prev - step;
        uint256 hi = prev + step;
        // the result lies between prev and spot, both < 2^160, so the cast is exact
        uint160 stored = spot < lo ? uint160(lo) : spot > hi ? uint160(hi) : spot;
        uint32 s = stored != spot ? streak + 1 : 0;

        cum = c;
        tLast = nowTs;
        last = stored;
        streak = s;
        if (stored != spot) tClamped = nowTs;
        fastCount = _write(fastObs, fastCount, FAST_CARD, nowTs, c, FAST_SPACING_S);
        slowCount = _write(slowObs, slowCount, SLOW_CARD, nowTs, c, SLOW_SPACING_S);

        emit Poked(spot, stored, stored != spot, s);
        return true;
    }

    /// @inheritdoc IVenueOracle
    function consult(uint32 window, bool slow) external view returns (uint160, uint32, uint64) {
        return slow ? _consult(slowObs, slowCount, SLOW_CARD, window) : _consult(fastObs, fastCount, FAST_CARD, window);
    }

    /// @inheritdoc IVenueOracle
    /// @dev Both windows are measured back from the NEWEST entry, not from now, so a ring that
    /// went stale still reports full coverage: stale-only within STALE_GRACE_S answers the
    /// averages up to the last sample (the recent market, flagged) rather than leaving the
    /// factory on its constant, which may sit far from the market on either side.
    /// Fast-only (status == SLOW_SHORT): answers max(fast, slow so far) only when every sample
    /// from the fast window's reference entry on is a real, unclamped spot (no seed, no clamp).
    /// Once the fast ring covers its window the slow ring holds at least two entries.
    function startPrice() external view returns (uint160 sqrtP, uint8 status) {
        if (fastCount < 2) status |= NO_DATA;
        uint64 age = uint64(block.timestamp) - tLast;
        if (age > MAX_AGE_S) status |= STALE;
        (uint160 f, uint32 cf, uint64 nT) = _consult(fastObs, fastCount, FAST_CARD, FAST_WINDOW_S);
        (uint160 s, uint32 cs,) = _consult(slowObs, slowCount, SLOW_CARD, SLOW_WINDOW_S);
        if (cf < FAST_WINDOW_S) status |= FAST_SHORT;
        if (cs < SLOW_WINDOW_S) status |= SLOW_SHORT;
        // every sample from the window's reference entry on was a real, unclamped spot
        bool fastOnly = status == SLOW_SHORT && tClamped < nT - cf;
        if (status == 0 || fastOnly || (status == STALE && age <= STALE_GRACE_S)) sqrtP = f > s ? f : s;
    }

    /// @inheritdoc IVenueOracle
    function latest() external view returns (uint160, uint64, uint32) {
        return (last, tLast, streak);
    }

    /// @dev Append (nowTs, c) when the newest entry is at least `spacing` old; returns the count.
    function _write(Observation[64] storage ring, uint32 count, uint256 card, uint64 nowTs, uint192 c, uint64 spacing)
        internal
        returns (uint32)
    {
        if (nowTs - ring[(count - 1) % card].t < spacing) return count;
        ring[count % card] = Observation({t: nowTs, cum: c});
        return count + 1;
    }

    /// @dev Two-point average between the newest entry N and the newest entry at or before
    /// N.t - window (the oldest held entry when the ring does not reach that far back).
    function _consult(Observation[64] storage ring, uint32 count, uint256 card, uint32 window)
        internal
        view
        returns (uint160, uint32, uint64)
    {
        uint256 held = count < card ? count : card;
        uint256 oldest = count < card ? 0 : count % card;
        Observation memory n = ring[(count - 1) % card];
        uint64 target = n.t > window ? n.t - window : 0;

        // entries are ordered by time from `oldest`: binary search for the newest t <= target
        uint256 best;
        uint256 lo;
        uint256 hi = held - 1;
        while (lo <= hi) {
            uint256 mid = (lo + hi) / 2;
            if (ring[(oldest + mid) % card].t <= target) {
                best = mid;
                lo = mid + 1;
            } else {
                if (mid == 0) break;
                hi = mid - 1;
            }
        }
        Observation memory r = ring[(oldest + best) % card];
        if (n.t <= r.t) return (0, 0, n.t);
        uint64 covered = n.t - r.t;
        uint192 span;
        unchecked {
            span = n.cum - r.cum; // exact mod 2^192
        }
        // covered saturates rather than truncates, so a long span can never report as short
        return (
            uint160(uint256(span) / covered),
            covered > type(uint32).max ? type(uint32).max : uint32(covered),
            n.t
        );
    }
}
