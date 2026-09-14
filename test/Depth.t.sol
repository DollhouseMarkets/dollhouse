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

/// @notice DEPTH: what the protocol does ten links down. Three audit findings live here.
///
///   F3 - the keeper conversion used to normalise the chain rate to 1e18 per link. Each link is
///        worth 5-8% of its parent, so the rate lost ~4 significant digits per generation and
///        reached ZERO (`BadConversionRate`) around j = 10: every deeper generation's ETH sleeve
///        was permanently unspendable. The fix walks the AMOUNT through the chain with a
///        full-precision `mulDiv` per factor.
///   F6 - the entry bond doubles with depth, so extending the chain never becomes free.
///   beta depth cap - `maxIndex` refuses the registration that would go past it.
contract DepthTest is RoundTestBase {
    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

    uint256 internal constant WAD = 1e18;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
    }

    // ---------------------------------------------------------------------------------
    // F6: the entry bond doubles with depth
    // ---------------------------------------------------------------------------------

    function test_bondDoublesEveryFourLinksAndIsCapped() public view {
        uint256 base = roundManager.BOND_BASE_WEI();
        assertEq(roundManager.BOND_DOUBLING_EVERY(), 4);
        assertEq(roundManager.bondFor(1), base, "index 1 pays the base bond");
        assertEq(roundManager.bondFor(3), base, "...and so does index 3");
        assertEq(roundManager.bondFor(4), 2 * base, "index 4 is the first doubling");
        assertEq(roundManager.bondFor(5), 2 * base);
        assertEq(roundManager.bondFor(8), 4 * base);
        assertEq(roundManager.bondFor(9), 4 * base);
        assertEq(roundManager.bondFor(24), 64 * base, "six doublings reaches the cap");
        assertEq(roundManager.bondFor(28), roundManager.BOND_MAX_WEI(), "and never goes past it");
        assertEq(roundManager.bondFor(1_000_000), roundManager.BOND_MAX_WEI(), "the shift cannot overflow");
        assertEq(roundManager.currentBond(), roundManager.bondFor(1), "the next round competes for index 1");
    }

    /// @notice The round's bond is the schedule's value for the index it competes for, it is
    /// enforced to the wei, and the refund/forfeit paths use the amount the candidate ACTUALLY
    /// posted rather than a global constant.
    function test_theBondIsEnforcedRefundedAndForfeitedAtTheScheduledAmount() public {
        uint256 base = roundManager.BOND_BASE_WEI();

        // wrong value, either way, is refused
        vm.deal(address(0xA11CE), 1 ether);
        vm.prank(address(0xA11CE));
        vm.expectRevert(FamilyFactory.WrongBond.selector);
        factory.registerCandidate{value: base - 1}("X", "X", "");
        vm.prank(address(0xA11CE));
        vm.expectRevert(FamilyFactory.WrongBond.selector);
        factory.registerCandidate{value: base + 1}("X", "X", "");

        // a round with a winner: the winner gets its own bond back, the loser's is forfeited
        _registerCandidate(address(0xB0B), "WIN");
        _registerCandidate(address(0xCAFE), "LOSE");
        assertEq(roundManager.roundInfo(1).bondWei, base, "the round pinned the schedule's bond");
        assertEq(roundManager.candidateInfo(0).bond, base, "and every candidate stored what it paid");

        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(1);
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(cands[0], true, 6_100_000e18);
        _settleEnd();
        roundManager.submitScore(cands[0].id);
        roundManager.submitScore(cands[1].id);
        vm.warp(submitEnd + 1);

        uint256 winnerBefore = address(0xB0B).balance;
        uint256 earmarkBefore = vault.genesisBidEarmark();
        roundManager.finalize();
        assertEq(address(0xB0B).balance - winnerBefore, base, "the winner is refunded its own bond");
        assertEq(vault.genesisBidEarmark() - earmarkBefore, base, "the loser's bond is forfeited, at its own amount");
    }

    // ---------------------------------------------------------------------------------
    // beta depth cap
    // ---------------------------------------------------------------------------------

    /// @notice REVIEW 2: there is no "unlimited". The ancestor sleeve is three Fenwick trees over
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
        vm.expectRevert(RoundManager.BadMaxIndex.selector);
        _deployStack(true, steward, address(0));
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
        _createGenesis();
        vm.deal(address(this), 10_000 ether);
        _buyGenesis(5 ether);
        assertEq(roundManager.MAX_INDEX(), 1);

        // index 1 is allowed...
        _runWinningRound(1, 6_100_000e18);
        assertEq(roundManager.headIndex(), 1, "the cap is not off by one");

        // ...index 2 is not
        uint256 bond = roundManager.currentBond();
        vm.deal(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        vm.expectRevert(RoundManager.ChainDepthLimit.selector);
        factory.registerCandidate{value: bond}("TOODEEP", "TOODEEP", "");
    }

    // ---------------------------------------------------------------------------------
    // F3: the conversion at depth
    // ---------------------------------------------------------------------------------

    /// @notice A chain of TWELVE links (canonical 0..11), and a keeper deployment eight and
    /// eleven generations deep.
    ///
    /// @dev The old `ethPerTokenWad` is recomputed here the way it used to be - a WAD-normalised
    /// rate, one `mulDiv` per link - and asserted to have collapsed to ZERO well before the end
    /// of the chain: that is the bug, and every generation past it had an ETH sleeve that could
    /// never be spent. The live conversion walks the amount instead and stays exact (it is
    /// LINEAR in the amount to the wei, which a collapsed rate cannot be).
    function test_deepChainConvertsAndDeploysWhereTheOldRateUnderflowed() public {
        _buildChain(11);
        assertEq(roundManager.headIndex(), 11, "twelve links");
        _warmAllPools();

        // 1. the old arithmetic: a normalised rate, floored per link
        uint256 oldRateWad = WAD;
        uint256 collapsedAt = type(uint256).max;
        for (uint256 k = 0; k <= 11; k++) {
            oldRateWad = FullMath.mulDiv(oldRateWad, _parentPerTokenWad(k), WAD);
            if (oldRateWad == 0 && collapsedAt == type(uint256).max) collapsedAt = k;
        }
        emit log_named_uint("the old normalised rate reached zero at generation", collapsedAt);
        assertLe(collapsedAt, 11, "F3: the old rate really did underflow on this chain");

        // 2. the new walk: positive, and exactly linear in the amount
        (uint256 v1,) = bidDeployer.ethValueOfParent(10, 1_000_000e18);
        (uint256 v2,) = bidDeployer.ethValueOfParent(10, 2_000_000e18);
        assertGt(v1, 0, "the deepest link still converts to a positive ETH value");
        assertApproxEqAbs(v2, 2 * v1, 2, "and the conversion is linear at depth, to the wei");

        // 3. the old code could not even be CALLED this deep: the normalised rate it priced
        // against is zero from generation 7 on, so `deployAncestor(8)` reverted BadConversionRate
        // for every keeper, forever, and generation 8's ETH was stranded by construction
        vm.expectRevert(BidDeployer.BadConversionRate.selector);
        bidDeployer.ethPerTokenWad(7);

        // ...and now it is a real keeper deployment, paid out of generation 8's own sleeve
        uint256 paid = _deployAt(8);
        emit log_named_uint("deployAncestor(8) paid, wei", paid);
        assertGt(paid, 0, "generation 8's sleeve is spendable at all");

        // 4. generation 11, the deepest link of the chain. The old rate was zero from generation
        // 7 on, so NOTHING here could ever be priced - the sleeve was a dead end. The walk prices
        // any amount that is worth at least a wei, and such an amount exists inside the supply:
        address parent10 = roundManager.canonical(10);
        uint256 oneWeiWorth = bidDeployer.parentForEthValue(10, 1);
        emit log_named_uint("generation-10 tokens worth one wei", oneWeiWorth);
        assertLt(oneWeiWorth, IERC20(parent10).totalSupply(), "a wei of value exists in generation 10's supply");
        (uint256 deep,) = bidDeployer.ethValueOfParent(10, 4 * oneWeiWorth);
        assertGt(deep, 0, "and the conversion prices it, eleven links down");

        // What stops the keeper this deep is now the POOL, not the arithmetic: a link whose whole
        // market cap is a fraction of a microether (5 ETH genesis x ~6.5% per link, eleven times)
        // cannot absorb a wei-sized bid inside the 2% size cap. That is an economic limit with a
        // named error, not a permanent stranding of the ledger.
        address keeper = address(0xC0FFEE);
        _seedSleeve(11);
        uint256 amount11 = 4 * oneWeiWorth;
        deal(parent10, keeper, amount11);
        vm.startPrank(keeper);
        IERC20(parent10).approve(address(bidDeployer), amount11);
        vm.expectRevert(abi.encodeWithSelector(BidDeployer.SizeCapExceeded.selector, amount11, bidDeployer.bidCap(11)));
        bidDeployer.deployAncestor(11, amount11);
        vm.stopPrank();
        _assertSolvent();
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

    /// @dev Seed generation `j`'s ETH sleeve, hand a keeper the parent tokens it needs and run
    /// the keeper path. Returns the ETH the keeper was paid.
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
        uint256 before = keeper.balance;
        vm.startPrank(keeper);
        IERC20(parent).approve(address(bidDeployer), amount);
        _deployAncestor(j, amount);
        vm.stopPrank();
        paid = keeper.balance - before;
    }

    /// @dev Give generation `j` an ETH sleeve to be paid out of. A continuation-free stack earns
    /// these from its own genesis-pool volume; seeding is how a depth test reaches generation 11
    /// without simulating months of trading.
    function _seedSleeve(uint256 j) internal {
        uint256 seed = 10 ether;
        vm.deal(address(vault), address(vault).balance + seed);
        stdstore.target(address(vault)).sig("reinforcementEth(uint256)").with_key(j).checked_write(seed);
        stdstore.target(address(vault))
            .sig("ledgerTotal(address)")
            .with_key(address(0))
            .checked_write(vault.ledgerTotal(Currency.wrap(address(0))) + seed);
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
            _buyGenesis(0.05 ether);
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
