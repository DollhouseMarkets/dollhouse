// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DevVesting} from "../contracts/DevVesting.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";

/// @notice The genesis developer allocation (design decision 2026-09-11): 3% of the GENESIS supply
/// only, minted at genesis into an immutable {DevVesting} contract with a 1-month cliff and
/// 12-month linear release, and nothing at all on any candidate token. The supply still balances
/// exactly: locked curve + vesting + burned rounding dust = the whole supply.
contract DevAllocationTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    function test_genesisSupplyIsConserved() public view {
        uint256 inPool = token.balanceOf(address(manager));
        uint256 vested = token.balanceOf(factory.devVesting());
        uint256 burned = SUPPLY - token.totalSupply();

        assertEq(factory.DEV_ALLOCATION_BPS(), 300, "3% of the genesis supply");
        assertEq(factory.devAllocation(), (SUPPLY * 300) / 10_000);
        assertEq(vested, factory.devAllocation(), "the allocation sits in the vesting contract");
        assertEq(factory.genesisTokensForSale(), SUPPLY - vested, "the rest is what the curve sells");
        assertEq(inPool + vested + burned, SUPPLY, "curve + vesting + burned dust = the whole supply");
        assertLt(burned, 1e12, "the burn is rounding dust only");
        assertEq(token.balanceOf(address(locker)), 0, "the Locker keeps nothing loose");
    }

    function test_vestingIsWiredToTheGenesisTokenAndTheDeveloper() public view {
        DevVesting v = DevVesting(factory.devVesting());
        assertEq(address(v.token()), address(token), "the genesis token");
        assertEq(v.beneficiary(), vault.developer(), "the developer fee address at genesis");
        assertEq(v.start(), uint64(block.timestamp), "vesting starts at the genesis timestamp");
        assertEq(v.cliff(), vestingCliffS, "cliff from the factory constant");
        assertEq(v.duration(), vestingDurationS, "duration from the factory constant");
        assertEq(v.total(), factory.devAllocation());
        assertEq(v.releasable(), 0, "nothing is releasable at genesis");
    }

    function test_theAllocationVestsOnTheAnnouncedSchedule() public {
        DevVesting v = DevVesting(factory.devVesting());
        uint256 allocation = factory.devAllocation();
        uint64 start = v.start();

        vm.warp(start + vestingCliffS - 1);
        assertEq(v.releasable(), 0, "nothing before the cliff");

        vm.warp(start + vestingCliffS);
        assertEq(v.releasable(), (allocation * vestingCliffS) / vestingDurationS, "the cliff step");
        v.release();
        assertEq(token.balanceOf(developer), (allocation * vestingCliffS) / vestingDurationS);

        vm.warp(start + vestingDurationS);
        v.release();
        assertEq(token.balanceOf(developer), allocation, "and the whole allocation by the end");
        assertEq(token.balanceOf(address(v)), 0);
    }

    function test_candidatesHaveNoAllocationAtAll() public {
        _buyGenesis(1 ether);
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");

        IERC20 ct = IERC20(c.token);
        assertEq(ct.balanceOf(factory.devVesting()), 0, "the vesting contract holds no candidate supply");
        assertEq(ct.balanceOf(address(locker)), 0, "the Locker keeps nothing loose");
        assertEq(ct.balanceOf(address(manager)), ct.totalSupply(), "100% of a candidate is locked liquidity");
        assertLt(SUPPLY - ct.totalSupply(), 1e12, "only rounding dust is burned");
    }

    /// @notice The genesis transaction announces the allocation publicly.
    function test_genesisEmitsTheDevAllocationEvent() public {
        // a second, independent stack so that genesis can be created inside this test
        Stack memory s = _deployStack(true, steward, address(0));
        _useStack(s);
        vm.recordLogs();
        (address t,) = s.factory.createGenesis("Family Genesis", "FAM", "ipfs://genesis");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(s.factory)) continue;
            if (logs[i].topics[0] != FamilyFactory.DevAllocationVested.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), s.factory.devVesting(), "the vesting contract");
            (uint256 amount, uint64 cliff, uint64 duration) = abi.decode(logs[i].data, (uint256, uint64, uint64));
            assertEq(amount, s.factory.devAllocation(), "the allocation, in tokens");
            assertEq(cliff, vestingCliffS);
            assertEq(duration, vestingDurationS);
            seen++;
        }
        assertEq(seen, 1, "exactly one DevAllocationVested at genesis");

        address vesting = s.factory.devVesting();
        assertTrue(vesting != address(0), "genesis deployed a vesting contract");
        assertEq(IERC20(t).balanceOf(vesting), s.factory.devAllocation());
        assertEq(
            uint256(DevVesting(vesting).cliff()) + DevVesting(vesting).duration(),
            uint256(vestingCliffS) + vestingDurationS,
            "the announced schedule"
        );
    }
}
