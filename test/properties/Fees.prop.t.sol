// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {FamilyHook} from "../../contracts/FamilyHook.sol";

/// @dev The FeeVault's own split event, decoded. Shared by the two fixtures below.
struct Split {
    address currency;
    uint256 hopFee;
    uint256 protocolFee;
    uint256 terminalIndex;
    bool attributed;
    uint256 dev;
    uint256 creator;
    uint256 sleeve;
    uint256 reinforce;
}

/// @dev Everything both fixtures need to read the vault's split events back.
abstract contract FeesPropBase is RoundTestBase {
    /// @dev The published snipe schedule, with the subtraction taken at true floor division.
    function _snipePpmSpec(uint256 dt) internal view returns (uint256) {
        uint256 s = hook.SNIPE_S();
        if (dt >= s) return 0;
        uint256 start = hook.SNIPE_START_PPM();
        uint256 drop = start - hook.SNIPE_END_PPM();
        uint256 fall = (drop * dt) / s;
        if ((drop * dt) % s != 0) fall += 1; // floor of a negative term is a ceiling of its size
        return start - fall;
    }

    /// @dev Every `FeeSplit` the vault emitted since the last {vm.recordLogs}, in order.
    function _splits() internal returns (Split[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == FeeVault.FeeSplit.selector) n++;
        }
        out = new Split[](n);
        uint256 k;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != FeeVault.FeeSplit.selector) continue;
            (
                uint256 hopFee,
                uint256 protocolFee,
                uint256 terminalIndex,
                bool attributed,
                uint256 dev,
                uint256 creator,
                uint256 sleeve,
                uint256 reinforce
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool, uint256, uint256, uint256, uint256));
            out[k++] = Split({
                currency: address(uint160(uint256(logs[i].topics[1]))),
                hopFee: hopFee,
                protocolFee: protocolFee,
                terminalIndex: terminalIndex,
                attributed: attributed,
                dev: dev,
                creator: creator,
                sleeve: sleeve,
                reinforce: reinforce
            });
        }
    }
}

/// @notice Property tests for the fee machine (docs/spec/PROPERTIES.md sec.3.2), tier F. The
/// stack under test runs the harness split (dev 20% / creator 10% / sleeve / reinforcement) and
/// a 1000 ppm hop fee; every assertion is written against the constants the stack reports, never
/// against a literal, except the 1% edge fee itself.
///
/// THE EDGE IS $DOLL, not native ETH, and it is canonical index 0 - a token this
/// protocol adopted and owns no pool for. The EDGE POOL is link one, and "traversing the edge"
/// means traversing that pool.
contract FeesPropTest is FeesPropBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal link2;
    address internal link3;

    function setUp() public {
        _setUpEdge();
        link2 = _runWinningRound(1, WINNING_BUY).token;
        link3 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 3, "three links of ours: #1 (the edge), #2, #3");
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
        IERC20(link3).approve(address(familyRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // FEE-01 / FEE-02
    // ---------------------------------------------------------------------------------

    /// @notice FEE-01: a route of any length `L` that traverses an EDGE
    /// POOL once pays exactly one protocol fee of `PROTOCOL_FEE_PPM = 10_000` ppm on the
    /// $DOLL-side amount of that leg, and zero protocol fee on the other `L-1` legs. The old
    /// statement named the ETH edge; the edge is now link one, whose parent is canonical index 0.
    function testFuzz_FEE01_oneEdgeFeePerTraversal(uint256 dollIn, uint256 targetSeed) public {
        dollIn = bound(dollIn, 0.001 ether, 20 ether);
        uint256 target = bound(targetSeed, 1, 3);

        vm.recordLogs();
        familyRouter.buyExactIn(target, dollIn, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        uint256 edgeFees;
        uint256 total;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edgeFees++;
            total += splits[i].protocolFee;
            assertEq(splits[i].currency, address(doll), "the edge fee is charged in the edge currency");
        }
        assertEq(edgeFees, 1, "exactly one protocol fee, whatever the route length");
        assertEq(total, (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the $DOLL-side amount of the edge leg");
        _assertNoEth();
    }

    /// @notice FEE-01: the protocol-fee total at a given $DOLL notional is identical for every
    /// route length, in both directions.
    function testFuzz_FEE01_theEdgeFeeDoesNotDependOnDepth(uint256 dollIn) public {
        dollIn = bound(dollIn, 0.001 ether, 5 ether);

        uint256 atOne = _protocolFeeOfBuy(1, dollIn);
        uint256 atTwo = _protocolFeeOfBuy(2, dollIn);
        uint256 atThree = _protocolFeeOfBuy(3, dollIn);
        assertEq(atTwo, atOne, "one hop deeper pays the same edge fee");
        assertEq(atThree, atOne, "two hops deeper pays the same edge fee");

        // the reverse direction charges its 1% on the $DOLL the edge leg produces
        uint256 amount = IERC20(link3).balanceOf(address(this)) / 4;
        vm.recordLogs();
        uint256 dollOut = familyRouter.sellExactIn(3, amount, 0, address(this), 3);
        Split[] memory splits = _splits();
        uint256 edges;
        uint256 sold;
        uint256 hopOnTheEdge;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edges++;
            sold = splits[i].protocolFee;
            hopOnTheEdge = splits[i].hopFee;
        }
        assertEq(edges, 1, "one traversal, one fee, selling too");
        uint256 gross = dollOut + sold + hopOnTheEdge;
        assertApproxEqAbs(sold, (gross * hook.PROTOCOL_FEE_PPM()) / PPM, 1, "1% of the gross $DOLL the pool paid");
    }

    /// @notice FEE-02: every family pool charges `hopFeePpm` on the parent side of every swap,
    /// the edge leg included, so a full-line route to index `L` pays one edge fee plus exactly
    /// `L` hop fees, each a fraction of its OWN leg's parent amount.
    function testFuzz_FEE02_everyLegPaysItsOwnHopFee(uint256 dollIn, uint256 targetSeed) public {
        dollIn = bound(dollIn, 0.01 ether, 20 ether);
        uint256 target = bound(targetSeed, 1, 3);

        vm.recordLogs();
        familyRouter.buyExactIn(target, dollIn, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        uint256 legs;
        for (uint256 i = 0; i < splits.length; i++) {
            assertGt(splits[i].hopFee, 0, "every leg pays a hop fee on its own parent side");
            legs++;
        }
        assertEq(legs, target, "one hop fee per leg");
        // the edge leg's own hop fee is a fraction of the $DOLL the trader paid in
        assertEq(splits[0].hopFee, (dollIn * _hopFeePpm()) / PPM, "the edge leg's hop fee is a fraction of the $DOLL");
        assertEq(splits[0].currency, address(doll), "and it is charged in the edge currency");
    }

    // ---------------------------------------------------------------------------------
    // FEE-04 / FEE-05
    // ---------------------------------------------------------------------------------

    /// @notice FEE-04: the snipe tax on a candidate pool at time `t` is `SNIPE_START_PPM +
    /// (SNIPE_END_PPM - SNIPE_START_PPM)*(t - tradingStart)/SNIPE_S` for
    /// `t in [tradingStart, tradingStart + 3 s)` and exactly 0 afterwards.
    function testFuzz_FEE04_theSnipeScheduleIsLinearOverThreeSeconds(uint256 dtSeed, uint256 amountSeed) public {
        uint256 dt = bound(dtSeed, 0, 6);
        uint256 amount = bound(amountSeed, 1e18, 100_000e18);

        Cand memory c = _registerCandidate(address(0xA11CE), "S");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + dt);

        uint256 expectedSnipePpm = _snipePpmSpec(dt);
        vm.recordLogs();
        _tradeCandidate(c, true, amount);
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one pool, one accrual");
        assertEq(splits[0].protocolFee, 0, "no protocol fee off the edge");
        uint256 expected = (amount * _hopFeePpm()) / PPM + (amount * expectedSnipePpm) / PPM;
        assertEq(splits[0].hopFee, expected, "hop fee plus the scheduled snipe tax");
        if (dt >= hook.SNIPE_S()) assertEq(expectedSnipePpm, 0, "the window is three seconds long");
    }

    /// @notice FEE-04: a canonical pool whose snipe window closed long ago is never sniped again,
    /// at any time; the edge pool keeps charging its 1% and nothing else.
    function testFuzz_FEE04_asettledEdgePoolIsNeverSnipedAgain(uint256 dollIn, uint256 warpSeed) public {
        dollIn = bound(dollIn, 0.001 ether, 10 ether);
        vm.warp(vm.getBlockTimestamp() + bound(warpSeed, 0, 400 days));

        vm.recordLogs();
        familyRouter.buyExactIn(1, dollIn, 0, address(this), 1);
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one leg");
        assertEq(splits[0].hopFee, (dollIn * _hopFeePpm()) / PPM, "the hop fee alone, never a snipe tax");
        assertEq(splits[0].protocolFee, (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM, "and the 1% edge fee");
    }

    /// @notice FEE-05: for a fixed parent-side gross amount the fee is `gross * rate` on both
    /// pool sides and in both swap modes - the hook grosses the pool's cost up by `1/(1-rate)`
    /// whenever it is handed the pool's side. Tolerance: one wei of integer division.
    function testFuzz_FEE05_theFeeIsAlwaysTheRateOfTheGross(uint256 dollIn, uint256 outSeed) public {
        dollIn = bound(dollIn, 0.01 ether, 10 ether);
        uint256 rate = _hopFeePpm() + hook.PROTOCOL_FEE_PPM();

        // exact-IN buy: the trader's gross is exactly what was pulled, and each rate is applied
        // to it independently (so the total is the sum of two floors, never a floor of the sum)
        uint256 before = _feeVaultEdge();
        _swap(swapRouter, true, -int256(dollIn), "");
        uint256 feeIn = _feeVaultEdge() - before;
        assertEq(
            feeIn,
            (dollIn * _hopFeePpm()) / PPM + (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM,
            "exact-in: the rate of what the trader paid"
        );
        assertApproxEqAbs(feeIn, (dollIn * rate) / PPM, 1, "...to within one wei of the combined rate");

        // exact-OUT sell: the pool pays the trader plus the fee, and the fee is the rate of that
        // gross - not `rate/(1+rate)` of the receipt
        uint256 tokens = IERC20(address(token)).balanceOf(address(this));
        assertGt(tokens, 0, "holding link one to sell");
        uint256 wanted = bound(outSeed, 1e12, dollIn / 4 + 1e12);
        before = _feeVaultEdge();
        uint256 dollBefore = doll.balanceOf(address(this));
        _swap(swapRouter, false, int256(wanted), "");
        uint256 feeOut = _feeVaultEdge() - before;
        uint256 receipt = doll.balanceOf(address(this)) - dollBefore;
        uint256 gross = receipt + feeOut;
        assertEq(receipt, wanted, "the exact-output leg delivered what was asked");
        assertApproxEqAbs(feeOut, (gross * rate) / PPM, 1, "exact-out: the rate of the GROSS the pool paid");
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // FEE-08 / FEE-12
    // ---------------------------------------------------------------------------------

    /// @notice FEE-08: for every swap, `dev + creator + coCredit + sleeve + reinforce ==
    /// protocolFee` and `reinforcement[parent] == hopFee + snipeFee`, with no other ledger
    /// changed and no wei created or destroyed. Currency-agnostic: the ledger is the vault's
    /// `EDGE`, whatever that token is.
    function testFuzz_FEE08_theProtocolFeeIsConserved(uint256 dollIn, uint256 targetSeed) public {
        dollIn = bound(dollIn, 0.001 ether, 20 ether);
        uint256 target = bound(targetSeed, 1, 3);

        Currency edgeCurrency = vault.EDGE();
        uint256 devBefore = vault.devBalance();
        uint256 ledgerBefore = vault.ledgerTotal(edgeCurrency);
        uint256 reinforceEdgeBefore = vault.reinforcementEdge(target - 1);
        uint256 hopPotBefore = vault.reinforcementBalance(address(doll));
        uint256 creatorBefore = vault.creatorBalance(roundManager.canonical(target));
        uint256 sleeveBefore = _sleeveTotal();

        vm.recordLogs();
        familyRouter.buyExactIn(target, dollIn, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        Split memory edge = splits[0];
        assertEq(edge.currency, address(doll), "the edge leg is the first accrual");
        assertGt(edge.protocolFee, 0, "an edge fee was charged");
        assertEq(
            edge.dev + edge.creator + edge.sleeve + edge.reinforce, edge.protocolFee, "the four buckets are the fee"
        );

        // and every bucket landed where the event said it did
        assertEq(vault.devBalance() - devBefore, edge.dev, "dev ledger");
        assertEq(vault.creatorBalance(roundManager.canonical(target)) - creatorBefore, edge.creator, "creator ledger");
        assertEq(
            vault.reinforcementEdge(target - 1) - reinforceEdgeBefore, edge.reinforce, "immediate-parent reinforcement"
        );
        assertApproxEqAbs(_sleeveTotal() - sleeveBefore, edge.sleeve, edge.sleeve / 1e6 + 4, "ancestor sleeve");
        assertLe(_sleeveTotal() - sleeveBefore, edge.sleeve, "the sleeve is never over-credited");
        assertEq(vault.reinforcementBalance(address(doll)) - hopPotBefore, edge.hopFee, "hop fee to the parent's pot");
        assertEq(
            vault.ledgerTotal(edgeCurrency) - ledgerBefore,
            edge.hopFee + edge.protocolFee,
            "the edge ledger total is the fee"
        );
        assertEq(vault.ledgerTotal(edgeCurrency), vault.holdings(edgeCurrency), "and it is fully backed");
        _assertNoEth();
    }

    /// @notice FEE-12: an unattributed swap credits `creator = 0` and `M = 0`, so its whole
    /// flywheel share lands on canonical index 0 - the adopted genesis; the developer's 20% is
    /// paid on every protocol fee.
    function testFuzz_FEE12_unattributedFeesFallBackToIndexZero(uint256 dollIn) public {
        dollIn = bound(dollIn, 0.001 ether, 20 ether);

        uint256 devBefore = vault.devBalance();
        uint256 creator2Before = vault.creatorBalance(link2);
        uint256 creator3Before = vault.creatorBalance(link3);
        uint256 creator1Before = vault.creatorBalance(address(token));
        uint256 genesisSleeveBefore = vault.claimableAncestor(0);
        uint256 reinforceZeroBefore = vault.reinforcementEdge(0);

        // a copycat caller: the hook refuses to trust its hookData, whatever it claims
        vm.recordLogs();
        PoolKey memory edgeKey = roundManager.poolKeyOf(1);
        plainRouter.swap(
            edgeKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(dollIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(3))
        );
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one accrual");
        assertTrue(!splits[0].attributed, "the fee is unattributed");
        assertEq(splits[0].creator, 0, "no creator share");
        assertEq(vault.creatorBalance(link2), creator2Before, "nobody's creator ledger moved");
        assertEq(vault.creatorBalance(link3), creator3Before, "not even the claimed one");
        assertEq(vault.creatorBalance(address(token)), creator1Before, "nor link one's creator's");
        assertEq(splits[0].dev, (splits[0].protocolFee * vault.DEV_BPS()) / 10_000, "the developer is always paid");
        assertEq(vault.devBalance() - devBefore, splits[0].dev, "into the dev ledger");
        assertGt(vault.claimableAncestor(0) - genesisSleeveBefore, 0, "the whole sleeve lands on index 0");
        assertEq(
            vault.reinforcementEdge(0) - reinforceZeroBefore,
            splits[0].reinforce,
            "M = 0, so the reinforcement share follows index 0 too"
        );
    }

    // ---------------------------------------------------------------------------------
    // spec gap 1: a $DOLL -> ... -> $DOLL round trip inside one `swapPath`
    // ---------------------------------------------------------------------------------

    /// @notice FEE-01 (spec gap 1): what a round trip across the EDGE POOL inside ONE `swapPath`
    /// pays. The property assumes one fee per TRAVERSAL, i.e. two for a round trip.
    function testFuzz_FEE01_aRoundTripPaysOneFeePerTraversal(uint256 dollIn) public {
        dollIn = bound(dollIn, 0.01 ether, 5 ether);
        uint256[] memory path = new uint256[](3);
        path[0] = 0;
        path[1] = 1;
        path[2] = 0;

        vm.recordLogs();
        familyRouter.swapPath(path, dollIn, 0, address(this), 2);
        Split[] memory splits = _splits();

        uint256 edges;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee != 0) edges++;
        }
        assertEq(edges, 2, "one protocol fee per traversal of the edge pool");
        assertEq(splits[0].protocolFee, (dollIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% going in");
        _assertNoEth();
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _protocolFeeOfBuy(uint256 target, uint256 dollIn) internal returns (uint256 fee) {
        vm.recordLogs();
        familyRouter.buyExactIn(target, dollIn, 0, address(this), target + 1);
        Split[] memory splits = _splits();
        for (uint256 i = 0; i < splits.length; i++) {
            fee += splits[i].protocolFee;
        }
    }

    /// @dev Everything the ancestor tree can ever pay out, across the whole chain.
    function _sleeveTotal() internal view returns (uint256 sum) {
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            sum += vault.claimableAncestor(i);
        }
    }
}

/// @notice FEE-06, THE LOAD-BEARING EXCLUSION. A ROUND-ONE pool is both an EDGE pool (1%)
/// and a freshly opened candidate pool (99% decaying over {FamilyHook.SNIPE_S}), and the sum of
/// those rates exceeds 100%, which exact-input accounting cannot express. The two are therefore
/// mutually exclusive IN TIME rather than by pool class: the edge fee is suppressed for exactly
/// as long as the snipe tax runs.
///
/// This fixture stops at {_setUpFamily}, so the head is canonical index 0 - the adopted genesis -
/// and every candidate it registers is an edge pool with a live snipe window.
contract FeesEdgeWindowPropTest is FeesPropBase {
    function setUp() public {
        _setUpFamily();
    }

    /// @notice FEE-06: at every instant of a round-one pool's life, `protocolPpm * snipePpm == 0`
    /// and the summed parent-side rates stay strictly under 100%. The fee the vault books is
    /// exactly the schedule, at every one of those instants.
    function testFuzz_FEE06_theEdgeFeeIsSuppressedWhileTheSnipeTaxRuns(uint256 dtSeed, uint256 amountSeed) public {
        uint256 dt = bound(dtSeed, 0, 10);
        uint256 amount = bound(amountSeed, 1e18, 100_000e18);

        Cand memory c = _registerCandidate(address(0xA11CE), "EDGE");
        assertTrue(hook.poolInfo(c.poolId).isEdge, "round one launches against index 0: an edge pool");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(uint256(tradingStart) + dt);

        uint256 snipePpm = _snipePpmSpec(dt);
        uint256 protocolPpm = snipePpm == 0 ? hook.PROTOCOL_FEE_PPM() : 0;
        assertLt(_hopFeePpm() + protocolPpm + snipePpm, PPM, "the summed parent-side rates stay under 100%");

        vm.recordLogs();
        _tradeCandidate(c, true, amount);
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one pool, one accrual");
        assertEq(splits[0].currency, address(doll), "an edge pool is quoted in the edge currency");
        assertEq(splits[0].protocolFee, (amount * protocolPpm) / PPM, "the edge fee waits for the window to close");
        assertEq(
            splits[0].hopFee,
            (amount * _hopFeePpm()) / PPM + (amount * snipePpm) / PPM,
            "hop fee plus the scheduled snipe tax"
        );
        assertTrue(splits[0].protocolFee == 0 || snipePpm == 0, "never both rates at once");
        if (dt < hook.SNIPE_S()) {
            assertEq(splits[0].protocolFee, 0, "no edge fee inside the snipe window");
            assertGt(snipePpm, 0, "but the snipe tax is running");
        } else {
            assertEq(splits[0].protocolFee, amount / 100, "the 1% edge fee starts when the window closes");
        }
        _assertNoEth();
    }

    /// @notice FEE-06: the exact-OUTPUT path is the one the summed rates would actually break -
    /// the gross-up `poolCost / (1 - rate)` has no finite answer at 100% - so it must price at
    /// the very first instant of a round-one pool.
    function testFuzz_FEE06_exactOutputPricesThroughTheWholeWindow(uint256 dtSeed, uint256 outSeed) public {
        uint256 dt = bound(dtSeed, 0, 10);
        uint256 tokensOut = bound(outSeed, 1e15, 10_000e18);

        Cand memory c = _registerCandidate(address(0xA11CE), "EDGE");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(uint256(tradingStart) + dt);

        bool zeroForOne = !c.tokenIsCurrency0;
        uint256 before = IERC20(c.token).balanceOf(address(this));
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(tokensOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(IERC20(c.token).balanceOf(address(this)) - before, tokensOut, "exact output honored at every instant");
        _assertNoEth();
    }
}
