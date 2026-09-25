// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice `adoptGenesis` used `_head != address(0)` as its
/// write-once flag, so adopting `address(0)` would have left the flag unset and allowed a second
/// call to re-seat canonical index 0, the head and the edge currency. Unreachable as deployed
/// (`onlyFactory`, and the factory constructor refuses a zero or codeless `GENESIS_TOKEN`), but
/// fixed anyway with a dedicated `_genesisAdopted` flag and an explicit `token == address(0)`
/// check.
contract Review5eTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    /// @notice The zero-address path this fix closes: called directly as the factory (bypassing
    /// the factory's own zero/codeless guard, which is what makes it latent rather than live), it
    /// must revert rather than seat the sentinel. A second, unwired stack is used because the
    /// fixture's own trunk is already adopted by {setUp}.
    function test_adoptGenesisRefusesTheZeroAddress() public {
        Stack memory s2 = _deployStack(false, steward, address(0));

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.BadGenesisToken.selector);
        s2.roundManager.adoptGenesis(address(0), address(this));
    }

    /// @notice A second adoption reverts after the first, with the dedicated flag - not by
    /// coincidentally re-reading a token field as a sentinel.
    function test_adoptGenesisRevertsOnASecondCall() public {
        // this stack's genesis was already adopted in setUp() via factory.wire()
        vm.prank(address(factory));
        vm.expectRevert(RoundManager.GenesisAlreadyAdopted.selector);
        roundManager.adoptGenesis(address(0xBEEF), address(this));
    }

    /// @notice The scenario the write-once bug's counterexample took: attempt to adopt `address(0)` first. With
    /// the fix that attempt itself reverts and leaves the flag unset, so pin that a real adoption
    /// can still happen exactly once afterwards, and that a further attempt then hits the
    /// dedicated flag rather than re-seating canonical index 0.
    function test_zeroAddressAdoptionCannotBeFollowedByARealOne() public {
        Stack memory s2 = _deployStack(false, steward, address(0));

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.BadGenesisToken.selector);
        s2.roundManager.adoptGenesis(address(0), address(this));

        // the flag was never set by the reverted call, and priorRegistry is still zero, so a real
        // adoption succeeds - exactly once
        vm.prank(address(s2.factory));
        s2.roundManager.adoptGenesis(address(doll), address(this));
        assertEq(s2.roundManager.canonical(0), address(doll), "the real token seated once");

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.GenesisAlreadyAdopted.selector);
        s2.roundManager.adoptGenesis(address(0xCAFE), address(this));
        assertEq(s2.roundManager.canonical(0), address(doll), "index 0 was not re-seated");
    }

    /// @notice The production path: the factory adopts exactly once inside {wire}, and calling it
    /// again from anybody is a no-op, not a second adoption.
    function test_factoryPathStillAdoptsExactlyOnce() public {
        assertTrue(factory.genesisAdopted(), "set up wires, and wiring adopts");
        assertEq(roundManager.canonical(0), address(doll));
        assertEq(roundManager.head(), address(doll));
        assertEq(roundManager.headIndex(), 0);

        factory.wire();
        vm.prank(address(0xA11CE));
        factory.wire();

        assertEq(roundManager.canonical(0), address(doll), "still the same token at index 0");
        assertEq(roundManager.head(), address(doll), "still the same head");
        assertEq(roundManager.headIndex(), 0, "still index 0");
    }
}
