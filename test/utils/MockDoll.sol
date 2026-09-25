// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A plain 18-decimal ERC-20 standing in for the externally launched genesis token
/// ($DOLL) the protocol adopts as canonical index 0. The real one is minted and graduated on a
/// launch venue this protocol never calls; nothing here models that venue, because nothing in the
/// stack touches it. Mint is open so a test can fund any actor.
contract MockDoll is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Dollhouse", "DOLL") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
