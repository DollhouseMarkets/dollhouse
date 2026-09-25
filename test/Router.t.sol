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

/// @notice The canonical router: exact-in routes across a 3-link chain, slippage, unspent-input
/// handling, and the attribution rule that makes a copycat router worthless.
contract RouterTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link2;
    address internal link3;

    function setUp() public {
        _setUpEdge();
        link2 = _runWinningRound(1, WINNING_BUY).token;
        link3 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 3, "three links of ours: #1, #2, #3");
        IERC20(link3).approve(address(familyRouter), type(uint256).max);
    }

    function test_buyAndSellThroughThreeLinks() public {
        uint256 dollBefore = doll.balanceOf(address(this));
        uint256 out = familyRouter.buyExactIn(3, 1 ether, 1, address(this), 3);

        assertGt(out, 0, "received the terminal token");
        assertEq(IERC20(link3).balanceOf(address(this)) >= out, true, "delivered to `to`");
        assertEq(dollBefore - doll.balanceOf(address(this)), 1 ether, "exact-in spends exactly what was asked");
        // the router is a pure conduit: it keeps nothing
        assertEq(doll.balanceOf(address(familyRouter)), 0, "no $DOLL stranded in the router");
        assertEq(IERC20(address(token)).balanceOf(address(familyRouter)), 0, "no #1 stranded");
        assertEq(IERC20(link2).balanceOf(address(familyRouter)), 0, "no #2 stranded");
        assertEq(IERC20(link3).balanceOf(address(familyRouter)), 0, "no #3 stranded");

        uint256 dollMid = doll.balanceOf(address(this));
        uint256 back = familyRouter.sellExactIn(3, out, 1, address(this), 3);
        assertGt(back, 0, "sold back into $DOLL");
        assertEq(doll.balanceOf(address(this)) - dollMid, back, "$DOLL delivered to `to`");
        // a round trip pays the 1% edge fee twice plus three hop fees each way, so it must lose
        assertLt(back, 1 ether, "a round trip cannot be profitable");
        _assertNoEth();
    }

    function test_minOutReverts() public {
        uint256 quoted = familyRouter.buyExactIn(3, 0.1 ether, 0, address(this), 3);
        vm.expectRevert();
        familyRouter.buyExactIn(3, 0.1 ether, quoted * 2, address(this), 3);
    }

    function test_depthCapRejectsTooManyHops() public {
        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.buyExactIn(3, 0.1 ether, 0, address(this), 2);
    }

    /// @notice Link one's curve absorbs a finite amount of $DOLL; an exact-in route simply spends
    /// less, because the router pulls only what the legs actually consumed.
    function test_unspentInputIsNeverPulled() public {
        uint256 huge = 10_000_000_000 ether; // more than the whole curve can absorb
        _fundDoll(address(this), huge);
        uint256 before = doll.balanceOf(address(this));
        familyRouter.buyExactIn(1, huge, 0, address(this), 1);
        uint256 spent = before - doll.balanceOf(address(this));
        assertLt(spent, huge, "the unfillable remainder was never pulled");
        assertGt(spent, 0, "the fillable part was spent");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "the router keeps no dust");
        _assertNoEth();
    }

    /// @notice A general family route with no EDGE leg: #3 -> #2. No protocol fee is possible.
    function test_swapPathBetweenFamilyLinks() public {
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 amount = IERC20(link3).balanceOf(address(this)) / 2;

        uint256[] memory path = new uint256[](2);
        path[0] = 3;
        path[1] = 2;
        uint256 devBefore = vault.devBalance();
        uint256 out = familyRouter.swapPath(path, amount, 1, address(this), 1);

        assertGt(out, 0, "rotated #3 into #2");
        assertEq(vault.devBalance(), devBefore, "no edge leg, no protocol fee");
    }

    /// @notice Attribution is trusted only from the canonical router. A copycat that passes the
    /// same hookData gets attribution zero, and the creator is credited nothing.
    function test_hookDataOnlyTrustedFromTheCanonicalRouter() public {
        address creator2 = roundManager.creatorOf(link3);
        assertEq(vault.creatorBalance(link3), 0, "nothing credited yet");

        // the copycat: a direct PoolManager swap on the EDGE pool, claiming terminal index 3
        PoolKey memory edgeKey = roundManager.poolKeyOf(1);
        plainRouter.swap(
            edgeKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(3))
        );
        assertEq(vault.creatorBalance(link3), 0, "a fake router gets attribution 0");
        assertGt(vault.devBalance(), 0, "the fee is still collected, just unattributed");

        // the real router credits the terminal token's creator
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        uint256 credited = vault.creatorBalance(link3);
        assertEq(credited, (1 ether / 100 * CREATOR_BPS) / 10_000, "creator gets CREATOR_BPS of the edge fee");
        assertEq(vault.creatorRecipient(link3), creator2, "claimable by the creator");
    }

    function test_gas_routedThreeHopBuy() public {
        uint256 g = gasleft();
        familyRouter.buyExactIn(3, 1 ether, 0, address(this), 3);
        emit log_named_uint("routed 3-hop buy ($DOLL -> #1 -> #2 -> #3) gas", g - gasleft());
    }

    // ---------------------------------------------------------------------------------
    // The attribution sentinel is index 0
    // ---------------------------------------------------------------------------------

    /// @notice A round trip `[0, 1, 0]` ends where it started, at the EDGE CURRENCY, so the
    /// terminal token of the route is canonical index 0 and the creator credited is the genesis
    /// creator - the deployer, since adoption credits the deployment itself. The path
    /// pays the protocol fee on both edge legs; only one creator is ever credited for it.
    function test_aRoundTripPathCreditsTheGenesisCreator() public {
        _runWinningRound(1, WINNING_BUY);
        _warmOracles();
        address edge = roundManager.canonical(0);
        address genesisCreator = roundManager.creatorOf(edge);
        assertEq(genesisCreator, factory.DEPLOYER(), "index 0 is credited to the deployer");

        address link1 = roundManager.canonical(1);
        uint256 creditedBefore = vault.creatorBalance(edge);
        uint256 linkCreditedBefore = vault.creatorBalance(link1);
        uint256[] memory path = new uint256[](3);
        path[0] = 0;
        path[1] = 1;
        path[2] = 0;
        IERC20(address(doll)).approve(address(familyRouter), type(uint256).max);
        familyRouter.swapPath(path, 1 ether, 0, address(this), 3);

        assertGt(vault.creatorBalance(edge) - creditedBefore, 0, "the edge currency's creator is credited");
        assertEq(vault.creatorRecipient(edge), genesisCreator, "and it is claimable by the deployer");
        assertEq(vault.creatorBalance(link1), linkCreditedBefore, "the link the route passed THROUGH is credited nothing");
    }
}
