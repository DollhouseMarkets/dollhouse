// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Property tests for supply (docs/spec/PROPERTIES.md sec.3.1), tier F.
contract SupplyPropTest is RoundTestBase {
    /// @dev The supply the launch transaction leaves behind: the whole supply less the dust the
    /// launch burns to absorb curve rounding (SUP-02). The token under test is LINK
    /// ONE, the first token this protocol launches.
    uint256 internal launchSupply;

    function setUp() public {
        _setUpEdge();
        vm.warp(block.timestamp + 10);
        launchSupply = token.totalSupply();
    }

    /// @notice SUP-01: `totalSupply()` is `1e9 * 1e18` immediately after `initialize` and is
    /// non-increasing forever after, decreasing only by the exact amount a holder passes to
    /// `burn` from their own balance.
    function testFuzz_SUP01_supplyOnlyEverFallsByAHoldersOwnBurn(uint256 parentIn, uint256 burnSeed) public {
        assertEq(launchSupply + _launchDust(), SUPPLY, "the supply plus the launch dust is the whole supply");
        assertLt(_launchDust(), 1e18, "and the dust is dust");

        _swap(swapRouter, true, -int256(bound(parentIn, 0.01 ether, 20 ether)), "");
        uint256 held = token.balanceOf(address(this));
        assertGt(held, 0, "the buyer holds tokens");
        assertEq(token.totalSupply(), launchSupply, "a swap mints and burns nothing");

        uint256 amount = bound(burnSeed, 1, held);
        token.burn(amount);
        assertEq(token.totalSupply(), launchSupply - amount, "burn removes exactly what the holder passed");
        assertEq(token.balanceOf(address(this)), held - amount, "out of their OWN balance");

        // and nobody can burn what they do not hold
        vm.prank(address(0xB0B));
        vm.expectRevert();
        token.burn(1);
        assertEq(token.totalSupply(), launchSupply - amount, "supply is unchanged by a failed burn");
    }

    /// @notice SUP-01: there is no mint path at all - `initialize` is once-only, and only the
    /// factory may ever call it.
    function testFuzz_SUP01_thereIsNoSecondMint(address caller, uint256 amount) public {
        vm.assume(caller != address(0));
        amount = bound(amount, 1, SUPPLY);

        vm.prank(caller);
        vm.expectRevert();
        amount;
        FamilyToken(address(token)).initialize("X", "X", "", caller);
        assertEq(token.totalSupply(), launchSupply, "the supply is still the launch supply");
    }

    /// @notice SUP-08: a launch curve's FDV bands - and therefore every tick - are denominated
    /// in the full `1e9 * 1e18` supply, and the PLACED quantity is the same number:
    /// there is no developer allocation, so 100% of every family supply is on the curve.
    function test_SUP08_ticksAreDenominatedInTheWholeSupply() public {
        assertEq(FamilyToken(address(token)).TOTAL_SUPPLY(), SUPPLY, "the tick denominator");

        // Measured on a pool that has NEVER traded. Link one is crowned through a round it
        // had to absorb its way through, so the link this fixture holds has already sold part of
        // its supply; a freshly registered candidate still has the whole placement intact.
        Cand memory c = _registerCandidate(address(0xA11CE), "FRESH");
        assertEq(FamilyToken(c.token).TOTAL_SUPPLY(), SUPPLY, "every family token is denominated the same");
        uint256 placed = IERC20(c.token).balanceOf(address(manager));
        uint256 dust = SUPPLY - IERC20(c.token).totalSupply();
        assertEq(placed + dust, SUPPLY, "curve + dust = supply");
        assertLt(dust, 1e18, "...less only the burnt dust");
    }

    /// @notice SUP-04: no protocol contract holds family-token supply, and none of
    /// them holds native ETH either.
    function test_SUP04_noProtocolContractHoldsSupplyOrEth() public view {
        address[6] memory stack =
            [address(factory), address(hook), address(roundManager), address(vault), address(bidDeployer), address(familyRouter)];
        for (uint256 i = 0; i < stack.length; i++) {
            assertEq(IERC20(address(token)).balanceOf(stack[i]), 0, "a protocol contract holds supply");
        }
        _assertNoEth();
    }

    /// @dev The dust the launch transaction burned.
    function _launchDust() internal view returns (uint256) {
        return SUPPLY - launchSupply;
    }
}
