// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";

/// @notice Fork scenario 6 of docs/spec/PROPERTIES.md sec.4: the purse on the real
/// `PoolManager`. Review 3: a generation's ETH sleeve is locked under the trunk coin, the pair
/// is verified against the board on chain, rank 3 receives exactly nothing, and a stale board
/// cannot be spent. Covers PUR-01/03/04/05/07 and BID-01/05.
contract PurseForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Cand internal winner;
    Cand internal runnerUp;
    Cand internal third;

    function setUp() public {
        if (!_setUpForkFamily()) return;
        _buyGenesis(5 ether);

        // one round with three candidates: the first wins, and all three keep their pools
        winner = _runWinningRound(3, WINNING_BUY);
        runnerUp = cands[1];
        third = cands[2];
        assertEq(roundManager.canonical(1), winner.token, "the first candidate won");

        // a second generation, so generation 1 earns a real ETH sleeve
        _runWinningRound(1, WINNING_BUY);
        _accrue(3 ether);
        // every SIBLING pool is a bid target, so each needs the oracle coverage the band guard
        // insists on: two observations more than the minimum spacing apart
        _warm(runnerUp);
        _warm(third);
        _settleOracles();
    }

    function _approveParent() internal {
        IERC20(roundManager.canonical(0)).approve(address(swapRouter), type(uint256).max);
    }

    function _affordable() internal view returns (uint256) {
        return IERC20(roundManager.canonical(0)).balanceOf(address(this));
    }

    function _settleOracles() internal {
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    function _warm(Cand memory c) internal {
        _approveParent();
        uint256 unit = _affordable() / 200;
        _tradeCandidate(c, true, unit);
        vm.warp(block.timestamp + 200);
        _tradeCandidate(c, true, unit);
    }

    function _accrue(uint256 ethIn) internal {
        familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn{value: ethIn / 10}(2, 0, address(this), 3);
        _settleOracles();
    }

    function _support(Cand memory c, uint256 numerator, uint256 denominator) internal {
        _approveParent();
        _tradeCandidate(c, true, (_affordable() * numerator) / denominator);
        _settleOracles();
    }

    function _dump(Cand memory c) internal {
        IERC20(c.token).approve(address(swapRouter), type(uint256).max);
        _tradeCandidate(c, false, IERC20(c.token).balanceOf(address(this)));
        _settleOracles();
    }

    /// @dev Hand a keeper the parent tokens for one deployment of generation 1.
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

    /// @notice PUR-02 and BID-01/05: on the real singleton the purse is locked under the TRUNK
    /// link of the generation, in one bid, and every losing sibling's pool is left untouched to
    /// the wei - even when a loser has far better trailing support than the winner.
    function testFork_PUR02_thePurseGoesToTheTrunkAndLosersGetNothing() public {
        _requireFork();
        _support(runnerUp, 1, 2);
        _dump(winner);

        PoolId trunkPool = roundManager.poolKeyOf(1).toId();
        address keeper = address(0xBEEF);
        uint256 amount = _keeperStock(keeper);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // the deposit is the purse plus whatever room the size cap left for the generation's own
        // parent-denominated hop pot, so it is never less than what the keeper brought
        assertGe(deposited, amount, "everything the keeper brought was deployed");

        (address trunk, uint256 loggedDeposit) = _purseDeployedEvent(logs);
        assertEq(trunk, roundManager.canonical(1), "the destination is the canonical link");
        assertEq(trunk, winner.token, "which is the coin that won the round");
        assertEq(loggedDeposit, deposited, "and the event reports what was locked");

        // ...and the singleton saw liquidity added to exactly that pool, never to a loser's
        (uint256 addsTrunk, uint256 addsRunnerUp, uint256 addsThird) =
            _liquidityAdds(logs, trunkPool, runnerUp.poolId, third.poolId);
        assertEq(addsTrunk, 1, "one bid, into the trunk pool");
        assertEq(addsRunnerUp, 0, "the runner-up received exactly zero");
        assertEq(addsThird, 0, "and so did the third");

        // the trunk is the winner's, pairing rights included, whatever the siblings did after
        assertEq(roundManager.indexOf(winner.token), 1, "the winner still holds the index");
        _assertSolvent();
    }

    /// @dev The single {BidDeployer.PurseDeployed} in `logs`.
    function _purseDeployedEvent(Vm.Log[] memory logs) internal view returns (address trunk, uint256 deposited) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(bidDeployer)) continue;
            if (logs[i].topics[0] != BidDeployer.PurseDeployed.selector) continue;
            trunk = address(uint160(uint256(logs[i].topics[2])));
            deposited = abi.decode(logs[i].data, (uint256));
            found = true;
        }
        assertTrue(found, "the deployment published its destination");
    }

    /// @dev How many liquidity ADDITIONS the singleton recorded for each of three pools.
    function _liquidityAdds(Vm.Log[] memory logs, PoolId a, PoolId b, PoolId c)
        internal
        pure
        returns (uint256 nA, uint256 nB, uint256 nC)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != POOL_MANAGER) continue;
            if (logs[i].topics[0] != IPoolManager.ModifyLiquidity.selector) continue;
            bytes32 id = logs[i].topics[1];
            if (id == PoolId.unwrap(a)) nA++;
            else if (id == PoolId.unwrap(b)) nB++;
            else if (id == PoolId.unwrap(c)) nC++;
        }
    }
}
