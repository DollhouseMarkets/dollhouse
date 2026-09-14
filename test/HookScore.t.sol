// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice C1: the score is the NET PARENT THAT STAYS IN THE POOL, in every one of the four
/// swap orientations, and a fee skimmed in `beforeSwap` is counted exactly once.
///
/// The pool's parent delta is not directly observable from a test, but it is exactly
/// `-(trader's parent delta) - (parent-denominated fee the vault collected)` in all four cases:
/// every wei the trader parts with either lands in the pool or is minted to the vault as a
/// 6909 claim. Each case below pins `R` against that identity, measured from real balances.
contract HookScoreTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpFamily();
    }

    /// @dev (trader ETH delta, fee collected) for one swap on the genesis pool.
    function _swapAndMeasure(bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 traderEthDelta, uint256 fee, int128 rBefore, int128 rAfter)
    {
        rBefore = hook.poolInfo(poolId).R;
        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, zeroForOne, amountSpecified, "");
        traderEthDelta = int256(address(this).balance) - int256(ethBefore);
        fee = _feeVaultEth() - vaultBefore;
        rAfter = hook.poolInfo(poolId).R;
    }

    /// @notice AUDIT 9 - UNISWAP'S OWN PROTOCOL FEE. If the v4 fee controller ever switches a
    /// protocol fee on for a family pool, part of the parent a trader pays is taken by the
    /// PoolManager and never becomes pool liquidity. The swapper delta still counts it, so it
    /// would inflate the absorption score a candidate is judged on - a rival could buy a better
    /// score with money that never reached the pool. It is subtracted from the scored input.
    function test_aV4ProtocolFeeDoesNotInflateTheScore() public {
        // the vendored core's own fee-controller path: the test contract owns the PoolManager
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, ProtocolFeeLibrary.MAX_PROTOCOL_FEE | (ProtocolFeeLibrary.MAX_PROTOCOL_FEE << 12));

        uint256 accruedBefore = manager.protocolFeesAccrued(Currency.wrap(address(0)));
        int128 rBefore = hook.poolInfo(poolId).R;
        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, true, -1 ether, "");
        int256 traderEthDelta = int256(address(this).balance) - int256(ethBefore);
        uint256 fee = _feeVaultEth() - vaultBefore;
        int128 rAfter = hook.poolInfo(poolId).R;

        uint256 protocolFee = manager.protocolFeesAccrued(Currency.wrap(address(0))) - accruedBefore;
        assertGt(protocolFee, 0, "the v4 protocol fee really was charged");

        // the score is what STAYED in the pool: the trader's parent, minus this version's own fee
        // claim, minus what Uniswap kept
        int256 expected = -traderEthDelta - int256(fee) - int256(protocolFee);
        assertEq(int256(rAfter) - int256(rBefore), expected, "the v4 protocol fee is not scored");
    }

    function _assertScoreIsPoolDelta(bool zeroForOne, int256 amountSpecified, string memory what) internal {
        (int256 traderEthDelta, uint256 fee, int128 rBefore, int128 rAfter) =
            _swapAndMeasure(zeroForOne, amountSpecified);
        int256 expected = -traderEthDelta - int256(fee);
        assertEq(int256(rAfter) - int256(rBefore), expected, what);
    }

    /// @notice exact-IN buy: the parent is the SPECIFIED currency and the fee is skimmed in
    /// `beforeSwap`. This is the case the old code double-counted.
    function test_scoreExactInParentSpecified() public {
        uint256 amountIn = 1 ether;
        uint256 fee = (amountIn * TOTAL_FEE_PPM) / PPM;
        int128 rBefore = hook.poolInfo(poolId).R;
        _swap(swapRouter, true, -int256(amountIn), "");
        int128 rAfter = hook.poolInfo(poolId).R;

        // the pool received exactly the input minus the fee, and that is the whole score move
        assertEq(int256(rAfter) - int256(rBefore), int256(amountIn - fee), "R = input net of the skimmed fee");
        assertEq(uint256(uint128(rAfter)), amountIn - fee, "exact value, not an approximation");
    }

    /// @notice exact-OUT sell: the parent is the specified currency and the fee is added on top
    /// in `beforeSwap`; the pool pays out the gross, so the score falls by the gross.
    function test_scoreExactOutParentSpecified() public {
        _swap(swapRouter, true, -int256(2 ether), "");
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        _assertScoreIsPoolDelta(false, int256(0.5 ether), "exact-out, parent specified");
    }

    /// @notice exact-IN sell: the parent is the UNSPECIFIED currency, fee charged in `afterSwap`.
    function test_scoreExactInParentUnspecified() public {
        _swap(swapRouter, true, -int256(2 ether), "");
        uint256 tokens = token.balanceOf(address(this)) / 2;
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        _assertScoreIsPoolDelta(false, -int256(tokens), "exact-in, parent unspecified");
    }

    /// @notice exact-OUT buy: the parent is the unspecified (input) currency.
    function test_scoreExactOutParentUnspecified() public {
        _assertScoreIsPoolDelta(true, int256(1_000_000e18), "exact-out, parent unspecified");
    }

    /// @notice The four orientations agree with each other: a buy and the sell that exactly
    /// undoes it leave the score at the net of the two pool deltas, never at a fee-adjusted
    /// number that drifts with the number of swaps.
    function test_scoreIsAdditiveAcrossOrientations() public {
        _swap(swapRouter, true, -int256(1 ether), "");
        int128 r1 = hook.poolInfo(poolId).R;
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);

        uint256 vaultBefore = _feeVaultEth();
        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, false, -int256(token.balanceOf(address(this))), "");
        int256 traderDelta = int256(address(this).balance) - int256(ethBefore);
        uint256 fee = _feeVaultEth() - vaultBefore;

        assertEq(int256(hook.poolInfo(poolId).R), int256(r1) - traderDelta - int256(fee), "additive across swaps");
        assertLt(hook.poolInfo(poolId).R, r1, "selling gives the parent back");
    }

    /// @notice C1: a buy inside the snipe window scores what the POOL absorbed - a small
    /// positive number - and never a negative one. With a 99% snipe tax and a 10 bps hop fee,
    /// 1e18 of parent leaves 0.9% = 0.009e18 in the pool.
    function test_snipeWindowBuyScoresPoolDeltaAndNeverGoesNegative() public {
        _buyGenesis(5 ether);
        Cand memory c = _registerCandidate(address(0xA11CE), "SNIPE");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());

        // exactly at tradingStart the tax is SNIPE_START_PPM = 99%
        vm.warp(tradingStart);
        uint256 amountIn = 1 ether; // 1e18 units of the PARENT token
        uint256 feePpm = hook.SNIPE_START_PPM() + hook.hopFeePpm();
        assertEq(feePpm, 991_000, "99% snipe + 10 bps hop");

        int128 rBefore = hook.poolInfo(c.poolId).R;
        assertEq(rBefore, 0, "a fresh candidate pool starts at zero");
        _tradeCandidate(c, true, amountIn);
        int128 rAfter = hook.poolInfo(c.poolId).R;

        assertEq(uint256(uint128(rAfter)), amountIn - (amountIn * feePpm) / PPM, "R = the pool's own delta");
        assertEq(uint256(uint128(rAfter)), 0.009 ether, "0.9% of the 1e18 buy reached the pool");
        assertGt(rAfter, 0, "a sniped buy can never score negative");
    }

    /// @notice The same buy one second later is taxed less, so it scores more - the score
    /// tracks the pool, not the trader's gross.
    function test_snipeDecayMovesTheScoreNotTheSign() public {
        _buyGenesis(5 ether);
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart);
        _tradeCandidate(a, true, 1 ether);
        vm.warp(tradingStart + 2);
        _tradeCandidate(b, true, 1 ether);

        int128 rEarly = hook.poolInfo(a.poolId).R;
        int128 rLate = hook.poolInfo(b.poolId).R;
        assertGt(rLate, rEarly, "less tax later means more parent stays in the pool");
        assertGt(rEarly, 0);
    }
}
