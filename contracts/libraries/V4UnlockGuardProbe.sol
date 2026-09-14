// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {V4UnlockGuard} from "./V4UnlockGuard.sol";

/// @title V4UnlockGuardProbe
/// @notice The deploy-time SELF-CHECK for the REN-01 guard, and nothing else. It is not part of
/// the protocol: the deploy script deploys one, calls {probe} once against the PoolManager the
/// stack was wired to, records the answer in the broadcast log and never touches it again.
///
/// @dev {V4UnlockGuard} reads one transient slot of v4-core's internal `Lock` library through
/// `exttload`. A manager that does not implement `Exttload` makes the read REVERT; a manager
/// whose lock slot differs makes it answer `false` forever, which is a guard that FAILS OPEN in
/// silence - every `notInsideUnlock` in the stack would be a no-op and nobody would notice.
/// `FamilyFactory.wire` pins down the cheap half (the read works, and answers `false` outside an
/// unlock). The other half cannot be checked from there without opening an unlock, so it is
/// checked here: this contract opens a throwaway unlock of its own, does nothing inside it, and
/// asserts the guard answers `true` while it is open.
contract V4UnlockGuardProbe is IUnlockCallback {
    /// @notice The guard did not answer `false` outside the unlock.
    error GuardFailsOpen();
    /// @notice The guard did not answer `true` inside the unlock: it is not bound to this
    /// manager's lock slot, so every `notInsideUnlock` in the stack is a no-op.
    error GuardNotBound();
    error NotPoolManager();

    /// @notice The manager of the unlock currently being probed, zero at rest.
    address public probing;

    /// @notice Exercise the guard against `poolManager`, both outside and inside an unlock.
    /// Reverts unless it reads `false` outside and `true` inside; returns `true` when it does.
    function probe(address poolManager) external returns (bool bound) {
        if (V4UnlockGuard.isInsideUnlock(poolManager)) revert GuardFailsOpen();
        probing = poolManager;
        bound = abi.decode(IPoolManager(poolManager).unlock(""), (bool));
        probing = address(0);
        if (!bound) revert GuardNotBound();
        // and the flag is transient: it is back to `false` the moment the unlock closed
        if (V4UnlockGuard.isInsideUnlock(poolManager)) revert GuardFailsOpen();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata) external view returns (bytes memory) {
        if (msg.sender != probing) revert NotPoolManager();
        return abi.encode(V4UnlockGuard.isInsideUnlock(msg.sender));
    }
}
