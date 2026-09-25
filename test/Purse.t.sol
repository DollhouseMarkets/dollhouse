// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {ILocker} from "../contracts/interfaces/ILocker.sol";

/// @notice sec.1 - THE PURSE IS NOT CONTESTABLE. A generation's share of
/// the ancestor sleeve is deployed, in full, as locked bid liquidity under the TRUNK coin that
/// won that round. There is no ranking, no board and no split, and a losing sibling never
/// receives purse liquidity however well it trades afterwards.
contract PurseTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    /// @dev Generation 2's siblings: `winner` won the round, `runnerUp` and `third` did not.
    Cand internal winner;
    Cand internal runnerUp;
    Cand internal third;

    function setUp() public {
        _setUpEdge();

        // one round with three candidates: the first wins, and all three keep their pools
        winner = _runWinningRound(3, WINNING_BUY);
        runnerUp = cands[1];
        third = cands[2];
        assertEq(roundManager.canonical(2), winner.token, "the first candidate won");
        assertEq(roundManager.roundOfIndex(2), 2, "generation 2 was crowned by round 2");

        // one more generation, so that generation 2 earns a real edge-currency sleeve
        _runWinningRound(1, WINNING_BUY);
        _accrue(3 ether);
        // the losing pools are warmed too, so that nothing in this file passes merely because a
        // sibling pool would have been unusable as a bid target
        _warm(runnerUp);
        _warm(third);
        _settleOracles();
    }

    /// @dev Two spaced token-sized buys, so a loser's pool has a usable TWAP.
    function _warm(Cand memory c) internal {
        _approveParent();
        uint256 unit = _affordable() / 200;
        _tradeCandidate(c, true, unit);
        vm.warp(block.timestamp + 200);
        _tradeCandidate(c, true, unit);
    }

    function _approveParent() internal {
        IERC20(roundManager.canonical(1)).approve(address(swapRouter), type(uint256).max);
    }

    /// @dev What this test contract can still spend of generation 2's parent token.
    function _affordable() internal view returns (uint256) {
        return IERC20(roundManager.canonical(1)).balanceOf(address(this));
    }

    /// @dev Let the clock run until the 30-minute TWAPs reflect whatever was just traded.
    function _settleOracles() internal {
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Trade the chain so generation 2's edge sleeve fills, then let the oracles settle.
    function _accrue(uint256 dollIn) internal {
        familyRouter.buyExactIn(3, dollIn, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(3, dollIn / 10, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Buy a share of what is left of the parent into a SIBLING's pool, then let the clock
    /// run so the buy is fully reflected in every average.
    function _support(Cand memory c, uint256 numerator, uint256 denominator) internal {
        _approveParent();
        _tradeCandidate(c, true, (_affordable() * numerator) / denominator);
        _settleOracles();
    }

    /// @dev Sell a sibling's whole position back, then let the clock run.
    function _dump(Cand memory c) internal {
        IERC20(c.token).approve(address(swapRouter), type(uint256).max);
        _tradeCandidate(c, false, IERC20(c.token).balanceOf(address(this)));
        _settleOracles();
    }

    /// @dev Hand a keeper the parent tokens for a deployment of generation 2.
    function _keeperStock(address keeper) internal returns (uint256 amount) {
        uint256 cap = bidDeployer.bidCap(2);
        uint256 affordable = bidDeployer.maxParentForDeploy(2);
        amount = cap < affordable ? cap : affordable;
        address parent = roundManager.canonical(1);
        uint256 held = IERC20(parent).balanceOf(address(this));
        if (amount > held) amount = held;
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);
    }

    /// @dev How many bids the Locker deposited into `id` during the recorded logs. A bid sits
    /// BELOW spot, so the pool's active liquidity does not move: the deposit event is the witness.
    function _bidsInto(Vm.Log[] memory logs, PoolId id) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker)) continue;
            if (logs[i].topics[0] != ILocker.BidDeposited.selector) continue;
            if (logs[i].topics[1] == PoolId.unwrap(id)) n++;
        }
    }

    // ---------------------------------------------------------------------------------
    // the destination
    // ---------------------------------------------------------------------------------

    /// @notice THE RULE: the whole purse is locked under the coin that won the round, and the
    /// event names that coin.
    function test_thePurseIsDeployedUnderTheTrunkCoin() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        PoolId trunkPool = roundManager.poolKeyOf(2).toId();

        vm.recordLogs();
        vm.expectEmit(true, true, false, false, address(bidDeployer));
        emit BidDeployer.PurseDeployed(2, winner.token, amount);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(2, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGe(deposited, amount, "everything the keeper brought was deployed");
        assertEq(_bidsInto(logs, trunkPool), 1, "one bid, into the trunk pool");
    }

    /// @notice A losing sibling never receives purse liquidity - not even when it is the
    /// best-supported coin of its generation by a wide margin.
    function test_aLosingSiblingNeverReceivesPurseLiquidity() public {
        // the runner-up is bought hard and the winner's own pool is sold down: under the old
        // contested rule this is exactly the state that moved the purse to the sibling
        _support(runnerUp, 1, 2);
        _dump(winner);

        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(2, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_bidsInto(logs, roundManager.poolKeyOf(2).toId()), 1, "the trunk took the whole purse");
        assertEq(_bidsInto(logs, runnerUp.poolId), 0, "the runner-up receives exactly zero");
        assertEq(_bidsInto(logs, third.poolId), 0, "and so does the third");
        // and the trunk is still the winner's, pairing rights included
        assertEq(roundManager.canonical(2), winner.token, "the winner still holds the index");
        assertEq(roundManager.indexOf(winner.token), 2, "and its pairing rights");
    }

    /// @notice Nothing a keeper can choose changes the destination: the only arguments are the
    /// generation and the amount, and the generation resolves to `canonical(j)`.
    function test_theDestinationIsNotAKeeperChoice() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(2, amount);
        (address trunk, uint256 deposited) = _purseDeployedFromLogs();

        assertEq(trunk, roundManager.canonical(2), "the destination is the canonical link, always");
        assertGe(deposited, amount, "and the whole amount went there");
    }

    /// @notice A generation this deployment never crowned cannot be deployed for at all.
    function test_anUnknownGenerationIsRefused() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        // read BEFORE the prank: an external call in the argument list consumes it
        uint256 uncrowned = roundManager.headIndex() + 1;
        vm.prank(keeper);
        vm.expectRevert(BidDeployer.UnknownGeneration.selector);
        bidDeployer.deployAncestor(uncrowned, amount);
    }

    /// @notice Canonical index 0 is the ADOPTED genesis: it has no pool of ours at all, so there
    /// is nothing to bid into. Generation 0's sleeve reaches link one through
    /// {BidDeployer.deployEdgeBid} instead.
    function test_indexZeroIsNotAnAncestorDeployment() public {
        vm.expectRevert(BidDeployer.NoPoolAtIndex.selector);
        bidDeployer.deployAncestor(0, 1e18);
    }

    // ---------------------------------------------------------------------------------
    // conservation, the bucket and the bounty are unchanged
    // ---------------------------------------------------------------------------------

    /// @notice The amount conserves: what the keeper brought is what the trunk pool received,
    /// plus whatever the generation's own parent-denominated hop pot topped it up with, and
    /// nothing is left behind in the deployer.
    function test_theAmountConserves() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        address parent = roundManager.canonical(1);
        uint256 keeperParentBefore = IERC20(parent).balanceOf(keeper);

        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(2, amount);

        assertEq(IERC20(parent).balanceOf(keeper), keeperParentBefore - amount, "the keeper paid exactly `amount`");
        assertGe(deposited, amount, "and at least that much was locked");
        assertEq(IERC20(parent).balanceOf(address(bidDeployer)), 0, "nothing is stranded in the deployer");
        _assertSolvent();
    }

    /// @notice The bounty rule is unchanged: the keeper is paid the $DOLL value plus
    /// {BidDeployer.BOUNTY_BPS}, floored at {MIN_BOUNTY_DOLL}, on top of the deployment.
    function test_theBountyRuleIsUnchanged() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        uint256 dollBefore = doll.balanceOf(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(2, amount);

        (uint256 dollUsed, uint256 bounty) = _ancestorDeployedFromLogs();
        assertEq(doll.balanceOf(keeper) - dollBefore, dollUsed, "the keeper was paid the whole payout in $DOLL");
        assertEq(bounty, _expectedBounty(dollUsed - bounty), "max(1%, MIN_BOUNTY_DOLL), under its ceiling");
        _assertNoEth();
    }

    /// @notice The vault's daily drawdown bucket still bounds the purse: the deployment draws
    /// exactly its payout out of generation 2's allowance, and no more.
    function test_theDailyBucketStillBounds() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        uint256 drawableBefore = vault.drawableEdge(2);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(2, amount);
        (uint256 dollUsed,) = _ancestorDeployedFromLogs();

        assertEq(drawableBefore - vault.drawableEdge(2), dollUsed, "the bucket fell by exactly the payout");
        assertLe(dollUsed, drawableBefore, "and never by more than it held");
    }

    // ---------------------------------------------------------------------------------
    // log helpers
    // ---------------------------------------------------------------------------------

    function _purseDeployedFromLogs() internal returns (address trunk, uint256 deposited) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer) || logs[i].topics[0] != BidDeployer.PurseDeployed.selector) {
                continue;
            }
            trunk = address(uint160(uint256(logs[i].topics[2])));
            deposited = abi.decode(logs[i].data, (uint256));
        }
    }

    function _ancestorDeployedFromLogs() internal returns (uint256 dollUsed, uint256 bounty) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer) || logs[i].topics[0] != BidDeployer.AncestorDeployed.selector) {
                continue;
            }
            (dollUsed,, bounty) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
    }
}

/// @notice THE SELF-FUNDED PURSE. At generation 1 the parent IS the edge currency:
/// the vault pays the whole payout and the keeper delivers nothing at all. The
/// {BidDeployer.MIN_BOUNTY_DOLL} floor exists to make a small delivery of REAL parent tokens worth
/// its gas, and on that branch there is no delivery to compensate - so the floor is not paid.
contract PurseSelfFundedBountyTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal keeper = address(0xBEEF);

    function setUp() public {
        _setUpEdge();
        // one more link, so that trades walking the chain fill generation 1's own sleeve
        _runWinningRound(1, WINNING_BUY);
        familyRouter.buyExactIn(2, 60 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, 20 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
        // the sleeve is drawable at 10% per 24 h, so the repeated small deployment this test
        // makes has to fit inside TODAY's allowance for the loop below to prove anything
        assertGt(vault.drawableEdge(1), 5 * 4 * bidDeployer.MIN_BOUNTY_DOLL(), "a sleeve to deploy");
    }

    /// @notice Repeat the smallest deployment a floor would make profitable. Every call is
    /// free to the keeper, so if a floor applied each one would skim `MIN_BOUNTY_DOLL` (capped at
    /// a quarter of the value) for no capital at all; the whole point of this test is that the
    /// total paid is the proportional rate on what was actually drawn instead.
    function test_theSelfFundedBranchPaysTheProportionalBountyOnly() public {
        uint256 min = bidDeployer.MIN_BOUNTY_DOLL();
        uint256 amount = 4 * min;
        uint256 keeperBefore = doll.balanceOf(keeper);
        uint256 drawableBefore = vault.drawableEdge(1);

        uint256 calls;
        for (uint256 i = 0; i < 5; i++) {
            if (bidDeployer.maxParentForDeploy(1) < amount) break;
            if (bidDeployer.bidCap(1) < amount) break;
            vm.prank(keeper);
            bidDeployer.deployAncestor(1, amount);
            calls++;
        }
        assertGt(calls, 1, "this loop really is repeatable");

        uint256 paid = doll.balanceOf(keeper) - keeperBefore;
        uint256 drawn = drawableBefore - vault.drawableEdge(1);
        // the keeper brought nothing, so everything it received is bounty
        assertEq(
            paid,
            (calls * amount * bidDeployer.BOUNTY_BPS()) / 10_000,
            "the proportional rate on each deployment, and nothing else"
        );
        assertLe(paid, (drawn * bidDeployer.BOUNTY_BPS()) / 10_000, "never more than the rate on what was drawn");
        // the floor, capped at a quarter of the value, is what applying a floor would pay per call
        assertLt(paid, (calls * amount) / 4, "far below the floor a floored branch would hand out");
        _assertSolvent();
    }

    /// @dev The floor where it BELONGS - a deployment that delivers real parent tokens - is
    /// asserted at generation 2 by `PurseTest.test_theBountyRuleIsUnchanged`.
}

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
contract PurseEdgeBidBountyTest is RoundTestBase {
    address internal keeper = address(0xC0FFEE);

    function setUp() public {
        // the pots a round of this size builds are thousands of $DOLL, so the floor is set above
        // them: this is the below-floor region, where a 20% ceiling would bind
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
contract PurseLinkOneInverseTest is RoundTestBase {
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
