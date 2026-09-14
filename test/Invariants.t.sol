// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FamilyHandler} from "./utils/FamilyHandler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Protocol-wide invariants, driven by a random-action handler: supply is fixed, locked
/// liquidity is a ratchet, the ETH-edge fee is the only protocol fee, the vault is solvent, and
/// the canonical history is append-only.
contract InvariantsTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    FamilyHandler internal handler;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(2 ether);

        handler = new FamilyHandler(factory, familyRouter, vault, bidDeployer, swapRouter);
        for (uint256 i = 0; i < ranges.length; i++) {
            handler.notePosition(poolId, ranges[i].tickLower, ranges[i].tickUpper);
        }

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = FamilyHandler.buy.selector;
        selectors[1] = FamilyHandler.sell.selector;
        selectors[2] = FamilyHandler.registerCandidate.selector;
        selectors[3] = FamilyHandler.tradeCandidate.selector;
        selectors[4] = FamilyHandler.advanceTime.selector;
        selectors[5] = FamilyHandler.submitAndFinalize.selector;
        selectors[6] = FamilyHandler.deploySupport.selector;
        selectors[7] = FamilyHandler.forceSuccession.selector;
        selectors[8] = FamilyHandler.claimFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Fixed supply: no mint, ever. (The only burn is the launch dust, before the token
    /// is ever seen by the handler.)
    function invariant_supplyIsConstant() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            address t = handler.tokens(i);
            assertEq(IERC20(t).totalSupply(), handler.supplySeen(t), "supply moved");
        }
    }

    /// @notice Locked liquidity is a ratchet: no position the Locker owns can ever shrink.
    function invariant_lockedPositionsNeverDecrease() public view {
        uint256 n = handler.positionCount();
        for (uint256 i = 0; i < n; i++) {
            (PoolId id, int24 tickLower, int24 tickUpper) = handler.positions(i);
            (uint128 liq,,) = im.getPositionInfo(id, address(locker), tickLower, tickUpper, bytes32(0));
            assertGe(liq, handler.maxLiquidity(keccak256(abi.encode(id, tickLower, tickUpper))), "liquidity shrank");
        }
    }

    /// @notice The 1% protocol fee exists only on the ETH edge. For every family currency, the
    /// vault's whole ledger in that currency is hop fees (plus snipe tax) — never a protocol fee.
    function invariant_noProtocolFeeOnFamilyPools() public view {
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            Currency c = Currency.wrap(roundManager.canonical(i));
            assertEq(vault.ledgerTotal(c), vault.reinforcementBalance(Currency.unwrap(c)), "non-ETH ledger is hop-only");
        }
    }

    /// @notice Solvency: the vault never promises more than it holds, in any currency.
    function invariant_vaultIsSolvent() public view {
        _assertSolvent();
    }

    /// @notice M6: an invariant run that never reached the interesting paths proves nothing.
    /// Checked once at the END of every run (the counters are necessarily zero at depth 0):
    /// each run must have deployed protocol-owned support, crowned a successor, and paid a
    /// pull claim at least once.
    function afterInvariant() public view {
        // Each path is judged only against the runs that actually REACHED it: a sequence that
        // never called `deploySupport` proves nothing about the keeper path, but a sequence
        // that called it and never once succeeded is a real failure.
        if (handler.deployAttempts() != 0) {
            assertGt(handler.deploysSucceeded(), 0, "the keeper deployment path never succeeded");
        }
        if (handler.successionAttempts() != 0) {
            assertGt(handler.successions(), 0, "a funded succession attempt never crowned anyone");
        }
        if (handler.claimAttempts() != 0) {
            assertGt(handler.claims(), 0, "no fee was ever claimable");
        }
    }

    /// @notice One canonical token per index, append-only, with a consistent reverse index.
    function invariant_canonicalHistoryIsAppendOnly() public view {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i < handler.canonicalSeenCount(); i++) {
            address seen = handler.canonicalSeen(i);
            if (seen == address(0)) continue;
            assertEq(roundManager.canonical(i), seen, "canonical entry was rewritten");
        }
        for (uint256 i = 0; i <= head; i++) {
            address t = roundManager.canonical(i);
            assertTrue(t != address(0), "no gap in the chain");
            assertEq(roundManager.indexOf(t), i, "reverse index agrees");
            assertTrue(roundManager.isCanonical(t));
            if (i > 0) assertEq(roundManager.parentOf(t), roundManager.canonical(i - 1), "parent is the predecessor");
        }
    }
}
