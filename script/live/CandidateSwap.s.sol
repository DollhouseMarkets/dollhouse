// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @title CandidateSwap
/// @notice Trades a CANDIDATE pool, which {FamilyRouter} cannot reach.
///
/// @dev The router only routes CANONICAL links: every leg resolves its PoolKey through
/// `RoundManager.poolKeyOf(index)`, and a candidate has no canonical index until it wins. So a
/// candidate pool has to be driven straight through the PoolManager, and the cheapest working
/// path is the stock v4 `PoolSwapTest` harness (deployed once by `round.sh`).
///
/// Consequence, recorded deliberately: the hook only trusts `hookData` attribution when the
/// swap's `sender` is the canonical router, so these candidate trades are UNATTRIBUTED — the
/// parent-side hop fee still accrues to the parent's reinforcement sleeve, but no creator share
/// is credited. That is the same treatment any third-party router gets.
contract CandidateSwap is Script {
    function run() external {
        PoolSwapTest swapTest = PoolSwapTest(vm.envAddress("SWAP_TEST"));
        RoundManager roundManager = RoundManager(vm.envAddress("ROUND_MANAGER"));
        uint256 candidateId = vm.envUint("CANDIDATE_ID");
        // true: spend parent tokens to buy the candidate. false: sell the candidate back.
        bool parentIn = vm.envBool("PARENT_IN");
        // spend this many basis points of the caller's balance of the input token
        uint256 amountBps = vm.envUint("AMOUNT_BPS");

        RoundManager.Candidate memory c = roundManager.candidateInfo(candidateId);
        PoolKey memory key = c.key;
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == c.token;
        address parent = tokenIsCurrency0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        address input = parentIn ? parent : c.token;

        // buying the candidate spends the parent: that is zeroForOne exactly when the parent is
        // currency0, i.e. when the candidate token is NOT currency0
        bool zeroForOne = parentIn ? !tokenIsCurrency0 : tokenIsCurrency0;

        address me = msg.sender;
        uint256 amountIn = (IERC20(input).balanceOf(me) * amountBps) / 10_000;
        require(amountIn > 0, "nothing to spend");

        uint256 outBefore = IERC20(parentIn ? c.token : parent).balanceOf(me);

        vm.startBroadcast();
        if (IERC20(input).allowance(me, address(swapTest)) < amountIn) {
            IERC20(input).approve(address(swapTest), type(uint256).max);
        }
        swapTest.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        uint256 outAfter = IERC20(parentIn ? c.token : parent).balanceOf(me);
        console2.log("candidateId", candidateId);
        console2.log("amountIn", amountIn);
        console2.log("amountOut", outAfter - outBefore);
    }
}
