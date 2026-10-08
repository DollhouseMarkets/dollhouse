// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FamilyHandler} from "./utils/FamilyHandler.sol";
import {MockVenueOracle} from "./utils/MockVenueOracle.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {VenueOracle} from "../contracts/VenueOracle.sol";
import {IVenueOracle} from "../contracts/interfaces/IVenueOracle.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";

/// @dev A stack whose factory reads a real {VenueOracle} over a real ETH/$DOLL venue pool on the
/// same PoolManager, warmed with 25 hours of keeper pokes.
abstract contract StartAnchorBase is RoundTestBase {
    using StateLibrary for IPoolManager;

    // StartPriced flag bits (FamilyFactory)
    uint16 internal constant F_VENUE_FALLBACK = 1;
    uint16 internal constant F_LINK_YOUNG = 2;
    uint16 internal constant F_CLAMP_LO = 4;
    uint16 internal constant F_CLAMP_HI = 8;
    uint16 internal constant F_WALK_CAPPED = 16;
    uint16 internal constant F_LIMITER = 32;
    uint16 internal constant F_ANCHOR_MISSING = 64;
    uint16 internal constant F_VENUE_STALE_USED = 128;
    uint16 internal constant F_STATUS_STALE = uint16(2) << 8;
    uint16 internal constant F_STATUS_FAST_SHORT = uint16(4) << 8;
    uint16 internal constant F_STATUS_SLOW_SHORT = uint16(8) << 8;
    uint16 internal constant F_ORACLE_FAILED = uint16(16) << 8;

    uint256 internal constant E0 = 5e18;
    uint256 internal constant FALLBACK_DOLL = 3e25;
    /// @dev ~1e7 $DOLL per ETH: E0 is 5e25 $DOLL, 5% of the 1e27 $DOLL supply.
    int24 internal constant VENUE_TICK = 161_160;
    int256 internal constant VENUE_LIQ = 1e22;

    VenueOracle internal oracle;
    PoolKey internal venueKey;
    PoolId internal venueId;
    uint160 internal P0;
    address internal keeper = address(0xBEEF01);
    address internal pokerB = address(0xBEEF02);
    bool internal useVenue = true;

    struct Start {
        bool seen;
        uint256 roundId;
        address parent;
        uint160 sqrtP;
        uint256 doll;
        uint256 cap;
        uint256 basis;
        uint16 flags;
        bool anchorSeen;
        uint256 anchorIndex;
        uint256 anchorUnits;
        uint256 anchorDoll;
    }

    function _beforeStack() internal virtual override {
        if (!useVenue) return;
        venueKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(doll)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        venueId = venueKey.toId();
        P0 = TickMath.getSqrtPriceAtTick(VENUE_TICK);
        im.initialize(venueKey, P0);
        vm.deal(address(this), 1e9 ether);
        doll.approve(address(liquidityRouter), type(uint256).max);
        doll.approve(address(swapRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1e8 ether}(
            venueKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: VENUE_LIQ,
                salt: 0
            }),
            ""
        );
        oracle = new VenueOracle(im, venueKey, keeper, pokerB);
        startOracle = address(oracle);
    }

    function _setUpAnchored() internal {
        startFallbackDoll = FALLBACK_DOLL;
        _setUpFamily();
        vm.deal(address(this), 1e9 ether);
        if (useVenue) _warmVenue();
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _poke() internal {
        vm.prank(keeper);
        oracle.poke();
    }

    /// @dev 50 pokes 30 minutes apart: both rings cover their windows at the seed price.
    function _warmVenue() internal {
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(_now() + 1800);
            _poke();
        }
    }

    /// @dev E0 in $DOLL at venue sqrt price `s`.
    function _dollFor(uint160 s) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(E0, s, FixedPoint96.Q96), s, FixedPoint96.Q96);
    }

    /// @dev Swap the venue: `ethIn` true spends `amount` ETH (pumps $DOLL), false spends `amount`
    /// $DOLL (dumps it).
    function _venueSwap(bool ethIn, uint256 amount) internal {
        swapRouter.swap{value: ethIn ? amount : 0}(
            venueKey,
            SwapParams({
                zeroForOne: ethIn,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _startIn(Vm.Log[] memory logs) internal view returns (Start memory st) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory)) continue;
            if (logs[i].topics[0] == FamilyFactory.AnchorWritten.selector) {
                st.anchorSeen = true;
                st.anchorIndex = uint256(logs[i].topics[1]);
                (st.anchorUnits, st.anchorDoll) = abi.decode(logs[i].data, (uint256, uint256));
                continue;
            }
            if (logs[i].topics[0] != FamilyFactory.StartPriced.selector) continue;
            st.seen = true;
            st.roundId = uint256(logs[i].topics[1]);
            st.parent = address(uint160(uint256(logs[i].topics[2])));
            (st.sqrtP, st.doll, st.cap, st.basis, st.flags) =
                abi.decode(logs[i].data, (uint160, uint256, uint256, uint256, uint16));
        }
    }

    /// @dev `vm.lastCallGas().gasTotalUsed`, read as the raw second return word: the installed
    /// forge binary returns fewer fields than this forge-std's `Vm.Gas` declares.
    function _lastCallGasUsed() internal view returns (uint256 used) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        require(ok && ret.length >= 64, "lastCallGas");
        assembly ("memory-safe") {
            used := mload(add(ret, 0x40))
        }
    }

    /// @dev A test is one transaction, so everything an earlier step touched is warm. Mark every
    /// account a registration reads cold again, so the gas measured is a real transaction's.
    function _coolStack() internal {
        uint256 head = roundManager.headIndex();
        address[] memory accounts = new address[](head + 8);
        accounts[0] = address(factory);
        accounts[1] = address(roundManager);
        accounts[2] = address(hook);
        accounts[3] = address(locker);
        accounts[4] = address(manager);
        accounts[5] = address(doll);
        accounts[6] = factory.tokenImplementation();
        accounts[7] = address(oracle);
        for (uint256 i = 1; i <= head; i++) {
            accounts[7 + i] = roundManager.canonical(i);
        }
        // read everything first: a read after a cool would warm the account again
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] != address(0)) vm.cool(accounts[i]);
        }
    }

    /// @dev Register one candidate; returns it, the gas `registerCandidate` used and the start
    /// it priced (unseen for a sibling, which reuses the round's cached start).
    function _register(string memory name) internal returns (Cand memory c, uint256 gasUsed, Start memory st) {
        address creator = address(uint160(0xC0DE0000 + cands.length + _now()));
        uint256 bond = roundManager.currentBond();
        _fundDoll(creator, bond);
        vm.prank(creator);
        IERC20(address(doll)).approve(address(factory), bond);
        _coolStack();
        vm.recordLogs();
        vm.prank(creator);
        (address t, PoolKey memory k, uint256 id) = factory.registerCandidate(name, name, "", type(uint256).max);
        // the frame's own gas; under `forge test --isolate` the whole transaction's, intrinsic
        // gas included, with every account and slot cold as on chain
        gasUsed = _lastCallGasUsed();
        st = _startIn(vm.getRecordedLogs());
        c = Cand({
            token: t,
            key: k,
            poolId: k.toId(),
            id: id,
            tokenIsCurrency0: Currency.unwrap(k.currency0) == t,
            creator: creator
        });
        cands.push(c);
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        IERC20(t).approve(address(familyRouter), type(uint256).max);
    }

    /// @dev Crown `c` with a buy of `parentIn`, a second dust buy 200 s later (two oracle
    /// entries on the new link), then let an hour pass and poke the venue so the next start has
    /// a fresh oracle and a link with more than {START_LINK_MIN_COVER_S} of history.
    function _win(Cand memory c, uint256 parentIn, bool age) internal {
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(c, true, parentIn);
        vm.warp(tradingStart + 205);
        _tradeCandidate(c, true, parentIn / 1_000_000);
        _settleEnd();
        roundManager.submitScore(c.id);
        if (_now() < submitEnd + 1) vm.warp(submitEnd + 1);
        roundManager.finalize();
        assertEq(roundManager.head(), c.token, "crowned");
        if (age) vm.warp(_now() + 1 hours);
        if (useVenue) _poke();
    }

    /// @dev The buy that lifts a new link to about 4x its start, so the next start (E0) is about a
    /// quarter of its cap: inside the clamps.
    function _pumpFor(Start memory st) internal pure returns (uint256) {
        uint256 amount = (st.cap * 3) / 10;
        return amount < WINNING_ABSORPTION ? WINNING_ABSORPTION : amount;
    }

    /// @dev The $DOLL value of `amount` of generation `j`'s parent, through BidDeployer's own walk
    /// (an independent implementation: min of spot and both averages per link).
    function _dollValue(uint256 j, uint256 amount) internal view returns (uint256 v) {
        (v,) = bidDeployer.dollValueOfParent(j, amount);
    }

    /// @dev The FDV, in parent units, candidate `c`'s pool was initialised at.
    function _openingFdv(Cand memory c) internal view returns (uint256) {
        uint160 init = hook.poolInfo(c.poolId).initSqrtPriceX96;
        return CurveMath.fdvAtSqrtPrice(init, SUPPLY, c.tokenIsCurrency0);
    }
}

/// @notice The ETH-anchored start against a live venue oracle.
contract StartAnchorTest is StartAnchorBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpAnchored();
    }

    /// @notice Link one ($DOLL parent, empty walk) opens at E0: D = E0 * s^2, unclamped, and
    /// the pool's opening FDV is D within one tick spacing.
    function test_link1_opensAtE0() public {
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 0, "warm oracle");
        (Cand memory c,, Start memory st) = _register("L1");
        assertTrue(st.seen, "StartPriced");
        assertEq(st.flags, 0, "no flag: live venue price, unclamped");
        assertEq(st.parent, address(doll));
        assertEq(st.sqrtP, s, "the oracle's start price");
        assertEq(st.doll, _dollFor(s), "D = E0 * s^2");
        assertEq(st.cap, st.doll, "link one: empty walk, cap = D");
        assertEq(factory.startFdvOf(c.token), st.cap, "start FDV = cap");
        assertEq(factory.roundStartFlags(st.roundId), st.flags, "flags stored for readers without logs");
        assertApproxEqRel(_openingFdv(c), st.doll, 0.0061e18, "opens at E0 within one tick spacing");
        // and in ETH: FDV_doll / (s / Q96)^2 is E0
        uint256 fdvEth =
            FullMath.mulDiv(FullMath.mulDiv(_openingFdv(c), FixedPoint96.Q96, s), FixedPoint96.Q96, s);
        assertApproxEqRel(fdvEth, E0, 0.0061e18, "5 ETH");
        (uint256 qCap, uint256 qBasis, uint16 qFlags) = factory.quoteStart(address(doll));
        assertEq(qCap, st.cap, "quoteStart agrees");
        assertEq(qBasis, st.basis);
        assertEq(qFlags, st.flags);
    }

    /// @notice Depths 2 to 8: every link opens at E0 (through the chain's own averages), unclamped.
    function test_depth2to8_openAtE0_whenUnclamped() public {
        (Cand memory c,, Start memory st) = _register("L1");
        _win(c, _pumpFor(st), true);
        for (uint256 j = 2; j <= 8; j++) {
            (c,, st) = _register("LJ");
            assertEq(st.flags, 0, "unclamped, every link mature, live venue");
            // BidDeployer skips the slow average under a day of history; the dust buy keeps them apart by <1e-5
            assertApproxEqRel(_dollValue(j, st.cap), st.doll, 1e13, "cap is worth D $DOLL through the chain");
            assertApproxEqRel(_openingFdv(c), st.cap, 0.0061e18, "the pool opens at the cap within a spacing");
            _win(c, _pumpFor(st), true);
        }
    }

    /// @notice A venue swap of either sign right before registering, in the same transaction,
    /// leaves the round's basis exactly unchanged: the start path never reads spot.
    function test_sameTxVenueSwapLeavesBasis() public {
        uint256 snap = vm.snapshotState();
        (,, Start memory plain) = _register("A");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        _venueSwap(true, 1.5 ether); // pump $DOLL
        (uint160 spot,,,) = im.getSlot0(venueId);
        assertLt(spot, (P0 * 3) / 4, "the venue moved a lot");
        (,, Start memory pumped) = _register("A");
        assertEq(factory.roundCurveBasis(pumped.roundId), plain.basis, "pump: same basis");
        vm.revertToState(snap);

        _venueSwap(false, 5e25); // dump $DOLL
        (spot,,,) = im.getSlot0(venueId);
        assertGt(spot, (P0 * 3) / 2, "the venue moved a lot");
        (,, Start memory dumped) = _register("A");
        assertEq(factory.roundCurveBasis(dumped.roundId), plain.basis, "dump: same basis");
    }

    /// @notice A reverting oracle: registration succeeds on the constant fallback, flagged.
    function test_oracleRevert_fallsBack() public {
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(IVenueOracle.startPrice.selector), "down");
        (,, Start memory st) = _register("A");
        assertEq(st.flags & F_VENUE_FALLBACK, F_VENUE_FALLBACK, "fallback flag");
        assertEq(st.flags & F_ORACLE_FAILED, F_ORACLE_FAILED, "the read failed");
        assertEq(st.doll, FALLBACK_DOLL, "START_FALLBACK_DOLL");
        assertEq(st.sqrtP, 0);
        assertEq(st.cap, FALLBACK_DOLL, "unclamped fallback");
    }

    /// @notice An oracle that burns every unit of gas it is given: the read is capped at
    /// ORACLE_GAS, registration succeeds on the fallback, and the burn costs at most that cap.
    function test_oracleGasBurn_fallsBack() public {
        uint256 snap = vm.snapshotState();
        (, uint256 gasHealthy,) = _register("A");
        vm.revertToState(snap);

        vm.etch(address(oracle), hex"5b5f56"); // JUMPDEST PUSH0 JUMP: loops forever
        (, uint256 gasBurn, Start memory st) = _register("A");
        assertEq(st.flags & F_VENUE_FALLBACK, F_VENUE_FALLBACK, "fallback flag");
        assertEq(st.flags & F_ORACLE_FAILED, F_ORACLE_FAILED, "the read failed");
        assertEq(st.doll, FALLBACK_DOLL);
        assertLt(gasBurn, gasHealthy + factory.ORACLE_GAS() + 50_000, "the burn is capped at ORACLE_GAS");
    }

    /// @notice A link-pool swap of either sign right before registering, in the same
    /// transaction, never lowers the round's basis: the walk reads the hook's averages, whose
    /// spot tail has zero length inside the swap's own second.
    function test_sameTxLinkSwapLeavesBasis() public {
        (Cand memory c,, Start memory st) = _register("L1");
        _win(c, _pumpFor(st), true);

        uint256 snap = vm.snapshotState();
        (,, Start memory plain) = _register("L2");
        assertEq(plain.flags, 0, "a live walk through a mature link");
        vm.revertToState(snap);

        snap = vm.snapshotState();
        uint160 before = _linkSpot(c);
        _tradeCandidate(c, true, _pumpFor(st) * 4); // pump link one against $DOLL
        assertTrue(_linkSpot(c) != before, "the link moved");
        (,, Start memory pumped) = _register("L2");
        assertGe(factory.roundCurveBasis(pumped.roundId), plain.basis, "pump: basis unchanged or higher");
        vm.revertToState(snap);

        uint256 held = IERC20(c.token).balanceOf(address(this));
        _tradeCandidate(c, false, held / 2); // dump link one
        (,, Start memory dumped) = _register("L2");
        assertGe(factory.roundCurveBasis(dumped.roundId), plain.basis, "dump: basis unchanged or higher");
    }

    function _linkSpot(Cand memory c) internal view returns (uint160 s) {
        (s,,,) = im.getSlot0(c.poolId);
    }

    /// @notice The keeper stopped poking two hours ago: the oracle is stale but its averages
    /// are under a day old, so the start uses them, flagged, and not the constant.
    function test_staleOracle_registrationUsesRecentAverage() public {
        vm.warp(_now() + 2 hours);
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 2, "stale only");
        assertGt(s, 0, "the averages up to the last sample");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_STALE_USED | F_STATUS_STALE, "stale averages used, flagged, no fallback");
        assertEq(st.sqrtP, s);
        assertEq(st.doll, _dollFor(s), "D = E0 * s^2 from the stale averages");
        assertTrue(st.doll != FALLBACK_DOLL);
    }

    /// @notice Past STALE_GRACE_S with no poke the averages are too old: the constant applies.
    function test_staleBeyondGrace_constantFallback() public {
        vm.warp(_now() + 1 days + 1);
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 2);
        assertEq(s, 0, "beyond the grace: no price");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_FALLBACK | F_STATUS_STALE, "constant fallback, stale status");
        assertEq(st.sqrtP, 0);
        assertEq(st.doll, FALLBACK_DOLL);
    }

    /// @notice A caller cannot pick a gas limit that starves the oracle read into the fallback
    /// while registration still succeeds: across every limit, a success read the oracle, and
    /// the limits that would starve the read revert the whole call.
    function test_callerStarvedGas_registrationRevertsCleanly() public {
        address creator = address(0xC0FFEE);
        uint256 bond = roundManager.currentBond();
        _fundDoll(creator, bond);
        vm.prank(creator);
        IERC20(address(doll)).approve(address(factory), bond);
        bytes memory data = abi.encodeCall(FamilyFactory.registerCandidate, ("S", "S", "", type(uint256).max));
        uint160 live = _startSqrtP();

        uint256 succeeded;
        uint256 reverted;
        bool guardFired;
        for (uint256 g = 100_000; g <= 8_000_000 && succeeded < 3; g += 20_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            vm.prank(creator);
            (bool ok, bytes memory ret) = address(factory).call{gas: g}(data);
            if (ok) {
                Start memory st = _startIn(vm.getRecordedLogs());
                assertTrue(st.seen, "priced");
                assertEq(st.flags & (F_VENUE_FALLBACK | F_ORACLE_FAILED), 0, "a success always read the oracle");
                assertEq(st.sqrtP, live, "and used its price");
                succeeded++;
            } else {
                reverted++;
                if (ret.length >= 4 && bytes4(ret) == FamilyFactory.OracleGasShort.selector) guardFired = true;
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0, "some limit is enough");
        assertGt(reverted, 0, "some limit is not");
        assertTrue(guardFired, "a limit that reaches the read without enough for it reverts OracleGasShort");
    }

    function _startSqrtP() internal view returns (uint160 s) {
        (s,) = oracle.startPrice();
    }

    /// @notice The bind is once: a second bind, of the same oracle or any other, reverts.
    function test_bindOnce_secondBindReverts() public {
        assertEq(factory.venueOracle(), address(oracle), "bound at deploy");
        vm.expectRevert(FamilyFactory.OracleAlreadyBound.selector);
        factory.bindVenueOracle(address(oracle));
        vm.prank(address(0xBAD));
        vm.expectRevert(FamilyFactory.OracleAlreadyBound.selector);
        factory.bindVenueOracle(address(0x1234));
    }

    /// @notice A $DOLL dump held for more than a day raises both averages; the start is capped
    /// at X of the parent's cap and says so.
    function test_dumpHeld_clampsAtCeiling() public {
        _venueSwap(false, 2.8e26); // ~100x $DOLL per ETH
        for (uint256 i = 0; i < 130; i++) {
            vm.warp(_now() + 1800);
            _poke();
        }
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 0);
        assertGt(s, P0 * 5, "both averages followed the dump");
        (,, Start memory st) = _register("A");
        uint256 supply = doll.totalSupply();
        assertGt(st.doll, (supply * 5_000) / 10_000, "E0 is more than half of $DOLL's cap now");
        assertEq(st.cap, (supply * 5_000) / 10_000, "A = X * Sp");
        assertEq(st.flags, F_CLAMP_HI, "upper clamp flagged");
    }

    /// @notice A $DOLL pump held for an hour moves the fast average and barely the slow one: the
    /// max rule keeps the slow one, so the basis drops by at most the pump's 1 h share of the
    /// 24 h slow window instead of following the pump.
    function test_pumpHeld1h_basisUnchanged() public {
        (, uint256 basisBefore,) = factory.quoteStart(address(doll));
        _venueSwap(true, 1.31 ether); // ~2x $DOLL price
        for (uint256 i = 0; i < 60; i++) {
            vm.warp(_now() + 60);
            _poke();
        }
        (uint160 fast,,) = oracle.consult(3600, false);
        (uint160 slow,,) = oracle.consult(86400, true);
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 0);
        assertLt(fast, (P0 * 85) / 100, "the fast average followed the pump");
        assertEq(s, slow, "max(fast, slow) keeps the slow average");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, 0);
        // a fast-only rule would open at (fast / P0)^2 < 0.73 of the basis
        assertGe(st.basis, (basisBefore * 97) / 100, "within the slow window's 1 h share");
        assertLe(st.basis, basisBefore, "a pump never raises the basis");
    }

    /// @notice Two siblings share one basis and one opening FDV after the venue moved between
    /// their registrations; a fresh quote has moved.
    function test_siblingsShareBasis_afterVenueMove() public {
        (Cand memory a,, Start memory st) = _register("A");
        _venueSwap(false, 5e25);
        vm.warp(_now() + 61);
        _poke();
        vm.warp(_now() + 61);
        _poke();
        (, uint256 quoted,) = factory.quoteStart(address(doll));
        assertTrue(quoted != st.basis, "the start rule would price differently now");
        (Cand memory b,, Start memory sib) = _register("B");
        assertFalse(sib.seen, "the sibling reuses the cached start");
        assertEq(roundManager.roundCount(), st.roundId, "same round");
        assertEq(factory.curveBasisOf(b.token), st.basis, "shared basis");
        assertApproxEqRel(_openingFdv(a), _openingFdv(b), 1e16, "same opening FDV");
    }

    /// @notice A link younger than START_LINK_MIN_COVER_S opens its child at the lower clamp.
    function test_youngLink_lowerClampFlag() public {
        (Cand memory c,, Start memory st) = _register("L1");
        _win(c, _pumpFor(st), false); // no hour of aging: link one has ~20 min of history
        (,, st) = _register("L2");
        uint256 supply = IERC20(roundManager.canonical(1)).totalSupply();
        assertEq(st.flags, F_LINK_YOUNG | F_CLAMP_LO, "young link, lower clamp");
        assertEq(st.cap, (supply * 1e15) / 1e18, "A = Y * Sp");
    }

    /// @notice A parent worth less than E0 / X (link one left at its launch price): the start
    /// would exceed half the parent's cap, so it opens at X * Sp.
    function test_collapsedParent_upperClamp() public {
        (Cand memory c,, Start memory st) = _register("L1");
        _win(c, 2_500_000e18, true); // link one ends ~1.4x its start: E0 is ~70% of its cap
        (,, st) = _register("L2");
        uint256 supply = IERC20(roundManager.canonical(1)).totalSupply();
        assertEq(st.flags, F_CLAMP_HI, "upper clamp");
        assertEq(st.cap, (supply * 5_000) / 10_000, "A = X * Sp");
    }

    /// @notice A parent worth far more than E0 / Y ($DOLL at 1e4 per ETH, a 100,000 ETH cap): the
    /// start would be below a thousandth of the parent, so it opens at Y * Sp.
    function test_valuableParent_lowerClamp() public {
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(IVenueOracle.startPrice.selector),
            abi.encode(uint160(100 * FixedPoint96.Q96), uint8(0))
        );
        (,, Start memory st) = _register("A");
        assertEq(st.doll, 5e22, "E0 at 1e4 $DOLL per ETH");
        assertEq(st.flags, F_CLAMP_LO, "lower clamp");
        assertEq(st.cap, (doll.totalSupply() * 1e15) / 1e18, "A = Y * Sp");
    }

    /// @notice The walk cap. Grown to START_WALK_MAX + 5 links, every link mature: registration
    /// walks at most START_WALK_MAX links, the deep ones from an anchor snapshot, and its gas
    /// stays bounded. Logs the gas at depths 1, 8, 24 and START_WALK_MAX + 5.
    function test_walkCap_gasBounded() public {
        uint256 k = factory.START_WALK_MAX();
        uint256 top = k + 5;
        (Cand memory c, uint256 gasUsed, Start memory st) = _register("L1");
        emit log_named_uint("registerCandidate gas, depth 1", gasUsed);
        _win(c, _pumpFor(st), true);
        uint256 gas24;
        for (uint256 j = 2; j <= top; j++) {
            uint256 anchorTopBefore = factory.anchorTop();
            (c, gasUsed, st) = _register("LJ");
            if (j == 8) emit log_named_uint("registerCandidate gas, depth 8", gasUsed);
            if (j == 24) {
                emit log_named_uint("registerCandidate gas, depth 24", gasUsed);
                gas24 = gasUsed;
            }
            uint256 p = j - 1;
            if (p > k) {
                assertEq(st.flags, F_WALK_CAPPED, "anchor snapshot path, nothing else");
                assertEq(anchorTopBefore, p - k, "started from the anchor K links up");
            } else {
                assertEq(st.flags, 0, "full live walk");
            }
            if (p >= k) {
                assertEq(factory.anchorTop(), p + 1 - k, "anchor recorded for the next round");
                // and logged, so a deep start can be explained from the logs alone
                assertTrue(st.anchorSeen, "AnchorWritten");
                assertEq(st.anchorIndex, p + 1 - k, "AnchorWritten index");
                assertEq(st.anchorUnits, factory.anchorUnits(st.anchorIndex), "AnchorWritten units");
                assertEq(st.anchorDoll, factory.anchorDoll(st.anchorIndex), "AnchorWritten doll");
                assertEq(st.anchorDoll, st.doll, "the anchor holds this round's D");
            } else {
                assertFalse(st.anchorSeen, "no anchor written on a shallow walk");
            }
            if (j == top) {
                emit log_named_uint("registerCandidate gas, depth START_WALK_MAX+5", gasUsed);
                assertLt(gasUsed, 3_000_000, "registration gas bounded at depth");
                assertLt(gasUsed, gas24 + 400_000, "no growth past the cap");
                // the anchor path prices the same as a full walk while the anchored links are quiet
                assertApproxEqRel(_dollValue(j, st.cap), st.doll, 0.02e18, "cap is worth about D");
            }
            _win(c, _pumpFor(st), true);
        }
    }
}

/// @notice A freshly bound oracle in its first day (no 25 h warm-up): the fallback until ten clean
/// minutes, then fast-only (status 8, no fallback flag) unless the seed or a clamp is in the window.
contract StartAnchorFreshOracleTest is StartAnchorBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        startFallbackDoll = FALLBACK_DOLL;
        _setUpFamily();
        vm.deal(address(this), 1e9 ether);
    }

    function _pokes(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(_now() + 60);
            _poke();
        }
    }

    /// @dev Pin the venue spot the oracle reads (slot0) without touching the pool.
    function _setVenueSpot(uint160 p) internal {
        vm.mockCall(
            address(im),
            abi.encodeWithSignature("extsload(bytes32)", StateLibrary._getPoolStateSlot(venueId)),
            abi.encode(bytes32(uint256(p)))
        );
    }

    /// @notice Ten clean minutes past the seed: the start is priced from it, flagged 0x0800 only.
    function test_fastOnlyFlagEmitted() public {
        _pokes(11);
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 8, "slow short");
        assertGt(s, 0, "fast-only price");
        (,, uint16 qFlags) = factory.quoteStart(address(doll));
        assertEq(qFlags & ~F_CLAMP_HI, F_STATUS_SLOW_SHORT, "quoteStart: 0x0800 (or 0x0808)");
        (,, Start memory st) = _register("A");
        assertTrue(st.seen);
        assertEq(st.flags & ~F_CLAMP_HI, F_STATUS_SLOW_SHORT, "fast-only: status 8, no fallback");
        assertEq(st.flags, qFlags, "quoteStart agrees");
        assertEq(st.sqrtP, s);
        assertEq(st.doll, _dollFor(s), "D = E0 * s^2");
        assertTrue(st.doll != FALLBACK_DOLL);
    }

    /// @notice Inside the first window, and at exactly ten minutes (the seed is still the
    /// window's reference entry), starts open on the constant, flagged.
    function test_warmupFirstWindow_fallbackFlagged() public {
        _pokes(5);
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 4 | 8);
        assertEq(s, 0);
        (, uint256 b30, uint16 f30) = factory.quoteStart(address(doll));
        assertEq(f30, F_VENUE_FALLBACK | F_STATUS_FAST_SHORT | F_STATUS_SLOW_SHORT, "5 min: fallback");
        _pokes(5);
        (s, status) = oracle.startPrice();
        assertEq(status, 8, "10 min: fast covered");
        assertEq(s, 0, "the seed is in the window");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_FALLBACK | F_STATUS_SLOW_SHORT, "0x0801: fast-only refused");
        assertEq(st.sqrtP, 0);
        assertEq(st.doll, FALLBACK_DOLL);
        assertEq(st.basis, b30, "the same constant start");
    }

    /// @notice A clamped sample in the last ten minutes refuses fast-only: the constant, flagged
    /// with the limiter and status 8.
    function test_fastOnlyBlockedByLimiter_fallsBack() public {
        _pokes(11);
        (uint160 s,) = oracle.startPrice();
        assertGt(s, 0, "clean window");
        _venueSwap(true, 1.31 ether); // ~2x $DOLL price
        _pokes(1);
        (,, uint32 streak) = oracle.latest();
        assertGt(streak, 0, "clamped");
        uint8 status;
        (s, status) = oracle.startPrice();
        assertEq(status, 8);
        assertEq(s, 0, "a clamp in the window");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_FALLBACK | F_LIMITER | F_STATUS_SLOW_SHORT, "fallback, limiter, status 8");
        assertEq(st.doll, FALLBACK_DOLL);
    }

    /// @notice A $DOLL pump ramped at the limiter's full unclamped rate (2.9% sqrt price a poke)
    /// right after the clean window, then held: max(fast, slow so far) keeps the first-day basis
    /// at least 0.2x the fair one.
    function test_firstDayRamp_basisFloorBound() public {
        _pokes(11);
        (, uint256 fair, uint16 f0) = factory.quoteStart(address(doll));
        assertEq(f0 & VENUE_LOW_BYTE, 0, "fast-only at the fair price");
        (uint160 p,,) = oracle.latest();
        for (uint256 i = 0; i < 10; i++) {
            p = uint160((uint256(p) * 971) / 1000);
            _setVenueSpot(p);
            _pokes(1);
            (,, uint32 streak) = oracle.latest();
            assertEq(streak, 0, "every ramp step is unclamped");
        }
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 8);
        assertGt(s, 0, "fast-only: the ramp is clean");
        (, uint256 ramped, uint16 f1) = factory.quoteStart(address(doll));
        assertEq(f1 & F_VENUE_FALLBACK, 0);
        emit log_named_uint("basis after the 10 min ramp, bps of fair", (ramped * 10_000) / fair);
        assertGe(ramped * 5, fair, "ramp: basis >= 0.2x fair");
        _pokes(10); // held at the bottom for another window
        (, uint256 held, uint16 f2) = factory.quoteStart(address(doll));
        assertEq(f2 & F_VENUE_FALLBACK, 0);
        emit log_named_uint("basis after 10 min held, bps of fair", (held * 10_000) / fair);
        assertGe(held * 5, fair, "held: basis >= 0.2x fair");
        (,, Start memory st) = _register("A");
        assertEq(st.basis, held);
    }

    uint16 internal constant VENUE_LOW_BYTE = F_VENUE_FALLBACK | F_LIMITER | F_VENUE_STALE_USED;
}

/// @notice The stack deployed before the venue oracle existed: unbound, every start is the
/// constant, flagged; the one-shot bind accepts only the expected oracle.
contract StartAnchorUnboundTest is StartAnchorBase {
    function setUp() public {
        bindStartOracle = false;
        _setUpAnchored();
    }

    function test_unbound_constantFallbackFlagged() public {
        assertEq(factory.venueOracle(), address(0), "unbound");
        assertEq(factory.EXPECTED_VENUE_ID(), PoolId.unwrap(venueId), "the venue is expected");
        (uint160 s, uint8 status) = oracle.startPrice();
        assertEq(status, 0, "a warm oracle exists, but the factory does not read it yet");
        assertGt(s, 0);
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_FALLBACK | F_ORACLE_FAILED, "fallback, no read");
        assertEq(st.sqrtP, 0);
        assertEq(st.doll, FALLBACK_DOLL);
    }

    /// @notice A real VenueOracle on another venue, a look-alike reporting the expected venue
    /// and PoolManager, and a code-less address are all refused; the expected oracle binds,
    /// anyone may send it, and the next start reads it.
    function test_bindOnce_wrongVenueRejected() public {
        VenueOracle other = _otherVenueOracle();
        vm.expectRevert(FamilyFactory.BadVenueOracle.selector);
        factory.bindVenueOracle(address(other));

        MockVenueOracle lookAlike = new MockVenueOracle();
        lookAlike.set(uint160(FixedPoint96.Q96), 0, 0, 0);
        lookAlike.setVenue(PoolId.unwrap(venueId), address(manager));
        vm.expectRevert(FamilyFactory.BadVenueOracle.selector);
        factory.bindVenueOracle(address(lookAlike));

        vm.expectRevert(FamilyFactory.BadVenueOracle.selector);
        factory.bindVenueOracle(address(0xDEAD));
        assertEq(factory.venueOracle(), address(0), "still unbound");

        vm.expectEmit(true, false, false, false, address(factory));
        emit FamilyFactory.VenueOracleBound(address(oracle));
        vm.prank(address(0xA11CE)); // permissionless
        factory.bindVenueOracle(address(oracle));
        assertEq(factory.venueOracle(), address(oracle));

        (,, Start memory st) = _register("A");
        assertEq(st.flags, 0, "the bound oracle prices the start");
        (uint160 s,) = oracle.startPrice();
        assertEq(st.sqrtP, s);
    }

    /// @notice Deploy.s.sol's curve-phase code hash: a VenueOracle deployed against MOCKED venue
    /// reads (another seed price) has the same runtime code as the live one, so the hash fixed
    /// before graduation is the hash the real oracle has after it.
    function test_mockedVenueCodehashMatchesLive() public {
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(venueId);
        vm.mockCall(address(im), abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(uint256(1) << 96));
        vm.mockCall(
            address(im),
            abi.encodeWithSignature("extsload(bytes32)", bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)),
            abi.encode(uint256(1))
        );
        VenueOracle localCopy = new VenueOracle(im, venueKey, keeper, pokerB);
        vm.clearMockedCalls();
        (uint160 seeded,,) = localCopy.latest();
        assertEq(seeded, uint160(1) << 96, "seeded from the mocked read, not the live venue");
        assertTrue(seeded != P0);
        assertEq(address(localCopy).codehash, factory.EXPECTED_ORACLE_CODEHASH(), "same code");
        assertEq(address(oracle).codehash, factory.EXPECTED_ORACLE_CODEHASH());
    }

    /// @dev A VenueOracle on a second ETH/$DOLL venue (fee 500) with the same pokers.
    function _otherVenueOracle() internal returns (VenueOracle) {
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(doll)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        im.initialize(k, P0);
        liquidityRouter.modifyLiquidity{value: 1e6 ether}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidityDelta: 1e20,
                salt: 0
            }),
            ""
        );
        return new VenueOracle(im, k, keeper, pokerB);
    }
}

/// @notice No oracle at all (curve phase, or a permanent fallback): every start is the constant.
contract StartAnchorNoOracleTest is StartAnchorBase {
    function setUp() public {
        useVenue = false;
        _setUpAnchored();
    }

    function test_noOracle_constantFallback() public {
        assertEq(factory.venueOracle(), address(0));
        assertEq(factory.EXPECTED_VENUE_ID(), bytes32(0), "no venue: the bind is dead");
        (,, Start memory st) = _register("A");
        assertEq(st.flags, F_VENUE_FALLBACK | F_ORACLE_FAILED, "fallback, no read");
        assertEq(st.sqrtP, 0);
        assertEq(st.doll, FALLBACK_DOLL);
        assertEq(st.cap, FALLBACK_DOLL, "3% of $DOLL's cap: inside the clamps");
        assertEq(st.basis, FALLBACK_DOLL * 1000, "basis = cap / spec[0].fdvRatioLowerWad");
    }

    /// @notice With no expected venue, nothing can ever be bound.
    function test_noVenue_bindRefused() public {
        MockVenueOracle m = new MockVenueOracle();
        vm.expectRevert(FamilyFactory.BadVenueOracle.selector);
        factory.bindVenueOracle(address(m));
    }

    /// @notice The constructor refuses a start setup whose clamps are inverted.
    function test_badStartSetup_refused() public {
        startWalkMax = 0;
        _deployFactory(address(swapRouter));
        assertEq(lastFactoryError, FamilyFactory.BadStartSetup.selector, "no walk");
    }
}

/// @notice Invariant: whatever the oracle answers (any price, any status, revert, gas burn,
/// short or out-of-range return data), registration never reverts because of it, and every
/// start lies within [Y, X] of the parent's supply.
contract StartAnchorInvariantsTest is RoundTestBase {
    FamilyHandler internal handler;
    MockVenueOracle internal mock;

    function _beforeStack() internal override {
        mock = new MockVenueOracle();
        mock.set(uint160(3162 * FixedPoint96.Q96), 0, 0, 0);
        mock.setVenue(keccak256("mock venue"), address(manager));
        startOracle = address(mock);
    }

    function setUp() public {
        startFallbackDoll = 3e25;
        _setUpEdge();
        handler = new FamilyHandler(factory, familyRouter, vault, bidDeployer, swapRouter);
        handler.setOracle(mock);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = FamilyHandler.buy.selector;
        selectors[1] = FamilyHandler.sell.selector;
        selectors[2] = FamilyHandler.registerCandidate.selector;
        selectors[3] = FamilyHandler.tradeCandidate.selector;
        selectors[4] = FamilyHandler.advanceTime.selector;
        selectors[5] = FamilyHandler.submitAndFinalize.selector;
        selectors[6] = FamilyHandler.forceSuccession.selector;
        selectors[7] = FamilyHandler.fuzzOracle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_startsWithinClamps() public view {
        assertEq(handler.startsOutOfBand(), 0, "a start outside [Y, X] * Sp");
    }

    function invariant_oracleNeverBlocksRegistration() public view {
        assertEq(handler.oracleCausedReverts(), 0, "registration reverted on oracle state");
    }

    /// @notice A run that never priced a start proves nothing about the clamps.
    function afterInvariant() public view {
        if (handler.calls() > 16) assertGt(handler.startsChecked(), 0, "no start was ever priced");
    }
}
