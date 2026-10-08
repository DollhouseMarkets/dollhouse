// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {VenueOracle} from "../contracts/VenueOracle.sol";
import {IVenueOracle} from "../contracts/interfaces/IVenueOracle.sol";
import {MockDoll} from "./utils/MockDoll.sol";

/// @dev A poker that can call poke() from inside its own PoolManager unlock.
contract UnlockPoker is IUnlockCallback {
    IPoolManager internal immutable manager;
    VenueOracle public oracle;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function setOracle(VenueOracle o) external {
        oracle = o;
    }

    function pokeInsideUnlock() external {
        manager.unlock("");
    }

    function pokeOutside() external returns (bool) {
        return oracle.poke();
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        oracle.poke();
        return "";
    }
}

/// @dev Deploys a VenueOracle from inside its own PoolManager unlock.
contract UnlockDeployer is IUnlockCallback {
    IPoolManager internal immutable manager;
    PoolKey internal venueKey;

    constructor(IPoolManager _manager, PoolKey memory k) {
        manager = _manager;
        venueKey = k;
    }

    function deployInsideUnlock() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        new VenueOracle(manager, venueKey, address(this), address(this));
        return "";
    }
}

/// @notice VenueOracle: poker-only sampling outside any unlock, left-endpoint accumulation, the
/// +-3% step limiter, the two rings and the startPrice status bits.
contract VenueOracleTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    MockDoll internal doll;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    UnlockPoker internal backup;
    VenueOracle internal oracle;
    PoolKey internal key;
    PoolId internal id;

    address internal keeper = makeAddr("keeper");
    uint160 internal P0;
    int256 internal constant LIQ = 1e22;
    /// @dev Test clock: via-IR may reuse a `block.timestamp` read across a warp.
    uint256 internal clock;

    receive() external payable {}

    function setUp() public {
        clock = 1_700_000_000;
        vm.warp(clock);
        manager = IPoolManager(address(new PoolManager(address(this))));
        doll = new MockDoll(18);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        doll.mint(address(this), 1e30);
        doll.approve(address(liquidityRouter), type(uint256).max);
        doll.approve(address(swapRouter), type(uint256).max);
        vm.deal(address(this), 1e9 ether);

        key = _key(60);
        id = key.toId();
        P0 = TickMath.getSqrtPriceAtTick(69000); // ~1000 $DOLL per ETH
        manager.initialize(key, P0);
        _liquidity(key, LIQ);

        backup = new UnlockPoker(manager);
        oracle = new VenueOracle(manager, key, keeper, address(backup));
        backup.setOracle(oracle);
    }

    // -------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(doll)),
            fee: 3000,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });
    }

    function _liquidity(PoolKey memory k, int256 delta) internal {
        liquidityRouter.modifyLiquidity{value: delta > 0 ? 1e8 ether : 0}(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(k.tickSpacing),
                tickUpper: TickMath.maxUsableTick(k.tickSpacing),
                liquidityDelta: delta,
                salt: 0
            }),
            ""
        );
    }

    function _skip(uint256 dt) internal {
        clock += dt;
        vm.warp(clock);
    }

    /// @dev Pin what the oracle reads as the venue spot (slot0) without touching the pool.
    function _setSpot(uint160 p) internal {
        vm.mockCall(
            address(manager),
            abi.encodeWithSignature("extsload(bytes32)", StateLibrary._getPoolStateSlot(id)),
            abi.encode(bytes32(uint256(p)))
        );
    }

    /// @dev External, so an expected constructor revert is a call of its own.
    function deployOracle(PoolKey memory k, address a, address b) external returns (VenueOracle) {
        return new VenueOracle(manager, k, a, b);
    }

    function _poke() internal returns (bool) {
        vm.prank(keeper);
        return oracle.poke();
    }

    function _pokeAfter(uint256 dt, uint160 spot) internal returns (bool) {
        _skip(dt);
        _setSpot(spot);
        return _poke();
    }

    /// @dev Poke at a constant spot every `step` seconds for `secs` seconds.
    function _warm(uint160 spot, uint256 secs, uint256 step) internal {
        for (uint256 t = step; t <= secs; t += step) {
            assertTrue(_pokeAfter(step, spot));
        }
    }

    function _stored() internal view returns (uint160 s) {
        (s,,) = oracle.latest();
    }

    function _clamp(uint160 prev, uint160 spot) internal pure returns (uint160) {
        uint256 step = uint256(prev) * 300 / 1e4;
        uint256 lo = prev - step;
        uint256 hi = prev + step;
        if (spot < lo) return uint160(lo);
        if (spot > hi) return uint160(hi);
        return spot;
    }

    // -------------------------------------------------------------------------------------
    // access and spacing
    // -------------------------------------------------------------------------------------

    function test_nonPokerReverts() public {
        _skip(60);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IVenueOracle.NotPoker.selector);
        oracle.poke();
        // both pokers may poke
        assertTrue(_poke());
        _skip(60);
        assertTrue(backup.pokeOutside());
    }

    function test_pokeRevertsInsideUnlock() public {
        _skip(60);
        vm.expectRevert(IVenueOracle.InsideUnlock.selector);
        backup.pokeInsideUnlock();
        // the same poker outside an unlock succeeds
        assertTrue(backup.pokeOutside());
    }

    function test_pokeWithinSpacingNoOp() public {
        assertFalse(_poke(), "same second as the seed");
        assertTrue(_pokeAfter(60, P0 * 101 / 100));
        (uint160 s, uint64 t, uint32 k) = oracle.latest();
        (uint160 tw, uint32 cov, uint64 tn) = oracle.consult(3600, false);

        vm.recordLogs();
        assertFalse(_pokeAfter(59, P0 * 102 / 100), "59 s after the last poke");
        assertEq(vm.getRecordedLogs().length, 0, "a spaced-out poke emits nothing");
        (uint160 s2, uint64 t2, uint32 k2) = oracle.latest();
        (uint160 tw2, uint32 cov2, uint64 tn2) = oracle.consult(3600, false);
        assertEq(s2, s);
        assertEq(t2, t);
        assertEq(k2, k);
        assertEq(tw2, tw);
        assertEq(cov2, cov);
        assertEq(tn2, tn);

        assertTrue(_pokeAfter(1, P0 * 102 / 100), "60 s after the last poke");
    }

    // -------------------------------------------------------------------------------------
    // weighting and limiter
    // -------------------------------------------------------------------------------------

    function test_newestSampleHasNoWeight() public {
        _warm(P0, 90_000, 1800);
        (uint160 before, uint8 st) = oracle.startPrice();
        assertEq(st, 0);
        assertEq(before, P0);

        assertTrue(_pokeAfter(60, P0 * 10));
        assertGt(_stored(), P0, "the new sample moved");
        (uint160 afterP, uint8 st2) = oracle.startPrice();
        assertEq(st2, 0);
        assertEq(afterP, before, "the newest sample carries no weight");
    }

    function testFuzz_storedStepBounded(uint160[12] memory spots, uint32[12] memory dts) public {
        for (uint256 i = 0; i < spots.length; i++) {
            uint160 spot = uint160(bound(spots[i], TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
            uint160 prev = _stored();
            assertTrue(_pokeAfter(bound(dts[i], 60, 1e6), spot));
            uint160 s = _stored();
            uint256 diff = s > prev ? s - prev : prev - s;
            assertLe(diff * 1e4, uint256(prev) * 300, "step above 3%");
            assertEq(s, _clamp(prev, spot), "clamp toward spot");
            (,, uint32 streak) = oracle.latest();
            if (s == spot) assertEq(streak, 0);
            else assertGt(streak, 0);
        }
    }

    function test_limiterFollowsCrash() public {
        // a 10x price move is a sqrt(10) move in sqrtP
        uint160 down = uint160(uint256(P0) * 1e9 / 3_162_277_660);
        uint256 n;
        while (_stored() != down) {
            _pokeAfter(60, down);
            n++;
            assertLe(n, 39, "crash not followed within 39 pokes");
        }
        (,, uint32 streak) = oracle.latest();
        assertEq(streak, 0, "streak resets once caught up");
        emit log_named_uint("pokes to follow a 10x crash", n);

        uint160 up = uint160(uint256(down) * 3_162_277_661 / 1e9);
        n = 0;
        while (_stored() != up) {
            _pokeAfter(60, up);
            n++;
            assertLe(n, 39, "rally not followed within 39 pokes");
        }
        emit log_named_uint("pokes to follow a 10x rally", n);
    }

    // -------------------------------------------------------------------------------------
    // rings
    // -------------------------------------------------------------------------------------

    struct Naive {
        uint64[] pt; // every sample time, seed first
        uint160[] ps; // every stored sample
        uint64[] fastT; // fast ring entry times, in order written
        uint64[] slowT; // slow ring entry times, in order written
    }

    function _naiveConsult(Naive memory m, uint64[] memory ringT, uint256 len, uint32 w)
        internal
        pure
        returns (uint160, uint32)
    {
        uint256 first = len > 64 ? len - 64 : 0;
        uint64 nt = ringT[len - 1];
        uint64 target = nt > w ? nt - w : 0;
        uint64 rt = ringT[first];
        for (uint256 i = first; i < len; i++) {
            if (ringT[i] <= target) rt = ringT[i];
        }
        if (nt <= rt) return (0, 0);
        uint256 sum;
        for (uint256 k = 0; k + 1 < m.pt.length; k++) {
            if (m.pt[k] >= rt && m.pt[k + 1] <= nt) sum += uint256(m.ps[k]) * (m.pt[k + 1] - m.pt[k]);
        }
        return (uint160(sum / (nt - rt)), uint32(nt - rt));
    }

    function testFuzz_ringMatchesNaiveTwap(uint256 seed, uint8 nRaw, uint32 wFast, uint32 wSlow) public {
        uint256 n = bound(nRaw, 1, 150);
        Naive memory m;
        m.pt = new uint64[](n + 1);
        m.ps = new uint160[](n + 1);
        m.fastT = new uint64[](n + 1);
        m.slowT = new uint64[](n + 1);
        m.pt[0] = uint64(clock);
        m.ps[0] = P0;
        m.fastT[0] = m.pt[0];
        m.slowT[0] = m.pt[0];
        uint256 slowLen = 1;
        uint160 spot = P0;

        for (uint256 i = 1; i <= n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // mostly keeper cadence, sometimes a long gap
            uint256 dt = r % 8 == 0 ? 60 + (r >> 8) % 50_000 : 60 + (r >> 8) % 120;
            // spot drifts up to +-5% per step, so the limiter binds sometimes
            spot = uint160(uint256(spot) * (9500 + (r >> 64) % 1001) / 1e4);
            assertTrue(_pokeAfter(dt, spot));
            m.pt[i] = uint64(clock);
            m.ps[i] = _clamp(m.ps[i - 1], spot);
            assertEq(_stored(), m.ps[i], "stored sample");
            m.fastT[i] = m.pt[i];
            if (m.pt[i] - m.slowT[slowLen - 1] >= 1800) m.slowT[slowLen++] = m.pt[i];
        }

        uint32[4] memory ws = [uint32(bound(wFast, 0, 10_000)), 3600, uint32(bound(wSlow, 0, 200_000)), 86_400];
        for (uint256 j = 0; j < 4; j++) {
            bool slow = j >= 2;
            (uint160 tw, uint32 cov, uint64 tn) = oracle.consult(ws[j], slow);
            (uint160 etw, uint32 ecov) = slow ? _naiveConsult(m, m.slowT, slowLen, ws[j]) : _naiveConsult(m, m.fastT, n + 1, ws[j]);
            assertEq(tw, etw, "twap");
            assertEq(cov, ecov, "covered");
            assertEq(tn, slow ? m.slowT[slowLen - 1] : m.fastT[n], "tNewest");
        }
    }

    function test_fastRingCovers600AtMinSpacing() public {
        _warm(P0, 100 * 60, 60); // 100 pokes: the 64-entry ring has wrapped
        (uint160 tw, uint32 cov,) = oracle.consult(600, false);
        assertEq(cov, 600);
        assertEq(tw, P0);
        (, cov,) = oracle.consult(63 * 60, false);
        assertEq(cov, 63 * 60, "the whole ring");
        (, cov,) = oracle.consult(64 * 60, false);
        assertEq(cov, 63 * 60, "beyond the ring: reported short, not garbage");
        (, uint8 st) = oracle.startPrice();
        assertEq(st, 8, "only the slow ring is short");
    }

    // -------------------------------------------------------------------------------------
    // edges
    // -------------------------------------------------------------------------------------

    function test_uninitVenueSkips() public {
        // construction refuses an uninitialised venue, an empty one, and a non-native one
        PoolKey memory k2 = _key(10);
        vm.expectRevert(VenueOracle.VenueNotInitialized.selector);
        this.deployOracle(k2, keeper, keeper);
        manager.initialize(k2, P0);
        vm.expectRevert(VenueOracle.VenueNoLiquidity.selector);
        this.deployOracle(k2, keeper, keeper);
        PoolKey memory k3 = k2;
        k3.currency0 = Currency.wrap(address(1));
        vm.expectRevert(VenueOracle.VenueNotNative.selector);
        this.deployOracle(k3, keeper, keeper);
        vm.expectRevert(VenueOracle.ZeroPoker.selector);
        this.deployOracle(key, keeper, address(0));

        (uint160 s, uint64 t, uint32 k) = oracle.latest();
        _skip(60);
        _setSpot(0);
        vm.expectEmit(address(oracle));
        emit IVenueOracle.PokeSkipped(1);
        assertFalse(_poke());
        vm.clearMockedCalls();

        // all in-range liquidity withdrawn
        _liquidity(key, -LIQ);
        assertEq(manager.getLiquidity(id), 0);
        vm.expectEmit(address(oracle));
        emit IVenueOracle.PokeSkipped(2);
        assertFalse(_poke());

        (uint160 s2, uint64 t2, uint32 k2_) = oracle.latest();
        assertEq(s2, s);
        assertEq(t2, t);
        assertEq(k2_, k);
        (, uint32 cov,) = oracle.consult(3600, false);
        assertEq(cov, 0, "nothing written");
    }

    function test_maxSqrtPriceNoOverflow() public {
        uint160 max = TickMath.MAX_SQRT_PRICE;
        _setSpot(max - 1);
        VenueOracle o = new VenueOracle(manager, key, keeper, keeper);
        // 20 gaps of 2^30 s at the top price: the accumulator wraps past 2^192
        for (uint256 i = 0; i < 20; i++) {
            _skip(1 << 30);
            _setSpot(max);
            vm.prank(keeper);
            assertTrue(o.poke());
        }
        (uint160 s,,) = o.latest();
        assertEq(s, max);
        (uint160 tw, uint32 cov,) = o.consult(3600, false);
        assertEq(cov, 1 << 30);
        assertEq(tw, max, "exact across the wrap");
        (tw, cov,) = o.consult(1 << 31, true);
        assertEq(cov, 1 << 31);
        assertEq(tw, max);

        // and the bottom of the range
        _setSpot(TickMath.MIN_SQRT_PRICE);
        VenueOracle lo = new VenueOracle(manager, key, keeper, keeper);
        _skip(60);
        _setSpot(TickMath.MIN_SQRT_PRICE);
        vm.prank(keeper);
        assertTrue(lo.poke());
        (tw, cov,) = lo.consult(60, false);
        assertEq(tw, TickMath.MIN_SQRT_PRICE);
    }

    function test_sameTimestampNoDivZero() public {
        (uint160 tw, uint32 cov, uint64 tn) = oracle.consult(3600, false);
        assertEq(tw, 0);
        assertEq(cov, 0);
        assertEq(tn, clock);
        (tw, cov,) = oracle.consult(0, true);
        assertEq(cov, 0);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(sp, 0);
        assertEq(st, 1 | 4 | 8);

        assertTrue(_pokeAfter(60, P0));
        assertFalse(_poke(), "second poke in the same second");
        (tw, cov,) = oracle.consult(0, false);
        assertEq(cov, 0, "zero window");
        (tw, cov,) = oracle.consult(60, false);
        assertEq(cov, 60);
        assertEq(tw, P0);
    }

    function test_timeJumpPricedByPriorSample() public {
        uint160 q = P0 * 102 / 100;
        assertTrue(_pokeAfter(36_000, q));
        assertEq(_stored(), q, "within the step");
        (uint160 tw, uint32 cov,) = oracle.consult(3600, false);
        assertEq(cov, 36_000);
        assertEq(tw, P0, "the jump is priced by the sample before it");
        (tw,,) = oracle.consult(3600, true);
        assertEq(tw, P0);
    }

    // -------------------------------------------------------------------------------------
    // startPrice status
    // -------------------------------------------------------------------------------------

    function test_keeperDown_stale() public {
        _warm(P0, 90_000, 1800);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 0);
        assertEq(sp, P0);
        _skip(1800);
        (, st) = oracle.startPrice();
        assertEq(st, 0, "exactly MAX_AGE_S old is fresh");
        _skip(1);
        (sp, st) = oracle.startPrice();
        assertEq(st, 2, "stale");
        assertEq(sp, P0, "stale only, within the grace: the averages up to the last sample");
        // STALE_GRACE_S after the last sample it still answers; one second more and it does not
        _skip(oracle.STALE_GRACE_S() - 1801);
        (sp, st) = oracle.startPrice();
        assertEq(st, 2);
        assertEq(sp, P0, "exactly STALE_GRACE_S old");
        _skip(1);
        (sp, st) = oracle.startPrice();
        assertEq(st, 2, "stale");
        assertEq(sp, 0, "beyond the grace: no price");
    }

    /// @notice Stale is the only bit a price survives: stale with short history answers nothing.
    function test_staleWithOtherBits_noPrice() public {
        _warm(P0, 600, 60); // fast covered, slow short
        _skip(1801);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 2 | 8, "stale and slow short");
        assertEq(sp, 0);
    }

    /// @notice The two getters the factory's bind checks.
    function test_bindGetters() public view {
        assertEq(PoolId.unwrap(oracle.venueId()), PoolId.unwrap(id));
        assertEq(address(oracle.poolManager()), address(manager));
        assertEq(PoolId.unwrap(IVenueOracle(address(oracle)).venueId()), PoolId.unwrap(key.toId()));
    }

    function test_warmup_statusBits() public {
        uint256 t0 = clock;
        (, uint8 st) = oracle.startPrice();
        assertEq(st, 1 | 4 | 8, "seed only");
        assertTrue(_pokeAfter(60, P0));
        (, st) = oracle.startPrice();
        assertEq(st, 4 | 8);
        _warm(P0, 600 - 120, 60);
        (, st) = oracle.startPrice();
        assertEq(st, 4 | 8, "9 min of history");
        assertTrue(_pokeAfter(60, P0));
        assertEq(clock - t0, 600);
        uint160 sp;
        (sp, st) = oracle.startPrice();
        assertEq(st, 8, "10 min: fast covered, slow short");
        assertEq(sp, 0, "10 min: the seed is the window's reference entry");
        assertTrue(_pokeAfter(60, P0));
        (sp, st) = oracle.startPrice();
        assertEq(st, 8, "10 min + 60 s: slow short");
        assertEq(sp, P0, "10 min + 60 s: fast-only, max with slow so far");
        _warm(P0, 47 * 1800, 1800);
        assertEq(clock - t0, 85_260);
        (sp, st) = oracle.startPrice();
        assertEq(st, 8, "~23.7 h: slow still short");
        assertEq(sp, P0, "~23.7 h: fast-only");
        assertTrue(_pokeAfter(1800, P0));
        uint8 st2;
        (sp, st2) = oracle.startPrice();
        assertEq(st2, 0, "24 h: ready");
        assertEq(sp, P0);
    }

    function test_startPriceIsMaxOfFastAndSlow() public {
        _warm(P0, 90_000, 1800);
        // a sustained dump lowers the fast average first; the higher slow average binds
        uint160 dumped = P0 * 90 / 100;
        _warm(dumped, 600, 60);
        (uint160 f,,) = oracle.consult(600, false);
        (uint160 s,,) = oracle.consult(86_400, true);
        assertLt(f, s);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 0);
        assertEq(sp, s);
    }

    // -------------------------------------------------------------------------------------
    // fast-only: ten clean minutes, max with the partial slow average
    // -------------------------------------------------------------------------------------

    function _max(uint160 a, uint160 b) internal pure returns (uint160) {
        return a > b ? a : b;
    }

    /// @notice Ten clean minutes after the seed has left the window: status 8 with a price.
    function test_fastOnlyAfterTenMinutes() public {
        _warm(P0, 600, 60);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 8);
        assertEq(sp, 0, "the seed is still the window's reference entry");
        assertTrue(_pokeAfter(60, P0));
        (sp, st) = oracle.startPrice();
        assertEq(st, 8, "slow short");
        (uint160 f,,) = oracle.consult(600, false);
        (uint160 s,,) = oracle.consult(86_400, true);
        assertEq(sp, _max(f, s));
        assertEq(sp, P0);
    }

    /// @notice A fast window under 10 min never prices, whatever else holds.
    function test_fastOnlyRejectsShortFast() public {
        for (uint256 i = 0; i < 9; i++) {
            assertTrue(_pokeAfter(60, P0));
            (uint160 sp, uint8 st) = oracle.startPrice();
            assertEq(st, 4 | 8, "fast short and slow short");
            assertEq(sp, 0);
        }
        // a stale gap does not count as coverage either: fast short with stale is no price
        _skip(1801);
        (uint160 sp2, uint8 st2) = oracle.startPrice();
        assertEq(st2, 2 | 4 | 8);
        assertEq(sp2, 0);
    }

    /// @notice A seed far from the market (P0 / 10 in sqrt price) cannot price a start: it blocks
    /// fast-only while it is in the window, and the limiter's climb from it clamps every poke
    /// until caught up. Ten minutes after the last clamp the price is the real market's.
    function test_fastOnlyExcludesSeed() public {
        _setSpot(P0 / 10);
        oracle = this.deployOracle(key, keeper, address(backup));
        (uint160 seeded,,) = oracle.latest();
        assertEq(seeded, P0 / 10);
        uint256 lastClamp;
        uint256 n;
        while (_stored() != P0) {
            assertTrue(_pokeAfter(60, P0));
            (,, uint32 streak) = oracle.latest();
            if (streak > 0) lastClamp = clock;
            n++;
            assertLe(n, 100);
            (uint160 sp,) = oracle.startPrice();
            assertEq(sp, 0, "no price while the seed or a clamp is in the window");
        }
        assertGt(lastClamp, 0, "the climb was clamped");
        while (clock < lastClamp + 600) {
            assertTrue(_pokeAfter(60, P0));
            (uint160 sp,) = oracle.startPrice();
            assertEq(sp, 0, "a clamp is still in the window");
        }
        assertTrue(_pokeAfter(60, P0));
        (uint160 sp3, uint8 st3) = oracle.startPrice();
        assertEq(st3, 8);
        (uint160 f,,) = oracle.consult(600, false);
        assertEq(f, P0, "the window holds only real, unclamped spot");
        assertEq(sp3, P0, "max(fast, slow so far): the climb only lowers slow");
    }

    /// @notice A clamped sample inside the 10 min window refuses fast-only until it leaves.
    function test_fastOnlyBlockedByClampInWindow() public {
        _warm(P0, 7200, 60);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 8);
        assertEq(sp, P0);
        uint160 moved = P0 * 110 / 100;
        uint256 lastClamp;
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(_pokeAfter(60, moved));
            (,, uint32 streak) = oracle.latest();
            if (streak > 0) lastClamp = clock;
        }
        assertGt(lastClamp, 0, "the 10% move was clamped");
        assertEq(_stored(), moved, "caught up");
        (sp, st) = oracle.startPrice();
        assertEq(st, 8);
        assertEq(sp, 0, "clamp in the window");
        while (clock < lastClamp + 600) {
            assertTrue(_pokeAfter(60, moved));
            (sp, st) = oracle.startPrice();
            assertEq(st, 8);
            assertEq(sp, 0, "the clamp is still at or after the reference entry");
        }
        assertTrue(_pokeAfter(60, moved));
        (sp, st) = oracle.startPrice();
        assertEq(st, 8);
        (uint160 f,,) = oracle.consult(600, false);
        (uint160 s,,) = oracle.consult(86_400, true);
        assertEq(sp, _max(f, s), "priced again once the clamp left the window");
        assertGt(sp, 0);
    }

    /// @notice Fast-only answers max(fast, slow so far): a dump in the first day is held up by
    /// the partial slow average, a pump follows the fast one.
    function test_fastOnlyTakesMaxWithPartialSlow() public {
        _warm(P0, 7200, 60);
        uint256 snap = vm.snapshotState();
        uint256 clock0 = clock;

        uint160 low = P0 * 99 / 100;
        _warm(low, 660, 60);
        (uint160 f, uint32 cf,) = oracle.consult(600, false);
        (uint160 s, uint32 cs,) = oracle.consult(86_400, true);
        assertGe(cf, 600);
        assertLt(cs, 86_400, "slow partial");
        assertLt(f, s);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 8);
        assertEq(sp, s, "slow so far binds on a dump");

        vm.revertToState(snap);
        clock = clock0;
        vm.warp(clock);
        uint160 high = P0 * 101 / 100;
        _warm(high, 660, 60);
        (f,,) = oracle.consult(600, false);
        (s,,) = oracle.consult(86_400, true);
        assertGt(f, s);
        (sp, st) = oracle.startPrice();
        assertEq(st, 8);
        assertEq(sp, f, "fast binds on a pump");
    }

    /// @notice Once the slow window is covered (status 0) a clamp no longer blocks the price.
    function test_slowCoverageTakesOverAt24h() public {
        _warm(P0, 90_000, 1800);
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 0);
        assertEq(sp, P0);
        assertTrue(_pokeAfter(60, P0 * 110 / 100));
        (,, uint32 streak) = oracle.latest();
        assertGt(streak, 0, "clamped");
        assertTrue(_pokeAfter(60, P0 * 110 / 100));
        (sp, st) = oracle.startPrice();
        assertEq(st, 0, "status 0 ignores the clamp gate");
        (uint160 f,,) = oracle.consult(600, false);
        (uint160 s,,) = oracle.consult(86_400, true);
        assertEq(sp, _max(f, s));
        assertGt(sp, 0);
    }

    /// @notice The constructor refuses to seed inside a PoolManager unlock.
    function test_constructorRevertsInsideUnlock() public {
        UnlockDeployer d = new UnlockDeployer(manager, key);
        vm.expectRevert(IVenueOracle.InsideUnlock.selector);
        d.deployInsideUnlock();
    }

    function test_sameTxVenueSwapDoesNotMoveConsult() public {
        vm.clearMockedCalls();
        for (uint256 i = 0; i < 50; i++) {
            _skip(1800);
            assertTrue(_poke());
        }
        (uint160 sp, uint8 st) = oracle.startPrice();
        assertEq(st, 0);
        (uint160 f, uint32 cf, uint64 tf) = oracle.consult(3600, false);
        (uint160 s, uint32 cs, uint64 ts) = oracle.consult(86_400, true);

        (uint160 spotBefore,,,) = manager.getSlot0(id);
        swapRouter.swap{value: 1e7 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e7 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 spotAfter,,,) = manager.getSlot0(id);
        assertLt(uint256(spotAfter) * 2, spotBefore, "the venue moved by more than half");

        (uint160 sp2, uint8 st2) = oracle.startPrice();
        assertEq(sp2, sp);
        assertEq(st2, st);
        (uint160 f2, uint32 cf2, uint64 tf2) = oracle.consult(3600, false);
        (uint160 s2, uint32 cs2, uint64 ts2) = oracle.consult(86_400, true);
        assertEq(f2, f);
        assertEq(cf2, cf);
        assertEq(tf2, tf);
        assertEq(s2, s);
        assertEq(cs2, cs);
        assertEq(ts2, ts);
        assertFalse(_poke(), "and a same-second poke cannot sample it");
    }

    function test_runtimeSize() public {
        uint256 size = address(oracle).code.length;
        emit log_named_uint("VenueOracle runtime bytes", size);
        assertLt(size, 6000);
    }
}
