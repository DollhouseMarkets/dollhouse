// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "./utils/FamilyTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {CurveRange} from "../contracts/types/CurveRange.sol";
import {ILocker} from "../contracts/interfaces/ILocker.sol";

contract GenesisTest is FamilyTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployProtocol();
        _createGenesis();
    }

    /// @notice Everything except the disclosed, vested developer allocation is locked liquidity:
    /// nothing loose in the Locker, nothing for the creator, and the only supply outside the pool
    /// is the allocation sitting in the immutable {DevVesting} contract.
    function test_supplyIsEntirelyLocked() public {
        assertEq(token.balanceOf(address(locker)), 0, "locker holds no loose supply");
        assertEq(token.balanceOf(address(this)), 0, "creator holds nothing");

        uint256 inPool = token.balanceOf(address(manager));
        uint256 vested = token.balanceOf(factory.devVesting());
        assertEq(vested, factory.devAllocation(), "the allocation is in the vesting contract");
        assertEq(token.totalSupply(), inPool + vested, "all remaining supply is in the pool or vesting");
        uint256 dust = _genesisTokensForSale() - inPool;
        emit log_named_uint("curve rounding dust burned (wei)", dust);
        assertLt(dust, 1e12, "rounding dust below 1e12 wei");
        assertEq(inPool + vested + dust, SUPPLY, "curve + vesting + burned dust = the whole supply");
    }

    function test_poolIsRegisteredAndPriced() public view {
        IFamilyHook.RegisteredPool memory p = hook.poolInfo(poolId);
        assertTrue(p.registered);
        assertTrue(p.isGenesis);
        assertEq(p.initSqrtPriceX96, initSqrtPriceX96);
        assertEq(p.tradingStart, 0, "genesis trades immediately");

        (uint160 sqrtPriceX96,,,) = im.getSlot0(poolId);
        assertEq(sqrtPriceX96, initSqrtPriceX96);
        assertEq(factory.genesisCreator(), address(this));
        assertEq(factory.genesisToken(), address(token));
    }

    function test_curveRangesAreContiguousAndTokenOnly() public view {
        for (uint256 i = 0; i < ranges.length; i++) {
            assertLt(ranges[i].tickLower, ranges[i].tickUpper, "non-empty range");
            assertLe(ranges[i].tickUpper, TickMath.getTickAtSqrtPrice(initSqrtPriceX96), "at or below spot");
            if (i > 0) assertEq(ranges[i].tickUpper, ranges[i - 1].tickLower, "contiguous");
        }
    }

    function test_genesisIsOnceOnly() public {
        vm.expectRevert(FamilyFactory.GenesisAlreadyCreated.selector);
        factory.createGenesis("Again", "AGAIN", "");
    }

    function test_initializeRevertsForUnregisteredKey() public {
        PoolKey memory rogue = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 120, // not the registered key
            hooks: IHooks(address(hook))
        });
        _expectHookRevert(address(hook), IHooks.beforeInitialize.selector, IFamilyHook.PoolNotRegistered.selector);
        manager.initialize(rogue, initSqrtPriceX96);
    }

    function test_initializeRevertsAtWrongPrice() public {
        // a second, independent deployment lets us register a key without initializing it
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

        // the registered price works
        manager.initialize(k2, initSqrtPriceX96);
    }

    function test_registerPoolOnlyFactory() public {
        vm.expectRevert(IFamilyHook.NotFactory.selector);
        hook.registerPool(key, true, initSqrtPriceX96, 0, 0, true);
    }

    function test_addLiquidityRevertsForNonLocker() public {
        _expectHookRevert(address(hook), IHooks.beforeAddLiquidity.selector, IFamilyHook.OnlyLocker.selector);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: ranges[0].tickLower, tickUpper: ranges[0].tickUpper, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        );
    }

    function test_removeLiquidityAlwaysReverts() public {
        _expectHookRevert(address(hook), IHooks.beforeRemoveLiquidity.selector, IFamilyHook.LiquidityIsLocked.selector);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: ranges[0].tickLower, tickUpper: ranges[0].tickUpper, liquidityDelta: -1e18, salt: bytes32(0)
            }),
            ""
        );
    }

    function test_donateReverts() public {
        _expectHookRevert(address(hook), IHooks.beforeDonate.selector, IFamilyHook.DonationDisabled.selector);
        donateRouter.donate{value: 1 ether}(key, 1 ether, 0, "");
    }

    function test_lockerHasNoExit() public {
        // only the FeeVault's keeper path may deposit a bid, and only the factory places curves
        vm.expectRevert(ILocker.NotBidDeployer.selector);
        locker.depositBid(key, 1 ether, -120, -60);

        vm.expectRevert(ILocker.NotFactory.selector);
        locker.placeStandardCurve(key, ranges, false);
    }

    function test_registerCandidateRequiresTheBond() public {
        vm.expectRevert(FamilyFactory.WrongBond.selector);
        factory.registerCandidate("Candidate", "CAND", "");

        uint256 shortBond = roundManager.currentBond() - 1;
        vm.expectRevert(FamilyFactory.WrongBond.selector);
        factory.registerCandidate{value: shortBond}("Candidate", "CAND", "");
    }

    function test_gas_createGenesis() public {
        // fresh deployment so the measurement is a real first genesis
        (FamilyFactory f2,) = _deployFactory(address(swapRouter));
        uint256 gasBefore = gasleft();
        f2.createGenesis("Family Genesis", "FAM", "ipfs://genesis");
        emit log_named_uint("createGenesis gas", gasBefore - gasleft());
    }
}
