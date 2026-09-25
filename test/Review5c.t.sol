// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {HostileDoll} from "./utils/HostileDoll.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice The edge bid's bounty behaviour on a small set of pots.
///
/// The edge bid draws FOUR pots of the protocol's own edge currency, the caller delivers nothing
/// at all, and it pays the proportional rate only, never the {BidDeployer.MIN_BOUNTY_DOLL} floor.
/// Below 100 x that floor, if the {BidDeployer.MAX_BOUNTY_SHARE_BPS} ceiling applied it would
/// bind, letting the first caller to notice a small set of pots take a FIFTH of all four of them
/// for one call; this path avoids that entirely, exactly as `deployAncestor(1)`'s self-funded
/// branch does.
///
/// The floor is set high here precisely so that the pots a short test can build land in the
/// region where that ceiling would otherwise bind. That is the region these tests target; a real
/// chain reaches it whenever the pots are young.
contract Review5cEdgeBidTest is RoundTestBase {
    address internal keeper = address(0xC0FFEE);

    function setUp() public {
        // the pots a round of this size builds are thousands of $DOLL, so the floor is set above
        // them: this is the below-floor region, where the old 20% ceiling bound
        minBountyDoll = 1_000e18;
        _setUpFamily();
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
        _runWinningRound(1, WINNING_ABSORPTION);
        _buyLink(2, 50_000e18);

        // a failed round, so a forfeited bond reaches the earmark: the fourth pot
        _registerCandidate(address(0xF00D), "FAIL");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        _warmOracles();
    }

    function _pots() internal view returns (uint256) {
        return vault.drawableEdge(0) + vault.drawableEdge(1) + vault.reinforcementBalance(address(doll))
            + vault.edgeBidEarmark();
    }

    /// @notice THE PROPERTY. With the pots below 100 x {BidDeployer.MIN_BOUNTY_DOLL}, applying
    /// the floor would cap the bounty at {BidDeployer.MAX_BOUNTY_SHARE_BPS} of what the call
    /// consumes - a fifth of everything the four pots hold. The bounty paid is the proportional
    /// 1% instead.
    function test_theEdgeBidPaysTheProportionalRateAndNoFloor() public {
        uint256 potTotal = _pots();
        assertGt(potTotal, 0, "there is something to deploy");
        assertLt(potTotal, 100 * bidDeployer.MIN_BOUNTY_DOLL(), "and it is in the below-floor region");

        uint256 before = doll.balanceOf(keeper);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployEdgeBid();
        uint256 bounty = doll.balanceOf(keeper) - before;

        assertGt(deposited, 0, "the bid was placed");
        assertEq(bounty, (deposited * bidDeployer.BOUNTY_BPS()) / 10_000, "the proportional rate, exactly");
        // the whole point: nowhere near the ceiling that would otherwise bind, and never more
        // than the rate on the pots the call consumed
        assertLe(bounty, (potTotal * bidDeployer.BOUNTY_BPS()) / 10_000, "at most 1% of the pots");
        assertLt(bounty, _expectedBounty(deposited), "strictly less than the floored bounty the ceiling would allow");
        assertLt(bounty * 5, potTotal, "and a fifth of the four pots is exactly what it is not");
        assertEq(doll.balanceOf(address(bidDeployer)), 0, "the deployer keeps nothing");
        _assertSolvent();
    }

    /// @notice A DUST SET OF POTS, about 0.001 $DOLL of them. There is no floor on this path: it
    /// deploys, and it pays 1% of the dust rather than the fifth of it a floor's ceiling would
    /// otherwise hand over.
    function test_aDustSizedSetOfPotsIsStillOnlyWorthOnePercent() public {
        // empty the link-one hop pot on its own path - each call takes what the pool's reserve cap
        // allows, so it takes a few - and then ask for NO sleeve. What is left for the edge bid is
        // the forfeited bond of 0.001 $DOLL and whatever dust the hop pot could not place.
        for (uint256 i = 0; i < 40; i++) {
            if (vault.reinforcementBalance(address(doll)) < 1e15) break;
            vm.prank(keeper);
            try bidDeployer.deployHopPot(1) {} catch { break; }
        }

        uint256 earmark = vault.edgeBidEarmark();
        uint256 potTotal = earmark + vault.reinforcementBalance(address(doll));
        assertGt(potTotal, 0, "dust, but not nothing");
        assertLt(potTotal, 1e16, "and it really is dust: under 0.01 $DOLL between the two pots");

        uint256 before = doll.balanceOf(keeper);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployEdgeBid(0); // 0 from each sleeve
        uint256 bounty = doll.balanceOf(keeper) - before;

        // it deploys: a dust deposit is real liquidity under link one, so no minimum size and no
        // new revert were needed
        assertGt(deposited, 0, "a dust deposit is still real liquidity, not a rounded-away zero");
        assertEq(bounty, (deposited * bidDeployer.BOUNTY_BPS()) / 10_000, "1% of the dust");
        assertLe(bounty, potTotal / 100 + 1, "and of the pots too");
        // what it is NOT is a fifth of the pots, which is what a floor's ceiling would otherwise pay
        assertLt(bounty * 5, potTotal, "no fifth of the pots for a call that delivers nothing");
        _assertSolvent();
    }
}

/// @notice THE INVERSE MUST MATCH THE CHARGE. `maxParentForDeploy` inverts the payout
/// a deployment costs, and the keeper sizes every call by it. `deployAncestor(1)`
/// pays the PROPORTIONAL bounty on its self-funded branch, so the inverse must invert that same
/// proportional charge - inverting the FLOORED one instead would understate generation 1's usable
/// sleeve by up to {BidDeployer.MIN_BOUNTY_DOLL} and leave the keeper that much undeployable
/// forever.
contract Review5cInverseTest is RoundTestBase {
    address internal keeper = address(0xBEEF);

    function setUp() public {
        _setUpEdge();
        _runWinningRound(1, WINNING_ABSORPTION);
        familyRouter.buyExactIn(2, 60 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, 20 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @notice The round trip: what the view offers is exactly what the call accepts, and what it
    /// leaves behind in the sleeve is smaller than a wei of bounty.
    function test_maxParentForDeployAtLinkOneRoundTripsWithDeployAncestor() public {
        uint256 available = vault.drawableEdge(1);
        assertGt(available, 0, "generation 1 has a sleeve");

        uint256 offered = bidDeployer.maxParentForDeploy(1);
        uint256 bps = bidDeployer.BOUNTY_BPS();
        // the proportional inverse, exactly: `v + v/100 <= available`
        assertEq(offered, (available * 10_000) / (10_000 + bps), "the proportional inverse");
        uint256 payout = offered + (offered * bps) / 10_000;
        assertLe(payout, available, "and what it costs fits in the sleeve");
        // maximal up to the flooring of the two divisions: nothing worth a wei is left behind
        assertLt(available - payout, 10_000 / bps + 1, "and leaves nothing usable in the sleeve");
        // the floored inverse would leave a whole floor unusable if used here
        assertGt(offered, available - bidDeployer.MIN_BOUNTY_DOLL(), "strictly more than the floored answer");

        // and the call really does take it. The pool's own reserve cap is the other bound the
        // keeper applies, so this is the smaller of the two, as the keeper computes it.
        uint256 cap = bidDeployer.bidCap(1);
        uint256 amount = offered < cap ? offered : cap;
        assertGt(amount, 0);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);
        assertGt(deposited, 0, "the bid was placed");
        assertEq(doll.balanceOf(keeper), (amount * bps) / 10_000, "the keeper was paid the proportional rate");
        _assertSolvent();
    }
}

/// @notice THE ESCROW CHECK AND THE FORFEITS IT MUST NOT BE BLIND TO. `addCandidate` proves a
/// bond was really delivered by comparing this contract's balance against what it owes. This
/// contract has a SECOND thing to owe - `pendingForfeits`, tokens held for the vault - so the
/// check must not read `bondEscrow` alone: otherwise held forfeits could stand in for a bond that
/// never arrived.
contract Review5cEscrowTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    HostileDoll internal hostile;

    function setUp() public {
        _setUpFamily();
        HostileDoll impl = new HostileDoll(18);
        vm.etch(DOLL_ADDRESS, address(impl).code);
        hostile = HostileDoll(DOLL_ADDRESS);
    }

    /// @dev A round taken to the edge of finalization.
    function _stageRoundReadyToFinalize() internal returns (uint256 bond) {
        bond = roundManager.currentBond();
        delete cands;
        for (uint256 i = 0; i < 3; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i + block.timestamp)), "CAND");
        }
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);

        vm.warp(tradingStart + 5);
        _tradeCandidate(cands[0], true, WINNING_BUY);
        for (uint256 i = 1; i < 3; i++) {
            _tradeCandidate(cands[i], true, WINNING_BUY / 100);
        }
        _settleEnd();
        for (uint256 i = 0; i < 3; i++) {
            roundManager.submitScore(cands[i].id);
        }
        vm.warp(submitEnd + 1);
    }

    /// @dev Crown a round with the token paused, so both losing bonds are HELD rather than
    /// delivered and `pendingForfeits` is non-zero for what follows.
    function _crownWithForfeitsHeld() internal returns (uint256 bond) {
        bond = _stageRoundReadyToFinalize();
        hostile.setPaused(true);
        roundManager.finalize();
        hostile.setPaused(false);
        assertEq(roundManager.pendingForfeits(), 2 * bond, "two bonds are held for the vault");
    }

    /// @notice THE PROPERTY. A registration whose bond arrives SHORT, while held forfeits sit in
    /// the same balance, is refused: reading `bondEscrow` alone would let the held forfeits cover
    /// the shortfall and record the candidate as having paid a bond it never paid in full.
    function test_anUnderDeliveredBondIsRefusedEvenWhileForfeitsAreHeld() public {
        uint256 forfeits = _crownWithForfeitsHeld();
        uint256 bond = roundManager.currentBond();

        address alice = address(0xA11CE);
        _fundDoll(alice, bond);
        vm.prank(alice);
        IERC20(address(doll)).approve(address(factory), type(uint256).max);

        hostile.setFeeBps(100); // 1% skimmed in flight: the bond arrives short by bond/100
        uint256 held = IERC20(address(doll)).balanceOf(address(roundManager));
        uint256 escrow = roundManager.bondEscrow();
        assertEq(held, escrow + 2 * forfeits, "the balance covers both ledgers before the call");
        // the masking condition, spelled out: the shortfall is smaller than what is held for the
        // vault, so the OLD check - balance against `bondEscrow` alone - would have passed
        assertGt(2 * forfeits, bond / 100, "the held forfeits are larger than the shortfall");

        vm.prank(alice);
        vm.expectRevert(RoundManager.BondNotDelivered.selector);
        factory.registerCandidate("SHORT", "SHORT", "", type(uint256).max);

        // and the same registration goes through the moment the token stops skimming
        hostile.setFeeBps(0);
        vm.prank(alice);
        factory.registerCandidate("FULL", "FULL", "", type(uint256).max);
        assertEq(roundManager.bondEscrow(), escrow + bond, "the bond that was really delivered is escrowed");
        assertEq(roundManager.pendingForfeits(), 2 * forfeits, "and the held forfeits were not touched");
    }

    /// @notice CONSERVATION ACROSS FINALIZE AND FLUSH. The earmark grows by the forfeited bonds,
    /// exactly, exactly once, whether the delivery happens inside `finalize` or on a later flush.
    function test_theEarmarkTakesTheForfeitedBondsExactlyOnce() public {
        uint256 bond = _crownWithForfeitsHeld();
        assertEq(vault.edgeBidEarmark(), 0, "nothing reached the earmark inside finalize");

        uint256 earmarkBefore = vault.edgeBidEarmark();
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark() - earmarkBefore, 2 * bond, "the delta IS the forfeited amount");
        assertEq(roundManager.pendingForfeits(), 0, "nothing is held any more");

        // and there is no second delivery to be had, by anyone
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "still exactly the forfeited amount");
        _assertSolvent();
    }

    /// @notice A GAS-BURNING EDGE TOKEN CANNOT STARVE THE CROWNING. The forfeit delivery is made
    /// through a `try`, which hands the token 63/64 of the gas left; this token consumes every
    /// drop of it. The round must still crown out of the remaining 64th, under a finite gas limit
    /// rather than the test runner's unbounded one.
    function test_finalizeCrownsUnderAGasLimitAgainstAGasBurningEdgeToken() public {
        uint256 bond = _stageRoundReadyToFinalize();

        // what an honest finalization costs, measured and then thrown away
        uint256 snap = vm.snapshotState();
        uint256 gasBefore = gasleft();
        roundManager.finalize();
        uint256 honest = gasBefore - gasleft();
        vm.revertToState(snap);

        hostile.setBurnsGasTo(address(vault));
        // 64 times the honest cost: the token takes 63/64 of it and the 64th left behind is what
        // has to carry the rest of the round end
        uint256 limit = 64 * honest;
        roundManager.finalize{gas: limit}();
        hostile.setBurnsGasTo(address(0));

        assertEq(roundManager.headIndex(), 1, "the round CROWNED");
        assertEq(roundManager.head(), cands[0].token, "and the candidate that won holds link one");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "the delivery it could not afford is held, not lost");
        assertEq(vault.edgeBidEarmark(), 0, "and nothing reached the earmark");

        // the held amount is still deliverable once the token behaves
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "delivered in full on the retry");
        _assertSolvent();
    }

    /// @notice A HOSTILE EDGE TOKEN RE-ENTERING THE FLUSH. `flushForfeits` zeroes what it holds
    /// before it transfers, and carries the reentrancy guard on top: a token that calls back into
    /// it from inside the transfer is refused, and the forfeits are delivered exactly once.
    function test_flushForfeitsRejectsAReentrantEdgeToken() public {
        uint256 bond = _crownWithForfeitsHeld();
        hostile.setReenters(address(roundManager));

        roundManager.flushForfeits();

        assertTrue(hostile.reentryRejected(), "the re-entrant flush was refused");
        assertEq(vault.edgeBidEarmark(), 2 * bond, "the forfeits arrived exactly once");
        assertEq(roundManager.pendingForfeits(), 0, "and nothing is held");
        hostile.setReenters(address(0));
        _assertSolvent();
    }
}
