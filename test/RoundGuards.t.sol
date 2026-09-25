// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {IBurnableERC20} from "../contracts/interfaces/IBurnableERC20.sol";
import {FenwickRangeAdd} from "../contracts/libraries/FenwickRangeAdd.sol";
import {HostileDoll} from "./utils/HostileDoll.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {V4UnlockGuard} from "../contracts/libraries/V4UnlockGuard.sol";
import {V4UnlockGuardProbe} from "../contracts/libraries/V4UnlockGuardProbe.sol";

/// @dev A candidate creator whose bond refund cannot be PUSHED. Bonds are paid in $DOLL, so
/// the real case is a token that refuses the transfer - a blacklist, a pause, a non-standard
/// `false` return - rather than a contract without a `receive()`. The refusal is forced in the
/// test with `vm.mockCallRevert` on exactly that transfer, which is what `_tryTransfer` survives.
contract RefundRejector {
    function register(FamilyFactory factory, IERC20 edge, uint256 bond) external returns (uint256 id) {
        edge.approve(address(factory), bond);
        (,, id) = factory.registerCandidate("REJ", "REJ", "", type(uint256).max);
    }

    function claim(RoundManager rm, address to) external {
        rm.claimRefund(to);
    }
}

/// @notice Round-level guards: the pull refund fallback, the documented burn/threshold
/// interaction and the chain-depth limit.
contract RoundGuardsTest is RoundTestBase {
    using stdStorage for StdStorage;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // the pull refund fallback
    // ---------------------------------------------------------------------------------

    function test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth() public {
        RefundRejector rejector = new RefundRejector();
        uint256 bond = roundManager.currentBond();
        _fundDoll(address(rejector), bond);
        uint256 id = rejector.register(factory, IERC20(address(doll)), bond);
        assertEq(doll.balanceOf(address(rejector)), 0, "the rejector forwarded its whole bond");

        RoundManager.Candidate memory c = roundManager.candidateInfo(id);
        Cand memory cand = Cand({
            token: c.token,
            key: c.key,
            poolId: c.key.toId(),
            id: id,
            tokenIsCurrency0: address(c.token) < roundManager.head(),
            creator: address(rejector)
        });
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 5);
        _tradeCandidate(cand, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(id);

        vm.warp(submitEnd);
        // the token refuses exactly this transfer, so the push refund reverts inside `finalize`
        vm.mockCallRevert(address(doll), abi.encodeCall(IERC20.transfer, (address(rejector), bond)), "blacklisted");
        roundManager.finalize();
        vm.clearMockedCalls();
        assertEq(roundManager.head(), c.token, "the rejector won");
        assertEq(doll.balanceOf(address(rejector)), 0, "the push refund could not land");
        assertEq(roundManager.pendingRefund(address(rejector)), bond, "it is owed as a pull claim");
        assertEq(doll.balanceOf(address(roundManager)), bond, "and the escrow still holds it");

        // nobody else can take it
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        roundManager.claimRefund(address(this));

        // the creator pulls it to an address the token does accept
        address payout = address(0xF00D);
        rejector.claim(roundManager, payout);
        assertEq(doll.balanceOf(payout), bond, "the bond was pulled out");
        assertEq(roundManager.pendingRefund(address(rejector)), 0, "and the claim is cleared");

        // and only once
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        rejector.claim(roundManager, payout);
    }

    // ---------------------------------------------------------------------------------
    // Burning head supply lowers H (accepted, documented)
    // ---------------------------------------------------------------------------------

    /// @notice `H` is a fraction of the head's LIVE supply, so burning head tokens lowers the
    /// succession threshold. This is accepted and documented in `RoundManager.threshold`: the
    /// burner pays the full market value of what they burn to move `H` by only `h` times as
    /// much (15 bps at deploy), so it is a ~667x-overpriced attack that also enriches every
    /// other holder of the very token being defended.
    function test_burningHeadSupplyLowersThreshold() public {
        uint256 hBefore = roundManager.threshold();
        uint256 supplyBefore = IERC20(roundManager.head()).totalSupply();
        assertEq(hBefore, (supplyBefore * H_FRAC_WAD) / 1e18, "H tracks the live supply");

        uint256 burn = IERC20(roundManager.head()).balanceOf(address(this)) / 2;
        assertGt(burn, 0);
        IBurnableERC20(roundManager.head()).burn(burn);

        uint256 hAfter = roundManager.threshold();
        assertLt(hAfter, hBefore, "burning head supply lowers H");
        assertEq(hAfter, ((supplyBefore - burn) * H_FRAC_WAD) / 1e18, "by exactly h x the burn");

        // the relief is `h` times the burn: the burner pays 1/h times what they buy
        assertEq(hBefore - hAfter, (burn * H_FRAC_WAD) / 1e18, "h x burn, not 1:1");
        assertLt(hBefore - hAfter, burn / 100, "which is a tiny fraction of what it cost");

        // and a round opened afterwards really does use the lowered threshold
        _registerCandidate(address(0xA11CE), "A");
        assertEq(roundManager.roundInfo(roundManager.roundCount()).hUsed, hAfter, "the round uses the live H");
    }

    // ---------------------------------------------------------------------------------
    // The chain depth limit is a clear revert at REGISTRATION
    // ---------------------------------------------------------------------------------

    /// @notice The ancestor sleeve is a Fenwick tree over a bounded index space. The chain must
    /// refuse the registration that would create an unaddressable generation, rather than let
    /// the tree revert later from inside a swap and brick every pool on the chain.
    function test_registrationRefusesToExceedTheChainDepthLimit() public {
        uint256 max = FenwickRangeAdd.MAX_INDEX;

        // one below the limit: a registration is still fine. `headIndex` is located by its own
        // getter rather than a hardcoded slot, so adding state to the RoundManager cannot make
        // this test silently poke the wrong word. The bond is read AFTER the write: it scales
        // with the index the round competes for.
        stdstore.target(address(roundManager)).sig("headIndex()").checked_write(max - 1);
        assertEq(roundManager.headIndex(), max - 1);
        uint256 bond = roundManager.currentBond();
        assertEq(bond, roundManager.BOND_MAX(), "the schedule is capped, not unbounded");
        _fundDoll(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        doll.approve(address(factory), bond);
        vm.prank(address(0xA11CE));
        factory.registerCandidate("OK", "OK", "", type(uint256).max);

        // at the limit the next link would be unaddressable: a named, immediate revert
        stdstore.target(address(roundManager)).sig("headIndex()").checked_write(max);
        _fundDoll(address(0xB0B), bond);
        vm.prank(address(0xB0B));
        doll.approve(address(factory), bond);
        vm.prank(address(0xB0B));
        vm.expectRevert(FamilyFactory.ChainDepthLimit.selector);
        factory.registerCandidate("NO", "NO", "", type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // REN-01: the round machine and the claims refuse to run inside somebody's unlock
    // ---------------------------------------------------------------------------------

    /// @notice The slot the guard reads is v4-core's own, by its own definition.
    function test_REN01_theGuardReadsV4sOwnLockSlot() public pure {
        assertEq(
            V4UnlockGuard.IS_UNLOCKED_SLOT,
            bytes32(uint256(keccak256("Unlocked")) - 1),
            "Lock.IS_UNLOCKED_SLOT"
        );
    }

    /// @notice REN-01 as the property states it. Being inside a `PoolManager` unlock used not to
    /// be a state the protocol checked, so a contract could open its own flash accounting, swap,
    /// and settle a round in the same frame. Every round-machine transition and every pull
    /// payment now refuses; the swap path itself is untouched, which the rest of the suite shows.
    function test_REN01_everyGuardedEntrypointRefusesFromInsideAnUnlock() public {
        UnlockProber p = new UnlockProber(IPoolManager(address(manager)));

        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.finalize, ())),
            RoundManager.InsideUnlock.selector,
            "finalize"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.requestEnd, ())),
            RoundManager.InsideUnlock.selector,
            "requestEnd"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.finalizeDeterministic, ())),
            RoundManager.InsideUnlock.selector,
            "finalizeDeterministic"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.submitScore, (0))),
            RoundManager.InsideUnlock.selector,
            "submitScore"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimDev, (address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimDev"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimCreator, (address(token), address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimCreator"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimCreatorAccrued, (address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimCreatorAccrued"
        );
        // The two round-machine paths that were still unguarded, and the keeper
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.fulfilEnd, (""))),
            RoundManager.InsideUnlock.selector,
            "fulfilEnd"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.claimRefund, (address(this)))),
            RoundManager.InsideUnlock.selector,
            "claimRefund"
        );
        assertEq(
            p.probe(address(bidDeployer), abi.encodeWithSignature("deployEdgeBid()")),
            BidDeployer.InsideUnlock.selector,
            "deployEdgeBid"
        );
    }

    // ---------------------------------------------------------------------------------
    // REN-01: the guard is BOUND to the deployed PoolManager, and cannot fail open
    // ---------------------------------------------------------------------------------

    /// @notice A guard that reads the wrong slot answers `false` forever, and every
    /// `notInsideUnlock` in the stack becomes a silent no-op. The binding is therefore proved,
    /// not assumed: `false` outside an unlock (which `FamilyFactory.wire` asserts on the way to
    /// the first launch) and `true` inside one, which needs an unlock to be opened. The deploy
    /// script runs exactly this probe against the manager it deployed to, and
    /// `test/fork/UnlockGuard.fork.t.sol` runs it against the live singleton.
    function test_REN01_theGuardIsBoundToTheDeployedPoolManager() public {
        assertFalse(V4UnlockGuard.isInsideUnlock(address(manager)), "false outside an unlock");
        assertTrue(new V4UnlockGuardProbe().probe(address(manager)), "and true inside one");
        assertTrue(factory.wired(), "the stack was wired with the guard read exercised");
    }

    /// @notice ...and the check is in `wire`, so a stack wired against a manager the guard cannot
    /// read never launches anything. The read is exercised at the door: against a manager with no
    /// `exttload` it reverts rather than wiring a stack whose guards are decorative.
    function test_REN01_wiringRevertsWhenTheGuardCannotReadTheManager() public {
        FamilyFactory fresh = _deployStack(true, steward, address(0)).factory;
        // a manager whose lock slot cannot be read at all: the guard's `exttload` reverts, and
        // so does the wiring that depends on it
        vm.mockCallRevert(address(manager), abi.encodeWithSignature("exttload(bytes32)"), "");
        vm.expectRevert();
        fresh.wire();
        vm.clearMockedCalls();
        fresh.wire();
        assertTrue(fresh.wired(), "and it wires once the manager answers");
    }

    /// @notice OUTSIDE an unlock the same calls behave exactly as they did: the guard is a state
    /// check, not a permission. `finalize` on a round that has not settled still reverts with its
    /// own error, and a round still runs end to end.
    function test_REN01_theGuardChangesNothingOutsideAnUnlock() public {
        _openRoundAtNominalEnd();
        vm.expectRevert(RoundManager.EndNotSettled.selector);
        roundManager.finalize();

        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    /// @dev Open a round and stand at its nominal end `T`, where {RoundManager.requestEnd} is
    /// the next legal call.
    function _openRoundAtNominalEnd() internal returns (uint256 roundId) {
        _registerCandidate(address(0xA11CE), "CAND");
        roundId = roundManager.roundCount();
        (, uint64 nominalEnd,) = _roundTimes(roundId);
        vm.warp(nominalEnd);
    }
}

/// @dev The suite's $DOLL with switches ({HostileDoll}), etched over {DOLL_ADDRESS} after the stack
/// is deployed, wired and funded, plus a round taken to the edge of finalization.
abstract contract HostileEdgeTokenTestBase is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    HostileDoll internal hostile;

    function _etchHostileDoll() internal {
        HostileDoll impl = new HostileDoll(18);
        vm.etch(DOLL_ADDRESS, address(impl).code);
        hostile = HostileDoll(DOLL_ADDRESS);
    }

    /// @dev Register three candidates, push the first over the threshold and take the round all
    /// the way to the edge of finalization. The caller then breaks whatever it likes and calls
    /// {RoundManager.finalize} itself.
    function _stageRoundReadyToFinalize() internal returns (uint256 bond) {
        bond = roundManager.currentBond();
        delete cands;
        for (uint256 i = 0; i < 3; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i + block.timestamp)), "CAND");
        }
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);

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
}

/// @notice Forfeit delivery on the finalization path must fail safely.
///
/// This matters because finalization is the round's ONLY progression path, there is
/// no pause and no rollback anywhere in this protocol, and it makes two external calls
/// that a third party can make revert. A chain that cannot finalize never crowns again. So the
/// forfeited bonds are now delivered on a path that is allowed to fail, and everything else in
/// this file is the evidence that it does fail safely: against a token that reverts, one that
/// answers `false`, one that takes a fee on transfer, one that blacklists the vault, and against
/// a vault that refuses the deposit outright.
contract ForfeitDeliveryTest is HostileEdgeTokenTestBase {
    /// @dev A bond that actually CHANGES across a rollover; the suite's
    /// default schedule doubles only every fourth link.
    function _bondSchedule() internal view virtual override returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: BOND_BASE, doublingEvery: 1, max: BOND_MAX});
    }

    function setUp() public {
        _setUpFamily();
        _etchHostileDoll();
        assertEq(hostile.decimals(), 18, "the etched token is still the 18-decimal edge currency");
        assertEq(hostile.totalSupply(), doll.totalSupply(), "and holds every balance already minted");
    }

    // ---------------------------------------------------------------------------------
    // The forfeited bonds never block a crowning
    // ---------------------------------------------------------------------------------

    /// @dev The whole shape of the fix in one place: the round crowns, the two losing bonds are
    /// held rather than delivered, and the vault's earmark has not moved.
    function _assertCrownedWithForfeitsHeld(uint256 bond) internal view {
        assertEq(roundManager.headIndex(), 1, "the round CROWNED: link one exists");
        assertEq(roundManager.head(), cands[0].token, "and the candidate that won holds it");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "both losing bonds are held for delivery");
        assertEq(vault.edgeBidEarmark(), 0, "nothing reached the earmark");
        assertGe(
            IERC20(address(doll)).balanceOf(address(roundManager)),
            roundManager.bondEscrow() + roundManager.pendingForfeits(),
            "and the held tokens are really there"
        );
    }

    /// @notice A PAUSABLE edge currency, paused between the last score and finalization. The
    /// transfer of the forfeited bonds reverts; the round crowns anyway.
    function test_aPausedEdgeCurrencyDoesNotStopTheCrowning() public {
        uint256 bond = _stageRoundReadyToFinalize();
        hostile.setPaused(true);

        vm.expectEmit(false, false, false, true);
        emit RoundManager.ForfeitDeferred(2 * bond);
        roundManager.finalize();

        _assertCrownedWithForfeitsHeld(bond);
        // the winner's refund could not be pushed either, and falls back to the pull by design:
        // the two failures are independent and neither reverts the round
        assertEq(roundManager.pendingRefund(cands[0].creator), bond, "the refund waits as a claim");

        // ...and once the token works again, the held forfeits go where they always belonged
        hostile.setPaused(false);
        roundManager.flushForfeits();
        assertEq(roundManager.pendingForfeits(), 0, "nothing held any more");
        assertEq(vault.edgeBidEarmark(), 2 * bond, "the earmark received both bonds");
        _assertSolvent();
    }

    /// @notice An edge currency that answers `false` instead of reverting. `SafeERC20` turns that
    /// into a revert, which is precisely what finalization must survive.
    function test_anEdgeCurrencyThatReturnsFalseDoesNotStopTheCrowning() public {
        uint256 bond = _stageRoundReadyToFinalize();
        hostile.setReturnsFalse(true);

        roundManager.finalize();
        _assertCrownedWithForfeitsHeld(bond);

        // it is still broken, so the retry reverts and the amount stays held
        vm.expectRevert();
        roundManager.flushForfeits();
        assertEq(roundManager.pendingForfeits(), 2 * bond, "still held, nothing lost");

        hostile.setReturnsFalse(false);
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "delivered on the retry");
    }

    /// @notice A FEE-ON-TRANSFER edge currency. The transfer itself succeeds, so the failure lands
    /// one call later: the vault counts what actually arrived and refuses the deposit
    /// ({FeeVault.NotDelivered}), a check that runs on the finalization path.
    function test_aFeeOnTransferEdgeCurrencyDoesNotStopTheCrowning() public {
        uint256 bond = _stageRoundReadyToFinalize();
        hostile.setFeeBps(100); // 1% skimmed off every transfer

        roundManager.finalize();
        assertEq(roundManager.headIndex(), 1, "the round CROWNED");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "both losing bonds are held");
        assertEq(vault.edgeBidEarmark(), 0, "the vault refused a delivery that arrived short");

        vm.expectRevert(FeeVault.NotDelivered.selector);
        roundManager.flushForfeits();

        hostile.setFeeBps(0);
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "delivered in full once the token stops skimming");
    }

    /// @notice A BLACKLISTING edge currency that blocks the vault. Nothing this protocol owns can
    /// undo that, and the chain still moves.
    function test_aBlacklistedVaultDoesNotStopTheCrowning() public {
        uint256 bond = _stageRoundReadyToFinalize();
        hostile.setBlocked(address(vault), true);

        roundManager.finalize();
        _assertCrownedWithForfeitsHeld(bond);

        hostile.setBlocked(address(vault), false);
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond);
    }

    /// @notice The other half of the same path: a VAULT that refuses the deposit. The token is
    /// perfectly well behaved here; it is the solvency check on the far side that reverts.
    function test_aVaultThatRefusesTheDepositDoesNotStopTheCrowning() public {
        uint256 bond = _stageRoundReadyToFinalize();
        vm.mockCallRevert(
            address(vault),
            abi.encodeWithSelector(FeeVault.depositEdgeBidEarmark.selector),
            abi.encodeWithSelector(FeeVault.NotDelivered.selector)
        );

        roundManager.finalize();
        assertEq(roundManager.headIndex(), 1, "the round CROWNED");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "the forfeit is held");

        vm.clearMockedCalls();
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "and delivered once the vault accepts it");
        _assertSolvent();
    }

    /// @notice Nothing to flush is a named refusal, not a silent success that emits an event.
    function test_flushingNothingReverts() public {
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        roundManager.flushForfeits();
    }

    /// @notice The happy path is unchanged: a well-behaved token delivers the forfeits INSIDE
    /// finalization, and nothing is ever left pending.
    function test_theNormalPathStillDeliversInsideFinalize() public {
        uint256 bond = _stageRoundReadyToFinalize();
        roundManager.finalize();

        assertEq(roundManager.headIndex(), 1, "crowned");
        assertEq(roundManager.pendingForfeits(), 0, "nothing deferred");
        assertEq(vault.edgeBidEarmark(), 2 * bond, "the earmark took both losing bonds at once");
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // The bond a registrant agreed to
    // ---------------------------------------------------------------------------------

    /// @notice A blanket allowance survives a rollover; the bond does not. The registrant states
    /// the figure it was quoted and the doubled bond is refused rather than pulled.
    function test_aStandingAllowanceIsNotChargedTheNextRoundsBond() public {
        uint256 quoted = roundManager.currentBond();
        _runWinningRound(1, WINNING_BUY);
        uint256 nowDue = roundManager.currentBond();
        assertEq(nowDue, 2 * quoted, "the bond doubled with the link the next round competes for");

        address alice = address(0xA11CE);
        _fundDoll(alice, nowDue);
        vm.prank(alice);
        IERC20(address(doll)).approve(address(factory), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FamilyFactory.BondTooHigh.selector, nowDue, quoted));
        factory.registerCandidate("STALE", "STALE", "", quoted);

        // and the same allowance pays the bond the registrant was actually shown
        vm.prank(alice);
        factory.registerCandidate("FRESH", "FRESH", "", nowDue);
        assertEq(IERC20(address(doll)).balanceOf(alice), 0, "exactly the bond, once");
    }

}

/// @notice THE BOND ESCROW. `addCandidate` proves a bond was really delivered by comparing this
/// contract's balance against what it owes: `bondEscrow` AND `pendingForfeits`, tokens held for
/// the vault, so held forfeits can never stand in for a bond that never arrived.
///
/// Registration is also reachable from inside this contract's own transfers. Two paths book value
/// out before they move it:
///
///   {RoundManager.flushForfeits} zeroes `pendingForfeits` and then transfers, and
///   {RoundManager.finalize} releases `bondEscrow` and then pushes the forfeit and the refund.
///
/// In both windows the balance still holds tokens that are no longer owed to anyone the check
/// knows about, so a bond delivered SHORT would pass a balance check alone. The edge currency is
/// an ERC-20 this protocol did not write, and one with a sender hook can call the factory back
/// from inside the very transfer the protocol is making. Both factory entrypoints carry the
/// reentrancy guard; the factory calls them in sequence and nothing between them re-enters the
/// RoundManager, so the honest path is unchanged.
contract BondEscrowTest is HostileEdgeTokenTestBase {
    /// @dev The skim the attacker's own bond suffers, in basis points: the bond arrives SHORT.
    uint256 internal constant SKIM_BPS = 100;

    function setUp() public {
        _setUpFamily();
        _etchHostileDoll();
    }

    /// @dev Crown a round with the token paused, so both losing bonds are HELD rather than
    /// delivered and `pendingForfeits` is non-zero for what follows.
    function _crownWithForfeitsHeld() internal returns (uint256 bond) {
        bond = _stageRoundReadyToFinalize();
        hostile.setPaused(true);
        roundManager.finalize();
        hostile.setPaused(false);
        assertEq(roundManager.pendingForfeits(), 2 * bond, "two bonds are held for the vault");
    }

    /// @notice THE PROPERTY. A registration whose bond arrives SHORT, while held forfeits sit in
    /// the same balance, is refused: reading `bondEscrow` alone would let the held forfeits cover
    /// the shortfall and record the candidate as having paid a bond it never paid in full.
    function test_anUnderDeliveredBondIsRefusedEvenWhileForfeitsAreHeld() public {
        uint256 forfeits = _crownWithForfeitsHeld();
        uint256 bond = roundManager.currentBond();

        address alice = address(0xA11CE);
        _fundDoll(alice, bond);
        vm.prank(alice);
        IERC20(address(doll)).approve(address(factory), type(uint256).max);

        hostile.setFeeBps(100); // 1% skimmed in flight: the bond arrives short by bond/100
        uint256 held = IERC20(address(doll)).balanceOf(address(roundManager));
        uint256 escrow = roundManager.bondEscrow();
        assertEq(held, escrow + 2 * forfeits, "the balance covers both ledgers before the call");
        // the masking condition, spelled out: the shortfall is smaller than what is held for the
        // vault, so the OLD check - balance against `bondEscrow` alone - would have passed
        assertGt(2 * forfeits, bond / 100, "the held forfeits are larger than the shortfall");

        vm.prank(alice);
        vm.expectRevert(RoundManager.BondNotDelivered.selector);
        factory.registerCandidate("SHORT", "SHORT", "", type(uint256).max);

        // and the same registration goes through the moment the token stops skimming
        hostile.setFeeBps(0);
        vm.prank(alice);
        factory.registerCandidate("FULL", "FULL", "", type(uint256).max);
        assertEq(roundManager.bondEscrow(), escrow + bond, "the bond that was really delivered is escrowed");
        assertEq(roundManager.pendingForfeits(), 2 * forfeits, "and the held forfeits were not touched");
    }

    /// @notice CONSERVATION ACROSS FINALIZE AND FLUSH. The earmark grows by the forfeited bonds,
    /// exactly, exactly once, whether the delivery happens inside `finalize` or on a later flush.
    function test_theEarmarkTakesTheForfeitedBondsExactlyOnce() public {
        uint256 bond = _crownWithForfeitsHeld();
        assertEq(vault.edgeBidEarmark(), 0, "nothing reached the earmark inside finalize");

        uint256 earmarkBefore = vault.edgeBidEarmark();
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark() - earmarkBefore, 2 * bond, "the delta IS the forfeited amount");
        assertEq(roundManager.pendingForfeits(), 0, "nothing is held any more");

        // and there is no second delivery to be had, by anyone
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "still exactly the forfeited amount");
        _assertSolvent();
    }

    /// @notice A GAS-BURNING EDGE TOKEN CANNOT STARVE THE CROWNING. The forfeit delivery is made
    /// through a `try`, which hands the token 63/64 of the gas left; this token consumes every
    /// drop of it. The round must still crown out of the remaining 64th, under a finite gas limit
    /// rather than the test runner's unbounded one.
    function test_finalizeCrownsUnderAGasLimitAgainstAGasBurningEdgeToken() public {
        uint256 bond = _stageRoundReadyToFinalize();

        // what an honest finalization costs, measured and then thrown away
        uint256 snap = vm.snapshotState();
        uint256 gasBefore = gasleft();
        roundManager.finalize();
        uint256 honest = gasBefore - gasleft();
        vm.revertToState(snap);

        hostile.setBurnsGasTo(address(vault));
        // 64 times the honest cost: the token takes 63/64 of it and the 64th left behind is what
        // has to carry the rest of the round end
        uint256 limit = 64 * honest;
        roundManager.finalize{gas: limit}();
        hostile.setBurnsGasTo(address(0));

        assertEq(roundManager.headIndex(), 1, "the round CROWNED");
        assertEq(roundManager.head(), cands[0].token, "and the candidate that won holds link one");
        assertEq(roundManager.pendingForfeits(), 2 * bond, "the delivery it could not afford is held, not lost");
        assertEq(vault.edgeBidEarmark(), 0, "and nothing reached the earmark");

        // the held amount is still deliverable once the token behaves
        roundManager.flushForfeits();
        assertEq(vault.edgeBidEarmark(), 2 * bond, "delivered in full on the retry");
        _assertSolvent();
    }

    /// @notice A HOSTILE EDGE TOKEN RE-ENTERING THE FLUSH. `flushForfeits` zeroes what it holds
    /// before it transfers, and carries the reentrancy guard on top: a token that calls back into
    /// it from inside the transfer is refused, and the forfeits are delivered exactly once.
    function test_flushForfeitsRejectsAReentrantEdgeToken() public {
        uint256 bond = _crownWithForfeitsHeld();
        hostile.setReenters(address(roundManager));

        roundManager.flushForfeits();

        assertTrue(hostile.reentryRejected(), "the re-entrant flush was refused");
        assertEq(vault.edgeBidEarmark(), 2 * bond, "the forfeits arrived exactly once");
        assertEq(roundManager.pendingForfeits(), 0, "and nothing is held");
        hostile.setReenters(address(0));
        _assertSolvent();
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
        uint256 bond = _stageRoundReadyToFinalize();
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
    /// skim, no re-entry, refused with `BondNotDelivered`. The guard closes a window
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
}

/// @dev Opens a v4 unlock of its own and makes one call from inside it, reporting the revert
/// selector rather than bubbling it. Nothing in the callback creates a delta, so the unlock
/// itself settles cleanly and what the test reads is the guard and only the guard.
contract UnlockProber is IUnlockCallback {
    IPoolManager internal immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function probe(address target, bytes memory call) external returns (bytes4 selector) {
        return abi.decode(poolManager.unlock(abi.encode(target, call)), (bytes4));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory ret) = target.call(call);
        if (ok) return abi.encode(bytes4(0));
        if (ret.length < 4) return abi.encode(bytes4(0xffffffff));
        return abi.encode(bytes4(ret));
    }
}
