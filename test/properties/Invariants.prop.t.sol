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
        _setUpEdge();

        initialSteward = roundManager.steward();
        initialDeveloper = vault.developer();
        initialGenesisCreator = vault.creatorRecipient(address(token));

        handler = new PropHandler(factory, familyRouter, vault, bidDeployer, swapRouter);
        for (uint256 i = 0; i < ranges.length; i++) {
            handler.notePosition(poolId, ranges[i].tickLower, ranges[i].tickUpper);
        }

        bytes4[] memory selectors = new bytes4[](12);
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
        selectors[10] = PropHandler.propDonate.selector;
        selectors[11] = PropHandler.propProbePrivileged.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------------------
    // supply and liquidity
    // ---------------------------------------------------------------------------------

    /// @notice SUP-01: `totalSupply()` is fixed for every FAMILY token - no mint path exists and
    /// the only burn is the launch dust, taken before the token is ever handed out. Canonical
    /// index 0 is excluded: it is an EXTERNAL token this protocol adopted, and what its issuer
    /// does with its supply is not a guarantee this protocol can make.
    function invariant_SUP01_supplyNeverMoves() public view {
        address edge = roundManager.canonical(0);
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            address t = handler.tokens(i);
            if (t == edge) continue;
            assertEq(IERC20(t).totalSupply(), handler.supplySeen(t), "supply moved");
        }
    }

    /// @notice SUP-04. Two clauses, because the chain now has two kinds
    /// of token in it:
    ///
    ///   1. no protocol contract ever holds a movable balance of a FAMILY token - every wei of
    ///      every family supply is in a Locker position or in a trader's hands;
    ///   2. the EDGE currency is an EXTERNAL token this protocol legitimately custodies (the
    ///      RoundManager escrows bonds in it, the FeeVault holds the fees), so the statement
    ///      there is a solvency one: the vault's holding is never less than the ledgers it has
    ///      promised, PLUS whatever has been donated to it.
    ///
    /// The second clause is an INEQUALITY on purpose. An unsolicited transfer raises `holdings`
    /// and credits no ledger, and there is no sweep, so the surplus is unclaimable forever;
    /// {invariant_SUP04_aDonationNeverCreditsALedger} is the other half of that statement.
    function invariant_SUP04_noProtocolContractHoldsSupply() public view {
        address edge = roundManager.canonical(0);
        uint256 n = handler.tokenCount();
        for (uint256 i = 0; i < n; i++) {
            IERC20 t = IERC20(handler.tokens(i));
            if (address(t) == edge) continue; // clause 2, below
            assertEq(t.balanceOf(address(factory)), 0, "the factory holds nothing");
            assertEq(t.balanceOf(address(roundManager)), 0, "the round manager holds nothing");
            assertEq(t.balanceOf(address(familyRouter)), 0, "the router holds nothing");
            assertEq(t.balanceOf(address(bidDeployer)), 0, "the bid deployer holds nothing");
        }

        Currency edgeCurrency = vault.EDGE();
        assertGe(
            vault.holdings(edgeCurrency),
            vault.ledgerTotal(edgeCurrency) + handler.donated(),
            "a donation is held ON TOP of every ledger, never instead of one"
        );
        assertGe(
            IERC20(edge).balanceOf(address(roundManager)),
            roundManager.bondEscrow() + roundManager.pendingForfeits(),
            "the bond escrow and any held forfeit are backed by what the round manager holds"
        );
        assertEq(IERC20(edge).balanceOf(address(factory)), 0, "the factory keeps none of the edge currency");
        assertEq(IERC20(edge).balanceOf(address(familyRouter)), 0, "the router keeps none of it");
        assertEq(IERC20(edge).balanceOf(address(bidDeployer)), 0, "and neither does the keeper contract");
    }

    /// @notice NO PROTOCOL CONTRACT ENDS WITH ETH. Every value this stack moves is
    /// an ERC-20 - bonds, fees, sleeves, bounties - and none of these
    /// contracts has a payable entry point left. A balance here means value arrived by a path
    /// nobody designed, and it would be stuck.
    function invariant_noProtocolContractHoldsEth() public view {
        _assertNoEth();
    }

    /// @notice SUP-04, the other half: a gift of the edge currency credits NO ledger. Nothing in
    /// the vault reads its own balance, so an unsolicited transfer can never become a claim.
    function invariant_SUP04_aDonationNeverCreditsALedger() public view {
        assertEq(handler.donationsThatMovedALedger(), 0, "a donation moved a ledger");
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
        Currency edgeCurrency = vault.EDGE();
        // `ledgerTotal` already includes whatever is queued for a successor, so this is the
        // whole promise measured against the whole holding
        assertGe(vault.ledgerTotal(edgeCurrency), vault.pendingForwardTotal(), "the queue is part of the ledger");
    }

    /// @notice FEE-10: fees only ever move into the named destinations - the dev ledger, the
    /// creator ledgers, the ancestor tree, the per-generation reinforcement, the parent hop pot,
    /// the edge bid earmark and the forwarding queue. Their sum never exceeds the EDGE ledger
    /// total, and the difference is only the sleeve's permanently unclaimable floor residue.
    /// Currency-agnostic: the ledger is the vault's own `EDGE`.
    function invariant_FEE10_everyEdgeDestinationIsANamedLedger() public view {
        Currency edgeCurrency = vault.EDGE();
        uint256 named = vault.devBalance() + vault.reinforcementBalance(address(doll)) + vault.edgeBidEarmark()
            + vault.pendingForwardTotal();
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            named += vault.creatorBalance(roundManager.canonical(i));
            named += vault.reinforcementEdge(i);
            named += vault.claimableAncestor(i);
        }
        assertLe(named, vault.ledgerTotal(edgeCurrency), "no edge destination outside the named list");
    }

    /// @notice FEE-08 / the hop fee's own pot: the FAMILY ledgers - canonical index 1 and deeper
    /// - are hop fees and snipe tax alone. A protocol fee exists only on the edge, which is
    /// canonical index 0 and therefore not in this loop.
    function invariant_FEE08_familyLedgersAreHopFeesOnly() public view {
        for (uint256 i = 1; i <= roundManager.headIndex(); i++) {
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

    /// @notice Round `n+1` cannot open until round `n` is finalized.
    function invariant_RND08_onlyOneRoundIsEverOpen() public view {
        uint256 open = roundManager.roundCount();
        for (uint256 i = 1; i < open; i++) {
            assertTrue(roundManager.roundInfo(i).finalized, "an earlier round is still open");
        }
    }

    /// @notice A round never moves backwards through the phase machine.
    function invariant_RND03_phasesNeverGoBackwards() public view {
        uint256 roundId = roundManager.roundCount();
        if (roundId == 0) return;
        assertGe(uint8(roundManager.phase(roundId)), handler.maxPhase(roundId), "a round went backwards");
    }

    /// @notice The threshold never leaves `[H_MIN_FRAC_WAD, H_FRAC_WAD]`, whatever
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

    /// @notice BID-05 / BID-14: the edge currency leaves the vault on the keeper path only
    /// against a credit created in the same call, so no keeper call ever leaves a residual credit
    /// behind, and there is no native balance anywhere in the stack to leave behind either.
    function invariant_BID05_theKeeperLeashIsNeverSlack() public view {
        assertEq(vault.deployerCredit(), 0, "a keeper call left a credit outstanding");
        assertEq(doll.balanceOf(address(bidDeployer)), 0, "the bid deployer holds nothing between calls");
        _assertNoEth();
    }

    /// @notice ROL-01: nothing outside the named role calls can move a role. The handler's
    /// `propProbePrivileged` action attempts every role, sunset and creator-right move from an
    /// address that holds none of them; none may take effect, and every holder is still the one
    /// set at deployment. The handler itself holds no role, so no other action can move one
    /// legitimately either.
    function invariant_ROL01_thePrivilegedSurfaceIsUnreachable() public view {
        assertEq(handler.privilegedSucceeded(), 0, "a non-holder moved a role, a sunset or a creator right");
        assertEq(roundManager.steward(), initialSteward, "the steward moved");
        assertEq(roundManager.pendingSteward(), address(0), "a steward transfer was announced");
        assertEq(vault.developer(), initialDeveloper, "the developer moved");
        assertEq(vault.pendingDeveloper(), address(0), "a developer transfer was announced");
        assertEq(vault.creatorRecipient(address(token)), initialGenesisCreator, "a creator right moved");
        assertEq(roundManager.sunsetAt(), 0, "a sunset was announced by something other than the steward");
        assertEq(roundManager.successor(), address(0), "a successor was named without the steward");
    }

    /// @notice ROL-01, the probe itself: one call of the handler's action really reaches the role
    /// surface from a non-holder and is refused everywhere.
    function test_ROL01_theProbeIsRefusedEverywhere() public {
        handler.propProbePrivileged(7);
        assertEq(handler.privilegedAttempts(), 1, "the probe did not run");
        assertEq(handler.privilegedSucceeded(), 0, "a non-holder moved a role");
        assertEq(roundManager.steward(), initialSteward, "the steward moved");
        assertEq(vault.developer(), initialDeveloper, "the developer moved");
        assertEq(roundManager.sunsetAt(), 0, "a sunset was announced");
    }

    /// @notice REN-01: no call originating inside a `PoolManager` unlock reaches a
    /// state-changing function of `RoundManager` or `FeeVault` except the hook's own accrual
    /// path; in particular no swap can re-entrantly call `finalize`, `submitScore`, `rank`, a
    /// claim or a keeper entrypoint.
    // This was recorded as a DIVERGENCE - being inside a `PoolManager` unlock was not
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
        assertEq(handler.reentryCallbacksRun(), handler.reentryAttempts(), "an unlock probe was rolled back");
        assertEq(
            handler.reentryBlockedByGuard(),
            handler.reentryAttempts() * handler.GUARDED_PROBES(),
            "a guarded probe failed for a reason other than the unlock guard"
        );
    }

    /// @notice REN-01, measured: which state-changing calls are actually reachable from inside a
    /// `PoolManager` unlock, in a state with a crowned generation and a funded vault.
    function test_REN01_whichCallsAreReachableFromInsideAnUnlock() public {
        handler.propRegister(43200);
        handler.propSucceed(type(uint256).max);
        assertGt(roundManager.headIndex(), 0, "precondition: no generation was crowned");
        handler.propReenterFromUnlock(2992);
        emit log_named_uint("total reachable", handler.reentrySucceeded());
        // the probe really ran inside an unlock that completed (a rolled-back unlock would
        // also roll back every success counter below)
        assertEq(handler.reentryCallbacksRun(), 1, "the unlock callback did not run to completion");
        // and every guarded target was refused BY the unlock guard, not by some other check
        assertEq(handler.reentryBlockedByGuard(), handler.GUARDED_PROBES(), "a probe failed for a reason other than the unlock guard");
        assertEq(handler.reentryFinalizeSucceeded(), 0, "finalize is reachable from inside an unlock");
        assertEq(handler.reentryClaimSucceeded(), 0, "a vault claim is reachable from inside an unlock");
        assertEq(handler.reentryFlushSucceeded(), 0, "flushForward is reachable from inside an unlock");
        assertEq(handler.reentryKeeperSucceeded(), 0, "a keeper entrypoint is reachable from inside an unlock");
        assertEq(handler.reentryRefundSucceeded(), 0, "claimRefund is reachable from inside an unlock");
        assertEq(handler.reentryRequestEndSucceeded(), 0, "requestEnd is reachable from inside an unlock");
        assertEq(handler.reentryFulfilEndSucceeded(), 0, "fulfilEnd is reachable from inside an unlock");
        assertEq(handler.reentryDeterministicSucceeded(), 0, "finalizeDeterministic is reachable from inside an unlock");
        assertEq(handler.reentrySubmitSucceeded(), 0, "submitScore is reachable from inside an unlock");
        assertEq(handler.reentrySucceeded(), 0, "a call from inside an unlock took effect");
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
