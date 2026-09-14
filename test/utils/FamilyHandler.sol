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

    /// @notice Coverage ghosts (M6): the invariant run is worthless if these stay at zero.
    uint256 public deploysSucceeded;
    uint256 public successions;
    uint256 public claims;
    /// @dev How often each path was actually REACHED, so the invariant can demand a success
    /// only of the runs that gave it the opportunity.
    uint256 public deployAttempts;
    uint256 public successionAttempts;
    uint256 public claimAttempts;

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
        vm.deal(address(this), 10_000 ether);
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

    function buy(uint256 targetSeed, uint256 ethIn) external {
        calls++;
        uint256 target = roundManager.headIndex() == 0 ? 0 : targetSeed % (roundManager.headIndex() + 1);
        ethIn = bound(ethIn, 0.001 ether, 20 ether);
        try router.buyExactIn{value: ethIn}(target, 0, address(this), target + 1) {} catch {}
        _snapshot();
    }

    function sell(uint256 targetSeed, uint256 amountSeed) external {
        calls++;
        uint256 head = roundManager.headIndex();
        uint256 target = head == 0 ? 0 : targetSeed % (head + 1);
        address t = roundManager.canonical(target);
        uint256 balance = IERC20(t).balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        try router.sellExactIn(target, amount, 0, address(this), target + 1) {} catch {}
        _snapshot();
    }

    function registerCandidate(uint256 seed) external {
        calls++;
        uint256 bond = roundManager.currentBond();
        address parent = roundManager.head();
        uint256 parentSupply = IERC20(parent).totalSupply();
        try factory.registerCandidate{value: bond}("H", "H", "") returns (
            address token, PoolKey memory key, uint256 id
        ) {
            _noteToken(token);
            (CurveRange[] memory ranges,) = StandardCurve.build(
                factory.curveSpec(),
                parentSupply,
                FamilyToken(token).TOTAL_SUPPLY(),
                factory.TICK_SPACING(),
                Currency.unwrap(key.currency0) == token
            );
            for (uint256 i = 0; i < ranges.length; i++) {
                notePosition(key.toId(), ranges[i].tickLower, ranges[i].tickUpper);
            }
            _candidates.push(id);
            seed;
        } catch {}
        _snapshot();
    }

    uint256[] internal _candidates;

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
            if (block.timestamp < open.submitEnd) vm.warp(open.submitEnd);
            roundManager.finalize();
            delete _candidates;
        }
        uint256 head = roundManager.headIndex();
        try router.buyExactIn{value: 5 ether}(head, 0, address(this), head + 1) {} catch {}

        address parent = roundManager.head();
        uint256 balance = IERC20(parent).balanceOf(address(this));
        if (balance < 4_000_000e18) return;
        successionAttempts++;

        uint256 bond = roundManager.currentBond();
        (address token, PoolKey memory key, uint256 id) = factory.registerCandidate{value: bond}("W", "W", "");
        _noteToken(token);
        {
            (CurveRange[] memory ranges,) = StandardCurve.build(
                factory.curveSpec(),
                IERC20(parent).totalSupply(),
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
        vm.warp(r.submitEnd);
        uint256 headBefore = roundManager.headIndex();
        roundManager.finalize();
        if (roundManager.headIndex() != headBefore) successions++;
        delete _candidates;
        _snapshot();
    }

    /// @dev Exercise the pull-claim paths so the invariant run proves they are reachable.
    function claimFees(uint256 seed) external {
        calls++;
        // an attributed buy through the canonical router funds the dev and creator ledgers
        if (vault.devBalance() == 0) {
            try router.buyExactIn{value: 0.5 ether}(roundManager.headIndex(), 0, address(this), 64) {} catch {}
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
        try roundManager.finalize() {
            delete _candidates;
        } catch {}
        _snapshot();
    }

    function deploySupport(uint256 seed) external {
        calls++;
        // Give the keeper path a fair shot: two spaced genesis buys fund every ETH pot AND
        // leave the genesis oracle with two observations more than OBS_MIN_SPACING apart, which
        // is what the band guard now insists on (M2).
        try router.buyExactIn{value: 0.5 ether}(0, 0, address(this), 1) {} catch {}
        vm.warp(block.timestamp + 200);
        try router.buyExactIn{value: 0.05 ether}(0, 0, address(this), 1) {} catch {}
        uint256 head = roundManager.headIndex();
        uint256 j = head == 0 ? 0 : seed % (head + 1);
        // the band guard needs a TWAP that covers the whole window, so let the clock run
        vm.warp(block.timestamp + 2_000);
        vm.recordLogs();
        // the genesis bid is always attempted: it is the one deployment that needs no keeper
        // capital, so a run that never manages an ancestor deploy still exercises the path
        deployAttempts++;
        try bidDeployer.deployGenesisBid() returns (uint256) {
            deploysSucceeded++;
        } catch {}
        if (j != 0) {
            address parent = roundManager.canonical(j - 1);
            uint256 balance = IERC20(parent).balanceOf(address(this));
            uint256 amount = balance / 1000;
            if (amount != 0) {
                IERC20(parent).approve(address(bidDeployer), type(uint256).max);
                // v3 (review 3): the purse goes to the generation's trunk link, nowhere else
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
