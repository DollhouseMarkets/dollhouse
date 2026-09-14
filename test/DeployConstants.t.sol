// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";

/// @notice The stack as it will actually be deployed: every number here is the LOCKED value from
/// docs/DEPLOY_CONSTANTS.md (and `script/Deploy.s.sol`), not the tranche-1 test values the rest
/// of the suite runs on. It asserts the constants are wired where they are supposed to be, and
/// then pins the resulting fee split - on a genesis buy and on a candidate buy - to the wei.
///
/// The split is quoted in DEPLOY_CONSTANTS as shares of the WHOLE protocol fee: developer 20%,
/// creator 40% (on a candidate trade: 20% to the candidate's creator + 20% to the head's, the
/// "season" split), ancestor sleeve 20%, immediate-parent reinforcement 20%. The contract takes
/// the last two as shares of what is left after dev and creator, hence 5000/5000 of a 40%
/// remainder. This test is the proof that the two descriptions are the same thing.
contract DeployConstantsTest is RoundTestBase {
    // ---- docs/DEPLOY_CONSTANTS.md, transcribed exactly ----
    uint256 internal constant D_HOP_FEE_PPM = 750; // 7.5 bps, parent side, per hop
    uint256 internal constant D_PROTOCOL_FEE_PPM = 10_000; // 1% = 100 bps, ETH edge only
    uint256 internal constant D_DEV_BPS = 2_000;
    uint256 internal constant D_CREATOR_BPS = 4_000;
    uint256 internal constant D_ANCESTOR_OF_FEE_BPS = 2_000;
    uint256 internal constant D_REINFORCE_OF_FEE_BPS = 2_000;
    uint256 internal constant D_GENESIS_UNIT = 1000 ether;
    /// @dev Bond (design decision 2026-09-13): flat on mainnet, base == max, so `bondFor` clamps
    /// to the same amount at every depth regardless of `BOND_DOUBLING_EVERY`.
    uint256 internal constant D_BOND_WEI = 0.008 ether;
    uint256 internal constant D_BOND_DOUBLING_EVERY = 4;
    uint256 internal constant D_BOND_MAX_WEI = 0.008 ether;
    uint256 internal constant D_H_FRAC_WAD = 1.5e15; // 0.15% of parent supply
    uint64 internal constant D_TRADING_S = 900;
    uint64 internal constant D_SUBMIT_S = 300;
    /// @dev Developer allocation: 3% of the GENESIS supply, 1-month cliff, 12-month linear.
    uint256 internal constant D_DEV_ALLOCATION_BPS = 300;
    uint64 internal constant D_VESTING_CLIFF_S = 30 days;
    uint64 internal constant D_VESTING_DURATION_S = 365 days;
    /// @dev Steward / developer role transfer delay.
    uint64 internal constant D_ROLE_TRANSFER_DELAY = 7 days;

    uint256 internal constant BUY = 1 ether;

    function _hopFeePpm() internal pure override returns (uint256) {
        return D_HOP_FEE_PPM;
    }

    function _creatorBps() internal pure override returns (uint256) {
        return D_CREATOR_BPS;
    }

    /// @dev The ancestor/reinforce split is taken against the REMAINDER after dev and creator,
    /// which is 40% of the fee here - so 50/50 of it is 20/20 of the whole.
    function _ancestorBps() internal pure override returns (uint256) {
        return 5_000;
    }

    function _reinforceBps() internal pure override returns (uint256) {
        return 5_000;
    }

    /// @dev Mainnet bond: flat, not the tranche-1/testnet doubling schedule.
    function _bondSchedule() internal pure override returns (RoundManager.Bond memory) {
        return RoundManager.Bond({base: D_BOND_WEI, doublingEvery: D_BOND_DOUBLING_EVERY, max: D_BOND_MAX_WEI});
    }

    function setUp() public {
        _setUpFamily();
    }

    // ---------------------------------------------------------------------------------
    // the constants themselves
    // ---------------------------------------------------------------------------------

    function test_deployConstantsAreWiredWhereTheyBelong() public view {
        assertEq(hook.hopFeePpm(), D_HOP_FEE_PPM, "hop fee 750 ppm");
        assertEq(hook.PROTOCOL_FEE_PPM(), D_PROTOCOL_FEE_PPM, "protocol fee 100 bps on the ETH edge");
        assertEq(vault.DEV_BPS(), D_DEV_BPS, "developer 20%");
        assertEq(vault.CREATOR_BPS(), D_CREATOR_BPS, "creator 40%");
        assertEq(vault.ANCESTOR_BPS(), 5_000, "half the remainder to the ancestor sleeve");
        assertEq(vault.REINFORCE_BPS(), 5_000, "and half to the immediate parent");
        assertEq(factory.GENESIS_UNIT(), D_GENESIS_UNIT, "GENESIS_UNIT 1000 ETH");
        assertEq(roundManager.currentBond(), D_BOND_WEI, "bond 0.001 ETH at index 1");
        assertEq(roundManager.BOND_BASE_WEI(), D_BOND_WEI, "bond base 0.001 ETH");
        assertEq(roundManager.BOND_DOUBLING_EVERY(), D_BOND_DOUBLING_EVERY, "doubling every 4 links");
        assertEq(roundManager.BOND_MAX_WEI(), D_BOND_MAX_WEI, "bond cap 64x base");
        // review 2: a `maxIndex` of 0 is the Fenwick sleeve's own cap, not "unlimited"
        assertEq(roundManager.MAX_INDEX(), 4095, "testnet: capped only by the ancestor sleeve");
        assertEq(bidDeployer.TWAP_WINDOW(), 1800, "fast TWAP window 30 min");
        assertEq(bidDeployer.SLOW_TWAP_WINDOW(), 7 days, "slow TWAP window 7 days");
        assertEq(bidDeployer.SLOW_TWAP_MIN_COVERAGE(), 1 days, "...usable from one day of history");
        assertEq(bidDeployer.MAX_RESERVE_BPS(), 200, "2% of the sizing basis per call");
        assertEq(vault.DAILY_DRAW_BPS(), 1_000, "10% of a generation's sleeve per 24 h");
        assertEq(vault.DRAW_WINDOW(), 1 days);
        assertEq(hook.OBS_MIN_SPACING(), 120, "fast observation spacing 120 s");
        assertEq(hook.SLOW_OBS_MIN_SPACING(), 3 hours, "slow observation spacing 3 h");
        assertEq(hook.SLOW_OBS_CARDINALITY(), 64, "64 slow observations covers 8 days");
        assertEq(roundManager.sunsetDelay(), 7 days, "sunset delay 7 days");
        assertEq(roundManager.ROLE_TRANSFER_DELAY(), D_ROLE_TRANSFER_DELAY, "steward transfer delay 7 days");
        assertEq(vault.ROLE_TRANSFER_DELAY(), D_ROLE_TRANSFER_DELAY, "developer transfer delay 7 days");
        assertEq(factory.DEV_ALLOCATION_BPS(), D_DEV_ALLOCATION_BPS, "developer allocation 3% of genesis");
        assertEq(factory.VESTING_CLIFF_S(), D_VESTING_CLIFF_S, "vesting cliff 30 days");
        assertEq(factory.VESTING_DURATION_S(), D_VESTING_DURATION_S, "vesting duration 365 days");
        assertEq(factory.devAllocation(), (SUPPLY * D_DEV_ALLOCATION_BPS) / 10_000, "3% of the supply, in tokens");
        assertEq(factory.genesisTokensForSale(), SUPPLY - factory.devAllocation(), "97% goes on the curve");
        assertEq(roundManager.H_FRAC_WAD(), D_H_FRAC_WAD, "H0 = 0.15% of parent supply");
        assertEq(roundManager.durationFor(1), D_TRADING_S, "trading window 900 s");
        assertEq(factory.TICK_SPACING(), 60, "tick spacing 60");

        // MECHANISM_v3: the adaptive schedule, the closing window and the random end
        assertEq(roundManager.DURATION_SCALE_DIV(), 1, "the mainnet schedule is unscaled");
        assertEq(roundManager.BASE_TRADING_S(), 15 minutes, "D(1) = 15 min");
        assertEq(roundManager.MAX_TRADING_S(), 12 hours, "D is capped at 12 h");
        assertEq(roundManager.MIN_REGISTRATION_S(), 3 minutes, "R floor 3 min");
        assertEq(roundManager.MAX_REGISTRATION_S(), 1 hours, "R cap 1 h");
        assertEq(roundManager.LATE_ENTRY_FROM_S(), 1 hours, "late entry from 1-hour rounds up");
        assertEq(roundManager.closingWindowFor(1), 15 minutes, "closing window 15 min on a short round");
        assertEq(roundManager.closingWindowFor(13), 15 minutes, "and 15 min on a 12-hour one: W is flat");
        assertEq(roundManager.RANDOM_END_S(), 180, "the true end falls in the last 3 minutes");
        assertEq(roundManager.END_TIMEOUT(), 30 minutes, "deterministic fallback after 30 min");
        assertEq(roundManager.SUBMIT_S(), D_SUBMIT_S, "submission window 300 s");
        assertEq(hook.SCORE_SLOTS(), 36, "36 fast score slots");
        assertEq(hook.SCORE_SLOT_S(), 5, "5 seconds each");
        assertEq(hook.SCORE_RING_S(), roundManager.RANDOM_END_S(), "which is exactly the random-end span");
        assertEq(hook.SCORE_COARSE_SLOTS(), 64, "64 coarse score slots");

        // the MID curve: shares 20/25/35/20 over FDV ratios 1e-3 -> 1e-2 -> 1e-1 -> 1 -> 100
        assertEq(factory.curveSpec().length, 4, "four ranges");
        assertEq(factory.curveSpec()[0].shareWad, 0.2e18);
        assertEq(factory.curveSpec()[1].shareWad, 0.25e18);
        assertEq(factory.curveSpec()[2].shareWad, 0.35e18);
        assertEq(factory.curveSpec()[3].shareWad, 0.2e18);
        assertEq(factory.curveSpec()[0].fdvRatioLowerWad, 1e15);
        assertEq(factory.curveSpec()[3].fdvRatioUpperWad, 100e18);
    }

    /// @notice Design decision 2026-09-13: the mainnet bond is FLAT at every depth (spam
    /// resistance only), not the depth-doubling schedule the contract still supports. `bondMax ==
    /// bondBase` makes `bondFor` clamp to the same amount everywhere, including at indices deep
    /// enough that `bondBase << (index / doublingEvery)` would otherwise overflow the shift.
    function test_mainnetBondIsFlatAtEveryDepth() public view {
        assertEq(roundManager.bondFor(0), D_BOND_WEI, "index 0");
        assertEq(roundManager.bondFor(4), D_BOND_WEI, "index 4");
        assertEq(roundManager.bondFor(24), D_BOND_WEI, "index 24");
        assertEq(roundManager.bondFor(4095), D_BOND_WEI, "index 4095, the sleeve's own cap");
    }

    // ---------------------------------------------------------------------------------
    // the split, to the wei
    // ---------------------------------------------------------------------------------

    /// @notice One genesis buy of exactly 1 ETH: the ETH edge charges 1% and the deploy split
    /// puts 20 / 40 / 20 / 20 of it into dev / creator / sleeve / reinforcement, exactly.
    function test_genesisBuySplitsTheFeeExactly() public {
        uint256 fee = (BUY * D_PROTOCOL_FEE_PPM) / PPM;
        assertEq(fee, 0.01 ether, "1% of the ETH leg");

        uint256 devBefore = vault.devBalance();
        vm.recordLogs();
        familyRouter.buyExactIn{value: BUY}(0, 0, address(this), 2);
        (uint256 hopFee, uint256 protocolFee, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce) =
            _ethEdgeSplit(vm.getRecordedLogs());

        assertEq(hopFee, (BUY * D_HOP_FEE_PPM) / PPM, "750 ppm hop fee on the parent (ETH) side");
        assertEq(protocolFee, fee);
        assertEq(dev, (fee * D_DEV_BPS) / 10_000, "developer 20% of the fee");
        assertEq(creator, (fee * D_CREATOR_BPS) / 10_000, "creator 40% of the fee");
        assertEq(sleeve, (fee * D_ANCESTOR_OF_FEE_BPS) / 10_000, "ancestor sleeve 20% of the fee");
        assertEq(reinforce, (fee * D_REINFORCE_OF_FEE_BPS) / 10_000, "reinforcement 20% of the fee");
        assertEq(dev + creator + sleeve + reinforce, fee, "and the four are the whole fee");

        // the ledgers agree with the event
        assertEq(vault.devBalance() - devBefore, dev, "dev ledger");
        assertEq(vault.creatorBalance(address(token)), creator, "the genesis creator takes the whole creator share");
        assertEq(vault.reinforcementEth(0), reinforce, "genesis is its own M = 0 reinforcement target");
        assertEq(vault.reinforcementBalance(address(0)), hopFee, "the hop fee is ETH under the genesis pool");
        _assertSolvent();
    }

    /// @notice One candidate buy of exactly 1 ETH: identical totals, except that the creator
    /// share is the 20/20 season split - half to the candidate's creator, half to the creator of
    /// the head it is challenging.
    function test_candidateBuySplitsTheSeasonShareExactly() public {
        _buyGenesis(1 ether); // give the genesis pool a price history to trade against
        address candidateCreator = address(0xA11CE);
        Cand memory c = _registerCandidate(candidateCreator, "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        address headCreator = roundManager.creatorOf(roundManager.canonical(0));
        uint256 headCreatorBefore = vault.creatorBalance(roundManager.canonical(0));
        uint256 devBefore = vault.devBalance();
        uint256 reinforceBefore = vault.reinforcementEth(0);

        uint256 fee = (BUY * D_PROTOCOL_FEE_PPM) / PPM;
        vm.recordLogs();
        familyRouter.buyCandidate{value: BUY}(c.id, 0, address(this), 4);
        (, uint256 protocolFee, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce) =
            _ethEdgeSplit(vm.getRecordedLogs());

        assertEq(protocolFee, fee, "the ETH edge is charged once, on the genesis leg");
        assertEq(dev, (fee * D_DEV_BPS) / 10_000, "developer 20%");
        assertEq(creator, (fee * D_CREATOR_BPS) / 10_000, "creator 40%");
        assertEq(sleeve, (fee * D_ANCESTOR_OF_FEE_BPS) / 10_000, "ancestor sleeve 20%");
        assertEq(reinforce, (fee * D_REINFORCE_OF_FEE_BPS) / 10_000, "reinforcement 20%");

        // the season split: 20% of the fee each
        uint256 season = (fee * 2_000) / 10_000;
        assertEq(vault.creatorBalance(c.token), season, "20% of the fee to the candidate's creator");
        assertEq(
            vault.creatorBalance(roundManager.canonical(0)) - headCreatorBefore,
            season,
            "20% of the fee to the head's creator"
        );
        assertEq(season + season, creator, "and the two halves are the whole creator share");
        assertEq(vault.devBalance() - devBefore, dev, "dev ledger");
        assertEq(vault.reinforcementEth(0) - reinforceBefore, reinforce, "M = headIndex = 0 on a candidate trade");
        assertEq(vault.creatorRecipient(c.token), candidateCreator);
        assertTrue(headCreator != candidateCreator, "two distinct creators");
        _assertSolvent();
    }

    /// @dev The single ETH-edge {FeeVault.FeeSplit} of the route just executed.
    function _ethEdgeSplit(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 hopFee, uint256 protocolFee, uint256 dev, uint256 creator, uint256 sleeve, uint256 reinforce)
    {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != FeeVault.FeeSplit.selector) continue;
            (uint256 h, uint256 p,, bool attributed, uint256 d, uint256 cr, uint256 sl, uint256 re) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, bool, uint256, uint256, uint256, uint256));
            if (p == 0) continue;
            assertTrue(attributed, "the canonical router attributed the ETH edge");
            (hopFee, protocolFee, dev, creator, sleeve, reinforce) = (h, p, d, cr, sl, re);
            seen++;
        }
        assertEq(seen, 1, "exactly one ETH-edge fee per route");
    }
}
