// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";
import {StandardCurve} from "../contracts/libraries/StandardCurve.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {ILocker} from "../contracts/interfaces/ILocker.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";

/// @notice The MIRRORED orientation: a candidate whose token address sorts BELOW its parent, so
/// the candidate is `currency0` and the parent is `currency1`. This flips every frame in the
/// system - `CurveMath`'s mirrored branch, `StandardCurve.build`'s opening price, and
/// `FeeVault._bidTicks`' else-branch - and is reachable in production roughly half the time.
///
/// The candidate's address comes from the factory's own CREATE nonce, so the test simply keeps
/// registering candidates in one round until one of them lands below the parent.
contract MirroredTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
    }

    /// @dev Launch a candidate that sorts BELOW its parent. The token is the factory's next
    /// CREATE (an EIP-1167 clone), so the orientation is a pure function of the factory's nonce:
    /// search for the first nonce that lands below the parent and fast-forward the factory to
    /// it. Registering candidates until one happened to sort that way made this test's success
    /// depend on where the genesis token landed - with a low genesis address, most of the
    /// address space is ABOVE it and a fixed number of tries is a coin flip.
    function _mirroredCandidate() internal returns (Cand memory mirrored) {
        address parent = roundManager.head();
        uint64 nonce = vm.getNonce(address(factory));
        for (uint64 i = nonce; i < nonce + 4096; i++) {
            if (vm.computeCreateAddress(address(factory), i) < parent) {
                vm.setNonce(address(factory), i);
                mirrored = _registerCandidate(address(0xB1B100), "MIRROR");
                assertTrue(mirrored.token < parent, "the searched nonce really is mirrored");
                return mirrored;
            }
        }
        revert("no mirrored nonce found in 4096 tries");
    }

    function test_mirroredCandidateLaunchesUpsideDown() public {
        Cand memory m = _mirroredCandidate();
        address parent = roundManager.head();
        assertTrue(m.tokenIsCurrency0, "the candidate really is currency0");
        assertEq(Currency.unwrap(m.key.currency1), parent, "the parent is currency1");

        // the hook knows which side is the parent, and it is NOT currency0 here
        IFamilyHook.RegisteredPool memory p = hook.poolInfo(m.poolId);
        assertFalse(p.parentIsCurrency0, "mirrored: the parent is currency1");

        // CurveMath's mirrored branch: higher FDV is a HIGHER tick, so the curve sits ABOVE spot
        (CurveRange[] memory rs, uint160 initSqrt) = StandardCurve.build(
            factory.curveSpec(), IERC20(parent).totalSupply(), FamilyToken(m.token).TOTAL_SUPPLY(), 60, true
        );
        (uint160 spot, int24 tick,,) = im.getSlot0(m.poolId);
        assertEq(spot, initSqrt, "opened at the mirrored price");
        assertEq(spot, TickMath.getSqrtPriceAtTick(rs[0].tickLower) - 1, "one wei below the first range");
        for (uint256 i = 0; i < rs.length; i++) {
            assertLt(rs[i].tickLower, rs[i].tickUpper, "non-empty range");
            assertGe(rs[i].tickLower, tick, "token-only inventory sits ABOVE spot in the mirrored frame");
            if (i > 0) assertEq(rs[i].tickLower, rs[i - 1].tickUpper, "contiguous, ascending");
        }

        // and the whole supply really is in the pool, single-sided
        assertEq(IERC20(m.token).balanceOf(address(manager)), IERC20(m.token).totalSupply(), "all supply locked");
        assertEq(IERC20(parent).balanceOf(address(manager)) > 0, true, "the parent side holds the genesis pool's own");
    }

    /// @notice A mirrored candidate trades, scores and can win exactly like any other, and its
    /// score is still the net parent that stayed in the pool.
    function test_mirroredCandidateTradesAndWins() public {
        Cand memory m = _mirroredCandidate();
        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 5);
        uint256 out = _tradeCandidate(m, true, WINNING_BUY);
        assertGt(out, 0, "bought the mirrored candidate with parent tokens");

        int128 r = hook.poolInfo(m.poolId).R;
        uint256 fee = (WINNING_BUY * hook.hopFeePpm()) / PPM;
        assertEq(uint256(uint128(r)), WINNING_BUY - fee, "score = net parent absorbed, mirrored frame too");

        _settleEnd();
        roundManager.submitScore(m.id);
        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(roundManager.head(), m.token, "a mirrored candidate can be crowned");
        assertEq(roundManager.canonical(1), m.token);
    }

    /// @notice `FeeVault._bidTicks` else-branch: with the parent as currency1 the bid sits BELOW
    /// the current tick, and the whole keeper path works end to end on a mirrored link.
    function test_keeperBidOnAMirroredLinkUsesTheElseBranch() public {
        Cand memory m = _mirroredCandidate();
        address parent0 = roundManager.head();
        IERC20(parent0).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 5);
        _tradeCandidate(m, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(m.id);
        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(roundManager.headIndex(), 1, "the mirrored link is canonical #1");

        // generation 1 only earns a sleeve when it is an ANCESTOR, so crown one more link
        _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.headIndex(), 2);

        // accrue fees for generation 1 and let every oracle on the route cover the window
        familyRouter.buyExactIn{value: 2 ether}(2, 0, address(this), 3);
        vm.warp(block.timestamp + 300);
        familyRouter.buyExactIn{value: 0.2 ether}(2, 0, address(this), 3);
        vm.warp(block.timestamp + 7 days);
        assertGt(vault.claimableEth(1), 0, "generation 1 has an ETH sleeve");

        address keeper = address(0xBEEF);
        uint256 stock = IERC20(address(token)).balanceOf(address(this)) / 4;
        IERC20(address(token)).transfer(keeper, stock);
        vm.prank(keeper);
        IERC20(address(token)).approve(address(bidDeployer), type(uint256).max);

        uint256 cap = bidDeployer.bidCap(1);
        uint256 affordable = bidDeployer.maxParentForDeploy(1);
        uint256 amount = cap < affordable ? cap : affordable;
        if (amount > stock) amount = stock;
        assertGt(amount, 0, "there is something to deploy");

        vm.recordLogs();
        _deployAncestorAs(keeper, 1, amount);

        (, int24 currentTick,,) = im.getSlot0(roundManager.poolIdOf(1));
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _lastBidFromLogs();
        assertGt(liquidity, 0, "a bid was placed on the mirrored pool");
        assertLe(tickUpper, currentTick, "else-branch: the parent-only range sits BELOW spot");
        assertEq(tickUpper - tickLower, 60 * 10, "10 spacings wide, not collapsed");
        _assertSolvent();
    }

    function _lastBidFromLogs() internal returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        // getRecordedLogs() drains the buffer, so it is read exactly once here
        bytes32 topic = ILocker.BidDeposited.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker) || logs[i].topics[0] != topic) continue;
            (, tickLower, tickUpper, liquidity) = abi.decode(logs[i].data, (uint256, int24, int24, uint128));
        }
    }
}
