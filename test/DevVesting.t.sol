// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {DeployVesting} from "../script/DeployVesting.s.sol";
import {MockDoll} from "./utils/MockDoll.sol";

/// @notice The developer's 3% lock: plain linear release from launch (no cliff), and release()
/// always pays the beneficiary regardless of who calls it.
contract DevVestingTest is Test {
    uint64 constant DURATION = 365 days;
    uint256 constant TOTAL = 30_000_000e18;

    address beneficiary = makeAddr("beneficiary");
    address stranger = makeAddr("stranger");
    MockDoll doll;
    VestingWallet wallet;
    uint64 start;

    function setUp() public {
        doll = new MockDoll(18);
        start = uint64(block.timestamp);
        wallet = new VestingWallet(beneficiary, start, DURATION);
        doll.mint(address(wallet), TOTAL);
    }

    function test_noReleaseAtStart() public view {
        assertEq(wallet.releasable(address(doll)), 0);
    }

    function test_linearAt30Days() public {
        vm.warp(start + 30 days);
        uint256 expected = (TOTAL * 30 days) / DURATION;
        assertEq(wallet.releasable(address(doll)), expected);
        assertGt(expected, 0);
    }

    function test_fullyVestedAtEnd() public {
        vm.warp(start + DURATION);
        assertEq(wallet.releasable(address(doll)), TOTAL);
        assertEq(wallet.vestedAmount(address(doll), start + DURATION), TOTAL);
    }

    function test_releaseTransfersToBeneficiary() public {
        vm.warp(start + 30 days);
        uint256 expected = wallet.releasable(address(doll));
        wallet.release(address(doll));
        assertEq(doll.balanceOf(beneficiary), expected);
        assertEq(doll.balanceOf(address(wallet)), TOTAL - expected);
    }

    /// @dev release() takes no beneficiary argument: whoever calls it, the payout always goes to
    /// owner() (the beneficiary), never to msg.sender.
    function test_strangerCannotRedirectRelease() public {
        vm.warp(start + 30 days);
        uint256 expected = wallet.releasable(address(doll));
        uint256 strangerBefore = doll.balanceOf(stranger);

        vm.prank(stranger);
        wallet.release(address(doll));

        assertEq(doll.balanceOf(stranger), strangerBefore);
        assertEq(doll.balanceOf(beneficiary), expected);
    }

    /// @notice Runs DeployVesting's own deploy + fund + verify logic end to end against a mock
    /// token, the same sequence the launch-day script runs, so a script regression fails here
    /// instead of on launch day.
    function test_scriptDeploysFundsAndVerifies() public {
        DeployVestingHarness harness = new DeployVestingHarness();
        doll.mint(address(harness), TOTAL);

        // Pranked as the harness itself: `_deployAndFund`'s `msg.sender` balance check and the
        // token it actually moves (out of `address(this)`, i.e. the harness) are then the same
        // account, exactly as `run()`'s broadcaster is one account for both.
        vm.prank(address(harness));
        VestingWallet deployed = harness.deployFundAndVerify(address(doll), beneficiary, start, TOTAL);

        assertEq(doll.balanceOf(address(deployed)), TOTAL);
        assertEq(deployed.owner(), beneficiary);
        assertEq(deployed.start(), start);
        assertEq(deployed.duration(), DURATION);
    }

    function test_scriptRevertsWhenBroadcasterUnderfunded() public {
        DeployVestingHarness harness = new DeployVestingHarness();
        doll.mint(address(harness), TOTAL - 1);

        vm.prank(address(harness));
        vm.expectRevert("broadcaster balance below AMOUNT");
        harness.deployFundAndVerify(address(doll), beneficiary, start, TOTAL);
    }
}

/// @dev Exposes DeployVesting's internal deploy/fund/verify sequence for direct testing.
contract DeployVestingHarness is DeployVesting {
    function deployFundAndVerify(address token, address beneficiary, uint64 start, uint256 amount)
        external
        returns (VestingWallet wallet)
    {
        wallet = _deployAndFund(token, beneficiary, start, amount);
        _verify(wallet, token, beneficiary, start, amount);
    }
}
