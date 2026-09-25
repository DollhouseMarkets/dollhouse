// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";
import {ILocker} from "../contracts/interfaces/ILocker.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";

/// @notice The bid path: the Locker never settles more than it was given, the bid range
/// never collapses against the tick bounds, and a cold pool can still be sized and
/// supported.
contract BidTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpEdge();
    }


    // ---------------------------------------------------------------------------------
    // The Locker owes at most what it was handed
    // ---------------------------------------------------------------------------------

    /// @dev Deposit `amount` of the EDGE CURRENCY as a currency0-only bid above `spot` and return
    /// what the PoolManager actually took. $DOLL is `currency0` of every link-one pool.
    function _bidDoll(uint256 amount, int24 lower, int24 upper) internal returns (uint256 settled) {
        _fundDoll(address(locker), amount);
        uint256 before = doll.balanceOf(address(manager));
        vm.prank(address(bidDeployer));
        locker.depositBid(key, amount, lower, upper);
        settled = doll.balanceOf(address(manager)) - before;
    }

    /// @dev The same, for a currency1-only (family token) bid below spot.
    function _bidToken(uint256 amount, int24 lower, int24 upper) internal returns (uint256 settled) {
        IERC20(address(token)).transfer(address(locker), amount);
        uint256 before = IERC20(address(token)).balanceOf(address(manager));
        vm.prank(address(bidDeployer));
        locker.depositBid(key, amount, lower, upper);
        settled = IERC20(address(token)).balanceOf(address(manager)) - before;
    }

    /// @notice Fuzz the currency0 branch: whatever the range and the amount, the Locker never
    /// settles more than the FeeVault handed it.
    function testFuzz_bidNeverOwesMoreThanItWasGiven_currency0(uint256 amount, uint16 offset, uint8 widthSpacings)
        public
    {
        _buyLink(1, 2 ether);
        amount = bound(amount, 1e6, 100 ether);
        int24 spacing = factory.TICK_SPACING();
        (, int24 tick,,) = im.getSlot0(poolId);
        int24 lower = CurveMath.floorToSpacing(tick, spacing) + spacing * (1 + int24(uint24(offset % 500)));
        int24 upper = lower + spacing * int24(uint24(bound(widthSpacings, 1, 50)));
        vm.assume(upper < TickMath.MAX_TICK);

        uint256 settled = _bidDoll(amount, lower, upper);
        assertLe(settled, amount, "the Locker never settles more than it holds");
        assertGt(settled, 0, "and it really did place the bid");
    }

    /// @notice Fuzz the currency1 branch (the mirrored orientation's arithmetic).
    function testFuzz_bidNeverOwesMoreThanItWasGiven_currency1(uint256 amount, uint16 offset, uint8 widthSpacings)
        public
    {
        _buyLink(1, 50 ether);
        amount = bound(amount, 1e12, IERC20(address(token)).balanceOf(address(this)) / 2);
        int24 spacing = factory.TICK_SPACING();
        (, int24 tick,,) = im.getSlot0(poolId);
        int24 upper = CurveMath.floorToSpacing(tick, spacing) - spacing * int24(uint24(offset % 500));
        int24 lower = upper - spacing * int24(uint24(bound(widthSpacings, 1, 50)));
        vm.assume(lower > TickMath.MIN_TICK);

        uint256 settled = _bidToken(amount, lower, upper);
        assertLe(settled, amount, "the Locker never settles more than it holds");
        assertGt(settled, 0, "and it really did place the bid");
    }

    /// @notice A one-wei-off amount (the rounding case L2 is about) is still accepted and still
    /// settles within budget.
    function test_bidAbsorbsTheRoundingWei() public {
        _buyLink(1, 2 ether);
        int24 spacing = factory.TICK_SPACING();
        (, int24 tick,,) = im.getSlot0(poolId);
        int24 lower = CurveMath.floorToSpacing(tick, spacing) + spacing;
        for (uint256 i = 0; i < 24; i++) {
            uint256 amount = 1e6 + i;
            uint256 settled = _bidDoll(amount, lower, lower + spacing);
            assertLe(settled, amount, "never over budget, for any amount");
        }
    }

    // ---------------------------------------------------------------------------------
    // The bid range never collapses
    // ---------------------------------------------------------------------------------

    /// @notice Even at the extreme end of the tick space the clamped bid keeps
    /// `tickLower < tickUpper`; the Locker refuses anything that does not.
    function test_bidRangeAlwaysHasWidth() public {
        int24 spacing = factory.TICK_SPACING();
        int24 maxTick = CurveMath.floorToSpacing(TickMath.MAX_TICK, spacing);
        int24 minTick = CurveMath.floorToSpacing(TickMath.MIN_TICK, spacing) + spacing;
        assertLt(maxTick - spacing, maxTick, "the clamped upper branch keeps width");
        assertLt(minTick, minTick + spacing, "the clamped lower branch keeps width");

        // and a zero-width or inverted range is refused at the Locker
        vm.prank(address(bidDeployer));
        vm.expectRevert(ILocker.BidStraddlesSpot.selector);
        locker.depositBid(key, 1 ether, 600, 600);

        vm.prank(address(bidDeployer));
        vm.expectRevert(ILocker.BidStraddlesSpot.selector);
        locker.depositBid(key, 1 ether, 600, 540);
    }

    // ---------------------------------------------------------------------------------
    // The size cap of a cold pool
    // ---------------------------------------------------------------------------------

    /// @notice The cap is sized against the whole FIRST CURVE RANGE (the parent a buyer would
    /// have to bring to walk through it from the current price), not against the 60-tick bucket
    /// the price happens to sit in. The bucket is 3 orders of magnitude smaller, which made the
    /// keeper bounty far smaller than the gas of the call and left both keeper paths unused.
    ///
    /// @dev A pool sitting at the top of its curve is no longer an UN-TRADED canonical
    /// pool - a link is crowned by a round it had to absorb its way through, and the threshold `H`
    /// is larger than the whole first range - so the shape is rebuilt by selling the position
    /// back. The genuinely liquidity-free case is exercised by
    /// {test_coldPoolAcceptsALockedBid} against a candidate pool that has never traded.
    function test_theCapIsSizedFromTheFirstCurveRangeNotTheBucket() public {
        _rewindEdgePool();
        uint256 cap = bidDeployer.bidCap(1);
        assertGt(cap, 0, "A pool at the top of its curve is sized from that curve's first range");

        (uint160 sqrtP, int24 tick,,) = im.getSlot0(poolId);
        int24 spacing = factory.TICK_SPACING();
        int24 activeUpper = CurveMath.floorToSpacing(tick, spacing) + spacing;
        uint256 bucket =
            SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(activeUpper), ranges[0].liquidity, false);
        uint160 rangeLower = TickMath.getSqrtPriceAtTick(ranges[0].tickLower);
        uint256 firstRange = SqrtPriceMath.getAmount0Delta(rangeLower, sqrtP, ranges[0].liquidity, false);

        assertEq(cap, (firstRange * bidDeployer.MAX_RESERVE_BPS()) / 10_000, "sized off the whole first range");
        assertGt(cap, (bucket * bidDeployer.MAX_RESERVE_BPS()) / 10_000, "and that is strictly more than the bucket");
        _assertNoEth();
    }

    /// @notice The bounty an edge-bid keeper earns on a realistic pool
    /// must be worth the gas of the call. Measured against the deploy-target 0.01 gwei of the
    /// Orbit chain, with a 3x margin.
    function test_edgeBidBountyBeatsTheGasOfTheCall() public {
        // a real-sized pool: genuine volume (the fees are what the bid is made of), a failed
        // round's forfeited bond, and only THEN a warm oracle, so that spot and the 30-minute
        // average agree when the keeper calls
        _buyLink(1, 5 ether);
        _registerCandidate(address(0xF00D), "FAIL");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 4; i++) {
            _buyLink(1, 5 ether);
            t += 300;
            vm.warp(t);
        }
        _warmOracles();

        address keeper = address(0xC0FFEE);
        uint256 before = doll.balanceOf(keeper);
        uint256 g = gasleft();
        vm.prank(keeper);
        bidDeployer.deployEdgeBid();
        uint256 gasUsed = g - gasleft();
        uint256 bounty = doll.balanceOf(keeper) - before;

        uint256 gasCost = gasUsed * 0.01 gwei;
        emit log_named_uint("deployEdgeBid gas", gasUsed);
        emit log_named_uint("bounty, wei", bounty);
        emit log_named_uint("gas cost at 0.01 gwei, wei", gasCost);
        assertGt(bounty, 3 * gasCost, "the bounty must be worth the gas of the call");
        assertGt(bounty, 1e13, "and a non-dust amount in absolute terms");
    }

    /// @notice A pool that has NEVER traded sits exactly at the top tick of its curve, so it
    /// has zero active liquidity, and the Locker must still accept a parent-side bid into it.
    /// The only un-traded pool in the protocol is a freshly registered CANDIDATE.
    function test_coldPoolAcceptsALockedBid() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "COLD");
        assertEq(im.getLiquidity(c.poolId), 0, "cold: no position is in range at the top of the curve");

        int24 spacing = factory.TICK_SPACING();
        (, int24 tick,,) = im.getSlot0(c.poolId);
        // the PARENT side of the candidate pool: above spot when the parent sorts first, below it
        // when the candidate token does
        int24 lower;
        int24 upper;
        if (c.tokenIsCurrency0) {
            upper = CurveMath.floorToSpacing(tick, spacing);
            lower = upper - spacing * 10;
        } else {
            lower = CurveMath.floorToSpacing(tick, spacing) + spacing;
            upper = lower + spacing * 10;
        }

        uint256 amount = 1_000e18;
        IERC20(address(token)).transfer(address(locker), amount);
        vm.prank(address(bidDeployer));
        uint128 liquidity = locker.depositBid(c.key, amount, lower, upper);
        assertGt(liquidity, 0, "a cold pool can receive a locked bid");
        (uint128 posLiquidity,,) = im.getPositionInfo(c.poolId, address(locker), lower, upper, bytes32(0));
        assertEq(posLiquidity, liquidity, "and the position belongs to the Locker, forever");
        _assertNoEth();
    }

    /// @notice The active-range reserve is far smaller than the naive whole-range virtual reserve
    /// `L / sqrtP`, which is exactly the over-statement the active-range sizing avoids.
    function test_activeRangeReserveIsMuchSmallerThanTheVirtualReserve() public {
        _buyLink(1, 5 ether);
        uint128 L = im.getLiquidity(poolId);
        (uint160 sqrtP, int24 tick,,) = im.getSlot0(poolId);
        assertGt(L, 0, "warm");

        uint256 virtualReserve = (uint256(L) << 96) / sqrtP;
        int24 spacing = factory.TICK_SPACING();
        int24 activeUpper = CurveMath.floorToSpacing(tick, spacing) + spacing;
        uint256 active = SqrtPriceMath.getAmount0Delta(sqrtP, TickMath.getSqrtPriceAtTick(activeUpper), L, false);

        assertLt(active, virtualReserve, "the active bucket holds far less than the virtual reserve");
        // the cap is the LARGER of the active bucket and what is left of the first curve range
        // After this buy the price has walked out of range 0, so the bucket is the binding
        // basis and the cap is exactly 2% of the real amount
        assertEq(
            bidDeployer.bidCap(1), (active * bidDeployer.MAX_RESERVE_BPS()) / 10_000, "the cap uses the real amount"
        );
    }
}
