// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {V4UnlockGuard} from "../../contracts/libraries/V4UnlockGuard.sol";
import {V4UnlockGuardProbe} from "../../contracts/libraries/V4UnlockGuardProbe.sol";

/// @notice REVIEW 2, the REN-01 guard against the LIVE singleton. Every `notInsideUnlock` in the
/// stack is one `exttload` of a slot v4-core's internal `Lock` library defines; the constant is
/// pinned in `V4UnlockGuard` rather than imported, because the library is internal. A slot that
/// does not match the deployed manager's does not fail loudly - it answers `false` forever, and
/// every guard in the protocol silently becomes a no-op.
///
/// @dev So the binding is measured here, on the real manager at {ForkBase.POOL_MANAGER}, with the
/// same {V4UnlockGuardProbe} the deploy script runs after deployment: `false` outside an unlock,
/// `true` inside one it opens, and `false` again once that unlock has closed. Skips cleanly when
/// `RPC_TESTNET` is unset.
contract UnlockGuardForkTest is ForkBase {
    function setUp() public {
        _selectFork();
    }

    /// @notice The guard reads the live manager's lock flag, both ways round.
    function testFork_theUnlockGuardIsBoundToTheLiveManager() public {
        _requireFork();

        assertFalse(V4UnlockGuard.isInsideUnlock(POOL_MANAGER), "false outside an unlock");
        V4UnlockGuardProbe probe = new V4UnlockGuardProbe();
        assertTrue(probe.probe(POOL_MANAGER), "true inside an unlock of our own");
        assertFalse(V4UnlockGuard.isInsideUnlock(POOL_MANAGER), "and false again once it closed");
    }

    /// @notice ...and the slot it reads is v4-core's own, by v4-core's own definition, on the
    /// chain the stack deploys to.
    function testFork_theGuardSlotIsV4sOwn() public {
        _requireFork();
        assertEq(V4UnlockGuard.IS_UNLOCKED_SLOT, bytes32(uint256(keccak256("Unlocked")) - 1), "Lock slot");
    }
}
