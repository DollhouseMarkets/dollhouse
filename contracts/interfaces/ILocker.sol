// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurveRange} from "../types/CurveRange.sol";

interface ILocker {
    event CurvePlaced(bytes32 indexed poolId, uint256 rangeCount, uint256 tokenPlaced, uint256 dustBurned);
    event BidDeposited(
        bytes32 indexed poolId, uint256 parentAmount, int24 tickLower, int24 tickUpper, uint128 liquidity
    );

    error NotFactory();
    error NotBidDeployer();
    error NotPoolManager();
    error NoRanges();
    error ParentOwed();
    error TokenOwed();
    error BidStraddlesSpot();
    error NothingToDeposit();
    error WrongValue();

    function placeStandardCurve(PoolKey calldata key, CurveRange[] calldata ranges, bool tokenIsCurrency0) external;

    function depositBid(PoolKey calldata key, uint256 parentAmount, int24 tickLower, int24 tickUpper)
        external
        payable
        returns (uint128 liquidity);
}
