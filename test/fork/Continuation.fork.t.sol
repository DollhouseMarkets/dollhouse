// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";

/// @notice Fork scenarios 8 and 10 of docs/spec/PROPERTIES.md sec.4 on the real `PoolManager`:
/// the forward handover from one deployment to its successor, and a role transfer under real
/// time. Two complete stacks live in the same singleton, exactly as they would on chain.
/// Covers CON-01/04/05/06 and ROL-04/05.
contract ContinuationForkTest is ForkBase {
    address internal constant STEWARD = address(0x57E4A2D);
    Currency internal constant ETH = Currency.wrap(address(0));

    Stack internal v1;
    Stack internal v2;

    address internal genesis;
    address internal link1;
    address internal link2;

    function setUp() public {
        steward = STEWARD;
        if (!_setUpForkFamily()) return;
        v1 = _currentStack();
        _buyGenesis(5 ether);
        genesis = address(token);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(v1.roundManager.headIndex(), 1, "v1 head is #1");

        v2 = _deployStack(true, STEWARD, address(v1.roundManager));
        _useStack(v2);
    }

    /// @dev Announce the sunset on the deploy-constant delay and let it land.
    function _sunsetV1() internal {
        if (v1.roundManager.sunsetAt() == 0) {
            vm.prank(STEWARD);
            v1.roundManager.announceSunset(address(v2.roundManager));
        }
        if (block.timestamp < v1.roundManager.sunsetAt()) vm.warp(v1.roundManager.sunsetAt());
        assertTrue(v1.roundManager.isSunsetEffective(), "the handover is live");
    }

    /// @dev v2 runs its own first round and crowns canonical #2 on top of v1's head.
    function _crownLink2() internal {
        _useStack(v2);
        IERC20(link1).approve(address(swapRouter), type(uint256).max);
        link2 = _runWinningRound(1, WINNING_BUY).token;
    }

    /// @notice CON-01/CON-06: v2 opens nothing until the sunset lands, then adopts v1's head and
    /// numbers its own first link at `priorIndex + 1`, while v1 opens no further round.
    function testFork_CON01_theSuccessorAdoptsTheHeadAtTheHandover() public {
        _requireFork();
        assertEq(v2.roundManager.priorRegistry(), address(v1.roundManager), "v2 continues v1");
        assertFalse(v2.roundManager.adopted(), "nothing adopted yet");

        uint256 bond = v2.roundManager.currentBond();
        vm.deal(address(0xA11CE), bond * 4);
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.PriorNotHandedOver.selector);
        v2.factory.registerCandidate{value: bond}("EARLY", "EARLY", "");

        // the sunset delay really is the constructor parameter, not the mainnet constant
        uint64 announcedAt = uint64(block.timestamp);
        vm.prank(STEWARD);
        v1.roundManager.announceSunset(address(v2.roundManager));
        assertEq(v1.roundManager.sunsetAt(), announcedAt + DEPLOY_SUNSET_DELAY_S, "the deployed delay");
        _sunsetV1();

        // v1 mints no further round...
        vm.deal(address(0xB0B), bond * 4);
        vm.prank(address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(RoundManager.Sunset.selector, address(v2.roundManager)));
        v1.factory.registerCandidate{value: bond}("LATE", "LATE", "");

        // ...and v2 picks the trunk up exactly where v1 left it
        _crownLink2();
        assertTrue(v2.roundManager.adopted(), "v2 adopted the trunk");
        assertEq(v2.roundManager.priorIndex(), 1, "v1's final head index");
        assertEq(v2.roundManager.canonical(1), link1, "index 1 still resolves to v1's link");
        assertEq(v2.roundManager.canonical(2), link2, "and v2 numbers its own first link at prior + 1");
        assertEq(v2.roundManager.headIndex(), 2, "one trunk, not two");
        assertEq(v1.roundManager.canonical(2), address(0), "v1 never wrote index 2");
    }

    /// @notice CON-04/CON-05: after the handover the 1% ETH edge charged on v1's genesis pool is
    /// booked by v2's FeeVault, with v2's split and v2's attribution, while v1 keeps only the hop
    /// fee that reinforces its own pool. The ledgers accrued before the handover do not move.
    function testFork_CON04_theEdgeIsForwardedToTheSuccessorVault() public {
        _requireFork();
        _sunsetV1();
        _crownLink2();
        address creator2 = v2.roundManager.creatorOf(link2);

        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v1LedgerBefore = v1.vault.ledgerTotal(ETH);
        uint256 v1HopBefore = v1.vault.reinforcementBalance(address(0));
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);
        uint256 v2CreatorBefore = v2.vault.creatorBalance(link2);

        uint256 ethIn = 1 ether;
        uint256 out = v2.router.buyExactIn{value: ethIn}(2, 1, address(this), 3);
        assertGt(out, 0, "the cross-version route still delivers");

        uint256 fee = (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM;
        uint256 hop = (ethIn * _hopFeePpm()) / PPM;

        assertEq(v1.vault.devBalance(), v1DevBefore, "v1's dev ledger is frozen at the handover");
        assertEq(v1.vault.reinforcementBalance(address(0)) - v1HopBefore, hop, "the hop fee stays with v1");
        assertEq(v1.vault.ledgerTotal(ETH) - v1LedgerBefore, hop, "v1 books the hop fee only");
        assertEq(v1.vault.successorVault(), address(v2.vault), "v1 resolved and cached v2's vault");

        assertEq(v2.vault.ledgerTotal(ETH) - v2LedgerBefore, fee, "the whole edge landed in v2's ETH ledger");
        assertEq(
            v2.vault.creatorBalance(link2) - v2CreatorBefore,
            (fee * _creatorBps()) / 10_000,
            "attributed to the terminal token's creator, under v2's split"
        );
        assertEq(v2.vault.creatorRecipient(link2), creator2, "claimable by that creator");
        assertGe(v2.vault.holdings(ETH), v2.vault.ledgerTotal(ETH), "v2 holds what it promises");
        assertGe(v1.vault.holdings(ETH), v1.vault.ledgerTotal(ETH), "and so does v1");
    }

    /// @notice CON-05: BEFORE the sunset takes effect nothing moves - v1 books the edge on its own
    /// ledgers and resolves no successor at all.
    function testFork_CON05_beforeTheHandoverTheEdgeStaysWithTheIncumbent() public {
        _requireFork();
        uint256 v1DevBefore = v1.vault.devBalance();
        uint256 v2LedgerBefore = v2.vault.ledgerTotal(ETH);

        v2.router.buyExactIn{value: 1 ether}(1, 0, address(this), 2);

        uint256 fee = (1 ether * hook.PROTOCOL_FEE_PPM()) / PPM;
        assertEq(v1.vault.devBalance() - v1DevBefore, (fee * v1.vault.DEV_BPS()) / 10_000, "v1 booked the edge");
        assertEq(v2.vault.ledgerTotal(ETH), v2LedgerBefore, "v2 got none of it");
        assertEq(v1.vault.successorVault(), address(0), "no successor was ever resolved");
    }

    /// @notice ROL-04/ROL-05 under real time: the only privileged role in the system cannot change
    /// hands silently. Execution is refused one second short of the delay, succeeds at the delay
    /// from any caller, and an announcement can be taken back before it lands.
    function testFork_ROL05_theStewardRoleMovesOnlyOnItsPublicDelay() public {
        _requireFork();
        address nextSteward = address(0x5EC0ED);
        uint64 delay = v1.roundManager.ROLE_TRANSFER_DELAY();

        // an announcement that is taken back changes nothing
        vm.prank(STEWARD);
        v1.roundManager.announceStewardTransfer(nextSteward);
        vm.prank(STEWARD);
        v1.roundManager.cancelStewardTransfer();
        assertEq(v1.roundManager.steward(), STEWARD, "cancelled: the role never moved");

        vm.prank(STEWARD);
        v1.roundManager.announceStewardTransfer(nextSteward);
        uint64 effectiveAt = uint64(block.timestamp) + delay;

        vm.warp(effectiveAt - 1);
        vm.expectRevert(RoundManager.TransferNotReady.selector);
        v1.roundManager.executeStewardTransfer();

        // ...and only the named destination can ever take it, whoever sends the transaction
        vm.warp(effectiveAt);
        vm.prank(address(0xDEAD));
        v1.roundManager.executeStewardTransfer();
        assertEq(v1.roundManager.steward(), nextSteward, "the role moved to the announced address");

        // nothing new becomes callable: the surface is still the sunset switch alone
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.NotSteward.selector);
        v1.roundManager.announceSunset(address(v2.roundManager));
        vm.prank(nextSteward);
        v1.roundManager.announceSunset(address(v2.roundManager));
        assertEq(v1.roundManager.successor(), address(v2.roundManager), "the new holder can sunset, and only that");
    }
}
