// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {FenwickRangeAdd} from "../contracts/libraries/FenwickRangeAdd.sol";

/// @notice DEPTH: what the protocol does ten links down. Three properties matter here.
///
///   The keeper conversion walks the AMOUNT through the chain with a full-precision `mulDiv` per
///        factor, not a normalised 1e18-per-link rate: each link is worth 5-8% of its parent, so
///        a normalised rate would lose ~4 significant digits per generation and reach ZERO
///        (`BadConversionRate`) around j = 10, permanently stranding every deeper generation's
///        ETH sleeve.
///   The entry bond doubles with depth, so extending the chain never becomes free.
///   beta depth cap - `maxIndex` refuses the registration that would go past it.
contract DepthTest is RoundTestBase {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

    uint256 internal constant WAD = 1e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // The entry bond doubles with depth
    // ---------------------------------------------------------------------------------

    function test_bondDoublesEveryFourLinksAndIsCapped() public view {
        uint256 base = roundManager.BOND_BASE();
        assertEq(roundManager.BOND_DOUBLING_EVERY(), 4);
        assertEq(roundManager.bondFor(1), base, "index 1 pays the base bond");
        assertEq(roundManager.bondFor(3), base, "...and so does index 3");
        assertEq(roundManager.bondFor(4), 2 * base, "index 4 is the first doubling");
        assertEq(roundManager.bondFor(5), 2 * base);
        assertEq(roundManager.bondFor(8), 4 * base);
        assertEq(roundManager.bondFor(9), 4 * base);
        assertEq(roundManager.bondFor(24), 64 * base, "six doublings reaches the cap");
        assertEq(roundManager.bondFor(28), roundManager.BOND_MAX(), "and never goes past it");
        assertEq(roundManager.bondFor(1_000_000), roundManager.BOND_MAX(), "the shift cannot overflow");
        assertEq(roundManager.currentBond(), roundManager.bondFor(2), "the next round competes for index 2");
    }

    /// @notice The round's bond is the schedule's value for the index it competes for, it is
    /// pulled to the wei, and the refund/forfeit paths use the amount the candidate ACTUALLY
    /// posted rather than a global constant.
    ///
    /// @dev The bond is an ERC-20 escrow, not `msg.value`, so "the wrong amount" is no
    /// longer expressible - what is enforced is that the factory pulls EXACTLY the scheduled bond
    /// and refuses a registrant who has not allowed that much.
    function test_theBondIsEnforcedRefundedAndForfeitedAtTheScheduledAmount() public {
        uint256 base = roundManager.BOND_BASE();

        // an allowance short of the scheduled bond is refused...
        _fundDoll(address(0xA11CE), 10 * base);
        vm.prank(address(0xA11CE));
        doll.approve(address(factory), base - 1);
        vm.prank(address(0xA11CE));
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(factory), base - 1, base
            )
        );
        factory.registerCandidate("X", "X", "", type(uint256).max);

        // ...and a larger one still only ever moves the scheduled bond
        uint256 registrantBefore = doll.balanceOf(address(0xA11CE));
        vm.prank(address(0xA11CE));
        doll.approve(address(factory), 10 * base);
        vm.prank(address(0xA11CE));
        factory.registerCandidate("X", "X", "", type(uint256).max);
        assertEq(registrantBefore - doll.balanceOf(address(0xA11CE)), base, "exactly the scheduled bond was pulled");

        // a round with a winner: the winner gets its own bond back, the loser's is forfeited
        Cand memory win = _registerCandidate(address(0xB0B), "WIN");
        Cand memory lose = _registerCandidate(address(0xCAFE), "LOSE");
        assertEq(roundManager.roundInfo(2).bondAmount, base, "the round pinned the schedule's bond");
        assertEq(roundManager.candidateInfo(win.id).bond, base, "and every candidate stored what it paid");

        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(win, true, 6_100_000e18);
        _settleEnd();
        roundManager.submitScore(win.id);
        roundManager.submitScore(lose.id);
        vm.warp(submitEnd + 1);

        uint256 winnerBefore = doll.balanceOf(address(0xB0B));
        uint256 earmarkBefore = vault.edgeBidEarmark();
        roundManager.finalize();
        assertEq(doll.balanceOf(address(0xB0B)) - winnerBefore, base, "the winner is refunded its own bond");
        // two losers: the short-allowance registrant's replacement and LOSE
        assertEq(vault.edgeBidEarmark() - earmarkBefore, 2 * base, "the losing bonds are forfeited, at their amount");
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // beta depth cap
    // ---------------------------------------------------------------------------------

    /// @notice There is no "unlimited". The ancestor sleeve is three Fenwick trees over
    /// {FenwickRangeAdd.MAX_INDEX} + 1 generations, so a link crowned above that index could
    /// never be paid at all - `addSleeve` reverts `IndexOutOfRange` on the very next fee. A
    /// `maxIndex` of 0 therefore means the sleeve's own cap, and a deployment that asks for more
    /// is refused at construction rather than at the fee that discovers it.
    function test_theDepthCapIsTheSleevesAndCannotBeDeployedPastIt() public {
        assertEq(roundManager.MAX_INDEX(), FenwickRangeAdd.MAX_INDEX, "0 means the sleeve's cap");

        // the last legal value deploys, and means exactly what 0 meant
        maxIndex = FenwickRangeAdd.MAX_INDEX;
        Stack memory atCap = _deployStack(true, steward, address(0));
        assertEq(atCap.roundManager.MAX_INDEX(), FenwickRangeAdd.MAX_INDEX, "the deepest legal chain");

        // one past it is refused at construction
        maxIndex = FenwickRangeAdd.MAX_INDEX + 1;
        // Read off `lastFactoryError` (see FamilyTestBase._newFactory)
        _deployStack(true, steward, address(0));
        assertEq(lastFactoryError, RoundManager.BadMaxIndex.selector, "refused at construction");
        maxIndex = 0;
    }

    /// @notice `maxIndex` is a DEPLOY constant, not a policy: a beta deployment simply refuses to
    /// crown past it, with a named error at registration.
    function test_maxIndexRefusesTheRoundThatWouldGoPastIt() public {
        assertEq(roundManager.MAX_INDEX(), FenwickRangeAdd.MAX_INDEX, "the default stack is sleeve-capped");

        // a second, capped stack in the same PoolManager
        maxIndex = 1;
        Stack memory capped = _deployStack(true, steward, address(0));
        _useStack(capped);
        _adoptGenesis();
        assertEq(roundManager.MAX_INDEX(), 1);

        // index 1 is allowed...
        _runWinningRound(1, 6_100_000e18);
        assertEq(roundManager.headIndex(), 1, "the cap is not off by one");

        // ...index 2 is not
        uint256 bond = roundManager.currentBond();
        _fundDoll(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        doll.approve(address(factory), bond);
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.ChainDepthLimit.selector);
        factory.registerCandidate("TOODEEP", "TOODEEP", "", type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // The conversion at depth
    // ---------------------------------------------------------------------------------

    /// @notice A chain of SIXTEEN links (canonical 1..16 plus the adopted index 0), and a keeper
    /// deployment fourteen and sixteen generations deep.
    ///
    /// @dev A naive `dollPerTokenWad` - a WAD-normalised rate, one `mulDiv` per link - is
    /// recomputed here and asserted to collapse to ZERO well before the end
    /// of the chain: every generation past that point would have a sleeve that could never
    /// be spent. The live conversion walks the amount instead and stays exact (it is LINEAR in
    /// the amount to the wei, which a collapsed rate cannot be).
    ///
    /// @dev Every link is a family link, quoted against the edge currency rather than native ETH
    /// against a genesis token, so the chain has to be longer before the naive arithmetic dies -
    /// and it still dies, a dozen links in, a long way inside the index space the sleeve can
    /// address.
    function test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed() public {
        // `_setUpEdge` already crowned link one, so fifteen more rounds reach canonical 16
        _buildChain(15);
        assertEq(roundManager.headIndex(), 16, "sixteen links of our own");
        _warmAllPools();

        // 1. THE OLD ARITHMETIC: a WAD-normalised rate, floored once per link. Index 0 is the
        // edge currency itself and has no pool, so the walk starts at link one.
        uint256 oldRateWad = WAD;
        uint256 collapsedAt = type(uint256).max;
        uint256 head = roundManager.headIndex();
        for (uint256 k = 1; k <= head; k++) {
            oldRateWad = FullMath.mulDiv(oldRateWad, _parentPerTokenWad(k), WAD);
            if (oldRateWad == 0 && collapsedAt == type(uint256).max) collapsedAt = k;
        }
        emit log_named_uint("the old normalised rate reached zero at generation", collapsedAt);
        assertLe(collapsedAt, head, "The old rate really did underflow on this chain");

        // 2. the new walk: positive, and exactly linear in the amount
        (uint256 v1,) = bidDeployer.dollValueOfParent(15, 1_000_000e18);
        (uint256 v2,) = bidDeployer.dollValueOfParent(15, 2_000_000e18);
        assertGt(v1, 0, "the deepest link still converts to a positive $DOLL value");
        assertApproxEqAbs(v2, 2 * v1, 2, "and the conversion is linear at depth, to the wei");

        // 3. the old code could not even be CALLED past the collapse: the normalised rate it
        // priced against is zero from generation 13 on, so `deployAncestor(14)` reverted
        // BadConversionRate for every keeper, forever, and generation 14's sleeve was stranded by
        // construction
        vm.expectRevert(BidDeployer.BadConversionRate.selector);
        bidDeployer.dollPerTokenWad(13);

        // ...and now it is a real keeper deployment, paid out of generation 14's own sleeve
        uint256 paid = _deployAt(14);
        emit log_named_uint("deployAncestor(14) paid, wei", paid);
        assertGt(paid, 0, "generation 14's sleeve is spendable at all");

        // 4. generation 16, the deepest link of the chain. The old rate was zero from generation
        // 13 on, so NOTHING here could ever be priced - the sleeve was a dead end. The walk prices
        // any amount that is worth at least a wei, and such an amount exists inside the supply:
        address parent15 = roundManager.canonical(15);
        uint256 oneWeiWorth = bidDeployer.parentForDollValue(16, 1);
        emit log_named_uint("generation-15 tokens worth one wei of the edge currency", oneWeiWorth);
        assertLt(oneWeiWorth, IERC20(parent15).totalSupply(), "a wei of value exists in generation 15's supply");
        (uint256 deep,) = bidDeployer.dollValueOfParent(16, 4 * oneWeiWorth);
        assertGt(deep, 0, "and the conversion prices it, sixteen links down");

        // What stops the keeper this deep is now the POOL, not the arithmetic: a link whose whole
        // market cap is a vanishing fraction of the edge pool's cannot absorb a wei-sized bid
        // inside the 2% size cap. That is an economic limit with a named error, not a permanent
        // stranding of the ledger.
        address keeper = address(0xC0FFEE);
        _seedSleeve(16);
        uint256 amount16 = 4 * oneWeiWorth;
        deal(parent15, keeper, amount16);
        vm.startPrank(keeper);
        IERC20(parent15).approve(address(bidDeployer), amount16);
        vm.expectRevert(abi.encodeWithSelector(BidDeployer.SizeCapExceeded.selector, amount16, bidDeployer.bidCap(16)));
        bidDeployer.deployAncestor(16, amount16);
        vm.stopPrank();
        _assertSolvent();
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev `parentPerToken` of generation `k`, WAD-scaled: the per-link factor the OLD
    /// conversion multiplied into a running rate.
    function _parentPerTokenWad(uint256 k) internal view returns (uint256) {
        PoolId id = roundManager.poolKeyOf(k).toId();
        (uint160 twap,) = hook.consult(id, bidDeployer.TWAP_WINDOW());
        bool parentIsCurrency0 = hook.poolInfo(id).parentIsCurrency0;
        uint256 half = parentIsCurrency0
            ? FullMath.mulDiv(FixedPoint96.Q96, WAD, twap)
            : FullMath.mulDiv(twap, WAD, FixedPoint96.Q96);
        return parentIsCurrency0
            ? FullMath.mulDiv(half, FixedPoint96.Q96, twap)
            : FullMath.mulDiv(half, twap, FixedPoint96.Q96);
    }

    /// @dev Seed generation `j`'s edge sleeve, hand a keeper the parent tokens it needs and run
    /// the keeper path. Returns the $DOLL the keeper was paid.
    function _deployAt(uint256 j) internal returns (uint256 paid) {
        _seedSleeve(j);
        uint256 cap = bidDeployer.bidCap(j);
        uint256 affordable = bidDeployer.maxParentForDeploy(j);
        uint256 amount = cap < affordable ? cap : affordable;
        address parent = roundManager.canonical(j - 1);
        uint256 held = IERC20(parent).balanceOf(address(this));
        if (amount > held) amount = held;
        assertGt(amount, 0, "the keeper has something to deploy");

        address keeper = address(0xC0FFEE);
        IERC20(parent).transfer(keeper, amount);
        uint256 before = doll.balanceOf(keeper);
        vm.startPrank(keeper);
        IERC20(parent).approve(address(bidDeployer), amount);
        _deployAncestor(j, amount);
        vm.stopPrank();
        paid = doll.balanceOf(keeper) - before;
    }

    /// @dev Give generation `j` an edge-currency sleeve to be paid out of. A stack earns these
    /// from its own edge-pool volume; seeding is how a depth test reaches generation 11 without
    /// replaying months of trading.
    function _seedSleeve(uint256 j) internal {
        uint256 seed = 10 ether;
        _fundDoll(address(vault), seed);
        stdstore.target(address(vault)).sig("reinforcementEdge(uint256)").with_key(j).checked_write(seed);
        stdstore.target(address(vault))
            .sig("ledgerTotal(address)")
            .with_key(DOLL_ADDRESS)
            .checked_write(vault.ledgerTotal(Currency.wrap(DOLL_ADDRESS)) + seed);
    }

    /// @dev Crown `links` more links, one round each. Every round buys twice the threshold of
    /// the head, which is what a real succession has to absorb.
    function _buildChain(uint256 links) internal {
        for (uint256 i = 0; i < links; i++) {
            address parent = roundManager.head();
            uint256 buy = 2 * roundManager.threshold();
            uint256 held = IERC20(parent).balanceOf(address(this));
            assertGe(held, buy, "the previous round left enough of the head to succeed it");
            _runWinningRound(1, buy);
        }
    }

    /// @dev Give every pool on the chain a TWAP the keeper paths can use: two observations more
    /// than {FamilyHook.OBS_MIN_SPACING} apart, then a long quiet stretch so that the average and
    /// the spot price agree (the band guard is applied to the target pool).
    function _warmAllPools() internal {
        // `block.timestamp` is CSE'd across `vm.warp` inside one function under `via_ir`: track
        // the clock in a local
        uint256 t = block.timestamp;
        for (uint256 pass = 0; pass < 2; pass++) {
            _buyLink(1, 0.05 ether);
            for (uint256 i = 1; i <= roundManager.headIndex(); i++) {
                _nudge(i);
            }
            t += 200;
            vm.warp(t);
        }
        vm.warp(t + 4 * uint256(bidDeployer.TWAP_WINDOW()));
    }

    /// @dev The smallest useful swap against link `i`'s pool: enough to write an observation.
    function _nudge(uint256 i) internal {
        PoolKey memory k = roundManager.poolKeyOf(i);
        address parent = roundManager.canonical(i - 1);
        uint256 amountIn = IERC20(parent).balanceOf(address(this)) / 10_000;
        if (amountIn == 0) return;
        IERC20(parent).approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = Currency.unwrap(k.currency0) == parent;
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
