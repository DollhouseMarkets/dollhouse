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
        _setUpFamily();
        _buyGenesis(5 ether);
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
        _setUpFamily();
        _buyGenesis(5 ether);
        assertEq(roundManager.steward(), address(0));

        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        vm.prank(address(0));
        vm.expectRevert(RoundManager.NotSteward.selector);
        roundManager.announceSunset(successorStub);

        // and the chain keeps running forever
        vm.warp(block.timestamp + 365 days);
        _runWinningRound(1, WINNING_BUY);
        assertEq(roundManager.headIndex(), 1, "succession still works");
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
        assertEq(roundManager.headIndex(), 1, "succession works during the delay");

        // one second before the deadline a new round still opens
        vm.warp(roundManager.sunsetAt() - 1);
        assertFalse(roundManager.isSunset());
        _registerCandidate(address(0xA11CE), "LATE");
        assertEq(roundManager.roundCount(), 2, "a round opened one second before the sunset");
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

        assertEq(roundManager.headIndex(), 1, "the in-flight round crowned a new head after sunset");
        assertEq(roundManager.head(), cands[0].token);
        assertEq(roundManager.canonical(1), cands[0].token);
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
        factory.registerCandidate{value: bond}("NO", "NO", "");

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
        uint256 got = familyRouter.buyExactIn{value: 1 ether}(1, 0, address(this), 4);
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
        bidDeployer.deployGenesisBid();

        // 4. the history is intact and still readable
        assertEq(roundManager.headIndex(), 1);
        assertEq(roundManager.canonical(0), address(token));
        assertEq(roundManager.canonical(1), link1);
        assertEq(roundManager.parentOf(link1), address(token));
        assertEq(roundManager.indexOf(link1), 1);
        assertTrue(roundManager.isCanonical(link1));
        FamilyLens.LinkView[] memory links = lens.chainView(0, 1);
        assertEq(links.length, 2);
        assertEq(links[1].token, link1);

        // 5. the finalized round is still finalizable-idempotent and reports the same result
        roundManager.finalize();
        assertTrue(roundManager.roundInfo(roundManager.roundCount()).hasWinner);
        _assertSolvent();
    }

    // ---------------------------------------------------------------------------------
    // F2: a hostile successor may not brick trading, and the steward has one way back
    // ---------------------------------------------------------------------------------

    /// @notice THE BRICKING BUG (audit F2). `announceSunset` only checks that the successor has
    /// CODE. A successor whose `factory()` and `accrueForwarded` burn every wei of gas they are
    /// given used to make every swap of every pool of this version revert: the hook staticalled
    /// it unbounded on every swap, and the vault handed it 63/64 of the gas, leaving too little
    /// behind for the Fenwick booking. The switch is irreversible, so that was permanent.
    ///
    /// Here the same successor is named and the same swaps must still go through - the genesis
    /// pool (which pays the forwarded ETH edge) and a candidate pool (which pays the hook's
    /// attribution resolution) - with bounded gas.
    /// @notice AUDIT 7B - `sync(ERC20)` INSIDE THE UNLOCK. The PoolManager keeps ONE transient
    /// "currency being synced" slot. A successor that syncs an ERC-20 while the handover hop runs
    /// (it is called from inside the swap) left that slot pointing at a token, and the router's
    /// native `settle{value}` afterwards was credited against the wrong currency - the whole
    /// route reverted. The router and the Locker now `sync(native)` immediately before every
    /// native settle, so nothing another contract did earlier in the unlock can matter.
    function test_aSuccessorSyncingAnErc20DoesNotBreakNativeSettlement() public {
        SyncGriefer griefer = new SyncGriefer(im, address(token));
        vm.prank(STEWARD);
        roundManager.announceSunset(address(griefer));
        vm.warp(roundManager.sunsetAt());

        // a normal ETH-funded route: the edge is forwarded to the griefer mid-swap, which syncs
        // an ERC-20 before the router settles its native input
        uint256 devBefore = vault.devBalance();
        uint256 out = familyRouter.buyExactIn{value: 1 ether}(0, 0, address(this), 2);
        assertGt(out, 0, "the route settled its native input anyway");
        assertTrue(griefer.synced(), "...and the successor really did sync an ERC-20 first");
        assertEq(vault.devBalance(), devBefore, "the edge was not booked here (audit 4)");

        // the Locker's native settle is on the same footing: a genesis bid still places
        _warmOracles();
        assertGt(bidDeployer.deployGenesisBid(), 0, "the Locker settled native ETH too");
    }

    /// @notice AUDIT 7A - THE DIRTY WORD. A successor that answers with a well-formed 32-byte
    /// word whose upper 96 bits are not zero made `abi.decode(ret, (address))` REVERT inside the
    /// hook - and that revert happened in `beforeSwap`, so every attributed third-party route
    /// through this version failed for good. The word is now validated instead of decoded: it is
    /// simply "no answer", cached negative like any other failed resolution.
    function test_aDirtyWordSuccessorCannotBrickRoutes() public {
        Cand memory c = _registerCandidate(address(0xC0DE), "CAND");
        (uint64 tradingStart,,) = _roundTimes(roundManager.roundCount());
        vm.warp(tradingStart + 10);

        address dirty = address(new DirtyWordSuccessor());
        vm.prank(STEWARD);
        roundManager.announceSunset(dirty);
        vm.warp(roundManager.sunsetAt());

        // the genesis pool still swaps
        assertGt(_buyGenesis(1 ether), 0, "the genesis swap went through");

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
        uint256 out = _buyGenesis(1 ether);
        uint256 firstGas = g - gasleft();
        assertGt(out, 0, "the genesis swap went through");
        // AUDIT 4: the fee is QUEUED for a later flush, never booked here - the gas of a swap no
        // longer decides which version receives a post-sunset fee
        assertEq(vault.devBalance(), devBefore, "nothing was booked locally");
        assertEq(vault.pendingForwardTotal(), 1e16, "the edge is queued for a flush");
        assertTrue(vault.forwardingFailed(), "the failed hop is cached, once");

        // 2. the next swap must not pay for the burner AGAIN (negative resolution cached)
        g = gasleft();
        _buyGenesis(1 ether);
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
        assertEq(roundManager.roundCount(), 1, "a round opened after the cancelled sunset");

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
}

/// @dev AUDIT 7B: a "successor stack" (registry, factory, router and vault in one contract) whose
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

    function receiveForward(uint256) external payable {
        pm.sync(Currency.wrap(token));
        synced = true;
    }
}

/// @dev AUDIT 7A: a "successor" that answers every resolution call with a 32-byte word whose
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

/// @dev F2: a "successor" that answers every call by burning every wei of gas it is given. It has
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
