// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";

/// @notice Property tests for the role surface (docs/spec/PROPERTIES.md sec.3.10), tier F.
contract RolesPropTest is RoundTestBase {
    function setUp() public {
        steward = address(0x57E);
        _setUpEdge();
    }

    /// @notice ROL-05: for the steward role, `announceStewardTransfer(to)` is current-holder
    /// only, refuses `to == address(0)` and refuses to overwrite a pending transfer;
    /// `executeStewardTransfer()` is permissionless and reverts before `announcement + 7 days`;
    /// `cancelStewardTransfer()` is current-holder-only and repeatable.
    function testFuzz_ROL05_stewardTransferDelayAndAccess(address to, address stranger, uint256 early) public {
        vm.assume(to != address(0) && to != steward);
        vm.assume(stranger != steward);
        assertEq(roundManager.ROLE_TRANSFER_DELAY(), 7 days, "the delay is seven days");

        vm.prank(stranger);
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceStewardTransfer(to);

        vm.prank(steward);
        vm.expectRevert(RoundManager.BadSteward.selector);
        roundManager.announceStewardTransfer(address(0));

        vm.prank(steward);
        roundManager.announceStewardTransfer(to);
        uint64 at = roundManager.stewardTransferAt();

        vm.prank(steward);
        vm.expectRevert(RoundManager.TransferPending.selector);
        roundManager.announceStewardTransfer(to);

        vm.warp(at - bound(early, 1, 7 days));
        vm.prank(stranger);
        vm.expectRevert(RoundManager.TransferNotReady.selector);
        roundManager.executeStewardTransfer();

        vm.warp(at);
        vm.prank(stranger);
        roundManager.executeStewardTransfer();
        assertEq(roundManager.steward(), to, "the role moved");
        assertEq(roundManager.pendingSteward(), address(0), "and nothing is pending");
    }

    /// @notice ROL-05: a cancelled steward transfer never executes, and the holder may announce
    /// and cancel repeatedly.
    function testFuzz_ROL05_stewardTransferIsCancellable(address to, uint256 rounds) public {
        vm.assume(to != address(0) && to != steward);
        rounds = bound(rounds, 1, 4);

        for (uint256 i = 0; i < rounds; i++) {
            vm.prank(steward);
            roundManager.announceStewardTransfer(to);
            vm.prank(steward);
            roundManager.cancelStewardTransfer();
            assertEq(roundManager.stewardTransferAt(), 0, "the announcement is gone");
            vm.expectRevert(RoundManager.NoTransferPending.selector);
            roundManager.executeStewardTransfer();
        }
        assertEq(roundManager.steward(), steward, "the role never moved");
    }

    /// @notice ROL-05: the developer role obeys the same announce/delay/execute/cancel shape.
    function testFuzz_ROL05_developerTransferDelayAndAccess(address to, address stranger, uint256 early) public {
        vm.assume(to != address(0) && to != developer);
        vm.assume(stranger != developer);
        assertEq(vault.ROLE_TRANSFER_DELAY(), 7 days, "the delay is seven days");

        vm.prank(stranger);
        vm.expectRevert(FeeVault.NotDeveloper.selector);
        vault.announceDeveloperTransfer(to);

        vm.prank(developer);
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.announceDeveloperTransfer(address(0));

        vm.prank(developer);
        vault.announceDeveloperTransfer(to);
        uint64 at = vault.developerTransferAt();

        vm.prank(developer);
        vm.expectRevert(FeeVault.TransferPending.selector);
        vault.announceDeveloperTransfer(to);

        vm.warp(at - bound(early, 1, 7 days));
        vm.prank(stranger);
        vm.expectRevert(FeeVault.TransferNotReady.selector);
        vault.executeDeveloperTransfer();

        vm.warp(at);
        vm.prank(stranger);
        vault.executeDeveloperTransfer();
        assertEq(vault.developer(), to, "the role moved");
    }

    /// @notice ROL-07: `transferCreatorRecipient` sweeps the current `creatorBalance[token]`
    /// into the OLD recipient's `creatorAccrued` ledger, zeroes it, and refuses
    /// `to == address(0)`; a swept accrual survives any number of later transfers.
    function testFuzz_ROL07_transferSweepsTheAccrualToTheOldRecipient(uint256 buySeed, uint256 transfers) public {
        uint256 ethIn = bound(buySeed, 0.01 ether, 5 ether);
        transfers = bound(transfers, 1, 4);
        address genesis = address(token);

        _buyLink(1, ethIn);
        uint256 accrued = vault.creatorBalance(genesis);
        assertGt(accrued, 0, "the genesis creator was credited");

        address current = vault.creatorRecipient(genesis);
        assertEq(current, roundManager.creatorOf(genesis), "link one's creator holds the right");

        vm.prank(current);
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.transferCreatorRecipient(genesis, address(0));

        address first = current;
        for (uint256 i = 0; i < transfers; i++) {
            address next = address(uint160(0xC0FFEE00 + i));
            uint256 heldBefore = vault.creatorAccrued(current);
            uint256 balanceBefore = vault.creatorBalance(genesis);

            vm.prank(current);
            vault.transferCreatorRecipient(genesis, next);

            assertEq(vault.creatorBalance(genesis), 0, "the live ledger is swept");
            assertEq(vault.creatorAccrued(current) - heldBefore, balanceBefore, "to the OLD recipient");
            assertEq(vault.creatorRecipient(genesis), next, "and the right moved on");
            assertEq(vault.creatorAccrued(first), accrued, "the first sweep survives every later transfer");
            current = next;
        }

        // and the old recipient can still take it out
        uint256 before = doll.balanceOf(first);
        vm.prank(first);
        vault.claimCreatorAccrued(first);
        assertEq(doll.balanceOf(first) - before, accrued, "the swept accrual is still claimable");
    }

    /// @notice ROL-07: only the current recipient may transfer the right.
    function testFuzz_ROL07_onlyTheCurrentRecipientTransfers(address stranger) public {
        address genesis = address(token);
        vm.assume(stranger != vault.creatorRecipient(genesis));
        vm.prank(stranger);
        vm.expectRevert(FeeVault.NotCreator.selector);
        vault.transferCreatorRecipient(genesis, address(0xBEEF));
    }
}
