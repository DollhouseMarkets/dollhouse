// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FamilyFactory} from "../../contracts/FamilyFactory.sol";
import {FamilyRouter} from "../../contracts/FamilyRouter.sol";
import {BidDeployer} from "../../contracts/BidDeployer.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";
import {Locker} from "../../contracts/Locker.sol";
import {RoundManager} from "../../contracts/RoundManager.sol";
import {ILocker} from "../../contracts/interfaces/ILocker.sol";
import {StandardCurve} from "../../contracts/libraries/StandardCurve.sol";
import {CurveRange} from "../../contracts/types/CurveRange.sol";
import {FamilyToken} from "../../contracts/FamilyToken.sol";
import {MockDoll} from "./MockDoll.sol";
import {MockVenueOracle} from "./MockVenueOracle.sol";

/// @dev Random-action driver for the invariant suite. Every action is wrapped in `try` so that a
/// legitimately-reverting call (wrong phase, empty pool, band guard) does not end the run; the
/// ghost state it maintains is what the invariants are checked against.
contract FamilyHandler is CommonBase, StdCheats, StdUtils {
    using StateLibrary for IPoolManager;

    struct Position {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
    }

    IPoolManager public immutable poolManager;
    FamilyFactory public immutable factory;
    RoundManager public immutable roundManager;
    FamilyRouter public immutable router;
    FeeVault public immutable vault;
    BidDeployer public immutable bidDeployer;
    Locker public immutable locker;
    PoolSwapTest public immutable swapRouter;
    /// @notice The edge currency, canonical index 0. Every route this handler drives
    /// starts and ends here, and the candidate bond is posted in it.
    MockDoll public immutable edge;

    /// @notice Every token the family has ever launched, and its supply when first seen.
    address[] public tokens;
    mapping(address => uint256) public supplySeen;
    mapping(address => bool) public known;

    /// @notice Every locked position the protocol has ever created, and the most liquidity it
    /// has ever been observed holding.
    Position[] public positions;
    mapping(bytes32 => uint128) public maxLiquidity;
    mapping(bytes32 => bool) internal positionKnown;

    /// @notice Canonical history as it was first observed: it must never be rewritten.
    mapping(uint256 => address) public canonicalSeen;
    uint256 public canonicalSeenCount;

    uint256 public calls;

    /// @notice Coverage ghosts: the invariant run is worthless if these stay at zero.
    uint256 public deploysSucceeded;
    uint256 public successions;
    uint256 public claims;
    /// @dev How often each path was actually REACHED, so the invariant can demand a success
    /// only of the runs that gave it the opportunity.
    uint256 public deployAttempts;
    uint256 public successionAttempts;
    uint256 public claimAttempts;

    /// @notice START-RULE GHOSTS. The venue oracle the factory was built against, when the suite
    /// fuzzes it (zero otherwise); every {FamilyFactory.StartPriced} seen and how many of those
    /// opened outside [Y, X] of the parent's supply; and how many registrations reverted ONLY
    /// because of the oracle's state (the same call, retried against a sane oracle, succeeds).
    MockVenueOracle public oracle;
    uint256 public startsChecked;
    uint256 public startsOutOfBand;
    uint256 public oracleCausedReverts;

    /// @notice POOL-START GHOSTS. Every candidate's pool opens at its own registration
    /// (`c.tradingStart == block.timestamp`), and no later than
    /// `max(r.tradingStart, T - W - RANDOM_END_S)`, so a scored window never starts before a
    /// pool existed. Counts every registration checked and every one that broke either rule.
    uint256 public poolStartsChecked;
    uint256 public poolStartsOutOfRule;
    /// @notice How many of the pool-start checks above landed on a LATE entrant (registered at
    /// or after `r.registrationEnd`, on a round long enough to offer one). Coverage only — the
    /// random walk rarely reaches a round long enough to offer late entry, so this is not
    /// asserted against in {InvariantsTest}; the guarantee it would check is pinned instead by
    /// the deterministic `InstantTradingTest.test_lateEntrantIsScoredFromTEndMinusWWithNoFloorBinding`.
    uint256 public lateEntryChecked;

    /// @notice FINALIZE-GATE GHOSTS. Every finalize that actually closed a round, how many of those
    /// closed it BEFORE `submitEnd` (the early path, which needs every candidate's score in), and
    /// how many broke the gate: closed before `submitEnd` with some candidate of the round still
    /// unsubmitted. The "every candidate submitted" fact is recomputed here from the candidates'
    /// own `submitted` flags, independently of the contract's `submittedCount`.
    uint256 public finalizesChecked;
    uint256 public earlyFinalizes;
    uint256 public finalizesOutOfGate;

    /// @notice THE NEGATIVE BRANCH OF THE FINALIZE GATE. How many times
    /// {attemptFinalizeWithMissingScore} deliberately withheld one candidate's score and tried to
    /// finalize before `submitEnd` anyway, and how many of those the contract actually refused.
    /// Without this pair, `invariant_finalizeNeverRunsBeforeEveryScoreOrSubmitEnd` could pass
    /// vacuously forever: the random walk almost never happens to call `finalize` with a score
    /// missing on its own, so the gate's refusal path would never be exercised.
    uint256 public missingScoreFinalizeAttempts;
    uint256 public missingScoreFinalizeRefused;

    constructor(
        FamilyFactory _factory,
        FamilyRouter _router,
        FeeVault _vault,
        BidDeployer _bidDeployer,
        PoolSwapTest _swapRouter
    ) {
        factory = _factory;
        router = _router;
        vault = _vault;
        bidDeployer = _bidDeployer;
        swapRouter = _swapRouter;
        poolManager = _factory.poolManager();
        roundManager = _factory.roundManager();
        locker = _factory.locker();
        edge = MockDoll(_factory.genesisToken());
        edge.mint(address(this), 10_000_000 ether);
        edge.approve(address(_factory), type(uint256).max);
        edge.approve(address(_router), type(uint256).max);
        edge.approve(address(_bidDeployer), type(uint256).max);
        edge.approve(address(_swapRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // ghost bookkeeping
    // ---------------------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function _noteToken(address t) internal {
        if (t == address(0) || known[t]) return;
        known[t] = true;
        tokens.push(t);
        supplySeen[t] = IERC20(t).totalSupply();
        IERC20(t).approve(address(swapRouter), type(uint256).max);
        IERC20(t).approve(address(router), type(uint256).max);
    }

    function notePosition(PoolId poolId, int24 tickLower, int24 tickUpper) public {
        bytes32 k = keccak256(abi.encode(poolId, tickLower, tickUpper));
        if (!positionKnown[k]) {
            positionKnown[k] = true;
            positions.push(Position({poolId: poolId, tickLower: tickLower, tickUpper: tickUpper}));
        }
    }

    /// @dev Called after every action: liquidity may only ever grow, so the maximum observed is
    /// the floor the invariant checks against.
    function _snapshot() internal {
        for (uint256 i = 0; i < positions.length; i++) {
            Position memory p = positions[i];
            (uint128 liq,,) = poolManager.getPositionInfo(p.poolId, address(locker), p.tickLower, p.tickUpper, 0);
            bytes32 k = keccak256(abi.encode(p.poolId, p.tickLower, p.tickUpper));
            if (liq > maxLiquidity[k]) maxLiquidity[k] = liq;
        }
        uint256 head = roundManager.headIndex();
        for (uint256 i = canonicalSeenCount; i <= head; i++) {
            canonicalSeen[i] = roundManager.canonical(i);
            canonicalSeenCount = i + 1;
            _noteToken(canonicalSeen[i]);
        }
    }

    // ---------------------------------------------------------------------------------
    // actions
    // ---------------------------------------------------------------------------------

    function buy(uint256 targetSeed, uint256 dollIn) external {
        calls++;
        uint256 head = roundManager.headIndex();
        // index 0 is the edge currency itself: the shortest real route is 0 -> 1
        if (head == 0) return;
        uint256 target = 1 + (targetSeed % head);
        dollIn = bound(dollIn, 0.001 ether, 20 ether);
        try router.buyExactIn(target, dollIn, 0, address(this), target + 1) {} catch {}
        _snapshot();
    }

    function sell(uint256 targetSeed, uint256 amountSeed) external {
        calls++;
        uint256 head = roundManager.headIndex();
        if (head == 0) return;
        uint256 target = 1 + (targetSeed % head);
        address t = roundManager.canonical(target);
        uint256 balance = IERC20(t).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        try router.sellExactIn(target, amount, 0, address(this), target + 1) {} catch {}
        _snapshot();
    }

    function setOracle(MockVenueOracle o) external {
        oracle = o;
    }

    /// @dev A random oracle answer: any price (biased towards a plausible band), any status,
    /// any clamped streak, and sometimes a revert, a gas burn, a short or an out-of-range answer.
    function fuzzOracle(uint256 priceSeed, uint256 statusSeed, uint256 modeSeed) external {
        calls++;
        if (address(oracle) == address(0)) return;
        uint160 price = priceSeed % 2 == 0
            ? uint160(bound(priceSeed, uint256(1) << 80, uint256(1) << 112))
            : uint160(bound(priceSeed, 0, type(uint160).max));
        uint8 status = statusSeed % 3 == 0 ? uint8(statusSeed >> 8) : 0;
        uint8 mode = uint8(modeSeed % 10);
        oracle.set(price, status, uint32(statusSeed >> 16), mode > 4 ? 0 : mode);
    }

    /// @dev Every start priced in `logs` must lie within [Y, X] of its parent's supply.
    function _checkStarts(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != FamilyFactory.StartPriced.selector) {
                continue;
            }
            (,, uint256 cap,,) = abi.decode(logs[i].data, (uint160, uint256, uint256, uint256, uint16));
            uint256 supply = IERC20(address(uint160(uint256(logs[i].topics[2])))).totalSupply();
            uint256 lo = (supply * factory.START_MIN_PARENT_WAD()) / 1e18;
            uint256 hi = (supply * factory.START_MAX_PARENT_BPS()) / 10_000;
            startsChecked++;
            if (cap < lo || cap > hi || cap == 0) startsOutOfBand++;
        }
    }

    /// @dev A registration reverted: retry it against a sane oracle and put the state back. If
    /// the retry succeeds, the oracle's state alone made registration revert.
    function _checkOracleRevert() internal {
        if (address(oracle) == address(0)) return;
        (uint160 p, uint8 st, uint32 sk, uint8 m) = (oracle.sqrtP(), oracle.status(), oracle.streak(), oracle.mode());
        if (m == 0 && st == 0 && p != 0) return; // already sane: nothing to blame on the oracle
        uint256 snap = vm.snapshotState();
        oracle.set(uint160(uint256(1) << 96), 0, 0, 0);
        try factory.registerCandidate("H", "H", "", type(uint256).max) {
            oracleCausedReverts++;
        } catch {}
        vm.revertToState(snap);
        sk;
    }

    function registerCandidate(uint256 seed) external {
        calls++;
        uint256 bond = roundManager.currentBond();
        _registerOneCandidate();
        seed;
        bond;
        _snapshot();
    }

    /// @dev Shared registration body: {registerCandidate} and {attemptFinalizeWithMissingScore}'s
    /// own guaranteed-fresh candidate both run it, so `poolStartsChecked` and every other
    /// registration ghost (tokens, positions) reflect EVERY candidate this harness ever
    /// registers, through either path, rather than only the ones that went through the
    /// dedicated action.
    function _registerOneCandidate() internal returns (bool ok) {
        vm.recordLogs();
        try factory.registerCandidate("H", "H", "", type(uint256).max) returns (
            address token, PoolKey memory key, uint256 id
        ) {
            _checkStarts(vm.getRecordedLogs());
            _noteToken(token);
            (CurveRange[] memory ranges,) = StandardCurve.build(
                factory.curveSpec(),
                factory.curveBasisOf(token),
                FamilyToken(token).TOTAL_SUPPLY(),
                factory.TICK_SPACING(),
                Currency.unwrap(key.currency0) == token
            );
            for (uint256 i = 0; i < ranges.length; i++) {
                notePosition(key.toId(), ranges[i].tickLower, ranges[i].tickUpper);
            }
            _checkPoolStart(id);
            _candidates.push(id);
            ok = true;
        } catch {
            _checkOracleRevert();
            ok = false;
        }
    }

    uint256[] internal _candidates;

    /// @dev The candidate just registered opened its pool now, and at or before
    /// `max(r.tradingStart, T - W - RANDOM_END_S)`.
    function _checkPoolStart(uint256 id) internal {
        RoundManager.Candidate memory c = roundManager.candidateInfo(id);
        RoundManager.Round memory r = roundManager.roundInfo(c.roundId);
        uint64 reach = roundManager.closingWindowFor(c.roundId) + roundManager.RANDOM_END_S();
        uint64 latest = r.nominalEnd > reach ? r.nominalEnd - reach : 0;
        if (latest < r.tradingStart) latest = r.tradingStart;
        poolStartsChecked++;
        if (c.tradingStart != block.timestamp || c.tradingStart > latest) poolStartsOutOfRule++;
        if (factory.hook().poolInfo(c.key.toId()).tradingStart != c.tradingStart) poolStartsOutOfRule++;
        if (r.lateEntryEnd != 0 && c.tradingStart >= r.registrationEnd) lateEntryChecked++;
    }

    function tradeCandidate(uint256 seed, uint256 amountSeed) external {
        calls++;
        if (_candidates.length == 0) return;
        RoundManager.Candidate memory c = roundManager.candidateInfo(_candidates[seed % _candidates.length]);
        address parent = roundManager.head();
        uint256 balance = IERC20(parent).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        bool zeroForOne = Currency.unwrap(c.key.currency0) == parent;
        try swapRouter.swap(
            c.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
        _snapshot();
    }

    /// @dev A deterministic, successful succession: the random walk almost never clears the
    /// threshold on its own, and the invariants must see head changes.
    function forceSuccession(uint256 amountSeed) external {
        calls++;
        // close whatever round is open first (the random walk leaves rounds hanging)
        if (roundManager.roundCount() != 0 && !roundManager.roundInfo(roundManager.roundCount()).finalized) {
            RoundManager.Round memory open = roundManager.roundInfo(roundManager.roundCount());
            _settleEnd();
            for (uint256 i = 0; i < _candidates.length; i++) {
                try roundManager.submitScore(_candidates[i]) {} catch {}
            }
            open = roundManager.roundInfo(roundManager.roundCount());
            // early when every score is in; otherwise wait out the window
            if (block.timestamp < open.submitEnd && !_allSubmitted(roundManager.roundCount())) {
                vm.warp(open.submitEnd);
            }
            _finalizeChecked();
            delete _candidates;
        }
        uint256 head = roundManager.headIndex();
        try router.buyExactIn(head, 5 ether, 0, address(this), head + 1) {} catch {}

        address parent = roundManager.head();
        uint256 balance = IERC20(parent).balanceOf(address(this));
        if (balance < 4_000_000e18) return;
        successionAttempts++;

        uint256 bond = roundManager.currentBond();
        vm.recordLogs();
        (address token, PoolKey memory key, uint256 id) = factory.registerCandidate("W", "W", "", type(uint256).max);
        _checkStarts(vm.getRecordedLogs());
        _checkPoolStart(id);
        _noteToken(token);
        {
            (CurveRange[] memory ranges,) = StandardCurve.build(
                factory.curveSpec(),
                factory.curveBasisOf(token),
                FamilyToken(token).TOTAL_SUPPLY(),
                factory.TICK_SPACING(),
                Currency.unwrap(key.currency0) == token
            );
            for (uint256 i = 0; i < ranges.length; i++) {
                notePosition(key.toId(), ranges[i].tickLower, ranges[i].tickUpper);
            }
        }

        RoundManager.Round memory r = roundManager.roundInfo(roundManager.roundCount());
        vm.warp(r.tradingStart + 5);
        uint256 amount = bound(amountSeed, 4_000_000e18, balance);
        bool zeroForOne = Currency.unwrap(key.currency0) == parent;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _settleEnd();
        roundManager.submitScore(id);
        r = roundManager.roundInfo(roundManager.roundCount());
        if (!_allSubmitted(roundManager.roundCount())) vm.warp(r.submitEnd);
        uint256 headBefore = roundManager.headIndex();
        _finalizeChecked();
        if (roundManager.headIndex() != headBefore) successions++;
        delete _candidates;
        _snapshot();
    }

    /// @dev Exercise the pull-claim paths so the invariant run proves they are reachable.
    function claimFees(uint256 seed) external {
        calls++;
        // an attributed buy through the canonical router funds the dev and creator ledgers
        if (vault.devBalance() == 0) {
            try router.buyExactIn(roundManager.headIndex(), 0.5 ether, 0, address(this), 64) {} catch {}
        }
        claimAttempts++;
        address t = roundManager.canonical(roundManager.headIndex());
        address recipient = vault.creatorRecipient(t);
        if (recipient != address(0) && vault.creatorBalance(t) != 0) {
            vm.prank(recipient);
            try vault.claimCreator(t, recipient) returns (uint256) {
                claims++;
            } catch {}
        }
        if (vault.devBalance() != 0) {
            address dev = vault.developer();
            vm.prank(dev);
            try vault.claimDev(dev) returns (uint256) {
                claims++;
            } catch {}
        }
        seed;
        _snapshot();
    }

    function advanceTime(uint256 seconds_) external {
        calls++;
        vm.warp(block.timestamp + bound(seconds_, 1, 400));
        _snapshot();
    }

    function submitAndFinalize() external {
        calls++;
        _settleEnd();
        for (uint256 i = 0; i < _candidates.length; i++) {
            try roundManager.submitScore(_candidates[i]) {} catch {}
        }
        if (_finalizeChecked()) delete _candidates;
        _snapshot();
    }

    /// @dev NEGATIVE BRANCH: deliberately withholds the last candidate's score and attempts
    /// `finalize()` before `submitEnd` anyway. The call must be refused (`SubmissionWindowOpen`):
    /// a success here is exactly what `finalizesOutOfGate` (via `_finalizeChecked`) already
    /// treats as a failure, so this action's only job is to make sure that branch is actually
    /// reachable instead of merely never tried.
    ///
    /// Registers one FRESH candidate of its own BEFORE settling the end (registration closes
    /// once trading ends, so it must happen first), rather than relying on the random walk to
    /// have left one of the round's existing candidates unsubmitted: a candidate registered in
    /// this very call is guaranteed unsubmitted, which is what makes the missing-score state
    /// below reachable on demand instead of by luck.
    ///
    /// Whatever happens above, the LAST thing this call does is submit every outstanding score
    /// and retry finalize. Without that cleanup, a fresh candidate this action registers but
    /// never gets to (the round was not yet settled, or was already past `submitEnd`) would sit
    /// permanently unsubmitted, which would push EVERY later `submitAndFinalize` / `forceSuccession`
    /// on that round past the early path for good - exactly the coverage this harness also has to
    /// prove (`earlyFinalizes`), so this action must never be the reason it goes unreached.
    function attemptFinalizeWithMissingScore() external {
        calls++;
        _registerOneCandidate();
        _settleEnd();
        uint256 roundId = roundManager.roundCount();
        if (roundId != 0) {
            RoundManager.Round memory r = roundManager.roundInfo(roundId);
            bool ready = !r.finalized && r.tradingEnd != 0 && block.timestamp < r.submitEnd && _candidates.length >= 1;
            if (ready) {
                // submit every score except the last candidate's
                for (uint256 i = 0; i + 1 < _candidates.length; i++) {
                    try roundManager.submitScore(_candidates[i]) {} catch {}
                }
                if (!roundManager.candidateInfo(_candidates[_candidates.length - 1]).submitted) {
                    missingScoreFinalizeAttempts++;
                    if (_finalizeChecked()) delete _candidates;
                    else missingScoreFinalizeRefused++;
                }
            }
            // cleanup: submit whatever is still outstanding (a no-op for anything already
            // submitted) and retry finalize, so nothing this call touched is left orphaned
            for (uint256 i = 0; i < _candidates.length; i++) {
                try roundManager.submitScore(_candidates[i]) {} catch {}
            }
            if (_finalizeChecked()) delete _candidates;
        }
        _snapshot();
    }

    /// @dev Every candidate registered in `roundId` has a score, read off the candidates themselves.
    function _allSubmitted(uint256 roundId) internal view returns (bool) {
        uint256[] memory ids = roundManager.candidateIds(roundId);
        for (uint256 i = 0; i < ids.length; i++) {
            if (!roundManager.candidateInfo(ids[i]).submitted) return false;
        }
        return true;
    }

    /// @dev `finalize()` under the gate ghost: a call that closes the round must find the round's
    /// `submitEnd` passed or every candidate's score in. Returns whether the round is now final.
    function _finalizeChecked() internal returns (bool closed) {
        uint256 roundId = roundManager.roundCount();
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        bool wasFinal = r.finalized;
        bool allIn = _allSubmitted(roundId);
        try roundManager.finalize() {} catch {}
        closed = roundManager.roundInfo(roundId).finalized;
        if (closed && !wasFinal) {
            finalizesChecked++;
            if (block.timestamp < r.submitEnd) {
                earlyFinalizes++;
                if (!allIn) finalizesOutOfGate++;
            }
            if (r.tradingEnd == 0) finalizesOutOfGate++;
        }
    }

    function deploySupport(uint256 seed) external {
        calls++;
        // Give the keeper path a fair shot: two spaced EDGE buys fund every $DOLL pot AND leave
        // link one's oracle with two observations more than OBS_MIN_SPACING apart, which is what
        // the band guard now insists on.
        try router.buyExactIn(1, 0.5 ether, 0, address(this), 1) {} catch {}
        vm.warp(block.timestamp + 200);
        try router.buyExactIn(1, 0.05 ether, 0, address(this), 1) {} catch {}
        uint256 head = roundManager.headIndex();
        uint256 j = head == 0 ? 0 : seed % (head + 1);
        // the band guard needs a TWAP that covers the whole window, so let the clock run
        vm.warp(block.timestamp + 2_000);
        vm.recordLogs();
        // the edge bid is always attempted: it is the one deployment that needs no keeper
        // capital, so a run that never manages an ancestor deploy still exercises the path
        deployAttempts++;
        try bidDeployer.deployEdgeBid() returns (uint256) {
            deploysSucceeded++;
        } catch {}
        if (j != 0) {
            address parent = roundManager.canonical(j - 1);
            uint256 balance = IERC20(parent).balanceOf(address(this));
            uint256 amount = balance / 1000;
            if (amount != 0) {
                IERC20(parent).approve(address(bidDeployer), type(uint256).max);
                // v3: the purse goes to the generation's trunk link, nowhere else
                try bidDeployer.deployAncestor(j, amount) returns (uint256) {
                    deploysSucceeded++;
                } catch {}
            }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(locker) || logs[i].topics[0] != ILocker.BidDeposited.selector) continue;
            (, int24 tickLower, int24 tickUpper,) = abi.decode(logs[i].data, (uint256, int24, int24, uint128));
            notePosition(PoolId.wrap(logs[i].topics[1]), tickLower, tickUpper);
        }
        _snapshot();
    }

    /// @dev Settle the current round's random end at `T` (word 0), if it is due and unsettled.
    function _settleEnd() internal {
        uint256 roundId = roundManager.roundCount();
        if (roundId == 0) return;
        RoundManager.Round memory r = roundManager.roundInfo(roundId);
        if (r.finalized || r.tradingEnd != 0) return;
        if (block.timestamp < r.nominalEnd) vm.warp(r.nominalEnd);
        try roundManager.requestEnd() returns (bytes32) {} catch {}
        try roundManager.fulfilEnd("") returns (uint64) {} catch {}
    }

    receive() external payable {}
}
