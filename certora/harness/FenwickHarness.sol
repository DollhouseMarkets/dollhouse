// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FenwickRangeAdd} from "../../contracts/libraries/FenwickRangeAdd.sol";

/// @title FenwickHarness
/// @notice Thin external wrapper over the internal `FenwickRangeAdd` library so the ancestor
/// sleeve can be verified directly (PROTOCOL_SPEC §J "Ancestor polynomial", PROPERTIES SLV-01..07).
/// @dev No logic of its own: every function forwards one-to-one to the library. The single
/// `Tree` mirrors `FeeVault.ancestorTree`, which is the only sleeve tree the protocol keeps.
contract FenwickHarness {
    using FenwickRangeAdd for FenwickRangeAdd.Tree;

    FenwickRangeAdd.Tree internal tree;

    function MAX_INDEX() external pure returns (uint256) {
        return FenwickRangeAdd.MAX_INDEX;
    }

    function WAD() external pure returns (uint256) {
        return FenwickRangeAdd.WAD;
    }

    function rangeAdd(uint256 l, uint256 r, int256 c0, int256 c1, int256 c2) external {
        tree.rangeAdd(l, r, c0, c1, c2);
    }

    function addSleeve(uint256 sleeve, uint256 M) external {
        tree.addSleeve(sleeve, M);
    }

    function query(uint256 j) external view returns (int256) {
        return tree.query(j);
    }

    function coefficientPrefix(uint256 k, uint256 j) external view returns (int256) {
        return tree.coefficientPrefix(k, j);
    }
}
