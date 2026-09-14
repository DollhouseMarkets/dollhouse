// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DevVesting} from "../contracts/DevVesting.sol";

contract VestingToken is ERC20 {
    constructor(address to, uint256 amount) ERC20("Vesting", "VEST") {
        _mint(to, amount);
    }
}

/// @notice The developer allocation's schedule, to the wei: nothing before the cliff, the
/// linear amount accrued SINCE `start` at the cliff, linear onwards, and never more than the
/// allocation in total. Plus the 7-day beneficiary transfer that makes a lost key recoverable.
contract DevVestingTest is Test {
    uint64 internal constant START = 1_800_000_000;
    uint64 internal constant CLIFF = 30 days;
    uint64 internal constant DURATION = 365 days;
    uint256 internal constant ALLOCATION = 30_000_000e18; // 3% of 1e9

    address internal dev = address(0xDE7);
    address internal newDev = address(0xBEEF);

    DevVesting internal vesting;
    VestingToken internal token;

    function setUp() public {
        vm.warp(START);
        // the vesting contract is deployed first, then funded, exactly as the factory does it
        address predictedToken = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vesting = new DevVesting(IERC20(predictedToken), dev, START, CLIFF, DURATION);
        token = new VestingToken(address(vesting), ALLOCATION);
        assertEq(address(vesting.token()), address(token), "token address prediction");
        assertEq(vesting.total(), ALLOCATION);
    }

    // ---------------------------------------------------------------------------------
    // the schedule
    // ---------------------------------------------------------------------------------

    function test_nothingVestsBeforeTheCliff() public {
        assertEq(vesting.vested(START), 0, "nothing at start");
        assertEq(vesting.vested(START + CLIFF - 1), 0, "nothing one second before the cliff");
        assertEq(vesting.releasable(), 0, "nothing releasable at start");
        vm.warp(START + CLIFF - 1);
        assertEq(vesting.releasable(), 0, "nothing releasable one second before the cliff");
        vm.expectRevert(DevVesting.NothingToRelease.selector);
        vesting.release();
        assertEq(token.balanceOf(dev), 0, "the beneficiary has nothing before the cliff");
    }

    function test_theCliffUnlocksWhatAccruedSinceStart() public {
        uint256 expected = (ALLOCATION * CLIFF) / DURATION;
        assertEq(vesting.vested(START + CLIFF), expected, "cliff/duration of the allocation, in one step");
        assertGt(expected, 0);

        vm.warp(START + CLIFF);
        assertEq(vesting.releasable(), expected);
        vesting.release();
        assertEq(token.balanceOf(dev), expected, "paid to the beneficiary");
        assertEq(vesting.released(), expected);
    }

    function test_linearBetweenCliffAndEnd() public view {
        uint64 mid = START + DURATION / 2;
        assertEq(vesting.vested(mid), (ALLOCATION * (DURATION / 2)) / DURATION, "half the allocation at half time");

        uint64 t = START + CLIFF + 77 days;
        assertEq(vesting.vested(t), (ALLOCATION * (t - START)) / DURATION, "plain linear share of elapsed time");
    }

    function test_everythingVestedAtTheEndAndNeverMore() public {
        assertEq(vesting.vested(START + DURATION), ALLOCATION, "the whole allocation at the end");
        assertEq(vesting.vested(START + DURATION + 365 days), ALLOCATION, "and never more than the allocation");

        vm.warp(START + DURATION + 1 days);
        assertEq(vesting.releasable(), ALLOCATION);
        vesting.release();
        assertEq(token.balanceOf(dev), ALLOCATION, "the beneficiary has exactly the allocation");
        assertEq(token.balanceOf(address(vesting)), 0, "and the vesting contract is empty");
        assertEq(vesting.releasable(), 0);
        vm.expectRevert(DevVesting.NothingToRelease.selector);
        vesting.release();
    }

    function test_releaseTwicePaysTheDeltaOnly() public {
        vm.warp(START + CLIFF);
        uint256 first = vesting.releasable();
        vesting.release();

        vm.warp(START + DURATION / 2);
        uint256 secondExpected = (ALLOCATION * (DURATION / 2)) / DURATION - first;
        assertEq(vesting.releasable(), secondExpected, "only what accrued since the first release");
        vm.prank(address(0xCAFE)); // anyone may call it; it always pays the beneficiary
        vesting.release();
        assertEq(token.balanceOf(dev), first + secondExpected, "the two payments sum to what has vested");
        assertEq(vesting.released(), first + secondExpected);
        assertEq(vesting.released() + token.balanceOf(address(vesting)), ALLOCATION, "supply conservation");
    }

    // ---------------------------------------------------------------------------------
    // the 7-day beneficiary transfer
    // ---------------------------------------------------------------------------------

    function test_beneficiaryTransferWaitsOutTheDelay() public {
        vm.prank(dev);
        vesting.announceBeneficiaryTransfer(newDev);
        assertEq(vesting.pendingBeneficiary(), newDev);
        assertEq(vesting.beneficiaryTransferAt(), START + vesting.ROLE_TRANSFER_DELAY());

        vm.expectRevert(DevVesting.TransferNotReady.selector);
        vesting.executeBeneficiaryTransfer();

        vm.warp(START + vesting.ROLE_TRANSFER_DELAY() - 1);
        vm.expectRevert(DevVesting.TransferNotReady.selector);
        vesting.executeBeneficiaryTransfer();

        // permissionless once the delay is up: the point is to survive a lost announcing key
        vm.warp(START + vesting.ROLE_TRANSFER_DELAY());
        vm.prank(address(0xCAFE));
        vesting.executeBeneficiaryTransfer();
        assertEq(vesting.beneficiary(), newDev);
        assertEq(vesting.pendingBeneficiary(), address(0));
        assertEq(vesting.beneficiaryTransferAt(), 0);

        // and the released tokens follow the new beneficiary
        vm.warp(START + DURATION);
        vesting.release();
        assertEq(token.balanceOf(newDev), ALLOCATION);
        assertEq(token.balanceOf(dev), 0);
    }

    function test_onlyTheBeneficiaryAnnouncesOrCancels() public {
        vm.expectRevert(DevVesting.NotBeneficiary.selector);
        vesting.announceBeneficiaryTransfer(newDev);

        vm.prank(dev);
        vm.expectRevert(DevVesting.BadRecipient.selector);
        vesting.announceBeneficiaryTransfer(address(0));

        vm.prank(dev);
        vesting.announceBeneficiaryTransfer(newDev);

        // one pending at a time
        vm.prank(dev);
        vm.expectRevert(DevVesting.TransferPending.selector);
        vesting.announceBeneficiaryTransfer(address(0xF00D));

        vm.expectRevert(DevVesting.NotBeneficiary.selector);
        vesting.cancelBeneficiaryTransfer();
    }

    function test_cancelTakesTheAnnouncementBack() public {
        vm.prank(dev);
        vesting.announceBeneficiaryTransfer(newDev);
        vm.prank(dev);
        vesting.cancelBeneficiaryTransfer();
        assertEq(vesting.pendingBeneficiary(), address(0));
        assertEq(vesting.beneficiaryTransferAt(), 0);

        vm.warp(START + 30 days);
        vm.expectRevert(DevVesting.NoTransferPending.selector);
        vesting.executeBeneficiaryTransfer();
        assertEq(vesting.beneficiary(), dev, "still the original beneficiary");

        // cancelling is repeatable: a second announcement still works
        vm.prank(dev);
        vesting.announceBeneficiaryTransfer(newDev);
        vm.warp(block.timestamp + vesting.ROLE_TRANSFER_DELAY());
        vesting.executeBeneficiaryTransfer();
        assertEq(vesting.beneficiary(), newDev);
    }

    function test_badScheduleIsRefused() public {
        vm.expectRevert(DevVesting.BadSchedule.selector);
        new DevVesting(IERC20(address(token)), dev, START, 31 days, 30 days);
        vm.expectRevert(DevVesting.BadSchedule.selector);
        new DevVesting(IERC20(address(token)), dev, START, 0, 0);
        vm.expectRevert(DevVesting.BadRecipient.selector);
        new DevVesting(IERC20(address(token)), address(0), START, CLIFF, DURATION);
    }
}
