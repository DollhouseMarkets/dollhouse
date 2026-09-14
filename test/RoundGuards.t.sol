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

/// @dev A candidate creator that cannot receive ETH, so the winner's bond refund must fall back
/// to the pull path.
contract RefundRejector {
    function register(FamilyFactory factory, uint256 bond) external payable returns (uint256 id) {
        (,, id) = factory.registerCandidate{value: bond}("REJ", "REJ", "");
    }

    function claim(RoundManager rm, address to) external {
        rm.claimRefund(to);
    }
    // deliberately no receive()
}

/// @notice Round-level guards: the pull refund fallback, the documented burn/threshold
/// interaction (L10) and the chain-depth limit (L6).
contract RoundGuardsTest is RoundTestBase {
    using stdStorage for StdStorage;

    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
    }

    // ---------------------------------------------------------------------------------
    // the pull refund fallback
    // ---------------------------------------------------------------------------------

    function test_claimRefundIsThePullFallbackForAWinnerThatRejectsEth() public {
        RefundRejector rejector = new RefundRejector();
        uint256 bond = roundManager.currentBond();
        uint256 id = rejector.register{value: bond}(factory, bond);
        assertEq(address(rejector).balance, 0, "the rejector forwarded its whole bond");

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
        roundManager.finalize();
        assertEq(roundManager.head(), c.token, "the rejector won");
        assertEq(address(rejector).balance, 0, "the push refund could not land");
        assertEq(roundManager.pendingRefund(address(rejector)), bond, "it is owed as a pull claim");
        assertEq(address(roundManager).balance, bond, "and the escrow still holds it");

        // nobody else can take it
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        roundManager.claimRefund(address(this));

        // the creator pulls it to an address that CAN receive ETH
        address payout = address(0xF00D);
        rejector.claim(roundManager, payout);
        assertEq(payout.balance, bond, "the bond was pulled out");
        assertEq(roundManager.pendingRefund(address(rejector)), 0, "and the claim is cleared");

        // and only once
        vm.expectRevert(RoundManager.NothingToClaim.selector);
        rejector.claim(roundManager, payout);
    }

    // ---------------------------------------------------------------------------------
    // L10: burning head supply lowers H (accepted, documented)
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
    // L6: the chain depth limit is a clear revert at REGISTRATION
    // ---------------------------------------------------------------------------------

    /// @notice The ancestor sleeve is a Fenwick tree over a bounded index space. The chain must
    /// refuse the registration that would create an unaddressable generation, rather than let
    /// the tree revert later from inside a swap and brick every pool on the chain.
    function test_registrationRefusesToExceedTheChainDepthLimit() public {
        uint256 max = FenwickRangeAdd.MAX_INDEX;

        // one below the limit: a registration is still fine. `headIndex` is located by its own
        // getter rather than a hardcoded slot, so adding state to the RoundManager cannot make
        // this test silently poke the wrong word. The bond is read AFTER the write: it scales
        // with the index the round competes for (F6).
        stdstore.target(address(roundManager)).sig("headIndex()").checked_write(max - 1);
        assertEq(roundManager.headIndex(), max - 1);
        uint256 bond = roundManager.currentBond();
        assertEq(bond, roundManager.BOND_MAX_WEI(), "the schedule is capped, not unbounded");
        vm.deal(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        factory.registerCandidate{value: bond}("OK", "OK", "");

        // at the limit the next link would be unaddressable: a named, immediate revert
        stdstore.target(address(roundManager)).sig("headIndex()").checked_write(max);
        vm.deal(address(0xB0B), bond);
        vm.prank(address(0xB0B));
        vm.expectRevert(FamilyFactory.ChainDepthLimit.selector);
        factory.registerCandidate{value: bond}("NO", "NO", "");
    }
}
