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

    /// @dev The chain starts with the ADOPTED external genesis at index 0. There is no
    /// pool at index 0; the first pool this protocol owns is link one, crowned by the first round.
    function _setUpFamily() internal {
        _deployProtocol(true);
        _adoptGenesis();
        vm.deal(address(this), 10_000 ether);
    }

    /// @dev {_setUpFamily} plus one won round, so canonical link ONE - the EDGE pool - exists and
    /// {key}, {poolId} and {token} point at it: a $DOLL-quoted pool carrying the 1% protocol fee,
    /// with $DOLL as `currency0`.
    /// @dev The parent-token absorption that carries a candidate over the succession threshold
    /// `H` (0.15% of the parent supply). Both the adopted token and every family token have the
    /// same 1e9 * 1e18 supply, so one figure works at every depth.
    uint256 internal constant WINNING_ABSORPTION = 6_100_000e18;

    function _setUpEdge() internal {
        _setUpFamily();
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
    }

    /// @dev Run enough spaced swaps on every canonical pool that the keeper TWAP covers the
    /// whole {FeeVault.TWAP_WINDOW} and the band guard can be satisfied.
    function _warmOracles() internal {
        uint256 head = roundManager.headIndex();
        for (uint256 k = 0; k < 3; k++) {
            // index 0 has no pool of ours: the canonical chain this protocol quotes starts at 1
            for (uint256 i = 1; i <= head; i++) {
                familyRouter.buyExactIn(i, 0.01 ether, 0, address(this), i + 1);
            }
            vm.warp(block.timestamp + 1_000);
        }
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev Sell the whole link-one position back, which returns the EDGE pool to the top tick of
    /// its own curve - the shape a pool has the moment it launches. Link one is crowned
    /// through a round it had to absorb its way over the threshold with, so there is no un-traded
    /// canonical pool and the launch shape has to be rebuilt; a trade after the bell
    /// cannot move a finished round's score, so nothing else changes.
    function _rewindEdgePool() internal {
        address link1 = roundManager.canonical(1);
        uint256 held = IERC20(link1).balanceOf(address(this));
        if (held == 0) return;
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        familyRouter.sellExactIn(1, held, 0, address(this), 1);
    }

    /// @dev Buy canonical link `j` with the edge currency through the canonical router.
    function _buyLink(uint256 j, uint256 dollIn) internal returns (uint256 out) {
        out = familyRouter.buyExactIn(j, dollIn, 0, address(this), j + 3);
    }

    function _registerCandidate(address creator, string memory name) internal returns (Cand memory c) {
        // NOTE: the bond is read BEFORE the prank; an external call in the argument list would
        // otherwise consume the prank itself
        uint256 bond = roundManager.currentBond();
        // The bond is posted in the EDGE CURRENCY and pulled by the factory
        _fundDoll(creator, bond);
        vm.prank(creator);
        IERC20(address(doll)).approve(address(factory), bond);
        vm.prank(creator);
        (address token, PoolKey memory key, uint256 id) = factory.registerCandidate(name, name, "", type(uint256).max);
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
        IERC20(token).approve(address(familyRouter), type(uint256).max);
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
        // And nothing this protocol owns ends a test holding ETH. Every value this
        // stack moves is an ERC-20, so a contract with a native balance means something
        // arrived by a path nobody designed. Asserted wherever solvency is.
        _assertNoEth();
        Currency edge = vault.EDGE();
        assertLe(vault.ledgerTotal(edge), vault.holdings(edge), "edge ledgers <= edge holdings");
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

    /// @dev The moment `c`'s OWN pool opened - its registration block - which its snipe tax and
    /// accumulator run from. Not the round clock ({_roundTimes}), which is what scoring is
    /// floored at.
    function _poolStart(Cand memory c) internal view returns (uint64) {
        return roundManager.candidateInfo(c.id).tradingStart;
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

    /// @dev v3: the purse is deployed under the generation's TRUNK link, with no
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
        IERC20(parent).approve(address(plainRouter), type(uint256).max);

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
