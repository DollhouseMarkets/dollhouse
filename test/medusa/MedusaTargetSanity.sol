// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MedusaTarget} from "./MedusaTarget.sol";

/// @dev A single forge test that proves the Medusa harness is not a no-op: the cheatcode-free
/// constructor really deploys the stack, and the fuzz actions really move protocol state. Medusa
/// reports coverage against its own bytecode matching, which cannot see the contracts this
/// harness deploys at runtime, so this is where "did the actions do anything" is checked.
contract MedusaTargetSanityTest is Test {
    MedusaTarget internal target;

    function setUp() public {
        target = new MedusaTarget{value: 10_000 ether}();
    }

    function test_theHarnessDrivesTheProtocol() public {
        assertTrue(target.genesisToken() != address(0), "genesis exists");
        assertEq(target.tokenCount(), 1, "genesis token noted");

        target.buy(0, 5 ether);
        assertGt(target.buysSucceeded(), 0, "a buy went through");

        target.register();
        assertGt(target.registrations(), 0, "a candidate registered");

        vm.warp(block.timestamp + 20 minutes);
        target.tradeCandidate(0, type(uint256).max / 2);
        target.requestEnd();
        target.fulfilMock();
        vm.warp(block.timestamp + 1 hours);
        target.finalize();
        assertGt(target.finalizations(), 0, "a round finalized");

        target.keeperDeploy(0, 1);
        target.claimDev();
        target.sell(0, 1e18);

        assertTrue(target.property_FEE11_vaultIsSolvent(), "FEE-11");
        assertTrue(target.property_FEE08_familyLedgersAreHopFeesOnly(), "FEE-08");
        assertTrue(target.property_SUP01_supplyNeverMoves(), "SUP-01");
        assertTrue(target.property_RND09_canonicalHistoryIsAppendOnly(), "RND-09");
        assertTrue(target.property_BID05_keeperLeashIsNeverSlack(), "BID-05");
    }
}
