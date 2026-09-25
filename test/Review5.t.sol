// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {MockDoll} from "./utils/MockDoll.sol";

/// @notice The external genesis, the edge currency, and the time-based exclusion between
/// the edge fee and the opening snipe tax. The invariants this behaviour must not break are
/// exercised by the rest of the suite.
contract Review5Test is RoundTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpFamily();
    }

    // ---------------------------------------------------------------------------------
    // the external genesis is ADOPTED, once
    // ---------------------------------------------------------------------------------

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

    // ---------------------------------------------------------------------------------
    // index 0 has no pool, and every consumer knows it
    // ---------------------------------------------------------------------------------

    /// @notice `poolKeyOf(0)` is a ZERO key and every consumer that walks it either answers
    /// zero or refuses with a named error. Nothing reverts from inside the PoolManager.
    function test_indexZeroHasNoPoolAndEveryConsumerGuardsOnIt() public {
        PoolKey memory k = roundManager.poolKeyOf(0);
        assertEq(address(k.hooks), address(0), "no hook: no pool of ours");
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(0));

        assertFalse(lens.hasPool(0), "the lens says so");
        assertEq(bidDeployer.bidCap(0), 0, "and nothing can be sized against it");
        assertEq(bidDeployer.maxParentForDeploy(0), 0);

        vm.expectRevert(BidDeployer.NoPoolAtIndex.selector);
        bidDeployer.deployAncestor(0, 1e18);

        vm.expectRevert(BidDeployer.NoPoolAtIndex.selector);
        bidDeployer.deployHopPot(0);

        vm.expectRevert(BidDeployer.NoPoolAtIndex.selector);
        bidDeployer.depositExternalBid(address(doll), 1e18);

        // the conversion walk is the identity at index 0 and 1, and reads no oracle at all
        (uint256 v0,) = bidDeployer.dollValueOfParent(0, 12_345e18);
        assertEq(v0, 12_345e18, "index 0 is the edge currency itself");
        assertEq(bidDeployer.parentForDollValue(0, 12_345e18), 12_345e18);
        _assertNoEth();
    }

    /// @notice `dollValueOfParent(1, x) == x`: generation one is priced in its own parent, which
    /// IS the edge currency. No TWAP is read and nothing can make the walk fail.
    function testFuzz_dollValueOfParentIsTheIdentityAtLinkOne(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        (uint256 v, bool slowMissing) = bidDeployer.dollValueOfParent(1, amount);
        assertEq(v, amount, "the identity");
        assertFalse(slowMissing, "no oracle was consulted, so none was missing");
        assertEq(bidDeployer.parentForDollValue(1, amount), amount, "and so is the inverse");
    }

    // ---------------------------------------------------------------------------------
    // the edge fee is suppressed during the snipe window
    // ---------------------------------------------------------------------------------

    /// @notice A ROUND-ONE pool is both an EDGE pool (1%) and a freshly opened candidate pool
    /// (99% decaying over {FamilyHook.SNIPE_S}). Charging both would put the parent-side rates
    /// above 100%, which exact-input accounting cannot express and which makes the exact-output
    /// gross-up diverge. The edge fee therefore waits for the snipe tax to finish.
    ///
    /// Asserted at three instants of the same pool: `t = 0` (the 99% opening tax), `t = 1 s`
    /// (mid-decay) and `t = 4 s` (past the window, where the 1% starts). At every one of them the
    /// swap goes through, the rates sum below 100%, and the split the vault books is exactly the
    /// schedule.
    function test_edgeFeeIsSuppressedForTheWholeSnipeWindow() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "EDGE");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        assertTrue(hook.poolInfo(c.poolId).isEdge, "round one launches against index 0: an edge pool");

        _assertSnipeWindowFee(c, tradingStart, 0);
        _assertSnipeWindowFee(c, tradingStart, 1);
        _assertSnipeWindowFee(c, tradingStart, 4);
        _assertNoEth();
    }

    /// @dev One buy of the candidate `dt` seconds into its trading, with the fee split asserted
    /// against the published schedule.
    function _assertSnipeWindowFee(Cand memory c, uint64 tradingStart, uint64 dt) internal {
        vm.warp(uint256(tradingStart) + dt);
        uint256 amountIn = 1_000e18;

        uint256 snipePpm = _snipePpm(dt);
        // THE FIX: the edge fee is charged only once the snipe tax has finished
        uint256 protocolPpm = snipePpm == 0 ? PROTOCOL_FEE_PPM : 0;
        assertLt(_hopFeePpm() + protocolPpm + snipePpm, PPM, "the summed parent-side rates stay under 100%");

        uint256 potBefore = vault.reinforcementBalance(address(doll));
        uint256 devBefore = vault.devBalance();
        uint256 vaultBefore = _feeVaultEdge();

        // a plain exact-input buy of the candidate with the parent (the edge currency)
        bool zeroForOne = !c.tokenIsCurrency0;
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 hopFee = (amountIn * _hopFeePpm()) / PPM;
        uint256 snipeFee = (amountIn * snipePpm) / PPM;
        uint256 protocolFee = (amountIn * protocolPpm) / PPM;

        assertEq(_feeVaultEdge() - vaultBefore, hopFee + snipeFee + protocolFee, "the whole parent-side charge");
        assertEq(vault.reinforcementBalance(address(doll)) - potBefore, hopFee + snipeFee, "hop + snipe are the pot");
        assertEq(vault.devBalance() - devBefore, (protocolFee * vault.DEV_BPS()) / 10_000, "the protocol share only");
        if (dt < hook.SNIPE_S()) {
            assertEq(protocolFee, 0, "no edge fee inside the snipe window");
            assertGt(snipeFee, 0, "but the snipe tax is running");
        } else {
            assertEq(protocolFee, amountIn / 100, "the 1% edge fee starts when the window closes");
            assertEq(snipeFee, 0, "and the snipe tax is over");
        }
    }

    /// @notice The exact-OUTPUT path is the one the summed rates would actually break: the
    /// gross-up `poolCost / (1 - rate)` has no finite answer at 100%. At the very first instant
    /// of a round-one pool it must still price.
    function test_exactOutputBuyPricesAtTheOpeningInstantOfAnEdgePool() public {
        Cand memory c = _registerCandidate(address(0xA11CE), "EDGE");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart);

        bool zeroForOne = !c.tokenIsCurrency0;
        uint256 before = IERC20(c.token).balanceOf(address(this));
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(1_000e18),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(IERC20(c.token).balanceOf(address(this)) - before, 1_000e18, "exact output honored at t = 0");
        _assertNoEth();
    }

    /// @dev The published snipe schedule, with the subtraction taken at true floor division.
    function _snipePpm(uint64 dt) internal view returns (uint256) {
        uint256 s = hook.SNIPE_S();
        if (dt >= s) return 0;
        return hook.SNIPE_END_PPM() + ((hook.SNIPE_START_PPM() - hook.SNIPE_END_PPM()) * (s - dt)) / s;
    }

    // ---------------------------------------------------------------------------------
    // the edge bid, and a self-funded link-one deployment
    // ---------------------------------------------------------------------------------

    /// @notice {BidDeployer.deployEdgeBid} funds a bid under LINK ONE out of ALL FOUR
    /// edge-currency pots: generation 0's sleeve, generation 1's sleeve, the link-one hop pot and
    /// the forfeited-bond earmark. Each is drawn partially, and the call is worth a keeper's gas.
    function test_deployEdgeBidFundsFromAllFourPots() public {
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
        // a second generation, so generation 0 and 1 both earn a real ancestor sleeve
        _runWinningRound(1, WINNING_ABSORPTION);
        _buyLink(2, 50_000e18);

        // a failed round, so there are forfeited bonds in the earmark
        _registerCandidate(address(0xF00D), "FAIL");
        (,, uint64 submitEnd) = _roundTimes(roundManager.roundCount());
        _settleEnd();
        vm.warp(submitEnd + 1);
        roundManager.finalize();

        _warmOracles();

        uint256 sleeve0 = vault.drawableEdge(0);
        uint256 sleeve1 = vault.drawableEdge(1);
        uint256 hopPot = vault.reinforcementBalance(address(doll));
        uint256 earmark = vault.edgeBidEarmark();
        assertGt(sleeve0, 0, "generation 0 has a sleeve");
        assertGt(sleeve1, 0, "generation 1 has one too");
        assertGt(hopPot, 0, "link one collected hop fees and snipe tax");
        assertGt(earmark, 0, "and a losing bond was forfeited into the earmark");

        address keeper = address(0xC0FFEE);
        uint256 keeperBefore = doll.balanceOf(keeper);
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployEdgeBid();

        assertGt(deposited, 0, "the bid was placed");
        assertGt(doll.balanceOf(keeper) - keeperBefore, 0, "and the keeper was paid its bounty");
        // every pot gave something up: the four together funded the deposit plus the bounty
        uint256 spent = (sleeve0 - vault.drawableEdge(0)) + (sleeve1 - vault.drawableEdge(1))
            + (hopPot - vault.reinforcementBalance(address(doll))) + (earmark - vault.edgeBidEarmark());
        assertEq(spent, deposited + (doll.balanceOf(keeper) - keeperBefore), "deposit + bounty came out of the pots");
        assertEq(doll.balanceOf(address(bidDeployer)), 0, "the deployer keeps nothing");
        _assertSolvent();
        _assertNoEth();
    }

    /// @notice {BidDeployer.deployAncestor} at generation ONE needs NO KEEPER TOKENS. The parcel
    /// and the payment are the same currency, so the two transfers cancel: the vault funds the
    /// bid out of generation one's own sleeve and only the bounty leaves.
    function test_deployAncestorAtLinkOneNeedsNoKeeperTokens() public {
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
        _runWinningRound(1, WINNING_ABSORPTION);
        _buyLink(2, 50_000e18);
        _warmOracles();

        uint256 available = vault.drawableEdge(1);
        assertGt(available, 0, "generation 1 has something to deploy");
        uint256 cap = bidDeployer.bidCap(1);
        uint256 amount = available / 2;
        if (amount > cap) amount = cap;
        assertGt(amount, 0);

        address keeper = address(0xBEEF);
        assertEq(doll.balanceOf(keeper), 0, "the keeper holds nothing at all");
        vm.prank(keeper);
        uint256 deposited = bidDeployer.deployAncestor(1, amount);

        assertGt(deposited, 0, "the bid was placed out of the vault's own edge currency");
        assertGt(doll.balanceOf(keeper), 0, "and the keeper was paid the bounty, having brought nothing");
        assertEq(doll.balanceOf(address(bidDeployer)), 0, "the deployer keeps nothing");
        _assertSolvent();
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // a donation is never sweepable
    // ---------------------------------------------------------------------------------

    /// @notice An unsolicited transfer of the edge currency into the vault raises `holdings`
    /// without raising any ledger. Solvency is an INEQUALITY, so it still holds - and there is no
    /// path of any kind that pays the donation out, because every payout is bounded by a ledger.
    function testFuzz_aVaultDonationIsNeverSweepable(uint256 gift) public {
        _runWinningRound(1, WINNING_ABSORPTION);
        _useLink(1);
        _buyLink(1, 10_000e18);
        gift = bound(gift, 1, 1_000_000e18);

        Currency edge = vault.EDGE();
        uint256 ledgerBefore = vault.ledgerTotal(edge);
        uint256 holdingsBefore = vault.holdings(edge);
        uint256 devBefore = vault.devBalance();

        doll.transfer(address(vault), gift);

        assertEq(vault.ledgerTotal(edge), ledgerBefore, "a gift credits no ledger");
        assertEq(vault.holdings(edge), holdingsBefore + gift, "but the vault really does hold it");
        assertEq(vault.devBalance(), devBefore, "and nobody's claim grew");
        assertLe(vault.ledgerTotal(edge), vault.holdings(edge), "solvency is an inequality, so it still holds");

        // the developer can claim exactly what the ledger says and not one wei more
        vm.prank(developer);
        uint256 paid = vault.claimDev(developer);
        assertEq(paid, devBefore, "the claim is the ledger, never the balance");
        assertGe(vault.holdings(edge), gift, "the gift is still there, unclaimable, forever");

        // there is no sweep: the vault exposes nothing that moves an unledgered balance
        assertEq(vault.deployerCredit(), 0, "and no keeper credit was created by the gift");
        _assertNoEth();
    }
}
