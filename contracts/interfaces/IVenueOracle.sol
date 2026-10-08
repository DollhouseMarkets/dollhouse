// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title IVenueOracle
/// @notice Averaged sqrt price of the external ETH/$DOLL venue pool (currency0 = ETH, currency1 =
/// $DOLL, so sqrtP^2 = $DOLL per ETH), sampled by two fixed pokers and never read from spot on
/// the consult path.
interface IVenueOracle {
    /// @notice A sample was written: `spotSqrtP` read from the venue, `storedSqrtP` after the step
    /// limiter, `clamped` when they differ, `clampedStreak` consecutive clamped samples.
    event Poked(uint160 spotSqrtP, uint160 storedSqrtP, bool clamped, uint32 clampedStreak);
    /// @notice A poke read an unusable venue and wrote nothing. `reason`: 1 uninitialised, 2 no
    /// in-range liquidity.
    event PokeSkipped(uint8 reason);

    /// @notice The caller is neither of the two immutable pokers.
    error NotPoker();
    /// @notice poke() was called while the PoolManager is unlocked (inside someone's unlock).
    error InsideUnlock();

    /// @notice Record one sample of the venue price. Poker only; outside any unlock. Returns
    /// false (no state change) within the spacing or when the venue is unusable.
    function poke() external returns (bool written);

    /// @notice Arithmetic mean of the stored sqrtP over about `window` seconds ending at the
    /// newest entry of the chosen ring (`slow` selects the 30-minute ring). `covered` is the span
    /// actually averaged (below `window` when history is short; 0 when there is none), `tNewest`
    /// the newest entry's timestamp. Never reads the venue.
    function consult(uint32 window, bool slow) external view returns (uint160 twapSqrtP, uint32 covered, uint64 tNewest);

    /// @notice max(fast 10 min average, slow 24 h average) when `status == 0`, and also when the
    /// only bit set is stale (2) while the newest sample is at most STALE_GRACE_S (24 h) old: then
    /// it is the averages up to that sample, with the stale bit; and when the only bit is
    /// slowShort (8) while the 10 min window holds no clamped or seed sample: max(fast, slow so
    /// far), status 8.
    /// Otherwise (0, status). Status bits:
    /// 1 noData, 2 stale, 4 fastShort, 8 slowShort.
    function startPrice() external view returns (uint160 sqrtP, uint8 status);

    /// @notice The newest stored sample, its timestamp and the current clamped streak.
    function latest() external view returns (uint160 stored, uint64 t, uint32 clampedStreak);

    /// @notice The PoolManager the venue lives on.
    function poolManager() external view returns (IPoolManager);

    /// @notice The venue pool this oracle samples (native ETH as currency0, $DOLL as currency1).
    function venueId() external view returns (PoolId);
}
