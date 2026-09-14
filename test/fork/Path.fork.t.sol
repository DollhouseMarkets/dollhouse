// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork scenario 2 of docs/spec/PROPERTIES.md sec.4: a three-deep path on the real
/// `PoolManager`. Exactly one protocol fee on the genesis leg in each direction, one hop fee per
/// leg, and a protocol-fee total that does not depend on the route length.
/// Covers FEE-01, FEE-02, ROU-03/04.
contract PathForkTest is ForkBase {
    address internal link1;
    address internal link2;

    function setUp() public {
        if (!_setUpForkFamily()) return;
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 2, "three links: genesis, #1, #2");
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
    }

    /// @notice FEE-01: a buy that crosses three pools pays exactly one 1% protocol fee, charged
    /// on the ETH-side amount of the genesis leg and nothing on the other two legs.
    function testFork_FEE01_threeDeepPathChargesOneEdgeFee() public {
        _requireFork();
        uint256 ethIn = 1 ether;

        vm.recordLogs();
        uint256 out = familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        Split[] memory splits = _splits();

        assertGt(out, 0, "the terminal token was delivered");
        assertEq(splits.length, 3, "three legs, three accruals");

        uint256 edges;
        uint256 total;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edges++;
            total += splits[i].protocolFee;
            assertEq(splits[i].currency, address(0), "the edge fee is charged in ETH");
        }
        assertEq(edges, 1, "exactly one protocol fee across the whole path");
        assertEq(total, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the ETH-side amount of the genesis leg");
        assertEq(splits[0].dev + splits[0].creator + splits[0].sleeve + splits[0].reinforce, total, "buckets sum");
        assertEq(vault.creatorBalance(link2), splits[0].creator, "the TERMINAL token's creator is credited");
        _assertSolvent();
    }

    /// @notice FEE-01: the protocol-fee total at a given ETH notional is identical for every
    /// route length, so depth is never a fee.
    function testFork_FEE01_theEdgeFeeDoesNotDependOnDepth() public {
        _requireFork();
        uint256 ethIn = 0.5 ether;
        uint256 atZero = _protocolFeeOfBuy(0, ethIn);
        uint256 atOne = _protocolFeeOfBuy(1, ethIn);
        uint256 atTwo = _protocolFeeOfBuy(2, ethIn);

        assertEq(atZero, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% at the edge itself");
        assertEq(atOne, atZero, "one hop deeper pays the same");
        assertEq(atTwo, atZero, "two hops deeper pays the same");
    }

    /// @notice FEE-02: every leg pays `hopFeePpm` on its OWN parent side, and each hop fee lands
    /// in that parent's reinforcement pot - so the total is not a closed form in ETH.
    function testFork_FEE02_everyLegPaysItsOwnHopFee() public {
        _requireFork();
        uint256 ethIn = 1 ether;

        uint256[3] memory potsBefore;
        for (uint256 i = 0; i < 3; i++) {
            potsBefore[i] = vault.reinforcementBalance(i == 0 ? address(0) : roundManager.canonical(i - 1));
        }

        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(2, 0, address(this), 3);
        Split[] memory splits = _splits();

        assertEq(splits.length, 3, "one hop fee per leg");
        assertEq(splits[0].hopFee, (ethIn * _hopFeePpm()) / PPM, "the ETH leg's hop fee is a fraction of the ETH in");
        for (uint256 i = 0; i < 3; i++) {
            address parent = i == 0 ? address(0) : roundManager.canonical(i - 1);
            assertGt(splits[i].hopFee, 0, "every leg pays a hop fee on its own parent side");
            assertEq(splits[i].currency, parent, "charged in that leg's parent currency");
            assertEq(vault.reinforcementBalance(parent) - potsBefore[i], splits[i].hopFee, "into that parent's own pot");
        }
    }

    /// @notice ROU-04: the reverse route pays one protocol fee too, charged on the gross ETH the
    /// genesis pool paid out, not on the trader's receipt.
    function testFork_ROU04_reverseRouteChargesOneEdgeFee() public {
        _requireFork();
        familyRouter.buyExactIn{value: 2 ether}(2, 0, address(this), 3);
        uint256 amount = IERC20(link2).balanceOf(address(this)) / 2;
        assertGt(amount, 0, "holding the terminal token to sell");

        vm.recordLogs();
        uint256 ethOut = familyRouter.sellExactIn(2, amount, 0, address(this), 3);
        Split[] memory splits = _splits();

        uint256 edges;
        uint256 sold;
        uint256 hopOnTheEdge;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edges++;
            sold = splits[i].protocolFee;
            hopOnTheEdge = splits[i].hopFee;
        }
        assertEq(splits.length, 3, "three legs going back out");
        assertEq(edges, 1, "one traversal, one fee, selling too");
        uint256 gross = ethOut + sold + hopOnTheEdge;
        assertApproxEqAbs(sold, (gross * hook.PROTOCOL_FEE_PPM()) / PPM, 1, "1% of the gross ETH the pool paid");
        assertEq(address(familyRouter).balance, 0, "the router keeps no dust");
        _assertSolvent();
    }

    /// @notice ROU-03: a route with no ETH edge can pay no protocol fee at all.
    function testFork_ROU03_aRouteWithoutTheEdgePaysNoProtocolFee() public {
        _requireFork();
        familyRouter.buyExactIn{value: 1 ether}(2, 0, address(this), 3);
        uint256 amount = IERC20(link2).balanceOf(address(this)) / 2;

        uint256[] memory path = new uint256[](2);
        path[0] = 2;
        path[1] = 1;
        uint256 devBefore = vault.devBalance();
        vm.recordLogs();
        uint256 out = familyRouter.swapPath(path, amount, 1, address(this), 1);
        Split[] memory splits = _splits();

        assertGt(out, 0, "rotated #2 into #1");
        for (uint256 i = 0; i < splits.length; i++) {
            assertEq(splits[i].protocolFee, 0, "no ETH edge, no protocol fee");
        }
        assertEq(vault.devBalance(), devBefore, "and the dev ledger did not move");
    }

    function _protocolFeeOfBuy(uint256 target, uint256 ethIn) internal returns (uint256 fee) {
        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(target, 0, address(this), target + 1);
        Split[] memory splits = _splits();
        for (uint256 i = 0; i < splits.length; i++) {
            fee += splits[i].protocolFee;
        }
    }
}
