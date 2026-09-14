// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {PropHandler} from "./PropHandler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @notice Stateful (tier I) property tests: docs/spec/PROPERTIES.md sections 3.1-3.10, driven
/// by {PropHandler}. Every invariant here names the property it stands for.
contract InvariantsPropTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    PropHandler internal handler;

    address internal initialSteward;
    address internal initialDeveloper;
    address internal initialGenesisCreator;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(2 ether);

        initialSteward = roundManager.steward();
        initialDeveloper = vault.developer();
        initialGenesisCreator = vault.creatorRecipient(address(token));

        handler = new PropHandler(factory, familyRouter, vault, bidDeployer, swapRouter);
        for (uint256 i = 0; i < ranges.length; i++) {
            handler.notePosition(poolId, ranges[i].tickLower, ranges[i].tickUpper);
        }

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = PropHandler.propBuy.selector;
        selectors[1] = PropHandler.propSell.selector;
        selectors[2] = PropHandler.propRegister.selector;
        selectors[3] = PropHandler.propTradeCandidate.selector;
        selectors[4] = PropHandler.propAdvanceTime.selector;
        selectors[5] = PropHandler.propSettle.selector;
        selectors[6] = PropHandler.propSucceed.selector;
        selectors[7] = PropHandler.propDeploySupport.selector;
        selectors[8] = PropHandler.propClaim.selector;
        selectors[9] = PropHandler.propReenterFromUnlock.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------------------
    // supply and liquidity
    // ---------------------------------------------------------------------------------

    /// @notice SUP-01: `totalSupply()` is fixed for every family token - no mint path exists and
    /// the only burn is the launch dust, taken before the token is ever handed out.
    function invariant_SUP01_supplyNeverMoves() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            address t = handler.tokens(i);
            assertEq(IERC20(t).totalSupply(), handler.supplySeen(t), "supply moved");
        }
    }

    /// @notice SUP-04: no protocol contract ever holds a movable balance of a family token; the
    /// supply is in Locker positions, in the vesting contract and in traders' hands.
    function invariant_SUP04_noProtocolContractHoldsSupply() public view {
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            IERC20 t = IERC20(handler.tokens(i));
            assertEq(t.balanceOf(address(factory)), 0, "the factory holds nothing");
            assertEq(t.balanceOf(address(roundManager)), 0, "the round manager holds nothing");
            assertEq(t.balanceOf(address(familyRouter)), 0, "the router holds nothing");
            assertEq(t.balanceOf(address(bidDeployer)), 0, "the bid deployer holds nothing");
        }
    }

    /// @notice SUP-05: per-pool locked liquidity is monotone non-decreasing over any sequence of
    /// actions - no call by any caller reduces a Locker-owned position.
    function invariant_SUP05_lockedLiquidityIsARatchet() public view {
        uint256 n = handler.positionCount();
        for (uint256 i = 0; i < n; i++) {
            (PoolId id, int24 tickLower, int24 tickUpper) = handler.positions(i);
            (uint128 liq,,) = im.getPositionInfo(id, address(locker), tickLower, tickUpper, bytes32(0));
            assertGe(liq, handler.maxLiquidity(keccak256(abi.encode(id, tickLower, tickUpper))), "liquidity shrank");
        }
    }

    // ---------------------------------------------------------------------------------
    // fees
    // ---------------------------------------------------------------------------------

    /// @notice FEE-11: for every currency, `ledgerTotal[c] <= holdings(c)` - what the vault has
    /// promised is always backed by unredeemed claims plus its real balance.
    function invariant_FEE11_theVaultIsSolvent() public view {
        _assertSolvent();
        Currency eth = Currency.wrap(address(0));
        // `ledgerTotal` already includes whatever is queued for a successor, so this is the
        // whole promise measured against the whole holding
        assertGe(vault.ledgerTotal(eth), vault.pendingForwardTotal(), "the queue is part of the ledger");
    }

    /// @notice FEE-10: fees only ever move into the named destinations - the dev ledger, the
    /// creator ledgers, the ancestor tree, the per-generation reinforcement, the parent hop pot,
    /// the genesis bid earmark and the forwarding queue. Their sum never exceeds the ETH ledger
    /// total, and the difference is only the sleeve's permanently unclaimable floor residue.
    function invariant_FEE10_everyEthDestinationIsANamedLedger() public view {
        Currency eth = Currency.wrap(address(0));
        uint256 named = vault.devBalance() + vault.reinforcementBalance(address(0)) + vault.genesisBidEarmark()
            + vault.pendingForwardTotal();
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            named += vault.creatorBalance(roundManager.canonical(i));
            named += vault.reinforcementEth(i);
            named += vault.claimableAncestor(i);
        }
        assertLe(named, vault.ledgerTotal(eth), "no ETH destination outside the named list");
    }

    /// @notice FEE-08 / the hop fee's own pot: the non-ETH ledgers are hop fees and snipe tax
    /// alone - a protocol fee exists only on the ETH edge.
    function invariant_FEE08_familyLedgersAreHopFeesOnly() public view {
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            Currency c = Currency.wrap(roundManager.canonical(i));
            assertEq(vault.ledgerTotal(c), vault.reinforcementBalance(Currency.unwrap(c)), "hop-only ledger");
        }
    }

    // ---------------------------------------------------------------------------------
    // rounds and history
    // ---------------------------------------------------------------------------------

    /// @notice RND-09 / PAR-02: `canonical[i]` is write-once, the chain has no gaps, and the
    /// reverse index (`indexOf`, `parentOf`, `isCanonical`) agrees with it at all times.
    function invariant_RND09_canonicalHistoryIsAppendOnly() public view {
        uint256 head = roundManager.headIndex();
        for (uint256 i = 0; i < handler.canonicalSeenCount(); i++) {
            address seen = handler.canonicalSeen(i);
            if (seen == address(0)) continue;
            assertEq(roundManager.canonical(i), seen, "a canonical entry was rewritten");
        }
        for (uint256 i = 0; i <= head; i++) {
            address t = roundManager.canonical(i);
            assertTrue(t != address(0), "no gap in the chain");
            assertEq(roundManager.indexOf(t), i, "the reverse index agrees");
            assertTrue(roundManager.isCanonical(t), "and says so");
            if (i > 0) assertEq(roundManager.parentOf(t), roundManager.canonical(i - 1), "parent is the predecessor");
        }
    }

    /// @notice RND-08: round `n+1` cannot open until round `n` is finalized.
    function invariant_RND08_onlyOneRoundIsEverOpen() public view {
        uint256 open = roundManager.roundCount();
        for (uint256 i = 1; i < open; i++) {
            assertTrue(roundManager.roundInfo(i).finalized, "an earlier round is still open");
        }
    }

    /// @notice RND-03: a round never moves backwards through the phase machine.
    function invariant_RND03_phasesNeverGoBackwards() public view {
        uint256 roundId = roundManager.roundCount();
        if (roundId == 0) return;
        assertGe(uint8(roundManager.phase(roundId)), handler.maxPhase(roundId), "a round went backwards");
    }

    /// @notice RND-13: the threshold never leaves `[H_MIN_FRAC_WAD, H_FRAC_WAD]`, whatever
    /// sequence of failed and crowned rounds runs.
    function invariant_RND13_theThresholdStaysInItsBand() public view {
        assertLe(roundManager.hWad(), roundManager.H_FRAC_WAD(), "H never rises above its reset value");
        assertGe(roundManager.hWad(), roundManager.H_MIN_FRAC_WAD(), "and never decays below the floor");
    }

    /// @notice PAR-01: the head moves only in a `finalize`; no other call by any actor changes
    /// `head` or `headIndex`.
    function invariant_PAR01_theHeadMovesOnlyAtFinalize() public view {
        assertLe(handler.headMoves(), handler.finalizingActions(), "the head moved outside a finalize");
    }

    // ---------------------------------------------------------------------------------
    // keeper leash and the privileged surface
    // ---------------------------------------------------------------------------------

    /// @notice BID-05 / BID-14: ETH leaves the vault on the keeper path only against a credit
    /// created in the same call, so no keeper call ever leaves a residual credit behind.
    function invariant_BID05_theKeeperLeashIsNeverSlack() public view {
        assertEq(vault.deployerCredit(), 0, "a keeper call left a credit outstanding");
        assertEq(address(bidDeployer).balance, 0, "and the bid deployer holds no ETH between calls");
    }

    /// @notice ROL-01: nothing outside the named role calls can move a role. The handler never
    /// announces or executes a transfer, so every role holder is still the one set at deployment.
    function invariant_ROL01_thePrivilegedSurfaceIsUnreachable() public view {
        assertEq(roundManager.steward(), initialSteward, "the steward moved");
        assertEq(vault.developer(), initialDeveloper, "the developer moved");
        assertEq(vault.creatorRecipient(address(token)), initialGenesisCreator, "a creator right moved");
        assertEq(roundManager.sunsetAt(), 0, "a sunset was announced by something other than the steward");
        assertEq(roundManager.successor(), address(0), "a successor was named without the steward");
    }

    /// @notice REN-01: no call originating inside a `PoolManager` unlock reaches a
    /// state-changing function of `RoundManager` or `FeeVault` except the hook's own accrual
    /// path; in particular no swap can re-entrantly call `finalize`, `submitScore`, `rank`, a
    /// claim or a keeper entrypoint.
    // REVIEW-2: this was recorded as a DIVERGENCE - being inside a `PoolManager` unlock was not
    // a state the protocol checked, and `rank`, `finalize` and the round-machine calls all ran
    // normally from inside an external caller's own unlock. EVERY state-changing entrypoint of
    // the round machine (`requestEnd`, `fulfilEnd`, `finalizeDeterministic`, `submitScore`,
    // `rank`, `finalize`, `claimRefund`), the vault's three claims and the keeper's deployments
    // now carry `notInsideUnlock`, which reads v4-core's own transient lock flag with one
    // `exttload`; `flushForward` and the keeper paths additionally reach a nested
    // `poolManager.unlock` and would revert `AlreadyUnlocked` anyway. The property is asserted
    // as written. The hook's own accrual path is deliberately NOT guarded: it is the one thing
    // that is MEANT to run inside the swap's unlock, on every swap.
    function invariant_REN01_nothingReentersFromInsideAnUnlock() public view {
        assertEq(handler.reentrySucceeded(), 0, "a call from inside an unlock took effect");
    }

    /// @notice REN-01, measured: which state-changing calls are actually reachable from inside a
    /// `PoolManager` unlock, in a state with a crowned generation and a funded vault.
    function test_REN01_whichCallsAreReachableFromInsideAnUnlock() public {
        handler.propRegister(43200);
        handler.propSucceed(type(uint256).max);
        handler.propReenterFromUnlock(2992);
        emit log_named_uint("finalize", handler.reentryFinalizeSucceeded());
        emit log_named_uint("claims", handler.reentryClaimSucceeded());
        emit log_named_uint("flushForward", handler.reentryFlushSucceeded());
        emit log_named_uint("keeper entrypoints", handler.reentryKeeperSucceeded());
        emit log_named_uint("bond refund", handler.reentryRefundSucceeded());
        emit log_named_uint("requestEnd", handler.reentryRequestEndSucceeded());
        emit log_named_uint("fulfilEnd", handler.reentryFulfilEndSucceeded());
        emit log_named_uint("finalizeDeterministic", handler.reentryDeterministicSucceeded());
        emit log_named_uint("submitScore", handler.reentrySubmitSucceeded());
        emit log_named_uint("total reachable", handler.reentrySucceeded());
    }

    /// @notice The run must actually have reached the interesting paths.
    function afterInvariant() public view {
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
}
