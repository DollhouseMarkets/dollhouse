// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IExttload} from "v4-core/src/interfaces/IExttload.sol";

/// @title V4UnlockGuard
/// @notice Reads whether a v4 `PoolManager` is currently UNLOCKED, i.e. whether the call is
/// happening inside somebody's `unlock` callback and flash accounting is open.
///
/// @dev v4-core keeps that state in one transient slot (`Lock.IS_UNLOCKED_SLOT`, defined as
/// `bytes32(uint256(keccak256("Unlocked")) - 1)`) and the `PoolManager` inherits `Exttload`, so
/// the slot is readable from outside with a single `exttload`. The constant is pinned here
/// rather than imported because `Lock` is an internal library: the value is asserted against
/// v4-core's own definition in `test/Review2.t.sol`.
///
/// REN-01: the protocol's OWN swap path legitimately runs inside an unlock - the hook's
/// `afterSwap` and the vault's `accrue` are called from there on every swap, and those are not
/// guarded. What is guarded is the round machine and the pull-payment claims, none of which the
/// protocol ever reaches from inside an unlock of its own.
library V4UnlockGuard {
    /// @notice The transient slot v4-core's `Lock` library holds the unlock flag in.
    bytes32 internal constant IS_UNLOCKED_SLOT = 0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;

    function isInsideUnlock(address poolManager) internal view returns (bool) {
        return IExttload(poolManager).exttload(IS_UNLOCKED_SLOT) != bytes32(0);
    }
}
