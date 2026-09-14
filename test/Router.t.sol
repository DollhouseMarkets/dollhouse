// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";

/// @notice The canonical router: exact-in routes across a 3-link chain, slippage, ETH refunds,
/// and the attribution rule that makes a copycat router worthless.
contract RouterTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link1;
    address internal link2;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 2, "three links: genesis, #1, #2");
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
    }

    function test_buyAndSellThroughThreeLinks() public {
        uint256 ethBefore = address(this).balance;
        uint256 out = familyRouter.buyExactIn{value: 1 ether}(2, 1, address(this), 3);

        assertGt(out, 0, "received the terminal token");
        assertEq(IERC20(link2).balanceOf(address(this)) >= out, true, "delivered to `to`");
        assertEq(ethBefore - address(this).balance, 1 ether, "exact-in spends exactly msg.value");
        // the router is a pure conduit: it keeps nothing
        assertEq(address(familyRouter).balance, 0, "no ETH stranded in the router");
        assertEq(IERC20(address(token)).balanceOf(address(familyRouter)), 0, "no genesis stranded");
        assertEq(IERC20(link1).balanceOf(address(familyRouter)), 0, "no #1 stranded");
        assertEq(IERC20(link2).balanceOf(address(familyRouter)), 0, "no #2 stranded");

        uint256 ethMid = address(this).balance;
        uint256 back = familyRouter.sellExactIn(2, out, 1, address(this), 3);
        assertGt(back, 0, "sold back into ETH");
        assertEq(address(this).balance - ethMid, back, "ETH delivered to `to`");
        // a round trip pays the 1% edge fee twice plus three hop fees each way, so it must lose
        assertLt(back, 1 ether, "a round trip cannot be profitable");
    }

    function test_minOutReverts() public {
        uint256 quoted = familyRouter.buyExactIn{value: 0.1 ether}(2, 0, address(this), 3);
        vm.expectRevert();
        familyRouter.buyExactIn{value: 0.1 ether}(2, quoted * 2, address(this), 3);
    }

    function test_depthCapRejectsTooManyHops() public {
        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.buyExactIn{value: 0.1 ether}(2, 0, address(this), 2);
    }

    /// @notice The genesis curve absorbs a finite amount of ETH; the rest comes back.
    function test_refundsUnusedEth() public {
        uint256 huge = 5_000 ether;
        uint256 before = address(this).balance;
        familyRouter.buyExactIn{value: huge}(0, 0, address(this), 1);
        uint256 spent = before - address(this).balance;
        assertLt(spent, huge, "the unfillable remainder was refunded");
        assertGt(spent, 0, "the fillable part was spent");
        assertEq(address(familyRouter).balance, 0, "the router keeps no dust");
    }

    /// @notice A general family route with no ETH edge: #2 -> #1. No protocol fee is possible.
    function test_swapPathBetweenFamilyLinks() public {
        familyRouter.buyExactIn{value: 1 ether}(2, 0, address(this), 3);
        uint256 amount = IERC20(link2).balanceOf(address(this)) / 2;

        uint256[] memory path = new uint256[](2);
        path[0] = 2;
        path[1] = 1;
        uint256 devBefore = vault.devBalance();
        uint256 out = familyRouter.swapPath(path, amount, 1, address(this), 1);

        assertGt(out, 0, "rotated #2 into #1");
        assertEq(vault.devBalance(), devBefore, "no ETH edge, no protocol fee");
    }

    /// @notice Attribution is trusted only from the canonical router. A copycat that passes the
    /// same hookData gets attribution zero, and the creator is credited nothing.
    function test_hookDataOnlyTrustedFromTheCanonicalRouter() public {
        address creator2 = roundManager.creatorOf(link2);
        assertEq(vault.creatorBalance(link2), 0, "nothing credited yet");

        // the copycat: a direct PoolManager swap on the genesis pool, claiming terminal index 2
        PoolKey memory genesisKey = roundManager.poolKeyOf(0);
        plainRouter.swap{value: 1 ether}(
            genesisKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(2))
        );
        assertEq(vault.creatorBalance(link2), 0, "a fake router gets attribution 0");
        assertGt(vault.devBalance(), 0, "the fee is still collected, just unattributed");

        // the real router credits the terminal token's creator
        familyRouter.buyExactIn{value: 1 ether}(2, 0, address(this), 3);
        uint256 credited = vault.creatorBalance(link2);
        assertEq(credited, (1 ether / 100 * CREATOR_BPS) / 10_000, "creator gets CREATOR_BPS of the edge fee");
        assertEq(vault.creatorRecipient(link2), creator2, "claimable by the creator");
    }

    function test_gas_routedThreeHopBuy() public {
        uint256 g = gasleft();
        familyRouter.buyExactIn{value: 1 ether}(2, 0, address(this), 3);
        emit log_named_uint("routed 3-hop buy (ETH -> #0 -> #1 -> #2) gas", g - gasleft());
    }
}
