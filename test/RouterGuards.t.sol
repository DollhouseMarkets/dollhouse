// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice Router hardening: value accounting, candidate routes and their attribution,
/// residual settlement across a route, and the round-trip delta read order.
contract RouterGuardsTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link1;

    function setUp() public {
        _setUpFamily();
        link1 = _runWinningRound(1, WINNING_BUY).token;
        _useLink(1);
        vm.warp(block.timestamp + 10);
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        _buyLink(1, 5 ether);
    }

    // ---------------------------------------------------------------------------------
    // Value accounting
    // ---------------------------------------------------------------------------------

    /// @notice Every route is funded by an ERC-20 `transferFrom` of exactly
    /// what the route actually spends, pulled inside the unlock: there is no `msg.value` to
    /// mismatch, no refund leg, and a route with nothing to spend is refused at the door.
    function test_swapPathIsFundedByTheCallerAndNothingElse() public {
        uint256[] memory path = new uint256[](2);
        path[0] = 0;
        path[1] = 1;

        vm.expectRevert(FamilyRouter.NothingIn.selector);
        familyRouter.swapPath(path, 0, 0, address(this), 1);

        uint256 before = doll.balanceOf(address(this));
        assertGt(familyRouter.swapPath(path, 1 ether, 0, address(this), 1), 0, "an approved route works");
        assertEq(before - doll.balanceOf(address(this)), 1 ether, "the caller paid exactly what it named");

        // and an unapproved caller cannot spend somebody else's balance
        address stranger = address(0xBEEF);
        _fundDoll(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        familyRouter.swapPath(path, 1 ether, 0, stranger, 1);
    }

    /// @notice ETH that somehow ends up at the router cannot be swept by anybody. There is no
    /// native path in the router at all, so there is no `receive()`, no payable
    /// entrypoint, and nothing that can move a native balance out again.
    function test_routerHeldEthCannotBeSwept() public {
        // a plain transfer is refused outright
        (bool sent,) = address(familyRouter).call{value: 1 ether}("");
        assertFalse(sent, "the router has no receive()");

        // force ETH in anyway (as a selfdestruct or a coinbase payout would)
        vm.deal(address(familyRouter), 5 ether);
        assertEq(address(familyRouter).balance, 5 ether);

        uint256[] memory path = new uint256[](2);
        path[0] = 0;
        path[1] = 1;
        // a legitimate route leaves the stranded balance exactly where it was
        uint256 before = doll.balanceOf(address(this));
        familyRouter.swapPath(path, 1 ether, 0, address(this), 1);
        assertEq(address(familyRouter).balance, 5 ether, "the stranded ETH is untouched");
        assertEq(before - doll.balanceOf(address(this)), 1 ether, "the caller spent only its own tokens");
    }

    // ---------------------------------------------------------------------------------
    // Round trips
    // ---------------------------------------------------------------------------------

    /// @notice A route whose first and last currency are the SAME must still report its output:
    /// reading the output delta after settling the input would report zero.
    function test_roundTripPathReportsItsOutput() public {
        uint256 amount = doll.balanceOf(address(this)) / 10_000;
        uint256[] memory path = new uint256[](3);
        path[0] = 0;
        path[1] = 1;
        path[2] = 0;

        uint256 before = doll.balanceOf(address(this));
        uint256 out = familyRouter.swapPath(path, amount, 0, address(this), 2);
        uint256 after_ = doll.balanceOf(address(this));

        assertGt(out, 0, "the round trip reports what came back, not zero");
        assertEq(after_, before - amount + out, "settled NET, at exactly the reported output");
        assertLt(out, amount, "and a round trip still loses the fees");

        // slippage protection works on a round trip too, which it could not if the reported
        // output were zero
        vm.expectRevert();
        familyRouter.swapPath(path, amount, amount, address(this), 2);
    }

    // ---------------------------------------------------------------------------------
    // Residual settlement
    // ---------------------------------------------------------------------------------

    /// @notice A partially filled route settles every currency it touched: the caller is
    /// refunded, `to` holds the output plus any intermediate residue, and the router keeps
    /// nothing in any currency.
    function test_midRoutePartialFillSettlesEveryCurrency() public {
        address to = address(0xD00D);
        // more $DOLL than link one's whole curve can absorb, so the first leg fills partially
        uint256 huge = 10_000_000_000 ether;
        _fundDoll(address(this), huge);

        uint256 before = doll.balanceOf(address(this));
        uint256 out = familyRouter.buyExactIn(1, huge, 0, to, 2);
        uint256 spent = before - doll.balanceOf(address(this));

        assertLt(spent, huge, "the unfillable remainder was never pulled (partial first leg)");
        assertGt(out, 0, "the fillable part was delivered");
        assertEq(IERC20(link1).balanceOf(to), out, "the terminal token went to `to`");
        assertEq(address(familyRouter).balance, 0, "no ETH anywhere near the router");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "no input stranded");
        assertEq(IERC20(link1).balanceOf(address(familyRouter)), 0, "no output stranded");
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // Candidate routes
    // ---------------------------------------------------------------------------------

    function test_buyAndSellCandidateWithTheEdgeCurrency() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart, uint64 tradingEnd,) = _roundTimes(roundManager.roundCount());

        // INSTANT TRADING: the pool opens at its own registration, so the route works during
        // Registration, before the round clock starts
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration));
        vm.warp(block.timestamp + 3); // past the pool's own snipe tax
        assertGt(familyRouter.buyCandidate(c.id, 1 ether, 1, address(0xBEEF), 8), 0, "buyable during Registration");

        // only Idle is refused (unreachable for a registered candidate; forced by a mock)
        _mockPhase(c.id, RoundManager.Phase.Idle);
        vm.expectRevert(FamilyRouter.NotTrading.selector);
        familyRouter.buyCandidate(c.id, 1 ether, 0, address(this), 8);
        vm.clearMockedCalls();

        vm.warp(tradingStart + 10);
        uint256 out = familyRouter.buyCandidate(c.id, 1 ether, 1, address(this), 8);
        assertGt(out, 0, "the edge currency bought the candidate through the whole chain");
        assertEq(IERC20(c.token).balanceOf(address(this)), out, "delivered");
        assertEq(doll.balanceOf(address(familyRouter)), 0, "nothing stranded");

        IERC20(c.token).approve(address(familyRouter), type(uint256).max);
        uint256 dollBefore = doll.balanceOf(address(this));
        uint256 back = familyRouter.sellCandidate(c.id, out / 2, 1, address(this), 8);
        assertGt(back, 0, "sold back into the edge currency");
        assertEq(doll.balanceOf(address(this)) - dollBefore, back, "delivered to `to`");

        // After the bell the route keeps working - through the index the ROUND recorded
        // as its parent, not through whatever the head has become since
        _settleEnd();
        assertGt(familyRouter.buyCandidate(c.id, 1 ether, 1, address(this), 8), 0, "still buyable");
    }

    /// @notice The edge fee on a candidate buy is credited through the sentinel attribution
    /// index - not to any canonical link's index - and the creator share is SPLIT 50/50 between
    /// the candidate's creator and the creator of the head the candidate is challenging (the
    /// round's parent, whose token the round is quoted in). Canonical-link trades are unchanged.
    function test_candidateBuySplitsTheCreatorShareWithTheHeadCreator() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        address headCreator = roundManager.creatorOf(link1);
        assertTrue(headCreator != address(0) && headCreator != address(0xA11CE), "two distinct creators");

        uint256 creatorBefore = vault.creatorBalance(c.token);
        uint256 link1Before = vault.creatorBalance(link1);
        familyRouter.buyCandidate(c.id, 1 ether, 0, address(this), 8);

        uint256 creatorShare = ((1 ether / 100) * CREATOR_BPS) / 10_000;
        uint256 toCandidate = vault.creatorBalance(c.token) - creatorBefore;
        uint256 toHead = vault.creatorBalance(link1) - link1Before;
        assertEq(toCandidate + toHead, creatorShare, "the whole creator share is still paid out");
        assertEq(toHead, creatorShare / 2, "half goes to the head's creator");
        assertEq(toCandidate, creatorShare - creatorShare / 2, "the candidate's creator takes the other half");
        assertEq(vault.creatorRecipient(c.token), address(0xA11CE), "claimable by the candidate's creator");

        vm.prank(address(0xA11CE));
        uint256 paid = vault.claimCreator(c.token, address(0xA11CE));
        assertEq(paid, toCandidate, "and it is really claimable");
        vm.prank(headCreator);
        assertEq(
            vault.claimCreator(link1, headCreator),
            link1Before + toHead,
            "so is the head creator's half, on top of what it had already earned"
        );
        _assertSolvent();
    }

    /// @notice The 50/50 split applies from the candidate's registration: a buy during
    /// Registration (the pool trades before the round clock starts) is "during the round" too.
    function test_candidateBuyDuringRegistrationSplitsTheCreatorShare() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration));
        vm.warp(block.timestamp + 3);

        uint256 creatorBefore = vault.creatorBalance(c.token);
        uint256 link1Before = vault.creatorBalance(link1);
        familyRouter.buyCandidate(c.id, 1 ether, 0, address(this), 8);

        uint256 creatorShare = ((1 ether / 100) * CREATOR_BPS) / 10_000;
        uint256 toCandidate = vault.creatorBalance(c.token) - creatorBefore;
        uint256 toHead = vault.creatorBalance(link1) - link1Before;
        assertEq(toHead, creatorShare / 2, "half goes to the head's creator during Registration");
        assertEq(toCandidate, creatorShare - creatorShare / 2, "the candidate's creator takes the other half");
        _assertSolvent();
    }

    /// @dev Force `phase(roundOf(candidateId))` to answer `p` for both the router and the vault.
    function _mockPhase(uint256 candidateId, RoundManager.Phase p) internal {
        uint256 roundId = roundManager.candidateInfo(candidateId).roundId;
        vm.mockCall(
            address(roundManager), abi.encodeWithSelector(RoundManager.phase.selector, roundId), abi.encode(p)
        );
    }

    /// @notice A canonical-link buy pays the WHOLE creator share to that link's own creator: the
    /// 50/50 rule is a candidate-trade rule only.
    function test_canonicalBuyPaysTheWholeCreatorShareToThatLinksCreator() public {
        uint256 before = vault.creatorBalance(link1);
        uint256 genesisBefore = vault.creatorBalance(address(doll));
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 2);
        assertEq(
            vault.creatorBalance(link1) - before,
            ((1 ether / 100) * CREATOR_BPS) / 10_000,
            "#1's creator takes all of it"
        );
        assertEq(vault.creatorBalance(address(doll)), genesisBefore, "and nobody else is credited");
    }

    /// @notice The head-creator half is credited per TRADE, not per outcome: a candidate that
    /// goes on to LOSE the round still leaves its creator holding their half, claimable forever.
    function test_losingCandidateCreatorKeepsTheirHalf() public {
        Cand memory loser = _registerCandidate(address(0xB0B), "LOSER");
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        // small enough that the candidate's absorption cannot clear H over the trading window
        uint256 buy = 0.01 ether;
        vm.warp(tradingStart + 10);
        familyRouter.buyCandidate(loser.id, buy, 0, address(this), 8);

        uint256 creatorShare = ((buy / 100) * CREATOR_BPS) / 10_000;
        uint256 half = creatorShare - creatorShare / 2;
        assertEq(vault.creatorBalance(loser.token), half, "credited while the round was live");

        // the round fails - nobody ever submitted a score, so there is no best candidate - and
        // the loser never becomes canonical
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        assertEq(roundManager.head(), link1, "the loser did not succeed");
        assertFalse(roundManager.isCanonical(loser.token));

        vm.prank(address(0xB0B));
        assertEq(vault.claimCreator(loser.token, address(0xB0B)), half, "and their half is still claimable");
        _assertSolvent();
    }

    /// @notice THE LOSER'S EXIT. When a round ends, a losing candidate's holders must not
    /// lose both their supported route and their creator's fee stream: without a recorded parent
    /// the router would walk the CURRENT head, which is a different token by then, leaving only
    /// an unattributed third-party swap as a way out. The route walks the round's recorded parent
    /// instead, and the whole creator share goes to the candidate's own creator - there is no
    /// contest left to split it with.
    function test_aLosingCandidateSellsThroughTheRouterAfterTheRoundAndPaysItsCreator() public {
        Cand memory loser = _registerCandidate(address(0xB0B), "LOSER");
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);
        uint256 bought = familyRouter.buyCandidate(loser.id, 0.01 ether, 0, address(this), 8);
        assertGt(bought, 0);

        // the round fails: the loser never becomes canonical, and the head moves on afterwards
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();
        assertFalse(roundManager.isCanonical(loser.token), "the candidate lost");
        address link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.head(), link2, "and the head has moved on since");

        // THE EXIT: a supported, attributed sale of the loser, quoted in the round's own parent
        address headCreator = roundManager.creatorOf(link1);
        uint256 headCreatorBefore = vault.creatorBalance(link1);
        uint256 creatorBefore = vault.creatorBalance(loser.token);
        IERC20(loser.token).approve(address(familyRouter), type(uint256).max);
        uint256 dollBefore = doll.balanceOf(address(this));
        uint256 back = familyRouter.sellCandidate(loser.id, bought, 1, address(this), 8);
        assertGt(back, 0, "the loser sold back into the edge currency through the router");
        assertEq(doll.balanceOf(address(this)) - dollBefore, back, "delivered");

        // the edge fee it paid is attributed 100% to the loser's own creator
        uint256 edge = (back * PROTOCOL_FEE_PPM) / PPM;
        uint256 credited = vault.creatorBalance(loser.token) - creatorBefore;
        assertApproxEqRel(credited, (edge * CREATOR_BPS) / 10_000, 0.02e18, "the WHOLE creator share");
        assertEq(vault.creatorBalance(link1), headCreatorBefore, "the head's creator no longer shares it");

        vm.prank(address(0xB0B));
        assertGt(vault.claimCreator(loser.token, address(0xB0B)), 0, "and the loser's creator can claim it");
        assertTrue(headCreator != address(0xB0B));
        _assertSolvent();
    }

    function test_unknownCandidateIsRejected() public {
        vm.expectRevert(FamilyRouter.UnknownCandidate.selector);
        familyRouter.buyCandidate(99, 1 ether, 0, address(this), 8);
    }

    /// @notice The candidate entrypoints are hop-capped exactly like the canonical ones, with
    /// the candidate leg COUNTED. There is no ETH leg, so #0 -> #1 -> candidate is TWO
    /// hops: a `maxHops` of one is refused and two is accepted. Without this the candidate routes
    /// were the one way into the router with no bound on the work a call could do.
    function test_candidateRoutesAreHopCapped() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);
        assertEq(roundManager.headIndex(), 1, "one canonical leg plus the candidate leg");

        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.buyCandidate(c.id, 1 ether, 0, address(this), 1);

        uint256 out = familyRouter.buyCandidate(c.id, 1 ether, 0, address(this), 2);
        assertGt(out, 0, "two hops is exactly the route");

        IERC20(c.token).approve(address(familyRouter), type(uint256).max);
        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.sellCandidate(c.id, out / 2, 0, address(this), 1);
        assertGt(familyRouter.sellCandidate(c.id, out / 2, 0, address(this), 2), 0, "and back out again");
    }

    /// @notice {buyCandidateWithParent} is the attributed way to absorb a candidate with the HEAD
    /// tokens a round participant already holds: one hop, no edge leg, and the same 50/50
    /// creator credit the edge-in route gets. Before it existed this trade had to go through a
    /// stock third-party router and was unattributed.
    function test_buyCandidateWithParentIsAttributedAndPullsHeadTokens() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        uint256 headStock = IERC20(link1).balanceOf(address(this));
        assertGt(headStock, 0, "the participant already holds the head token");
        uint256 spend = headStock / 4;
        IERC20(link1).approve(address(familyRouter), spend);

        uint256 dollBefore = doll.balanceOf(address(this));
        uint256 candidateCreatorBefore = vault.creatorBalance(c.token);
        uint256 headCreatorBefore = vault.creatorBalance(link1);
        uint256 hopPotBefore = vault.reinforcementBalance(link1);

        uint256 out = familyRouter.buyCandidateWithParent(c.id, spend, 1, address(this));

        assertGt(out, 0, "head tokens bought the candidate");
        assertEq(IERC20(c.token).balanceOf(address(this)), out, "delivered to `to`");
        assertEq(IERC20(link1).balanceOf(address(this)), headStock - spend, "pulled by transferFrom");
        assertEq(doll.balanceOf(address(this)), dollBefore, "no edge leg at all");
        assertEq(IERC20(link1).balanceOf(address(familyRouter)), 0, "nothing stranded in the router");
        // one family-to-family hop: the parent-side hop fee is the candidate pool's reinforcement
        assertGt(vault.reinforcementBalance(link1) - hopPotBefore, 0, "the hop fee was charged");
        // and no ETH edge is crossed, so there is no protocol fee to split here
        assertEq(vault.creatorBalance(c.token), candidateCreatorBefore, "no edge fee on a non-edge hop");
        assertEq(vault.creatorBalance(link1), headCreatorBefore);
        _assertSolvent();
    }

    /// @notice ...and the attribution it carries is the CANDIDATE sentinel, which is what makes
    /// the same trade attributed when it does cross the edge: the absorption it produces is
    /// the candidate's, and the round scores it exactly as the ETH-in route's.
    function test_buyCandidateWithParentCountsTowardTheRoundScore() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart, uint64 tradingEnd,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        uint256 spend = IERC20(link1).balanceOf(address(this)) / 4;
        IERC20(link1).approve(address(familyRouter), spend);
        familyRouter.buyCandidateWithParent(c.id, spend, 1, address(this));

        _settleEnd();
        assertGt(roundManager.submitScore(c.id), 0, "the head-funded absorption was scored");
    }

    /// @notice The head-funded route follows the same window as the edge-funded one: open from
    /// the candidate's registration, refused only when the round is Idle.
    function test_buyCandidateWithParentRespectsTheTradingWindow() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (, uint64 tradingEnd,) = _roundTimes(roundManager.roundCount());
        IERC20(link1).approve(address(familyRouter), type(uint256).max);

        // during REGISTRATION the pool is already open: the route works
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration));
        assertGt(familyRouter.buyCandidateWithParent(c.id, 1e18, 0, address(this)), 0, "buyable during Registration");

        // Idle is still refused
        _mockPhase(c.id, RoundManager.Phase.Idle);
        vm.expectRevert(FamilyRouter.NotTrading.selector);
        familyRouter.buyCandidateWithParent(c.id, 1e18, 0, address(this));
        vm.clearMockedCalls();

        // After the bell the route stays open, quoted in the round's recorded parent
        _settleEnd();
        assertGt(familyRouter.buyCandidateWithParent(c.id, 1e18, 0, address(this)), 0, "still buyable");

        vm.expectRevert(FamilyRouter.UnknownCandidate.selector);
        familyRouter.buyCandidateWithParent(99, 1e18, 0, address(this));
    }
}
