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

/// @notice Property tests for the fee machine (docs/spec/PROPERTIES.md sec.3.2), tier F. The
/// stack under test runs the harness split (dev 20% / creator 10% / sleeve / reinforcement) and
/// a 1000 ppm hop fee; every assertion is written against the constants the stack reports, never
/// against a literal, except the 1% edge fee itself.
contract FeesPropTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    /// @dev The FeeVault's own split event, decoded.
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

    address internal link1;
    address internal link2;

    function setUp() public {
        _setUpFamily();
        _buyGenesis(5 ether);
        link1 = _runWinningRound(1, WINNING_BUY).token;
        link2 = _runWinningRound(1, WINNING_BUY).token;
        assertEq(roundManager.headIndex(), 2, "three links: genesis, #1, #2");
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        IERC20(link2).approve(address(familyRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // FEE-01 / FEE-02
    // ---------------------------------------------------------------------------------

    /// @notice FEE-01: a route of any length `L` that traverses the ETH edge once pays exactly
    /// one protocol fee of `PROTOCOL_FEE_PPM = 10_000` ppm on the ETH-side amount of the genesis
    /// leg, and zero protocol fee on the other `L-1` legs.
    function testFuzz_FEE01_oneEdgeFeePerTraversal(uint256 ethIn, uint256 targetSeed) public {
        ethIn = bound(ethIn, 0.001 ether, 20 ether);
        uint256 target = bound(targetSeed, 0, 2);

        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(target, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        uint256 edgeFees;
        uint256 total;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee == 0) continue;
            edgeFees++;
            total += splits[i].protocolFee;
            assertEq(splits[i].currency, address(0), "the edge fee is charged in ETH");
        }
        assertEq(edgeFees, 1, "exactly one protocol fee, whatever the route length");
        assertEq(total, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% of the ETH-side amount of the genesis leg");
    }

    /// @notice FEE-01: the protocol-fee total at a given ETH notional is identical for every
    /// route length, in both directions.
    function testFuzz_FEE01_theEdgeFeeDoesNotDependOnDepth(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.001 ether, 5 ether);

        uint256 atZero = _protocolFeeOfBuy(0, ethIn);
        uint256 atOne = _protocolFeeOfBuy(1, ethIn);
        uint256 atTwo = _protocolFeeOfBuy(2, ethIn);
        assertEq(atOne, atZero, "one hop deeper pays the same edge fee");
        assertEq(atTwo, atZero, "two hops deeper pays the same edge fee");

        // the reverse direction charges its 1% on the ETH the genesis leg produces
        uint256 amount = IERC20(link2).balanceOf(address(this)) / 4;
        vm.recordLogs();
        uint256 ethOut = familyRouter.sellExactIn(2, amount, 0, address(this), 3);
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
        uint256 gross = ethOut + sold + hopOnTheEdge;
        assertApproxEqAbs(sold, (gross * hook.PROTOCOL_FEE_PPM()) / PPM, 1, "1% of the gross ETH the pool paid");
    }

    /// @notice FEE-02: every family pool charges `hopFeePpm` on the parent side of every swap,
    /// genesis leg included, so a full-line route to index `L` pays one edge fee plus exactly
    /// `L + 1` hop fees, each a fraction of its OWN leg's parent amount.
    function testFuzz_FEE02_everyLegPaysItsOwnHopFee(uint256 ethIn, uint256 targetSeed) public {
        ethIn = bound(ethIn, 0.01 ether, 20 ether);
        uint256 target = bound(targetSeed, 0, 2);

        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(target, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        uint256 legs;
        for (uint256 i = 0; i < splits.length; i++) {
            assertGt(splits[i].hopFee, 0, "every leg pays a hop fee on its own parent side");
            legs++;
        }
        assertEq(legs, target + 1, "one hop fee per leg");
        // the genesis leg's own hop fee is a fraction of the ETH the trader paid in
        assertEq(splits[0].hopFee, (ethIn * _hopFeePpm()) / PPM, "the ETH leg's hop fee is a fraction of the ETH in");
        assertEq(splits[0].currency, address(0), "and it is charged in ETH");
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
        assertEq(splits[0].protocolFee, 0, "no protocol fee off the ETH edge");
        uint256 expected = (amount * _hopFeePpm()) / PPM + (amount * expectedSnipePpm) / PPM;
        assertEq(splits[0].hopFee, expected, "hop fee plus the scheduled snipe tax");
        if (dt >= hook.SNIPE_S()) assertEq(expectedSnipePpm, 0, "the window is three seconds long");
    }

    /// @notice FEE-04: the genesis pool is never sniped, at any time.
    function testFuzz_FEE04_genesisIsNeverSniped(uint256 ethIn, uint256 warpSeed) public {
        ethIn = bound(ethIn, 0.001 ether, 10 ether);
        vm.warp(vm.getBlockTimestamp() + bound(warpSeed, 0, 400 days));

        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(0, 0, address(this), 1);
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one leg");
        assertEq(splits[0].hopFee, (ethIn * _hopFeePpm()) / PPM, "the hop fee alone, never a snipe tax");
        assertEq(splits[0].protocolFee, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "and the 1% edge fee");
    }

    /// @notice FEE-05: for a fixed parent-side gross amount the fee is `gross * rate` on both
    /// pool sides and in both swap modes - the hook grosses the pool's cost up by `1/(1-rate)`
    /// whenever it is handed the pool's side. Tolerance: one wei of integer division.
    function testFuzz_FEE05_theFeeIsAlwaysTheRateOfTheGross(uint256 ethIn, uint256 outSeed) public {
        ethIn = bound(ethIn, 0.01 ether, 10 ether);
        uint256 rate = _hopFeePpm() + hook.PROTOCOL_FEE_PPM();

        // exact-IN buy: the trader's gross is exactly `msg.value`, and each rate is applied to
        // it independently (so the total is the sum of two floors, never a floor of the sum)
        uint256 before = _feeVaultEth();
        _swap(swapRouter, true, -int256(ethIn), "");
        uint256 feeIn = _feeVaultEth() - before;
        assertEq(
            feeIn,
            (ethIn * _hopFeePpm()) / PPM + (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM,
            "exact-in: the rate of what the trader paid"
        );
        assertApproxEqAbs(feeIn, (ethIn * rate) / PPM, 1, "...to within one wei of the combined rate");

        // exact-OUT sell: the pool pays the trader plus the fee, and the fee is the rate of that
        // gross - not `rate/(1+rate)` of the receipt
        uint256 tokens = IERC20(address(token)).balanceOf(address(this));
        assertGt(tokens, 0, "holding genesis to sell");
        uint256 wanted = bound(outSeed, 1e12, ethIn / 4 + 1e12);
        before = _feeVaultEth();
        uint256 ethBefore = address(this).balance;
        _swap(swapRouter, false, int256(wanted), "");
        uint256 feeOut = _feeVaultEth() - before;
        uint256 receipt = address(this).balance - ethBefore;
        uint256 gross = receipt + feeOut;
        assertEq(receipt, wanted, "the exact-output leg delivered what was asked");
        assertApproxEqAbs(feeOut, (gross * rate) / PPM, 1, "exact-out: the rate of the GROSS the pool paid");
    }

    // ---------------------------------------------------------------------------------
    // FEE-08 / FEE-12
    // ---------------------------------------------------------------------------------

    /// @notice FEE-08: for every swap, `dev + creator + coCredit + sleeve + reinforce ==
    /// protocolFee` and `reinforcement[parent] == hopFee + snipeFee`, with no other ledger
    /// changed and no wei created or destroyed.
    function testFuzz_FEE08_theProtocolFeeIsConserved(uint256 ethIn, uint256 targetSeed) public {
        ethIn = bound(ethIn, 0.001 ether, 20 ether);
        uint256 target = bound(targetSeed, 0, 2);

        Currency eth = Currency.wrap(address(0));
        uint256 devBefore = vault.devBalance();
        uint256 ledgerBefore = vault.ledgerTotal(eth);
        uint256 reinforceEthBefore = vault.reinforcementEth(target == 0 ? 0 : target - 1);
        uint256 hopPotBefore = vault.reinforcementBalance(address(0));
        uint256 creatorBefore = vault.creatorBalance(roundManager.canonical(target));
        uint256 sleeveBefore = _sleeveTotal();

        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(target, 0, address(this), target + 1);
        Split[] memory splits = _splits();

        Split memory edge = splits[0];
        assertEq(edge.currency, address(0), "the ETH leg is the first accrual");
        assertGt(edge.protocolFee, 0, "an edge fee was charged");
        assertEq(
            edge.dev + edge.creator + edge.sleeve + edge.reinforce, edge.protocolFee, "the four buckets are the fee"
        );

        // and every bucket landed where the event said it did
        assertEq(vault.devBalance() - devBefore, edge.dev, "dev ledger");
        assertEq(vault.creatorBalance(roundManager.canonical(target)) - creatorBefore, edge.creator, "creator ledger");
        assertEq(
            vault.reinforcementEth(target == 0 ? 0 : target - 1) - reinforceEthBefore,
            edge.reinforce,
            "immediate-parent reinforcement"
        );
        assertApproxEqAbs(_sleeveTotal() - sleeveBefore, edge.sleeve, edge.sleeve / 1e6 + 4, "ancestor sleeve");
        assertLe(_sleeveTotal() - sleeveBefore, edge.sleeve, "the sleeve is never over-credited");
        assertEq(vault.reinforcementBalance(address(0)) - hopPotBefore, edge.hopFee, "hop fee to the parent's pot");
        assertEq(
            vault.ledgerTotal(eth) - ledgerBefore, edge.hopFee + edge.protocolFee, "the ETH ledger total is the fee"
        );
        assertEq(vault.ledgerTotal(eth), vault.holdings(eth), "and it is fully backed");
    }

    /// @notice FEE-12: an unattributed swap credits `creator = 0` and `M = 0`, so its whole
    /// flywheel share lands on genesis; the developer's 20% is paid on every protocol fee.
    function testFuzz_FEE12_unattributedFeesFallBackToGenesis(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.001 ether, 20 ether);

        uint256 devBefore = vault.devBalance();
        uint256 creator1Before = vault.creatorBalance(link1);
        uint256 creator2Before = vault.creatorBalance(link2);
        uint256 creator0Before = vault.creatorBalance(address(token));
        uint256 genesisSleeveBefore = vault.claimableAncestor(0);
        uint256 reinforceZeroBefore = vault.reinforcementEth(0);

        // a copycat caller: the hook refuses to trust its hookData, whatever it claims
        vm.recordLogs();
        PoolKey memory genesisKey = roundManager.poolKeyOf(0);
        plainRouter.swap{value: ethIn}(
            genesisKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(uint256(2))
        );
        Split[] memory splits = _splits();

        assertEq(splits.length, 1, "one accrual");
        assertTrue(!splits[0].attributed, "the fee is unattributed");
        assertEq(splits[0].creator, 0, "no creator share");
        assertEq(vault.creatorBalance(link1), creator1Before, "nobody's creator ledger moved");
        assertEq(vault.creatorBalance(link2), creator2Before, "not even the claimed one");
        assertEq(vault.creatorBalance(address(token)), creator0Before, "nor the genesis creator's");
        assertEq(splits[0].dev, (splits[0].protocolFee * vault.DEV_BPS()) / 10_000, "the developer is always paid");
        assertEq(vault.devBalance() - devBefore, splits[0].dev, "into the dev ledger");
        assertGt(vault.claimableAncestor(0) - genesisSleeveBefore, 0, "the whole sleeve lands on genesis");
        assertEq(
            vault.reinforcementEth(0) - reinforceZeroBefore,
            splits[0].reinforce,
            "M = 0, so the reinforcement share follows genesis too"
        );
    }

    // ---------------------------------------------------------------------------------
    // spec gap 1: an ETH -> ... -> ETH round trip inside one `swapPath`
    // ---------------------------------------------------------------------------------

    /// @notice FEE-01 (spec gap 1): what a round trip across the ETH edge inside ONE `swapPath`
    /// pays. The property assumes one fee per TRAVERSAL, i.e. two for a round trip.
    function testFuzz_FEE01_aRoundTripPaysOneFeePerTraversal(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.01 ether, 5 ether);
        uint256[] memory path = new uint256[](3);
        path[0] = familyRouter.ETH();
        path[1] = 0;
        path[2] = familyRouter.ETH();

        vm.recordLogs();
        familyRouter.swapPath{value: ethIn}(path, ethIn, 0, address(this), 2);
        Split[] memory splits = _splits();

        uint256 edges;
        for (uint256 i = 0; i < splits.length; i++) {
            if (splits[i].protocolFee != 0) edges++;
        }
        assertEq(edges, 2, "one protocol fee per traversal of the ETH edge");
        assertEq(splits[0].protocolFee, (ethIn * hook.PROTOCOL_FEE_PPM()) / PPM, "1% going in");
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _protocolFeeOfBuy(uint256 target, uint256 ethIn) internal returns (uint256 fee) {
        vm.recordLogs();
        familyRouter.buyExactIn{value: ethIn}(target, 0, address(this), target + 1);
        Split[] memory splits = _splits();
        for (uint256 i = 0; i < splits.length; i++) {
            fee += splits[i].protocolFee;
        }
    }

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

    /// @dev Everything the ancestor tree can ever pay out, across the whole chain.
    function _sleeveTotal() internal view returns (uint256 sum) {
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            sum += vault.claimableAncestor(i);
        }
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
