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

/// @notice MECHANISM_v3 sec.1 (review 3) - THE PURSE IS NOT CONTESTABLE. A generation's share of
/// the ancestor sleeve is deployed, in full, as locked bid liquidity under the TRUNK coin that
/// won that round. There is no ranking, no board and no split, and a losing sibling never
/// receives purse liquidity however well it trades afterwards.
contract PurseTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    /// @dev Generation 1's siblings: `winner` won the round, `runnerUp` and `third` did not.
    Cand internal winner;
    Cand internal runnerUp;
    Cand internal third;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);

        // one round with three candidates: the first wins, and all three keep their pools
        winner = _runWinningRound(3, WINNING_BUY);
        runnerUp = cands[1];
        third = cands[2];
        assertEq(roundManager.canonical(1), winner.token, "the first candidate won");
        assertEq(roundManager.roundOfIndex(1), 1, "generation 1 was crowned by round 1");

        // a second generation, so that generation 1 earns a real ETH sleeve
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
        IERC20(roundManager.canonical(0)).approve(address(swapRouter), type(uint256).max);
    }

    /// @dev What this test contract can still spend of generation 1's parent token.
    function _affordable() internal view returns (uint256) {
        return IERC20(roundManager.canonical(0)).balanceOf(address(this));
    }

    /// @dev Let the clock run until the 30-minute TWAPs reflect whatever was just traded.
    function _settleOracles() internal {
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Trade the chain so generation 1's ETH sleeve fills, then let the oracles settle.
    function _accrue(uint256 ethIn) internal {
        familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn{value: ethIn / 10}(2, 0, address(this), 3);
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

    /// @dev Hand a keeper the parent tokens for a deployment of generation 1.
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
        PoolId trunkPool = roundManager.poolKeyOf(1).toId();

        vm.recordLogs();
        vm.expectEmit(true, true, false, false, address(bidDeployer));
        emit BidDeployer.PurseDeployed(1, winner.token, amount);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);
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
        bidDeployer.deployAncestor(1, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_bidsInto(logs, roundManager.poolKeyOf(1).toId()), 1, "the trunk took the whole purse");
        assertEq(_bidsInto(logs, runnerUp.poolId), 0, "the runner-up receives exactly zero");
        assertEq(_bidsInto(logs, third.poolId), 0, "and so does the third");
        // and the trunk is still the winner's, pairing rights included
        assertEq(roundManager.canonical(1), winner.token, "the winner still holds the index");
        assertEq(roundManager.indexOf(winner.token), 1, "and its pairing rights");
    }

    /// @notice Nothing a keeper can choose changes the destination: the only arguments are the
    /// generation and the amount, and the generation resolves to `canonical(j)`.
    function test_theDestinationIsNotAKeeperChoice() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(1, amount);
        (address trunk, uint256 deposited) = _purseDeployedFromLogs();

        assertEq(trunk, roundManager.canonical(1), "the destination is the canonical link, always");
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

    /// @notice Generation 0 has no parent to be bid in: it takes ETH directly, through
    /// {BidDeployer.deployGenesisBid}.
    function test_genesisIsNotAnAncestorDeployment() public {
        vm.expectRevert(BidDeployer.UnknownGeneration.selector);
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
        address parent = roundManager.canonical(0);
        uint256 keeperParentBefore = IERC20(parent).balanceOf(keeper);

        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);

        assertEq(IERC20(parent).balanceOf(keeper), keeperParentBefore - amount, "the keeper paid exactly `amount`");
        assertGe(deposited, amount, "and at least that much was locked");
        assertEq(IERC20(parent).balanceOf(address(bidDeployer)), 0, "nothing is stranded in the deployer");
        _assertSolvent();
    }

    /// @notice The bounty rule is unchanged: the keeper is paid the ETH value plus
    /// {BidDeployer.BOUNTY_BPS}, floored at {MIN_BOUNTY_WEI}, on top of the deployment.
    function test_theBountyRuleIsUnchanged() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        uint256 ethBefore = keeper.balance;

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(1, amount);

        (uint256 ethUsed, uint256 bounty) = _ancestorDeployedFromLogs();
        assertEq(keeper.balance - ethBefore, ethUsed, "the keeper was paid the whole payout in ETH");
        assertEq(bounty, _expectedBounty(ethUsed - bounty), "max(1%, MIN_BOUNTY_WEI), under its ceiling");
    }

    /// @notice The vault's daily drawdown bucket still bounds the purse: the deployment draws
    /// exactly its payout out of generation 1's allowance, and no more.
    function test_theDailyBucketStillBounds() public {
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);
        uint256 drawableBefore = vault.drawableEth(1);

        vm.recordLogs();
        vm.prank(keeper);
        bidDeployer.deployAncestor(1, amount);
        (uint256 ethUsed,) = _ancestorDeployedFromLogs();

        assertEq(drawableBefore - vault.drawableEth(1), ethUsed, "the bucket fell by exactly the payout");
        assertLe(ethUsed, drawableBefore, "and never by more than it held");
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

    function _ancestorDeployedFromLogs() internal returns (uint256 ethUsed, uint256 bounty) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer) || logs[i].topics[0] != BidDeployer.AncestorDeployed.selector) {
                continue;
            }
            (ethUsed,, bounty) = abi.decode(logs[i].data, (uint256, uint256, uint256));
        }
    }
}
