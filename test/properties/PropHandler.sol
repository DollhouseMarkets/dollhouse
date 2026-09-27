// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyHandler} from "../utils/FamilyHandler.sol";
import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyRouter} from "../../contracts/FamilyRouter.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev The property suite's driver. Every action is a thin wrapper around the shared
/// {FamilyHandler} action of the same name, so the two suites drive the protocol identically;
/// the wrappers exist to record the ghosts the property invariants are checked against (how
/// often the head moved against how often a round was finalized, the phase each round has
/// reached, and whether the privileged surface was ever touched).
contract PropHandler is FamilyHandler {
    /// @notice How many times `headIndex` has been observed to move, and how many actions could
    /// possibly have moved it (PAR-01: only a `finalize` may).
    uint256 public headMoves;
    uint256 public finalizingActions;

    /// @notice The highest phase ordinal each round has been observed in (RND-03: a round never
    /// goes backwards).
    mapping(uint256 => uint8) public maxPhase;

    /// @notice Reentrancy attempts made from inside a `PoolManager` unlock, and how many of them
    /// changed anything (REN-01: none may).
    uint256 public reentryAttempts;
    /// @notice How many of those calls SUCCEEDED. REN-01 says this must stay at zero.
    uint256 public reentrySucceeded;
    /// @notice The same count split by target, so a failure names the reachable function. The
    /// probe covers every state-changing entrypoint of the round machine, the vault's claims and
    /// the keeper: `finalize`, `claimDev`, `claimCreator`, `claimCreatorAccrued`, the round
    /// manager's bond `claimRefund`, `flushForward`, the keeper deployments, `requestEnd`,
    /// `fulfilEnd`, `finalizeDeterministic` and `submitScore`. Every one of them must
    /// stay at zero.
    uint256 public reentryGuardedSucceeded;
    uint256 public reentryFinalizeSucceeded;
    uint256 public reentryClaimSucceeded;
    uint256 public reentryRefundSucceeded;
    uint256 public reentryFlushSucceeded;
    uint256 public reentryKeeperSucceeded;
    uint256 public reentryRequestEndSucceeded;
    uint256 public reentryFulfilEndSucceeded;
    uint256 public reentryDeterministicSucceeded;
    uint256 public reentrySubmitSucceeded;
    /// @notice How many times the unlock callback actually ran to completion. A success above
    /// that also left an unsettled delta would make `unlock` revert and roll every counter back
    /// with it, so REN-01 is only meaningful while this equals `reentryAttempts`.
    uint256 public reentryCallbacksRun;
    /// @notice How many probes were refused by the protocol's own unlock guard (`InsideUnlock()`)
    /// rather than by some unrelated precondition. Cause, not effect: REN-01 is asserted on the
    /// guard firing, not merely on the call failing.
    uint256 public reentryBlockedByGuard;
    /// @notice The probes in {unlockCallback} whose target carries `notInsideUnlock`: `finalize`,
    /// the three vault claims, `claimRefund`, `deployEdgeBid`, `deployHopPot`, `requestEnd`,
    /// `fulfilEnd`, `finalizeDeterministic` and `submitScore`. `flushForward` is the twelfth
    /// probe and is refused by v4-core's `AlreadyUnlocked` (or by an empty queue) instead.
    uint256 public constant GUARDED_PROBES = 11;

    /// @notice ROL-01: attempts to move a role, a sunset or a creator right from a caller that
    /// holds none of them, and how many of those attempts took effect. The second must stay at
    /// zero.
    uint256 public privilegedAttempts;
    uint256 public privilegedSucceeded;

    /// @notice SUP-04: the edge currency donated into the vault over the run, and how
    /// many of those donations moved a ledger. The second must stay at zero: a gift credits
    /// nobody, which is exactly why solvency is an inequality and why there is no sweep.
    uint256 public donated;
    uint256 public donationsThatMovedALedger;

    uint256 internal _headIndexSeen;

    constructor(
        FamilyFactory _factory,
        FamilyRouter _router,
        FeeVault _vault,
        BidDeployer _bidDeployer,
        PoolSwapTest _swapRouter
    ) FamilyHandler(_factory, _router, _vault, _bidDeployer, _swapRouter) {
        _headIndexSeen = _factory.roundManager().headIndex();
    }

    // ---------------------------------------------------------------------------------
    // ghosts
    // ---------------------------------------------------------------------------------

    function _observe() internal {
        uint256 head = roundManager.headIndex();
        if (head != _headIndexSeen) {
            headMoves++;
            _headIndexSeen = head;
        }
        uint256 roundId = roundManager.roundCount();
        if (roundId != 0) {
            uint8 p = uint8(roundManager.phase(roundId));
            if (p > maxPhase[roundId]) maxPhase[roundId] = p;
        }
    }

    // ---------------------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------------------

    function propBuy(uint256 targetSeed, uint256 ethIn) external {
        try this.buy(targetSeed, ethIn) {} catch {}
        _observe();
    }

    function propSell(uint256 targetSeed, uint256 amountSeed) external {
        try this.sell(targetSeed, amountSeed) {} catch {}
        _observe();
    }

    function propRegister(uint256 seed) external {
        try this.registerCandidate(seed) {} catch {}
        _observe();
    }

    function propTradeCandidate(uint256 seed, uint256 amountSeed) external {
        try this.tradeCandidate(seed, amountSeed) {} catch {}
        _observe();
    }

    function propAdvanceTime(uint256 seconds_) external {
        try this.advanceTime(seconds_) {} catch {}
        _observe();
    }

    function propSettle() external {
        finalizingActions++;
        try this.submitAndFinalize() {} catch {}
        _observe();
    }

    function propSucceed(uint256 amountSeed) external {
        finalizingActions++;
        try this.forceSuccession(amountSeed) {} catch {}
        _observe();
    }

    function propDeploySupport(uint256 seed) external {
        try this.deploySupport(seed) {} catch {}
        _observe();
    }

    function propClaim(uint256 seed) external {
        try this.claimFees(seed) {} catch {}
        _observe();
    }

    /// @dev SUP-04: an unsolicited transfer of the EDGE currency into the vault. It must raise
    /// `holdings` without raising any ledger, and no path of any kind may pay it back out.
    function propDonate(uint256 amountSeed) external {
        uint256 held = edge.balanceOf(address(this));
        if (held == 0) return;
        uint256 max = held < 1_000 ether ? held : 1_000 ether;
        uint256 amount = bound(amountSeed, 1, max);
        Currency e = vault.EDGE();
        uint256 ledgerBefore = vault.ledgerTotal(e);
        edge.transfer(address(vault), amount);
        donated += amount;
        if (vault.ledgerTotal(e) != ledgerBefore) donationsThatMovedALedger++;
        _observe();
    }

    /// @dev REN-01: attempt every state-changing RoundManager / FeeVault / keeper entrypoint
    /// from INSIDE a `PoolManager` unlock - the round machine including `fulfilEnd`, the three
    /// vault claims, the bond refund, the forwarding flush and the keeper deployments. Each must
    /// revert (or do nothing); none may take effect, so the ghosts the invariants read are
    /// unchanged by this action.
    function propReenterFromUnlock(uint256 seed) external {
        reentryAttempts++;
        // the action attempts `finalize` among the rest, so it counts as a finalizing action for
        // PAR-01's ghost even though REN-01 says none of it may take effect
        finalizingActions++;
        try poolManager.unlock(abi.encode(seed)) {} catch {}
        _observe();
    }

    /// @dev ROL-01: from a seeded address that holds no role, attempt every call that moves a
    /// role, a sunset, a successor or a creator right. Each must revert; if any access check were
    /// missing, the role would move and `invariant_ROL01_thePrivilegedSurfaceIsUnreachable`
    /// would fail on the next check.
    function propProbePrivileged(uint256 seed) external {
        address caller = address(uint160(uint256(keccak256(abi.encode("ROL-01", seed)))));
        address tok = roundManager.canonical(bound(seed, 0, roundManager.headIndex()));
        if (caller == roundManager.steward() || caller == vault.developer() || caller == vault.creatorRecipient(tok)) {
            return;
        }
        privilegedAttempts++;
        vm.prank(caller);
        try roundManager.announceSunset(address(roundManager)) {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try roundManager.cancelSunset() {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try roundManager.announceStewardTransfer(caller) {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try roundManager.cancelStewardTransfer() {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try roundManager.executeStewardTransfer() {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try vault.announceDeveloperTransfer(caller) {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try vault.cancelDeveloperTransfer() {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try vault.executeDeveloperTransfer() {
            privilegedSucceeded++;
        } catch {}
        vm.prank(caller);
        try vault.transferCreatorRecipient(tok, caller) {
            privilegedSucceeded++;
        } catch {}
        _observe();
    }

    /// @dev Counts a probe refused by the protocol's own unlock guard. `RoundManager`,
    /// `FeeVault` and `BidDeployer` declare the same `InsideUnlock()` error, so one selector
    /// covers all three.
    function _noteGuard(bytes memory reason) internal {
        if (reason.length >= 4 && bytes4(reason) == RoundManager.InsideUnlock.selector) reentryBlockedByGuard++;
    }

    /// @dev The unlock callback the action above lands in. Every call is wrapped: a revert is
    /// the expected outcome and must not end the run.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not the PoolManager");
        reentryCallbacksRun++;
        uint256 guarded;
        try roundManager.finalize() {
            guarded++;
            reentryFinalizeSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try vault.claimDev(address(this)) returns (uint256) {
            guarded++;
            reentryClaimSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try vault.claimCreator(roundManager.canonical(0), address(this)) returns (uint256) {
            guarded++;
            reentryClaimSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try vault.claimCreatorAccrued(address(this)) returns (uint256) {
            guarded++;
            reentryClaimSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        // The round manager's own pull payment, guarded like the vault's claims
        try roundManager.claimRefund(address(this)) {
            guarded++;
            reentryRefundSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try vault.flushForward(0, 1) returns (uint256) {
            guarded++;
            reentryFlushSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try bidDeployer.deployEdgeBid() returns (uint256) {
            guarded++;
            reentryKeeperSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try bidDeployer.deployHopPot(1) returns (uint256, uint256) {
            guarded++;
            reentryKeeperSucceeded++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        reentryGuardedSucceeded += guarded;

        uint256 open;
        try roundManager.requestEnd() returns (bytes32) {
            reentryRequestEndSucceeded++;
            open++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        // The relay half of the random end is guarded too
        try roundManager.fulfilEnd("") returns (uint64) {
            reentryFulfilEndSucceeded++;
            open++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try roundManager.finalizeDeterministic() {
            reentryDeterministicSucceeded++;
            open++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        try roundManager.submitScore(0) returns (int256) {
            reentrySubmitSucceeded++;
            open++;
        } catch (bytes memory reason) {
            _noteGuard(reason);
        }
        reentrySucceeded += guarded + open;
        return "";
    }
}
