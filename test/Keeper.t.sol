// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";

/// @notice What the keeper path is allowed to pay, and how fast.
///
/// The attack this guards against: buy a generation's parent token at the true price, pump a thin
/// ANCESTOR pool by a factor F, wait out the 30-minute TWAP, then call `deployAncestor` in a loop
/// until that generation's whole ETH sleeve has been paid out at the inflated rate, and sell the
/// pump back. Two independent brakes are tested here:
///
///   1. every link of the conversion is priced at `min(TWAP_30m, TWAP_7d)`, so a pump that is
///      only minutes old cannot raise the price the protocol pays at all;
///   2. a generation's sleeve can only be drawn down by {FeeVault.DAILY_DRAW_BPS} per 24 h, so
///      even a manipulation that survives both averages cannot take the sleeve in one block.
contract KeeperTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link2;
    address internal link3;

    function setUp() public {
        _setUpEdge();
        link2 = _runWinningRound(1, WINNING_BUY).token;
        link3 = _runWinningRound(1, WINNING_BUY).token;
    }

    /// @dev Trade the whole chain so that the shallow generations earn a real edge sleeve (the
    /// sleeve of a generation only fills when a DEEPER link is the attributed terminal token),
    /// and leave the oracles quiet afterwards so spot and the 30-minute average agree.
    function _accrue(uint256 dollIn) internal {
        familyRouter.buyExactIn(3, dollIn, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(3, dollIn / 10, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    // ---------------------------------------------------------------------------------
    // min(TWAP_30m, TWAP_7d)
    // ---------------------------------------------------------------------------------

    function test_aThirtyMinutePumpCannotRaiseWhatTheSleevePays() public {
        _buildSlowHistory();

        uint256 amount = 1_000_000e18; // a fixed parcel of link one's token
        (uint256 before,) = bidDeployer.dollValueOfParent(2, amount);
        assertGt(before, 0, "priced at the honest price");
        (, uint32 slowCovered) = hook.consultSlow(poolId, bidDeployer.SLOW_TWAP_WINDOW());
        emit log_named_uint("slow observations", hook.slowObservationCount(poolId));
        emit log_named_uint("slow coverage, s", slowCovered);
        assertGe(hook.slowObservationCount(poolId), 2, "the slow ring has history");
        assertGe(slowCovered, bidDeployer.SLOW_TWAP_MIN_COVERAGE(), "...and enough of it to be used");

        // THE PUMP: a large buy of the EDGE pool, then exactly the 30 minutes the fast average
        // needs to accept it as the new price.
        (uint160 spotBefore,,,) = im.getSlot0(poolId);
        // link one's pool has already absorbed a succession's worth of $DOLL, so the pump has to
        // be of that order to move the price at all
        _buyLink(1, 20_000_000e18);
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 16; i++) {
            t += 130;
            vm.warp(t);
            _buyLink(1, 0.01 ether);
        }
        (uint160 spotAfter,,,) = im.getSlot0(poolId);
        (uint160 fastAfter, uint32 fastCovered) = hook.consult(poolId, bidDeployer.TWAP_WINDOW());
        assertGe(fastCovered, bidDeployer.TWAP_WINDOW(), "the fast window is fully covered by the pump");
        assertLt(spotAfter, spotBefore, "the pump really did move link one's price");
        assertLt(fastAfter, spotBefore, "...and the 30-minute average followed it");

        // THE BRAKE: the conversion is floored by the 7-day average, so the parcel is still
        // priced at (almost exactly) the pre-pump price.
        (uint256 pumped,) = bidDeployer.dollValueOfParent(2, amount);
        emit log_named_uint("$DOLL paid for the parcel before the pump", before);
        emit log_named_uint("$DOLL paid for the parcel after the pump", pumped);
        // the 7-day average does move a little - the pump is 35 minutes of its ~51 hours - and
        // that residue is the whole gain: about 1%, against the 250% the fast average alone would
        // have handed over
        assertLe(pumped, (before * 102) / 100, "the pump bought at most 2% of extra payout");

        // and the fast-only price - what the old code paid - really was materially higher
        uint256 fastOnly = _valueAtPrice(amount, fastAfter);
        emit log_named_uint("$DOLL the 30-minute price alone would have paid", fastOnly);
        assertGt(fastOnly, 2 * pumped, "the same pump was worth multiples of that at the fast price alone");
    }

    /// @notice Until a pool has {BidDeployer.SLOW_TWAP_MIN_COVERAGE} of slow history there is
    /// nothing to floor the price with. That is not silently ignored: the deployment is priced on
    /// the fast average alone and says so.
    function test_aYoungPoolPricesOnTheFastAverageAndSaysSo() public {
        _warmOracles();
        _accrue(2 ether);
        (, uint32 slowCovered) = hook.consultSlow(roundManager.poolIdOf(1), bidDeployer.SLOW_TWAP_WINDOW());
        assertLt(slowCovered, bidDeployer.SLOW_TWAP_MIN_COVERAGE(), "a young pool has no 7-day average");

        // generation ONE is priced in the edge currency itself and reads no oracle at all, so the
        // first conversion that can miss a slow average is generation TWO's, across link one
        (, bool slowMissing) = bidDeployer.dollValueOfParent(2, 1_000e18);
        assertTrue(slowMissing, "and the conversion reports it");

        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper, 2);
        vm.expectEmit(true, false, false, false, address(bidDeployer));
        emit BidDeployer.SlowTwapUnavailable(2);
        vm.prank(keeper);
        bidDeployer.deployAncestor(2, amount);
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // min(spot, TWAP_30m, TWAP_7d)
    // ---------------------------------------------------------------------------------

    /// @notice THE CRASH. Only the TARGET pool is band-checked against spot, so a
    /// CONVERSION pool could be crashed and the two averages would keep quoting the pre-crash
    /// price for half an hour: the vault paid ~1.01x the old value for a parcel worth a tenth of
    /// it. Every link is now priced at `min(spot, TWAP_30m, TWAP_7d)` in value terms, so the
    /// payout tracks the crash immediately.
    function test_aCrashedConversionPoolIsPricedAtSpot() public {
        _warmOracles();
        _accrue(2 ether);

        uint256 amount = 1_000e18; // a fixed parcel of generation 3's parent, i.e. link two
        (uint256 before,) = bidDeployer.dollValueOfParent(3, amount);
        assertGt(before, 0, "priced at the honest price");

        // THE CRASH: dump link two into its OWN pool. That pool prices a conversion link for
        // generation 3, and nothing band-checks it.
        PoolId id2 = roundManager.poolIdOf(2);
        (uint160 fastBefore,) = hook.consult(id2, bidDeployer.TWAP_WINDOW());
        uint256[] memory path = new uint256[](2);
        path[0] = 2;
        path[1] = 1;
        uint256 held = IERC20(link2).balanceOf(address(this));
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
        familyRouter.swapPath(path, (held * 9) / 10, 0, address(this), 2);

        uint256 spotValue = _spotValue(3, amount);
        assertLt(spotValue, before / 10, "the conversion pool really lost 90%");
        (uint160 fastAfter,) = hook.consult(id2, bidDeployer.TWAP_WINDOW());
        assertApproxEqRel(uint256(fastAfter), uint256(fastBefore), 0.01e18, "the 30-minute average has not noticed");

        // THE BRAKE: the parcel is priced at spot, not at the stale average
        (uint256 afterCrash,) = bidDeployer.dollValueOfParent(3, amount);
        emit log_named_uint("$DOLL the averages alone would pay", before);
        emit log_named_uint("$DOLL the parcel is worth at spot", spotValue);
        emit log_named_uint("$DOLL the conversion now pays", afterCrash);
        assertLe(afterCrash, (spotValue * 101) / 100, "payout <= spot value + 1%");
        _assertNoEth();
    }

    /// @dev The edge-currency value of `amount` of generation `j`'s PARENT token at the CURRENT
    /// spot price of every pool on the walk - the same links {BidDeployer.dollValueOfParent}
    /// walks (`j - 1 .. 1`; index 0 has no pool), priced at slot0.
    function _spotValue(uint256 j, uint256 amount) internal view returns (uint256 value) {
        value = amount;
        for (uint256 k = j - 1; k >= 1; k--) {
            PoolId id = roundManager.poolIdOf(k);
            (uint160 sqrtP,,,) = im.getSlot0(id);
            if (hook.poolInfo(id).parentIsCurrency0) {
                value = FullMath.mulDiv(value, 1 << 96, sqrtP);
                value = FullMath.mulDiv(value, 1 << 96, sqrtP);
            } else {
                value = FullMath.mulDiv(value, sqrtP, 1 << 96);
                value = FullMath.mulDiv(value, sqrtP, 1 << 96);
            }
        }
    }

    // ---------------------------------------------------------------------------------
    // the bounty floor
    // ---------------------------------------------------------------------------------

    /// @notice KEEPER ECONOMICS. At Run-2 sizes the proportional 1% bounty was worth a
    /// fraction of the gas of the call (gas about 215x the bounty at j = 1), so no keeper would
    /// ever deploy a bid. Every deployment now pays at least {BidDeployer.MIN_BOUNTY_DOLL} out of
    /// the SAME sleeve, still capped at 20% of the edge currency the call consumes.
    ///
    /// @dev The edge is $DOLL, and link one is
    /// crowned by a round that had to absorb 0.15% of the whole adopted supply, so an EDGE bid is
    /// orders of magnitude past the floor and the proportional bounty pays for its gas many times
    /// over. The deployments where the floor is what makes the call worth making are the ancestor
    /// bids a keeper places round by round, which is where this test now stands: one hundredth of
    /// a $DOLL of value, deployed into generation two.
    function test_theBountyFloorIsPaidAtRunTwoSizes() public {
        assertEq(bidDeployer.MIN_BOUNTY_DOLL(), 3e14, "the testnet bounty floor");

        _warmOracles();
        _accrue(2_000 ether);

        // a Run-2-sized parcel: 0.01 $DOLL of value, well inside generation two's own sleeve
        address keeper = address(0xBEEF);
        address parent = roundManager.canonical(1);
        uint256 amount = bidDeployer.parentForDollValue(2, 0.01 ether);
        uint256 cap = bidDeployer.bidCap(2);
        if (amount > cap) amount = cap;
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);

        (uint256 dollValue,) = bidDeployer.dollValueOfParent(2, amount);
        uint256 proportional = (dollValue * bidDeployer.BOUNTY_BPS()) / 10_000;
        uint256 claimableBefore = vault.claimableEdge(2);
        uint256 before = doll.balanceOf(keeper);
        uint256 g = gasleft();
        _deployAncestorAs(keeper, 2, amount);
        uint256 gasUsed = g - gasleft();

        uint256 paid = doll.balanceOf(keeper) - before;
        uint256 bounty = paid - dollValue;
        uint256 consumed = claimableBefore - vault.claimableEdge(2);
        emit log_named_uint("deployAncestor(2) gas", gasUsed);
        emit log_named_uint("$DOLL of value deployed", dollValue);
        emit log_named_uint("proportional 1% bounty, wei", proportional);
        emit log_named_uint("bounty actually paid, wei", bounty);

        assertLt(proportional, 3e14, "the 1% bounty alone is below the floor");
        assertEq(bounty, 3e14, "the floor is what the keeper is paid");
        assertGt(bounty, 3 * (gasUsed * 0.01 gwei), "and it beats the gas of the call");
        assertEq(consumed, paid, "every wei came out of generation two's own sleeve");
        assertLe(
            bounty * 10_000, consumed * bidDeployer.MAX_BOUNTY_SHARE_BPS(), "never past 20% of the $DOLL consumed"
        );
        _assertSolvent();
        _assertNoEth();
    }

    /// @dev The four edge-currency pots {BidDeployer.deployEdgeBid} draws on.
    function _edgePots() internal view returns (uint256) {
        return vault.edgeBidEarmark() + vault.reinforcementBalance(address(doll)) + vault.claimableEdge(0)
            + vault.claimableEdge(1);
    }

    /// @notice THE SELF-FUNDED BRANCH PAYS NO FLOOR. At generation 1 the parent IS
    /// the edge currency: the vault pays the whole payout and the keeper delivers nothing, so
    /// there is no capital at risk for the {BidDeployer.MIN_BOUNTY_DOLL} floor to compensate.
    /// Paying it here meant a keeper could repeat the smallest possible call for the floor
    /// (capped at a quarter of the value) until the generation's daily allowance was empty. The
    /// rule on this branch is the proportional rate and nothing else; the floor and its 20% cap
    /// still govern every deployment that DELIVERS parent tokens (generation 2 and up, above).
    function test_theSelfFundedBranchPaysTheProportionalBountyWithNoFloor() public {
        _warmOracles();
        _accrue(2 ether);

        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper, 1);
        (uint256 dollValue,) = bidDeployer.dollValueOfParent(1, amount);
        uint256 proportional = (dollValue * bidDeployer.BOUNTY_BPS()) / 10_000;
        assertLt(dollValue, 4 * 3e14, "a deployment far too small to carry the floor");

        uint256 claimableBefore = vault.claimableEdge(1);
        uint256 before = doll.balanceOf(keeper);
        _deployAncestorAs(keeper, 1, amount);

        // generation one is paid in the SAME currency it deploys, so the keeper's parcel and its
        // payout net out: what is left over is exactly the bounty
        uint256 paid = doll.balanceOf(keeper) - before + amount;
        uint256 bounty = paid - dollValue;
        uint256 consumed = claimableBefore - vault.claimableEdge(1);
        assertEq(consumed, paid, "the whole payout came out of generation 1's own entitlement");
        assertEq(bounty, proportional, "the proportional rate, and nothing on top of it");
        assertLt(bounty, _expectedBounty(dollValue), "far below what the floored rule would have paid");
        assertLe(bounty * 10_000, consumed * bidDeployer.MAX_BOUNTY_SHARE_BPS(), "well inside the 20% ceiling");
        _assertSolvent();
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // the terminal generation's hop pot
    // ---------------------------------------------------------------------------------

    /// @notice THE STRANDED HEAD. The head of the chain has no descendant round, so its
    /// edge sleeve never fills (a sleeve only fills when a DEEPER link is the attributed terminal
    /// token) and `deployAncestor` - which pays out of that sleeve - can never be called for it.
    /// Its parent-denominated hop pot was therefore stuck in the vault forever, permanently so at
    /// `MAX_INDEX`. `deployHopPot` deploys it on its own, for a bounty in the same token.
    function test_theHeadsHopPotDeploysWithNoEdgeEntitlement() public {
        _warmOracles();
        _accrue(2 ether);

        assertEq(roundManager.headIndex(), 3, "generation 3 is the head");
        assertEq(vault.claimableEdge(3), 0, "the head has no edge sleeve, and never will");
        uint256 pot = vault.reinforcementBalance(link2);
        assertGt(pot, 0, "but its trades have collected a parent-denominated hop pot");

        // the edge-currency path cannot touch it: there is no entitlement to pay a keeper from
        address keeper = address(0xBEEF);
        vm.prank(keeper);
        vm.expectRevert(BidDeployer.TooMuchRequested.selector);
        bidDeployer.deployAncestor(3, 1e18);

        // the pot path can, permissionlessly, with no edge currency anywhere in the call
        uint256 vaultDollBefore = doll.balanceOf(address(vault));
        vm.prank(keeper);
        (uint256 deposited, uint256 bounty) = bidDeployer.deployHopPot(3);

        uint256 drawn = deposited + bounty;
        assertGt(deposited, 0, "the pot became liquidity");
        assertLe(drawn, bidDeployer.bidCap(3), "never more than the size cap in one call");
        assertEq(drawn, pot < bidDeployer.bidCap(3) ? pot : bidDeployer.bidCap(3), "min(pot, cap) was drawn");
        assertEq(bounty, (drawn * bidDeployer.BOUNTY_BPS()) / 10_000, "1% bounty");
        assertEq(IERC20(link2).balanceOf(keeper), bounty, "...paid to the keeper in parent tokens");
        assertEq(vault.reinforcementBalance(link2), pot - drawn, "the pot was drawn partially, never zeroed");
        assertEq(doll.balanceOf(address(vault)), vaultDollBefore, "no edge currency moved");
        assertEq(IERC20(link2).balanceOf(address(bidDeployer)), 0, "nothing is left stranded here");
        _assertSolvent();
        _assertNoEth();

        // an empty pot is a revert, not a free bounty...
        if (vault.reinforcementBalance(link2) == 0) {
            vm.prank(keeper);
            vm.expectRevert(BidDeployer.NothingToClaim.selector);
            bidDeployer.deployHopPot(3);
        }
        // ...and so is a generation that does not exist, or index 0 - the adopted genesis, which
        // has no pool of ours at all; its pots reach link one through `deployEdgeBid`
        vm.expectRevert(BidDeployer.UnknownGeneration.selector);
        bidDeployer.deployHopPot(4);
        vm.expectRevert(BidDeployer.NoPoolAtIndex.selector);
        bidDeployer.deployHopPot(0);
    }

    // ---------------------------------------------------------------------------------
    // the drawdown bucket
    // ---------------------------------------------------------------------------------

    function test_theDailyDrawdownLimitBindsAndRefills() public {
        _warmOracles();
        _accrue(2 ether);
        uint256 claimable = vault.claimableEdge(1);
        assertGt(claimable, 0, "generation 1 has a sleeve");

        uint256 allowance = (claimable * vault.DAILY_DRAW_BPS()) / 10_000;
        assertEq(vault.drawableEdge(1), allowance, "an untouched generation starts with a full bucket");
        assertLt(vault.drawableEdge(1), vault.claimableEdge(1), "the limit really binds");

        // the vault refuses a draw past the bucket even from its own BidDeployer
        vm.prank(address(bidDeployer));
        vm.expectRevert(abi.encodeWithSelector(FeeVault.DailyLimitExceeded.selector, allowance + 1, allowance));
        vault.consumeAncestorClaim(1, allowance + 1);

        // a keeper deployment sizes itself against the bucket, not against the sleeve
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper, 1);
        _deployAncestorAs(keeper, 1, amount);
        (uint64 updatedAt, uint256 available, uint256 cap) = vault.drawBucket(1);
        assertEq(updatedAt, uint64(block.timestamp), "the bucket was drawn now");
        assertLt(available, cap, "and it is no longer full");

        // the rest of the bucket, then nothing more until it refills
        uint256 left = vault.drawableEdge(1);
        vm.prank(address(bidDeployer));
        vault.consumeAncestorClaim(1, left);
        assertEq(vault.drawableEdge(1), 0, "the bucket is empty");
        vm.prank(address(bidDeployer));
        vm.expectRevert(abi.encodeWithSelector(FeeVault.DailyLimitExceeded.selector, 1, 0));
        vault.consumeAncestorClaim(1, 1);
        assertGt(vault.claimableEdge(1), 0, "but the sleeve itself is untouched beyond the bucket");

        // it refills CONTINUOUSLY: a quarter of a day is a quarter of the cap, not nothing
        uint256 capNow = (vault.claimableEdge(1) * vault.DAILY_DRAW_BPS()) / 10_000;
        vm.warp(block.timestamp + uint256(vault.DRAW_WINDOW()) / 4);
        assertApproxEqRel(vault.drawableEdge(1), capNow / 4, 0.01e18, "a quarter day refills a quarter of the cap");

        // ...and a full day refills it to the cap and no further
        vm.warp(block.timestamp + uint256(vault.DRAW_WINDOW()));
        assertEq(vault.drawableEdge(1), capNow, "a full bucket, sized on the remaining sleeve");
    }

    /// @notice THE BOUNDARY BURST. The old limit was a RESETTING window: a keeper could
    /// spend the whole 10% allowance in the last second of a window and another 10% of a fresh
    /// base one second later - about 19% of the sleeve in seconds, while the docs promised "10%
    /// per rolling 24 hours". The token bucket has no boundary to sit on.
    function test_noBurstAcrossTheOldWindowBoundary() public {
        _warmOracles();
        _accrue(2 ether);

        uint256 claimable = vault.claimableEdge(1);
        uint256 tenth = (claimable * vault.DAILY_DRAW_BPS()) / 10_000;

        // spend the whole bucket...
        uint256 first = vault.drawableEdge(1);
        vm.prank(address(bidDeployer));
        vault.consumeAncestorClaim(1, first);

        // ...then try again one second after the old window would have rolled over
        vm.warp(block.timestamp + uint256(vault.DRAW_WINDOW()) - 1);
        uint256 second = vault.drawableEdge(1);
        vm.prank(address(bidDeployer));
        vault.consumeAncestorClaim(1, second);
        vm.warp(block.timestamp + 2);
        uint256 third = vault.drawableEdge(1);

        // the BURST is what a keeper can take in the two seconds that straddle the old boundary:
        // under the resetting window that was the tail of one allowance plus a whole fresh one
        uint256 burst = second + third;
        emit log_named_uint("drawn in the 2 s across the old boundary, wei", burst);
        emit log_named_uint("10% of the sleeve, wei", tenth);
        assertLe(burst, tenth + tenth / 100, "at most one 10% allowance across the boundary");
        assertLt(burst, (tenth * 19) / 10, "and nowhere near the 19% the resetting window allowed");
        assertLt(third, tenth / 100, "crossing the old boundary refills nothing but the 2 s of drip");
        assertGt(first, 0, "the first draw really did take the whole bucket");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev The edge-currency value of `amount` of link one's token at a given sqrt price - the
    /// same two mulDivs the conversion does, for one link.
    function _valueAtPrice(uint256 amount, uint160 sqrtP) internal pure returns (uint256) {
        // link one pairs $DOLL (currency0) against the token, so parent-per-token is (Q96/sqrtP)^2
        uint256 v = (amount * (1 << 96)) / sqrtP;
        return (v * (1 << 96)) / sqrtP;
    }

    /// @dev Give `keeper` a deployable parcel of generation `j`'s parent token, approved.
    function _keeperStock(address keeper, uint256 j) internal returns (uint256 amount) {
        address parent = roundManager.canonical(j - 1);
        uint256 cap = bidDeployer.bidCap(j);
        uint256 affordable = bidDeployer.maxParentForDeploy(j);
        amount = cap < affordable ? cap : affordable;
        uint256 held = IERC20(parent).balanceOf(address(this));
        if (amount > held) amount = held;
        assertGt(amount, 0, "there is something to deploy");
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);
    }

    /// @dev Give the edge pool a SLOW observation ring with more than a day of coverage: the
    /// slow ring samples at most once every three hours, so this is two days of light trading.
    function _buildSlowHistory() internal {
        // NOTE: `block.timestamp` is common-subexpression-eliminated across `vm.warp` inside a
        // single function under `via_ir`, so the clock is tracked in a local instead.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 16; i++) {
            _buyLink(1, 0.01 ether);
            t += 3 hours + 300;
            vm.warp(t);
        }
        _buyLink(1, 0.01 ether);
        vm.warp(t + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }
}
