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
        assertEq(r.nominalEnd - r.tradingStart, roundManager.durationFor(2), "15 minute trading window");

        // the curve starts at START_RATIO of the parent supply, in parent units
        // (within one tick spacing: the curve bounds are snapped to the pool's tick grid)
        uint256 expectedFdv = factory.startFdv(token.totalSupply());
        (uint160 sqrtP,,,) = im.getSlot0(a.poolId);
        uint256 fdv = CurveMath.fdvAtSqrtPrice(sqrtP, SUPPLY, a.tokenIsCurrency0);
        assertApproxEqRel(fdv, expectedFdv, 1e16, "start FDV = START_RATIO x parent supply");

        // registration closes on the clock
        vm.warp(r.registrationEnd);
        vm.prank(address(0xDEAD));
        vm.expectRevert(RoundManager.RegistrationClosed.selector);
        factory.registerCandidate("late", "L", "", type(uint256).max);
    }

    function test_candidatePoolIsGatedUntilTradingStart() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);

        _expectHookRevert(address(hook), IHooks.beforeSwap.selector, IFamilyHook.TradingNotStarted.selector);
        _tradeCandidate(a, true, 1e18);

        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart - 1);
        _expectHookRevert(address(hook), IHooks.beforeSwap.selector, IFamilyHook.TradingNotStarted.selector);
        _tradeCandidate(a, true, 1e18);

        vm.warp(tradingStart);
        assertGt(_tradeCandidate(a, true, 1e18), 0, "trading opens exactly at tradingStart");
    }

    /// @notice The snipe tax takes 99% -> 1% of the parent side over the first 3 seconds. Two
    /// candidates in the same round have identical curves, so the same buy at +1 s and at +4 s is
    /// a like-for-like comparison.
    function test_snipeTaxBitesAtOneSecondButNotAtFour() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
        Cand memory b = _registerCandidate(address(0xB0B), "B");
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());

        uint256 buy = 1_000e18; // small enough that price impact does not blur the comparison
        vm.warp(tradingStart + 1);
        uint256 outEarly = _tradeCandidate(a, true, buy);

        vm.warp(tradingStart + 4);
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
    /// because `finalize()` only runs after the whole submission window.
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
        (int256 avgAtEnd, uint64 attained,,) = hook.averageOver(a.poolId, tradingEnd - roundManager.closingWindowFor(2), tradingEnd);
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
        (int256 avgStill,,,) = hook.averageOver(a.poolId, tradingEnd - roundManager.closingWindowFor(2), tradingEnd);
        assertEq(avgStill, expected, "the score at T_end is reconstructed identically after a dump");
        _tradeCandidate(a, false, IERC20(a.token).balanceOf(address(this)) / 2);
        (avgStill,,,) = hook.averageOver(a.poolId, tradingEnd - roundManager.closingWindowFor(2), tradingEnd);
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

    function test_staleFinalizeIsIdempotent() public {
        Cand memory a = _registerCandidate(address(0xA11CE), "A");
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
        assertApproxEqRel(fdv, factory.startFdv(parentSupply), 1e16, "start FDV = START_RATIO x #2 supply");
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
}
