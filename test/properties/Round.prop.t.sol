// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Property tests for the round lifecycle (docs/spec/PROPERTIES.md sec.3.5), tier F.
/// The stack under test runs at `DURATION_SCALE_DIV == 1`, i.e. the published schedule.
contract RoundPropTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // the schedule
    // ---------------------------------------------------------------------------------

    /// @notice The whole round `L(n) = min(10 min * 2^floor((n-1)/2), 12 h)`,
    /// `registrationFor(n) = clamp(L(n)/5, 3 min, 1 h)/DURATION_SCALE_DIV`,
    /// `durationFor(n) = (L(n) - R(n))/DURATION_SCALE_DIV`, `lateEntryUntil(n) = D(n)/3` iff the
    /// unscaled `D(n) >= 1 h` else 0, `closingWindowFor(n) = CLOSING_WINDOW_S` (a flat 15 min),
    /// `randomEndWindowFor(n) = max(1, min(180 s, D(n)/4))` - each a pure function of `n` alone.
    function testFuzz_RND01_scheduleIsAPureFunctionOfTheRoundNumber(uint256 n, uint256 warpSeed, address caller)
        public
    {
        n = bound(n, 1, 4096);
        uint64 div = roundManager.DURATION_SCALE_DIV();

        uint64 len = _rawRoundSpec(n);
        uint64 reg = len / 5;
        if (reg < 3 minutes) reg = 3 minutes;
        if (reg > 1 hours) reg = 1 hours;
        assertEq(roundManager.registrationFor(n), reg / div, "R(n)");

        uint64 raw = len - reg;
        uint64 d = raw / div;
        assertEq(roundManager.durationFor(n), d, "D(n) = L(n) - R(n)");
        assertEq(roundManager.roundLengthFor(n), reg / div + d, "L(n), as the chain publishes it");

        assertEq(roundManager.lateEntryUntil(n), raw >= 1 hours ? (raw / 3) / div : 0, "late entry");

        uint64 w = roundManager.CLOSING_WINDOW_S();
        assertEq(w, 15 minutes, "W is the published constant, not a fraction of D");
        assertEq(roundManager.closingWindowFor(n), w / div, "W(n)");

        uint64 quarter = d / 4;
        uint64 randomEnd = quarter < roundManager.RANDOM_END_S() ? quarter : roundManager.RANDOM_END_S();
        if (randomEnd == 0) randomEnd = 1;
        assertEq(roundManager.randomEndWindowFor(n), randomEnd, "random end window");

        // purity: no timestamp and no caller may perturb any of them
        vm.warp(block.timestamp + bound(warpSeed, 1, 400 days));
        vm.prank(caller);
        assertEq(roundManager.durationFor(n), d, "D(n) is independent of time and caller");
        assertEq(roundManager.closingWindowFor(n), w / div, "W(n) is independent of time and caller");
    }

    /// @notice For every `n`, `lateEntryUntil(n) < D(n) - closingWindowFor(n) -
    /// RANDOM_END_S`, so no candidate is ever scored over a span beginning before its own pool
    /// opened.
    function testFuzz_RND02_lateEntryEndsBeforeTheClosingWindowStarts(uint256 n) public view {
        n = bound(n, 1, 4096);
        uint64 late = roundManager.lateEntryUntil(n);
        if (late == 0) return;
        uint64 d = roundManager.durationFor(n);
        uint64 w = roundManager.closingWindowFor(n);
        assertGt(d, w + roundManager.RANDOM_END_S(), "the window fits inside the round");
        assertLt(late, d - w - roundManager.RANDOM_END_S(), "late entry closes before the window opens");
    }

    /// @notice The coarse ring's 63 usable slots span at least
    /// `W + RANDOM_END_S` for every round number `n`. The SETTLEMENT TAIL is not
    /// part of the requirement, because ring writes freeze at the pool's published end and
    /// nothing swapped during settlement can overwrite an entry.
    function testFuzz_SCR06_theCoarseRingSpansTheWholeRead(uint256 n) public view {
        n = bound(n, 1, 4096);
        uint64 span = roundManager.closingWindowFor(n) + roundManager.RANDOM_END_S();
        uint256 covered = uint256(roundManager.scoreSlotFor(n)) * 63;
        assertGe(covered, span, "63 coarse slots reach back over the whole scored span");
        assertEq(hook.SCORE_RING_S(), 180, "the fast ring spans 36 x 5 s");
        assertEq(uint256(hook.SCORE_SLOTS()) * hook.SCORE_SLOT_S(), roundManager.RANDOM_END_S(), "= RANDOM_END_S");
    }

    // ---------------------------------------------------------------------------------
    // bonds
    // ---------------------------------------------------------------------------------

    /// @notice `bondFor(i) = min(BOND_BASE << (i / BOND_DOUBLING_EVERY),
    /// BOND_MAX)` saturates rather than overflowing for every `i`.
    function testFuzz_RND12_bondScheduleSaturates(uint256 i) public view {
        uint256 base = roundManager.BOND_BASE();
        uint256 every = roundManager.BOND_DOUBLING_EVERY();
        uint256 max = roundManager.BOND_MAX();

        uint256 bond = roundManager.bondFor(i);
        assertLe(bond, max, "never above the cap");
        if (every == 0) {
            assertEq(bond, max, "a flat schedule is the cap");
            return;
        }
        uint256 doublings = i / every;
        if (doublings < 256) {
            uint256 scaled = base << doublings;
            if (scaled >> doublings == base && scaled <= max) {
                assertEq(bond, scaled, "the doubling schedule");
                return;
            }
        }
        assertEq(bond, max, "saturated at the cap");
    }

    /// @notice The bond schedule is monotone non-decreasing in the index.
    function testFuzz_RND12_bondIsMonotone(uint256 i, uint256 step) public view {
        i = bound(i, 0, type(uint128).max);
        step = bound(step, 1, type(uint64).max);
        assertLe(roundManager.bondFor(i), roundManager.bondFor(i + step), "bonds never fall with depth");
    }

    /// @notice `registerCandidate` reverts unless `msg.value` equals the round's pinned
    /// bond exactly.
    function testFuzz_RND14_registrationRequiresTheExactBond(uint256 shortAllowance) public {
        uint256 bond = roundManager.currentBond();
        // The bond is an ERC-20 escrow, not `msg.value`, so "the wrong amount" is no
        // longer expressible. What is enforced is that the factory pulls EXACTLY the scheduled
        // bond, and refuses a registrant who has not allowed it that much.
        shortAllowance = bound(shortAllowance, 0, bond - 1);

        address creator = address(0xBADB0);
        _fundDoll(creator, 10 ether);
        vm.prank(creator);
        doll.approve(address(factory), shortAllowance);
        vm.prank(creator);
        vm.expectRevert();
        factory.registerCandidate("X", "X", "", type(uint256).max);

        // and an allowance of at least the bond is accepted, moving exactly the bond
        vm.prank(creator);
        doll.approve(address(factory), type(uint256).max);
        uint256 before = doll.balanceOf(creator);
        vm.prank(creator);
        factory.registerCandidate("X", "X", "", type(uint256).max);
        assertEq(before - doll.balanceOf(creator), bond, "exactly the scheduled bond was pulled");
    }

    /// @notice On a crowned round the winner's bond is refunded to its creator and every
    /// other candidate's bond is forfeited to `FeeVault.edgeBidEarmark`; the forfeited total
    /// is `candidateCount * bondAmount - winnerBond`.
    function testFuzz_RND11_bondsAreRefundedOrForfeited(uint256 losers) public {
        losers = bound(losers, 0, 4);
        uint256 bond = roundManager.currentBond();
        uint256 earmarkBefore = vault.edgeBidEarmark();

        Cand memory winner = _registerCandidate(address(0xA11CE), "W");
        for (uint256 i = 0; i < losers; i++) {
            _registerCandidate(address(uint160(0xB0B00 + i)), "L");
        }
        (uint64 tradingStart,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(winner, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(winner.id);
        vm.warp(submitEnd);
        roundManager.finalize();

        assertEq(roundManager.head(), winner.token, "the round crowned the buyer");
        assertEq(doll.balanceOf(address(0xA11CE)), bond, "the winner's own bond came back, in $DOLL");
        assertEq(vault.edgeBidEarmark() - earmarkBefore, losers * bond, "every other bond was forfeited");
        assertEq(doll.balanceOf(address(roundManager)), 0, "no bond is left in escrow");
        _assertNoEth();
    }

    /// @notice On a failed round `hWad <- max(hWad*9/10, H_MIN_FRAC_WAD)`; on a crowned
    /// round `hWad <- H_FRAC_WAD` exactly, so decay compounds only across consecutive failures.
    function testFuzz_RND13_thresholdDecaysOnlyAcrossFailures(uint256 failures) public {
        failures = bound(failures, 1, 8);
        uint256 expected = roundManager.H_FRAC_WAD();
        uint256 floorWad = roundManager.H_MIN_FRAC_WAD();

        for (uint256 i = 0; i < failures; i++) {
            _registerCandidate(address(uint160(0xF00D00 + i)), "F");
            (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
            _settleEnd();
            vm.warp(submitEnd);
            roundManager.finalize();

            expected = (expected * 9) / 10;
            if (expected < floorWad) expected = floorWad;
            assertEq(roundManager.hWad(), expected, "H decays x0.9 towards the floor");
            assertEq(roundManager.headIndex(), 1, "a failed round crowns nobody");
        }

        // one crowned round resets it exactly, whatever the decay had reached
        Cand memory winner = _registerCandidate(address(0xA11CE), "W");
        (uint64 tradingStart,, uint64 submitEnd2) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(winner, true, WINNING_BUY);
        _settleEnd();
        roundManager.submitScore(winner.id);
        vm.warp(submitEnd2);
        roundManager.finalize();

        assertEq(roundManager.head(), winner.token, "crowned");
        assertEq(roundManager.hWad(), roundManager.H_FRAC_WAD(), "H does not persist across a win");
    }

    /// @dev The published whole round: `min(10 min * 2^floor((n-1)/2), 12 h)`.
    function _rawRoundSpec(uint256 n) internal pure returns (uint64) {
        uint256 doublings = n <= 1 ? 0 : (n - 1) / 2;
        if (doublings >= 16) return 12 hours;
        uint256 l = uint256(10 minutes) << doublings;
        return uint64(l > 12 hours ? 12 hours : l);
    }
}
