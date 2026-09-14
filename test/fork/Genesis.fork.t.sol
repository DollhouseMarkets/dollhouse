// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../../contracts/interfaces/IFamilyHook.sol";
import {ILocker} from "../../contracts/interfaces/ILocker.sol";
import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";

/// @notice Fork scenarios 1 and 9 of docs/spec/PROPERTIES.md sec.4: the genesis launch and the
/// first routed buy on the real `PoolManager`, and the locked-liquidity negative tests.
/// Covers SUP-02/03/05/06/07, FEE-01/02/08, ROU-01/02.
contract GenesisForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpForkFamily();
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

    /// @notice SUP-03: the tokens placed on the curve equal `genesisTokensForSale()` less burned
    /// dust, and exactly `devAllocation()` sits in the immutable vesting contract. Measured from
    /// the real singleton's balance, not from a local mock's.
    function testFork_SUP03_genesisSupplyIsPlacedOrVested() public {
        _requireFork();
        uint256 inPool = token.balanceOf(POOL_MANAGER);
        uint256 vested = token.balanceOf(factory.devVesting());

        assertEq(vested, factory.devAllocation(), "the allocation is in the vesting contract");
        assertEq(vested, (SUPPLY * devAllocationBps) / 10_000, "3% of the genesis supply");
        assertEq(token.balanceOf(address(locker)), 0, "the locker holds no loose supply");
        assertEq(token.balanceOf(address(this)), 0, "the creator holds nothing");

        uint256 dust = _genesisTokensForSale() - inPool;
        assertLt(dust, 1e12, "curve rounding dust below 1e12 wei");
        assertEq(inPool + vested + dust, SUPPLY, "curve + vesting + burned dust = the whole supply");
        assertEq(token.totalSupply(), inPool + vested, "the dust was burned, not parked");
    }

    /// @notice SUP-02/SUP-08: a candidate places its WHOLE supply with no allocation at all, and
    /// the genesis curve's ticks are denominated in the full supply.
    function testFork_SUP02_candidatePlacesTheWholeSupply() public {
        _requireFork();
        _buyGenesis(5 ether);
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
        assertEq(sqrtPriceX96, initSqrtPriceX96, "spot equals the registered initial price");

        IFamilyHook.RegisteredPool memory p = hook.poolInfo(poolId);
        assertTrue(p.registered, "registered");
        assertTrue(p.isGenesis, "the genesis pool");
        assertEq(p.tradingStart, 0, "genesis trades immediately");

        for (uint256 i = 0; i < ranges.length; i++) {
            assertLt(ranges[i].tickLower, ranges[i].tickUpper, "non-empty range");
            assertLe(ranges[i].tickUpper, TickMath.getTickAtSqrtPrice(initSqrtPriceX96), "at or below spot");
            if (i > 0) assertEq(ranges[i].tickUpper, ranges[i - 1].tickLower, "contiguous");
        }
    }

    /// @notice FEE-01/FEE-02/FEE-08 and ROU-01/02: the first routed buy across the ETH edge pays
    /// exactly one 1% protocol fee plus one 750 ppm hop fee, the four buckets sum to the protocol
    /// fee, and the terminal token's creator is credited.
    function testFork_FEE01_firstRoutedBuyChargesOneEdgeFee() public {
        _requireFork();
        uint256 ethIn = 1 ether;

        uint256 devBefore = vault.devBalance();
        vm.recordLogs();
        uint256 out = familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
        Split[] memory splits = _splits();

        assertGt(out, 0, "the real pool filled the buy");
        assertEq(splits.length, 1, "one leg, one accrual");
        Split memory edge = splits[0];
        assertEq(edge.currency, address(0), "the edge fee is charged in ETH");
        assertEq(edge.protocolFee, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the ETH in");
        assertEq(edge.hopFee, (ethIn * _hopFeePpm()) / PPM, "750 ppm of the ETH in");
        assertEq(edge.dev + edge.creator + edge.sleeve + edge.reinforce, edge.protocolFee, "the four buckets");
        assertEq(edge.dev, (edge.protocolFee * vault.DEV_BPS()) / 10_000, "dev 20%");
        assertEq(edge.creator, (edge.protocolFee * _creatorBps()) / 10_000, "creator 40%");

        assertEq(vault.devBalance() - devBefore, edge.dev, "the dev ledger moved by the event amount");
        assertEq(vault.creatorBalance(address(token)) - 0, edge.creator, "the genesis creator was credited");
        assertEq(vault.creatorRecipient(address(token)), address(this), "claimable by the creator");
        assertEq(address(familyRouter).balance, 0, "the router keeps nothing");
        _assertSolvent();
    }

    /// @notice FEE-13: a partially filled exact-input buy is still charged on the full
    /// `amountSpecified`; the unfillable remainder is refunded by the router. Disclosed (L1).
    function testFork_FEE13_feeBasisIsTheFullSpecifiedAmount() public {
        _requireFork();
        uint256 huge = 5_000 ether;
        uint256 before = address(this).balance;
        vm.recordLogs();
        familyRouter.buyExactIn{value: huge}(0, 0, address(this), 1);
        Split[] memory splits = _splits();

        uint256 spent = before - address(this).balance;
        assertLt(spent, huge, "the curve could not absorb the whole amount");
        assertEq(splits[0].protocolFee, (huge * hook.PROTOCOL_FEE_PPM()) / PPM, "charged on what was specified");
        assertEq(address(familyRouter).balance, 0, "the remainder was refunded, not stranded");
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
        donateRouter.donate{value: 1 ether}(key, 1 ether, 0, "");
    }

    /// @notice SUP-07: pre-initialization poisoning (attack-log #8) is refused by the real
    /// singleton too - an unregistered key, and a registered key one wei off its price.
    function testFork_SUP07_unregisteredKeyAndWrongPriceAreRefused() public {
        _requireFork();
        PoolKey memory rogue = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
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
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: f2.TICK_SPACING(),
            hooks: IHooks(address(h2))
        });
        vm.prank(address(f2));
        h2.registerPool(k2, true, initSqrtPriceX96, 0, 0, true);

        _expectHookRevert(address(h2), IHooks.beforeInitialize.selector, IFamilyHook.WrongInitialPrice.selector);
        manager.initialize(k2, initSqrtPriceX96 + 1);

        manager.initialize(k2, initSqrtPriceX96); // the registered price is accepted
    }
}
