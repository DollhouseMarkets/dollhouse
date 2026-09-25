// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {HostileDoll} from "./utils/HostileDoll.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice Forfeit delivery on the finalization path must fail safely.
///
/// This matters because finalization is the round's ONLY progression path, there is
/// no pause and no rollback anywhere in this protocol, and it makes two external calls
/// that a third party can make revert. A chain that cannot finalize never crowns again. So the
/// forfeited bonds are now delivered on a path that is allowed to fail, and everything else in
/// this file is the evidence that it does fail safely: against a token that reverts, one that
/// answers `false`, one that takes a fee on transfer, one that blacklists the vault, and against
/// a vault that refuses the deposit outright.
contract Review5bTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    /// @dev The same $DOLL, with the switches. Etched over {DOLL_ADDRESS} in {setUp}, off, so the
    /// stack is deployed, wired and funded exactly as every other test sees it.
    HostileDoll internal hostile;

    /// @dev A bond that actually CHANGES across a rollover; the suite's
    /// default schedule doubles only every fourth link.
    function _bondSchedule() internal view virtual override returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: BOND_BASE, doublingEvery: 1, max: BOND_MAX});
    }

    function setUp() public {
        _setUpFamily();
        HostileDoll impl = new HostileDoll(18);
        vm.etch(DOLL_ADDRESS, address(impl).code);
        hostile = HostileDoll(DOLL_ADDRESS);
        assertEq(hostile.decimals(), 18, "the etched token is still the 18-decimal edge currency");
        assertEq(hostile.totalSupply(), doll.totalSupply(), "and holds every balance already minted");
    }

    // ---------------------------------------------------------------------------------
    // The forfeited bonds never block a crowning
    // ---------------------------------------------------------------------------------

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

    // ---------------------------------------------------------------------------------
    // The attribution sentinel is index 0
    // ---------------------------------------------------------------------------------

    /// @notice A round trip `[0, 1, 0]` ends where it started, at the EDGE CURRENCY, so the
    /// terminal token of the route is canonical index 0 and the creator credited is the genesis
    /// creator - the deployer, since adoption credits the deployment itself. The path
    /// pays the protocol fee on both edge legs; only one creator is ever credited for it.
    function test_aRoundTripPathCreditsTheGenesisCreator() public {
        _runWinningRound(1, WINNING_BUY);
        _warmOracles();
        address edge = roundManager.canonical(0);
        address genesisCreator = roundManager.creatorOf(edge);
        assertEq(genesisCreator, factory.DEPLOYER(), "index 0 is credited to the deployer");

        address link1 = roundManager.canonical(1);
        uint256 creditedBefore = vault.creatorBalance(edge);
        uint256 linkCreditedBefore = vault.creatorBalance(link1);
        uint256[] memory path = new uint256[](3);
        path[0] = 0;
        path[1] = 1;
        path[2] = 0;
        IERC20(address(doll)).approve(address(familyRouter), type(uint256).max);
        familyRouter.swapPath(path, 1 ether, 0, address(this), 3);

        assertGt(vault.creatorBalance(edge) - creditedBefore, 0, "the edge currency's creator is credited");
        assertEq(vault.creatorRecipient(edge), genesisCreator, "and it is claimable by the deployer");
        assertEq(vault.creatorBalance(link1), linkCreditedBefore, "the link the route passed THROUGH is credited nothing");
    }
}

/// @notice THE SELF-FUNDED PURSE. At generation 1 the parent IS the edge currency:
/// the vault pays the whole payout and the keeper delivers nothing at all. The
/// {BidDeployer.MIN_BOUNTY_DOLL} floor exists to make a small delivery of REAL parent tokens worth
/// its gas, and on that branch there is no delivery to compensate - so the floor is not paid.
contract Review5bBountyTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal keeper = address(0xBEEF);

    function setUp() public {
        _setUpEdge();
        // one more link, so that trades walking the chain fill generation 1's own sleeve
        _runWinningRound(1, WINNING_BUY);
        familyRouter.buyExactIn(2, 60 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, 20 ether, 0, address(this), 3);
        vm.warp(block.timestamp + 2 * uint256(bidDeployer.TWAP_WINDOW()));
        // the sleeve is drawable at 10% per 24 h, so the repeated small deployment this test
        // makes has to fit inside TODAY's allowance for the loop below to prove anything
        assertGt(vault.drawableEdge(1), 5 * 4 * bidDeployer.MIN_BOUNTY_DOLL(), "a sleeve to deploy");
    }

    /// @notice Repeat the smallest deployment a floor would make profitable. Every call is
    /// free to the keeper, so if a floor applied each one would skim `MIN_BOUNTY_DOLL` (capped at
    /// a quarter of the value) for no capital at all; the whole point of this test is that the
    /// total paid is the proportional rate on what was actually drawn instead.
    function test_theSelfFundedBranchPaysTheProportionalBountyOnly() public {
        uint256 min = bidDeployer.MIN_BOUNTY_DOLL();
        uint256 amount = 4 * min;
        uint256 keeperBefore = doll.balanceOf(keeper);
        uint256 drawableBefore = vault.drawableEdge(1);

        uint256 calls;
        for (uint256 i = 0; i < 5; i++) {
            if (bidDeployer.maxParentForDeploy(1) < amount) break;
            if (bidDeployer.bidCap(1) < amount) break;
            vm.prank(keeper);
            bidDeployer.deployAncestor(1, amount);
            calls++;
        }
        assertGt(calls, 1, "this loop really is repeatable");

        uint256 paid = doll.balanceOf(keeper) - keeperBefore;
        uint256 drawn = drawableBefore - vault.drawableEdge(1);
        // the keeper brought nothing, so everything it received is bounty
        assertEq(
            paid,
            (calls * amount * bidDeployer.BOUNTY_BPS()) / 10_000,
            "the proportional rate on each deployment, and nothing else"
        );
        assertLe(paid, (drawn * bidDeployer.BOUNTY_BPS()) / 10_000, "never more than the rate on what was drawn");
        // the floor, capped at a quarter of the value, is what applying a floor would pay per call
        assertLt(paid, (calls * amount) / 4, "far below the floor a floored branch would hand out");
        _assertSolvent();
    }

    /// @dev The floor where it BELONGS - a deployment that delivers real parent tokens - is
    /// asserted at generation 2 by `PurseTest.test_theBountyRuleIsUnchanged`, which this change
    /// leaves passing untouched.
}
