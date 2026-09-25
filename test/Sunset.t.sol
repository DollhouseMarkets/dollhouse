// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyLens} from "../contracts/FamilyLens.sol";
import {RoundManager} from "../contracts/RoundManager.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {IFeeVault} from "../contracts/interfaces/IFeeVault.sol";

/// @notice The ENTIRE privileged surface of the protocol: an immutable steward that may, once,
/// announce that this version stops opening new rounds seven days from now. These tests pin down
/// both halves of that promise - that it works, and that it does nothing else.
///
/// README "Upgrade model": "v1 gains a single narrow switch: `announceSunset(successor)` by an
/// immutable steward, effective after a 7-day public delay, which only stops v1 from opening new
/// rounds (in-flight rounds finish; trading, liquidity, fees, claims, history untouched;
/// irreversible)."
contract SunsetTest is RoundTestBase {
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    address internal constant STEWARD = address(0x57E4A2D);
    /// @dev Stands in for the v2 RoundManager: `announceSunset` only requires code at the address.
    address internal successorStub;

    function setUp() public {
        steward = STEWARD;
        _setUpEdge();
        successorStub = address(new Stub());
    }

    // ---------------------------------------------------------------------------------
    // who, and how often
    // ---------------------------------------------------------------------------------

    function test_onlyTheStewardMayAnnounce() public {
        assertEq(roundManager.steward(), STEWARD, "the steward is immutable wiring");

        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        vm.prank(address(0xBADBAD));
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        assertEq(roundManager.successor(), successorStub);
    }

    function test_announceIsOnceAndForever() public {
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        uint64 at = roundManager.sunsetAt();

        address other = address(new Stub());
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SunsetAlreadyAnnounced.selector);
        roundManager.announceSunset(other);

        // there is no cancel and no shorten: the two stored words never move again
        vm.warp(block.timestamp + 30 days);
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SunsetAlreadyAnnounced.selector);
        roundManager.announceSunset(other);
        assertEq(roundManager.sunsetAt(), at, "the effective time is immutable once set");
        assertEq(roundManager.successor(), successorStub, "the successor is immutable once set");
    }

    function test_successorMustBeAContract() public {
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SuccessorHasNoCode.selector);
        roundManager.announceSunset(address(0xE0A));

        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SuccessorHasNoCode.selector);
        roundManager.announceSunset(address(0));
    }

    /// @notice A deployment whose steward is address(0) can NEVER be sunset - not by anyone, not
    /// by address(0) itself. That is the "no upgrade path at all" configuration.
    function test_zeroStewardMeansNoSunsetIsPossible() public {
        steward = address(0);
        _setUpEdge();
        assertEq(roundManager.steward(), address(0));

        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        vm.prank(address(0));
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        // and the chain keeps running forever
        vm.warp(block.timestamp + 365 days);
        _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.headIndex(), 2, "succession still works");
    }

    function test_gas_announceSunset() public {
        vm.prank(STEWARD);
        uint256 g = gasleft();
        roundManager.announceSunset(successorStub);
        emit log_named_uint("announceSunset gas", g - gasleft());
    }

    // ---------------------------------------------------------------------------------
    // the delay
    // ---------------------------------------------------------------------------------

    function test_theDelayIsSevenDaysAndRoundsOpenThroughout() public {
        uint256 announcedAt = block.timestamp;
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        assertEq(roundManager.sunsetAt(), announcedAt + 7 days, "SUNSET_DELAY is 7 days");
        assertEq(roundManager.sunsetDelay(), 7 days);
        assertFalse(roundManager.isSunset(), "not yet in force");

        // a whole round still opens, runs and crowns a head inside the window
        _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.headIndex(), 2, "succession works during the delay");

        // one second before the deadline a new round still opens
        vm.warp(roundManager.sunsetAt() - 1);
        assertFalse(roundManager.isSunset());
        _registerCandidate(address(0xA11CE), "LATE");
        assertEq(roundManager.roundCount(), 3, "a round opened one second before the sunset");
    }

    // ---------------------------------------------------------------------------------
    // the in-flight round finishes
    // ---------------------------------------------------------------------------------

    /// @notice The sunset check sits AFTER the "a round is already open" branch, so a round that
    /// was open when the sunset landed still registers, trades, is scored and crowns a head.
    function test_aRoundOpenWhenTheSunsetLandsStillFinishesAndCrowns() public {
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);

        // open a round that will still be in its registration window at `sunsetAt`
        vm.warp(roundManager.sunsetAt() - 60);
        delete cands;
        _registerCandidate(address(0xA11CE), "INFLIGHT");
        uint256 roundId = roundManager.roundCount();
        (uint64 tradingStart, uint64 tradingEnd, uint64 submitEnd) = _roundTimes(roundId);
        assertGt(uint256(tradingEnd), uint256(roundManager.sunsetAt()), "the round outlives the sunset");

        // a SECOND candidate can still join the open round after the sunset has taken effect
        vm.warp(roundManager.sunsetAt() + 1);
        assertTrue(roundManager.isSunset(), "in force");
        _registerCandidate(address(0xB0B), "INFLIGHT2");
        assertEq(roundManager.roundCount(), roundId, "no new round was opened");
        assertEq(roundManager.roundInfo(roundId).candidateCount, 2);

        address parent = roundManager.head();
        IERC20(parent).approve(address(swapRouter), type(uint256).max);
        vm.warp(tradingStart + 5);
        _tradeCandidate(cands[0], true, WINNING_BUY);
        _tradeCandidate(cands[1], true, WINNING_BUY / 100);

        _settleEnd();
        roundManager.submitScore(cands[0].id);
        roundManager.submitScore(cands[1].id);
        vm.warp(submitEnd + 1);
        roundManager.finalize();

        assertEq(roundManager.headIndex(), 2, "the in-flight round crowned a new head after sunset");
        assertEq(roundManager.head(), cands[0].token);
        assertEq(roundManager.canonical(2), cands[0].token);
    }

    // ---------------------------------------------------------------------------------
    // after the sunset: exactly one thing stops
    // ---------------------------------------------------------------------------------

    function test_openingANewRoundRevertsAfterTheSunset() public {
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        vm.warp(roundManager.sunsetAt());
        assertTrue(roundManager.isSunset(), "exactly at `sunsetAt` it is already in force");

        uint256 bond = roundManager.currentBond();
        vm.deal(address(0xA11CE), bond);
        vm.prank(address(0xA11CE));
        vm.expectRevert(abi.encodeWithSelector(RoundManager.Sunset.selector, successorStub));
        factory.registerCandidate("NO", "NO", "", type(uint256).max);

        // the error carries the successor, so a UI can point traders at the new deployment
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(RoundManager.Sunset.selector, successorStub));
        roundManager.openRoundIfIdle();
    }

    /// @notice Everything that is NOT "open a new round" keeps working forever.
    function test_everythingElseKeepsWorkingAfterTheSunset() public {
        // a full round BEFORE the sunset, so there is history, fees and a claimable creator share
        _runWinningRound(1, WINNING_BUY);
        address link1 = roundManager.head();
        address creator1 = roundManager.creatorOf(link1);

        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        vm.warp(roundManager.sunsetAt() + 1 days);
        assertTrue(roundManager.isSunset());

        // 1. swaps still work, in both directions, on genesis and on the deep link
        uint256 got = familyRouter.buyExactIn(1, 1 ether, 0, address(this), 4);
        assertGt(got, 0, "a routed buy still fills after the sunset");
        IERC20(link1).approve(address(familyRouter), type(uint256).max);
        uint256 back = familyRouter.sellExactIn(1, got / 2, 0, address(this), 4);
        assertGt(back, 0, "a routed sell still fills after the sunset");

        // 2. fees still accrue and are still claimable
        assertGt(vault.devBalance(), 0, "fees still accrue");
        vm.prank(developer);
        vault.claimDev(developer);
        uint256 creatorOwed = vault.creatorBalance(link1);
        if (creatorOwed != 0) {
            vm.prank(creator1);
            vault.claimCreator(link1, creator1);
        }

        // 3. keeper deployments still work
        _warmOracles();
        bidDeployer.deployEdgeBid();

        // 4. the history is intact and still readable
        assertEq(roundManager.headIndex(), 2);
        assertEq(roundManager.canonical(0), address(doll), "index 0 is the adopted genesis");
        assertEq(roundManager.canonical(1), address(token), "link one is the edge");
        assertEq(roundManager.canonical(2), link1);
        assertEq(roundManager.parentOf(link1), address(token));
        assertEq(roundManager.indexOf(link1), 2);
        assertTrue(roundManager.isCanonical(link1));
        FamilyLens.LinkView[] memory links = lens.chainView(0, 2);
        assertEq(links.length, 3);
        assertEq(links[2].token, link1);

        // 5. the finalized round is still finalizable-idempotent and reports the same result
        roundManager.finalize();
        assertTrue(roundManager.roundInfo(roundManager.roundCount()).hasWinner);
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // A hostile successor may not brick trading, and the steward has one way back
    // ---------------------------------------------------------------------------------

    /// @notice `announceSunset` only checks that the successor has
    /// CODE. A successor whose `factory()` and `accrueForwarded` burn every wei of gas they are
    /// given must not make every swap of every pool of this version revert: the hook staticalls
    /// it with a bound on every swap, and the vault keeps back a gas reserve, so there is always
    /// enough left for the Fenwick booking even though the switch is irreversible.
    ///
    /// Here the same successor is named and the same swaps must still go through - the genesis
    /// pool (which pays the forwarded ETH edge) and a candidate pool (which pays the hook's
    /// attribution resolution) - with bounded gas.
    /// @notice `sync(ERC20)` INSIDE THE UNLOCK. The PoolManager keeps ONE transient
    /// "currency being synced" slot. A successor that syncs an ERC-20 while the handover hop runs
    /// (it is called from inside the swap) would leave that slot pointing at a token, and without
    /// a guard the router's native `settle{value}` afterwards would be credited against the wrong
    /// currency, reverting the whole route. The router and the Locker `sync(native)` immediately
    /// before every native settle, so nothing another contract did earlier in the unlock can
    /// matter.
    function test_aSuccessorSyncingAnErc20DoesNotBreakNativeSettlement() public {
        SyncGriefer griefer = new SyncGriefer(im, address(token));
        vm.prank(STEWARD);
        roundManager.announceSunset(address(griefer));
        vm.warp(roundManager.sunsetAt());

        // a normal ETH-funded route: the edge is forwarded to the griefer mid-swap, which syncs
        // an ERC-20 before the router settles its native input
        uint256 devBefore = vault.devBalance();
        uint256 out = familyRouter.buyExactIn(1, 1 ether, 0, address(this), 2);
        assertGt(out, 0, "the route settled its native input anyway");
        assertTrue(griefer.synced(), "...and the successor really did sync an ERC-20 first");
        assertEq(vault.devBalance(), devBefore, "the edge was not booked here");

        // the Locker's native settle is on the same footing: a genesis bid still places
        _warmOracles();
        assertGt(bidDeployer.deployEdgeBid(), 0, "the Locker settled native ETH too");
    }

    /// @notice THE DIRTY WORD. A successor that answers with a well-formed 32-byte
    /// word whose upper 96 bits are not zero must not make `abi.decode(ret, (address))` REVERT
    /// inside the hook - a revert there would happen in `beforeSwap`, failing every attributed
    /// third-party route through this version for good. The word is validated instead of decoded:
    /// it is simply "no answer", cached negative like any other failed resolution.
    function test_aDirtyWordSuccessorCannotBrickRoutes() public {
        Cand memory c = _registerCandidate(address(0xC0DE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        address dirty = address(new DirtyWordSuccessor());
        vm.prank(STEWARD);
        roundManager.announceSunset(dirty);
        vm.warp(roundManager.sunsetAt());

        // the genesis pool still swaps
        assertGt(_buyLink(1, 1 ether), 0, "the genesis swap went through");

        // and so does the path that resolves the successor's ROUTER: a family-pool swap carrying
        // attribution data from a caller the hook does not already trust
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        _swapCandidate(c, 1_000e18, abi.encode(uint256(1)));
        assertTrue(hook.successorUnresolvable(), "the dirty word was cached as unresolvable");

        // the next one does not even try, and still works
        _swapCandidate(c, 1_000e18, abi.encode(uint256(1)));
    }

    function test_aGasBurningSuccessorCannotBrickSwaps() public {
        // a candidate pool that exists BEFORE the sunset (no new round opens after it)
        Cand memory c = _registerCandidate(address(0xC0DE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        address burner = address(new GasBurner());
        vm.prank(STEWARD);
        roundManager.announceSunset(burner);
        vm.warp(roundManager.sunsetAt());

        // 1. the genesis pool: the ETH edge tries to forward into the burner and must not fail
        uint256 devBefore = vault.devBalance();
        uint256 g = gasleft();
        uint256 out = _buyLink(1, 1 ether);
        uint256 firstGas = g - gasleft();
        assertGt(out, 0, "the genesis swap went through");
        // The fee is QUEUED for a later flush, never booked here - the gas of a swap no
        // longer decides which version receives a post-sunset fee
        assertEq(vault.devBalance(), devBefore, "nothing was booked locally");
        assertEq(vault.pendingForwardTotal(), 1e16, "the edge is queued for a flush");
        assertTrue(vault.forwardingFailed(), "the failed hop is cached, once");

        // 2. the next swap must not pay for the burner AGAIN (negative resolution cached)
        g = gasleft();
        _buyLink(1, 1 ether);
        uint256 secondGas = g - gasleft();
        emit log_named_uint("genesis swap gas, first attempt at the hostile hop", firstGas);
        emit log_named_uint("genesis swap gas, after the negative cache", secondGas);
        assertLt(firstGas, 8_000_000, "even the hostile attempt is bounded by FORWARD_GAS");
        assertLt(secondGas, firstGas, "the hop is never retried");
        assertLt(secondGas, 1_000_000, "and the swap gas is bounded from then on");

        // 3. a family pool swap carrying attribution data from a NON-canonical caller: that is
        // the path where the hook resolves the successor's router, staticalling the burner
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        g = gasleft();
        _swapCandidate(c, 1_000e18, abi.encode(uint256(1)));
        uint256 candGas = g - gasleft();
        emit log_named_uint("candidate pool swap gas with a gas-burning successor", candGas);
        assertLt(candGas, 1_000_000, "bounded by the per-leg staticcall cap");
        assertTrue(hook.successorUnresolvable(), "the hook cached the negative resolution too");

        // and the next one does not even try
        g = gasleft();
        _swapCandidate(c, 1_000e18, abi.encode(uint256(1)));
        assertLt(g - gasleft(), candGas, "the resolution is never retried");
    }

    /// @dev A parent-in swap against a candidate pool carrying `hookData`, sent by a caller the
    /// hook does not trust: the attribution path that resolves the successor's router.
    function _swapCandidate(Cand memory c, uint256 amountIn, bytes memory hookData) internal {
        bool zeroForOne = !c.tokenIsCurrency0;
        swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice The one way back out of a mistaken sunset: {RoundManager.cancelSunset}, allowed
    /// only BEFORE the announced moment, and only once.
    function test_cancelSunsetWorksBeforeTheEffectAndNotAfter() public {
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        uint64 at = roundManager.sunsetAt();

        // not the steward
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.cancelSunset();

        // one second before it takes effect: still cancellable
        vm.warp(at - 1);
        vm.expectEmit(true, true, false, false, address(roundManager));
        emit RoundManager.SunsetCancelled(STEWARD, successorStub);
        vm.prank(STEWARD);
        roundManager.cancelSunset();

        assertEq(roundManager.sunsetAt(), 0, "the announcement is gone");
        assertEq(roundManager.successor(), address(0), "and so is the successor");
        assertTrue(roundManager.sunsetCancelled(), "the escape hatch is spent");
        assertFalse(roundManager.isSunset());

        // rounds open again, after the moment the sunset would have landed
        vm.warp(at + 1 days);
        _registerCandidate(address(0xA11CE), "AFTER");
        assertEq(roundManager.roundCount(), 2, "a round opened after the cancelled sunset");

        // a SECOND announcement is allowed - and this one can never be taken back
        vm.prank(STEWARD);
        roundManager.announceSunset(successorStub);
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SunsetNotCancellable.selector);
        roundManager.cancelSunset();

        // and once the sunset has taken effect there is no cancel either
        vm.warp(roundManager.sunsetAt());
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SunsetNotCancellable.selector);
        roundManager.cancelSunset();
        assertTrue(roundManager.isSunset(), "the sunset stands");
    }

    function test_cancelSunsetNeedsAnAnnouncement() public {
        vm.prank(STEWARD);
        vm.expectRevert(RoundManager.SunsetNotCancellable.selector);
        roundManager.cancelSunset();
    }

    /// @dev The edge currency's ledger key: $DOLL.
    Currency internal constant EDGE = Currency.wrap(DOLL_ADDRESS);
    /// @dev The attribution the EDGE fee is queued under: the terminal canonical index, which for
    /// a $DOLL -> link-one buy is 1. The edge is not at index 0.
    uint256 internal constant QUEUE_KEY = 1;

    /// @dev Declared locally so that {vm.expectEmit} can name them before the vault does.
    event SuccessorDeclaredDead(address indexed successor, uint256 attribution, uint256 amount);
    event SuccessorDeliveryFailed(uint256 indexed attribution, bytes reason);
    event SuccessorUnresolved(address indexed successor);
    event SuccessorDeliveryEvidenceCleared(uint256 indexed attribution);

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
    // A successor that never answers may not freeze the queue forever
    // ---------------------------------------------------------------------------------

    /// @dev Sunset this version in favour of a stack that RESOLVES to a vault which refuses every
    /// delivery, and charge one edge fee so that the forward queue holds something. A successor
    /// that does not resolve at all is a different case entirely and is never
    /// evidence of a dead one, so the recovery path has to be exercised against a real refusal.
    function _queueBehindADeadSuccessor() internal returns (address stub, uint256 fee) {
        FlakySuccessorVault v = new FlakySuccessorVault();
        v.setFailing(true);
        stub = _sunsetTowards(address(v));
        // the canonical router attributes the edge to the terminal index, so the queue key is 0
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    /// @notice The queue is not allowed to depend entirely on a successor that
    /// answers: the escape is TWO-PHASE. The first full-budget failure only
    /// records evidence against that attribution and forwards nothing; only a SECOND full-budget
    /// failure, {FeeVault.DEAD_SUCCESSOR_DELAY} after the first, books the fee here.
    function test_aDeadSuccessorCannotFreezeTheQueueForever() public {
        (address stub, uint256 fee) = _queueBehindADeadSuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        // PHASE ONE: the successor's vault refuses the delivery, which is said out loud, and the
        // failure is recorded rather than acted on
        uint64 evidenceAt = uint64(block.timestamp);
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorDeliveryFailed(attribution, "");
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "nothing is forwarded on the first failure");
        assertEq(vault.deadEvidenceAt(attribution), evidenceAt, "the clock starts HERE, on evidence");
        assertEq(vault.pendingForward(attribution), fee, "still queued");
        assertEq(vault.devBalance(), devBefore, "and nothing booked locally");
        _assertSolvent();

        // inside the timelock the fee stays queued: the successor may still come to life
        vm.warp(uint256(evidenceAt) + 29 days);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "still nothing");
        assertEq(vault.pendingForward(attribution), fee, "still queued");
        assertEq(vault.devBalance(), devBefore, "still nothing booked");

        // PHASE TWO: the delay has run out behind the recorded evidence AND this attempt failed
        vm.warp(uint256(evidenceAt) + 30 days + 1);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SuccessorDeclaredDead(stub, attribution, fee);
        uint256 flushed = vault.flushForward(attribution, type(uint256).max);

        assertEq(flushed, fee, "the whole queued fee was recovered");
        assertEq(vault.pendingForward(attribution), 0, "the queue is empty");
        assertEq(vault.pendingForwardTotal(), 0, "and so is its total");
        assertGt(vault.devBalance() - devBefore, 0, "booked with this version's split");
        _assertSolvent();
    }

    /// @notice A successor that does not RESOLVE YET is not a successor that is
    /// DEAD. The registry names a stack whose vault is still to be deployed at the address its
    /// factory already publishes; until that address has code there is no delivery attempt to
    /// fail, so the flush says so and records NOTHING. Counting an unresolved hop as evidence let
    /// this version take the whole queue for itself thirty days into a handover that was merely
    /// unfinished, without one real delivery ever having been refused.
    function test_anUnresolvedSuccessorIsNeverEvidenceOfADeadOne() public {
        // the address the successor's factory publishes, before anything is deployed at it
        address predicted = address(0xFEE7A17);
        address successor = _sunsetTowards(predicted);
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        uint256 fee = 1 ether / 100;
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();
        assertEq(vault.pendingForward(attribution), fee, "the edge is queued, not booked");

        // day 0, full gas: the resolution fails, which is said out loud and is all that happens
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorUnresolved(successor);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "there is nobody to deliver to");
        assertEq(vault.deadEvidenceAt(attribution), 0, "an unresolved successor is not evidence");

        // day 31, full gas: a month of the same answer is still not evidence, and the timelock
        // has nothing to run against
        vm.warp(block.timestamp + 31 days);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "still nothing forwarded");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and still no evidence");
        assertEq(vault.pendingForward(attribution), fee, "the fee is still the successor's");
        assertEq(vault.devBalance(), devBefore, "nothing was booked locally");
        _assertSolvent();

        // the vault is deployed at the address the factory always named, and the queue goes
        // where it belongs
        vm.etch(predicted, address(new FlakySuccessorVault()).code);
        assertEq(vault.flushForward(attribution, type(uint256).max), fee, "delivered");
        assertEq(vault.pendingForward(attribution), 0, "the queue is empty");
        assertEq(doll.balanceOf(predicted), fee, "the successor really has the $DOLL");
        _assertSolvent();
    }

    /// @notice THE PROPERTY. The clock runs on evidence about the successor itself, NOT on when
    /// the queue filled: a perfectly healthy successor that simply had nothing pushed to it for
    /// thirty days is never declared dead by the very FIRST flush ever made, on one transient
    /// revert. It takes two full-budget failures a month apart, and one transient revert is not
    /// two.
    function test_aHealthySuccessorCannotBeDeclaredDead() public {
        (FlakySuccessorVault successorVault, uint256 fee) = _queueBehindAFlakySuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        // the OLD clock is long expired: the queue has been sitting here for a month
        uint64 flushedAt = uint64(block.timestamp + 30 days + 1);
        vm.warp(flushedAt);

        // ...and the successor reverts once, the way a live contract transiently can
        successorVault.setFailing(true);
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "the transient revert forwards nothing");
        assertEq(vault.devBalance(), devBefore, "and books NOTHING locally: one revert is not evidence enough");
        assertEq(vault.pendingForward(attribution), fee, "the fee is still the successor's");
        assertEq(vault.deadEvidenceAt(attribution), flushedAt, "it only started the clock");
        _assertSolvent();

        // the successor is healthy again, so the very next flush delivers
        successorVault.setFailing(false);
        uint256 flushed = vault.flushForward(attribution, type(uint256).max);
        assertEq(flushed, fee, "delivered");
        assertEq(doll.balanceOf(address(successorVault)), fee, "the successor really has the $DOLL");
        assertEq(vault.devBalance(), devBefore, "still nothing booked here");
        _assertSolvent();
    }

    /// @notice ...and a delivery WITHDRAWS the evidence, so a successor that has one bad month
    /// does not carry a half-spent death sentence forever.
    function test_evidenceClearsOnDelivery() public {
        (FlakySuccessorVault successorVault, uint256 fee) = _queueBehindAFlakySuccessor();
        uint256 attribution = QUEUE_KEY;

        uint64 firstFailureAt = uint64(block.timestamp);
        successorVault.setFailing(true);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), firstFailureAt, "evidence stands");

        // half the queue is delivered: that is proof of life
        successorVault.setFailing(false);
        vm.expectEmit(true, false, false, false, address(vault));
        emit SuccessorDeliveryEvidenceCleared(attribution);
        assertEq(vault.flushForward(attribution, fee / 2), fee / 2, "half forwarded");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and the evidence is withdrawn");

        // so a later failure starts a FRESH thirty days rather than completing the old ones
        uint64 secondFailureAt = firstFailureAt + 29 days;
        vm.warp(secondFailureAt);
        successorVault.setFailing(true);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), secondFailureAt, "the clock restarted here");
        vm.warp(uint256(secondFailureAt) + 29 days);
        uint256 devBefore = vault.devBalance();
        assertEq(vault.flushForward(attribution, type(uint256).max), 0, "29 days is not 30");
        assertEq(vault.devBalance(), devBefore, "nothing booked on the old clock");
        _assertSolvent();
    }

    /// @notice The queue entry and the ledger are debited BEFORE the successor is
    /// called, so at no instant of ITS execution does this vault count the same wei twice - once
    /// as $DOLL already sent and once as still queued. The successor reads the prior vault from
    /// inside `receiveForward` and the numbers it sees are the ones that must hold.
    function test_noTransientDoubleCountDuringTheHandoverCall() public {
        (ObservingSuccessorVault successorVault, uint256 fee) = _queueBehindAnObservingSuccessor();
        uint256 attribution = QUEUE_KEY;

        assertEq(vault.flushForward(attribution, type(uint256).max), fee, "delivered");
        assertEq(successorVault.seenPending(), 0, "the queue no longer counts what is already in flight");
        assertLe(successorVault.seenLedger(), successorVault.seenHoldings(), "and the vault looks solvent throughout");
        _assertSolvent();
    }

    /// @dev Sunset this version in favour of a stack that DOES resolve to a vault, and charge one
    /// edge fee. The in-swap hop fails (the stub has no `accrueForwarded`), so the fee queues
    /// exactly as it does behind a dead successor - but the flush path can reach it.
    function _queueBehindAFlakySuccessor() internal returns (FlakySuccessorVault v, uint256 fee) {
        v = new FlakySuccessorVault();
        _sunsetTowards(address(v));
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    function _queueBehindAnObservingSuccessor() internal returns (ObservingSuccessorVault v, uint256 fee) {
        v = new ObservingSuccessorVault(address(vault));
        _sunsetTowards(address(v));
        familyRouter.buyExactIn(1, 1 ether, 0, address(this), 1);
        fee = 1 ether / 100;
        assertEq(vault.pendingForward(QUEUE_KEY), fee, "the edge is queued, not booked");
    }

    /// @dev Name a successor whose `factory().feeVault()` resolves to `successorVault`.
    function _sunsetTowards(address successorVault) internal returns (address successor) {
        SuccessorFactoryStub f = new SuccessorFactoryStub(successorVault);
        SuccessorRegistryStub reg = new SuccessorRegistryStub(address(f));
        successor = address(reg);
        vm.prank(steward);
        roundManager.announceSunset(successor);
        vm.warp(roundManager.sunsetAt());
    }

    /// @notice ...and a caller cannot declare the successor dead by starving the hop of gas: the
    /// recovery only arms behind a delivery attempt that had the full {FeeVault.FORWARD_GAS}, and
    /// a thin-gas call may not even RECORD the evidence that starts the clock.
    function test_aThinGasFlushCannotDeclareTheSuccessorDead() public {
        (, uint256 fee) = _queueBehindADeadSuccessor();
        uint256 attribution = QUEUE_KEY;
        uint256 devBefore = vault.devBalance();

        (bool ok,) = address(vault).call{gas: 2_000_000}(
            abi.encodeCall(FeeVault.flushForward, (attribution, type(uint256).max))
        );
        assertFalse(ok, "a thin-gas flush is refused");
        assertEq(vault.deadEvidenceAt(attribution), 0, "and it recorded no evidence against the successor");
        assertEq(vault.pendingForward(attribution), fee, "nothing left the queue");
        assertEq(vault.devBalance(), devBefore, "and nothing was booked locally");
        _assertSolvent();

        // the honest calls still work: one to record the evidence, one to act on it
        uint64 recordedAt = uint64(block.timestamp);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.deadEvidenceAt(attribution), recordedAt, "full gas records it");
        vm.warp(uint256(recordedAt) + 30 days + 1);
        vault.flushForward(attribution, type(uint256).max);
        assertEq(vault.pendingForward(attribution), 0, "a second full-gas flush recovers it");
        _assertSolvent();
    }
}

/// @dev A "successor stack" (registry, factory, router and vault in one contract) whose
/// only behaviour is to `sync` an ERC-20 on the PoolManager while the handover hop runs - i.e.
/// inside somebody else's unlock, just before they settle native ETH.
contract SyncGriefer {
    IPoolManager public immutable pm;
    address public immutable token;
    bool public synced;

    constructor(IPoolManager _pm, address _token) {
        pm = _pm;
        token = _token;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function feeVault() external view returns (address) {
        return address(this);
    }

    function router() external view returns (address) {
        return address(this);
    }

    function roundManager() external view returns (address) {
        return address(this);
    }

    function accrueForwarded(uint256, uint256, uint256) external {
        pm.sync(Currency.wrap(token));
        synced = true;
    }

    function receiveForward(uint256, uint256) external {
        pm.sync(Currency.wrap(token));
        synced = true;
    }
}

/// @dev A "successor" that answers every resolution call with a 32-byte word whose
/// upper 96 bits are garbage. `abi.decode(..., (address))` reverts on exactly this.
contract DirtyWordSuccessor {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(type(uint256).max));
    }
}

/// @dev The smallest possible "successor deployment": `announceSunset` only checks for code.
contract Stub {
    uint256 public x;
}

/// @dev A "successor" that answers every call by burning every wei of gas it is given. It has
/// code, so `announceSunset` accepts it; nothing else about it is real.
contract GasBurner {
    function factory() external pure returns (address) {
        _burn();
        return address(0);
    }

    function router() external pure returns (address) {
        _burn();
        return address(0);
    }

    function feeVault() external pure returns (address) {
        _burn();
        return address(0);
    }

    function roundManager() external pure returns (address) {
        _burn();
        return address(0);
    }

    function accrueForwarded(uint256, uint256, uint256) external pure {
        _burn();
    }

    /// @dev Burns until there is nothing left: every call into this contract ends in OutOfGas,
    /// which is exactly what the 63/64 rule turns into a bricked swap when it is not capped.
    function _burn() internal pure {
        uint256 x = 1;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
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

/// @dev A successor vault that takes delivery unless it is switched to failing. The switch is
/// EXTERNAL on purpose: a revert inside `receiveForward` rolls back any state it wrote, so a
/// self-decrementing counter would stay stuck at its initial value forever. It deliberately does
/// NOT implement `accrueForwarded`, so the in-swap hop always fails and the fee queues.
contract FlakySuccessorVault {
    bool public failing;
    uint256 public received;

    function setFailing(bool f) external {
        failing = f;
    }

    function receiveForward(uint256, uint256 amount) external {
        if (failing) revert("transient");
        received += amount;
    }

    receive() external payable {}
}

/// @dev A successor vault that reads the PRIOR vault's books from inside the handover call: what
/// it sees is the state foreign code observes while the hop is in flight.
contract ObservingSuccessorVault {
    FeeVault internal immutable prior;
    uint256 public seenPending;
    uint256 public seenLedger;
    uint256 public seenHoldings;

    constructor(address _prior) {
        prior = FeeVault(payable(_prior));
    }

    function receiveForward(uint256 attribution, uint256) external {
        Currency edge = prior.EDGE();
        seenPending = prior.pendingForward(attribution);
        seenLedger = prior.ledgerTotal(edge);
        seenHoldings = prior.holdings(edge);
    }

    receive() external payable {}
}
