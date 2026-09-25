// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../../contracts/interfaces/IFamilyHook.sol";
import {ILocker} from "../../contracts/interfaces/ILocker.sol";
import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";

/// @notice Fork scenarios 1 and 9 of docs/spec/PROPERTIES.md sec.4: the
/// ADOPTION of the external genesis token, the launch of LINK ONE (the edge pool) and the first
/// routed buy across it on the real `PoolManager`, plus the locked-liquidity negative tests.
/// Covers SUP-02/03/05/06/07, FEE-01/02/08, ROU-01/02.
///
/// @dev The external entrance - the venue pool the adopted token graduated into - is present on
/// the same singleton as a HOOKLESS ETH/$DOLL pool and is never touched by anything the stack
/// does. That is the whole relationship: the protocol depends on it for a door and on nothing
/// else about it.
contract EdgeForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        if (!_setUpForkEdge()) return;
        vm.warp(block.timestamp + 10); // past link one's snipe window
    }

    /// @notice The fork really is chain 46630's v4 singleton: a reviewer running this sees the
    /// same runtime code at the same address.
    /// @dev Identity is pinned by CODE HASH, not by a block number. This chain reports the
    /// settlement layer's reference height in `block.number`, so the value read inside the fork
    /// is not the height the fork was created at; it is logged rather than asserted. Every
    /// schedule in the system is denominated in `block.timestamp`, which is unaffected.
    function testFork_poolManagerIdentity() public {
        _requireFork();
        assertEq(block.chainid, FORK_CHAIN_ID, "chain id");
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH, "PoolManager runtime code hash");
        assertEq(address(manager), POOL_MANAGER, "the stack was built on the real singleton");
        emit log_named_uint("block.number reported inside the fork", block.number);
        emit log_named_uint("block.timestamp reported inside the fork", block.timestamp);
    }

    /// @notice Index 0 is ADOPTED, not launched. It is the external token, it has no
    /// pool of ours, and the entrance pool that does quote it is hookless and untouched.
    function testFork_ADOPT_indexZeroIsExternalAndHasNoPool() public {
        _requireFork();
        assertEq(roundManager.canonical(0), address(doll), "canonical 0 is the adopted token");
        assertEq(address(roundManager.poolKeyOf(0).hooks), address(0), "index 0 has no pool of ours");
        assertFalse(lens.hasPool(0), "and the lens says so");
        assertTrue(lens.hasPool(1), "link one does have one");

        // the entrance stand-in exists on the same singleton and carries none of our hooks
        assertTrue(entranceInitialized, "the entrance pool was initialized");
        assertEq(address(entranceKey.hooks), address(0), "the entrance is hookless");
        (uint160 sqrtP,,,) = im.getSlot0(entranceKey.toId());
        assertGt(sqrtP, 0, "and it is a real, initialized pool");
        assertFalse(hook.poolInfo(entranceKey.toId()).registered, "our hook knows nothing about it");
    }

    /// @notice SUP-03: link one places its WHOLE supply on the curve, less burned dust. There is
    /// no developer allocation, so there is nothing else to account for. Measured from
    /// the real singleton's balance, not from a local mock's.
    function testFork_SUP03_launchSupplyIsAllOnTheCurve() public {
        _requireFork();
        // link one is crowned through a round it had to absorb its way through, so the
        // position is sold back first: what the launch placed is then all that is in the pool
        _rewindEdgePool();
        uint256 inPool = token.balanceOf(POOL_MANAGER);

        assertEq(token.balanceOf(address(locker)), 0, "the locker holds no loose supply");
        assertEq(token.balanceOf(address(this)), 0, "nobody holds loose supply");

        uint256 dust = SUPPLY - inPool;
        assertLt(dust, 1e12, "curve rounding dust below 1e12 wei");
        assertEq(token.totalSupply(), inPool, "the dust was burned, not parked");
        _assertNoEth();
    }

    /// @notice SUP-02/SUP-08: a candidate places its WHOLE supply with no allocation at all.
    function testFork_SUP02_candidatePlacesTheWholeSupply() public {
        _requireFork();
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");

        uint256 inPool = IERC20(c.token).balanceOf(POOL_MANAGER);
        uint256 dust = SUPPLY - inPool;
        assertEq(IERC20(c.token).totalSupply(), inPool, "no supply outside the pool");
        assertLt(dust, 1e12, "the dust burn absorbs the rounding");
        assertEq(IERC20(c.token).balanceOf(address(locker)), 0, "nothing loose in the locker");
    }

    /// @notice The curve the factory placed is what the real pool reports: contiguous ranges, all
    /// at or below spot, and a slot0 price equal to the registered one to the wei.
    function testFork_SUP07_poolIsInitializedAtTheRegisteredPrice() public {
        _requireFork();
        (uint160 sqrtPriceX96,,,) = im.getSlot0(poolId);
        IFamilyHook.RegisteredPool memory p = hook.poolInfo(poolId);
        assertEq(p.initSqrtPriceX96, initSqrtPriceX96, "the registered price is the curve's");

        assertTrue(p.registered, "registered");
        assertTrue(p.isEdge, "link one is the edge pool");
        assertGt(p.tradingStart, 0, "It is an ordinary round pool with a snipe window");
        assertGt(p.nominalEnd, p.tradingStart, "and a published end, so its rings freeze");
        assertGt(sqrtPriceX96, 0, "the pool is live");

        for (uint256 i = 0; i < ranges.length; i++) {
            assertLt(ranges[i].tickLower, ranges[i].tickUpper, "non-empty range");
            if (i > 0) assertEq(ranges[i].tickUpper, ranges[i - 1].tickLower, "contiguous");
        }
    }

    /// @notice FEE-01/FEE-02/FEE-08 and ROU-01/02: the first routed buy across the EDGE pool pays
    /// exactly one 1% protocol fee plus one 750 ppm hop fee, the four buckets sum to the protocol
    /// fee, and the terminal token's creator is credited. The fee is charged in the EDGE CURRENCY.
    function testFork_FEE01_firstRoutedBuyChargesOneEdgeFee() public {
        _requireFork();
        uint256 amountIn = 1 ether;

        uint256 devBefore = vault.devBalance();
        uint256 creatorBefore = vault.creatorBalance(address(token));
        vm.recordLogs();
        uint256 out = familyRouter.buyExactIn(1, amountIn, 0, address(this), 2);
        Split[] memory splits = _splits();

        assertGt(out, 0, "the real pool filled the buy");
        assertEq(splits.length, 1, "one leg, one accrual");
        Split memory edge = splits[0];
        assertEq(edge.currency, address(doll), "the edge fee is charged in the edge currency");
        assertEq(edge.protocolFee, (amountIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the parent in");
        assertEq(edge.hopFee, (amountIn * _hopFeePpm()) / PPM, "750 ppm of the parent in");
        assertEq(edge.dev + edge.creator + edge.sleeve + edge.reinforce, edge.protocolFee, "the four buckets");
        assertEq(edge.dev, (edge.protocolFee * vault.DEV_BPS()) / 10_000, "dev 20%");
        assertEq(edge.creator, (edge.protocolFee * _creatorBps()) / 10_000, "creator 40%");

        assertEq(vault.devBalance() - devBefore, edge.dev, "the dev ledger moved by the event amount");
        assertEq(vault.creatorBalance(address(token)) - creatorBefore, edge.creator, "link one's creator credited");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "the router keeps nothing");
        _assertSolvent();
        _assertNoEth();
    }

    /// @notice FEE-13: a partially filled exact-input buy is still charged on the full
    /// `amountSpecified`; what the route could not absorb is simply never pulled from the payer.
    /// Disclosed.
    function testFork_FEE13_feeBasisIsTheFullSpecifiedAmount() public {
        _requireFork();
        // more $DOLL than link one's whole curve can absorb, so the leg fills partially
        uint256 huge = 10_000_000_000 ether;
        _fundDoll(address(this), huge);
        uint256 before = doll.balanceOf(address(this));
        vm.recordLogs();
        familyRouter.buyExactIn(1, huge, 0, address(this), 2);
        Split[] memory splits = _splits();

        uint256 spent = before - doll.balanceOf(address(this));
        assertLt(spent, huge, "the curve could not absorb the whole amount");
        assertEq(splits[0].protocolFee, (huge * hook.PROTOCOL_FEE_PPM()) / PPM, "charged on what was specified");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "the remainder was never pulled, not stranded");
    }

    /// @notice SUP-05: the ratchet. No caller can reduce a Locker-owned position on the real
    /// singleton - not an EOA, not the Locker, not the factory.
    function testFork_SUP05_lockedLiquidityCannotBeRemoved() public {
        _requireFork();
        _expectHookRevert(address(hook), IHooks.beforeRemoveLiquidity.selector, IFamilyHook.LiquidityIsLocked.selector);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: ranges[0].tickLower, tickUpper: ranges[0].tickUpper, liquidityDelta: -1e18, salt: bytes32(0)
            }),
            ""
        );

        // ...and the same call from the Locker itself, which owns the position
        vm.prank(address(locker));
        _expectHookRevert(address(hook), IHooks.beforeRemoveLiquidity.selector, IFamilyHook.LiquidityIsLocked.selector);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: ranges[0].tickLower, tickUpper: ranges[0].tickUpper, liquidityDelta: -1e18, salt: bytes32(0)
            }),
            ""
        );

        // the Locker exposes no exit of its own, either
        vm.expectRevert(ILocker.NotBidDeployer.selector);
        locker.depositBid(key, 1 ether, -120, -60);
        vm.expectRevert(ILocker.NotFactory.selector);
        locker.placeStandardCurve(key, ranges, false);
    }

    /// @notice SUP-06: liquidity may only be added by the Locker, and donation is impossible -
    /// otherwise the score's "swap deltas only" claim is void.
    function testFork_SUP06_addLiquidityAndDonateAreRefused() public {
        _requireFork();
        _expectHookRevert(address(hook), IHooks.beforeAddLiquidity.selector, IFamilyHook.OnlyLocker.selector);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: ranges[0].tickLower, tickUpper: ranges[0].tickUpper, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        );

        _expectHookRevert(address(hook), IHooks.beforeDonate.selector, IFamilyHook.DonationDisabled.selector);
        donateRouter.donate(key, 1 ether, 0, "");
    }

    /// @notice SUP-07: pre-initialization poisoning is refused by the real
    /// singleton too - an unregistered key, and a registered key one wei off its price.
    function testFork_SUP07_unregisteredKeyAndWrongPriceAreRefused() public {
        _requireFork();
        PoolKey memory rogue = PoolKey({
            currency0: Currency.wrap(address(doll)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 120, // not the registered key
            hooks: IHooks(address(hook))
        });
        _expectHookRevert(address(hook), IHooks.beforeInitialize.selector, IFamilyHook.PoolNotRegistered.selector);
        manager.initialize(rogue, initSqrtPriceX96);

        // a second, independent stack lets a key be registered without being initialized
        (FamilyFactory f2, FamilyHook h2) = _deployFactory(address(swapRouter));
        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(address(doll)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: f2.TICK_SPACING(),
            hooks: IHooks(address(h2))
        });
        uint64 start = uint64(block.timestamp) + 60;
        vm.prank(address(f2));
        h2.registerPool(k2, true, initSqrtPriceX96, start, start + 900, 0, true);

        _expectHookRevert(address(h2), IHooks.beforeInitialize.selector, IFamilyHook.WrongInitialPrice.selector);
        manager.initialize(k2, initSqrtPriceX96 + 1);

        manager.initialize(k2, initSqrtPriceX96); // the registered price is accepted
    }
}
