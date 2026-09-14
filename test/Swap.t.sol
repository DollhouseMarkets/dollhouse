// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "./utils/FamilyTestBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";

contract SwapTest is FamilyTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployProtocol();
        _createGenesis();
        vm.deal(address(this), 1_000 ether);
    }

    /// @notice Exact-in ETH buy: the fee is charged on the specified (ETH) side in `beforeSwap`,
    /// so the trader pays exactly 1 ETH and the pool receives 1 ETH minus the fee.
    function test_buyExactIn_chargesEthSideFees() public {
        uint256 amountIn = 1 ether;
        uint256 hopFee = (amountIn * HOP_FEE_PPM) / PPM;
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_PPM) / PPM;
        uint256 expectedTokens = _quoteBuy(amountIn - hopFee - protocolFee);

        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, true, -int256(amountIn), "");

        assertEq(_feeVaultEth(), hopFee + protocolFee, "1% protocol + 0.1% hop on the ETH side");
        assertEq(protocolFee, amountIn / 100, "protocol fee is exactly 1%");
        assertEq(ethBefore - address(this).balance, amountIn, "trader paid exactly the exact-in amount");
        assertApproxEqRel(token.balanceOf(address(this)), expectedTokens, 1e15, "tokens out within 0.1% of the curve");
        assertGt(token.balanceOf(address(this)), 0);
    }

    /// @notice Exact-in sell: ETH is the unspecified currency, so the fee is charged in
    /// `afterSwap` out of the ETH the pool pays out.
    function test_sellExactIn_chargesEthSideFees() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        uint256 tokens = token.balanceOf(address(this));
        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;

        _swap(swapRouter, false, -int256(tokens), "");

        uint256 ethOut = address(this).balance - ethBefore;
        uint256 fee = _feeVaultEth() - vaultBefore;
        uint256 gross = ethOut + fee;
        assertGt(ethOut, 0, "trader received ETH");
        assertEq(token.balanceOf(address(this)), 0, "sold everything");
        assertApproxEqAbs(fee, (gross * TOTAL_FEE_PPM) / PPM, 2, "fee is 1.1% of the ETH leg");
        assertApproxEqAbs(
            (gross * PROTOCOL_FEE_PPM) / PPM, (fee * PROTOCOL_FEE_PPM) / TOTAL_FEE_PPM, 2, "1% protocol share"
        );
    }

    /// @notice Exact-out buy: ETH is the unspecified (input) currency; the fee is added on top
    /// of the ETH the pool needs, so the trader still receives exactly the requested tokens. The
    /// rate is a fraction of the TOTAL ETH the trader parts with, exactly as on the exact-in leg:
    /// the hook grosses the pool cost up by `1 / (1 - rate)` before applying it.
    function test_buyExactOut_chargesEthSideFees() public {
        uint256 tokensWanted = 1_000_000e18;
        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;

        _swap(swapRouter, true, int256(tokensWanted), "");

        uint256 ethSpent = ethBefore - address(this).balance;
        uint256 fee = _feeVaultEth() - vaultBefore;
        assertEq(token.balanceOf(address(this)), tokensWanted, "exact output honored");
        assertApproxEqAbs(fee, (ethSpent * TOTAL_FEE_PPM) / PPM, 2, "fee is 1.1% of the TOTAL ETH paid");
    }

    /// @notice F9: exact-OUTPUT sell. The trader names the ETH it wants; the pool pays that plus
    /// the fee, and the fee is `rate` of the GROSS ETH that left the pool - the same basis as the
    /// exact-input sell above and as the exact-output buy. The old code charged `rate` of the
    /// trader's receipt instead, i.e. only `rate / (1 + rate)` of the gross, which quietly made a
    /// sell mode cheaper than the other three.
    function test_sellExactOut_chargesTheSameFeeBasisAsExactIn() public {
        _swap(swapRouter, true, -int256(20 ether), "");
        uint256 tokens = token.balanceOf(address(this));

        // leg 1: exact-IN sell of a tenth of the stack
        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, false, -int256(tokens / 10), "");
        uint256 inReceipt = address(this).balance - ethBefore;
        uint256 inFee = _feeVaultEth() - vaultBefore;
        uint256 inGross = inReceipt + inFee;

        // leg 2: exact-OUT sell asking for exactly what leg 1 delivered
        vaultBefore = _feeVaultEth();
        ethBefore = address(this).balance;
        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(swapRouter, false, int256(inReceipt), "");
        uint256 outReceipt = address(this).balance - ethBefore;
        uint256 outFee = _feeVaultEth() - vaultBefore;
        uint256 outGross = outReceipt + outFee;

        assertEq(outReceipt, inReceipt, "the exact-output leg delivered exactly what was asked");
        assertLt(token.balanceOf(address(this)), tokensBefore, "and it cost tokens");

        // both legs charge the SAME fraction of the gross parent the pool paid out
        assertApproxEqAbs(inFee, (inGross * TOTAL_FEE_PPM) / PPM, 2, "exact-in: rate of the gross");
        assertApproxEqAbs(outFee, (outGross * TOTAL_FEE_PPM) / PPM, 2, "exact-out: rate of the gross too");
        assertApproxEqRel(outFee, inFee, 1e15, "the two sell modes cost the same to 0.1%");

        // and it really is more than the old `rate / (1 + rate)` basis
        uint256 oldBasisFee = (outReceipt * TOTAL_FEE_PPM) / PPM;
        assertGt(outFee, oldBasisFee, "the gross-up is what makes the rate symmetric");
    }

    /// @notice hookData is only trusted from the canonical router.
    function test_attributionOnlyFromRouter() public {
        uint256 amountIn = 1 ether;
        uint256 hopFee = (amountIn * HOP_FEE_PPM) / PPM;
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_PPM) / PPM;

        vm.expectEmit(true, true, true, true, address(hook));
        emit IFamilyHook.FeeAccrued(poolId, CurrencyLibrary.ADDRESS_ZERO, hopFee, protocolFee, address(swapRouter), 42);
        _swap(swapRouter, true, -int256(amountIn), abi.encode(uint256(42)));

        vm.expectEmit(true, true, true, true, address(hook));
        emit IFamilyHook.FeeAccrued(poolId, CurrencyLibrary.ADDRESS_ZERO, hopFee, protocolFee, address(plainRouter), 0);
        _swap(plainRouter, true, -int256(amountIn), abi.encode(uint256(42)));
    }

    /// @notice Score and price accumulators advance with swaps.
    function test_scoreAndObservationAccumulate() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        IFamilyHook.RegisteredPool memory p1 = hook.poolInfo(poolId);
        assertGt(p1.R, 0, "net parent absorbed is positive after a buy");
        assertEq(p1.acc, 0, "no elapsed time yet");

        vm.warp(block.timestamp + 60);
        _swap(swapRouter, true, -int256(1 ether), "");
        IFamilyHook.RegisteredPool memory p2 = hook.poolInfo(poolId);
        assertEq(p2.acc, int256(p1.R) * 60, "acc integrates R over time");
        assertGt(p2.R, p1.R, "R grows with further absorption");
        assertGt(p2.cumSqrtP, 0, "price observation accumulated");
    }

    /// @notice A candidate pool cannot be traded before its synchronized start.
    function test_swapRevertsBeforeTradingStart() public {
        (FamilyFactory f2, FamilyHook h2) = _deployFactory(address(swapRouter));
        PoolKey memory k2 = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: f2.TICK_SPACING(),
            hooks: IHooks(address(h2))
        });
        uint64 tradingStart = uint64(block.timestamp + 600);
        vm.prank(address(f2));
        h2.registerPool(k2, false, initSqrtPriceX96, tradingStart, 0, true);
        manager.initialize(k2, initSqrtPriceX96);

        _expectHookRevert(address(h2), IHooks.beforeSwap.selector, IFamilyHook.TradingNotStarted.selector);
        swapRouter.swap{value: 1 ether}(
            k2,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_gas_swapBuyExactIn() public {
        uint256 gasBefore = gasleft();
        _swap(swapRouter, true, -int256(1 ether), "");
        emit log_named_uint("buy 1 ETH exact-in gas (incl. test router)", gasBefore - gasleft());
    }
}
