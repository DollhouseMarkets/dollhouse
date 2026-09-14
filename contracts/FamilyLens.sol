// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "./FamilyFactory.sol";
import {FamilyHook} from "./FamilyHook.sol";
import {RoundManager} from "./RoundManager.sol";
import {IFamilyHook} from "./interfaces/IFamilyHook.sol";

/// @title FamilyLens
/// @notice Read-only, batched views for the UI and indexers. It holds no state, has no
/// privileges, and never writes: everything here is derivable from the RoundManager, the hook
/// and the PoolManager, just expensive to fetch one call at a time.
contract FamilyLens {
    using StateLibrary for IPoolManager;

    struct CandidateView {
        uint256 candidateId;
        address token;
        PoolId poolId;
        address creator;
        bool submitted;
        int256 avg;
        int128 R;
        int256 acc;
        uint160 spotSqrtPriceX96;
        uint256 tokensSold;
    }

    struct RoundView {
        RoundManager.Phase phase;
        uint256 roundId;
        uint64 openedAt;
        uint64 registrationEnd;
        uint64 tradingStart;
        uint64 lateEntryEnd;
        uint64 nominalEnd;
        uint64 tradingEnd;
        uint64 submitEnd;
        uint256 H;
        uint256 parentIndex;
        address parentToken;
        uint256 candidateCount;
        bool finalized;
        bool hasWinner;
        uint256 winnerCandidateId;
    }

    struct LinkView {
        uint256 index;
        address token;
        address parent;
        address creator;
        PoolId poolId;
        uint160 spotSqrtPriceX96;
        uint256 parentReserve;
        uint256 tokenReserve;
        uint128 liquidity;
    }

    IPoolManager public immutable poolManager;
    FamilyFactory public immutable factory;
    FamilyHook public immutable hook;
    RoundManager public immutable roundManager;

    constructor(FamilyFactory _factory) {
        factory = _factory;
        poolManager = _factory.poolManager();
        hook = _factory.hook();
        roundManager = _factory.roundManager();
    }

    /// @notice Everything about a round, with its candidate list paginated by `(offset, limit)`.
    function roundView(uint256 roundId, uint256 offset, uint256 limit)
        external
        view
        returns (RoundView memory view_, CandidateView[] memory candidates)
    {
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        view_ = RoundView({
            phase: roundManager.phase(roundId),
            roundId: roundId,
            openedAt: r.openedAt,
            registrationEnd: r.registrationEnd,
            tradingStart: r.tradingStart,
            lateEntryEnd: r.lateEntryEnd,
            nominalEnd: r.nominalEnd,
            tradingEnd: r.tradingEnd,
            submitEnd: r.submitEnd,
            H: r.hUsed,
            parentIndex: r.parentIndex,
            parentToken: r.parentToken,
            candidateCount: r.candidateCount,
            finalized: r.finalized,
            hasWinner: r.hasWinner,
            winnerCandidateId: r.winnerCandidateId
        });

        // AUDIT 11: the PAGE, not the whole array. Loading every id of a spammed round only to
        // throw all but `limit` of them away made this view's gas grow with the number of
        // candidates, so the one read an indexer needs could exceed an `eth_call` gas limit
        // exactly when a round is being spammed.
        (uint256[] memory ids,) = roundManager.candidateIds(roundId, offset, limit);
        candidates = new CandidateView[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            candidates[i] = candidateView(ids[i]);
        }
    }

    function candidateView(uint256 candidateId) public view returns (CandidateView memory v) {
        RoundManager.Candidate memory c = roundManager.candidateInfo(candidateId);
        PoolId id = c.key.toId();
        IFamilyHook.RegisteredPool memory p = hook.poolInfo(id);
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        v = CandidateView({
            candidateId: candidateId,
            token: c.token,
            poolId: id,
            creator: c.creator,
            submitted: c.submitted,
            avg: c.avg,
            R: p.R,
            acc: p.acc,
            spotSqrtPriceX96: sqrtP,
            tokensSold: IERC20(c.token).totalSupply() - IERC20(c.token).balanceOf(address(poolManager))
        });
    }

    /// @notice The canonical chain from index `from` to index `to` (inclusive), with spot prices
    /// and the virtual reserves of each pool's active tick range.
    function chainView(uint256 from, uint256 to) external view returns (LinkView[] memory links) {
        uint256 head = roundManager.headIndex();
        if (to > head) to = head;
        if (from > to) return new LinkView[](0);
        links = new LinkView[](to - from + 1);
        for (uint256 i = from; i <= to; i++) {
            address token = roundManager.canonical(i);
            PoolKey memory key = roundManager.poolKeyOf(i);
            PoolId id = key.toId();
            (uint160 sqrtP,,,) = poolManager.getSlot0(id);
            uint128 L = poolManager.getLiquidity(id);
            bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
            uint256 amount0 = sqrtP == 0 ? 0 : FullMath.mulDiv(L, FixedPoint96.Q96, sqrtP);
            uint256 amount1 = FullMath.mulDiv(L, sqrtP, FixedPoint96.Q96);
            links[i - from] = LinkView({
                index: i,
                token: token,
                parent: roundManager.parentOf(token),
                creator: roundManager.creatorOf(token),
                poolId: id,
                spotSqrtPriceX96: sqrtP,
                parentReserve: tokenIsCurrency0 ? amount1 : amount0,
                tokenReserve: tokenIsCurrency0 ? amount0 : amount1,
                liquidity: L
            });
        }
    }
}
