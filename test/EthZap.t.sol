// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BaseTestHooks} from "v4-core/src/test/BaseTestHooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {EthZap} from "../contracts/EthZap.sol";

/// @dev Stand-in for the graduated venue's hook: afterSwap + afterSwapReturnDelta, taking 2% of
/// the unspecified (output) currency (a 1% fee plus a 1% creator tax, as the launch venue does).
/// `physical` selects how the cut leaves the swapper's delta: `take` of the real currency into the
/// hook (as the launch venue does), or ERC-6909 claims minted to the hook.
contract MockVenueHook is BaseTestHooks {
    IPoolManager public immutable manager;
    bool public immutable physical;

    constructor(IPoolManager _manager, bool _physical) {
        manager = _manager;
        physical = _physical;
    }

    /// @dev The physical variant receives native ETH from the PoolManager.
    receive() external payable {}

    function afterSwap(address, PoolKey calldata k, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        if (unspecified <= 0) return (IHooks.afterSwap.selector, 0);
        uint256 u = uint256(uint128(unspecified));
        uint256 fee = u / 100 + u / 100; // 1% fee + 1% creator tax
        Currency c = specifiedIs0 ? k.currency1 : k.currency0;
        if (fee != 0) {
            if (physical) manager.take(c, address(this), fee);
            else manager.mint(address(this), uint256(uint160(Currency.unwrap(c))), fee);
        }
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }
}

/// @dev A contract payer that tries to re-enter the zap from inside its buy-side ETH refund.
contract ReentrantBuyer {
    EthZap public zap;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    constructor(EthZap _zap) {
        zap = _zap;
    }

    function buy(uint256 target) external payable returns (uint256) {
        return zap.buyWithEth{value: msg.value}(target, 1, address(this), target, block.timestamp);
    }

    receive() external payable {
        if (msg.sender != address(zap) || attempted) return;
        attempted = true;
        try zap.buyWithEth{value: msg.value}(1, 0, address(this), 1, block.timestamp) returns (uint256) {
            reentered = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }
}

/// @dev Forces ETH into an address that refuses plain sends.
contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev Tries to re-enter the zap from inside its ETH receipt and records what happened.
contract ReentrantReceiver {
    EthZap public zap;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    constructor(EthZap _zap) {
        zap = _zap;
    }

    receive() external payable {
        if (msg.sender != address(zap) || attempted) return;
        attempted = true;
        try zap.buyWithEth{value: msg.value}(1, 0, address(this), 1, block.timestamp) returns (uint256) {
            reentered = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @notice The native-ETH zap: venue leg in its own unlock, family legs through the unchanged
/// router, attribution intact, and nothing left behind in the zap after any call.
contract EthZapTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;
    uint256 internal constant CAND_ATTR = 1 << 255;

    address internal link1;
    address internal link2;
    Cand internal cand;

    MockVenueHook internal venueHook; // claims variant
    MockVenueHook internal takeHook; // physical-take variant
    PoolKey internal hookedKey;
    PoolKey internal takeKey;
    PoolKey internal plainKey;
    PoolKey internal tinyKey;
    PoolKey internal richKey;

    EthZap internal zap; // hooked venue, cut minted as claims
    EthZap internal zapTake; // hooked venue, cut physically taken: the launch shape
    EthZap internal zapPlain; // hookless venue
    EthZap internal zapTiny; // narrow single-range venue: the price limit binds
    EthZap internal zapRich; // very deep $DOLL: overfills link one's curve

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpEdge();
        link1 = roundManager.canonical(1);
        link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 2);

        // an open round with one candidate, trading, quoted in link two
        cand = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        vm.deal(address(this), 1e7 ether);
        doll.mint(address(this), 3e12 ether);

        // the venue hook, mined onto its permission bits
        uint160 flags = Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(address(manager), false);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), flags, type(MockVenueHook).creationCode, args);
        venueHook = new MockVenueHook{salt: salt}(IPoolManager(address(manager)), false);
        assertEq(address(venueHook), predicted);
        args = abi.encode(address(manager), true);
        (predicted, salt) = HookMiner.find(address(this), flags, type(MockVenueHook).creationCode, args);
        takeHook = new MockVenueHook{salt: salt}(IPoolManager(address(manager)), true);
        assertEq(address(takeHook), predicted);

        // ~1000 $DOLL per ETH, full range, ~1000 ETH deep
        hookedKey = _venue(200, address(venueHook));
        _fullRange(hookedKey, TickMath.getSqrtPriceAtTick(69000), 31_623e18);
        takeKey = _venue(200, address(takeHook));
        _fullRange(takeKey, TickMath.getSqrtPriceAtTick(69000), 31_623e18);
        plainKey = _venue(200, address(0));
        _fullRange(plainKey, TickMath.getSqrtPriceAtTick(69000), 31_623e18);
        // one 10-tick range holding a few thousandths of an ETH
        tinyKey = _venue(10, address(0));
        manager.initialize(tinyKey, TickMath.getSqrtPriceAtTick(69005));
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            tinyKey, ModifyLiquidityParams({tickLower: 69000, tickUpper: 69010, liquidityDelta: 1e21, salt: 0}), ""
        );
        // ~1e9 $DOLL per ETH, ~2e12 $DOLL deep
        richKey = _venue(20, address(0));
        _fullRange(richKey, TickMath.getSqrtPriceAtTick(207200), 6.3e25);

        zap = new EthZap(familyRouter, hookedKey);
        zapTake = new EthZap(familyRouter, takeKey);
        zapPlain = new EthZap(familyRouter, plainKey);
        zapTiny = new EthZap(familyRouter, tinyKey);
        zapRich = new EthZap(familyRouter, richKey);

        vm.deal(alice, 1e5 ether);
        vm.startPrank(alice);
        address[5] memory zs =
            [address(zap), address(zapTake), address(zapPlain), address(zapTiny), address(zapRich)];
        for (uint256 i = 0; i < 5; i++) {
            IERC20(link1).approve(zs[i], type(uint256).max);
            IERC20(link2).approve(zs[i], type(uint256).max);
            IERC20(cand.token).approve(zs[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------

    function _venue(int24 spacing, address hooks) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(doll)),
            fee: 0,
            tickSpacing: spacing,
            hooks: IHooks(hooks)
        });
    }

    function _fullRange(PoolKey memory k, uint160 sqrtPrice, uint256 liquidity) internal {
        manager.initialize(k, sqrtPrice);
        liquidityRouter.modifyLiquidity{value: 5_000 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(k.tickSpacing),
                tickUpper: TickMath.maxUsableTick(k.tickSpacing),
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );
    }

    /// @dev The negative invariant: no ETH, no $DOLL, no link coin, no router allowance.
    function _assertClean(EthZap z) internal view {
        assertEq(address(z).balance, 0, "zap holds ETH");
        address[4] memory ts = [address(doll), link1, link2, cand.token];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(IERC20(ts[i]).balanceOf(address(z)), 0, "zap holds a token");
            assertEq(IERC20(ts[i]).allowance(address(z), address(familyRouter)), 0, "zap left an allowance");
        }
        assertEq(address(familyRouter).balance, 0, "router holds ETH");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "router holds $DOLL");
    }

    function _assertAllZapsClean() internal view {
        _assertClean(zap);
        _assertClean(zapTake);
        _assertClean(zapPlain);
        _assertClean(zapTiny);
        _assertClean(zapRich);
        _assertNoEth();
    }

    /// @dev Every FeeAccrued in `logs` came from a router swap carrying `attribution`; returns
    /// how many there were.
    function _assertAttributed(Vm.Log[] memory logs, uint256 attribution) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != IFamilyHook.FeeAccrued.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(familyRouter), "sender is the router");
            (,, uint256 attr) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(attr, attribution, "terminal attribution");
            n++;
        }
    }

    function _buy(EthZap z, uint256 target, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(alice);
        out = z.buyWithEth{value: ethIn}(target, 1, alice, target, block.timestamp);
    }

    // -------------------------------------------------------------------------------------
    // happy paths
    // -------------------------------------------------------------------------------------

    function test_buyLinkOne_hookedVenue_attributed() public {
        uint256 ethBefore = alice.balance;
        uint256 hookClaimsBefore = manager.balanceOf(address(venueHook), uint256(uint160(address(doll))));
        vm.recordLogs();
        uint256 out = _buy(zap, 1, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(out, 0);
        assertEq(IERC20(link1).balanceOf(alice), out, "delivered to `to`");
        assertEq(ethBefore - alice.balance, 1 ether, "full fill spends exactly msg.value");
        assertGt(
            manager.balanceOf(address(venueHook), uint256(uint160(address(doll)))), hookClaimsBefore, "venue hook took its cut"
        );
        assertEq(_assertAttributed(logs, 1), 1, "one family hop, attributed to link one");
        _assertAllZapsClean();
    }

    function test_buyAndSellDeeperLink_hookedVenue() public {
        vm.recordLogs();
        uint256 out = _buy(zap, 2, 2 ether);
        assertEq(_assertAttributed(vm.getRecordedLogs(), 2), 2, "two hops, both attributed to link two");
        assertEq(IERC20(link2).balanceOf(alice), out);
        _assertAllZapsClean();

        uint256 ethBefore = alice.balance;
        uint256 hookEthBefore = manager.balanceOf(address(venueHook), 0);
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zap.sellForEth(2, out, 1, alice, 2, block.timestamp);
        assertEq(_assertAttributed(vm.getRecordedLogs(), 2), 2, "sell hops attributed to link two");
        assertGt(ethOut, 0);
        assertLt(ethOut, 2 ether, "round trip loses fees");
        assertEq(alice.balance - ethBefore, ethOut, "ETH delivered");
        assertEq(IERC20(link2).balanceOf(alice), 0);
        assertGt(manager.balanceOf(address(venueHook), 0), hookEthBefore, "venue hook took its ETH cut");
        _assertAllZapsClean();
    }

    function test_sellLinkOne_toAnotherRecipient() public {
        uint256 out = _buy(zapTake, 1, 1 ether);
        vm.prank(alice);
        uint256 ethOut = zapTake.sellForEth(1, out, 1, bob, 1, block.timestamp);
        assertEq(bob.balance, ethOut, "bob receives the ETH");
        _assertAllZapsClean();
    }

    /// @notice The launch shape: the venue hook physically takes its 2% in the real currency.
    function test_takeHookVenue_buyAndSell() public {
        uint256 hookDollBefore = doll.balanceOf(address(takeHook));
        vm.recordLogs();
        uint256 out = _buy(zapTake, 2, 2 ether);
        assertEq(_assertAttributed(vm.getRecordedLogs(), 2), 2, "two hops, both attributed to link two");
        assertGt(doll.balanceOf(address(takeHook)), hookDollBefore, "hook took $DOLL on the buy");
        _assertAllZapsClean();

        uint256 ethBefore = alice.balance;
        uint256 hookEthBefore = address(takeHook).balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zapTake.sellForEth(2, out, 1, alice, 2, block.timestamp);
        assertEq(_assertAttributed(vm.getRecordedLogs(), 2), 2, "sell hops attributed to link two");
        assertEq(alice.balance - ethBefore, ethOut, "ETH delivered");
        assertLt(ethOut, 2 ether, "round trip loses fees");
        uint256 hookCut = address(takeHook).balance - hookEthBefore;
        assertGt(hookCut, 0, "hook took ETH on the sell");
        // 2% of the gross output: cut / (ethOut + cut) is 2%, to rounding
        assertApproxEqRel(hookCut * 50, ethOut + hookCut, 0.01e18, "2% of the output");
        _assertAllZapsClean();
    }

    function test_hooklessVenue_buyAndSell() public {
        uint256 out = _buy(zapPlain, 1, 1 ether);
        assertGt(out, 0);
        vm.prank(alice);
        uint256 ethOut = zapPlain.sellForEth(1, out, 1, alice, 1, block.timestamp);
        assertGt(ethOut, 0);
        _assertAllZapsClean();
    }

    function test_candidate_buyAndSell_attributed() public {
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zap.buyCandidateWithEth{value: 1 ether}(cand.id, 1, alice, 3, block.timestamp);
        assertEq(_assertAttributed(vm.getRecordedLogs(), CAND_ATTR | cand.id), 3, "three hops to the candidate");
        assertEq(IERC20(cand.token).balanceOf(alice), out);
        _assertAllZapsClean();

        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zap.sellCandidateForEth(cand.id, out, 1, alice, 3, block.timestamp);
        assertEq(_assertAttributed(vm.getRecordedLogs(), CAND_ATTR | cand.id), 3, "three hops back");
        assertEq(alice.balance - ethBefore, ethOut);
        _assertAllZapsClean();
    }

    function test_eventsCarryPathAndMidLeg() public {
        vm.recordLogs();
        uint256 out = _buy(zap, 1, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(zap) || logs[i].topics[0] != EthZap.EthBuy.selector) continue;
            (bool candidate, uint256 ethIn, uint256 refunded, uint256 dollMid, uint256 dollRefunded, uint256 o) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
            assertFalse(candidate);
            assertEq(ethIn, 1 ether);
            assertEq(refunded, 0);
            assertGt(dollMid, 0);
            assertEq(dollRefunded, 0, "a full fill leaves no $DOLL");
            assertEq(o, out);
            assertEq(uint256(logs[i].topics[3]), 1);
            seen = true;
        }
        assertTrue(seen, "EthBuy emitted");
    }

    // -------------------------------------------------------------------------------------
    // slippage and deadline
    // -------------------------------------------------------------------------------------

    function test_minOutReverts() public {
        vm.prank(alice);
        vm.expectPartialRevert(FamilyRouter.InsufficientOutput.selector, address(familyRouter));
        zap.buyWithEth{value: 1 ether}(1, type(uint256).max, alice, 1, block.timestamp);
    }

    function test_minEthOutReverts() public {
        uint256 out = _buy(zap, 1, 1 ether);
        vm.prank(alice);
        vm.expectPartialRevert(EthZap.InsufficientOutput.selector, address(zap));
        zap.sellForEth(1, out, 10 ether, alice, 1, block.timestamp);
    }

    function test_deadlineReverts() public {
        uint256 past = block.timestamp - 1;
        vm.startPrank(alice);
        vm.expectRevert(EthZap.Expired.selector);
        zap.buyWithEth{value: 1 ether}(1, 0, alice, 1, past);
        vm.expectRevert(EthZap.Expired.selector);
        zap.buyCandidateWithEth{value: 1 ether}(cand.id, 0, alice, 3, past);
        vm.expectRevert(EthZap.Expired.selector);
        zap.sellForEth(1, 1, 0, alice, 1, past);
        vm.expectRevert(EthZap.Expired.selector);
        zap.sellCandidateForEth(cand.id, 1, 0, alice, 3, past);
        vm.stopPrank();
    }

    function test_zeroValueAndBadRecipientRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(EthZap.NothingIn.selector);
        zap.buyWithEth(1, 0, alice, 1, block.timestamp);
        vm.expectRevert(EthZap.InvalidRecipient.selector);
        zap.buyWithEth{value: 1 ether}(1, 0, address(zap), 1, block.timestamp);
        vm.expectRevert(EthZap.InvalidRecipient.selector);
        zap.sellForEth(1, 1, 0, address(0), 1, block.timestamp);
        vm.stopPrank();
    }

    function test_nothingInOnSellsReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(EthZap.NothingIn.selector, address(zap));
        zap.sellForEth(1, 0, 0, alice, 1, block.timestamp);
        vm.expectRevert(EthZap.NothingIn.selector, address(zap));
        zap.sellCandidateForEth(cand.id, 0, 0, alice, 3, block.timestamp);
        vm.expectRevert(EthZap.NothingIn.selector, address(zap));
        zap.buyCandidateWithEth(cand.id, 0, alice, 3, block.timestamp);
        vm.stopPrank();
    }

    function test_invalidRecipientOnCandidateCallsReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(EthZap.InvalidRecipient.selector, address(zap));
        zap.buyCandidateWithEth{value: 1 ether}(cand.id, 0, address(0), 3, block.timestamp);
        vm.expectRevert(EthZap.InvalidRecipient.selector, address(zap));
        zap.buyCandidateWithEth{value: 1 ether}(cand.id, 0, address(zap), 3, block.timestamp);
        vm.expectRevert(EthZap.InvalidRecipient.selector, address(zap));
        zap.sellCandidateForEth(cand.id, 1, 0, address(0), 3, block.timestamp);
        vm.expectRevert(EthZap.InvalidRecipient.selector, address(zap));
        zap.sellCandidateForEth(cand.id, 1, 0, address(zap), 3, block.timestamp);
        vm.stopPrank();
    }

    function test_unknownCandidateReverts() public {
        uint256 bad = roundManager.candidateCount();
        vm.startPrank(alice);
        vm.expectRevert(EthZap.UnknownCandidate.selector, address(zap));
        zap.buyCandidateWithEth{value: 1 ether}(bad, 0, alice, 3, block.timestamp);
        vm.expectRevert(EthZap.UnknownCandidate.selector, address(zap));
        zap.sellCandidateForEth(bad, 1, 0, alice, 3, block.timestamp);
        vm.stopPrank();
    }

    /// @notice Index 0 ($DOLL itself) and an index past the head are refused by the zap before any
    /// venue swap: the venue pool is untouched.
    function test_unknownIndexRevertsBeforeVenueSwap() public {
        PoolId id = hookedKey.toId();
        (uint160 priceBefore,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
        vm.startPrank(alice);
        vm.expectRevert(EthZap.UnknownIndex.selector, address(zap));
        zap.buyWithEth{value: 1 ether}(0, 0, alice, 1, block.timestamp);
        vm.expectRevert(EthZap.UnknownIndex.selector, address(zap));
        zap.buyWithEth{value: 1 ether}(99, 0, alice, 99, block.timestamp);
        vm.expectRevert(EthZap.UnknownIndex.selector, address(zap));
        zap.sellForEth(0, 1, 0, alice, 1, block.timestamp);
        vm.expectRevert(EthZap.UnknownIndex.selector, address(zap));
        zap.sellForEth(99, 1, 0, alice, 99, block.timestamp);
        vm.stopPrank();

        // the early revert never opened an unlock: a call that did would have to swap first
        vm.recordLogs();
        vm.prank(alice);
        try zap.buyWithEth{value: 1 ether}(0, 0, alice, 1, block.timestamp) returns (uint256) {
            fail();
        } catch (bytes memory r) {
            assertEq(bytes4(r), EthZap.UnknownIndex.selector);
        }
        assertEq(vm.getRecordedLogs().length, 0, "no swap event: the venue was never touched");
        (uint160 priceAfter,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
        assertEq(priceAfter, priceBefore);
    }

    /// @notice A venue leg that produces no $DOLL (dust into a pool priced far below one wei of
    /// $DOLL per wei of ETH), and a route that produces no $DOLL (one wei of link coin).
    function test_nothingOutReverts() public {
        PoolKey memory dustKey = _venue(30, address(0));
        manager.initialize(dustKey, TickMath.getSqrtPriceAtTick(-200010));
        liquidityRouter.modifyLiquidity{value: 5_000 ether}(
            dustKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(30),
                tickUpper: TickMath.maxUsableTick(30),
                liquidityDelta: 1e15,
                salt: 0
            }),
            ""
        );
        EthZap zapDust = new EthZap(familyRouter, dustKey);
        vm.prank(alice);
        vm.expectRevert(EthZap.NothingOut.selector, address(zapDust));
        zapDust.buyWithEth{value: 1}(1, 0, alice, 1, block.timestamp);

        _buy(zap, 1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EthZap.NothingOut.selector, address(zap));
        zap.sellForEth(1, 1, 0, alice, 1, block.timestamp);
    }

    // -------------------------------------------------------------------------------------
    // partial fills and refunds
    // -------------------------------------------------------------------------------------

    struct BuyLog {
        bool seen;
        uint256 ethRefunded;
        uint256 dollMid;
        uint256 dollRefunded;
        uint256 out;
    }

    struct SellLog {
        bool seen;
        uint256 coinRefunded;
        uint256 dollMid;
        uint256 dollSpent;
        uint256 dollRefunded;
        uint256 ethOut;
    }

    function _buyLog(Vm.Log[] memory logs, EthZap z) internal pure returns (BuyLog memory b) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(z) || logs[i].topics[0] != EthZap.EthBuy.selector) continue;
            b.seen = true;
            (, , b.ethRefunded, b.dollMid, b.dollRefunded, b.out) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256));
        }
    }

    function _sellLog(Vm.Log[] memory logs, EthZap z) internal pure returns (SellLog memory s) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(z) || logs[i].topics[0] != EthZap.EthSell.selector) continue;
            s.seen = true;
            (, , s.coinRefunded, s.dollMid, s.dollSpent, s.dollRefunded, s.ethOut) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256, uint256));
        }
    }

    /// @dev Sum of `IntermediateReturned(token, to, _)` amounts the zap emitted.
    function _intermediateReturned(Vm.Log[] memory logs, EthZap z, address token, address to)
        internal
        pure
        returns (uint256 sum)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(z) || logs[i].topics[0] != EthZap.IntermediateReturned.selector) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != token) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != to) continue;
            sum += abi.decode(logs[i].data, (uint256));
        }
    }

    /// @dev $DOLL moved `from` -> `to`, summed over ERC-20 Transfer logs.
    function _dollTransferred(Vm.Log[] memory logs, address from, address to) internal view returns (uint256 sum) {
        bytes32 sig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(doll) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != from) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != to) continue;
            sum += abi.decode(logs[i].data, (uint256));
        }
    }

    /// @dev Drain link one's pool of $DOLL, then put a sliver back: the next link-one -> $DOLL leg
    /// fills only partly and leaves a link-one residue.
    function _drainLinkOnePool() internal {
        deal(link1, address(this), 500_000_000 ether);
        plainRouter.swap(
            roundManager.poolKeyOf(1),
            SwapParams({zeroForOne: false, amountSpecified: -500_000_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        familyRouter.buyExactIn(1, 1e15, 0, address(this), 1);
    }

    function test_partialEthFill_refundsEth() public {
        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        uint256 out = _buy(zapTiny, 1, 1 ether);
        BuyLog memory b = _buyLog(vm.getRecordedLogs(), zapTiny);
        uint256 spent = ethBefore - alice.balance;
        assertGt(out, 0);
        assertGt(spent, 0, "some ETH was absorbed");
        assertLt(spent, 0.01 ether, "the rest came back");
        assertEq(b.ethRefunded, 1 ether - spent, "event carries the ETH refund");
        _assertAllZapsClean();
    }

    /// @notice A full fill: the router spent every $DOLL the venue produced.
    function test_dollMidEqualsRouterSpend_fullFill() public {
        vm.recordLogs();
        _buy(zap, 1, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BuyLog memory b = _buyLog(logs, zap);
        uint256 spend = _dollTransferred(logs, address(zap), address(manager));
        assertEq(b.dollRefunded, 0);
        assertEq(b.dollMid, spend + b.dollRefunded, "dollMid == router spend + refund");
    }

    function test_leftoverDollOnBuy_goesToRecipient() public {
        // ~2e10 $DOLL: more than link one's curve can absorb
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zapRich.buyWithEth{value: 20 ether}(1, 1, alice, 1, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BuyLog memory b = _buyLog(logs, zapRich);
        assertGt(out, 0);
        assertGt(b.dollRefunded, 0, "partial fill reported");
        assertEq(doll.balanceOf(alice), b.dollRefunded, "unabsorbed $DOLL went to `to`");
        uint256 spend = _dollTransferred(logs, address(zapRich), address(manager));
        assertGt(spend, 0);
        assertEq(b.dollMid, spend + b.dollRefunded, "dollMid == router spend + refund");
        _assertAllZapsClean();
    }

    function test_leftoverDollOnSell_goesToRecipient() public {
        uint256 out = _buy(zap, 1, 1 ether);
        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zapTiny.sellForEth(1, out, 0, alice, 1, block.timestamp);
        SellLog memory s = _sellLog(vm.getRecordedLogs(), zapTiny);
        assertGt(s.dollRefunded, 0, "venue could not absorb all $DOLL");
        assertEq(s.dollMid, s.dollSpent + s.dollRefunded);
        assertEq(doll.balanceOf(alice), s.dollRefunded, "rest went to `to`");
        assertEq(s.ethOut, ethOut);
        assertEq(alice.balance - ethBefore, ethOut);
        _assertAllZapsClean();
    }

    function test_leftoverLinkCoinOnSell_isRefunded() public {
        uint256 huge = 500_000_000 ether;
        deal(link1, alice, huge);
        uint256 supply = IERC20(link1).totalSupply();
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zapTake.sellForEth(1, huge, 1, alice, 1, block.timestamp);
        SellLog memory s = _sellLog(vm.getRecordedLogs(), zapTake);
        assertGt(ethOut, 0);
        uint256 back = IERC20(link1).balanceOf(alice);
        assertGt(back, 0, "unspent link coin returned");
        assertLt(back, huge, "some was sold");
        assertEq(s.coinRefunded, back, "event carries the coin refund");
        // the partial canonical fill and the zap's refund to the payer pass the venue lock untaxed
        assertEq(IERC20(link1).totalSupply(), supply, "partial fill and refund untaxed");
        _assertAllZapsClean();
    }

    /// @notice A partially filled MIDDLE leg: the router sweeps that link's residue to `to`,
    /// which on a sell is the zap; the zap must pass it on.
    function test_intermediateResidueOnSell_isReturned() public {
        uint256 out = _buy(zapTake, 2, 10 ether);
        _drainLinkOnePool();

        uint256 link1Before = IERC20(link1).balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        zapTake.sellForEth(2, out, 0, alice, 2, block.timestamp);
        uint256 residue = IERC20(link1).balanceOf(alice) - link1Before;
        assertGt(residue, 0, "middle-leg residue returned");
        assertEq(_intermediateReturned(vm.getRecordedLogs(), zapTake, link1, alice), residue, "event carries it");
        _assertAllZapsClean();
    }

    // candidate routes ---------------------------------------------------------------------

    function test_candidateBuy_partialEthFill_refundsEth() public {
        uint256 ethBefore = alice.balance;
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zapTiny.buyCandidateWithEth{value: 1 ether}(cand.id, 1, alice, 3, block.timestamp);
        BuyLog memory b = _buyLog(vm.getRecordedLogs(), zapTiny);
        uint256 spent = ethBefore - alice.balance;
        assertGt(out, 0);
        assertEq(IERC20(cand.token).balanceOf(alice), out);
        assertLt(spent, 0.01 ether, "the rest came back");
        assertEq(b.ethRefunded, 1 ether - spent);
        _assertAllZapsClean();
    }

    function test_candidateBuy_leftoverDoll_goesToRecipient() public {
        vm.recordLogs();
        vm.prank(alice);
        uint256 out = zapRich.buyCandidateWithEth{value: 20 ether}(cand.id, 1, alice, 3, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        BuyLog memory b = _buyLog(logs, zapRich);
        assertGt(out, 0);
        assertGt(b.dollRefunded, 0, "partial first leg");
        assertEq(doll.balanceOf(alice), b.dollRefunded, "unabsorbed $DOLL went to `to`");
        assertEq(b.dollMid, _dollTransferred(logs, address(zapRich), address(manager)) + b.dollRefunded);
        _assertAllZapsClean();
    }

    function test_candidateSell_leftoverCoin_isRefunded() public {
        // give the candidate pool some link two to pay out, then sell far more than it holds
        vm.prank(alice);
        zap.buyCandidateWithEth{value: 1 ether}(cand.id, 1, alice, 3, block.timestamp);
        uint256 huge = 500_000_000 ether;
        deal(cand.token, alice, huge);
        vm.recordLogs();
        vm.prank(alice);
        uint256 ethOut = zapTake.sellCandidateForEth(cand.id, huge, 0, alice, 3, block.timestamp);
        SellLog memory s = _sellLog(vm.getRecordedLogs(), zapTake);
        assertGt(ethOut, 0);
        uint256 back = IERC20(cand.token).balanceOf(alice);
        assertGt(back, 0, "unspent candidate returned");
        assertLt(back, huge, "some was sold");
        assertEq(s.coinRefunded, back);
        _assertAllZapsClean();
    }

    function test_candidateSell_intermediateResidue_isReturned() public {
        vm.prank(alice);
        uint256 out = zapTake.buyCandidateWithEth{value: 10 ether}(cand.id, 1, alice, 3, block.timestamp);
        _drainLinkOnePool();

        uint256 link1Before = IERC20(link1).balanceOf(alice);
        vm.recordLogs();
        vm.prank(alice);
        zapTake.sellCandidateForEth(cand.id, out, 0, alice, 3, block.timestamp);
        uint256 residue = IERC20(link1).balanceOf(alice) - link1Before;
        assertGt(residue, 0, "middle-leg residue returned");
        assertEq(_intermediateReturned(vm.getRecordedLogs(), zapTake, link1, alice), residue);
        _assertAllZapsClean();
    }

    function test_candidateSell_leftoverDoll_goesToRecipient() public {
        vm.prank(alice);
        uint256 out = zap.buyCandidateWithEth{value: 1 ether}(cand.id, 1, alice, 3, block.timestamp);
        vm.recordLogs();
        vm.prank(alice);
        zapTiny.sellCandidateForEth(cand.id, out, 0, alice, 3, block.timestamp);
        SellLog memory s = _sellLog(vm.getRecordedLogs(), zapTiny);
        assertGt(s.dollRefunded, 0);
        assertEq(s.dollMid, s.dollSpent + s.dollRefunded);
        assertEq(doll.balanceOf(alice), s.dollRefunded);
        _assertAllZapsClean();
    }

    // leftover recipients with msg.sender != to --------------------------------------------

    /// @notice Unconverted input (ETH on a buy) returns to the payer, not to `to`.
    function test_leftoverRule_unspentEthToSender() public {
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        uint256 out = zapTiny.buyWithEth{value: 1 ether}(1, 1, bob, 1, block.timestamp);
        assertEq(IERC20(link1).balanceOf(bob), out, "bob gets the link");
        assertEq(bob.balance, 0, "bob gets no ETH");
        assertLt(aliceBefore - alice.balance, 0.01 ether, "alice got the unspent ETH back");
        _assertAllZapsClean();
    }

    /// @notice $DOLL produced from the payer's ETH but not absorbed goes to `to`.
    function test_leftoverRule_buyDollToRecipient() public {
        vm.prank(alice);
        zapRich.buyWithEth{value: 20 ether}(1, 1, bob, 1, block.timestamp);
        assertGt(doll.balanceOf(bob), 0, "bob gets the $DOLL");
        assertEq(doll.balanceOf(alice), 0, "alice gets none");
        _assertAllZapsClean();
    }

    /// @notice Unconverted input (link coin the router did not pull) returns to the payer.
    function test_leftoverRule_unpulledCoinToSender() public {
        uint256 huge = 500_000_000 ether;
        deal(link1, alice, huge);
        vm.prank(alice);
        uint256 ethOut = zapTake.sellForEth(1, huge, 1, bob, 1, block.timestamp);
        assertEq(bob.balance, ethOut);
        assertGt(IERC20(link1).balanceOf(alice), 0, "alice gets the unpulled coin back");
        assertEq(IERC20(link1).balanceOf(bob), 0, "bob gets none");
        _assertAllZapsClean();
    }

    /// @notice A middle link's residue was produced from the payer's coin: it goes to `to`.
    function test_leftoverRule_intermediateToRecipient() public {
        uint256 out = _buy(zapTake, 2, 10 ether);
        _drainLinkOnePool();
        uint256 aliceLink1 = IERC20(link1).balanceOf(alice);
        vm.prank(alice);
        zapTake.sellForEth(2, out, 0, bob, 2, block.timestamp);
        assertGt(IERC20(link1).balanceOf(bob), 0, "bob gets the residue");
        assertEq(IERC20(link1).balanceOf(alice), aliceLink1, "alice gets none");
        _assertAllZapsClean();
    }

    /// @notice $DOLL the venue could not absorb on a sell goes to `to`.
    function test_leftoverRule_sellDollToRecipient() public {
        uint256 out = _buy(zap, 1, 1 ether);
        vm.prank(alice);
        uint256 ethOut = zapTiny.sellForEth(1, out, 0, bob, 1, block.timestamp);
        assertEq(bob.balance, ethOut);
        assertGt(doll.balanceOf(bob), 0, "bob gets the $DOLL");
        assertEq(doll.balanceOf(alice), 0, "alice gets none");
        _assertAllZapsClean();
    }

    // donations ------------------------------------------------------------------------------

    /// @notice ETH forced in and tokens sent directly are never counted: they stay put, and a
    /// user's buy and sell come out exactly as they would without them.
    function test_donationsStayPutAndDoNotAffectCalls() public {
        uint256 snap = vm.snapshotState();
        (uint256 outClean, uint256 ethOutClean, uint256 aliceEthClean) = _roundTripLinkTwo();
        vm.revertToState(snap);

        new ForceSend{value: 3 ether}(payable(address(zapTake)));
        doll.transfer(address(zapTake), 1_000e18);
        deal(link1, address(this), 2e18);
        IERC20(link1).transfer(address(zapTake), 1e18);
        deal(link2, address(this), 2e18);
        IERC20(link2).transfer(address(zapTake), 1e18);
        assertEq(address(zapTake).balance, 3 ether, "forced ETH landed");

        (uint256 out, uint256 ethOut, uint256 aliceEth) = _roundTripLinkTwo();
        assertEq(out, outClean, "buy unaffected");
        assertEq(ethOut, ethOutClean, "sell unaffected");
        assertEq(aliceEth, aliceEthClean, "payer unaffected");
        assertEq(address(zapTake).balance, 3 ether, "forced ETH stays put");
        assertEq(doll.balanceOf(address(zapTake)), 1_000e18, "$DOLL stays put");
        assertEq(IERC20(link1).balanceOf(address(zapTake)), 1e18, "intermediate link stays put");
        assertEq(IERC20(link2).balanceOf(address(zapTake)), 1e18, "sold link stays put");
    }

    /// @dev Buy link two with ETH, drain link one so the sell leaves a middle residue, sell back.
    function _roundTripLinkTwo() internal returns (uint256 out, uint256 ethOut, uint256 aliceEth) {
        out = _buy(zapTake, 2, 10 ether);
        _drainLinkOnePool();
        vm.prank(alice);
        ethOut = zapTake.sellForEth(2, out, 0, alice, 2, block.timestamp);
        aliceEth = alice.balance;
    }

    // -------------------------------------------------------------------------------------
    // access and reentrancy
    // -------------------------------------------------------------------------------------

    function test_plainEthSendReverts() public {
        (bool ok,) = address(zap).call{value: 1}("");
        assertFalse(ok, "plain ETH refused");
        vm.deal(address(manager), 1 ether);
        vm.prank(address(manager));
        (ok,) = address(zap).call{value: 1}("");
        assertTrue(ok, "PoolManager may send");
    }

    function test_unlockCallbackOnlyFromOwnUnlock() public {
        vm.expectRevert(EthZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(true, uint256(1)));
        vm.prank(address(manager));
        vm.expectRevert(EthZap.NotPoolManager.selector);
        zap.unlockCallback(abi.encode(true, uint256(1)));
    }

    function test_reentrantRecipientCannotReenter() public {
        ReentrantReceiver r = new ReentrantReceiver(zap);
        uint256 out = _buy(zap, 1, 1 ether);
        vm.prank(alice);
        uint256 ethOut = zap.sellForEth(1, out, 1, address(r), 1, block.timestamp);
        assertTrue(r.attempted());
        assertFalse(r.reentered(), "re-entry refused");
        assertEq(bytes4(r.reason()), EthZap.Reentrancy.selector);
        assertEq(address(r).balance, ethOut);
        _assertAllZapsClean();
    }

    /// @notice A contract payer re-entering from inside its buy-side ETH refund is refused, and
    /// still receives the refund and its link.
    function test_reentrantPayerOnBuyRefundCannotReenter() public {
        ReentrantBuyer b = new ReentrantBuyer(zapTiny);
        uint256 out = b.buy{value: 1 ether}(1);
        assertTrue(b.attempted(), "the refund reached the payer");
        assertFalse(b.reentered(), "re-entry refused");
        assertEq(bytes4(b.reason()), EthZap.Reentrancy.selector);
        assertGt(address(b).balance, 0.99 ether, "refund kept");
        assertEq(IERC20(link1).balanceOf(address(b)), out);
        _assertAllZapsClean();
    }

    function test_revertingReceiverReverts() public {
        RevertingReceiver r = new RevertingReceiver();
        uint256 out = _buy(zap, 1, 1 ether);
        vm.prank(alice);
        vm.expectRevert(EthZap.EthTransferFailed.selector);
        zap.sellForEth(1, out, 1, address(r), 1, block.timestamp);
    }

    // -------------------------------------------------------------------------------------
    // constructor
    // -------------------------------------------------------------------------------------

    function test_constructorRejectsBadKeys() public {
        PoolKey memory k = hookedKey;
        k.currency0 = Currency.wrap(address(1));
        vm.expectRevert(EthZap.VenueNotNative.selector);
        new EthZap(familyRouter, k);

        k = hookedKey;
        k.currency1 = Currency.wrap(link1);
        vm.expectRevert(EthZap.VenueNotEdgeCurrency.selector);
        new EthZap(familyRouter, k);

        k = _venue(60, address(0));
        vm.expectRevert(EthZap.VenueNotInitialized.selector);
        new EthZap(familyRouter, k);

        manager.initialize(k, TickMath.getSqrtPriceAtTick(69000));
        vm.expectRevert(EthZap.VenueNoLiquidity.selector);
        new EthZap(familyRouter, k);
    }

    function test_venueViews() public view {
        assertEq(PoolId.unwrap(zap.venuePoolId()), PoolId.unwrap(hookedKey.toId()));
        assertEq(address(zap.poolManager()), address(manager));
        assertEq(address(zap.doll()), address(doll));
        assertLt(address(zap).code.length, 24_576, "under the EIP-170 limit");
    }

    function test_codeSize() public {
        emit log_named_uint("EthZap runtime size (bytes)", address(zap).code.length);
    }

    // -------------------------------------------------------------------------------------
    // fuzz
    // -------------------------------------------------------------------------------------

    /// @dev route 0: link one; 1: link two; 2: the candidate. `physical` picks the venue hook that
    /// takes its cut in the real currency.
    function testFuzz_roundTrip(uint256 ethIn, uint8 route, bool physical) public {
        ethIn = bound(ethIn, 1e15, 50 ether);
        route = uint8(bound(route, 0, 2));
        EthZap z = physical ? zapTake : zap;
        uint256 ethBefore = alice.balance;
        uint256 out;
        address token;
        if (route == 2) {
            vm.prank(alice);
            out = z.buyCandidateWithEth{value: ethIn}(cand.id, 1, alice, 3, block.timestamp);
            token = cand.token;
        } else {
            out = _buy(z, route + 1, ethIn);
            token = route == 0 ? link1 : link2;
        }
        assertEq(IERC20(token).balanceOf(alice), out);
        _assertAllZapsClean();
        vm.prank(alice);
        if (route == 2) z.sellCandidateForEth(cand.id, out, 0, alice, 3, block.timestamp);
        else z.sellForEth(route + 1, out, 0, alice, route + 1, block.timestamp);
        _assertAllZapsClean();
        assertLt(alice.balance, ethBefore, "a round trip cannot be profitable");
        assertEq(IERC20(token).balanceOf(alice), 0);
    }

    // -------------------------------------------------------------------------------------
    // gas
    // -------------------------------------------------------------------------------------

    function test_gas_buyAndSell() public {
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 out = zap.buyWithEth{value: 1 ether}(1, 1, alice, 1, block.timestamp);
        emit log_named_uint("buyWithEth (venue + 1 family hop) gas", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        zap.sellForEth(1, out, 1, alice, 1, block.timestamp);
        emit log_named_uint("sellForEth (1 family hop + venue) gas", g - gasleft());
    }
}
