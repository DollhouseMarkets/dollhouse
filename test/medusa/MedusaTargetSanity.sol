// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MedusaTarget} from "./MedusaTarget.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @dev A single forge test that proves the Medusa harness is not a no-op: the cheatcode-free
/// constructor really deploys the stack, and the fuzz actions really move protocol state. Medusa
/// reports coverage against its own bytecode matching, which cannot see the contracts this
/// harness deploys at runtime, so this is where "did the actions do anything" is checked.
contract MedusaTargetSanityTest is Test {
    MedusaTarget internal target;

    function setUp() public {
        target = new MedusaTarget();
    }

    function test_theHarnessDrivesTheProtocol() public {
        assertTrue(target.genesisToken() != address(0), "the adopted genesis exists");
        assertEq(target.tokenCount(), 1, "the adopted token is noted");

        // Canonical index 0 is an ADOPTED token with no pool of ours, so there is
        // nothing to buy until link one is crowned - the round comes first now.
        target.buy(0, 5 ether);
        assertEq(target.buysSucceeded(), 0, "there is nothing to buy before link one exists");

        RoundManager rm = target.roundManager();
        target.register();
        assertGt(target.registrations(), 0, "a candidate registered");

        // the candidate is bought INSIDE its trading window, so the absorption actually scores
        RoundManager.Round memory r = rm.roundInfo(rm.roundCount());
        vm.warp(uint256(r.tradingStart) + 10);
        target.tradeCandidate(0, type(uint256).max / 2);

        vm.warp(r.nominalEnd);
        target.requestEnd();
        target.fulfilMock();
        target.submitScores();
        vm.warp(uint256(rm.roundInfo(rm.roundCount()).submitEnd) + 1);
        target.finalize();
        assertGt(target.finalizations(), 0, "a round finalized");
        assertGt(target.successions(), 0, "and it crowned link one");

        // ...and now the edge pool exists, so a routed buy fills
        target.buy(0, 5 ether);
        assertGt(target.buysSucceeded(), 0, "a buy went through");

        target.keeperDeploy(0, 1);
        target.claimDev();
        target.sell(0, 1e18);

        assertTrue(target.property_FEE11_vaultIsSolvent(), "FEE-11");
        assertTrue(target.property_FEE08_familyLedgersAreHopFeesOnly(), "FEE-08");
        assertTrue(target.property_SUP01_supplyNeverMoves(), "SUP-01");
        assertTrue(target.property_RND09_canonicalHistoryIsAppendOnly(), "RND-09");
        assertTrue(target.property_BID05_keeperLeashIsNeverSlack(), "BID-05");
        assertTrue(target.property_NOETH_stackHoldsNoEth(), "no contract holds ETH");
    }
}
