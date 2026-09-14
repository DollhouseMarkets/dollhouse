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

/// @notice Router hardening: value accounting (M1), candidate routes and their attribution (M4),
/// residual settlement across a route (M5), and the round-trip delta read order (L12).
contract RouterGuardsTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link1;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        IERC20(address(token)).approve(address(familyRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // M1: value accounting
    // ---------------------------------------------------------------------------------

    /// @notice An ETH route must be funded by its own `msg.value`, exactly.
    function test_swapPathRequiresMatchingValueOnAnEthRoute() public {
        uint256[] memory path = new uint256[](2);
        path[0] = familyRouter.ETH();
        path[1] = 0;

        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, 0, 1 ether));
        familyRouter.swapPath(path, 1 ether, 0, address(this), 1);

        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, 0.5 ether, 1 ether));
        familyRouter.swapPath{value: 0.5 ether}(path, 1 ether, 0, address(this), 1);

        assertGt(familyRouter.swapPath{value: 1 ether}(path, 1 ether, 0, address(this), 1), 0, "matched value works");
    }

    /// @notice A token route must carry no ETH at all.
    function test_swapPathRejectsValueOnATokenRoute() public {
        uint256[] memory path = new uint256[](2);
        path[0] = 1;
        path[1] = 0;
        uint256 amount = IERC20(link1).balanceOf(address(this)) / 10;

        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, 1 ether, 0));
        familyRouter.swapPath{value: 1 ether}(path, amount, 0, address(this), 1);
    }

    /// @notice M1: ETH that somehow ends up at the router cannot be swept by anybody. There is no
    /// `receive()`, so it cannot even be sent in the ordinary way, and a route can never spend
    /// more than its own `msg.value`.
    function test_routerHeldEthCannotBeSwept() public {
        // a plain transfer is refused outright now
        (bool sent,) = address(familyRouter).call{value: 1 ether}("");
        assertFalse(sent, "the router has no receive()");

        // force ETH in anyway (as a selfdestruct or a coinbase payout would)
        vm.deal(address(familyRouter), 5 ether);
        assertEq(address(familyRouter).balance, 5 ether);

        uint256[] memory path = new uint256[](2);
        path[0] = familyRouter.ETH();
        path[1] = 0;
        // claiming to spend the stranded ETH without sending any is refused...
        vm.expectRevert(abi.encodeWithSelector(FamilyRouter.WrongValue.selector, 0, 5 ether));
        familyRouter.swapPath(path, 5 ether, 0, address(0xBEEF), 1);

        // ...and a legitimate route leaves the stranded balance exactly where it was
        uint256 before = address(this).balance;
        familyRouter.swapPath{value: 1 ether}(path, 1 ether, 0, address(this), 1);
        assertEq(address(familyRouter).balance, 5 ether, "the stranded ETH is untouched");
        assertEq(before - address(this).balance, 1 ether, "the caller spent only its own ETH");
    }

    // ---------------------------------------------------------------------------------
    // L12: round trips
    // ---------------------------------------------------------------------------------

    /// @notice A route whose first and last currency are the SAME must still report its output:
    /// reading the output delta after settling the input would report zero.
    function test_roundTripPathReportsItsOutput() public {
        uint256 amount = IERC20(address(token)).balanceOf(address(this)) / 10;
        uint256[] memory path = new uint256[](3);
        path[0] = 0;
        path[1] = 1;
        path[2] = 0;

        uint256 before = IERC20(address(token)).balanceOf(address(this));
        uint256 out = familyRouter.swapPath(path, amount, 0, address(this), 2);
        uint256 after_ = IERC20(address(token)).balanceOf(address(this));

        assertGt(out, 0, "the round trip reports what came back, not zero");
        assertEq(after_, before - amount + out, "settled NET, at exactly the reported output");
        assertLt(out, amount, "and a round trip still loses the fees");

        // slippage protection works on a round trip too, which it could not if the reported
        // output were zero
        vm.expectRevert();
        familyRouter.swapPath(path, amount, amount, address(this), 2);
    }

    // ---------------------------------------------------------------------------------
    // M5: residual settlement
    // ---------------------------------------------------------------------------------

    /// @notice A partially filled route settles every currency it touched: the caller is
    /// refunded, `to` holds the output plus any intermediate residue, and the router keeps
    /// nothing in any currency.
    function test_midRoutePartialFillSettlesEveryCurrency() public {
        address to = address(0xD00D);
        uint256 huge = 20_000 ether;
        vm.deal(address(this), huge + 1 ether);

        uint256 before = address(this).balance;
        uint256 out = familyRouter.buyExactIn{value: huge}(1, 0, to, 2);
        uint256 spent = before - address(this).balance;

        assertLt(spent, huge, "the unfillable remainder was refunded (partial first leg)");
        assertGt(out, 0, "the fillable part was delivered");
        assertEq(IERC20(link1).balanceOf(to), out, "the terminal token went to `to`");
        assertEq(address(familyRouter).balance, 0, "no ETH stranded");
        assertEq(IERC20(address(token)).balanceOf(address(familyRouter)), 0, "no intermediate stranded");
        assertEq(IERC20(link1).balanceOf(address(familyRouter)), 0, "no output stranded");
        // any intermediate residue is swept to `to`, never left in the router
        assertEq(
            IERC20(address(token)).balanceOf(to) + IERC20(address(token)).balanceOf(address(familyRouter)),
            IERC20(address(token)).balanceOf(to),
            "residue belongs to `to`"
        );
    }

    // ---------------------------------------------------------------------------------
    // M4: candidate routes
    // ---------------------------------------------------------------------------------

    function test_buyAndSellCandidateWithEth() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart, uint64 tradingEnd,) = _roundTimes(roundManager.roundCount());

        // refused outside Trading
        vm.expectRevert(FamilyRouter.NotTrading.selector);
        familyRouter.buyCandidate{value: 1 ether}(c.id, 0, address(this), 8);

        vm.warp(tradingStart + 10);
        uint256 out = familyRouter.buyCandidate{value: 1 ether}(c.id, 1, address(this), 8);
        assertGt(out, 0, "ETH bought the candidate through the whole chain");
        assertEq(IERC20(c.token).balanceOf(address(this)), out, "delivered");
        assertEq(address(familyRouter).balance, 0, "nothing stranded");

        IERC20(c.token).approve(address(familyRouter), type(uint256).max);
        uint256 ethBefore = address(this).balance;
        uint256 back = familyRouter.sellCandidate(c.id, out / 2, 1, address(this), 8);
        assertGt(back, 0, "sold back into ETH");
        assertEq(address(this).balance - ethBefore, back, "ETH delivered to `to`");

        // AUDIT 8: after the bell the route keeps working - through the index the ROUND recorded
        // as its parent, not through whatever the head has become since
        _settleEnd();
        assertGt(familyRouter.buyCandidate{value: 1 ether}(c.id, 1, address(this), 8), 0, "still buyable");
    }

    /// @notice The ETH-edge fee on a candidate buy is credited through the sentinel attribution
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
        familyRouter.buyCandidate{value: 1 ether}(c.id, 0, address(this), 8);

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
        assertEq(vault.claimCreator(link1, headCreator), toHead, "so is the head creator's half");
        _assertSolvent();
    }

    /// @notice A canonical-link buy pays the WHOLE creator share to that link's own creator: the
    /// 50/50 rule is a candidate-trade rule only.
    function test_canonicalBuyPaysTheWholeCreatorShareToThatLinksCreator() public {
        uint256 before = vault.creatorBalance(link1);
        uint256 genesisBefore = vault.creatorBalance(address(token));
        familyRouter.buyExactIn{value: 1 ether}(1, 0, address(this), 2);
        assertEq(
            vault.creatorBalance(link1) - before,
            ((1 ether / 100) * CREATOR_BPS) / 10_000,
            "#1's creator takes all of it"
        );
        assertEq(vault.creatorBalance(address(token)), genesisBefore, "and nobody else is credited");
    }

    /// @notice The head-creator half is credited per TRADE, not per outcome: a candidate that
    /// goes on to LOSE the round still leaves its creator holding their half, claimable forever.
    function test_losingCandidateCreatorKeepsTheirHalf() public {
        Cand memory loser = _registerCandidate(address(0xB0B), "LOSER");
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        // small enough that the candidate's absorption cannot clear H over the trading window
        uint256 buy = 0.01 ether;
        vm.warp(tradingStart + 10);
        familyRouter.buyCandidate{value: buy}(loser.id, 0, address(this), 8);

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

    /// @notice AUDIT 8 - THE LOSER'S EXIT. When a round ends, a losing candidate's holders used to
    /// lose both their supported route (the router walked the CURRENT head, which is now a
    /// different token) and their creator's fee stream: the only way out was an unattributed
    /// third-party swap. The route now walks the round's recorded parent, and the whole creator
    /// share goes to the candidate's own creator - there is no contest left to split it with.
    function test_aLosingCandidateSellsThroughTheRouterAfterTheRoundAndPaysItsCreator() public {
        Cand memory loser = _registerCandidate(address(0xB0B), "LOSER");
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);
        uint256 bought = familyRouter.buyCandidate{value: 0.01 ether}(loser.id, 0, address(this), 8);
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
        uint256 ethBefore = address(this).balance;
        uint256 back = familyRouter.sellCandidate(loser.id, bought, 1, address(this), 8);
        assertGt(back, 0, "the loser sold back into ETH through the router");
        assertEq(address(this).balance - ethBefore, back, "ETH delivered");

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
        familyRouter.buyCandidate{value: 1 ether}(99, 0, address(this), 8);
    }

    /// @notice The candidate entrypoints are hop-capped exactly like the canonical ones, with
    /// the candidate leg COUNTED: ETH -> #0 -> #1 -> candidate is three hops, so a `maxHops` of
    /// two is refused and three is accepted. Without this the candidate routes were the one way
    /// into the router with no bound on the work a call could do.
    function test_candidateRoutesAreHopCapped() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);
        assertEq(roundManager.headIndex(), 1, "ETH + two canonical legs + the candidate leg");

        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.buyCandidate{value: 1 ether}(c.id, 0, address(this), 2);

        uint256 out = familyRouter.buyCandidate{value: 1 ether}(c.id, 0, address(this), 3);
        assertGt(out, 0, "three hops is exactly the route");

        IERC20(c.token).approve(address(familyRouter), type(uint256).max);
        vm.expectRevert(FamilyRouter.TooManyHops.selector);
        familyRouter.sellCandidate(c.id, out / 2, 0, address(this), 2);
        assertGt(familyRouter.sellCandidate(c.id, out / 2, 0, address(this), 3), 0, "and back out again");
    }

    /// @notice {buyCandidateWithParent} is the attributed way to absorb a candidate with the HEAD
    /// tokens a round participant already holds: one hop, no ETH, and the same 50/50 creator
    /// credit the ETH-in route gets. Before it existed this trade had to go through a stock
    /// third-party router and was unattributed.
    function test_buyCandidateWithParentIsAttributedAndPullsHeadTokens() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        uint256 headStock = IERC20(link1).balanceOf(address(this));
        assertGt(headStock, 0, "the participant already holds the head token");
        uint256 spend = headStock / 4;
        IERC20(link1).approve(address(familyRouter), spend);

        uint256 ethBefore = address(this).balance;
        uint256 candidateCreatorBefore = vault.creatorBalance(c.token);
        uint256 headCreatorBefore = vault.creatorBalance(link1);
        uint256 hopPotBefore = vault.reinforcementBalance(link1);

        uint256 out = familyRouter.buyCandidateWithParent(c.id, spend, 1, address(this));

        assertGt(out, 0, "head tokens bought the candidate");
        assertEq(IERC20(c.token).balanceOf(address(this)), out, "delivered to `to`");
        assertEq(IERC20(link1).balanceOf(address(this)), headStock - spend, "pulled by transferFrom");
        assertEq(address(this).balance, ethBefore, "no ETH leg at all");
        assertEq(IERC20(link1).balanceOf(address(familyRouter)), 0, "nothing stranded in the router");
        // one family-to-family hop: the parent-side hop fee is the candidate pool's reinforcement
        assertGt(vault.reinforcementBalance(link1) - hopPotBefore, 0, "the hop fee was charged");
        // and no ETH edge is crossed, so there is no protocol fee to split here
        assertEq(vault.creatorBalance(c.token), candidateCreatorBefore, "no ETH-edge fee on a family hop");
        assertEq(vault.creatorBalance(link1), headCreatorBefore);
        _assertSolvent();
    }

    /// @notice ...and the attribution it carries is the CANDIDATE sentinel, which is what makes
    /// the same trade attributed when it does cross the ETH edge: the absorption it produces is
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

    /// @notice The head-funded route is refused outside the trading window, exactly like the
    /// ETH-funded one.
    function test_buyCandidateWithParentRespectsTheTradingWindow() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "CAND");
        (, uint64 tradingEnd,) = _roundTimes(roundManager.roundCount());
        IERC20(link1).approve(address(familyRouter), type(uint256).max);

        // during REGISTRATION the pool exists but its hook gate is shut: still refused
        vm.expectRevert(FamilyRouter.NotTrading.selector);
        familyRouter.buyCandidateWithParent(c.id, 1e18, 0, address(this));

        // AUDIT 8: after the bell the route stays open, quoted in the round's recorded parent
        _settleEnd();
        assertGt(familyRouter.buyCandidateWithParent(c.id, 1e18, 0, address(this)), 0, "still buyable");

        vm.expectRevert(FamilyRouter.UnknownCandidate.selector);
        familyRouter.buyCandidateWithParent(99, 1e18, 0, address(this));
    }
}
