// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MedusaTarget} from "./MedusaTarget.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        assertTrue(
            target.property_finalizeNeverBeforeAllScoresOrSubmitEnd(), "finalize gate: deadline-side finalize"
        );

        // ...and now the edge pool exists, so a routed buy fills
        target.buy(0, 5 ether);
        assertGt(target.buysSucceeded(), 0, "a buy went through");

        target.keeperDeploy(0, 1);
        target.claimDev();
        target.sell(0, 1e18);
        assertEq(target.canonicalSellReverts(), 0, "the canonical sell filled");

        assertTrue(target.property_FEE11_vaultIsSolvent(), "FEE-11");
        assertTrue(target.property_FEE08_familyLedgersAreHopFeesOnly(), "FEE-08");
        assertTrue(target.property_SUP01_supplyNeverMoves(), "SUP-01");
        assertTrue(target.property_supplyOnlyDecreasesByBurn(), "supply: burn only");
        assertTrue(target.property_canonicalSellsNeverRevertOnVenueLock(), "canonical sells never refused");

        // the copy-pair leg is really refused (nothing moves), the burn really burns, and the
        // property accounts for every wei of it
        address link = target.roundManager().canonical(1);
        uint256 supplyBefore = IERC20(link).totalSupply();
        uint256 balanceBefore = IERC20(link).balanceOf(address(target));
        target.sideTrade(0, 1e18, true);
        assertEq(target.sideTrades(), 1, "the side leg was refused");
        assertEq(target.sideTradesAccepted(), 0, "and not let through");
        assertEq(IERC20(link).balanceOf(address(target)), balanceBefore, "nothing left the seller");
        assertEq(IERC20(link).totalSupply(), supplyBefore, "nothing charged");
        target.burnSome(0, 1e18);
        assertEq(target.burns(), 1, "the burn ran");
        assertLt(IERC20(link).totalSupply(), supplyBefore, "the supply fell");
        assertTrue(target.property_supplyOnlyDecreasesByBurn(), "every decrease is explained");
        assertTrue(target.property_SUP01_supplyNeverMoves(), "SUP-01 after burns");
        // the hookless copy pool through ERC-6909 claims (the claims residual): claims trade
        // there, but link one bought there never leaves as ERC-20 beyond the allowance
        uint256 supplyBeforeHookless = IERC20(link).totalSupply();
        target.sideTradeHookless(1e18, 0); // opens and seeds the pool, canonical claims buy, claims sell
        target.sideTradeHookless(1e18, 1); // hookless buy kept as claims
        target.sideTradeHookless(1e18, 2); // hookless buy, ERC-20 exit attempted
        assertEq(target.hooklessSideTradeReverts(), 0, "every hookless claims trade went through");
        assertEq(target.hooklessSideTrades(), 3);
        assertEq(target.hooklessExitsRefused(), 1, "the ERC-20 exit was refused");
        assertTrue(target.property_hooklessExitNeverExceedsTheAllowance(), "exit bounded by the allowance");
        assertEq(IERC20(link).totalSupply(), supplyBeforeHookless, "nothing charged");
        assertTrue(target.property_supplyOnlyDecreasesByBurn(), "supply: burn only, after hookless trades");
        assertTrue(target.property_RND09_canonicalHistoryIsAppendOnly(), "RND-09");
        assertTrue(target.property_BID05_keeperLeashIsNeverSlack(), "BID-05");
        assertTrue(target.property_NOETH_stackHoldsNoEth(), "no contract holds ETH");
        assertTrue(target.property_startWithinClamps(), "start cap within [Y, X]");
        assertTrue(target.property_registrationNeverRevertsOnOracleState(), "quoteStart never reverts");
    }

    /// @dev The bound {MockVenueOracle} was wired at construction (see {MedusaTarget}'s
    /// constructor): the oracle's own healthy start price already drove the very first round
    /// above, so this only has to prove the harness survives every misbehaviour mode {setOracle}
    /// can select, plus the normal-mode price sweep across the full v4 sqrt price range.
    function test_oracleStatesNeverBreakTheStartRule() public {
        target.register(); // link one, priced off the oracle's initial healthy state

        // mode 0, sweeping sqrtP end to end
        target.setOracle(0, 0, 0, 0);
        assertTrue(target.property_startWithinClamps(), "clamp holds at the low sqrtP end");
        assertTrue(target.property_registrationNeverRevertsOnOracleState(), "quoteStart holds at the low sqrtP end");
        target.setOracle(type(uint256).max, 0, 0, 0);
        assertTrue(target.property_startWithinClamps(), "clamp holds at the high sqrtP end");
        assertTrue(target.property_registrationNeverRevertsOnOracleState(), "quoteStart holds at the high sqrtP end");

        // status bits: 0 normal, 2 ORACLE_STALE-with-price, anything else treated as failed
        target.setOracle(1 << 96, 2, 5, 0);
        assertTrue(target.property_startWithinClamps(), "clamp holds when stale-with-price");
        target.setOracle(1 << 96, 7, 5, 0);
        assertTrue(target.property_startWithinClamps(), "clamp holds on an unrecognised status");

        // modes 1-4: revert, burn all the gas it is given, short return, malformed return
        for (uint8 mode = 1; mode <= 4; mode++) {
            target.setOracle(1 << 96, 0, 0, mode);
            assertTrue(target.property_startWithinClamps(), "clamp holds under oracle misbehaviour");
            assertTrue(
                target.property_registrationNeverRevertsOnOracleState(), "quoteStart holds under oracle misbehaviour"
            );
        }
    }
}
