// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @notice Property tests for continuation and handover (docs/spec/PROPERTIES.md sec.3.9),
/// tier F: two complete stacks in one PoolManager, v2 continuing v1.
contract ContinuationPropTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;
    address internal constant STEWARD = address(0x57E4A2D);
    Currency internal constant ETH = Currency.wrap(address(0));

    Stack internal v1;
    Stack internal v2;

    address internal genesis;
    address internal link1;

    function setUp() public {
        steward = STEWARD;
        _setUpFamily();
        v1 = _currentStack();
        _buyGenesis(5 ether);
        genesis = address(token);
        link1 = _runWinningRound(1, WINNING_BUY).token;

        v2 = _deployStack(true, STEWARD, address(v1.roundManager));
        _useStack(v2);
    }

    /// @notice CON-03: delegated canonical reads resolve through at most
    /// `MAX_CONTINUATION_HOPS = 8` registries; a deeper index is refused rather than looping
    /// unboundedly.
    function testFuzz_CON03_delegatedReadsAreHopBounded(uint256 indexSeed) public view {
        uint256 index = bound(indexSeed, 0, 1);
        assertEq(v2.roundManager.registryOf(index), address(v1.roundManager), "prior indices delegate one hop");
        assertEq(v2.roundManager.canonical(index), v1.roundManager.canonical(index), "and read identically");
        assertEq(v2.roundManager.MAX_CONTINUATION_HOPS(), 8, "the hop bound is eight registries");

        // an index nobody has crowned resolves to nothing rather than searching forever
        uint256 unseen = bound(indexSeed, 2, 4095);
        assertEq(v2.roundManager.canonical(unseen), address(0), "an unwritten index is empty, not a loop");
    }

    /// @notice CON-02: before adoption a continuation can open no round at all, however many
    /// times it is asked.
    function testFuzz_CON02_noRoundBeforeTheHandover(uint256 attempts) public {
        uint256 bond = v2.roundManager.currentBond();
        address who = address(0xA11CE);
        vm.deal(who, bond * 8);
        for (uint256 i = 0; i < bound(attempts, 1, 4); i++) {
            vm.prank(who);
            vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
            v2.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");
        }
        assertFalse(v2.roundManager.adopted(), "nothing was adopted along the way");
    }

    /// @notice CON-04: while a version is sunset, a protocol fee on its ETH edge is either
    /// forwarded in-swap to the successor's vault or queued in `pendingForward`; it is never
    /// booked to a local ledger.
    function testFuzz_CON04_thePostSunsetEdgeNeverBooksLocally(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.001 ether, 10 ether);
        _sunsetV1();

        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v1LedgerBefore = v1.vault.ledgerTotal(ETH);
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);

        v2.router.buyExactIn{value: ethIn}(1, 0, address(this), 2);

        uint256 fee = (ethIn * v1.hook.PROTOCOL_FEE_PPM()) / PPM;
        assertEq(v1.vault.devBalance(), v1DevBefore, "the sunset version booked none of the edge");
        assertEq(
            v1.vault.ledgerTotal(ETH) - v1LedgerBefore,
            (ethIn * _hopFeePpm()) / PPM,
            "only the hop fee stays with the charging version (CON-11)"
        );
        assertEq(v2.vault.ledgerTotal(ETH) - v2LedgerBefore, fee, "the live version received the whole edge fee");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);
    }

    /// @notice CON-05: `flushForward(attribution, max)` moves at most `max` from
    /// `pendingForward` to the immediate successor's vault, decrementing `pendingForward` and
    /// `ledgerTotal` by exactly the amount delivered, with no value created or destroyed.
    function testFuzz_CON05_flushMovesExactlyWhatItSays(uint256 ethIn, uint256 maxSeed) public {
        ethIn = bound(ethIn, 0.01 ether, 5 ether);
        _sunsetV1();

        // a third version, so v2 is sunset too and QUEUES rather than forwarding in-swap
        Stack memory v3 = _deployStack(true, STEWARD, address(v2.roundManager));
        _useStack(v2);
        _crownWithV2();
        vm.prank(STEWARD);
        v2.roundManager.announceSunset(address(v3.roundManager));
        vm.warp(vm.getBlockTimestamp() + v2.roundManager.sunsetDelay());

        v2.router.buyExactIn{value: ethIn}(1, 0, address(this), 2);
        uint256 fee = (ethIn * v1.hook.PROTOCOL_FEE_PPM()) / PPM;
        uint256 queued = v2.vault.pendingForwardTotal();
        assertEq(queued, fee, "the middle version queued the edge fee");

        uint256 attribution = _queuedAttribution(v2.vault);
        uint256 max = bound(maxSeed, 1, queued);
        uint256 ledgerBefore = v2.vault.ledgerTotal(ETH);
        uint256 v3LedgerBefore = v3.vault.ledgerTotal(ETH);

        uint256 moved = v2.vault.flushForward(attribution, max);
        assertEq(moved, max, "a flush moves at most `max`, and exactly it while the queue is deeper");
        assertEq(v2.vault.pendingForward(attribution), queued - moved, "the queue fell by exactly that");
        assertEq(v2.vault.ledgerTotal(ETH), ledgerBefore - moved, "and so did the ledger total");
        assertEq(v3.vault.ledgerTotal(ETH) - v3LedgerBefore, moved, "the successor booked exactly what arrived");

        // the rest still flushes, and the chain completes in one flush per version
        if (queued > moved) {
            uint256 rest = v2.vault.flushForward(attribution, type(uint256).max);
            assertEq(rest, queued - moved, "the remainder moves on the next flush");
        }
        assertEq(v2.vault.pendingForwardTotal(), 0, "nothing is left queued");
        _assertVaultSolvent(v1.vault);
        _assertVaultSolvent(v2.vault);
        _assertVaultSolvent(v3.vault);
    }

    /// @notice CON-09: no sunset or handover moves or reclaims any wei already credited in the
    /// old vault; balances accrued before the handover stay claimable there forever.
    function testFuzz_CON09_theOldVaultKeepsWhatItEarned(uint256 ethIn, uint256 wait) public {
        ethIn = bound(ethIn, 0.01 ether, 5 ether);
        _useStack(v1);
        _buyGenesis(ethIn);
        uint256 owed = v1.vault.devBalance();
        assertGt(owed, 0, "v1 earned something before the handover");

        _useStack(v2);
        _sunsetV1();
        vm.warp(vm.getBlockTimestamp() + bound(wait, 0, 400 days));
        v2.router.buyExactIn{value: ethIn}(1, 0, address(this), 2);

        assertEq(v1.vault.devBalance(), owed, "the handover did not touch v1's ledger");
        vm.prank(developer);
        assertEq(v1.vault.claimDev(developer), owed, "and it is still claimable in full");
        _assertVaultSolvent(v1.vault);
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _sunsetV1() internal {
        if (v1.roundManager.sunsetAt() == 0) {
            vm.prank(STEWARD);
            v1.roundManager.announceSunset(address(v2.roundManager));
        }
        if (vm.getBlockTimestamp() < v1.roundManager.sunsetAt()) vm.warp(v1.roundManager.sunsetAt());
        assertTrue(v1.roundManager.isSunsetEffective(), "the handover is live");
    }

    /// @dev v2's own first round, so it adopts the trunk and can hand it on in turn.
    function _crownWithV2() internal {
        if (v2.roundManager.adopted()) return;
        _useStack(v2);
        _runWinningRound(1, WINNING_BUY);
        assertTrue(v2.roundManager.adopted(), "v2 adopted at its first round");
    }

    function _queuedAttribution(FeeVault v) internal view returns (uint256 attribution) {
        attribution = type(uint256).max;
        for (uint256 i = 0; i <= v.roundManager().headIndex(); i++) {
            if (v.pendingForward(i) != 0) attribution = i;
        }
    }

    function _assertVaultSolvent(FeeVault v) internal view {
        assertLe(v.ledgerTotal(ETH), v.holdings(ETH), "ETH ledgers <= ETH holdings");
        RoundManager rm = v.roundManager();
        for (uint256 i = 0; i <= rm.headIndex(); i++) {
            Currency c = Currency.wrap(rm.canonical(i));
            assertLe(v.ledgerTotal(c), v.holdings(c), "token ledgers <= token holdings");
        }
    }
}
