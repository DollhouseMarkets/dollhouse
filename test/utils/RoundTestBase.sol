// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "./FamilyTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @dev Round-level helpers: registering candidates, trading against a gated candidate pool in
/// either orientation, and running a whole round to a winner.
abstract contract RoundTestBase is FamilyTestBase {
    using StateLibrary for IPoolManager;

    struct Cand {
        address token;
        PoolKey key;
        PoolId poolId;
        uint256 id;
        bool tokenIsCurrency0;
        address creator;
    }

    Cand[] internal cands;

    function _setUpFamily() internal {
        _deployProtocol(true);
        _createGenesis();
        vm.deal(address(this), 10_000 ether);
    }

    /// @dev Run enough spaced swaps on every canonical pool that the keeper TWAP covers the
    /// whole {FeeVault.TWAP_WINDOW} and the band guard can be satisfied (M2).
    function _warmOracles() internal {
        uint256 head = roundManager.headIndex();
        for (uint256 k = 0; k < 3; k++) {
            for (uint256 i = 0; i <= head; i++) {
                familyRouter.buyExactIn{value: 0.01 ether}(i, 0, address(this), i + 1);
            }
            vm.warp(block.timestamp + 1_000);
        }
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Buy genesis tokens through the canonical router (the ETH edge).
    function _buyGenesis(uint256 ethIn) internal returns (uint256 out) {
        out = familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 4);
    }

    function _registerCandidate(address creator, string memory name) internal returns (Cand memory c) {
        // NOTE: the bond is read BEFORE the prank; an external call in the argument list would
        // otherwise consume the prank itself
        uint256 bond = roundManager.currentBond();
        vm.deal(creator, bond);
        vm.prank(creator);
        (address token, PoolKey memory key, uint256 id) = factory.registerCandidate{value: bond}(name, name, "");
        c = Cand({
            token: token,
            key: key,
            poolId: key.toId(),
            id: id,
            tokenIsCurrency0: Currency.unwrap(key.currency0) == token,
            creator: creator
        });
        cands.push(c);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        IERC20(token).approve(address(plainRouter), type(uint256).max);
    }

    /// @dev Exact-in swap against a candidate pool, in whichever orientation it launched with.
    /// `parentIn == true` buys the candidate with parent tokens; `false` sells it back.
    function _tradeCandidate(Cand memory c, bool parentIn, uint256 amountIn) internal returns (uint256 amountOut) {
        bool zeroForOne = parentIn ? !c.tokenIsCurrency0 : c.tokenIsCurrency0;
        BalanceDelta delta = swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        amountOut = out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @dev The solvency invariant: every ledger the vault keeps is backed by what it holds
    /// (real balance plus unredeemed ERC-6909 claims), currency by currency.
    function _assertSolvent() internal view {
        Currency eth = Currency.wrap(address(0));
        assertLe(vault.ledgerTotal(eth), vault.holdings(eth), "ETH ledgers <= ETH holdings");
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            Currency c = Currency.wrap(roundManager.canonical(i));
            assertLe(vault.ledgerTotal(c), vault.holdings(c), "token ledgers <= token holdings");
        }
    }

    /// @dev The round's PUBLISHED schedule: its start, its nominal end `T` and the earliest the
    /// submission window can close. The TRUE end is drawn later and is never later than `T`, so
    /// these are the times a test plans against; {_settleEnd} then makes them real.
    function _roundTimes(uint256 roundId)
        internal
        view
        returns (uint64 tradingStart, uint64 nominalEnd, uint64 submitEnd)
    {
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        return (r.tradingStart, r.nominalEnd, r.nominalEnd + roundManager.SUBMIT_S());
    }

    /// @dev Settle the current round's random end at `T` exactly: warp to the nominal end, pin
    /// the randomness and relay a word of 0 (the mock's default), so `T_end == T` and the
    /// submission window opens at `T`. Tests that want a real offset set
    /// `randomness.setDefaultWord(...)` first, or call {_settleEndWith}.
    function _settleEnd() internal returns (uint64 tradingEnd, uint64 submitEnd) {
        return _settleEndWith(0);
    }

    function _settleEndWith(uint256 word) internal returns (uint64 tradingEnd, uint64 submitEnd) {
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        if (r.tradingEnd != 0) return (r.tradingEnd, r.submitEnd);
        if (block.timestamp < r.nominalEnd) vm.warp(r.nominalEnd);
        roundManager.requestEnd();
        if (randomness.DELAY_S() != 0) vm.warp(block.timestamp + randomness.DELAY_S());
        roundManager.fulfilEnd(abi.encode(word));
        r = roundManager.roundInfo(roundId);
        return (r.tradingEnd, r.submitEnd);
    }

    /// @dev v3 (review 3): the purse is deployed under the generation's TRUNK link, with no
    /// ranking and no split. One call, one destination.
    function _deployAncestor(uint256 j, uint256 amount) internal returns (uint256 deposited) {
        return bidDeployer.deployAncestor(j, amount);
    }

    /// @dev As {_deployAncestor}, but as `who`.
    function _deployAncestorAs(address who, uint256 j, uint256 amount) internal returns (uint256 deposited) {
        vm.prank(who);
        return bidDeployer.deployAncestor(j, amount);
    }

    /// @dev Register `n` candidates, push candidate 0 above the threshold, and finalize. Returns
    /// the winning token.
    function _runWinningRound(uint256 n, uint256 parentBuy) internal returns (Cand memory winner) {
        delete cands;
        for (uint256 i = 0; i < n; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i + block.timestamp)), "CAND");
        }
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);

        vm.warp(tradingStart + 5);
        _tradeCandidate(cands[0], true, parentBuy);
        // the other candidates absorb a token amount far below H
        for (uint256 i = 1; i < n; i++) {
            _tradeCandidate(cands[i], true, parentBuy / 100);
        }

        _settleEnd();
        for (uint256 i = 0; i < n; i++) {
            roundManager.submitScore(cands[i].id);
        }
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        winner = cands[0];
    }
}
