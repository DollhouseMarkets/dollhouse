// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {ILocker} from "../../contracts/interfaces/ILocker.sol";

/// @notice Property tests for the keeper path (docs/spec/PROPERTIES.md sec.3.8), tier F.
contract BidPropTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link1;
    address internal link2;
    address internal constant KEEPER = address(0xBEEF);

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        link2 = _runWinningRound(1, WINNING_BUY).token;
        _accrue(3 ether);
    }

    /// @notice BID-01: every deposit the BidDeployer makes lands in a Locker position that is
    /// single-sided on the parent side of spot, `BID_WIDTH_SPACINGS = 10` spacings wide, with
    /// `tickLower < tickUpper`; a range straddling spot is impossible.
    function testFuzz_BID01_bidsAreSingleSidedAndLocked(uint256 amountSeed) public {
        uint256 amount = _keeperStock(KEEPER, amountSeed);
        vm.assume(amount != 0);

        (, int24 spotTick,,) = im.getSlot0(roundManager.poolKeyOf(1).toId());
        bool parentIsCurrency0 = hook.poolInfo(roundManager.poolKeyOf(1).toId()).parentIsCurrency0;

        vm.recordLogs();
        vm.prank(KEEPER);
        bidDeployer.deployAncestor(1, amount);

        (bool found, int24 tickLower, int24 tickUpper, uint128 liquidity) = _lastBid();
        assertTrue(found, "the deposit really was locked in a Locker position");
        assertLt(tickLower, tickUpper, "a bid range is never empty or inverted");
        assertGt(liquidity, 0, "and it holds liquidity");
        assertEq(
            uint256(int256(tickUpper - tickLower)),
            uint256(int256(factory.TICK_SPACING() * 10)),
            "ten spacings wide"
        );
        if (parentIsCurrency0) {
            assertGt(tickLower, spotTick, "parent-side ranges sit strictly above spot");
        } else {
            assertLe(tickUpper, spotTick, "...or at and below it, never straddling");
        }
    }

    /// @notice BID-02: each conversion link is priced at the value-minimum of spot, the 1800 s
    /// average and the 7-day average, so no price movement can RAISE what a sleeve pays.
    function testFuzz_BID02_theConversionNeverPaysAboveSpot(uint256 amountSeed) public view {
        uint256 amount = bound(amountSeed, 1e15, 10_000_000e18);
        (uint256 ethValue,) = bidDeployer.ethValueOfParent(0, amount);

        (uint160 spot,,,) = im.getSlot0(poolId);
        uint256 atSpot = FullMath.mulDiv(FullMath.mulDiv(amount, FixedPoint96.Q96, spot), FixedPoint96.Q96, spot);
        assertLe(ethValue, atSpot, "a conversion is never worth more than the current market says");
    }

    /// @notice BID-02: the conversion is linear in the amount, so no keeper can improve its own
    /// price by splitting or by bundling a deployment.
    function testFuzz_BID02_theConversionIsLinearInTheAmount(uint256 amountSeed, uint256 splitSeed) public view {
        uint256 amount = bound(amountSeed, 1e18, 1_000_000e18);
        // both halves must be worth at least a wei of ETH: a parcel whose value floors to zero
        // is refused outright (`BadConversionRate`), which is the documented deep-chain guard
        uint256 part = bound(splitSeed, amount / 4, (amount * 3) / 4);
        (uint256 whole,) = bidDeployer.ethValueOfParent(0, amount);
        (uint256 first,) = bidDeployer.ethValueOfParent(0, part);
        (uint256 second,) = bidDeployer.ethValueOfParent(0, amount - part);
        assertGe(whole, first + second, "splitting a parcel never pays more");
        assertApproxEqAbs(whole, first + second, 4, "and the conversion is linear to the wei");
    }

    /// @notice BID-06: `bounty = min(max(ethValue*100/10000, MIN_BOUNTY_WEI),
    /// ethValue*2000/8000)`, so the bounty is never more than 20% of
    /// `payout = ethValue + bounty`.
    function testFuzz_BID06_theBountyIsTheStatedShape(uint256 amountSeed) public {
        uint256 amount = _keeperStock(KEEPER, amountSeed);
        vm.assume(amount != 0);
        (uint256 ethValue,) = bidDeployer.ethValueOfParent(0, amount);

        uint256 expected = (ethValue * bidDeployer.BOUNTY_BPS()) / 10_000;
        if (expected < bidDeployer.MIN_BOUNTY_WEI()) expected = bidDeployer.MIN_BOUNTY_WEI();
        uint256 ceiling = (ethValue * bidDeployer.MAX_BOUNTY_SHARE_BPS())
            / (10_000 - bidDeployer.MAX_BOUNTY_SHARE_BPS());
        if (expected > ceiling) expected = ceiling;

        uint256 before = KEEPER.balance;
        vm.prank(KEEPER);
        bidDeployer.deployAncestor(1, amount);
        // the keeper is paid the ETH value of the parcel it sold PLUS the bounty
        uint256 paid = KEEPER.balance - before;
        assertEq(paid, ethValue + expected, "the keeper is paid the value plus the bounty");
        uint256 bounty = paid - ethValue;

        assertEq(bounty, expected, "the published bounty shape");
        uint256 payout = ethValue + bounty;
        assertLe(bounty * 5, payout, "never more than 20% of what the call consumes");
        if (expected == (ethValue * bidDeployer.BOUNTY_BPS()) / 10_000) {
            assertEq(bounty, ethValue / 100, "1% wherever neither bound binds");
        }
    }

    /// @notice BID-07: a draw of `payout` from generation `j` succeeds only if
    /// `payout <= drawableEth(j)`, a continuously refilling bucket with cap `10% * claimableEth`
    /// and refill `10% * claimableEth * dt / 24 h`; there is no instant at which two draws
    /// together exceed the cap.
    function testFuzz_BID07_theDrawdownBucketBindsAndRefills(uint256 gap) public {
        uint256 cap = (vault.claimableEth(1) * vault.DAILY_DRAW_BPS()) / 10_000;
        assertGt(cap, 0, "generation 1 has a sleeve to draw on");
        assertLe(vault.drawableEth(1), cap, "the bucket never holds more than its cap");

        // the largest deployment the bucket can pay for right now, taken in full
        uint256 amount = _keeperStock(KEEPER, type(uint256).max);
        vm.assume(amount != 0);
        uint256 drawableBefore = vault.drawableEth(1);
        vm.prank(KEEPER);
        bidDeployer.deployAncestor(1, amount);

        uint256 left = vault.drawableEth(1);
        assertLt(left, drawableBefore, "the draw really came out of the bucket");

        // a second draw in the same instant cannot exceed what is left
        uint256 tooMuch = bidDeployer.maxParentForDeploy(1) * 4 + 1e18;
        IERC20(roundManager.canonical(0)).transfer(KEEPER, _spare(tooMuch));
        vm.prank(KEEPER);
        vm.expectRevert();
        bidDeployer.deployAncestor(1, tooMuch);

        // and it refills continuously, never above the cap
        uint256 dt = bound(gap, 1, 3 days);
        vm.warp(vm.getBlockTimestamp() + dt);
        uint256 capNow = (vault.claimableEth(1) * vault.DAILY_DRAW_BPS()) / 10_000;
        assertLe(vault.drawableEth(1), capNow, "the refill never overfills the bucket");
        if (dt >= 1 days) assertGe(vault.drawableEth(1) + 1, capNow, "a whole day refills it completely");
        else assertGt(vault.drawableEth(1), left, "and time alone puts some back");
    }

    /// @notice BID-10: `maxParentForDeploy(j)` returns a quote `deployAncestor` accepts.
    function testFuzz_BID10_theQuoteIsAcceptedAsIs(uint256 shareSeed) public {
        uint256 quote = bidDeployer.maxParentForDeploy(1);
        assertGt(quote, 0, "the view quotes a real size");
        uint256 cap = bidDeployer.bidCap(1);
        uint256 amount = quote < cap ? quote : cap;
        amount = bound(shareSeed, amount / 2 + 1, amount);

        address parent = roundManager.canonical(0);
        IERC20(parent).transfer(KEEPER, amount);
        vm.prank(KEEPER);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);

        vm.prank(KEEPER);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);
        assertGe(deposited, amount, "the quoted size is deployable as quoted");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _accrue(uint256 ethIn) internal {
        familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        vm.warp(vm.getBlockTimestamp() + 200);
        familyRouter.buyExactIn{value: ethIn / 10}(2, 0, address(this), 3);
        vm.warp(vm.getBlockTimestamp() + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Fund `keeper` with a deployable parcel of generation 1's parent token, bounded by
    /// the size cap, the sleeve and this contract's own holdings.
    function _keeperStock(address keeper, uint256 seed) internal returns (uint256 amount) {
        uint256 cap = bidDeployer.bidCap(1);
        uint256 affordable = bidDeployer.maxParentForDeploy(1);
        amount = cap < affordable ? cap : affordable;
        address parent = roundManager.canonical(0);
        uint256 held = IERC20(parent).balanceOf(address(this));
        if (amount > held) amount = held;
        if (amount == 0) return 0;
        if (seed != type(uint256).max) amount = bound(seed, amount / 4 + 1, amount);
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);
    }

    function _spare(uint256 wanted) internal view returns (uint256) {
        uint256 held = IERC20(roundManager.canonical(0)).balanceOf(address(this));
        return wanted < held ? wanted : held;
    }

    /// @dev The last `BidDeposited` the Locker emitted in the recorded logs.
    function _lastBid() internal returns (bool found, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker) || logs[i].topics[0] != ILocker.BidDeposited.selector) continue;
            (, tickLower, tickUpper, liquidity) = abi.decode(logs[i].data, (uint256, int24, int24, uint128));
            found = true;
        }
    }
}
