// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FenwickHarness} from "./utils/FenwickHarness.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFamilyHook} from "../contracts/interfaces/IFamilyHook.sol";
import {IFeeVault} from "../contracts/interfaces/IFeeVault.sol";
import {IRandomnessSource} from "../contracts/interfaces/IRandomnessSource.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {FenwickRangeAdd} from "../contracts/libraries/FenwickRangeAdd.sol";
import {V4UnlockGuard} from "../contracts/libraries/V4UnlockGuard.sol";
import {V4UnlockGuardProbe} from "../contracts/libraries/V4UnlockGuardProbe.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @notice LATENT-RISK REGRESSIONS from the formal specification. One test per property the
/// formal pass identified, plus two schedule/ordering items that came out
/// of the same read of the specification. Every one of them was unreachable as deployed; these
/// tests pin the guarantee so that it comes from the contract rather than from the
/// discipline of its only caller.
contract Review2Test is RoundTestBase {
    /// @dev The edge currency's ledger key: $DOLL, not native ETH, which the
    /// base etches at a fixed address so the constant can still be a constant.
    Currency internal constant EDGE = Currency.wrap(DOLL_ADDRESS);
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    function setUp() public {
        _setUpEdge();
    }

    // ---------------------------------------------------------------------------------
    // Every registered pool has a published end, and an EDGE pool keeps its snipe window
    // ---------------------------------------------------------------------------------

    /// @notice There is no genesis pool: an EDGE pool is an ordinary
    /// candidate pool with a snipe window, and the protocol fee and the opening snipe tax are
    /// mutually exclusive IN TIME (the edge fee is suppressed while the snipe tax runs), not by
    /// pool class. What the hook guarantees at registration is that EVERY pool has a published
    /// end strictly after its start, so the ring freeze is universal and no pool is frozen before
    /// it opens.
    function test_everyPoolNeedsAPublishedEndAfterItsStart() public {
        PoolKey memory k = _spareKey(address(0xDEADBEEF));
        uint64 start = uint64(block.timestamp) + 60;

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, true, initSqrtPriceX96, start, 0, 0, false);

        vm.prank(address(factory));
        vm.expectRevert(IFamilyHook.BadNominalEnd.selector);
        hook.registerPool(k, true, initSqrtPriceX96, start, start, 0, false);

        // an EDGE pool with a real schedule registers, snipe window and all
        vm.prank(address(factory));
        hook.registerPool(k, true, initSqrtPriceX96, start, start + 900, 0, false);
        assertTrue(hook.poolInfo(k.toId()).registered, "an edge pool with a published end registers");
        assertTrue(hook.poolInfo(k.toId()).isEdge, "and it is marked as the edge");
        assertEq(hook.poolInfo(k.toId()).tradingStart, start, "it keeps its snipe window");

        // and so does a non-edge candidate pool
        PoolKey memory c = _spareKey(address(0xC0FFEE));
        vm.prank(address(factory));
        hook.registerPool(c, false, initSqrtPriceX96, start, start + 900, 0, false);
        assertEq(hook.poolInfo(c.toId()).tradingStart, start, "a candidate still gets one");
        assertFalse(hook.poolInfo(c.toId()).isEdge, "but no protocol fee");
    }

    // ---------------------------------------------------------------------------------
    // The drawdown bucket's "untouched" state is a flag, not a zero timestamp
    // ---------------------------------------------------------------------------------

    /// @notice First use is unchanged: an untouched generation starts with a full bucket, and a
    /// drawn one refills continuously. That is the behaviour the flag has to preserve.
    function test_theBucketBehavesIdenticallyOnFirstUseAndAfter() public {
        _accrueSleeve(2 ether);

        assertGt(vault.claimableEdge(1), 0, "generation 1 has a sleeve");
        uint256 cap = (vault.claimableEdge(1) * vault.DAILY_DRAW_BPS()) / 10_000;
        assertGt(cap, 0, "and a bucket to meter it with");
        (uint64 updatedAt, uint256 available,) = vault.drawBucket(1);
        assertEq(updatedAt, 0, "nothing has been drawn yet");
        assertEq(available, cap, "and the bucket is full");
        assertEq(vault.drawableEdge(1), cap, "which is what a keeper may take");

        vm.prank(address(bidDeployer));
        vault.consumeAncestorClaim(1, cap);
        assertEq(vault.drawableEdge(1), 0, "the bucket is spent");

        vm.warp(block.timestamp + uint256(vault.DRAW_WINDOW()));
        uint256 capNow = (vault.claimableEdge(1) * vault.DAILY_DRAW_BPS()) / 10_000;
        assertEq(vault.drawableEdge(1), capNow, "a full day refills it to the cap and no further");
    }

    /// @notice THE SENTINEL COLLISION. `updatedAt` is written with `uint64(block.timestamp)`, so
    /// a clock at a multiple of 2^64 stores a legitimate zero. While zero also meant "never
    /// drawn", that state read as a full bucket and two draws in the same block each took one.
    /// The counterexample is Certora's own (`twoDrawsCannotDoubleUp`).
    function test_aStoredZeroTimestampIsNotReadAsAnUntouchedBucket() public {
        _accrueSleeve(2 ether);

        // the clock truncates to exactly zero in the field's own width
        vm.warp(2 ** 64);
        uint256 first = vault.drawableEdge(1);
        assertGt(first, 0, "there is a bucket to spend");
        vm.prank(address(bidDeployer));
        vault.consumeAncestorClaim(1, first);

        (uint64 updatedAt,,) = vault.drawBucket(1);
        assertEq(updatedAt, 0, "the stored clock really is a legitimate zero");
        assertEq(vault.drawableEdge(1), 0, "and the bucket stays spent rather than reading as fresh");

        vm.prank(address(bidDeployer));
        vm.expectRevert(abi.encodeWithSelector(FeeVault.DailyLimitExceeded.selector, 1, 0));
        vault.consumeAncestorClaim(1, 1);
    }

    // ---------------------------------------------------------------------------------
    // The end-request guard is a flag, not a non-zero beacon id
    // ---------------------------------------------------------------------------------

    function test_theEndCannotBeRequestedTwice() public {
        _openRoundAtNominalEnd();
        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    /// @notice A source that hands back `bytes32(0)` does not disarm the once-per-round guard,
    /// because the guard is its own flag, not the id itself. `DrandSource.pin()` returns
    /// `bytes32(round)`, so this would need beacon round 0 - but the guard holds either way.
    function test_aZeroRequestIdStillClosesTheRound() public {
        uint256 roundId = _openRoundAtNominalEnd();

        vm.mockCall(
            address(randomness), abi.encodeWithSelector(IRandomnessSource.pin.selector), abi.encode(bytes32(0))
        );
        bytes32 id = roundManager.requestEnd();
        assertEq(id, bytes32(0), "the source really returned a zero id");

        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertTrue(r.endRequested, "the request is recorded by its own flag");
        assertEq(r.randomId, bytes32(0), "and the id carries no 'unset' meaning");

        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    // ---------------------------------------------------------------------------------
    // The successor hop runs behind the reentrancy lock, on a complete ledger
    // ---------------------------------------------------------------------------------

    /// @notice POST-SUNSET HANDOVER, HOSTILE SUCCESSOR. `accrue` hands control to a successor
    /// vault that is unknown third-party code. It now does so behind the vault's own reentrancy
    /// lock and with `ledgerTotal` already credited in full, so a successor that calls back in
    /// can neither move a ledger nor observe an understated one. Conservation is asserted: the
    /// whole ETH edge is either in this vault's ledger or in the successor's hands.
    ///
    /// The solvency invariant is asserted DURING the hop as well. The protocol
    /// share's refund is the instruction BEFORE the ERC-6909 transfer, not after it: were the
    /// refund to run after the transfer returned, the claim would have left the vault while
    /// `ledgerTotal` still counted it for the whole of the successor's call -
    /// `ledgerTotal > holdings` in exactly the window where foreign code reads the vault. With the
    /// refund first, `ledgerTotal <= holdings` holds at every point, and the property that the
    /// ledger never UNDERSTATES what the vault holds is unchanged because the debit and
    /// the holding it accounts for move together and roll back together.
    function test_aHostileSuccessorCannotReenterTheAccrualPath() public {
        HostileSuccessorVault hostile = new HostileSuccessorVault(vault, IPoolManager(address(manager)));
        SuccessorFactoryStub sf = new SuccessorFactoryStub(address(hostile));
        SuccessorRegistryStub sr = new SuccessorRegistryStub(address(sf));

        vm.prank(steward);
        roundManager.announceSunset(address(sr));
        vm.warp(roundManager.sunsetAt());
        assertTrue(roundManager.isSunsetEffective(), "the handover is live");

        uint256 ledgerBefore = vault.ledgerTotal(EDGE);
        uint256 devBefore = vault.devBalance();
        uint256 hopBefore = vault.reinforcementBalance(address(doll));

        uint256 spend = 1 ether;
        uint256 out = familyRouter.buyExactIn(1, spend, 0, address(this), 4);
        assertGt(out, 0, "the swap is never failed by the handover");

        uint256 protocolFee = (spend * PROTOCOL_FEE_PPM) / PPM;
        uint256 hopFee = (spend * HOP_FEE_PPM) / PPM;

        // THE PROBE: the successor's re-entry into the vault was refused by the lock
        assertTrue(hostile.reentered(), "the successor did try to come back in");
        assertEq(hostile.flushRevert(), FeeVault.Reentrancy.selector, "flushForward is locked out");
        assertEq(hostile.accrueRevert(), FeeVault.Reentrancy.selector, "and accrue itself is locked");

        // the hop was completed, so the protocol share left as a claim and the ledger gave it up
        assertEq(
            manager.balanceOf(address(hostile), uint256(uint160(address(doll)))),
            protocolFee,
            "the successor holds the edge"
        );
        assertEq(vault.ledgerTotal(EDGE) - ledgerBefore, hopFee, "this version books the hop fee only");
        assertEq(vault.reinforcementBalance(address(doll)) - hopBefore, hopFee, "and it is the reinforcement");
        assertEq(vault.devBalance(), devBefore, "no local ledger moved during the foreign call");
        assertEq(vault.pendingForward(1), 0, "nothing had to be queued");

        // ...and what the foreign code saw while it held control
        assertEq(hostile.ledgerInside(), ledgerBefore + hopFee, "the share was given up BEFORE the claim left");
        assertLe(hostile.ledgerInside(), hostile.holdingsInside(), "the ledger never overstates, mid-hop either");
        assertGe(hostile.ledgerInside(), ledgerBefore, "and it never understates what stayed behind");

        // CONSERVATION: every wei of the edge is accounted for, and the vault is still solvent
        assertEq(protocolFee + hopFee, (spend * TOTAL_FEE_PPM) / PPM, "the whole fee is one of the two");
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // the random-end window is clamped to a quarter of the round
    // ---------------------------------------------------------------------------------

    /// @notice MAINNET IS UNCHANGED. The shortest round is 15 minutes, so `D(n)/4 >= 225 s` and
    /// the window is always the full {RoundManager.RANDOM_END_S}.
    function test_theRandomEndWindowIsUnchangedOnTheMainnetSchedule() public view {
        assertEq(roundManager.DURATION_SCALE_DIV(), 1, "this stack runs the published schedule");
        assertEq(roundManager.durationFor(1), 15 minutes, "the shortest round");
        assertEq(roundManager.randomEndWindowFor(1), 180, "the window is RANDOM_END_S exactly");
        for (uint256 n = 1; n <= 16; n++) {
            assertEq(roundManager.randomEndWindowFor(n), roundManager.RANDOM_END_S(), "every round");
        }
    }

    // ---------------------------------------------------------------------------------
    // the closing window is flat
    // ---------------------------------------------------------------------------------

    /// @notice `W` is {RoundManager.CLOSING_WINDOW_S} on every round, not a fraction of the
    /// duration such as `D(n)/4` above an hour (2 h -> 30 min, 12 h -> 3 h): the yardstick a coin
    /// is measured with does not change with the round number.
    function test_theClosingWindowIsTheSameConstantOnEveryRound() public view {
        uint64 w = roundManager.CLOSING_WINDOW_S();
        assertEq(w, 15 minutes, "the published constant");
        assertEq(roundManager.closingWindowFor(1), w, "round 1, a 15-minute round");
        assertEq(roundManager.closingWindowFor(5), w, "round 5, a 1-hour round");
        assertEq(roundManager.closingWindowFor(7), w, "round 7, a 2-hour round (was 30 min)");
        assertEq(roundManager.closingWindowFor(13), w, "round 13, a 12-hour round (was 3 h)");
    }

    /// @notice The hook's checkpoint rings reach back over `W + RANDOM_END_S` on every row of the
    /// schedule, which is the WHOLE span a round can be scored over: `T_end` lies in
    /// `[T - RANDOM_END_S, T]` and the window reaches `W` further back.
    ///
    /// The settlement TAIL has left this requirement. Ring writes freeze at the
    /// pool's published end `T`, so no swap made while a round is being settled or scored can
    /// overwrite an entry at all, and the ring no longer has to SURVIVE
    /// `END_TIMEOUT + SUBMIT_S` of churn on top of the span it has to REACH. On this stack the
    /// requirement is 900 + 180 = 1080 s for every round, met by 63 x 18 = 1134 s of coarse ring
    /// (it was 51 s, sized for 3180 s). The fast ring is unchanged at 36 x 5 = 180 s, which is
    /// exactly the random-end span it exists to cover.
    function test_theScoreRingsCoverTheFlatWindowAndTheRandomEnd() public view {
        assertEq(hook.SCORE_RING_S(), roundManager.RANDOM_END_S(), "the fast ring spans the random end");
        for (uint256 n = 1; n <= 20; n++) {
            uint256 needed = roundManager.closingWindowFor(n) + roundManager.RANDOM_END_S();
            assertEq(needed, 1080, "one requirement for every round now");
            uint256 slot = roundManager.scoreSlotFor(n);
            assertEq(slot, 18, "and one coarse spacing");
            assertGe((hook.SCORE_COARSE_SLOTS() - 1) * slot, needed, "the coarse ring reaches the far edge");
            assertGe(slot, hook.SCORE_SLOT_S(), "never finer than the fast ring");
        }
    }

    /// @dev The leader of a fresh round, with its support built early and topped up inside the
    /// closing window, warped to the nominal end `T`. Returns the candidate and the average its
    /// closing window is worth as of `T`, read BEFORE anything can have overwritten the ring.
    function _leaderAtNominalEnd() internal returns (Cand memory lead, int256 expected) {
        uint256 roundId = roundManager.roundCount() + 1;
        lead = _registerCandidate(address(0x1EADE4), "LEAD");
        assertEq(roundManager.roundCount(), roundId, "the registration opened the round");
        (uint64 tradingStart, uint64 nominalEnd,) = _roundTimes(roundId);
        uint64 w = roundManager.closingWindowFor(roundId);

        IERC20(roundManager.head()).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(lead, true, WINNING_BUY);
        // one more buy INSIDE the closing window, so the far edge of the window is resolved by a
        // coarse checkpoint rather than by the pool's live state
        vm.warp(nominalEnd - w / 2);
        _tradeCandidate(lead, true, WINNING_BUY / 50);

        vm.warp(nominalEnd);
        (expected,,,) = hook.averageOver(lead.poolId, nominalEnd - w, nominalEnd);
        assertGt(expected, 0, "the leader has a real closing-window average");
    }

    /// @dev Swap the leader's pool once per coarse slot across `(from, to]`, which is the fastest
    /// anyone can turn the ring over: a second swap inside the same slot writes nothing.
    function _swapEverySlot(Cand memory lead, uint64 from, uint64 to) internal {
        uint64 slot = uint64(roundManager.scoreSlotFor(roundManager.roundCount()));
        for (uint64 t = from + slot; t <= to; t += slot) {
            vm.warp(t);
            _tradeCandidate(lead, true, 1e18);
        }
    }

    /// @notice The ring is not merely large enough to
    /// survive the whole beacon-timeout gap - it is UNTOUCHED by it. Nobody relays a beacon, the
    /// leader's pool is swapped once per coarse slot for the entire `[T, T + END_TIMEOUT]`
    /// window, and the round is then settled deterministically and scored at the last moment of
    /// its submission window. Every one of those swaps is past the pool's published end, so none
    /// of them writes a ring entry: the whole ring is byte-identical afterwards, and the score is
    /// the one measured at `T`.
    function test_theRingIsUnchangedByAFullBeaconTimeoutOfPostBellDust() public {
        (Cand memory lead, int256 expected) = _leaderAtNominalEnd();
        uint256 roundId = roundManager.roundCount();
        (, uint64 nominalEnd,) = _roundTimes(roundId);
        uint64 timeout = roundManager.END_TIMEOUT();

        IFamilyHook.ScoreCheckpoint[] memory before = _ringSnapshot(lead.poolId);
        _swapEverySlot(lead, nominalEnd, nominalEnd + timeout);
        _assertRingsUnchangedUpTo(lead.poolId, before, nominalEnd);

        vm.warp(nominalEnd + timeout);
        roundManager.finalizeDeterministic();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        assertEq(r.tradingEnd, nominalEnd, "the deterministic end is T exactly");
        assertEq(r.submitEnd, uint64(block.timestamp) + roundManager.SUBMIT_S(), "the window opens now");

        vm.warp(r.submitEnd - 1);
        int256 avg = roundManager.submitScore(lead.id);
        assertEq(avg, expected, "the closing-window average is the one measured at T");
        assertEq(roundManager.candidateInfo(lead.id).avg, avg, "and it is what the round recorded");
    }

    /// @notice The same round with a PROMPT beacon: a submission window's worth of dust likewise
    /// writes nothing, and the far edge still resolves.
    function test_theRingIsUnchangedByASubmissionWindowOfDustAfterAPromptFulfil() public {
        (Cand memory lead, int256 expected) = _leaderAtNominalEnd();
        (, uint64 nominalEnd,) = _roundTimes(roundManager.roundCount());
        (uint64 tradingEnd, uint64 submitEnd) = _settleEnd();
        assertEq(tradingEnd, nominalEnd, "a word of zero ends the round at T");

        IFamilyHook.ScoreCheckpoint[] memory before = _ringSnapshot(lead.poolId);
        _swapEverySlot(lead, tradingEnd, submitEnd - 1);
        _assertRingsUnchangedUpTo(lead.poolId, before, nominalEnd);

        vm.warp(submitEnd - 1);
        assertEq(roundManager.submitScore(lead.id), expected, "the same average, read after the dust");
    }

    /// @dev Both rings of a pool, in one array: the fast ring first, then the coarse one.
    function _ringSnapshot(PoolId id) internal view returns (IFamilyHook.ScoreCheckpoint[] memory ring) {
        uint256 fast = hook.SCORE_SLOTS();
        uint256 coarse = hook.SCORE_COARSE_SLOTS();
        ring = new IFamilyHook.ScoreCheckpoint[](fast + coarse);
        for (uint256 i = 0; i < fast; i++) {
            ring[i] = hook.scoreCheckpoint(id, i);
        }
        for (uint256 i = 0; i < coarse; i++) {
            ring[fast + i] = hook.coarseCheckpoint(id, i);
        }
    }

    /// @dev Every entry stamped at or before the published end `T` is still there,
    /// unchanged, and no entry stamped AFTER `T` has appeared.
    function _assertRingsUnchangedUpTo(PoolId id, IFamilyHook.ScoreCheckpoint[] memory before, uint64 publishedEnd)
        internal
        view
    {
        IFamilyHook.ScoreCheckpoint[] memory now_ = _ringSnapshot(id);
        uint256 kept;
        for (uint256 i = 0; i < before.length; i++) {
            assertLe(now_[i].tSwap, publishedEnd, "no ring entry is ever stamped after the bell");
            assertEq(now_[i].tSwap, before[i].tSwap, "tSwap unchanged");
            assertEq(now_[i].tState, before[i].tState, "tState unchanged");
            assertEq(now_[i].R, before[i].R, "R unchanged");
            assertEq(now_[i].acc, before[i].acc, "acc unchanged");
            if (before[i].tSwap != 0) kept++;
        }
        assertGt(kept, 0, "the pool really did have a ring to preserve");
    }

    // ---------------------------------------------------------------------------------
    // the sleeve's bound check comes before its zero short-circuit
    // ---------------------------------------------------------------------------------

    /// @notice No index past {FenwickRangeAdd.MAX_INDEX} is ever accepted, even for a zero
    /// sleeve: the bound is checked before the zero short-circuit, so it reverts either way.
    function test_anOutOfRangeSleeveIndexAlwaysReverts() public {
        FenwickHarness h = new FenwickHarness();
        uint256 past = FenwickRangeAdd.MAX_INDEX + 1;

        vm.expectRevert(FenwickRangeAdd.IndexOutOfRange.selector);
        h.addSleeve(0, past);

        vm.expectRevert(FenwickRangeAdd.IndexOutOfRange.selector);
        h.addSleeve(1 ether, past);

        // the last legal index is still legal, and a zero sleeve there is still a no-op
        h.addSleeve(0, FenwickRangeAdd.MAX_INDEX);
        assertEq(h.query(0), 0, "nothing was credited");
    }

    // ---------------------------------------------------------------------------------
    // REN-01: the round machine and the claims refuse to run inside somebody's unlock
    // ---------------------------------------------------------------------------------

    /// @notice The slot the guard reads is v4-core's own, by its own definition.
    function test_REN01_theGuardReadsV4sOwnLockSlot() public pure {
        assertEq(
            V4UnlockGuard.IS_UNLOCKED_SLOT,
            bytes32(uint256(keccak256("Unlocked")) - 1),
            "Lock.IS_UNLOCKED_SLOT"
        );
    }

    /// @notice REN-01 as the property states it. Being inside a `PoolManager` unlock used not to
    /// be a state the protocol checked, so a contract could open its own flash accounting, swap,
    /// and settle a round in the same frame. Every round-machine transition and every pull
    /// payment now refuses; the swap path itself is untouched, which the rest of the suite shows.
    function test_REN01_everyGuardedEntrypointRefusesFromInsideAnUnlock() public {
        UnlockProber p = new UnlockProber(IPoolManager(address(manager)));

        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.finalize, ())),
            RoundManager.InsideUnlock.selector,
            "finalize"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.requestEnd, ())),
            RoundManager.InsideUnlock.selector,
            "requestEnd"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.finalizeDeterministic, ())),
            RoundManager.InsideUnlock.selector,
            "finalizeDeterministic"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.submitScore, (0))),
            RoundManager.InsideUnlock.selector,
            "submitScore"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimDev, (address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimDev"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimCreator, (address(token), address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimCreator"
        );
        assertEq(
            p.probe(address(vault), abi.encodeCall(FeeVault.claimCreatorAccrued, (address(this)))),
            FeeVault.InsideUnlock.selector,
            "claimCreatorAccrued"
        );
        // The two round-machine paths that were still unguarded, and the keeper
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.fulfilEnd, (""))),
            RoundManager.InsideUnlock.selector,
            "fulfilEnd"
        );
        assertEq(
            p.probe(address(roundManager), abi.encodeCall(RoundManager.claimRefund, (address(this)))),
            RoundManager.InsideUnlock.selector,
            "claimRefund"
        );
        assertEq(
            p.probe(address(bidDeployer), abi.encodeWithSignature("deployEdgeBid()")),
            BidDeployer.InsideUnlock.selector,
            "deployEdgeBid"
        );
    }

    // ---------------------------------------------------------------------------------
    // REN-01: the guard is BOUND to the deployed PoolManager, and cannot fail open
    // ---------------------------------------------------------------------------------

    /// @notice A guard that reads the wrong slot answers `false` forever, and every
    /// `notInsideUnlock` in the stack becomes a silent no-op. The binding is therefore proved,
    /// not assumed: `false` outside an unlock (which `FamilyFactory.wire` asserts on the way to
    /// the first launch) and `true` inside one, which needs an unlock to be opened. The deploy
    /// script runs exactly this probe against the manager it deployed to, and
    /// `test/fork/UnlockGuard.fork.t.sol` runs it against the live singleton.
    function test_REN01_theGuardIsBoundToTheDeployedPoolManager() public {
        assertFalse(V4UnlockGuard.isInsideUnlock(address(manager)), "false outside an unlock");
        assertTrue(new V4UnlockGuardProbe().probe(address(manager)), "and true inside one");
        assertTrue(factory.wired(), "the stack was wired with the guard read exercised");
    }

    /// @notice ...and the check is in `wire`, so a stack wired against a manager the guard cannot
    /// read never launches anything. The read is exercised at the door: against a manager with no
    /// `exttload` it reverts rather than wiring a stack whose guards are decorative.
    function test_REN01_wiringRevertsWhenTheGuardCannotReadTheManager() public {
        FamilyFactory fresh = _deployStack(true, steward, address(0)).factory;
        // a manager whose lock slot cannot be read at all: the guard's `exttload` reverts, and
        // so does the wiring that depends on it
        vm.mockCallRevert(address(manager), abi.encodeWithSignature("exttload(bytes32)"), "");
        vm.expectRevert();
        fresh.wire();
        vm.clearMockedCalls();
        fresh.wire();
        assertTrue(fresh.wired(), "and it wires once the manager answers");
    }

    /// @notice OUTSIDE an unlock the same calls behave exactly as they did: the guard is a state
    /// check, not a permission. `finalize` on a round that has not settled still reverts with its
    /// own error, and a round still runs end to end.
    function test_REN01_theGuardChangesNothingOutsideAnUnlock() public {
        _openRoundAtNominalEnd();
        vm.expectRevert(RoundManager.EndNotSettled.selector);
        roundManager.finalize();

        roundManager.requestEnd();
        vm.expectRevert(RoundManager.EndAlreadyRequested.selector);
        roundManager.requestEnd();
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// @dev A well-formed key that no pool has been registered under, so `registerPool`'s own
    /// guards are what the test is measuring.
    function _spareKey(address other) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(other),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Put a real ETH sleeve under generation 1, so the drawdown bucket has something to
    /// meter. A generation's sleeve only fills when a DEEPER link is the attributed terminal
    /// token, so the chain has to reach #2 and the buys have to terminate there.
    function _accrueSleeve(uint256 ethIn) internal {
        _runWinningRound(1, WINNING_BUY);
        _runWinningRound(1, WINNING_BUY);
        familyRouter.buyExactIn(2, ethIn, 0, address(this), 3);
        vm.warp(block.timestamp + 200);
        familyRouter.buyExactIn(2, ethIn / 10, 0, address(this), 3);
    }

    /// @dev Open a round and stand at its nominal end `T`, where {RoundManager.requestEnd} is
    /// the next legal call.
    function _openRoundAtNominalEnd() internal returns (uint256 roundId) {
        _registerCandidate(address(0xA11CE), "CAND");
        roundId = roundManager.roundCount();
        (, uint64 nominalEnd,) = _roundTimes(roundId);
        vm.warp(nominalEnd);
    }
}

/// @notice The same fixes, read on a heavily SCALED testnet schedule - the only place the
/// random-end clamp does anything at all.
contract Review2ScaledScheduleTest is RoundTestBase {
    function setUp() public {
        durationScaleDiv = 5;
        _setUpFamily();
    }

    /// @notice `RANDOM_END_S` is not scaled by {RoundManager.DURATION_SCALE_DIV}, so on a divisor
    /// of 5 the first round trades for 180 s; without a clamp the end would be drawn from a
    /// window as long as the whole round, and `T_end` could land at `tradingStart` itself,
    /// leaving nothing to score. The clamp keeps three quarters of every round unconditionally
    /// inside the round.
    function test_theRandomEndWindowIsAQuarterOfAScaledRound() public view {
        assertEq(roundManager.DURATION_SCALE_DIV(), 5, "the scaled testnet schedule");
        assertEq(roundManager.durationFor(1), 180, "a 180-second round");
        assertEq(roundManager.randomEndWindowFor(1), 45, "and a 45-second random-end window");
        assertLt(roundManager.randomEndWindowFor(1), roundManager.RANDOM_END_S(), "clamped, not RANDOM_END_S");
    }

    /// @notice The coarse ring's spacing follows the SCALED closing window, while `RANDOM_END_S`
    /// is seconds of wall clock whatever the schedule divisor does to the rounds; the settlement
    /// tail is not part of the span at all.
    function test_theCoarseSlotFollowsTheScaledWindowAndTheUnscaledRandomEnd() public view {
        assertEq(roundManager.closingWindowFor(1), 180, "W is scaled by the divisor");
        assertEq(roundManager.RANDOM_END_S(), 180, "the random-end span is not");
        uint256 needed = roundManager.closingWindowFor(1) + roundManager.RANDOM_END_S();
        assertEq(needed, 360, "180 + 180");
        assertEq(roundManager.scoreSlotFor(1), 6, "ceil(360 / 63)");
        assertGe((hook.SCORE_COARSE_SLOTS() - 1) * roundManager.scoreSlotFor(1), needed, "the ring covers it");
        assertGt(roundManager.closingWindowFor(1), roundManager.scoreSlotFor(1), "W exceeds one coarse slot");
    }

    /// @notice The clamp holds for every round of the schedule, and the window is never zero:
    /// `fulfilEnd` takes `word mod W_r`, which a zero window would make undefined.
    function test_theWindowIsNeverZeroAndNeverMoreThanAQuarter() public view {
        for (uint256 n = 1; n <= 32; n++) {
            uint64 w = roundManager.randomEndWindowFor(n);
            assertGt(w, 0, "the modulus is defined");
            assertLe(w, roundManager.RANDOM_END_S(), "never longer than RANDOM_END_S");
            assertLe(uint256(w) * 4, roundManager.durationFor(n), "never more than a quarter of the round");
        }
    }
}

/// @dev Opens a v4 unlock of its own and makes one call from inside it, reporting the revert
/// selector rather than bubbling it. Nothing in the callback creates a delta, so the unlock
/// itself settles cleanly and what the test reads is the guard and only the guard.
contract UnlockProber is IUnlockCallback {
    IPoolManager internal immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function probe(address target, bytes memory call) external returns (bytes4 selector) {
        return abi.decode(poolManager.unlock(abi.encode(target, call)), (bytes4));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory ret) = target.call(call);
        if (ok) return abi.encode(bytes4(0));
        if (ret.length < 4) return abi.encode(bytes4(0xffffffff));
        return abi.encode(bytes4(ret));
    }
}

/// @dev A successor vault that is hostile third-party code: it takes the handover and, while the
/// prior vault is still inside {FeeVault.accrue}, tries to come back in through the two doors
/// a hostile successor could reach. It swallows every revert so that the handover still completes
/// and the test can read what happened rather than just watching the swap fail.
contract HostileSuccessorVault {
    FeeVault internal immutable victim;
    IPoolManager internal immutable poolManager;

    bool public reentered;
    bytes4 public flushRevert;
    bytes4 public accrueRevert;
    /// @dev What the victim's EDGE ledger and holdings looked like DURING the hop, read by the
    /// foreign code the hop hands control to.
    uint256 public ledgerInside;
    uint256 public holdingsInside;

    constructor(FeeVault _victim, IPoolManager _poolManager) {
        victim = _victim;
        poolManager = _poolManager;
    }

    receive() external payable {}

    function accrueForwarded(uint256, uint256, uint256) external {
        reentered = true;
        Currency edge = victim.EDGE();
        ledgerInside = victim.ledgerTotal(edge);
        holdingsInside = victim.holdings(edge);
        flushRevert = _probe(abi.encodeWithSelector(FeeVault.flushForward.selector, uint256(1), type(uint256).max));
        accrueRevert = _probe(
            abi.encodeWithSelector(
                IFeeVault.accrue.selector, edge, address(0), uint256(0), uint256(0), uint256(0), false
            )
        );
    }

    function receiveForward(uint256, uint256) external {}

    function _probe(bytes memory call) internal returns (bytes4 selector) {
        (bool ok, bytes memory ret) = address(victim).call(call);
        if (ok) return bytes4(0);
        if (ret.length < 4) return bytes4(0xffffffff);
        return bytes4(ret);
    }
}

/// @dev `FeeVault._resolveSuccessorVault` walks `successor().factory().feeVault()`; these two
/// stubs are that walk and nothing else.
contract SuccessorFactoryStub {
    address public immutable feeVault;

    constructor(address v) {
        feeVault = v;
    }
}

contract SuccessorRegistryStub {
    address public immutable factory;

    constructor(address f) {
        factory = f;
    }
}
