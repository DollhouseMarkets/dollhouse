// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyRouter} from "../../contracts/FamilyRouter.sol";

/// @notice Property tests for the router (docs/spec/PROPERTIES.md sec.3.13), tier F.
contract RouterPropTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link1;
    address internal link2;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        link2 = _runWinningRound(1, WINNING_BUY).token;
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
        IERC20(address(token)).approve(address(familyRouter), type(uint256).max);
    }

    /// @notice ROU-01: every exact-in entrypoint reverts unless the final output is at least
    /// `minOut`, checked after the unlock returns.
    function testFuzz_ROU01_minOutIsEnforced(uint256 ethIn, uint256 excess) public {
        ethIn = bound(ethIn, 0.001 ether, 5 ether);
        uint256 quoted = familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        assertGt(quoted, 0, "the route delivered something");

        uint256 tooMuch = quoted + bound(excess, 1, 1e24);
        vm.expectRevert();
        familyRouter.buyExactIn{value: ethIn}(2, tooMuch, address(this), 3);

        // and any minOut at or below a fresh quote is accepted
        uint256 out = familyRouter.buyExactIn{value: ethIn}(2, 1, address(this), 3);
        assertGe(out, 1, "the route still runs under a satisfiable bound");
    }

    /// @notice ROU-01: a round-trip path reports the LAST leg's output rather than a netted zero.
    function testFuzz_ROU01_aRoundTripReportsItsLastLeg(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.01 ether, 5 ether);
        uint256[] memory path = new uint256[](3);
        path[0] = familyRouter.ETH();
        path[1] = 0;
        path[2] = familyRouter.ETH();

        uint256 before = address(this).balance;
        uint256 out = familyRouter.swapPath{value: ethIn}(path, ethIn, 0, address(this), 2);

        assertGt(out, 0, "the last leg's output is reported");
        assertLt(out, ethIn, "and a round trip pays two edge fees, so it cannot profit");
        assertEq(before - address(this).balance, ethIn - out, "the round trip's net cost is the fees plus slippage");
        assertEq(address(familyRouter).balance, 0, "the router keeps nothing");
    }

    /// @notice ROU-02: the fees paid by a routed swap equal those paid by an equivalent direct
    /// `PoolManager` swap, wei for wei; `hookData` affects only which ledger is credited.
    function testFuzz_ROU02_theRouterIsNeverFeePrivileged(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.001 ether, 10 ether);
        PoolKey memory genesisKey = roundManager.poolKeyOf(0);

        uint256 before = _feeVaultEth();
        plainRouter.swap{value: ethIn}(
            genesisKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 directFee = _feeVaultEth() - before;

        before = _feeVaultEth();
        familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
        uint256 routedFee = _feeVaultEth() - before;

        assertEq(routedFee, directFee, "routing costs exactly what the pool costs");

        // the same swap with attribution: the amount is unchanged, only the ledger differs
        before = _feeVaultEth();
        uint256 creatorBefore = vault.creatorBalance(address(token));
        plainRouter.swap{value: ethIn}(
            genesisKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(0))
        );
        assertEq(_feeVaultEth() - before, directFee, "hookData never moves a fee amount");
        assertEq(vault.creatorBalance(address(token)), creatorBefore, "and an untrusted sender credits nobody");
    }

    /// @notice ROU-04: `swapPath` enforces per-leg adjacency (`to == from+1`, `from == to+1`, or
    /// the ETH<->0 genesis leg) and reverts otherwise.
    function testFuzz_ROU04_adjacencyIsEnforced(uint256 fromSeed, uint256 toSeed) public {
        uint256 from = bound(fromSeed, 0, 2);
        uint256 to = bound(toSeed, 0, 2);
        bool adjacent = to == from + 1 || from == to + 1;

        uint256[] memory path = new uint256[](2);
        path[0] = from;
        path[1] = to;
        uint256 amount = IERC20(roundManager.canonical(from)).balanceOf(address(this)) / 8;
        vm.assume(amount != 0);

        if (adjacent) {
            uint256 out = familyRouter.swapPath(path, amount, 0, address(this), 1);
            assertGt(out, 0, "an adjacent leg trades");
        } else {
            vm.expectRevert(FamilyRouter.NonAdjacentPath.selector);
            familyRouter.swapPath(path, amount, 0, address(this), 1);
        }
    }

    /// @notice ROU-04: an ETH leg is adjacent only to index 0.
    function testFuzz_ROU04_theEthEdgeOnlyTouchesGenesis(uint256 indexSeed, uint256 ethIn) public {
        uint256 index = bound(indexSeed, 1, 2);
        ethIn = bound(ethIn, 0.001 ether, 1 ether);

        uint256[] memory path = new uint256[](2);
        path[0] = familyRouter.ETH();
        path[1] = index;
        vm.expectRevert(FamilyRouter.NonAdjacentPath.selector);
        familyRouter.swapPath{value: ethIn}(path, ethIn, 0, address(this), 1);
    }

    /// @notice ROU-04: `maxHops` bounds the whole route.
    function testFuzz_ROU04_maxHopsBoundsTheWholeRoute(uint256 target, uint256 hops) public {
        target = bound(target, 1, 2);
        hops = bound(hops, 0, target);
        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.buyExactIn{value: 0.1 ether}(target, 0, address(this), hops);
    }

    /// @notice ROU-05: `msg.value == amountIn` on an ETH-first path and `msg.value == 0`
    /// otherwise; the router has no `receive()`, so no ETH can be parked in it.
    function testFuzz_ROU05_valueMustMatchThePath(uint256 amountIn, uint256 value) public {
        amountIn = bound(amountIn, 1, 5 ether);
        value = bound(value, 0, 5 ether);
        vm.assume(value != amountIn);

        uint256[] memory ethPath = new uint256[](2);
        ethPath[0] = familyRouter.ETH();
        ethPath[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, value, amountIn));
        familyRouter.swapPath{value: value}(ethPath, amountIn, 0, address(this), 1);

        uint256[] memory tokenPath = new uint256[](2);
        tokenPath[0] = 1;
        tokenPath[1] = 2;
        vm.assume(value != 0);
        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, value, 0));
        familyRouter.swapPath{value: value}(tokenPath, amountIn, 0, address(this), 1);
    }

    /// @notice ROU-05: a plain ETH transfer to the router reverts, so nothing can be parked
    /// there and swept later.
    function testFuzz_ROU05_theRouterHoldsNoEth(uint256 value) public {
        value = bound(value, 1, 10 ether);
        (bool ok,) = address(familyRouter).call{value: value}("");
        assertFalse(ok, "the router has no receive()");
        assertEq(address(familyRouter).balance, 0, "and holds nothing");
    }

    /// @notice ROU-08: `buyCandidate`/`sellCandidate` are refused while the candidate's round is
    /// in Registration, and work forever afterwards, win or lose.
    function testFuzz_ROU08_candidateRoutesFollowTheRoundPhase(uint256 ethIn, uint256 wait) public {
        ethIn = bound(ethIn, 0.01 ether, 1 ether);
        Cand memory c = _registerCandidate(address(0xA11CE), "C");
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.expectRevert(FamilyRouter.NotTrading.selector);
        familyRouter.buyCandidate{value: ethIn}(c.id, 0, address(this), 8);

        vm.warp(tradingStart + 1);
        uint256 out = familyRouter.buyCandidate{value: ethIn}(c.id, 0, address(this), 8);
        assertGt(out, 0, "the candidate trades once its pool opens");

        // it loses the round, and its pool lives on
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        vm.warp(vm.getBlockTimestamp() + bound(wait, 1, 365 days));
        uint256 more = familyRouter.buyCandidate{value: ethIn}(c.id, 0, address(this), 8);
        assertGt(more, 0, "a loser's pool keeps trading forever");
    }
}
