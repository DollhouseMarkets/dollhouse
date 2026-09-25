// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
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
import {Vm} from "forge-std/Vm.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";

contract SwapTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    /// @dev The pool under test is LINK ONE - the EDGE pool. It is quoted in the
    /// adopted external token, carries the 1% protocol fee outside its snipe window, and has that
    /// token as `currency0`, which is exactly the shape the ETH-paired genesis pool had.
    function setUp() public {
        _setUpEdge();
        // past the 3-second snipe window, where the edge fee is suppressed
        vm.warp(block.timestamp + 10);
    }

    function _dollBalance() internal view returns (uint256) {
        return doll.balanceOf(address(this));
    }

    /// @notice Exact-in parent buy: the fee is charged on the specified (parent) side in
    /// `beforeSwap`, so the trader pays exactly `amountIn` and the pool receives it less the fee.
    function test_buyExactIn_chargesParentSideFees() public {
        uint256 amountIn = 1 ether;
        uint256 hopFee = (amountIn * HOP_FEE_PPM) / PPM;
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_PPM) / PPM;
        uint256 expectedTokens = _quoteBuy(amountIn - hopFee - protocolFee);

        uint256 parentBefore = _dollBalance();
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 vaultBefore = _feeVaultEdge();
        _swap(swapRouter, true, -int256(amountIn), "");

        assertEq(_feeVaultEdge() - vaultBefore, hopFee + protocolFee, "1% protocol + 0.1% hop, parent side");
        assertEq(protocolFee, amountIn / 100, "protocol fee is exactly 1%");
        assertEq(parentBefore - _dollBalance(), amountIn, "trader paid exactly the exact-in amount");
        uint256 got = token.balanceOf(address(this)) - tokensBefore;
        assertApproxEqRel(got, expectedTokens, 1e15, "tokens out within 0.1% of the curve");
        assertGt(got, 0);
        _assertNoEth();
    }

    /// @notice Exact-in sell: ETH is the unspecified currency, so the fee is charged in
    /// `afterSwap` out of the ETH the pool pays out.
    function test_sellExactIn_chargesParentSideFees() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        uint256 tokens = token.balanceOf(address(this));
        uint256 vaultBefore = _feeVaultEdge();
        uint256 parentBefore = _dollBalance();

        _swap(swapRouter, false, -int256(tokens), "");

        uint256 parentOut = _dollBalance() - parentBefore;
        uint256 fee = _feeVaultEdge() - vaultBefore;
        uint256 gross = parentOut + fee;
        assertGt(parentOut, 0, "trader received the parent");
        assertEq(token.balanceOf(address(this)), 0, "sold everything");
        assertApproxEqAbs(fee, (gross * TOTAL_FEE_PPM) / PPM, 2, "fee is 1.1% of the parent leg");
        assertApproxEqAbs(
            (gross * PROTOCOL_FEE_PPM) / PPM, (fee * PROTOCOL_FEE_PPM) / TOTAL_FEE_PPM, 2, "1% protocol share"
        );
    }

    /// @notice Exact-out buy: ETH is the unspecified (input) currency; the fee is added on top
    /// of the ETH the pool needs, so the trader still receives exactly the requested tokens. The
    /// rate is a fraction of the TOTAL ETH the trader parts with, exactly as on the exact-in leg:
    /// the hook grosses the pool cost up by `1 / (1 - rate)` before applying it.
    function test_buyExactOut_chargesParentSideFees() public {
        uint256 tokensWanted = 1_000_000e18;
        uint256 vaultBefore = _feeVaultEdge();
        uint256 parentBefore = _dollBalance();

        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(swapRouter, true, int256(tokensWanted), "");

        uint256 parentSpent = parentBefore - _dollBalance();
        uint256 fee = _feeVaultEdge() - vaultBefore;
        assertEq(token.balanceOf(address(this)) - tokensBefore, tokensWanted, "exact output honored");
        assertApproxEqAbs(fee, (parentSpent * TOTAL_FEE_PPM) / PPM, 2, "fee is 1.1% of the TOTAL parent paid");
    }

    /// @notice Exact-OUTPUT sell. The trader names the ETH it wants; the pool pays that plus
    /// the fee, and the fee is `rate` of the GROSS ETH that left the pool - the same basis as the
    /// exact-input sell above and as the exact-output buy. The old code charged `rate` of the
    /// trader's receipt instead, i.e. only `rate / (1 + rate)` of the gross, which quietly made a
    /// sell mode cheaper than the other three.
    function test_sellExactOut_chargesTheSameFeeBasisAsExactIn() public {
        _swap(swapRouter, true, -int256(20 ether), "");
        uint256 tokens = token.balanceOf(address(this));

        // leg 1: exact-IN sell of a tenth of the stack
        uint256 vaultBefore = _feeVaultEdge();
        uint256 parentBefore = _dollBalance();
        _swap(swapRouter, false, -int256(tokens / 10), "");
        uint256 inReceipt = _dollBalance() - parentBefore;
        uint256 inFee = _feeVaultEdge() - vaultBefore;
        uint256 inGross = inReceipt + inFee;

        // leg 2: exact-OUT sell asking for exactly what leg 1 delivered
        vaultBefore = _feeVaultEdge();
        parentBefore = _dollBalance();
        uint256 tokensBefore = token.balanceOf(address(this));
        _swap(swapRouter, false, int256(inReceipt), "");
        uint256 outReceipt = _dollBalance() - parentBefore;
        uint256 outFee = _feeVaultEdge() - vaultBefore;
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

        // the trusted router: its `hookData` is taken at face value. This test deploys the stack
        // against the real {FamilyRouter}, so that - and not a v4 test router - is the one address
        // whose attribution the hook believes.
        vm.recordLogs();
        familyRouter.buyExactIn(1, amountIn, 0, address(this), 1);
        _assertFeeAccrued(hopFee, protocolFee, address(familyRouter), 1);

        // an untrusted caller passing the same word is attributed to nobody
        vm.recordLogs();
        _swap(plainRouter, true, -int256(amountIn), abi.encode(uint256(1)));
        _assertFeeAccrued(hopFee, protocolFee, address(plainRouter), 0);
    }

    /// @dev Assert the ONE {IFamilyHook.FeeAccrued} the last swap emitted.
    function _assertFeeAccrued(uint256 hopFee, uint256 protocolFee, address sender, uint256 terminalIndex) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != IFamilyHook.FeeAccrued.selector) continue;
            seen++;
            assertEq(PoolId.unwrap(poolId), logs[i].topics[1], "the pool");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(doll), "the parent currency");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), sender, "sender");
            (uint256 h, uint256 pf, uint256 t) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(h, hopFee, "hop fee");
            assertEq(pf, protocolFee, "protocol fee");
            assertEq(t, terminalIndex, "attribution");
        }
        assertEq(seen, 1, "exactly one accrual");
    }

    /// @notice Score and price accumulators advance with swaps.
    function test_scoreAndObservationAccumulate() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        IFamilyHook.RegisteredPool memory p1 = hook.poolInfo(poolId);
        assertGt(p1.R, 0, "net parent absorbed is positive after a buy");

        vm.warp(block.timestamp + 60);
        _swap(swapRouter, true, -int256(1 ether), "");
        IFamilyHook.RegisteredPool memory p2 = hook.poolInfo(poolId);
        assertEq(p2.acc - p1.acc, int256(p1.R) * 60, "acc integrates R over the elapsed time");
        assertGt(p2.R, p1.R, "R grows with further absorption");
        assertGt(p2.cumSqrtP, 0, "price observation accumulated");
    }

    /// @notice A candidate pool cannot be traded before its synchronized start.
    function test_swapRevertsBeforeTradingStart() public {
        (FamilyFactory f2, FamilyHook h2) = _deployFactory(address(swapRouter));
        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(address(doll)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: f2.TICK_SPACING(),
            hooks: IHooks(address(h2))
        });
        uint64 tradingStart = uint64(block.timestamp + 600);
        vm.prank(address(f2));
        h2.registerPool(k2, false, initSqrtPriceX96, tradingStart, tradingStart + 900, 0, true);
        manager.initialize(k2, initSqrtPriceX96);

        _expectHookRevert(address(h2), IHooks.beforeSwap.selector, IFamilyHook.TradingNotStarted.selector);
        swapRouter.swap(
            k2,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_gas_swapBuyExactIn() public {
        uint256 gasBefore = gasleft();
        _swap(swapRouter, true, -int256(1 ether), "");
        emit log_named_uint("buy exact-in gas (incl. test router)", gasBefore - gasleft());
        _assertNoEth();
    }
}
