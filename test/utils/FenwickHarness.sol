// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FenwickRangeAdd} from "../../contracts/libraries/FenwickRangeAdd.sol";

/// @dev Thin wrapper so tests can drive exactly the tree the FeeVault uses.
contract FenwickHarness {
    using FenwickRangeAdd for FenwickRangeAdd.Tree;

    FenwickRangeAdd.Tree internal tree;

    function addSleeve(uint256 sleeve, uint256 M) external {
        tree.addSleeve(sleeve, M);
    }

    function rangeAdd(uint256 l, uint256 r, int256 c0, int256 c1, int256 c2) external {
        tree.rangeAdd(l, r, c0, c1, c2);
    }

    function query(uint256 j) external view returns (int256) {
        return tree.query(j);
    }

    function coefficientPrefix(uint256 k, uint256 j) external view returns (int256) {
        return tree.coefficientPrefix(k, j);
    }
}
