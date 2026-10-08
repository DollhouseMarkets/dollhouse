// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {EthZap} from "../contracts/EthZap.sol";
import {MockV2Pair, MockV3Pool, IMockV3Callback, MockSmartAccount, Mock7702Delegate} from "./utils/SidePoolMocks.sol";

/// @dev A pool shaped with `tokenA()` / `tokenB()` instead of `token0()` / `token1()`: the
/// venue lock's pool probe does not recognise it (see test_14).
contract MockAbPair {
    address public tokenA;
    address public tokenB;

    constructor(address a, address b) {
        (tokenA, tokenB) = (a, b);
    }

    function send(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @dev A hostile successor version in one contract: the registry the steward names in the
/// sunset notice, its factory and its hook. It names the prior registry back, shares the
/// PoolManager, and lists an arbitrary address (a v2 pair here) as its Locker and FeeVault.
contract HostileSuccessor {
    address public immutable priorRegistry;
    address public immutable poolManager;
    address public immutable locker;

    constructor(address prior, address pm, address endpoint) {
        priorRegistry = prior;
        poolManager = pm;
        locker = endpoint;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function hook() external view returns (address) {
        return address(this);
    }

    function feeVault() external view returns (address) {
        return locker;
    }

    function accept(FamilyToken t) external returns (bool) {
        return t.acceptCanonicalHook();
    }

    /// @dev Credit `delta` and read the allowance back in the same call (a test's top-level
    /// calls do not share transient storage).
    function credit(FamilyToken t, int256 delta) external returns (uint256 inAllowance, uint256 outAllowance) {
        t.creditCanonical(delta);
        return t.canonicalAllowance();
    }
}

/// @notice THE VENUE LOCK (private/V2_SIDE_TAX_DESIGN.md, superseding note). A family coin
/// traded through its canonical pool - by any router that settles after it swaps - moves
/// untouched; the same coin moved into or out of any other pool is refused with
/// `NonCanonicalVenue`; wallets, smart wallets and the protocol's own contracts are never
/// refused, and nothing is ever charged on the coin.
contract VenueLockTest is RoundTestBase, IUnlockCallback, IMockV3Callback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;
    uint8 internal constant INBOUND = 1;
    uint8 internal constant OUTBOUND = 2;
    uint8 internal constant POOL = 3;

    FamilyToken internal link1;
    FamilyToken internal link2;
    PoolKey internal edgeKey; // DOLL / link1, canonical
    PoolKey internal link2Key; // link1 / link2, canonical (a family parent)
    PoolKey internal sideKey; // DOLL / link1, hookless, same PoolManager

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpEdge();
        link1 = FamilyToken(roundManager.canonical(1));
        link2 = FamilyToken(_runWinningRound(1, WINNING_BUY).token);
        edgeKey = roundManager.poolKeyOf(1);
        link2Key = roundManager.poolKeyOf(2);
        link1.approve(address(swapRouter), type(uint256).max);
        link2.approve(address(swapRouter), type(uint256).max);
        link1.approve(address(familyRouter), type(uint256).max);
        link2.approve(address(familyRouter), type(uint256).max);
        doll.mint(address(this), 1e27);

        // the copy pool: a hookless DOLL/link1 pool in the SAME PoolManager, opened at the
        // canonical price. A plain LP cannot seed it (test_4); it is seeded here the one way that
        // remains - inside an unlock, funded by a canonical buy's link-one delta, so no link one
        // ever moves into or out of the PoolManager (the residual, see the sandwich test).
        sideKey = PoolKey({
            currency0: edgeKey.currency0,
            currency1: edgeKey.currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        assertEq(Currency.unwrap(sideKey.currency1), address(link1), "link one is currency1");
        (uint160 sqrtP,,,) = im.getSlot0(edgeKey.toId());
        manager.initialize(sideKey, sqrtP);
        Op[] memory ops = new Op[](3);
        ops[0] = _liq(sideKey, 1e21);
        ops[1] = _cover(edgeKey, true, sideKey.currency1); // canonical exact-out buy of the owed link one
        ops[2] = _settleAll(sideKey.currency0);
        _run(ops);
        assertGt(im.getLiquidity(sideKey.toId()), 0, "the copy pool is seeded");
    }

    // =====================================================================================
    // 1. canonical trading is untouched, by every settler that settles after it swaps
    // =====================================================================================

    function test_1_familyRouterMultiHopBuyAndSellUntaxed() public {
        (uint256 s1, uint256 s2) = _supplies();
        uint256 out = familyRouter.buyExactIn(2, 10 ether, 0, alice, 3);
        assertGt(out, 0);
        assertEq(link2.balanceOf(alice), out, "the whole output arrives");
        vm.startPrank(alice);
        link2.approve(address(familyRouter), out);
        uint256 dollOut = familyRouter.sellExactIn(2, out, 0, alice, 3);
        vm.stopPrank();
        assertGt(dollOut, 0);
        assertEq(link2.balanceOf(alice), 0, "the whole position was sold");
        _assertUnchanged(s1, s2);
    }

    /// @dev PoolSwapTest settles the input and takes the output after the swap, exactly: the
    /// shape of every third-party router that settles after swapping. All four modes, on the
    /// edge pool (parent = external $DOLL) and on link two's pool (parent = family link one, so
    /// both sides are credited and the parent credit runs through beforeSwap and afterSwap).
    function test_1_thirdPartyExactSettlerAllModesUntaxed() public {
        (uint256 s1, uint256 s2) = _supplies();
        PoolKey[2] memory ks = [edgeKey, link2Key];
        for (uint256 i = 0; i < 2; i++) {
            _swapVia(swapRouter, ks[i], true, -1e18);
            _swapVia(swapRouter, ks[i], false, -1e18);
            _swapVia(swapRouter, ks[i], true, 1e18);
            _swapVia(swapRouter, ks[i], false, 1e18);
        }
        _assertUnchanged(s1, s2);
    }

    function test_1_partialFillUntaxed() public {
        (uint256 s1, uint256 s2) = _supplies();
        (uint160 sqrtP,,,) = im.getSlot0(link2Key.toId());
        uint256 bal0 = IERC20(Currency.unwrap(link2Key.currency0)).balanceOf(address(this));
        int256 specified = -int256(bal0 / 2);
        // spend currency0 with a price limit barely below the current price: the pool fills a
        // sliver and the settler pays exactly that
        BalanceDelta d = swapRouter.swap(
            link2Key,
            SwapParams({zeroForOne: true, amountSpecified: specified, sqrtPriceLimitX96: sqrtP - sqrtP / 1000}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 paid = uint256(uint128(-d.amount0()));
        assertLt(paid, uint256(-specified), "partial fill");
        assertGt(paid, 0);
        assertEq(bal0 - IERC20(Currency.unwrap(link2Key.currency0)).balanceOf(address(this)), paid);
        _assertUnchanged(s1, s2);
    }

    /// @dev The v4-periphery router (`V4Router`, through its `MockV4Router` harness): exact-in
    /// and exact-out single hops both ways, a two-hop exact-in buy and sell ($DOLL -> link one ->
    /// link two), a two-hop exact-out buy, and an exact-in sell large enough to run the pool
    /// to its price limit (a partial fill, settled for exactly what was used).
    function test_1_v4PeripheryRouterAllShapesUntaxed() public {
        MockV4Router r = new MockV4Router(IPoolManager(address(manager)));
        doll.approve(address(r), type(uint256).max);
        link1.approve(address(r), type(uint256).max);
        link2.approve(address(r), type(uint256).max);
        (uint256 s1, uint256 s2) = _supplies();
        Currency cDoll = Currency.wrap(address(doll));
        Currency c1 = Currency.wrap(address(link1));
        Currency c2 = Currency.wrap(address(link2));
        bool dollIs0 = Currency.unwrap(edgeKey.currency0) == address(doll);
        bool link1Is0 = Currency.unwrap(link2Key.currency0) == address(link1);

        // single hops on the edge pool
        uint256 b1 = link1.balanceOf(address(this));
        _v4InSingle(r, edgeKey, dollIs0, 1e18, cDoll, c1);
        uint256 got = link1.balanceOf(address(this)) - b1;
        assertGt(got, 0, "exact-in single buy");
        _v4InSingle(r, edgeKey, !dollIs0, uint128(got / 2), c1, cDoll);
        _v4OutSingle(r, edgeKey, dollIs0, 1e18, cDoll, c1);
        _v4OutSingle(r, edgeKey, !dollIs0, 1e15, c1, cDoll);
        // single hops on link two's pool (a family parent: both sides credited)
        _v4InSingle(r, link2Key, link1Is0, 1e18, c1, c2);
        _v4OutSingle(r, link2Key, !link1Is0, 1e15, c2, c1);

        // two hops, exact in: $DOLL -> link one -> link two, and back
        uint256 b2 = link2.balanceOf(address(this));
        _v4InPath(r, cDoll, _path(c1, edgeKey, c2, link2Key), 1e18, c2);
        uint256 got2 = link2.balanceOf(address(this)) - b2;
        assertGt(got2, 0, "two-hop exact-in buy");
        _v4InPath(r, c2, _path(c1, link2Key, cDoll, edgeKey), uint128(got2), cDoll);
        // two hops, exact out: exactly 1e18 link two for $DOLL
        b2 = link2.balanceOf(address(this));
        // (an exact-output path names each hop by its INPUT currency)
        _v4OutPath(r, c2, _path(cDoll, edgeKey, c1, link2Key), 1e18, cDoll);
        assertEq(link2.balanceOf(address(this)) - b2, 1e18, "two-hop exact-out buy");

        // partial fill: sell far more link one than the pool can absorb before its price limit
        uint256 huge = 500_000_000 ether;
        deal(address(link1), address(this), link1.balanceOf(address(this)) + huge);
        b1 = link1.balanceOf(address(this));
        _v4InSingle(r, edgeKey, !dollIs0, uint128(huge), c1, cDoll);
        uint256 sold = b1 - link1.balanceOf(address(this));
        assertGt(sold, 0, "some was sold");
        assertLt(sold, huge, "partial fill: only what the pool used was settled");
        _assertUnchanged(s1, s2);
    }

    function test_1_buyCandidateWithParentUntaxed() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);
        (uint256 s1, uint256 s2) = _supplies();
        uint256 sc = IERC20(c.token).totalSupply();
        uint256 out = familyRouter.buyCandidateWithParent(c.id, 1e18, 0, alice);
        assertGt(out, 0);
        assertEq(IERC20(c.token).balanceOf(alice), out);
        assertEq(IERC20(c.token).totalSupply(), sc, "candidate supply unchanged");
        _assertUnchanged(s1, s2);
    }

    function test_1_ethZapBuyAndSellUntaxed() public {
        EthZap zap = _deployZap();
        (uint256 s1, uint256 s2) = _supplies();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 out = zap.buyWithEth{value: 1 ether}(2, 0, alice, 3, block.timestamp);
        assertGt(out, 0);
        assertEq(link2.balanceOf(alice), out, "the whole output arrives");
        vm.startPrank(alice);
        link2.approve(address(zap), out);
        uint256 ethOut = zap.sellForEth(2, out, 0, alice, 3, block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 0);
        assertEq(link2.balanceOf(alice), 0);
        _assertUnchanged(s1, s2);
    }

    /// @dev The zap's refund path: a sell the canonical pool fills only in part returns the
    /// unspent coin to the payer, through the zap, and the lock lets every leg through.
    function test_1_ethZapPartialSellRefundUntaxed() public {
        EthZap zap = _deployZap();
        (uint256 s1, uint256 s2) = _supplies();
        uint256 huge = 500_000_000 ether;
        deal(address(link1), alice, huge);
        vm.startPrank(alice);
        link1.approve(address(zap), huge);
        uint256 ethOut = zap.sellForEth(1, huge, 1, alice, 1, block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 0);
        uint256 back = link1.balanceOf(alice);
        assertGt(back, 0, "unspent link coin returned");
        assertLt(back, huge, "some was sold");
        _assertUnchanged(s1, s2);
    }

    // =====================================================================================
    // 2. a v2-shaped pair: seeding, selling and buying are all refused
    // =====================================================================================

    function test_2_v2PairRefused() public {
        MockV2Pair pair = new MockV2Pair(address(link1), address(doll));
        link1.transfer(alice, 100e18);
        uint256 supply = link1.totalSupply();

        // a mint / seed or a sell: into the pair
        vm.prank(alice);
        _expectRefused(alice, address(pair), POOL);
        link1.transfer(address(pair), 40e18);

        // a buy (or an LP remove): out of a pair that somehow holds the coin
        deal(address(link1), address(pair), 10e18);
        _expectRefused(address(pair), bob, POOL);
        pair.send(address(link1), bob, 10e18);

        assertEq(link1.balanceOf(alice), 100e18, "nothing left the seller");
        assertEq(link1.balanceOf(bob), 0, "nothing reached the buyer");
        assertEq(link1.totalSupply(), supply, "nothing is charged or burned");
    }

    // =====================================================================================
    // 3. a v3-shaped pool: seeding, selling and buying are all refused
    // =====================================================================================

    function test_3_v3PoolRefused() public {
        MockV3Pool pool = new MockV3Pool(address(link1), address(doll));
        uint256 supply = link1.totalSupply();

        // seed (a v3 mint pays the pool in its callback: a plain transfer in)
        _expectRefused(address(this), address(pool), POOL);
        link1.transfer(address(pool), 1_000e18);

        doll.transfer(address(pool), 1_000e18);
        deal(address(link1), address(pool), 1_000e18);

        // sell link1 into the pool: the callback's payment is refused
        _expectRefused(address(this), address(pool), POOL);
        pool.swap(address(link1), 10e18, address(doll), 1e18, address(this));

        // buy link1 out of the pool: the pool's payout is refused
        _expectRefused(address(pool), address(this), POOL);
        pool.swap(address(doll), 1e18, address(link1), 10e18, address(this));

        assertEq(link1.totalSupply(), supply);
    }

    function mockV3Callback(address t, uint256 amount) external {
        IERC20(t).transfer(msg.sender, amount);
    }

    // =====================================================================================
    // 4. a hookless v4 pool in the same PoolManager
    // =====================================================================================

    function test_4_hooklessV4SeedingReverts() public {
        Op[] memory ops = new Op[](3);
        ops[0] = _liq(sideKey, 1e18);
        ops[1] = _settleAll(sideKey.currency0);
        ops[2] = _settleAll(sideKey.currency1);
        _expectRefused(address(this), address(manager), INBOUND);
        this.runOps(ops);
    }

    function test_4_hooklessV4BuyReverts() public {
        _assertNoAllowance(link1, "no allowance carried over from setUp");
        Op[] memory ops = new Op[](3);
        ops[0] = _swapOp(sideKey, true, -1e18); // DOLL in, link1 out
        ops[1] = _settleAll(sideKey.currency0);
        ops[2] = _takeAll(sideKey.currency1, alice);
        _expectTakeRefused(alice);
        this.runOps(ops);

        // the same buy through PoolSwapTest
        _expectTakeRefused(address(this));
        _swapVia(swapRouter, sideKey, true, -1e17);
        assertEq(link1.balanceOf(alice), 0);
    }

    function test_4_hooklessV4SellReverts() public {
        Op[] memory ops = new Op[](3);
        ops[0] = _swapOp(sideKey, false, -1e18); // sell link1 (currency1) for DOLL
        ops[1] = _settleAll(sideKey.currency1);
        ops[2] = _takeAll(sideKey.currency0, address(this));
        _expectRefused(address(this), address(manager), INBOUND);
        this.runOps(ops);

        // the same sell through PoolSwapTest
        _expectRefused(address(this), address(manager), INBOUND);
        _swapVia(swapRouter, sideKey, false, -1e18);
    }

    // =====================================================================================
    // 5. wallets are never refused
    // =====================================================================================

    function test_5_walletsAndZapRefundsUntaxed() public {
        (uint256 s1, uint256 s2) = _supplies();
        link1.transfer(alice, 100e18);

        // EOA -> EOA
        vm.prank(alice);
        link1.transfer(bob, 10e18);
        assertEq(link1.balanceOf(bob), 10e18);

        // EOA -> EIP-7702 delegated EOA, and back out THROUGH its delegate's code. This needs the
        // Prague EVM (foundry.toml `evm_version = "prague"`): under Cancun the `0xef0100`
        // designator executes as INVALID, so the `execute` call below would revert.
        address delegated = makeAddr("delegated");
        Mock7702Delegate impl = new Mock7702Delegate();
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(impl)));
        vm.prank(alice);
        link1.transfer(delegated, 10e18);
        assertEq(link1.balanceOf(delegated), 10e18);
        vm.prank(delegated);
        Mock7702Delegate(payable(delegated)).execute(address(link1), abi.encodeCall(IERC20.transfer, (bob, 5e18)));
        assertEq(link1.balanceOf(bob), 15e18);

        // EOA -> ERC-4337 account, and out through `execute`
        MockSmartAccount account = new MockSmartAccount(alice, address(0x4337));
        vm.prank(alice);
        link1.transfer(address(account), 10e18);
        assertEq(link1.balanceOf(address(account)), 10e18);
        vm.prank(address(0x4337));
        account.execute(address(link1), 0, abi.encodeCall(IERC20.transfer, (bob, 4e18)));
        assertEq(link1.balanceOf(bob), 19e18);

        // a zap-shaped refund: a protocol contract (no pool getters) back to the payer
        EthZap zap = _deployZap();
        vm.prank(alice);
        link1.transfer(address(zap), 3e18);
        vm.prank(address(zap));
        link1.transfer(alice, 3e18);

        _assertUnchanged(s1, s2);
    }

    // =====================================================================================
    // 6. a plain transfer into (or out of) the PoolManager with no canonical credit is refused
    // =====================================================================================

    function test_6_plainTransferIntoThePoolManagerRefused() public {
        link1.transfer(alice, 100e18);
        uint256 pmBefore = link1.balanceOf(address(manager));
        vm.prank(alice);
        _expectRefused(alice, address(manager), INBOUND);
        link1.transfer(address(manager), 50e18);

        // and out of it: nothing was credited
        vm.prank(address(manager));
        _expectRefused(address(manager), bob, OUTBOUND);
        link1.transfer(bob, 1e18);
        assertEq(link1.balanceOf(address(manager)), pmBefore);
    }

    // =====================================================================================
    // 7. only the hook may credit
    // =====================================================================================

    function test_7_creditCanonicalFromANonHookReverts() public {
        vm.prank(alice);
        vm.expectRevert(FamilyToken.NotHook.selector);
        link1.creditCanonical(-1e18);

        vm.prank(address(familyRouter));
        vm.expectRevert(FamilyToken.NotHook.selector);
        link1.creditCanonical(1e18);

        vm.prank(address(manager));
        vm.expectRevert(FamilyToken.NotHook.selector);
        link1.creditCanonical(1e18);

        assertTrue(link1.isCanonicalHook(address(hook)));
        assertFalse(link1.isCanonicalHook(address(familyRouter)));
        _assertNoAllowance(link1, "nothing credited");
    }

    // =====================================================================================
    // 8. a transfer the allowance covers only in part is refused whole (never split)
    // =====================================================================================

    /// @dev Canonical Y + side Z taken in one go: the outbound allowance is Y, the take is Y + Z,
    /// so the whole take is refused - not Y let through and Z refused.
    function test_8_canonicalPlusSideBuyTakenTogetherRefusedWhole() public {
        Op[] memory ops = new Op[](4);
        ops[0] = _swapOp(edgeKey, true, 2e18); // canonical: DOLL in, exactly 2e18 link1 out
        ops[1] = _swapOp(sideKey, true, -1e18); // side: DOLL in, link1 out
        ops[2] = _settleAll(edgeKey.currency0);
        ops[3] = _takeAll(edgeKey.currency1, alice);
        _expectTakeRefused(alice, 2e18);
        this.runOps(ops);
        assertEq(link1.balanceOf(alice), 0);
    }

    /// @dev The inbound mirror: a canonical sell of Y plus a side sell of Z paid in one transfer
    /// of Y + Z against an inbound allowance of Y.
    function test_8_canonicalPlusSideSellPaidTogetherRefusedWhole() public {
        Op[] memory ops = new Op[](4);
        ops[0] = _swapOp(edgeKey, false, -1e18); // canonical sell of link1
        ops[1] = _swapOp(sideKey, false, -1e17); // side sell of link1
        ops[2] = _settleAll(edgeKey.currency1);
        ops[3] = _takeAll(edgeKey.currency0, address(this));
        _expectRefused(address(this), address(manager), INBOUND, 1e18);
        this.runOps(ops);
    }

    // =====================================================================================
    // 9. a side swap after a canonical swap is refused beyond the canonical net
    // =====================================================================================

    /// @dev The canonical buy is taken as ERC-6909 claims, so its outbound allowance Y stays open
    /// for the rest of the transaction; a later side buy of Z > Y taken as ERC-20 is refused.
    function test_9_sideSwapAfterACanonicalSwapRefusedBeyondTheNet() public {
        _expectTakeRefused(alice, 1e16);
        this.claimsBuyThenSideBuy();
        assertEq(link1.balanceOf(alice), 0);
    }

    /// @dev A canonical buy of exactly Y link one taken as ERC-6909 claims, then (a second
    /// unlock) a side buy of link one taken as ERC-20 by alice.
    function claimsBuyThenSideBuy() external returns (uint256 y) {
        BalanceDelta d = swapRouter.swap(
            edgeKey,
            SwapParams({zeroForOne: true, amountSpecified: 1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        y = uint256(uint128(d.amount1()));
        (uint256 inBetween, uint256 outBetween) = link1.canonicalAllowance();
        require(inBetween == 0 && outBetween == y, "an open outbound allowance of Y between the unlocks");
        Op[] memory ops = new Op[](3);
        ops[0] = _swapOp(sideKey, true, -1e18);
        ops[1] = _settleAll(sideKey.currency0);
        ops[2] = _takeAll(sideKey.currency1, alice);
        _run(ops);
    }

    /// @dev The two directions are separate allowances: an inbound canonical allowance (a sell
    /// whose input is netted against a side buy instead of paid, so its inbound room stays
    /// open) does not let the side buy's take out; the take is refused against the OUTBOUND
    /// allowance, which is zero.
    function test_9_canonicalSellDoesNotExemptASideBuy() public {
        Op[] memory ops = new Op[](5);
        ops[0] = _swapOp(edgeKey, false, -1e15); // canonical sell: 1e15 of inbound left open
        ops[1] = _swapOp(sideKey, true, -1e18); // side buy of link1 worth far more than 1e15
        ops[2] = _settleAll(sideKey.currency0);
        ops[3] = _takeAll(sideKey.currency0, address(this));
        ops[4] = _takeAll(sideKey.currency1, alice);
        _expectTakeRefused(alice, 0);
        this.runOps(ops);
    }

    /// @dev Directions never offset: a canonical buy and a canonical sell in one unlock, both
    /// kept in the PoolManager's deltas, leave BOTH allowances open (a single counter would have
    /// netted them to their difference).
    function test_9_directionsAreSeparateCounters() public {
        Op[] memory ops = new Op[](5);
        ops[0] = _swapOp(edgeKey, true, 3e17); // canonical buy: exactly 3e17 link1 owed out
        ops[1] = _swapOp(edgeKey, false, -1e18); // canonical sell: exactly 1e18 link1 owed in
        ops[2] = _settleAll(edgeKey.currency1); // pay the 7e17 difference in
        ops[3] = _settleAll(edgeKey.currency0);
        ops[4] = _takeAll(edgeKey.currency0, address(this));
        (uint256 inA, uint256 outA) = this.runOpsAndReadAllowance(ops);
        assertEq(inA, 1e18 - 7e17, "inbound: 1e18 credited, 7e17 spent");
        assertEq(outA, 3e17, "outbound: 3e17 credited, nothing spent");
    }

    /// @notice THE RESIDUAL, pinned rather than hidden. A copy pool already seeded (see setUp:
    /// funded by a canonical buy's delta, so no link one moved) can still be USED by a contract
    /// that wraps its side trade in canonical trades with claims-based settlement, inside ONE
    /// unlock:
    ///   1. canonical buy of exactly z link one (outbound allowance +z), kept as ERC-6909 claims;
    ///   2. side buy of z' <= z link one on the copy pool (no credit);
    ///   3. take z' out of the PoolManager: spends z' of the canonical allowance, so it passes;
    ///   4. burn the z claims and sell exactly z link one canonically (inbound credit -z);
    ///   5. settle the $DOLL.
    /// What that costs is the canonical round trip on z: two canonical legs, i.e. 2x the hop fee
    /// (plus, on an edge pool like this one, 2x the 1% protocol fee) on z >= z', plus the copy
    /// pool's own LP fee - never cheaper than trading canonically. The allowances left open
    /// (inbound z, outbound z - z') are transient and die with the transaction; each is canonical
    /// volume that paid the fee. A plain user's buy on the same pool, with no canonical trade
    /// around it, is refused.
    function test_sandwichCanStillUseASeededCopyPool() public {
        uint256 z = 1e18;
        uint256 zSide = 5e17;
        uint256 supply = link1.totalSupply();
        uint256 dollBefore = doll.balanceOf(address(this));
        Op[] memory ops = new Op[](8);
        ops[0] = _swapOp(edgeKey, true, int256(z)); // canonical buy, exact out z
        ops[1] = _mintAll(edgeKey.currency1); // ... kept as claims
        ops[2] = _swapOp(sideKey, true, int256(zSide)); // side buy, exact out z'
        ops[3] = _take(sideKey.currency1, alice, zSide); // take z' within the allowance
        ops[4] = _burn(edgeKey.currency1, z); // the claims back into the delta
        ops[5] = _swapOp(edgeKey, false, -int256(z)); // canonical sell, exact in z
        ops[6] = _settleAll(edgeKey.currency0); // $DOLL
        ops[7] = _takeAll(edgeKey.currency0, address(this));
        // external, so the allowance is read in the same call frame as the unlock (forge does
        // not carry transient storage from one top-level test call into the next)
        (uint256 inAfter, uint256 outAfter) = this.runOpsAndReadAllowance(ops);
        assertEq(uint256(uint128(swapDeltas[0].amount1())), z, "canonical buy of exactly z");
        assertEq(uint256(uint128(swapDeltas[1].amount1())), zSide, "side buy of exactly z'");
        assertEq(link1.balanceOf(alice), zSide, "the sandwiched side buy arrived whole");
        assertEq(link1.totalSupply(), supply, "nothing was charged");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(link1)))), 0, "the claims were burned");
        assertEq(inAfter, z, "the canonical sell's inbound z is left open (paid by burning claims)");
        assertEq(outAfter, z - zSide, "the canonical buy's outbound z less the take of z'");
        // the price of the sandwich: the canonical round trip on z, net of the side pool's buy
        uint256 sideCost = uint256(uint128(-swapDeltas[1].amount0()));
        uint256 roundTrip = dollBefore - doll.balanceOf(address(this)) - sideCost;
        emit log_named_uint("canonical round-trip cost on z ($DOLL wei)", roundTrip);
        uint256 zValue = uint256(uint128(-swapDeltas[0].amount0()));
        assertGe(roundTrip, 2 * zValue * _hopFeePpm() / 1_000_000 * 99 / 100, "at least ~2x hop fee on z");

        // a plain user's buy on the same seeded pool is refused
        doll.transfer(bob, 10e18);
        vm.startPrank(bob);
        doll.approve(address(swapRouter), type(uint256).max);
        _expectTakeRefused(bob);
        _swapVia(swapRouter, sideKey, true, -1e17);
        vm.stopPrank();
        assertEq(link1.balanceOf(bob), 0);
    }

    // =====================================================================================
    // 13. a leftover in one direction never blocks a canonical leg in the other
    // =====================================================================================

    /// @dev A 1-wei canonical buy kept as ERC-6909 claims earlier in the same unlock leaves 1 wei
    /// of OUTBOUND allowance unused; a later canonical sell still pays its whole input in. (A
    /// single netted counter left only 1e18 - 1 of inbound room and refused the payment whole.)
    function test_13_outboundLeftoverDoesNotBlockALaterCanonicalSell() public {
        Op[] memory ops = new Op[](6);
        ops[0] = _swapOp(edgeKey, true, 1); // canonical buy, exactly 1 wei of link1 out
        ops[1] = _mintAll(edgeKey.currency1); // ... kept as claims: 1 wei of outbound left open
        ops[2] = _swapOp(edgeKey, false, -1e18); // canonical sell, exact in 1e18
        ops[3] = _settleAll(edgeKey.currency1); // pay the whole 1e18 in
        ops[4] = _settleAll(edgeKey.currency0); // net $DOLL: one of these two is a no-op
        ops[5] = _takeAll(edgeKey.currency0, address(this));
        (uint256 inA, uint256 outA) = this.runOpsAndReadAllowance(ops);
        assertEq(inA, 0, "the sell's inbound allowance is spent");
        assertEq(outA, 1, "the 1-wei leftover is still open");
        assertEq(manager.balanceOf(address(this), uint256(uint160(address(link1)))), 1, "the claim is held");
    }

    /// @dev The mirror: a canonical sell whose debt is 1 wei short of paid by transfer (1 wei of
    /// it netted by a 1-wei side buy) leaves 1 wei of INBOUND allowance; a later canonical buy
    /// still takes its whole output out.
    function test_13_inboundLeftoverDoesNotBlockALaterCanonicalBuy() public {
        Op[] memory ops = new Op[](7);
        ops[0] = _swapOp(edgeKey, false, -1e18); // canonical sell, exact in 1e18
        ops[1] = _swapOp(sideKey, true, 1); // side buy of exactly 1 wei: nets 1 wei of that debt
        ops[2] = _settleAll(edgeKey.currency1); // pay 1e18 - 1 in: 1 wei of inbound left open
        ops[3] = _swapOp(edgeKey, true, -1e18); // canonical buy, exact in 1e18 $DOLL
        ops[4] = _takeAll(edgeKey.currency1, alice); // take the whole output out
        ops[5] = _settleAll(edgeKey.currency0);
        ops[6] = _takeAll(edgeKey.currency0, address(this));
        (uint256 inA, uint256 outA) = this.runOpsAndReadAllowance(ops);
        assertEq(inA, 1, "the 1-wei leftover is still open");
        assertEq(outA, 0, "the buy's whole output went out");
        assertEq(link1.balanceOf(alice), uint256(uint128(swapDeltas[2].amount1())), "the whole output arrived");
    }

    /// @dev A PAY-FIRST sell (the input settled BEFORE the swap, the V4Router `SETTLE` then
    /// `SWAP_EXACT_IN_SINGLE` with an open-delta amount shape) is refused: no canonical swap has
    /// run yet, so there is no inbound allowance (reason 1, available 0). Pinned limitation: a
    /// settler must swap before it pays this coin in.
    function test_13_payFirstSellIsRefused() public {
        Op[] memory ops = new Op[](3);
        ops[0] = _pay(edgeKey.currency1, 1e18); // sync, transfer 1e18 in, settle
        ops[1] = _swapOp(edgeKey, false, -1e18);
        ops[2] = _takeAll(edgeKey.currency0, address(this));
        _expectRefused(address(this), address(manager), INBOUND, 0);
        this.runOps(ops);

        // the same shape through the v4-periphery router: its payment is a `transferFrom`
        // whose revert the router's SafeTransferLib reports as TRANSFER_FROM_FAILED
        MockV4Router r = new MockV4Router(IPoolManager(address(manager)));
        link1.approve(address(r), type(uint256).max);
        Currency c1 = Currency.wrap(address(link1));
        Currency cDoll = Currency.wrap(address(doll));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(c1, uint256(1e18), true); // SETTLE: the trader pays 1e18 first
        // OPEN_DELTA (0): swap whatever credit is open
        params[1] = abi.encode(IV4Router.ExactInputSingleParams(edgeKey, false, 0, 0, 0, ""));
        params[2] = abi.encode(cDoll, uint256(0));
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        r.executeActions(
            abi.encode(abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL)), params)
        );
    }

    // =====================================================================================
    // 14. residuals, pinned rather than hidden
    // =====================================================================================

    /// @dev ERC-6909 claims (F1b). A canonical buy taken as claims moves no ERC-20, so it leaves
    /// its outbound allowance unused and nothing reverts. Claims are a balance INSIDE the
    /// PoolManager: they trade on the hookless copy pool by burn and mint alone, with no ERC-20
    /// transfer for the lock to see, so that works. What the lock still holds is the exit: turning
    /// claims into ERC-20 beyond the outbound allowance is refused.
    function test_14_claimsTradeOnAHooklessPoolButCannotExitBeyondTheAllowance() public {
        uint256 id1 = uint256(uint160(address(link1)));
        uint256 dollBefore = doll.balanceOf(address(this));
        (uint256 outBetween, uint256 dollOut) = this.claimsBuyThenClaimsSideSell(1e17);
        assertEq(outBetween, 1e17, "the claims buy left its outbound allowance unused");
        assertGt(dollOut, 0, "the claims sold on the hookless pool");
        assertEq(manager.balanceOf(address(this), id1), 0, "every claim was sold");
        assertLt(doll.balanceOf(address(this)), dollBefore, "the round trip cost $DOLL");

        // claims bought on the hookless pool itself: no canonical leg, no allowance, no ERC-20
        Op[] memory ops = new Op[](3);
        ops[0] = _swapOp(sideKey, true, -1e18); // side buy, link1 out
        ops[1] = _mintAll(sideKey.currency1); // kept as claims
        ops[2] = _settleAll(sideKey.currency0);
        this.runOps(ops);
        uint256 held = manager.balanceOf(address(this), id1);
        assertGt(held, 0, "claims held from the hookless pool");

        // ... but they cannot leave as ERC-20 beyond the outbound allowance
        (, uint256 outNow) = link1.canonicalAllowance();
        assertLt(outNow, held);
        ops = new Op[](2);
        ops[0] = _burn(sideKey.currency1, held);
        ops[1] = _takeAll(sideKey.currency1, alice);
        _expectTakeRefused(alice, outNow);
        this.runOps(ops);
        assertEq(link1.balanceOf(alice), 0);
    }

    /// @dev A canonical exact-out buy of `y` link one kept as claims (PoolSwapTest takeClaims),
    /// then an unlock that burns those claims and sells them on the hookless pool for $DOLL.
    function claimsBuyThenClaimsSideSell(uint256 y) external returns (uint256 outBetween, uint256 dollOut) {
        swapRouter.swap(
            edgeKey,
            SwapParams({zeroForOne: true, amountSpecified: int256(y), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        (, outBetween) = link1.canonicalAllowance();
        Op[] memory ops = new Op[](3);
        ops[0] = _burn(sideKey.currency1, y);
        ops[1] = _swapOp(sideKey, false, -int256(y)); // side sell of the claims
        ops[2] = _takeAll(sideKey.currency0, address(this));
        _run(ops);
        dollOut = uint256(uint128(swapDeltas[0].amount0()));
    }

    /// @dev A pool shaped with `tokenA()` / `tokenB()` (F1a): the probe asks only `token0()` /
    /// `token1()`, so such a pool is NOT recognised and transfers into and out of it pass. The
    /// lock covers the v2, v3 and v4 shapes; a contract with other getters is a wallet to it.
    function test_14_aTokenATokenBShapedPoolIsNotCaught() public {
        MockAbPair pair = new MockAbPair(address(link1), address(doll));
        link1.transfer(address(pair), 10e18);
        assertEq(link1.balanceOf(address(pair)), 10e18, "in: not refused");
        pair.send(address(link1), bob, 4e18);
        assertEq(link1.balanceOf(bob), 4e18, "out: not refused");
    }

    // =====================================================================================
    // 10. Locker placement, FeeVault redemption and bid flows are untouched
    // =====================================================================================

    function test_10_lockerVaultAndBidFlowsUntaxed() public {
        // Locker placement: a fresh candidate's whole supply goes into its pool (the Locker
        // burns only its own rounding dust, which stays with it: nothing is charged)
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        assertEq(IERC20(c.token).balanceOf(address(manager)), IERC20(c.token).totalSupply(), "all placed");
        assertLt(link1.TOTAL_SUPPLY() - IERC20(c.token).totalSupply(), 1e6, "only the rounding dust burned");

        // trade link two's pool so the vault earns link-one hop fees as claims
        _warmOracles();
        familyRouter.buyExactIn(2, 2 ether, 0, address(this), 2);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, 0.2 ether, 0, address(this), 2);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));

        (uint256 s1, uint256 s2) = _supplies();
        // FeeVault.redeem: PoolManager -> vault
        uint256 claims = manager.balanceOf(address(vault), uint256(uint160(address(link1))));
        assertGt(claims, 0, "the vault holds link-one claims");
        uint256 vaultBefore = link1.balanceOf(address(vault));
        vault.redeem(Currency.wrap(address(link1)));
        assertEq(link1.balanceOf(address(vault)) - vaultBefore, claims, "redeemed in full");

        // the keeper's hop-pot bid: vault -> BidDeployer -> Locker -> PoolManager, bounty out
        address keeper = address(0xBEEF);
        vm.prank(keeper);
        (uint256 deposited, uint256 bounty) = bidDeployer.deployHopPot(2);
        assertGt(deposited, 0);
        assertEq(link1.balanceOf(keeper), bounty, "the bounty arrives whole");
        _assertUnchanged(s1, s2);
    }

    // =====================================================================================
    // 11. a starved probe reverts instead of passing a pool off as a wallet
    // =====================================================================================

    function test_11_probeGasStarvationReverts() public {
        MockV2Pair pair = new MockV2Pair(address(link1), address(doll));
        link1.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(FamilyToken.ProbeGasShort.selector);
        link1.transfer{gas: 14_000}(address(pair), 1e18);

        // with gas to spare the same transfer is simply refused as a pool transfer
        vm.prank(alice);
        _expectRefused(alice, address(pair), POOL);
        link1.transfer(address(pair), 1e18);
    }

    // =====================================================================================
    // 12. the factory refuses an implementation built for another stack
    // =====================================================================================

    function test_12_factoryRejectsAMismatchedImplementation() public {
        for (uint256 field = 0; field < 4; field++) {
            address predictedFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            FactorySpec memory sp;
            sp.router = address(swapRouter);
            sp.steward = steward;
            address hookAddress;
            (hookAddress, sp.salt) = _mineHook(predictedFactory, address(swapRouter));
            address lockerAddress = vm.computeCreateAddress(predictedFactory, 1);
            sp.tokenImplementation = address(
                new FamilyToken(
                    predictedFactory,
                    field == 0 ? address(0xBAD) : address(manager),
                    field == 1 ? address(0xBAD) : hookAddress,
                    field == 2 ? address(0xBAD) : lockerAddress,
                    field == 3 ? address(0xBAD) : feeVault
                )
            );
            FamilyFactory f = _newFactory(sp);
            assertEq(address(f), address(0), "refused");
            assertEq(lastFactoryError, FamilyFactory.BadTokenImplementation.selector, "for the implementation");
        }
    }

    // =====================================================================================
    // gas
    // =====================================================================================

    function test_gas_walletTransfer() public {
        link1.transfer(alice, 10e18);
        vm.prank(alice);
        uint256 g = gasleft();
        link1.transfer(bob, 1e18);
        emit log_named_uint("wallet-to-wallet transfer gas", g - gasleft());
    }

    function test_gas_canonicalSwap() public {
        uint256 g = gasleft();
        _swapVia(swapRouter, link2Key, true, -1e18);
        emit log_named_uint("canonical exact-in swap (PoolSwapTest, family parent) gas", g - gasleft());
    }

    // =====================================================================================
    // helpers
    // =====================================================================================

    function _supplies() internal view returns (uint256, uint256) {
        return (link1.totalSupply(), link2.totalSupply());
    }

    function _assertUnchanged(uint256 s1, uint256 s2) internal view {
        assertEq(link1.totalSupply(), s1, "link one supply unchanged");
        assertEq(link2.totalSupply(), s2, "link two supply unchanged");
        _assertNoAllowance(link1, "no allowance left open (link one)");
        _assertNoAllowance(link2, "no allowance left open (link two)");
    }

    function _assertNoAllowance(FamilyToken t, string memory why) internal view {
        (uint256 inA, uint256 outA) = t.canonicalAllowance();
        assertEq(inA, 0, why);
        assertEq(outA, 0, why);
    }

    /// @dev The next call reverts with link one's `NonCanonicalVenue(from, to, reason, 0)`, raw
    /// (a direct transfer, or a settle's payment, which the PoolManager does not wrap).
    function _expectRefused(address from, address to, uint8 reason) internal {
        _expectRefused(from, to, reason, 0);
    }

    function _expectRefused(address from, address to, uint8 reason, uint256 available) internal {
        vm.expectRevert(abi.encodeWithSelector(FamilyToken.NonCanonicalVenue.selector, from, to, reason, available));
    }

    /// @dev The next call reverts on a PoolManager `take` of link one to `to`: the PoolManager
    /// wraps the token's `NonCanonicalVenue(manager, to, 2, available)` in an ERC-7751
    /// `WrappedError`.
    function _expectTakeRefused(address to) internal {
        _expectTakeRefused(to, 0);
    }

    function _expectTakeRefused(address to, uint256 available) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(link1),
                IERC20Minimal.transfer.selector,
                abi.encodeWithSelector(FamilyToken.NonCanonicalVenue.selector, address(manager), to, OUTBOUND, available),
                abi.encodePacked(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
    }

    function _swapVia(PoolSwapTest r, PoolKey memory k, bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return r.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---- the v4-periphery router ----

    function _v4InSingle(MockV4Router r, PoolKey memory k, bool zeroForOne, uint128 amountIn, Currency cin, Currency cout)
        internal
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(k, zeroForOne, amountIn, 0, 0, ""));
        params[1] = abi.encode(cin, type(uint256).max);
        params[2] = abi.encode(cout, uint256(0));
        r.executeActions(
            abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params)
        );
    }

    function _v4OutSingle(MockV4Router r, PoolKey memory k, bool zeroForOne, uint128 amountOut, Currency cin, Currency cout)
        internal
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactOutputSingleParams(k, zeroForOne, amountOut, type(uint128).max, 0, ""));
        params[1] = abi.encode(cin, type(uint256).max);
        params[2] = abi.encode(cout, uint256(amountOut));
        r.executeActions(
            abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params)
        );
    }

    function _v4InPath(MockV4Router r, Currency cin, PathKey[] memory path, uint128 amountIn, Currency cout) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputParams(cin, path, new uint256[](0), amountIn, 0));
        params[1] = abi.encode(cin, type(uint256).max);
        params[2] = abi.encode(cout, uint256(0));
        r.executeActions(
            abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_IN), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params)
        );
    }

    function _v4OutPath(MockV4Router r, Currency cout, PathKey[] memory path, uint128 amountOut, Currency cin) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactOutputParams(cout, path, new uint256[](0), amountOut, type(uint128).max));
        params[1] = abi.encode(cin, type(uint256).max);
        params[2] = abi.encode(cout, uint256(amountOut));
        r.executeActions(
            abi.encode(abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)), params)
        );
    }

    /// @dev A two-hop path through `mid` (pool `k1`) to `last` (pool `k2`).
    function _path(Currency mid, PoolKey memory k1, Currency last, PoolKey memory k2)
        internal
        pure
        returns (PathKey[] memory p)
    {
        p = new PathKey[](2);
        p[0] = PathKey(mid, k1.fee, k1.tickSpacing, k1.hooks, "");
        p[1] = PathKey(last, k2.fee, k2.tickSpacing, k2.hooks, "");
    }

    function _deployZap() internal returns (EthZap) {
        PoolKey memory venue = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(doll)),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        (uint160 p,,,) = im.getSlot0(venue.toId());
        if (p == 0) {
            vm.deal(address(this), 10_000 ether);
            manager.initialize(venue, TickMath.getSqrtPriceAtTick(69000));
            liquidityRouter.modifyLiquidity{value: 5_000 ether}(
                venue,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(200),
                    tickUpper: TickMath.maxUsableTick(200),
                    liquidityDelta: int256(31_623e18),
                    salt: 0
                }),
                ""
            );
        }
        return new EthZap(familyRouter, venue);
    }

    // ---- a scriptable unlock: the test contract is its own router ----

    enum Kind {
        SWAP,
        SETTLE_ALL,
        TAKE_ALL,
        LIQ,
        TAKE,
        COVER,
        MINT_ALL,
        BURN,
        PAY
    }

    struct Op {
        Kind kind;
        PoolKey key;
        bool zeroForOne;
        int256 amount;
        Currency c;
        address to;
    }

    BalanceDelta[] internal swapDeltas;

    function _run(Op[] memory ops) internal {
        delete swapDeltas;
        manager.unlock(abi.encode(ops));
    }

    /// @dev Run `ops`, then read link one's canonical allowance (inbound, outbound) within the
    /// same call.
    function runOpsAndReadAllowance(Op[] memory ops) external returns (uint256, uint256) {
        _run(ops);
        return link1.canonicalAllowance();
    }

    /// @dev External, so a test can `expectRevert` on the whole unlock.
    function runOps(Op[] memory ops) external {
        _run(ops);
    }

    function _swapOp(PoolKey memory k, bool zeroForOne, int256 amount) internal pure returns (Op memory o) {
        o.kind = Kind.SWAP;
        o.key = k;
        o.zeroForOne = zeroForOne;
        o.amount = amount;
    }

    function _settleAll(Currency c) internal pure returns (Op memory o) {
        o.kind = Kind.SETTLE_ALL;
        o.c = c;
    }

    function _takeAll(Currency c, address to) internal pure returns (Op memory o) {
        o.kind = Kind.TAKE_ALL;
        o.c = c;
        o.to = to;
    }

    function _take(Currency c, address to, uint256 amount) internal pure returns (Op memory o) {
        o.kind = Kind.TAKE;
        o.c = c;
        o.to = to;
        o.amount = int256(amount);
    }

    function _liq(PoolKey memory k, int256 liquidity) internal pure returns (Op memory o) {
        o.kind = Kind.LIQ;
        o.key = k;
        o.amount = liquidity;
    }

    /// @dev An exact-output swap in pool `k` for exactly what this contract owes in `c`.
    function _cover(PoolKey memory k, bool zeroForOne, Currency c) internal pure returns (Op memory o) {
        o.kind = Kind.COVER;
        o.key = k;
        o.zeroForOne = zeroForOne;
        o.c = c;
    }

    /// @dev Keep this contract's whole credit in `c` as ERC-6909 claims.
    function _mintAll(Currency c) internal pure returns (Op memory o) {
        o.kind = Kind.MINT_ALL;
        o.c = c;
    }

    /// @dev Pay `amount` of `c` into the PoolManager (sync, transfer, settle) whatever is owed.
    function _pay(Currency c, uint256 amount) internal pure returns (Op memory o) {
        o.kind = Kind.PAY;
        o.c = c;
        o.amount = int256(amount);
    }

    /// @dev Burn `amount` of this contract's ERC-6909 claims in `c` back into its delta.
    function _burn(Currency c, uint256 amount) internal pure returns (Op memory o) {
        o.kind = Kind.BURN;
        o.c = c;
        o.amount = int256(amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the manager");
        Op[] memory ops = abi.decode(data, (Op[]));
        for (uint256 i = 0; i < ops.length; i++) {
            Op memory o = ops[i];
            if (o.kind == Kind.SWAP || o.kind == Kind.COVER) {
                int256 amount = o.amount;
                if (o.kind == Kind.COVER) {
                    int256 owed = im.currencyDelta(address(this), o.c);
                    if (owed >= 0) continue;
                    amount = -owed; // exact output
                }
                swapDeltas.push(
                    manager.swap(
                        o.key,
                        SwapParams({
                            zeroForOne: o.zeroForOne,
                            amountSpecified: amount,
                            sqrtPriceLimitX96: o.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                        }),
                        ""
                    )
                );
            } else if (o.kind == Kind.TAKE) {
                manager.take(o.c, o.to, uint256(o.amount));
            } else if (o.kind == Kind.PAY) {
                manager.sync(o.c);
                IERC20(Currency.unwrap(o.c)).transfer(address(manager), uint256(o.amount));
                manager.settle();
            } else if (o.kind == Kind.BURN) {
                manager.burn(address(this), o.c.toId(), uint256(o.amount));
            } else if (o.kind == Kind.LIQ) {
                manager.modifyLiquidity(
                    o.key,
                    ModifyLiquidityParams({
                        tickLower: TickMath.minUsableTick(o.key.tickSpacing),
                        tickUpper: TickMath.maxUsableTick(o.key.tickSpacing),
                        liquidityDelta: o.amount,
                        salt: 0
                    }),
                    ""
                );
            } else {
                int256 d = im.currencyDelta(address(this), o.c);
                if (o.kind == Kind.TAKE_ALL) {
                    if (d > 0) manager.take(o.c, o.to, uint256(d));
                } else if (o.kind == Kind.MINT_ALL) {
                    if (d > 0) manager.mint(address(this), o.c.toId(), uint256(d));
                } else if (d < 0) {
                    manager.sync(o.c);
                    IERC20(Currency.unwrap(o.c)).transfer(address(manager), uint256(-d));
                    manager.settle();
                }
            }
        }
        return "";
    }
}

/// @notice The successor resolution (design risk 2): a continuation stack's hook credits a
/// PRIOR version's token once the registry chain has handed over to it, and that stack's Locker
/// and FeeVault are exempt endpoints - so the successor's pools are canonical, not side pools.
contract VenueLockContinuationTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;
    address internal constant STEWARD = address(0x57E4A2D);

    Stack internal v1;
    Stack internal v2;
    FamilyToken internal link1;

    function setUp() public {
        steward = STEWARD;
        _setUpEdge();
        v1 = _currentStack();
        link1 = FamilyToken(address(token));
        v2 = _deployStack(true, STEWARD, address(v1.roundManager));
        _useStack(v2);
    }

    function test_successorStackIsCanonicalForPriorTokens() public {
        // before the handover the successor is a stranger
        assertFalse(link1.isCanonicalHook(address(v2.hook)), "no handover yet");
        vm.prank(address(v2.hook));
        vm.expectRevert(FamilyToken.NotHook.selector);
        link1.creditCanonical(1);

        vm.prank(STEWARD);
        v1.roundManager.announceSunset(address(v2.roundManager));
        vm.warp(v1.roundManager.sunsetAt());
        assertTrue(link1.isCanonicalHook(address(v2.hook)), "resolved through the registry chain");
        assertTrue(link1.isCanonicalHook(address(v1.hook)), "the own hook stays canonical");
        assertFalse(link1.isCanonicalHook(address(v2.router)), "only the successor's hook");

        // a v2 round quoted in v1's link one: registration, the curve, trading
        uint256 supply = link1.totalSupply();
        address link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(link1.totalSupply(), supply, "v2's canonical pools are not refused for v1's token");
        assertEq(link1.successorRole(address(v2.hook)), 1, "the hook is cached at registration");
        assertEq(link1.successorRole(address(v2.locker)), 2, "its Locker is an endpoint");
        assertEq(link1.successorRole(address(v2.vault)), 2, "its FeeVault is an endpoint");
        assertEq(v2.hook.creditMask(v2.roundManager.poolKeyOf(2).toId()), 3, "both sides credited");

        // routed through v2 and back
        IERC20(link2).approve(address(v2.router), type(uint256).max);
        uint256 out = v2.router.buyExactIn(2, 1 ether, 0, address(this), 3);
        v2.router.sellExactIn(2, out, 0, address(this), 3);
        assertEq(link1.totalSupply(), supply, "cross-version route untouched");

        // v2's vault redeems its link-one claims
        uint256 claims = manager.balanceOf(address(v2.vault), uint256(uint160(address(link1))));
        assertGt(claims, 0);
        uint256 before = link1.balanceOf(address(v2.vault));
        v2.vault.redeem(Currency.wrap(address(link1)));
        assertEq(link1.balanceOf(address(v2.vault)) - before, claims, "redeemed in full");
        assertEq(link1.totalSupply(), supply);
        _assertNoAllowance();
    }

    /// @dev THE STEWARD TRUST PATH (F5), pinned. A hostile successor named in a sunset notice
    /// that has run its notice period resolves like any other: its "hook" may credit this token
    /// and whatever it lists as Locker or FeeVault - here a v2 pair of link one - becomes an
    /// exempt endpoint, so the pair is no longer refused. The exposure is the venue lock alone,
    /// public for the whole notice period, and logged ({SuccessorTrusted}).
    function test_hostileSuccessorMakesAPairAnExemptEndpoint() public {
        MockV2Pair pair = new MockV2Pair(address(link1), address(doll));
        HostileSuccessor h = new HostileSuccessor(address(v1.roundManager), address(manager), address(pair));
        address alice = makeAddr("alice");
        deal(address(link1), alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FamilyToken.NonCanonicalVenue.selector, alice, address(pair), 3, 0));
        link1.transfer(address(pair), 1e18);

        vm.prank(STEWARD);
        v1.roundManager.announceSunset(address(h));
        vm.warp(v1.roundManager.sunsetAt());
        vm.expectEmit(true, false, false, true, address(link1));
        emit FamilyToken.SuccessorTrusted(address(h), address(pair), address(pair));
        assertTrue(h.accept(link1), "the hostile hook is accepted");
        assertEq(link1.successorRole(address(h)), 1, "its hook may credit");
        assertEq(link1.successorRole(address(pair)), 2, "the pair is an exempt endpoint");

        vm.prank(alice);
        link1.transfer(address(pair), 1e18);
        assertEq(link1.balanceOf(address(pair)), 1e18, "into the pair: let through");
        pair.send(address(link1), alice, 1e18);
        assertEq(link1.balanceOf(alice), 10e18, "out of the pair: let through");

        (, uint256 outA) = h.credit(link1, 5e18);
        assertEq(outA, 5e18, "its hook opens PoolManager allowance");
    }

    function _assertNoAllowance() internal view {
        (uint256 inA, uint256 outA) = link1.canonicalAllowance();
        assertEq(inA, 0, "no inbound allowance left open");
        assertEq(outA, 0, "no outbound allowance left open");
    }
}
