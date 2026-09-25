// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FenwickHarness} from "./utils/FenwickHarness.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {ILocker} from "../contracts/interfaces/ILocker.sol";

/// @notice The fee ledger: the exact split, the Fenwick ancestor sleeve against a brute-force
/// ledger, pull claims, and the keeper deployment path end to end.
contract FeeVaultTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;
    uint256 internal constant WAD = 1e18;

    address internal link2;
    address internal link3;
    FenwickHarness internal fenwick;

    function setUp() public {
        _setUpEdge();
        link2 = _runWinningRound(1, WINNING_BUY).token;
        link3 = _runWinningRound(1, WINNING_BUY).token;
        fenwick = new FenwickHarness();
    }

    // ---------------------------------------------------------------------------------
    // the split
    // ---------------------------------------------------------------------------------

    /// @notice dev + creator + ancestor sleeve + reinforcement == the protocol fee, exactly.
    function test_allocationSumsExactly() public {
        uint256 devBefore = vault.devBalance();
        uint256 reinforce1Before = vault.reinforcementEdge(1);
        uint256 reinforce2Before = vault.reinforcementEdge(2);
        uint256 reinforceSeen;
        vm.recordLogs();
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 checked;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != FeeVault.FeeSplit.selector) continue;
            (
                uint256 hopFee,
                uint256 protocolFee,
                uint256 terminalIndex,
                bool attributed,
                uint256 dev,
                uint256 creator,
                uint256 sleeve,
                uint256 reinforce
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool, uint256, uint256, uint256, uint256));
            assertGt(hopFee, 0, "every leg pays the hop fee");
            if (protocolFee == 0) continue;

            assertTrue(attributed, "the router attributed the edge leg");
            assertEq(terminalIndex, 3);
            assertEq(protocolFee, 1 ether / 100, "1% of the edge leg");
            assertEq(dev, (protocolFee * vault.DEV_BPS()) / 10_000, "dev 20%");
            assertEq(creator, (protocolFee * CREATOR_BPS) / 10_000, "creator share");
            uint256 remainder = protocolFee - dev - creator;
            assertEq(sleeve, (remainder * ANCESTOR_BPS) / 10_000, "ancestor sleeve of the remainder");
            assertEq(reinforce, remainder - sleeve, "reinforcement takes the remainder exactly");
            assertEq(dev + creator + sleeve + reinforce, protocolFee, "the split is exact");
            reinforceSeen = reinforce;
            checked++;
        }
        assertEq(checked, 1, "exactly one edge fee");

        // the ledgers agree with the event, and the vault is solvent
        assertEq(vault.devBalance() - devBefore, (1 ether / 100 * vault.DEV_BPS()) / 10_000);
        assertEq(vault.creatorBalance(link3), (1 ether / 100 * CREATOR_BPS) / 10_000);
        // M = 2 for terminal index 3: the reinforcement sleeve belongs to link #2
        assertEq(
            vault.reinforcementEdge(2) - reinforce2Before, reinforceSeen, "the immediate parent (#2) is reinforced"
        );
        assertEq(vault.reinforcementEdge(1), reinforce1Before, "link one is not the immediate parent here");
        _assertSolvent();
    }

    /// @notice Unattributed fees (a direct PoolManager swap on the EDGE pool, paid in $DOLL) go
    /// entirely to the flywheel, with index 0 - the adopted genesis - as the beneficiary (M = 0).
    function test_unattributedFeesFallBackToGenesis() public {
        PoolKey memory edgeKey = roundManager.poolKeyOf(1);
        plainRouter.swap(
            edgeKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(vault.creatorBalance(link3), 0, "no creator share without attribution");
        assertGt(vault.claimableAncestor(0), 0, "the whole sleeve went to the adopted genesis");
        assertEq(vault.claimableAncestor(1), 0, "no one else is an ancestor of the flywheel");
        assertGt(vault.reinforcementEdge(0), 0, "and index 0 takes the reinforcement sleeve");
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // Fenwick ancestor sleeve
    // ---------------------------------------------------------------------------------

    /// @notice 50 pseudo-random attributed sleeves with M up to 30, checked against a
    /// brute-force per-index ledger: the range-add/point-query machinery must be exact.
    function test_fenwickPointQueriesMatchBruteForceLedger() public {
        int256[31] memory expected;
        uint256 seed = uint256(keccak256("family-fee-vault"));

        for (uint256 k = 0; k < 50; k++) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 sleeve = (seed % 3 ether) + 1;
            uint256 M = (seed >> 128) % 31;

            fenwick.addSleeve(sleeve, M);

            // brute force: the same coefficients, applied one index at a time
            if (M == 0) {
                expected[0] += int256(sleeve * WAD);
            } else {
                uint256 aWad = FullMath.mulDiv(sleeve * WAD, 6 * M, (M + 1) * (5 * M + 4));
                int256 c0 = int256(2 * aWad);
                int256 c1 = -int256((5 * aWad) / M);
                int256 c2 = int256((4 * aWad) / (M * M));
                for (uint256 j = 0; j <= M; j++) {
                    expected[j] += c0 + c1 * int256(j) + c2 * int256(j * j);
                }
            }

            for (uint256 j = 0; j < 31; j++) {
                assertEq(fenwick.query(j), expected[j], "point query equals the brute-force ledger");
            }
        }

        // the signed intermediates really do go negative: an unsigned port would underflow
        assertLt(fenwick.coefficientPrefix(1, 30), 0, "the linear coefficient is negative");
    }

    /// @notice The weight shape: OG-heavy, `w(0) = 2 x w(M)`, minimum at r = 5/8, and the sleeve
    /// is never over-allocated (floored coefficients leave a few wei of dust behind).
    function test_ancestorWeightShapeAndConservation() public {
        uint256 M = 8;
        uint256 sleeve = 1 ether;
        fenwick.addSleeve(sleeve, M);

        uint256 total;
        uint256[9] memory w;
        for (uint256 j = 0; j <= M; j++) {
            w[j] = uint256(fenwick.query(j)) / WAD;
            total += w[j];
        }
        assertApproxEqRel(w[0], 2 * w[M], 1e12, "genesis gets twice the newest link");
        assertLe(w[5], w[4], "the U bottoms out around r = 5/8");
        assertLe(w[5], w[6], "and rises again after it");
        assertLe(total, sleeve, "never over-allocated");
        assertApproxEqAbs(total, sleeve, 100, "and the dust is negligible");
    }

    // ---------------------------------------------------------------------------------
    // claims
    // ---------------------------------------------------------------------------------

    function test_devAndCreatorClaims() public {
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 devOwed = vault.devBalance();
        uint256 creatorOwed = vault.creatorBalance(link3);
        address creator = roundManager.creatorOf(link3);
        assertGt(devOwed, 0);
        assertGt(creatorOwed, 0);

        vm.expectRevert(FeeVault.NotDeveloper.selector);
        vault.claimDev(address(this));

        vm.prank(developer);
        vault.claimDev(developer);
        assertEq(doll.balanceOf(developer), devOwed, "dev paid in real $DOLL");
        assertEq(vault.devBalance(), 0);
        vm.prank(developer);
        vm.expectRevert(FeeVault.NothingToClaim.selector);
        vault.claimDev(developer);

        vm.expectRevert(FeeVault.NotCreator.selector);
        vault.claimCreator(link3, address(this));

        uint256 creatorBalanceBefore = doll.balanceOf(creator);
        vm.prank(creator);
        vault.claimCreator(link3, creator);
        assertEq(doll.balanceOf(creator) - creatorBalanceBefore, creatorOwed, "creator paid");
        vm.prank(creator);
        vm.expectRevert(FeeVault.NothingToClaim.selector);
        vault.claimCreator(link3, creator);

        _assertSolvent();
    }

    function test_creatorRecipientIsTransferable() public {
        address creator = roundManager.creatorOf(link3);
        address newRecipient = address(0xBEE5);

        vm.prank(creator);
        vault.transferCreatorRecipient(link3, newRecipient);
        assertEq(vault.creatorRecipient(link3), newRecipient);

        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        vm.prank(creator);
        vm.expectRevert(FeeVault.NotCreator.selector);
        vault.claimCreator(link3, creator);

        uint256 owed = vault.creatorBalance(link3);
        vm.prank(newRecipient);
        vault.claimCreator(link3, newRecipient);
        assertEq(doll.balanceOf(newRecipient), owed);
    }

    /// @notice AUDIT (spec discrepancy): transferring the creator right moves the FUTURE stream
    /// only. What had already accrued stays claimable by the address that earned it - the old
    /// code paid it to whoever held the right at claim time, so a transfer silently gave away
    /// booked earnings - and `address(0)` is refused rather than burning the stream.
    function test_transferringTheCreatorRightLeavesAccruedFeesBehind() public {
        address creator = roundManager.creatorOf(link3);
        address newRecipient = address(0xBEE5);

        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 accrued = vault.creatorBalance(link3);
        assertGt(accrued, 0, "the original creator earned something first");

        // the zero address is not a legal destination
        vm.prank(creator);
        vm.expectRevert(FeeVault.BadRecipient.selector);
        vault.transferCreatorRecipient(link3, address(0));

        vm.prank(creator);
        vault.transferCreatorRecipient(link3, newRecipient);
        assertEq(vault.creatorBalance(link3), 0, "the token's ledger was swept at the transfer");
        assertEq(vault.creatorAccrued(creator), accrued, "...into the OLD recipient's own ledger");

        // the new recipient gets what is earned from now on, and nothing of what came before
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 fresh = vault.creatorBalance(link3);
        assertGt(fresh, 0, "the new recipient earns the future stream");
        vm.prank(newRecipient);
        vault.claimCreator(link3, newRecipient);
        assertEq(doll.balanceOf(newRecipient), fresh, "and only the future stream");

        // the old one claims what it earned, once
        uint256 creatorBefore = doll.balanceOf(creator);
        vm.prank(creator);
        uint256 paid = vault.claimCreatorAccrued(creator);
        assertEq(paid, accrued);
        assertEq(
            doll.balanceOf(creator) - creatorBefore, accrued, "the accrued balance followed the address that earned it"
        );
        vm.prank(creator);
        vm.expectRevert(FeeVault.NothingToClaim.selector);
        vault.claimCreatorAccrued(creator);
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // keeper deployment
    // ---------------------------------------------------------------------------------

    /// @dev Trade on every canonical pool, twice, far enough apart that each pool has two
    /// observations, then let the clock run so the TWAP covers the whole window and converges on
    /// spot. Without this the band guard refuses to act at all.
    function _accrueAndSettle(uint256 dollIn) internal {
        familyRouter.buyExactIn(3, dollIn, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(3, dollIn / 10, 0, address(this), 3);
        vm.warp(block.timestamp + 7 days); // the TWAP converges on the last traded price
    }

    /// @dev Acquire `parent` tokens for the keeper and approve the vault.
    function _fundKeeper(address keeper, uint256 index, uint256 dollIn) internal returns (uint256 amount) {
        address parent = roundManager.canonical(index);
        uint256 before = IERC20(parent).balanceOf(address(this));
        familyRouter.buyExactIn(index, dollIn, 0, address(this), index + 1);
        amount = IERC20(parent).balanceOf(address(this)) - before;
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);
    }

    /// @dev The parent amount a keeper can actually deploy into generation `j` right now.
    function _deployableParent(uint256 j) internal view returns (uint256) {
        uint256 cap = bidDeployer.bidCap(j);
        uint256 affordable = bidDeployer.maxParentForDeploy(j);
        return cap < affordable ? cap : affordable;
    }

    // ---------------------------------------------------------------------------------
    // keeper deployment: the keeper brings the parent tokens, the vault never swaps
    // ---------------------------------------------------------------------------------

    function test_deployAncestorBuysParentFromTheKeeperAndLocksTheBid() public {
        address keeper = address(0xBEEF);
        uint256 keeperStock = _fundKeeper(keeper, 1, 3 ether);
        _accrueAndSettle(2 ether);

        uint256 claimable = vault.claimableEdge(2);
        assertGt(claimable, 0, "generation 2 has an edge-currency sleeve");

        uint256 parentAmount = _deployableParent(2);
        assertGt(parentAmount, 0, "there is something to deploy");
        if (parentAmount > keeperStock) parentAmount = keeperStock;
        // The conversion walks the AMOUNT through the chain, so the test must price it the
        // same way rather than through a normalised per-WAD rate
        (uint256 dollValue,) = bidDeployer.dollValueOfParent(2, parentAmount);
        uint256 payout = dollValue + _expectedBounty(dollValue);

        PoolId poolId2 = roundManager.poolIdOf(2);
        uint128 liquidityBefore = im.getLiquidity(poolId2);
        uint256 keeperDollBefore = doll.balanceOf(keeper);
        uint256 hopPot = vault.reinforcementBalance(address(token));
        uint256 cap = bidDeployer.bidCap(2);
        // The hop pot is drawn PARTIALLY, up to whatever room the size cap leaves
        uint256 expectedDraw = hopPot < cap - parentAmount ? hopPot : cap - parentAmount;

        vm.recordLogs();
        uint256 deposited = _deployAncestorAs(keeper, 2, parentAmount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(address(token)).balanceOf(keeper), keeperStock - parentAmount, "keeper delivered the parent");
        assertEq(doll.balanceOf(keeper) - keeperDollBefore, payout, "keeper paid the $DOLL value plus the bounty");
        assertGt(payout, dollValue, "the bounty is on top of the conversion value");
        assertEq(vault.claimableEdge(2), claimable - payout, "exactly the payout left the sleeve");
        assertEq(deposited, parentAmount + expectedDraw, "the pool's own hop fees went in alongside");
        assertEq(vault.reinforcementBalance(address(token)), hopPot - expectedDraw, "hop pot decremented, not zeroed");
        assertLe(deposited, cap, "the deposit respects the size cap");

        // the bid is a real, locked position owned by the Locker
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _lastBid(logs);
        assertGt(liquidity, 0, "a bid was placed");
        (uint128 posLiquidity,,) = im.getPositionInfo(poolId2, address(locker), tickLower, tickUpper, bytes32(0));
        assertEq(posLiquidity, liquidity, "the Locker owns the position");
        assertEq(tickUpper - tickLower, 60 * 10, "10 tick spacings wide");

        (, int24 currentTick,,) = im.getSlot0(poolId2);
        bool parentIsCurrency0 = Currency.unwrap(roundManager.poolKeyOf(2).currency0) == address(token);
        if (parentIsCurrency0) {
            assertGt(tickLower, currentTick, "parent-only range sits above spot (mirrored frame)");
        } else {
            assertLe(tickUpper, currentTick, "parent-only range sits below spot");
        }
        assertGe(im.getLiquidity(poolId2), liquidityBefore, "liquidity never decreases");
        _assertSolvent();
    }

    /// @notice The vault never calls the router: a deployment is a transfer plus an unlock, and
    /// nothing in it can move the price of any pool on the chain.
    function test_deployAncestorDoesNotSwap() public {
        address keeper = address(0xBEEF);
        uint256 stock = _fundKeeper(keeper, 1, 3 ether);
        _accrueAndSettle(2 ether);

        uint256 amount = _deployableParent(2);
        if (amount > stock) amount = stock;
        (uint160 edgeBefore,,,) = im.getSlot0(roundManager.poolIdOf(1));
        (uint160 childBefore,,,) = im.getSlot0(roundManager.poolIdOf(2));

        _deployAncestorAs(keeper, 2, amount);

        (uint160 edgeAfter,,,) = im.getSlot0(roundManager.poolIdOf(1));
        (uint160 childAfter,,,) = im.getSlot0(roundManager.poolIdOf(2));
        assertEq(edgeAfter, edgeBefore, "no swap on the edge pool");
        assertEq(childAfter, childBefore, "a single-sided bid never moves the price");
    }

    /// @notice A keeper cannot drain more of the edge currency than the generation is owed, and cannot exceed the
    /// per-call size cap.
    function test_deployAncestorRespectsSleeveAndSizeCap() public {
        address keeper = address(0xBEEF);
        uint256 stock = _fundKeeper(keeper, 1, 20 ether);
        _accrueAndSettle(2 ether);

        uint256 affordable = bidDeployer.maxParentForDeploy(2);
        uint256 cap = bidDeployer.bidCap(2);
        assertGt(affordable, 0);
        assertGt(cap, 0, "a live pool has a non-zero size cap");

        if (affordable + 1 <= stock && affordable + 1 > 0) {
            vm.prank(keeper);
            vm.expectRevert(BidDeployer.TooMuchRequested.selector);
            bidDeployer.deployAncestor(2, affordable * 2 + 1);
        }

        // and a partial deployment is fine: half now, the rest still claimable
        uint256 half = _deployableParent(2) / 2;
        _deployAncestorAs(keeper, 2, half);
        assertGt(vault.claimableEdge(2), 0, "partial draw leaves the rest claimable");
        _assertSolvent();
    }

    /// @notice The band is checked on the TARGET pool only. Requiring every pool on the
    /// chain to be simultaneously within +/-3% of its own TWAP made the keeper path less and less
    /// callable with depth (P(all in band) shrinks with j) for no safety gain: an ancestor's
    /// price only enters the conversion, where it is already floored by the slow TWAP and
    /// its coverage requirement.
    function test_deployAncestorBandsTheTargetPoolOnly() public {
        address keeper = address(0xBEEF);
        uint256 stock = _fundKeeper(keeper, 1, 3 ether);
        _accrueAndSettle(2 ether);
        uint256 amount = _deployableParent(2) / 2;
        if (amount > stock) amount = stock;

        // a whale dumps into the ANCESTOR (link one, the edge) pool right before the keeper call
        uint256 dump = IERC20(address(token)).balanceOf(address(this)) / 2;
        IERC20(address(token)).approve(address(familyRouter), type(uint256).max);
        familyRouter.sellExactIn(1, dump, 0, address(this), 1);
        (uint160 spot0,,,) = im.getSlot0(roundManager.poolIdOf(1));
        (uint160 twap0,) = hook.consult(roundManager.poolIdOf(1), bidDeployer.TWAP_WINDOW());
        assertGt(spot0, (uint256(twap0) * 10_300) / 10_000, "the ancestor pool really is out of band");

        _deployAncestorAs(keeper, 2, amount); // still callable: pool #2 is the target, not #1

        // ...but the TARGET pool out of band is still refused outright. The push is made with
        // link-one tokens straight into pool #2, so the crashed ancestor pool cannot soak it up.
        uint256[] memory hop = new uint256[](2);
        hop[0] = 1;
        hop[1] = 2;
        familyRouter.swapPath(hop, IERC20(address(token)).balanceOf(address(this)) / 2, 0, address(this), 1);
        (uint160 spot1,,,) = im.getSlot0(roundManager.poolIdOf(2));
        (uint160 twap1,) = hook.consult(roundManager.poolIdOf(2), bidDeployer.TWAP_WINDOW());
        // a candidate token may sort either side of its parent, so a buy moves the pool's sqrt
        // price up or down depending on orientation. The band is two-sided; assert on distance.
        assertTrue(
            spot1 > (uint256(twap1) * 10_300) / 10_000 || spot1 < (uint256(twap1) * 9_700) / 10_000,
            "the target pool is out of band"
        );
        uint256 rest = _deployableParent(2) / 2;
        if (rest > IERC20(address(token)).balanceOf(keeper)) rest = IERC20(address(token)).balanceOf(keeper);
        vm.prank(keeper);
        vm.expectRevert(BidDeployer.PriceOutOfBand.selector);
        bidDeployer.deployAncestor(2, rest);
    }

    /// @notice `maxParentForDeploy` must not report ZERO whenever the generation's
    /// drawable ETH is at or below {MIN_BOUNTY_DOLL}, even though such a call is accepted: below
    /// the floor the bounty is capped at {MAX_BOUNTY_SHARE_BPS} of the total the call consumes,
    /// so `0.8 * available` is deployable. The quote must be the REAL maximum in every regime,
    /// and must always satisfy `deployAncestor`'s own guard, `dollValue + bounty <= available`.
    function test_maxParentForDeployIsTheRealMaximumBelowTheBountyFloor() public {
        _fundKeeper(address(0xBEEF), 1, 3 ether);
        _accrueAndSettle(2 ether);

        uint256 m = bidDeployer.MIN_BOUNTY_DOLL();
        assertGt(m, 0, "the floor is what this test is about");

        // one allowance in each branch of the piecewise bounty, plus both knees
        uint256[7] memory allowances = [m / 3, m, m + 1, 4 * m, 5 * m, 100 * m, 101 * m];
        for (uint256 i = 0; i < allowances.length; i++) {
            uint256 available = allowances[i];
            vm.mockCall(
                address(vault), abi.encodeWithSelector(vault.drawableEdge.selector, uint256(2)), abi.encode(available)
            );

            uint256 parentAmount = bidDeployer.maxParentForDeploy(2);
            assertGt(parentAmount, 0, "a non-zero allowance always buys something");

            // exactly the check `deployAncestor` makes: the quote must be ACCEPTED, not refused
            (uint256 dollValue,) = bidDeployer.dollValueOfParent(2, parentAmount);
            assertLe(dollValue, available, "the quoted value fits the allowance");
            assertLe(dollValue + _expectedBounty(dollValue), available, "value plus bounty fits the allowance");

            // ...and it really is the maximum: 1% more parent no longer fits
            (uint256 tooMuch,) = bidDeployer.dollValueOfParent(2, parentAmount + parentAmount / 100);
            assertGt(tooMuch + _expectedBounty(tooMuch), available, "the quote is not conservative");
            vm.clearMockedCalls();
        }
    }

    /// @notice And the quote a below-floor allowance produces is accepted by the real call.
    function test_deployAncestorAcceptsTheBelowFloorQuote() public {
        address keeper = address(0xBEEF);
        uint256 stock = _fundKeeper(keeper, 1, 3 ether);
        _accrueAndSettle(2 ether);

        uint256 m = bidDeployer.MIN_BOUNTY_DOLL();
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.drawableEdge.selector, uint256(2)), abi.encode(m));
        uint256 amount = bidDeployer.maxParentForDeploy(2);
        vm.clearMockedCalls();

        assertGt(amount, 0, "the below-floor quote is non-zero");
        uint256 cap = bidDeployer.bidCap(2);
        if (amount > cap) amount = cap;
        if (amount > stock) amount = stock;

        _deployAncestorAs(keeper, 2, amount);
        _assertSolvent();
    }

    /// @notice A pool whose oracle does not cover the window is refused outright - a spot
    /// price is never silently accepted as a TWAP.
    function test_deployRevertsWhenTheTwapIsNotReady() public {
        // a brand new stack: link one has exactly one observation and no history
        vm.expectRevert();
        bidDeployer.deployEdgeBid();
    }

    function test_deployEdgeBidDepositsForfeitedBonds() public {
        // a failed round forfeits its bonds into the edge-bid earmark
        _registerCandidate(address(0xF00D), "FAIL");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(vault.edgeBidEarmark(), roundManager.currentBond(), "bond earmarked");

        _accrueAndSettle(1 ether);

        PoolId edgeId = roundManager.poolIdOf(1);
        uint256 pot = _edgePots();
        // The bounty is paid ON TOP of the deposit, exactly as `deployAncestor` pays it, so the
        // four pots have to fund `deposited * (1 + BOUNTY_BPS)`...
        uint256 expected = (pot * 10_000) / (10_000 + bidDeployer.BOUNTY_BPS());
        // ...and it is the DEPOSIT that the active-range size cap bounds.
        uint256 room = bidDeployer.bidCap(1);
        if (expected > room) expected = room;
        uint128 liquidityBefore = im.getLiquidity(edgeId);
        uint256 keeperDollBefore = doll.balanceOf(address(0xBEEF));
        uint256 potsBefore = _edgePots();

        vm.recordLogs();
        vm.prank(address(0xBEEF));
        uint256 deposited = bidDeployer.deployEdgeBid();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(deposited, expected, "the pots fund the deposit plus the 1% bounty on top of it");
        uint256 bounty = _expectedBounty(deposited);
        assertEq(
            doll.balanceOf(address(0xBEEF)) - keeperDollBefore,
            bounty,
            "the keeper is paid the bounty on top of the DEPOSIT"
        );
        uint256 potsAfter = _edgePots();
        assertEq(potsBefore - potsAfter, deposited + bounty, "and the pots lost exactly the deposit plus the bounty");
        assertLe(vault.edgeBidEarmark(), roundManager.currentBond(), "earmark drawn down");

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _lastBid(logs);
        (uint128 posLiquidity,,) = im.getPositionInfo(edgeId, address(locker), tickLower, tickUpper, bytes32(0));
        assertEq(posLiquidity, liquidity, "the $DOLL bid is locked in the Locker's position");
        (, int24 currentTick,,) = im.getSlot0(edgeId);
        assertGt(tickLower, currentTick, "$DOLL-only range: above the current tick, below spot in token terms");
        assertGe(im.getLiquidity(edgeId), liquidityBefore);
        _assertSolvent();
        _assertNoEth();
    }

    /// @dev The four edge-currency pots {BidDeployer.deployEdgeBid} draws on: generation 0's and
    /// generation 1's ancestor sleeves, link one's hop pot and the forfeited-bond earmark.
    function _edgePots() internal view returns (uint256) {
        return vault.edgeBidEarmark() + vault.reinforcementBalance(address(doll)) + vault.claimableEdge(0)
            + vault.claimableEdge(1);
    }

    /// @notice The edge sleeve can be empty and the hop pot non-empty (or the other way
    /// round) and the edge bid still deploys, drawing each pot partially.
    function test_edgeBidDeploysFromTheHopPotAloneAndDrawsPartially() public {
        _accrueAndSettle(1 ether);

        // drain the sleeve first, leaving only the hop pot and the earmark behind
        uint256 sleeve = vault.claimableEdge(0);
        assertGt(sleeve, 0);
        assertGt(vault.reinforcementBalance(address(doll)), 0, "the edge pool has hop fees");

        bidDeployer.deployEdgeBid(sleeve / 2);
        assertGt(vault.claimableEdge(0), 0, "only half the sleeve was drawn");

        uint256 hopLeft = vault.reinforcementBalance(address(doll));
        bidDeployer.deployEdgeBid(0); // sleeve untouched, hop pot alone
        assertLt(vault.reinforcementBalance(address(doll)), hopLeft + 1, "the hop pot funded a bid on its own");
        _assertSolvent();
    }

    /// @notice Cold start: a pool sitting exactly at the top tick of its curve has zero
    /// active liquidity, and must still be able to receive a bid.
    function test_coldPoolStillHasASizeCap() public {
        // link #3 has never traded through the whole first range; force the cold case by using
        // a pool whose current tick has no position in range
        uint256 cap = bidDeployer.bidCap(roundManager.headIndex());
        assertGt(cap, 0, "a cold pool reports a non-zero size cap from its curve's first range");
    }

    // ---------------------------------------------------------------------------------
    // gas
    // ---------------------------------------------------------------------------------

    function test_gas_deployAncestor() public {
        address keeper = address(0xBEEF);
        uint256 stock = _fundKeeper(keeper, 1, 3 ether);
        _accrueAndSettle(2 ether);
        uint256 amount = _deployableParent(2) / 2;
        if (amount > stock) amount = stock;
        vm.prank(keeper);
        uint256 g = gasleft();
        bidDeployer.deployAncestor(2, amount);
        emit log_named_uint("deployAncestor(j=1) gas", g - gasleft());
    }

    /// @notice What is left of the keeper path's cost is the TWAP chain, which is O(j)
    /// STATIC calls - no swap, no unlock and no liquidity walk per generation. The per-generation
    /// slope is measured on the REAL `dollPerTokenWad`; the j = 32 and j = 128 totals are measured
    /// on a loop making the identical external calls (a real 128-link chain cannot be built in a
    /// unit test, and link one's rate cannot simply be repeated 128 times without underflowing
    /// to zero, which the vault rightly refuses).
    function test_gas_deployAncestorConsultChain() public {
        _accrueAndSettle(1 ether);

        uint256 g = gasleft();
        bidDeployer.dollPerTokenWad(2);
        uint256 one = g - gasleft();
        g = gasleft();
        bidDeployer.dollPerTokenWad(3);
        uint256 two = g - gasleft();
        emit log_named_uint("dollPerTokenWad, 1 conversion hop", one);
        emit log_named_uint("dollPerTokenWad, 2 conversion hops", two);
        emit log_named_uint("per-generation slope (real)", two - one);

        uint256[3] memory js = [uint256(1), 32, 128];
        for (uint256 i = 0; i < js.length; i++) {
            g = gasleft();
            _consultChainCost(js[i]);
            emit log_named_uint(string.concat("band+consult chain, j = ", vm.toString(js[i])), g - gasleft());
        }

        // linear, not quadratic: the cost of the chain is a straight line in j
        assertLt(two - one, 2 * one, "each extra generation costs a constant, small amount");
    }

    /// @dev The O(j) part of a deployment: one `consult`, one `observationCount`, one `getSlot0`
    /// and one `poolInfo` per generation. Generations past the head reuse the head's pool, which
    /// is exactly the same work per step.
    function _consultChainCost(uint256 j) internal view {
        uint256 head = roundManager.headIndex();
        uint256 acc;
        // index 0 has no pool of ours: the walk starts at link one
        for (uint256 k = 1; k <= j; k++) {
            PoolId id = roundManager.poolIdOf(k > head ? head : k);
            (uint160 twap,) = hook.consult(id, bidDeployer.TWAP_WINDOW());
            (uint160 spot,,,) = im.getSlot0(id);
            acc += uint256(twap) + uint256(spot) + hook.observationCount(id)
            + (hook.poolInfo(id).parentIsCurrency0 ? 1 : 0);
        }
        assertGt(acc, 0);
    }

    function _lastBid(Vm.Log[] memory logs)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker) || logs[i].topics[0] != ILocker.BidDeposited.selector) continue;
            (, tickLower, tickUpper, liquidity) = abi.decode(logs[i].data, (uint256, int24, int24, uint128));
        }
    }
}
