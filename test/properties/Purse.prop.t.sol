// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {ILocker} from "../../contracts/interfaces/ILocker.sol";

/// @notice Property tests for the purse (docs/spec/PROPERTIES.md sec.3.7), tier F. Review 3: the
/// purse is no longer contestable, so the properties are about the DESTINATION being fixed and
/// the amount conserving, not about a split.
contract PursePropTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    Cand internal winner;
    Cand internal runnerUp;
    Cand internal third;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);

        winner = _runWinningRound(3, WINNING_BUY);
        runnerUp = cands[1];
        third = cands[2];
        _runWinningRound(1, WINNING_BUY);
        _accrue(3 ether);
        _warm(runnerUp);
        _warm(third);
        vm.warp(vm.getBlockTimestamp() + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @notice PUR-02: the destination of a deployment is `canonical(j)` and nothing else, for
    /// every amount and whatever support the losing siblings have built since the round.
    function testFuzz_PUR02_theDestinationIsAlwaysTheTrunk(uint256 amountSeed, uint256 supportSeed) public {
        // give the losing siblings real, arbitrary support levels first
        _support(runnerUp, bound(supportSeed, 1, 8), 100);
        _support(third, bound(supportSeed / 3 + 1, 1, 8), 100);

        address keeper = address(0xBEEF);
        uint256 stock = _keeperStock(keeper);
        uint256 amount = bound(amountSeed, stock / 4 + 1, stock);

        PoolId trunkPool = roundManager.poolKeyOf(1).toId();

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(1, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (address trunk, uint256 deposited) = _purseDeployedIn(logs);
        assertEq(trunk, roundManager.canonical(1), "the purse went to the trunk link");
        assertEq(trunk, winner.token, "which is the coin that won the round");
        assertGe(deposited, amount, "in full");
        assertEq(_bidsInto(logs, trunkPool), 1, "one bid, into the trunk pool");
        assertEq(_bidsInto(logs, runnerUp.poolId), 0, "a loser receives exactly zero");
        assertEq(_bidsInto(logs, third.poolId), 0, "every loser receives exactly zero");
    }

    /// @notice PUR-04: the amount CONSERVES. Exactly `amount` leaves the keeper, at least that
    /// much is locked (the difference is the generation's own hop pot topping the bid up), and
    /// nothing is stranded in the deployer.
    function testFuzz_PUR04_theAmountConserves(uint256 amountSeed) public {
        address keeper = address(0xBEEF);
        uint256 stock = _keeperStock(keeper);
        uint256 amount = bound(amountSeed, stock / 4 + 1, stock);
        address parent = roundManager.canonical(0);
        uint256 keeperBefore = IERC20(parent).balanceOf(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);
        (, uint256 logged) = _purseDeployedIn(vm.getRecordedLogs());

        assertEq(keeperBefore - IERC20(parent).balanceOf(keeper), amount, "exactly `amount` left the keeper");
        assertEq(logged, deposited, "the event reports what was locked");
        assertGe(deposited, amount, "and nothing of it was withheld");
        assertEq(IERC20(parent).balanceOf(address(bidDeployer)), 0, "nothing stranded in the deployer");
        _assertSolvent();
    }

    /// @notice PUR-05: the daily bucket and the bounty rule are untouched by the change. The
    /// vault's ETH allowance for generation 1 falls by exactly the payout, and the payout is the
    /// ETH value plus `max(1%, MIN_BOUNTY_WEI)`.
    function testFuzz_PUR05_theBucketAndBountyAreUnchanged(uint256 amountSeed) public {
        address keeper = address(0xBEEF);
        uint256 stock = _keeperStock(keeper);
        uint256 amount = bound(amountSeed, stock / 4 + 1, stock);
        uint256 drawableBefore = vault.drawableEth(1);
        uint256 ethBefore = keeper.balance;

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(1, amount);
        (uint256 ethUsed, uint256 bounty) = _ancestorDeployedFromLogs();

        assertEq(keeper.balance - ethBefore, ethUsed, "the keeper was paid the whole payout");
        assertEq(drawableBefore - vault.drawableEth(1), ethUsed, "the bucket fell by exactly the payout");
        assertEq(bounty, _expectedBounty(ethUsed - bounty), "max(1%, MIN_BOUNTY_WEI), under its ceiling");
        assertLe(bounty * 10_000, ethUsed * bidDeployer.MAX_BOUNTY_SHARE_BPS(), "the ceiling is a share of the call");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _purseDeployedIn(Vm.Log[] memory logs) internal view returns (address trunk, uint256 deposited) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer) || logs[i].topics[0] != BidDeployer.PurseDeployed.selector) {
                continue;
            }
            trunk = address(uint160(uint256(logs[i].topics[2])));
            deposited = abi.decode(logs[i].data, (uint256));
        }
    }

    function _ancestorDeployedFromLogs() internal returns (uint256 ethUsed, uint256 bounty) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer) || logs[i].topics[0] != BidDeployer.AncestorDeployed.selector) {
                continue;
            }
            (ethUsed,, bounty) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
    }

    /// @dev How many bids the Locker deposited into `id`. A bid sits BELOW spot, so the pool's
    /// active liquidity does not move: the deposit event is the witness.
    function _bidsInto(Vm.Log[] memory logs, PoolId id) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker)) continue;
            if (logs[i].topics[0] != ILocker.BidDeposited.selector) continue;
            if (logs[i].topics[1] == PoolId.unwrap(id)) n++;
        }
    }

    function _warm(Cand memory c) internal {
        _approveParent();
        uint256 unit = _affordable() / 200;
        _tradeCandidate(c, true, unit);
        vm.warp(vm.getBlockTimestamp() + 200);
        _tradeCandidate(c, true, unit);
    }

    function _approveParent() internal {
        IERC20(roundManager.canonical(0)).approve(address(swapRouter), type(uint256).max);
    }

    function _affordable() internal view returns (uint256) {
        return IERC20(roundManager.canonical(0)).balanceOf(address(this));
    }

    function _support(Cand memory c, uint256 numerator, uint256 denominator) internal {
        _approveParent();
        _tradeCandidate(c, true, (_affordable() * numerator) / denominator);
        vm.warp(vm.getBlockTimestamp() + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    function _accrue(uint256 ethIn) internal {
        familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        vm.warp(vm.getBlockTimestamp() + 200);
        familyRouter.buyExactIn{value: ethIn / 10}(2, 0, address(this), 3);
        vm.warp(vm.getBlockTimestamp() + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    function _keeperStock(address keeper) internal returns (uint256 amount) {
        uint256 cap = bidDeployer.bidCap(1);
        uint256 affordable = bidDeployer.maxParentForDeploy(1);
        amount = cap < affordable ? cap : affordable;
        address parent = roundManager.canonical(0);
        uint256 held = IERC20(parent).balanceOf(address(this));
        if (amount > held) amount = held;
        IERC20(parent).transfer(keeper, amount);
        vm.prank(keeper);
        IERC20(parent).approve(address(bidDeployer), type(uint256).max);
    }
}
