// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A v2-shaped pair: it answers `token0()`/`token1()` and moves tokens on request, the way a
/// fee-on-transfer-tolerant v2 pair settles off its measured balances.
contract MockV2Pair {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    /// @dev What the pair's `swap`/`burn` does to a token: pay `amount` out to `to`.
    function send(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @dev The payer side of {MockV3Pool}.
interface IMockV3Callback {
    function mockV3Callback(address token, uint256 amount) external;
}

/// @dev A v3-shaped pool: it pays the output first, then asks the caller for the input in a
/// callback and checks its OWN balance grew by the full amount (Uniswap v3's `IIA` check), which
/// is exactly what a transfer charge on the input side makes fail.
contract MockV3Pool {
    address public token0;
    address public token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient)
        external
    {
        if (amountOut != 0) IERC20(tokenOut).transfer(recipient, amountOut);
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IMockV3Callback(msg.sender).mockV3Callback(tokenIn, amountIn);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}

/// @dev A minimal ERC-4337-shaped smart account: an owner/entry-point gated `execute`, a
/// `validateUserOp` stub and a payable fallback that answers nothing (as most account
/// implementations' fallback handlers do for an unknown selector).
contract MockSmartAccount {
    address public immutable owner;
    address public immutable entryPoint;

    constructor(address owner_, address entryPoint_) {
        owner = owner_;
        entryPoint = entryPoint_;
    }

    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory ret) {
        require(msg.sender == owner || msg.sender == entryPoint, "not authorised");
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        require(ok, "call failed");
    }

    function validateUserOp(bytes calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    fallback() external payable {}

    receive() external payable {}
}

/// @dev An EIP-7702 delegate implementation (what a delegated EOA's code points at).
contract Mock7702Delegate {
    function execute(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        require(ok, "call failed");
    }

    receive() external payable {}
}
