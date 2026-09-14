// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "../utils/FamilyTestBase.sol";
import {DevVesting} from "../../contracts/DevVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Property tests for the developer vesting contract (docs/spec/PROPERTIES.md sec.3.11),
/// tier F, against the contract the genesis transaction actually deploys.
contract VestingPropTest is FamilyTestBase {
    DevVesting internal vesting;

    function setUp() public {
        _deployProtocol();
        _createGenesis();
        vesting = DevVesting(factory.devVesting());
    }

    /// @notice VST-01: `total() == token.balanceOf(this) + released` at all times, and equals
    /// `devAllocation()` from the end of `createGenesis` until the first release.
    function testFuzz_VST01_totalIsHeldPlusReleased(uint256 dt) public {
        assertEq(vesting.total(), factory.devAllocation(), "the allocation is never stored as a number");
        assertEq(vesting.released(), 0, "nothing released yet");

        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 800 days));
        assertEq(
            vesting.total(), IERC20(address(token)).balanceOf(address(vesting)) + vesting.released(), "held + released"
        );
        if (vesting.releasable() != 0) {
            vesting.release();
            assertEq(
                vesting.total(),
                IERC20(address(token)).balanceOf(address(vesting)) + vesting.released(),
                "still held + released after a release"
            );
            assertEq(vesting.total(), factory.devAllocation(), "and still the same allocation");
        }
    }

    /// @notice VST-02: `vested(t) = 0` for `t < start + cliff`; `= total()*(t - start)/duration`
    /// for `start + cliff <= t < start + duration`; `= total()` for `t >= start + duration`.
    function testFuzz_VST02_theScheduleIsTheStatedClosedForm(uint256 dt) public view {
        uint64 start = vesting.start();
        uint64 cliff = vesting.cliff();
        uint64 duration = vesting.duration();
        uint256 total = vesting.total();
        uint64 t = uint64(start + bound(dt, 0, 800 days));

        uint256 expected;
        if (t < start + cliff) {
            expected = 0;
        } else if (t >= start + duration) {
            expected = total;
        } else {
            expected = (total * (t - start)) / duration;
        }
        assertEq(vesting.vested(t), expected, "the published schedule");
    }

    /// @notice VST-02: the cliff does not unlock zero - `vested(start + cliff)` is
    /// `total()*cliff/duration`, about 8.2% at the deploy constants.
    function testFuzz_VST02_theCliffUnlocksItsAccruedShare(uint256 unused) public view {
        unused;
        uint64 start = vesting.start();
        uint256 atCliff = vesting.vested(start + vesting.cliff());
        assertEq(atCliff, (vesting.total() * vesting.cliff()) / vesting.duration(), "exactly cliff/duration");
        assertApproxEqRel(atCliff, (vesting.total() * 82) / 1000, 0.01e18, "about 8.2% at the deploy constants");
        assertGt(atCliff, 0, "the cliff unlocks what accrued since start");
        assertEq(vesting.vested(start + vesting.cliff() - 1), 0, "and nothing one second earlier");
    }

    /// @notice VST-03: `released(t)` is monotone non-decreasing in `t`, never exceeds `total()`,
    /// and equals `total()` exactly at and after `start + duration` once a release is called.
    function testFuzz_VST03_releasedIsMonotoneAndBounded(uint256[6] memory gaps) public {
        uint256 previous;
        for (uint256 i = 0; i < gaps.length; i++) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 0, 120 days));
            if (vesting.releasable() != 0) vesting.release();
            uint256 released = vesting.released();
            assertGe(released, previous, "released never falls");
            assertLe(released, vesting.total(), "released never exceeds the allocation");
            assertEq(released, vesting.vested(uint64(vm.getBlockTimestamp())), "released tracks the schedule");
            previous = released;
        }

        vm.warp(vesting.start() + vesting.duration() + 1);
        if (vesting.releasable() != 0) vesting.release();
        assertEq(vesting.released(), vesting.total(), "everything is out at the end");
        assertEq(IERC20(address(token)).balanceOf(address(vesting)), 0, "and nothing is left behind");
    }

    /// @notice VST-04: `release()` is permissionless and always pays `vested(now) - released` to
    /// the CURRENT beneficiary; a second call with nothing new reverts.
    function testFuzz_VST04_releaseIsPermissionlessAndPaysTheDelta(uint256 dt, address caller) public {
        vm.warp(vesting.start() + vesting.cliff() + bound(dt, 0, 300 days));
        address beneficiary = vesting.beneficiary();
        vm.assume(caller != address(0) && caller != beneficiary);

        uint256 owed = vesting.releasable();
        uint256 balanceBefore = IERC20(address(token)).balanceOf(beneficiary);
        vm.prank(caller);
        uint256 paid = vesting.release();

        assertEq(paid, owed, "the whole delta is paid");
        assertEq(
            IERC20(address(token)).balanceOf(beneficiary) - balanceBefore, owed, "and it reaches the beneficiary"
        );

        vm.prank(caller);
        vm.expectRevert(DevVesting.NothingToRelease.selector);
        vesting.release();
    }
}
