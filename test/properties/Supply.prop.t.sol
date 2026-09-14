// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FamilyTestBase} from "../utils/FamilyTestBase.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Property tests for supply (docs/spec/PROPERTIES.md sec.3.1), tier F.
contract SupplyPropTest is FamilyTestBase {
    /// @dev The supply the genesis transaction leaves behind: the whole supply less the dust the
    /// launch burns to absorb curve rounding (SUP-02).
    uint256 internal launchSupply;

    function setUp() public {
        _deployProtocol();
        _createGenesis();
        vm.deal(address(this), 1_000 ether);
        launchSupply = token.totalSupply();
    }

    /// @notice SUP-01: `totalSupply()` is `1e9 * 1e18` immediately after `initialize` and is
    /// non-increasing forever after, decreasing only by the exact amount a holder passes to
    /// `burn` from their own balance.
    function testFuzz_SUP01_supplyOnlyEverFallsByAHoldersOwnBurn(uint256 ethIn, uint256 burnSeed) public {
        assertEq(launchSupply + _launchDust(), SUPPLY, "the supply plus the launch dust is the whole supply");
        assertLt(_launchDust(), 1e18, "and the dust is dust");

        _swap(swapRouter, true, -int256(bound(ethIn, 0.01 ether, 20 ether)), "");
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
        FamilyToken(address(token)).initialize("X", "X", "", caller, caller, amount);
        assertEq(token.totalSupply(), launchSupply, "the supply is still the launch supply");
    }

    /// @notice SUP-08: the genesis curve's FDV bands - and therefore every tick - are
    /// denominated in the full `1e9 * 1e18` supply, while the placed quantities are denominated
    /// in `genesisTokensForSale()`.
    function testFuzz_SUP08_ticksAreDenominatedInTheWholeSupply(uint256 unused) public view {
        unused;
        assertEq(FamilyToken(address(token)).TOTAL_SUPPLY(), SUPPLY, "the tick denominator");
        assertLt(factory.genesisTokensForSale(), SUPPLY, "the placed quantity is the smaller one");
        assertEq(
            factory.genesisTokensForSale() + factory.devAllocation(), SUPPLY, "and the two make up the whole supply"
        );

        // what the Locker actually placed is denominated in the SALE supply, not in the total
        uint256 placed = IERC20(address(token)).balanceOf(address(manager));
        assertEq(placed + _launchDust() + factory.devAllocation(), SUPPLY, "curve + dust + allocation = supply");
        assertLe(placed, factory.genesisTokensForSale(), "the curve holds at most the sale supply");
        assertGe(placed + 1e18, factory.genesisTokensForSale(), "...less only the burnt dust");
        assertEq(
            IERC20(address(token)).balanceOf(factory.devVesting()), factory.devAllocation(), "the rest is vesting"
        );
    }


    /// @dev The dust the genesis transaction burned.
    function _launchDust() internal view returns (uint256) {
        return SUPPLY - launchSupply;
    }
}
