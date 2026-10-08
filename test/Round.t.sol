// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {CurveMath} from "../contracts/libraries/CurveMath.sol";
import {FamilyLens} from "../contracts/FamilyLens.sol";
import {IRandomnessSource} from "../contracts/interfaces/IRandomnessSource.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {MockDoll} from "./utils/MockDoll.sol";

/// @notice One whole succession round, end to end, plus the attacks the round design must
/// withstand: the submission-ordering attack, the post-bell dump, and a stale finalize.
contract RoundTest is RoundTestBase {
    using StateLibrary for IPoolManager;

    /// @dev ~6.1e6 head tokens absorbed: comfortably above H = 0.15% x 1e9 = 1.5e6.
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // registration
    // ---------------------------------------------------------------------------------

    function test_registrationEscrowsBondsAndOpensTheRound() public {
        // Link one is already crowned, so the chain is between rounds, not idle-at-birth
        assertEq(
            uint256(roundManager.currentPhase()),
            uint256(RoundManager.Phase.Finalized),
            "no round in flight once link one is crowned"
        );

        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        assertEq(roundManager.roundCount(), 2, "the first registration opens the next round");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration), "registration is open");

        _registerCandidate(address(0xB0B), "B");
        _registerCandidate(address(0xCA7), "C");

        assertEq(
            doll.balanceOf(address(roundManager)), 3 * roundManager.currentBond(), "three bonds escrowed in $DOLL"
        );
        RoundManager.Round memory r = roundManager.roundInfo(2);
        assertEq(r.candidateCount, 3);
        assertEq(r.parentToken, address(token), "candidates are quoted in the head");
        assertEq(r.hUsed, (token.totalSupply() * H_FRAC_WAD) / 1e18, "H is a fraction of the parent supply");
        assertEq(r.nominalEnd - r.tradingStart, roundManager.durationFor(2), "the trading window of round two");

        // the curve starts at START_RATIO of the parent supply, in parent units
        // (within one tick spacing: the curve bounds are snapped to the pool's tick grid)
        assertEq(
            factory.curveBasisOf(a.token),
            _lowerClampBasis(token.totalSupply()),
            "the basis is the parent supply at registration (lower clamp, 1000-wei floor)"
        );
        uint256 expectedFdv = factory.startFdvOf(a.token);
        assertEq(expectedFdv, factory.startFdv(token.totalSupply()), "startFdvOf agrees with startFdv");
        (uint160 sqrtP,,,) = im.getSlot0(a.poolId);
        uint256 fdv = CurveMath.fdvAtSqrtPrice(sqrtP, SUPPLY, a.tokenIsCurrency0);
        assertApproxEqRel(fdv, expectedFdv, 1e16, "start FDV = START_RATIO x parent supply");

        // registration closes on the clock
        vm.warp(r.registrationEnd);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate("late", "L", "", type(uint256).max);
    }

    /// @notice INSTANT TRADING: a candidate's pool opens at its own registration, before the
    /// round clock starts. The first block pays its own 99% snipe tax; three seconds later the
    /// same buy is untaxed.
    function test_candidatePoolTradesAtItsOwnRegistration() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        uint64 t0 = uint64(vm.getBlockTimestamp());
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        assertEq(roundManager.candidateInfo(a.id).tradingStart, t0, "the pool opens at its registration");
        assertEq(hook.poolInfo(a.poolId).tradingStart, t0, "and the hook gate agrees");
        assertLt(t0, tradingStart, "before the round clock starts");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Registration));

        uint256 buy = 1_000e18;
        uint256 outTaxed = _tradeCandidate(a, true, buy); // t + 0: 99%
        assertGt(outTaxed, 0, "trades in its registration block");

        vm.warp(t0 + 3);
        uint256 outFree = _tradeCandidate(b, true, buy); // t + 3: no tax
        assertLt(outTaxed, (outFree * 200) / 10_000, "99% of the parent side is taxed at t + 0");
        // what survives the parent side: 1 - 99% - 0.1% hop at +0, against 1 - 0.1% hop at +3
        assertApproxEqRel(outTaxed, (outFree * 9_000) / 999_000, 2e16, "the 99% tax runs from its own registration");
    }

    /// @notice The snipe tax takes 99% -> 1% of the parent side over the first 3 seconds of EACH
    /// pool's own life. B registers a minute after A; each is bought at its own +1 s and +4 s.
    /// Candidates in the same round have identical curves, so it is a like-for-like comparison.
    function test_snipeTaxBitesAtOneSecondButNotAtFour() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        uint64 startA = uint64(vm.getBlockTimestamp());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        uint256 buy = 1_000e18; // small enough that price impact does not blur the comparison
        vm.warp(startA + 1);
        uint256 outEarly = _tradeCandidate(a, true, buy);

        vm.warp(startA + 60);
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        uint64 startB = uint64(vm.getBlockTimestamp());
        assertEq(roundManager.candidateInfo(b.id).tradingStart, startB, "B's pool opens at ITS registration");

        vm.warp(startB + 4);
        uint256 outLate = _tradeCandidate(b, true, buy);

        // at +1 s the tax is 100 + 9800 * 2/3 = 6633 bps, at +4 s it is zero
        assertLt(outEarly, (outLate * 4_000) / 10_000, "the sniper keeps barely a third of the fill");
        assertApproxEqRel(outEarly, (outLate * (10_000 - 6_633)) / 10_000, 2e16, "linear 99% -> 1% decay");

        // and the tax is protocol-owned reinforcement for the parent, not a gift to the pool
        assertApproxEqRel(
            vault.reinforcementBalance(roundManager.head()),
            (buy * (663_300 + HOP_FEE_PPM)) / PPM + (buy * HOP_FEE_PPM) / PPM,
            1e16,
            "snipe tax + hop fees accrue to the vault in parent units"
        );
    }

    // ---------------------------------------------------------------------------------
    // scoring
    // ---------------------------------------------------------------------------------

    /// @notice A low score submitted first cannot exclude a better candidate,
    /// because `finalize()` only runs once EVERY candidate has submitted or the whole
    /// submission window has passed.
    function test_submitOrderingAttackCannotWin() public {
        Cand memory strong = _registerCandidate(address(0xA11CE), "STRONG");
        Cand memory weak = _registerCandidate(address(0xB0B), "WEAK");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 5);
        _tradeCandidate(strong, true, WINNING_BUY);
        _tradeCandidate(weak, true, WINNING_BUY / 10);

        // the weak candidate's creator submits first and immediately tries to close the round
        _settleEnd();
        vm.prank(address(0xB0B));
        roundManager.submitScore(weak.id);
        vm.prank(address(0xB0B));
        vm.expectRevert(RoundManager.SubmissionWindowOpen.selector);
        roundManager.finalize();

        // anyone can still submit the better candidate, right up to the end of the window
        vm.warp(submitEnd - 1);
        roundManager.submitScore(strong.id);

        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(roundManager.head(), strong.token, "the best candidate wins regardless of order");
    }

    /// @notice v3: the accumulator is never frozen - it runs forever, because the purse is ranked
    /// off it - but the ROUND's score is reconstructed at `T_end` from the checkpoint ring, so a
    /// post-bell dump moves the price and the live accumulator and still cannot move the score.
    function test_tailExtensionAndPostBellReconstruction() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 100);
        uint256 bought = _tradeCandidate(a, true, WINNING_BUY);

        // expected average as of T_end, computed from the raw accumulator before the bell
        vm.warp(tradingEnd);
        (int256 acc, int128 R, uint64 tLast) = hook.scoreState(a.poolId);
        int256 expected =
            (acc + int256(R) * int256(uint256(tradingEnd - tLast))) / int256(uint256(roundManager.durationFor(2)));
        assertEq(tLast, tradingStart + 100, "last accumulation is the last swap");
        assertApproxEqRel(
            uint256(expected),
            (WINNING_BUY * (roundManager.durationFor(2) - 100)) / roundManager.durationFor(2),
            2e16,
            "tail extension over the window less the 100 s before the buy"
        );
        // the window {RoundManager.submitScore} scores, `max(T_end - W, r.tradingStart)`: on a
        // ten-minute round W > D, so it is the whole of trading
        uint64 from = tradingEnd - roundManager.closingWindowFor(2);
        if (from < tradingStart) from = tradingStart;
        (int256 avgAtEnd, uint64 attained,,) = hook.averageOver(a.poolId, from, tradingEnd);
        assertEq(avgAtEnd, expected, "averageOver reproduces the tail extension exactly");
        assertEq(attained, tradingStart + 100, "tFirstAttained is the last update before T_end");

        // a post-bell dump: half the position sold after the bell
        _settleEnd();
        vm.warp(block.timestamp + 10);
        _tradeCandidate(a, false, bought / 2);
        (int256 accAfter,, uint64 tLastAfter) = hook.scoreState(a.poolId);
        assertGt(tLastAfter, tradingEnd, "the accumulator kept running past the bell");
        assertTrue(accAfter != acc, "and it really moved");

        // ...and the reconstruction at T_end is unchanged by either dump
        (int256 avgStill,,,) = hook.averageOver(a.poolId, from, tradingEnd);
        assertEq(avgStill, expected, "the score at T_end is reconstructed identically after a dump");
        _tradeCandidate(a, false, IERC20(a.token).balanceOf(address(this)) / 2);
        (avgStill,,,) = hook.averageOver(a.poolId, from, tradingEnd);
        assertEq(avgStill, expected, "and after a second one");

        roundManager.submitScore(a.id);
        RoundManager.Candidate memory c = roundManager.candidateInfo(a.id);
        assertEq(c.avg, expected, "the submitted average is the pre-dump snapshot");

        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(roundManager.head(), a.token, "the dumper still wins: the score was earned");
    }

    // ---------------------------------------------------------------------------------
    // finalization
    // ---------------------------------------------------------------------------------

    function test_finalizeCrownsWinnerRefundsBondAndForfeitsLosers() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        _registerCandidate(address(0xB0B), "B");
        _registerCandidate(address(0xCA7), "C");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(a.id);
        roundManager.submitScore(cands[1].id);
        roundManager.submitScore(cands[2].id);

        uint256 bond = roundManager.currentBond();
        uint256 vaultBefore = vault.edgeBidEarmark();
        vm.warp(submitEnd);
        roundManager.finalize();

        assertEq(roundManager.head(), a.token, "head changed");
        assertEq(roundManager.headIndex(), 2, "index incremented");
        assertEq(roundManager.canonical(2), a.token, "canonical history recorded");
        assertEq(roundManager.indexOf(a.token), 2);
        assertEq(roundManager.parentOf(a.token), address(token), "parent is the previous head");
        assertEq(doll.balanceOf(address(0xA11CE)), bond, "winner bond refunded in $DOLL");
        assertEq(vault.edgeBidEarmark() - vaultBefore, 2 * bond, "losing bonds earmarked as an edge bid");
        assertEq(doll.balanceOf(address(roundManager)), 0, "no bond left in escrow");
        assertEq(roundManager.hWad(), H_FRAC_WAD, "a successful round does not decay H");
    }

    /// @notice EARLY FINALIZE. With every candidate's score in there is nothing left a finalize
    /// could exclude, so the round closes at once instead of waiting for `submitEnd`; with one
    /// score missing it reverts right up to `submitEnd`, which stays the deadline.
    function test_finalizeAsSoonAsAllScoresAreIn() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);
        _tradeCandidate(b, true, WINNING_BUY / 10);
        (, uint64 submitEnd) = _settleEnd();
        uint256 roundId = roundManager.roundCount();

        // one score in, one missing: the window still guards the missing one
        roundManager.submitScore(b.id);
        assertEq(roundManager.submittedCount(roundId), 1, "one of two");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Submission), "still submitting");
        vm.expectRevert(RoundManager.SubmissionWindowOpen.selector);
        roundManager.finalize();

        // the second score lands: the round is finalizable now, well before submitEnd
        roundManager.submitScore(a.id);
        roundManager.submitScore(a.id); // a re-submission is a no-op and does not count twice
        assertEq(roundManager.submittedCount(roundId), 2, "two of two, counted once each");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Finalizable), "finalizable early");
        assertLt(block.timestamp, submitEnd, "before the deadline");
        roundManager.finalize();
        assertEq(roundManager.head(), a.token, "the best candidate wins");
        assertEq(uint256(roundManager.currentPhase()), uint256(RoundManager.Phase.Finalized));
    }

    /// @notice ...and the missing score keeps the round open until `submitEnd`, not a second longer.
    function test_aMissingScoreHoldsFinalizeUntilSubmitEnd() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);
        (, uint64 submitEnd) = _settleEnd();
        roundManager.submitScore(a.id);

        vm.warp(submitEnd - 1);
        vm.expectRevert(RoundManager.SubmissionWindowOpen.selector);
        roundManager.finalize();

        vm.warp(submitEnd);
        roundManager.finalize();
        assertEq(roundManager.head(), a.token, "the deadline path still crowns");
    }

    function test_staleFinalizeIsIdempotent() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        // a second candidate that never submits keeps the round on the submitEnd path
        _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());

        vm.warp(tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(a.id);

        vm.warp(submitEnd - 1);
        vm.expectRevert(RoundManager.SubmissionWindowOpen.selector);
        roundManager.finalize();

        vm.warp(submitEnd);
        roundManager.finalize();
        uint256 headIndex = roundManager.headIndex();
        uint256 balance = doll.balanceOf(address(0xA11CE));

        // stale calls, days later, change nothing
        roundManager.finalize();
        vm.warp(submitEnd + 7 days);
        roundManager.finalize();
        assertEq(roundManager.headIndex(), headIndex, "index unchanged");
        assertEq(doll.balanceOf(address(0xA11CE)), balance, "no second refund");

        // and a submission after the window is refused
        vm.expectRevert(RoundManager.OutsideSubmissionWindow.selector);
        roundManager.submitScore(a.id);
    }

    /// @notice No candidate clears H: the threshold decays x0.9 per failed round, and stops at
    /// the floor. All bonds are forfeited.
    function test_noWinnerDecaysThresholdToTheFloor() public {
        uint256 expected = H_FRAC_WAD;
        for (uint256 i = 0; i < 16; i++) {
            _registerCandidate(address(uint160(0xF00D00 + i)), "F");
            (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
            _settleEnd();
            vm.warp(submitEnd);
            roundManager.finalize();

            expected = (expected * 9) / 10;
            if (expected < H_MIN_FRAC_WAD) expected = H_MIN_FRAC_WAD;
            assertEq(roundManager.hWad(), expected, "H decays x0.9 down to the floor");
            assertEq(roundManager.headIndex(), 1, "no winner, no head change");
        }
        assertEq(roundManager.hWad(), H_MIN_FRAC_WAD, "the decay stops at H_MIN");
        assertEq(vault.edgeBidEarmark(), 16 * roundManager.currentBond(), "every bond forfeited");
    }

    // ---------------------------------------------------------------------------------
    // the next round, against the new head
    // ---------------------------------------------------------------------------------

    function test_secondRoundIsQuotedInTheNewHead() public {
        Cand memory first = _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.head(), first.token, "round 2 crowned #2");

        // #2's supply is the numeraire now
        Cand memory second = _registerCandidate(address(0xBEEF), "SECOND");
        RoundManager.Round memory r = roundManager.roundInfo(3);
        assertEq(r.parentToken, first.token, "quoted in #2");
        assertEq(r.parentIndex, 2);

        address c0 = Currency.unwrap(second.key.currency0);
        address c1 = Currency.unwrap(second.key.currency1);
        assertTrue(
            (c0 == second.token && c1 == first.token) || (c1 == second.token && c0 == first.token),
            "the pool pairs the candidate against #2"
        );

        uint256 parentSupply = IERC20(first.token).totalSupply();
        (uint160 sqrtP,,,) = im.getSlot0(second.poolId);
        uint256 fdv = CurveMath.fdvAtSqrtPrice(sqrtP, FamilyToken(second.token).TOTAL_SUPPLY(), second.tokenIsCurrency0);
        assertEq(
            factory.curveBasisOf(second.token), _lowerClampBasis(parentSupply), "the basis is #2's supply at registration"
        );
        assertApproxEqRel(fdv, factory.startFdvOf(second.token), 1e16, "start FDV = START_RATIO x #2 supply");
        assertEq(r.hUsed, (parentSupply * H_FRAC_WAD) / 1e18, "H re-based on #2's supply");
    }

    /// @notice The 1% protocol fee is charged on the $DOLL edge only. A routed buy through two
    /// links pays it once, on the link-one (edge) leg, and pays the hop fee on both legs.
    function test_routedBuyChargesProtocolFeeOnlyOnTheEdgeLeg() public {
        Cand memory first = _runWinningRound(1, WINNING_BUY);
        PoolId edgeId = roundManager.poolIdOf(1);
        PoolId childId = roundManager.poolIdOf(2);

        vm.recordLogs();
        familyRouter.buyExactIn(2, 1 ether, 0, address(this), 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != IFamilyHook.FeeAccrued.selector) continue;
            (uint256 hopFee, uint256 protocolFee, uint256 attribution) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            PoolId id = PoolId.wrap(logs[i].topics[1]);
            assertGt(hopFee, 0, "every family swap pays the hop fee");
            assertEq(attribution, 2, "the router attributes the fee to the terminal token");
            if (PoolId.unwrap(id) == PoolId.unwrap(edgeId)) {
                assertEq(protocolFee, 1 ether / 100, "1% on the $DOLL edge");
            } else {
                assertEq(PoolId.unwrap(id), PoolId.unwrap(childId), "only the two canonical legs");
                assertEq(protocolFee, 0, "no protocol fee on a family<->family hop");
            }
            seen++;
        }
        assertEq(seen, 2, "exactly two legs");
        assertGt(IERC20(first.token).balanceOf(address(this)), 0, "the buyer received #2");
    }

    /// @notice The lens: a paginated round view and the canonical chain view.
    function test_lensViews() public {
        _registerCandidate(address(0xA11CE), "A");
        _registerCandidate(address(0xB0B), "B");
        _registerCandidate(address(0xCA7), "C");

        (FamilyLens.RoundView memory rv, FamilyLens.CandidateView[] memory page) = lens.roundView(2, 1, 2);
        assertEq(uint256(rv.phase), uint256(RoundManager.Phase.Registration));
        assertEq(rv.candidateCount, 3, "three candidates");
        assertEq(rv.parentToken, address(token));
        assertEq(page.length, 2, "paginated: offset 1, limit 2");
        // candidate ids run across the whole chain, and round one already consumed id 0
        assertEq(page[0].candidateId, 2);
        assertEq(page[0].creator, address(0xB0B));
        assertGt(page[0].spotSqrtPriceX96, 0, "candidate pool is priced");
        assertEq(page[0].tokensSold, 0, "nothing sold before trading opens");

        (, FamilyLens.CandidateView[] memory tail) = lens.roundView(2, 5, 10);
        assertEq(tail.length, 0, "offset past the end is empty");

        // The lens reads the registry's PAGINATED overload, so its cost tracks the page
        // and not the number of candidates in the round. The page it returns is exactly the
        // registry's page, id for id, including a limit that runs past the end.
        (uint256[] memory ids, uint256 total) = roundManager.candidateIds(2, 1, 2);
        assertEq(total, 3, "the registry reports the full count");
        assertEq(page.length, ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(page[i].candidateId, ids[i], "the lens page is the registry page");
        }
        (, FamilyLens.CandidateView[] memory over) = lens.roundView(2, 2, 10);
        (uint256[] memory idsOver,) = roundManager.candidateIds(2, 2, 10);
        assertEq(over.length, idsOver.length, "a limit past the end is clamped the same way");
        assertEq(over[0].candidateId, idsOver[0]);

        FamilyLens.LinkView[] memory links = lens.chainView(0, 5);
        assertEq(links.length, 2, "the adopted genesis and link one are canonical so far");
        assertEq(links[0].token, address(doll), "index 0 is the adopted token");
        assertEq(links[0].parent, address(0), "the adopted genesis has no parent");
        assertFalse(links[0].hasPool, "and no pool of ours");
        assertEq(links[0].parentReserve, 0, "so no reserves to report");
        assertEq(links[1].token, address(token), "link one is the edge pool");
        assertEq(links[1].parent, address(doll), "whose parent is the adopted genesis");
        assertTrue(links[1].hasPool);
        assertGt(links[1].parentReserve, 0, "link one's pool holds $DOLL");
        assertGt(links[1].liquidity, 0);
    }

    // ---------------------------------------------------------------------------------
    // gas
    // ---------------------------------------------------------------------------------

    function test_gas_roundLifecycle() public {
        // the bond is posted in $DOLL now, so the registrant has to be funded and approved. The
        // bond is read BEFORE the prank: an external call in the argument list would consume it.
        uint256 bond = roundManager.currentBond();
        _fundDoll(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        doll.approve(address(factory), bond);
        vm.prank(address(0xA11CE));
        uint256 g = gasleft();
        (,, uint256 id) = factory.registerCandidate("A", "A", "", type(uint256).max);
        emit log_named_uint("registerCandidate gas", g - gasleft());

        Cand memory a = Cand({
            token: address(0),
            key: roundManager.candidateInfo(id).key,
            poolId: roundManager.candidateInfo(id).key.toId(),
            id: id,
            tokenIsCurrency0: Currency.unwrap(roundManager.candidateInfo(id).key.currency0)
                == roundManager.candidateInfo(id).token,
            creator: address(0xA11CE)
        });
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 5);
        _tradeCandidate(a, true, WINNING_BUY);

        _settleEnd();
        g = gasleft();
        roundManager.submitScore(id);
        emit log_named_uint("submitScore gas", g - gasleft());

        vm.warp(submitEnd);
        g = gasleft();
        roundManager.finalize();
        emit log_named_uint("finalize gas", g - gasleft());

        g = gasleft();
        familyRouter.buyExactIn(2, 1 ether, 0, address(this), 4);
        emit log_named_uint("routed buy, 2 links ($DOLL -> #1 -> #2) gas", g - gasleft());
    }

    /// @notice The candidate list is PAGINATED. A round can be spammed with candidates for
    /// the price of the bond, and an indexer that can only ask for the whole array would sooner
    /// or later exceed the gas limit of an `eth_call`.
    function test_candidateIdsArePaginated() public {
        for (uint256 i = 0; i < 5; i++) {
            _registerCandidate(address(uint160(0xC0DE00 + i)), "C");
        }
        uint256[] memory all = roundManager.candidateIds(2);
        assertEq(all.length, 5, "the unpaginated view still answers for a small round");

        (uint256[] memory page, uint256 total) = roundManager.candidateIds(2, 0, 2);
        assertEq(total, 5, "the total is reported with every page");
        assertEq(page.length, 2);
        assertEq(page[0], all[0]);
        assertEq(page[1], all[1]);

        (page, total) = roundManager.candidateIds(2, 4, 10);
        assertEq(page.length, 1, "the last page is short, not padded");
        assertEq(page[0], all[4]);

        (page, total) = roundManager.candidateIds(2, 5, 10);
        assertEq(page.length, 0, "an offset past the end is empty, not a revert");
        assertEq(total, 5);

        (page,) = roundManager.candidateIds(3, 0, 10);
        assertEq(page.length, 0, "and so is a round that does not exist");
    }

    // ---------------------------------------------------------------------------------
    // The end-request guard is a flag, not a non-zero beacon id
    // ---------------------------------------------------------------------------------

    function test_theEndCannotBeRequestedTwice() public {
        _openRoundAtNominalEnd();
        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    /// @notice A source that hands back `bytes32(0)` does not disarm the once-per-round guard,
    /// because the guard is its own flag, not the id itself. `DrandSource.pin()` returns
    /// `bytes32(round)`, so this would need beacon round 0 - but the guard holds either way.
    function test_aZeroRequestIdStillClosesTheRound() public {
        uint256 roundId = _openRoundAtNominalEnd();

        vm.mockCall(
            address(randomness), abi.encodeWithSelector(IRandomnessSource.pin.selector), abi.encode(bytes32(0))
        );
        bytes32 id = roundManager.requestEnd();
        assertEq(id, bytes32(0), "the source really returned a zero id");

        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertTrue(r.endRequested, "the request is recorded by its own flag");
        assertEq(r.randomId, bytes32(0), "and the id carries no 'unset' meaning");

        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    // ---------------------------------------------------------------------------------
    // A round with no score says so
    // ---------------------------------------------------------------------------------

    /// @notice A denied submission must be legible after the fact: a round that finalizes with no
    /// score at all says so on chain.
    function test_aRoundWithNoSubmittedScoreSaysSo() public {
        _registerCandidate(address(0xA11CE), "A");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);

        vm.recordLogs();
        roundManager.finalize();
        assertTrue(_sawNoScoreSubmitted(2), "finalize reports that no score was ever submitted");
    }

    function _sawNoScoreSubmitted(uint256 roundId) internal returns (bool) {
        bytes32 sig = keccak256("NoScoreSubmitted(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(roundManager) || logs[i].topics[0] != sig) continue;
            if (uint256(logs[i].topics[1]) == roundId) return true;
        }
        return false;
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

/// @notice The external genesis is ADOPTED, once, inside {FamilyFactory.wire}. `adoptGenesis` keeps
/// a dedicated `_genesisAdopted` flag and refuses `address(0)` explicitly, so a zero adoption can
/// never leave the write-once flag unset and let a second call re-seat canonical index 0, the
/// head and the edge currency.
contract GenesisAdoptionTest is RoundTestBase {
    function setUp() public {
        _setUpFamily();
    }

    /// @notice Adoption happens inside {FamilyFactory.wire}, exactly once, and the
    /// creator of record is the DEPLOYER whoever sends the wiring transaction. The entry it
    /// wrote is the registry entry of index 0.
    function test_adoptionHappensOnceInsideWiringAndCreditsTheDeployer() public {
        assertTrue(factory.genesisAdopted(), "set up wires, and wiring adopts");
        assertEq(roundManager.canonical(0), address(doll), "canonical 0 is the adopted token");
        assertEq(roundManager.head(), address(doll), "and it is the first head");
        assertEq(roundManager.headIndex(), 0);
        assertEq(roundManager.parentOf(address(doll)), address(0), "index 0 has no parent");
        assertEq(factory.DEPLOYER(), address(this), "the factory records who deployed it");
        assertEq(roundManager.creatorOf(address(doll)), address(this), "the deployer is the creator of record");

        // wiring again is a no-op, from anybody: there is no second adoption to race for
        factory.wire();
        vm.prank(address(0xA11CE));
        factory.wire();
        assertEq(roundManager.creatorOf(address(doll)), address(this), "and nobody else can take it");

        // and the RoundManager refuses a second entry even from the factory
        vm.prank(address(factory));
        vm.expectRevert();
        roundManager.adoptGenesis(address(0xDEAD), address(this));
    }

    /// @notice A third party who wires the stack first cannot become the creator of
    /// canonical index 0. The attribution is fixed at construction, not at the call.
    function test_wiringByAStrangerStillCreditsTheDeployer() public {
        maxIndex = 0;
        Stack memory s = _deployStack(true, steward, address(0));
        assertFalse(s.factory.genesisAdopted(), "a fresh stack is not wired yet");

        vm.prank(address(0xBAD));
        s.factory.wire();

        assertTrue(s.factory.genesisAdopted());
        assertEq(s.factory.genesisCreator(), address(this), "the deployer, not the caller");
        assertEq(s.roundManager.creatorOf(address(doll)), address(this));
        assertEq(s.roundManager.canonical(0), address(doll));
    }

    /// @notice A token with the wrong decimals is refused at adoption, so a stack quoted in a
    /// 6-decimal unit can never come into existence.
    function test_adoptionRefusesNonEighteenDecimals() public {
        // a whole second world: a six-decimal mock at the same fixed address
        MockDoll six = new MockDoll(6);
        vm.etch(DOLL_ADDRESS, address(six).code);
        MockDoll bad = MockDoll(DOLL_ADDRESS);
        bad.mint(address(this), 1e6);
        assertEq(bad.decimals(), 6, "the etched token is six-decimal");

        Stack memory s = _deployStack(true, steward, address(0));
        vm.expectRevert(FamilyFactory.BadGenesisToken.selector);
        s.factory.wire();
    }

    /// @notice The zero-address path: called directly as the factory (bypassing
    /// the factory's own zero/codeless guard, which is what makes it latent rather than live), it
    /// must revert rather than seat the sentinel. A second, unwired stack is used because the
    /// fixture's own trunk is already adopted by {setUp}.
    function test_adoptGenesisRefusesTheZeroAddress() public {
        Stack memory s2 = _deployStack(false, steward, address(0));

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.BadGenesisToken.selector);
        s2.roundManager.adoptGenesis(address(0), address(this));
    }

    /// @notice A second adoption reverts after the first, with the dedicated flag - not by
    /// coincidentally re-reading a token field as a sentinel.
    function test_adoptGenesisRevertsOnASecondCall() public {
        // this stack's genesis was already adopted in setUp() via factory.wire()
        vm.prank(address(factory));
        vm.expectRevert(RoundManager.GenesisAlreadyAdopted.selector);
        roundManager.adoptGenesis(address(0xBEEF), address(this));
    }

    /// @notice Attempt to adopt `address(0)` first. That attempt itself reverts and leaves the flag unset, so pin that a real adoption
    /// can still happen exactly once afterwards, and that a further attempt then hits the
    /// dedicated flag rather than re-seating canonical index 0.
    function test_zeroAddressAdoptionCannotBeFollowedByARealOne() public {
        Stack memory s2 = _deployStack(false, steward, address(0));

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.BadGenesisToken.selector);
        s2.roundManager.adoptGenesis(address(0), address(this));

        // the flag was never set by the reverted call, and priorRegistry is still zero, so a real
        // adoption succeeds - exactly once
        vm.prank(address(s2.factory));
        s2.roundManager.adoptGenesis(address(doll), address(this));
        assertEq(s2.roundManager.canonical(0), address(doll), "the real token seated once");

        vm.prank(address(s2.factory));
        vm.expectRevert(RoundManager.GenesisAlreadyAdopted.selector);
        s2.roundManager.adoptGenesis(address(0xCAFE), address(this));
        assertEq(s2.roundManager.canonical(0), address(doll), "index 0 was not re-seated");
    }

    /// @notice The production path: the factory adopts exactly once inside {wire}, and calling it
    /// again from anybody is a no-op, not a second adoption.
    function test_factoryPathStillAdoptsExactlyOnce() public {
        assertTrue(factory.genesisAdopted(), "set up wires, and wiring adopts");
        assertEq(roundManager.canonical(0), address(doll));
        assertEq(roundManager.head(), address(doll));
        assertEq(roundManager.headIndex(), 0);

        factory.wire();
        vm.prank(address(0xA11CE));
        factory.wire();

        assertEq(roundManager.canonical(0), address(doll), "still the same token at index 0");
        assertEq(roundManager.head(), address(doll), "still the same head");
        assertEq(roundManager.headIndex(), 0, "still index 0");
    }
}
