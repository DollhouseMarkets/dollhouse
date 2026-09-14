// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice The two mutable addresses in the system - the steward and the developer fee address -
/// move only on a public 7-day delay: announced by the current holder, executable by anyone once
/// the delay is up, cancellable by the current holder before it takes effect. Nothing else about
/// either role changes: the steward's whole surface is still the sunset switch, and the dev
/// ledger is still a single balance claimable by whoever holds the role at claim time.
contract RoleTransferTest is RoundTestBase {
    address internal newSteward = address(0x57E2);
    address internal newDeveloper = address(0xDE72);

    function setUp() public {
        _setUpFamily();
    }

    // ---------------------------------------------------------------------------------
    // steward (RoundManager)
    // ---------------------------------------------------------------------------------

    function test_stewardTransferWaitsOutTheDelayAndIsPermissionlessToExecute() public {
        assertEq(roundManager.ROLE_TRANSFER_DELAY(), 7 days, "the role delay is 7 days");
        uint64 t0 = uint64(block.timestamp);

        vm.prank(steward);
        roundManager.announceStewardTransfer(newSteward);
        assertEq(roundManager.pendingSteward(), newSteward);
        assertEq(roundManager.stewardTransferAt(), t0 + 7 days);
        assertEq(roundManager.steward(), steward, "nothing changes at the announcement");

        vm.expectRevert(RoundManager.TransferNotReady.selector);
        roundManager.executeStewardTransfer();
        vm.warp(t0 + 7 days - 1);
        vm.expectRevert(RoundManager.TransferNotReady.selector);
        roundManager.executeStewardTransfer();

        // anyone may push it through once the public delay has elapsed
        vm.warp(t0 + 7 days);
        vm.prank(address(0xCAFE));
        roundManager.executeStewardTransfer();
        assertEq(roundManager.steward(), newSteward);
        assertEq(roundManager.pendingSteward(), address(0));
        assertEq(roundManager.stewardTransferAt(), 0);
    }

    function test_sunsetPowersFollowTheNewSteward() public {
        vm.prank(steward);
        roundManager.announceStewardTransfer(newSteward);
        vm.warp(block.timestamp + 7 days);
        roundManager.executeStewardTransfer();

        // the old steward keeps nothing at all
        vm.prank(steward);
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(address(vault));

        // and the new one has the whole (one-function) surface
        vm.prank(newSteward);
        roundManager.announceSunset(address(vault));
        assertEq(roundManager.successor(), address(vault));
        assertEq(roundManager.sunsetAt(), uint64(block.timestamp) + roundManager.sunsetDelay());

        vm.prank(steward);
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.cancelSunset();
        vm.prank(newSteward);
        roundManager.cancelSunset();
        assertEq(roundManager.sunsetAt(), 0, "the new steward can take it back too");
    }

    function test_onlyTheStewardAnnouncesOrCancelsAndOnePendingAtATime() public {
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceStewardTransfer(newSteward);

        vm.prank(steward);
        vm.expectRevert(RoundManager.BadSteward.selector);
        roundManager.announceStewardTransfer(address(0));

        vm.prank(steward);
        roundManager.announceStewardTransfer(newSteward);
        vm.prank(steward);
        vm.expectRevert(RoundManager.TransferPending.selector);
        roundManager.announceStewardTransfer(address(0xF00D));

        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.cancelStewardTransfer();

        // cancel, and the announcement is gone for good
        vm.prank(steward);
        roundManager.cancelStewardTransfer();
        assertEq(roundManager.pendingSteward(), address(0));
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(RoundManager.NoTransferPending.selector);
        roundManager.executeStewardTransfer();
        assertEq(roundManager.steward(), steward, "still the original steward");

        // and a second announcement still works
        vm.prank(steward);
        roundManager.announceStewardTransfer(newSteward);
        vm.warp(block.timestamp + 7 days);
        roundManager.executeStewardTransfer();
        assertEq(roundManager.steward(), newSteward);
    }

    // ---------------------------------------------------------------------------------
    // developer (FeeVault)
    // ---------------------------------------------------------------------------------

    function test_developerTransferWaitsOutTheDelayAndIsPermissionlessToExecute() public {
        assertEq(vault.ROLE_TRANSFER_DELAY(), 7 days, "the role delay is 7 days");
        uint64 t0 = uint64(block.timestamp);

        vm.prank(developer);
        vault.announceDeveloperTransfer(newDeveloper);
        assertEq(vault.pendingDeveloper(), newDeveloper);
        assertEq(vault.developerTransferAt(), t0 + 7 days);
        assertEq(vault.developer(), developer, "nothing changes at the announcement");

        vm.expectRevert(FeeVault.TransferNotReady.selector);
        vault.executeDeveloperTransfer();
        vm.warp(t0 + 7 days - 1);
        vm.expectRevert(FeeVault.TransferNotReady.selector);
        vault.executeDeveloperTransfer();

        vm.warp(t0 + 7 days);
        vm.prank(address(0xCAFE));
        vault.executeDeveloperTransfer();
        assertEq(vault.developer(), newDeveloper);
        assertEq(vault.pendingDeveloper(), address(0));
        assertEq(vault.developerTransferAt(), 0);
    }

    /// @notice The dev ledger is one balance, not a per-holder one: what accrued BEFORE the
    /// transfer is claimable by whoever is the developer at claim time (disclosed on
    /// {FeeVault-developer}), and the old holder can no longer claim anything.
    function test_accruedDevBalanceIsClaimableByWhoeverHoldsTheRoleAtClaimTime() public {
        _buyGenesis(1 ether);
        uint256 accrued = vault.devBalance();
        assertGt(accrued, 0, "the ETH edge accrued a developer share");

        vm.prank(developer);
        vault.announceDeveloperTransfer(newDeveloper);
        vm.warp(block.timestamp + 7 days);
        vault.executeDeveloperTransfer();

        vm.prank(developer);
        vm.expectRevert(FeeVault.NotDeveloper.selector);
        vault.claimDev(developer);

        vm.prank(newDeveloper);
        uint256 claimed = vault.claimDev(newDeveloper);
        assertEq(claimed, accrued, "the whole accrued balance went with the role");
        assertEq(newDeveloper.balance, accrued);
        assertEq(vault.devBalance(), 0);
        _assertSolvent();
    }

    function test_onlyTheDeveloperAnnouncesOrCancelsAndOnePendingAtATime() public {
        vm.expectRevert(FeeVault.NotDeveloper.selector);
        vault.announceDeveloperTransfer(newDeveloper);

        vm.prank(developer);
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.announceDeveloperTransfer(address(0));

        vm.prank(developer);
        vault.announceDeveloperTransfer(newDeveloper);
        vm.prank(developer);
        vm.expectRevert(FeeVault.TransferPending.selector);
        vault.announceDeveloperTransfer(address(0xF00D));

        vm.expectRevert(FeeVault.NotDeveloper.selector);
        vault.cancelDeveloperTransfer();

        vm.prank(developer);
        vault.cancelDeveloperTransfer();
        assertEq(vault.pendingDeveloper(), address(0));
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(FeeVault.NoTransferPending.selector);
        vault.executeDeveloperTransfer();
        assertEq(vault.developer(), developer, "still the original developer");

        vm.prank(developer);
        vault.announceDeveloperTransfer(newDeveloper);
        vm.warp(block.timestamp + 7 days);
        vault.executeDeveloperTransfer();
        assertEq(vault.developer(), newDeveloper);
    }
}
