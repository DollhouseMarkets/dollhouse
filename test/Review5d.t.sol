// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {HostileDoll} from "./utils/HostileDoll.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice REGISTRATION IS REACHABLE FROM INSIDE THIS CONTRACT'S OWN TRANSFERS.
///
/// The bond escrow proves delivery by reading a balance: `addCandidate` refuses a registration
/// unless the RoundManager holds at least `bondEscrow + pendingForfeits`. That is sound between
/// calls and wrong DURING one. Two paths book value out before they move it:
///
///   {RoundManager.flushForfeits} zeroes `pendingForfeits` and then transfers, and
///   {RoundManager.finalize} releases `bondEscrow` and then pushes the forfeit and the refund.
///
/// In both windows the balance still holds tokens that are no longer owed to anyone the check
/// knows about, so a bond delivered SHORT would have passed. The edge currency is an ERC-20 this
/// protocol did not write, and one with a sender hook can call the factory back from inside the
/// very transfer the protocol is making, which is exactly the window. Both factory entrypoints
/// now carry the reentrancy guard; the factory calls them in sequence and nothing between them
/// re-enters the RoundManager, so the honest path is unchanged.
contract Review5dRegistrationReentrancyTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;
    /// @dev The skim the attacker's own bond suffers, in basis points: the bond arrives SHORT.
    uint256 internal constant SKIM_BPS = 100;

    HostileDoll internal hostile;

    function setUp() public {
        _setUpFamily();
        HostileDoll impl = new HostileDoll(18);
        vm.etch(DOLL_ADDRESS, address(impl).code);
        hostile = HostileDoll(DOLL_ADDRESS);
    }

    /// @dev The token itself becomes the registrant: it is funded, it approves the factory, and
    /// its own outgoing transfers - and only those - are skimmed, so the bond it delivers arrives
    /// short while the protocol's own transfers move in full.
    function _armTheToken() internal returns (uint256 bond) {
        bond = roundManager.currentBond();
        _fundDoll(address(hostile), 10 * bond);
        vm.prank(address(hostile));
        IERC20(address(doll)).approve(address(factory), type(uint256).max);
        hostile.setFeeFrom(address(hostile));
        hostile.setFeeBps(SKIM_BPS);
        hostile.setRegisterReentry(address(factory), address(roundManager));
    }

    function _disarm() internal {
        hostile.setRegisterReentry(address(0), address(0));
        hostile.setFeeBps(0);
        hostile.setFeeFrom(address(0));
    }

    /// @dev The custom error a recorded re-entrant call was refused with.
    function _rejectedBy(bytes memory data) internal pure returns (bytes4 sel) {
        assembly {
            sel := mload(add(data, 0x20))
        }
    }

    /// @dev What every one of these tests has to be true of afterwards: the contract still holds
    /// at least what it owes creators and what it owes the vault.
    function _assertEscrowCovered() internal view {
        assertGe(
            IERC20(address(doll)).balanceOf(address(roundManager)),
            roundManager.bondEscrow() + roundManager.pendingForfeits(),
            "the balance still covers both ledgers"
        );
    }

    function _assertTheGuardRefusedIt() internal view {
        assertTrue(hostile.registerAttempted(), "the token really did call the factory back");
        assertTrue(hostile.registerRejected(), "and the registration was refused");
        assertEq(
            _rejectedBy(hostile.registerRevertData()),
            RoundManager.Reentrancy.selector,
            "refused by the reentrancy guard, by name"
        );
    }

    /// @dev Three candidates, none of them traded and none of them scored: the round crowns
    /// nobody, every bond is forfeited and there is no refund, so `finalize` makes exactly ONE
    /// transfer - the forfeit push - and the re-entry can only have come from that one.
    function _stageFailingRound() internal returns (uint256 bond) {
        bond = roundManager.currentBond();
        delete cands;
        for (uint256 i = 0; i < 3; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i + block.timestamp)), "CAND");
        }
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);
    }

    /// @dev Three candidates, one of them a clear winner and scored: `finalize` pushes the
    /// forfeited bonds AND refunds the winner's.
    function _stageWinningRound() internal returns (uint256 bond) {
        bond = roundManager.currentBond();
        delete cands;
        for (uint256 i = 0; i < 3; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i + block.timestamp)), "CAND");
        }
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(cands[0], true, WINNING_BUY);
        for (uint256 i = 1; i < 3; i++) {
            _tradeCandidate(cands[i], true, WINNING_BUY / 100);
        }
        _settleEnd();
        for (uint256 i = 0; i < 3; i++) {
            roundManager.submitScore(cands[i].id);
        }
        vm.warp(submitEnd + 1);
    }

    /// @notice THE REENTRANCY GUARD, ON THE FLUSH. `flushForfeits` zeroes what it holds for the vault and
    /// then sends it. A token that registers a candidate from inside that transfer sees a balance
    /// that still contains the whole flushed amount and a `pendingForfeits` of zero, so a bond
    /// short by 1 percent would have cleared the escrow check. The guard refuses the call.
    function test_registrationCannotBeReenteredFromInsideTheFlush() public {
        uint256 bond = _stageFailingRound();
        hostile.setPaused(true);
        roundManager.finalize();
        hostile.setPaused(false);
        assertEq(roundManager.pendingForfeits(), 3 * bond, "three bonds are held for the vault");

        uint256 attackerBond = _armTheToken();
        // the masking condition: what is in flight is far larger than the shortfall the attacker
        // would have to hide, so without the guard the stale balance would have covered it
        assertGt(3 * bond, (attackerBond * SKIM_BPS) / 10_000, "the amount in flight covers the shortfall");

        roundManager.flushForfeits();
        _disarm();

        _assertTheGuardRefusedIt();
        assertEq(roundManager.candidateCount(), 3, "no fourth candidate was recorded");
        assertEq(vault.edgeBidEarmark(), 3 * bond, "the forfeits arrived exactly once");
        assertEq(roundManager.pendingForfeits(), 0, "and nothing is held any more");
        _assertEscrowCovered();
        _assertSolvent();
    }

    /// @notice THE SAME WINDOW INSIDE `finalize`, ON THE FORFEIT PUSH. `bondEscrow` is released
    /// in full before the push, so during it the balance holds the whole forfeited amount against
    /// a ledger that no longer counts it. This round crowns nobody, so the push is the only
    /// transfer the call makes.
    function test_registrationCannotBeReenteredFromInsideTheForfeitPush() public {
        uint256 bond = _stageFailingRound();
        uint256 attackerBond = _armTheToken();
        assertGt(attackerBond, 0);

        roundManager.finalize();
        _disarm();

        _assertTheGuardRefusedIt();
        assertEq(roundManager.candidateCount(), 3, "no fourth candidate was recorded");
        assertEq(roundManager.headIndex(), 0, "and the round crowned nobody, as it was staged to");
        assertEq(vault.edgeBidEarmark(), 3 * bond, "the forfeit was delivered in full");
        _assertEscrowCovered();
        _assertSolvent();
    }

    /// @notice AND ON THE REFUND PUSH. The winner's bond is pushed back after the forfeit, out of
    /// an escrow that has already been decremented by both. The vault is blocklisted here so the
    /// forfeit push reverts before it can transfer anything, which leaves the refund as the only
    /// transfer `finalize` completes and pins the re-entry to it.
    function test_registrationCannotBeReenteredFromInsideTheRefundPush() public {
        uint256 bond = _stageWinningRound();
        address winner = cands[0].creator;
        uint256 winnerBefore = IERC20(address(doll)).balanceOf(winner);

        hostile.setBlocked(address(vault), true);
        _armTheToken();

        roundManager.finalize();
        _disarm();
        hostile.setBlocked(address(vault), false);

        _assertTheGuardRefusedIt();
        assertEq(roundManager.candidateCount(), 3, "no fourth candidate was recorded");
        assertEq(roundManager.headIndex(), 1, "the round CROWNED");
        assertEq(roundManager.head(), cands[0].token, "and the candidate that won holds link one");
        assertEq(IERC20(address(doll)).balanceOf(winner) - winnerBefore, bond, "the refund was pushed in full");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "the blocked forfeit is held, not lost");
        _assertEscrowCovered();

        // and the held amount still delivers once the token stops blocking the vault
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "delivered in full on the retry");
        _assertSolvent();
    }

    /// @notice THE CONTROL. Outside those windows the escrow check is what stands between a short
    /// bond and a recorded candidate, and it still does: the same registrant, the same 1 percent
    /// skim, no re-entry, refused with `BondNotDelivered`. The guard added here closes a window
    /// in which that check reads a stale balance; it does not replace the check.
    function test_theEscrowCheckStillRefusesAShortBondOutsideTheWindow() public {
        uint256 bond = _stageFailingRound();
        hostile.setPaused(true);
        roundManager.finalize();
        hostile.setPaused(false);
        assertEq(roundManager.pendingForfeits(), 3 * bond);

        _armTheToken();
        hostile.setRegisterReentry(address(0), address(0)); // no re-entry: an ordinary call

        vm.prank(address(hostile));
        vm.expectRevert(RoundManager.BondNotDelivered.selector);
        factory.registerCandidate("SHORT", "SHORT", "", type(uint256).max);

        // and it goes through the moment the token stops skimming
        hostile.setFeeBps(0);
        vm.prank(address(hostile));
        factory.registerCandidate("FULL", "FULL", "", type(uint256).max);
        _disarm();
        assertEq(roundManager.candidateCount(), 4, "the bond that really arrived is recorded");
        _assertEscrowCovered();
    }

    /// @notice WHAT `maxParentForDeploy(1)` ACTUALLY PROMISES. The
    /// round trip is not exact and cannot be: the inverse is two integer divisions, so
    /// it is CONSERVATIVE by up to a hundred wei of the sleeve. The true property - what the view
    /// offers the call accepts, and what it leaves behind is worth less than a wei of bounty - is
    /// pinned here over a fuzzed sleeve rather than at one size. The token is neutral throughout:
    /// every switch on it is off, so it behaves exactly as the suite's ordinary edge currency.
    /// @param buy The edge currency spent on link 2, which is what sizes generation 1's sleeve.
    function testFuzz_maxParentForDeployAtLinkOneNeverOffersMoreThanTheSleeveHolds(uint256 buy) public {
        buy = bound(buy, 0.01 ether, 200 ether);
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
        _runWinningRound(1, WINNING_ABSORPTION);

        familyRouter.buyExactIn(2, buy, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, 0.01 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));

        uint256 available = vault.drawableEdge(1);
        uint256 offered = bidDeployer.maxParentForDeploy(1);
        uint256 bps = bidDeployer.BOUNTY_BPS();

        uint256 payout = offered + (offered * bps) / 10_000;
        // SOUND: what the view offers always fits in the sleeve, at every size
        assertLe(payout, available, "what it costs fits in the sleeve");
        // CONSERVATIVE, AND BY HOW MUCH: the two floored divisions can leave behind up to
        // `10_000 / BOUNTY_BPS` wei, no more. At the deployed 1 percent rate that is 100 wei.
        assertLt(available - payout, 10_000 / bps + 1, "and leaves under a hundred wei behind");
    }
}
