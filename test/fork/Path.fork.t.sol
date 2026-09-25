// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork scenario 2 of docs/spec/PROPERTIES.md sec.4: a three-deep path on the real
/// `PoolManager`. Exactly one protocol fee on the EDGE leg in each direction, one hop fee per
/// leg, and a protocol-fee total that does not depend on the route length.
/// Covers FEE-01, FEE-02, ROU-03/04.
///
/// The edge is $DOLL - canonical index 0, an adopted token with no pool of ours - and
/// the EDGE POOL is link one. A full-line route to index `L` is `L` legs, not `L + 1`.
contract PathForkTest is ForkBase {
    address internal link2;
    address internal link3;

    function setUp() public {
        if (!_setUpForkEdge()) return;
        _buyLink(1, 5 ether);
        link2 = _runWinningRound(1, WINNING_BUY).token;
        link3 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 3, "three links of ours: #1 (the edge), #2, #3");
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
        IERC20(link3).approve(address(familyRouter), type(uint256).max);
    }

    /// @notice FEE-01: a buy that crosses three pools pays exactly one 1% protocol fee, charged
    /// on the $DOLL-side amount of the edge leg and nothing on the other two legs.
    function testFork_FEE01_threeDeepPathChargesOneEdgeFee() public {
        _requireFork();
        uint256 dollIn = 1 ether;

        vm.recordLogs();
        uint256 out = familyRouter.buyExactIn(3, dollIn, 0, address(this), 3);
        Split[] memory splits = _splits();

        assertGt(out, 0, "the terminal token was delivered");
        assertEq(splits.length, 3, "three legs, three accruals");

        uint256 edges;
        uint256 total;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edges++;
            total += splits[i].protocolFee;
            assertEq(splits[i].currency, address(doll), "the edge fee is charged in the edge currency");
        }
        assertEq(edges, 1, "exactly one protocol fee across the whole path");
        assertEq(total, (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the $DOLL-side amount of the edge leg");
        assertEq(splits[0].dev + splits[0].creator + splits[0].sleeve + splits[0].reinforce, total, "buckets sum");
        assertEq(vault.creatorBalance(link3), splits[0].creator, "the TERMINAL token's creator is credited");
        _assertSolvent();
        _assertNoEth();
    }

    /// @notice FEE-01: the protocol-fee total at a given $DOLL notional is identical for every
    /// route length, so depth is never a fee.
    function testFork_FEE01_theEdgeFeeDoesNotDependOnDepth() public {
        _requireFork();
        uint256 dollIn = 0.5 ether;
        uint256 atOne = _protocolFeeOfBuy(1, dollIn);
        uint256 atTwo = _protocolFeeOfBuy(2, dollIn);
        uint256 atThree = _protocolFeeOfBuy(3, dollIn);

        assertEq(atOne, (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% at the edge itself");
        assertEq(atTwo, atOne, "one hop deeper pays the same");
        assertEq(atThree, atOne, "two hops deeper pays the same");
    }

    /// @notice FEE-02: every leg pays `hopFeePpm` on its OWN parent side, and each hop fee lands
    /// in that parent's reinforcement pot - so the total is not a closed form in $DOLL.
    function testFork_FEE02_everyLegPaysItsOwnHopFee() public {
        _requireFork();
        uint256 dollIn = 1 ether;

        uint256[3] memory potsBefore;
        for (uint256 i = 0; i < 3; i++) {
            potsBefore[i] = vault.reinforcementBalance(roundManager.canonical(i));
        }

        vm.recordLogs();
        familyRouter.buyExactIn(3, dollIn, 0, address(this), 3);
        Split[] memory splits = _splits();

        assertEq(splits.length, 3, "one hop fee per leg");
        assertEq(splits[0].hopFee, (dollIn * _hopFeePpm()) / PPM, "the edge leg's hop fee is a fraction of the $DOLL");
        for (uint256 i = 0; i < 3; i++) {
            address parent = roundManager.canonical(i);
            assertGt(splits[i].hopFee, 0, "every leg pays a hop fee on its own parent side");
            assertEq(splits[i].currency, parent, "charged in that leg's parent currency");
            assertEq(vault.reinforcementBalance(parent) - potsBefore[i], splits[i].hopFee, "into that parent's own pot");
        }
    }

    /// @notice ROU-04: the reverse route pays one protocol fee too, charged on the gross $DOLL
    /// the edge pool paid out, not on the trader's receipt.
    function testFork_ROU04_reverseRouteChargesOneEdgeFee() public {
        _requireFork();
        familyRouter.buyExactIn(3, 2 ether, 0, address(this), 3);
        uint256 amount = IERC20(link3).balanceOf(address(this)) / 2;
        assertGt(amount, 0, "holding the terminal token to sell");

        vm.recordLogs();
        uint256 dollOut = familyRouter.sellExactIn(3, amount, 0, address(this), 3);
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
        uint256 gross = dollOut + sold + hopOnTheEdge;
        assertApproxEqAbs(sold, (gross * hook.PROTOCOL_FEE_PPM()) / PPM, 1, "1% of the gross $DOLL the pool paid");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "the router keeps no dust");
        _assertSolvent();
        _assertNoEth();
    }

    /// @notice ROU-03: a route that never touches the edge pool can pay no protocol fee at all.
    function testFork_ROU03_aRouteWithoutTheEdgePaysNoProtocolFee() public {
        _requireFork();
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 amount = IERC20(link3).balanceOf(address(this)) / 2;

        uint256[] memory path = new uint256[](2);
        path[0] = 3;
        path[1] = 2;
        uint256 devBefore = vault.devBalance();
        vm.recordLogs();
        uint256 out = familyRouter.swapPath(path, amount, 1, address(this), 1);
        Split[] memory splits = _splits();

        assertGt(out, 0, "rotated #3 into #2");
        for (uint256 i = 0; i < splits.length; i++) {
            assertEq(splits[i].protocolFee, 0, "no edge leg, no protocol fee");
        }
        assertEq(vault.devBalance(), devBefore, "and the dev ledger did not move");
    }

    function _protocolFeeOfBuy(uint256 target, uint256 dollIn) internal returns (uint256 fee) {
        vm.recordLogs();
        familyRouter.buyExactIn(target, dollIn, 0, address(this), target + 1);
        Split[] memory splits = _splits();
        for (uint256 i = 0; i < splits.length; i++) {
            fee += splits[i].protocolFee;
        }
    }
}
