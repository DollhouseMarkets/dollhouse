// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";

/// @notice REGRESSIONS pinning the dead-successor evidence and schedule properties. Related
/// properties are also exercised beside related tests in `Review4.t.sol` and
/// `DeployConstants.t.sol`.
contract Review4cTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    // ---------------------------------------------------------------------------------
    // a candidate pool must have a published end after its start
    // ---------------------------------------------------------------------------------

    /// @notice The published end `T` is what freezes the score rings and what every scored window
    /// is measured back from. A candidate registered with `nominalEnd == 0` is therefore frozen
    /// before it opens: it accumulates nothing, writes no ring entry, and can never be scored,
    /// while still charging the hop fee on every swap. The factory always passes a real end; the
    /// hook guarantees it too, so no other caller can register a pool that is dead on arrival.
    function test_F_C_aCandidatePoolCannotBeRegisteredWithoutAnEndAfterItsStart() public {
        PoolKey memory k = _candidateKey(address(0xC0FFEE));
        uint64 start = uint64(block.timestamp) + 60;

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, false, initSqrtPriceX96, start, 0, 0, false);

        // an end AT the start measures nothing either
        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, false, initSqrtPriceX96, start, start, 0, false);

        // and a real one registers
        vm.prank(address(factory));
        hook.registerPool(k, false, initSqrtPriceX96, start, start + 900, 0, false);
        assertEq(hook.poolInfo(k.toId()).nominalEnd, start + 900, "the candidate carries its end");

        // The freeze is UNIVERSAL. There is no genesis exemption any more - every pool
        // this protocol owns is launched by a round - so an EDGE pool is held to exactly the same
        // rule as any other candidate.
        PoolKey memory g = _candidateKey(address(0xDEADBEEF));
        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(g, true, initSqrtPriceX96, start, 0, 0, false);

        vm.prank(address(factory));
        hook.registerPool(g, true, initSqrtPriceX96, start, start + 900, 0, false);
        assertTrue(hook.poolInfo(g.toId()).isEdge, "an edge pool...");
        assertEq(hook.poolInfo(g.toId()).nominalEnd, start + 900, "...with an end like every other");
    }

    function _candidateKey(address other) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(DOLL_ADDRESS),
            currency1: Currency.wrap(other),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }
}
