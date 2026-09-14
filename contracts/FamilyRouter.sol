// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FamilyFactory} from "./FamilyFactory.sol";
import {RoundManager} from "./RoundManager.sol";

/// @title FamilyRouter
/// @notice Permissionless, immutable convenience executor for canonical family routes. It is
/// NOT fee-privileged: it pays exactly the same hook fees as a direct PoolManager swap. Its only
/// privilege is attribution — the hook trusts `hookData` (the terminal token's canonical index)
/// only when the swap's `sender` is this contract, so the 1% ETH-edge fee can be credited to the
/// terminal token's creator. A copycat router passing the same `hookData` gets attribution zero.
///
/// @dev Every route runs inside ONE `unlock`: nested unlocks revert in v4, and the whole path
/// must settle atomically. Intermediate legs net to zero (the output of leg `i` is exactly the
/// input of leg `i+1`, hook fees included), so only the first and last currencies are settled,
/// read from the router's own transient deltas — which also makes partial fills safe and lets
/// unused ETH be refunded.
contract FamilyRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /// @notice Path sentinel for native ETH, which sits one hop outside canonical index 0.
    uint256 public constant ETH = type(uint256).max;

    /// @notice Attribution sentinel for a SUCCESSION CANDIDATE, which has no canonical index yet.
    /// The hook forwards `CANDIDATE_ATTRIBUTION | candidateId` unchanged and the FeeVault resolves
    /// it to `creatorOf(candidateInfo(candidateId).token)` (M4).
    uint256 public constant CANDIDATE_ATTRIBUTION = 1 << 255;

    IPoolManager public immutable poolManager;
    FamilyFactory public immutable factory;
    RoundManager public immutable roundManager;

    error NotPoolManager();
    error EmptyPath();
    error NonAdjacentPath();
    error TooManyHops();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error UnknownIndex();
    error RefundFailed();
    /// @notice `msg.value` must equal `amountIn` on an ETH-funded route, and be zero otherwise.
    error WrongValue(uint256 sent, uint256 expected);
    /// @notice A currency in the middle of the route ended the unlock owing the PoolManager.
    error IntermediateDeficit(uint256 pathIndex, uint256 amount);
    error NotTrading();
    error UnknownCandidate();

    constructor(FamilyFactory _factory) {
        factory = _factory;
        poolManager = _factory.poolManager();
        roundManager = _factory.roundManager();
    }

    // No `receive()`: the router is a pure conduit. Every wei it ever holds arrives as the
    // `msg.value` of the route currently executing and leaves again in the same call (spent into
    // the PoolManager, or refunded to the caller). Nothing can be parked here to be swept later,
    // and a plain ETH transfer to this address now reverts (M1).

    // -------------------------------------------------------------------------------------
    // canonical routes
    // -------------------------------------------------------------------------------------

    /// @notice Spend `msg.value` of ETH down the canonical chain and deliver link `targetIndex`.
    function buyExactIn(uint256 targetIndex, uint256 minOut, address to, uint256 maxHops)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.value == 0) revert WrongValue(0, 1);
        uint256[] memory path = new uint256[](targetIndex + 2);
        path[0] = ETH;
        for (uint256 i = 0; i <= targetIndex; i++) {
            path[i + 1] = i;
        }
        return _execute(path, msg.value, minOut, to, maxHops);
    }

    /// @notice Sell `amountIn` of link `targetIndex` back up the canonical chain into ETH.
    function sellExactIn(uint256 targetIndex, uint256 amountIn, uint256 minOut, address to, uint256 maxHops)
        external
        returns (uint256 amountOut)
    {
        uint256[] memory path = new uint256[](targetIndex + 2);
        for (uint256 i = 0; i <= targetIndex; i++) {
            path[i] = targetIndex - i;
        }
        path[targetIndex + 1] = ETH;
        return _execute(path, amountIn, minOut, to, maxHops);
    }

    /// @notice General family route: a list of canonical indices (with {ETH} allowed at either
    /// end), each adjacent to the next, executed exact-in in a single unlock.
    function swapPath(uint256[] calldata path, uint256 amountIn, uint256 minOut, address to, uint256 maxHops)
        external
        payable
        returns (uint256 amountOut)
    {
        // M1: an ETH-funded route must be funded by THIS call and nothing else, and a
        // token-funded route must carry no ETH at all. Without this, `amountIn` could be spent
        // out of ETH the router happened to be holding.
        if (path.length != 0 && path[0] == ETH) {
            if (msg.value != amountIn) revert WrongValue(msg.value, amountIn);
        } else if (msg.value != 0) {
            revert WrongValue(msg.value, 0);
        }
        uint256[] memory p = new uint256[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            p[i] = path[i];
        }
        return _execute(p, amountIn, minOut, to, maxHops);
    }

    // -------------------------------------------------------------------------------------
    // candidate routes (M4)
    // -------------------------------------------------------------------------------------

    /// @notice Buy a succession CANDIDATE with ETH: down the canonical chain to the current head,
    /// then one more hop into the candidate's own pool. Only while its round is Trading.
    /// @dev The ETH-edge fee is attributed to the CANDIDATE's creator, not to any canonical
    /// link's: a candidate has no canonical index, so the attribution carries the
    /// {CANDIDATE_ATTRIBUTION} sentinel and the FeeVault resolves it through `creatorOf`.
    function buyCandidate(uint256 candidateId, uint256 minOut, address to, uint256 maxHops)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.value == 0) revert WrongValue(0, 1);
        (PoolKey memory candidateKey, uint256 parentIndex,) = _candidateRoute(candidateId);

        uint256[] memory path = new uint256[](parentIndex + 2);
        path[0] = ETH;
        for (uint256 i = 0; i <= parentIndex; i++) {
            path[i + 1] = i;
        }
        return _executeWithTail(path, candidateKey, true, msg.value, minOut, to, candidateId, maxHops);
    }

    /// @notice Buy a succession CANDIDATE with the HEAD token the caller already holds: one hop,
    /// head -> candidate, attributed exactly like {buyCandidate}.
    /// @dev This is the entrypoint a round participant needs. Absorption during a round is paid
    /// for out of head tokens, and without this the only attributed candidate route was ETH-in,
    /// which re-buys the whole canonical chain the caller has already bought; the alternative
    /// (a stock third-party swap router) is UNATTRIBUTED, so the candidate's creator, the head's
    /// creator and the ancestor sleeve all get nothing. `parentAmount` of the head token is
    /// pulled from `msg.sender` with `transferFrom`, so it must be approved to this router.
    /// There is no canonical chain to walk and therefore no `maxHops`: the route is one leg.
    function buyCandidateWithParent(uint256 candidateId, uint256 parentAmount, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        (PoolKey memory candidateKey, uint256 parentIndex,) = _candidateRoute(candidateId);
        uint256[] memory path = new uint256[](1);
        path[0] = parentIndex;
        return _run(path, candidateKey, true, parentAmount, minOut, to, CANDIDATE_ATTRIBUTION | candidateId);
    }

    /// @notice Sell `amountIn` of a candidate back into ETH: out of the candidate's pool into the
    /// head, then up the canonical chain. Only while its round is Trading.
    function sellCandidate(uint256 candidateId, uint256 amountIn, uint256 minOut, address to, uint256 maxHops)
        external
        returns (uint256 amountOut)
    {
        (PoolKey memory candidateKey, uint256 parentIndex,) = _candidateRoute(candidateId);

        uint256[] memory path = new uint256[](parentIndex + 2);
        for (uint256 i = 0; i <= parentIndex; i++) {
            path[i] = parentIndex - i;
        }
        path[parentIndex + 1] = ETH;
        return _executeWithTail(path, candidateKey, false, amountIn, minOut, to, candidateId, maxHops);
    }

    /// @dev Resolve a candidate's pool key and the canonical index its pool is quoted in.
    ///
    /// AUDIT 8: a LOSING candidate's holders lost their supported exit the moment the round
    /// ended. The route walked the CURRENT head, which after the round is some other token, so
    /// every candidate route reverted and the only way out was a third-party router - i.e. an
    /// unattributed swap that pays the candidate's creator nothing. The route now walks the
    /// index the ROUND recorded as its parent, which is immutable once written, so a candidate
    /// pool stays tradeable through this router forever. Registration (the pool exists but the
    /// hook's own gate has not opened) is still refused.
    /// @return key The candidate's pool key.
    /// @return parentIndex The canonical index the candidate's pool is quoted in.
    /// @return trading True while the candidate's round is still Trading.
    function _candidateRoute(uint256 candidateId)
        internal
        view
        returns (PoolKey memory key, uint256 parentIndex, bool trading)
    {
        if (candidateId >= roundManager.candidateCount()) revert UnknownCandidate();
        RoundManager.Candidate memory c = roundManager.candidateInfo(candidateId);
        RoundManager.Phase p = roundManager.phase(c.roundId);
        if (p == RoundManager.Phase.Registration || p == RoundManager.Phase.Idle) revert NotTrading();
        trading = p == RoundManager.Phase.Trading;
        parentIndex = roundManager.roundInfo(c.roundId).parentIndex;
        key = c.key;
        if (address(key.hooks) == address(0)) revert UnknownIndex();
    }

    // -------------------------------------------------------------------------------------
    // execution
    // -------------------------------------------------------------------------------------

    function _execute(uint256[] memory path, uint256 amountIn, uint256 minOut, address to, uint256 maxHops)
        internal
        returns (uint256 amountOut)
    {
        if (path.length < 2) revert EmptyPath();
        if (path.length - 1 > maxHops) revert TooManyHops();

        PoolKey memory noTail;
        return _run(path, noTail, false, amountIn, minOut, to, type(uint256).max);
    }

    /// @dev A canonical route with ONE extra hop into a candidate pool at the far end. The hop
    /// budget is checked exactly as {_execute} checks it, with the candidate leg COUNTED: the
    /// canonical part contributes `path.length - 1` hops and the tail one more, so the whole
    /// route is `path.length` hops against the caller's `maxHops`.
    function _executeWithTail(
        uint256[] memory path,
        PoolKey memory tail,
        bool tailIsLast,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 candidateId,
        uint256 maxHops
    ) internal returns (uint256 amountOut) {
        if (path.length < 2) revert EmptyPath();
        if (path.length > maxHops) revert TooManyHops();
        return _run(path, tail, tailIsLast, amountIn, minOut, to, CANDIDATE_ATTRIBUTION | candidateId);
    }

    function _run(
        uint256[] memory path,
        PoolKey memory tail,
        bool tailIsLast,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint256 attribution
    ) internal returns (uint256 amountOut) {
        uint256 spent;
        (amountOut, spent) = abi.decode(
            poolManager.unlock(abi.encode(path, tail, tailIsLast, amountIn, to, msg.sender, attribution)),
            (uint256, uint256)
        );

        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        // refund whatever the route could not absorb (a partially filled first leg)
        if (path[0] == ETH && msg.value > spent) {
            (bool ok,) = msg.sender.call{value: msg.value - spent}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Route memory r;
        (r.path, r.tail, r.tailIsLast, r.amount, r.to, r.payer, r.attribution) =
            abi.decode(data, (uint256[], PoolKey, bool, uint256, address, address, uint256));

        // the terminal token is the family end of the path; the hook trusts this only because
        // the swap's `sender` is this router
        if (r.attribution == type(uint256).max) {
            r.attribution = r.path[0] == ETH ? r.path[r.path.length - 1] : r.path[0];
        }
        bytes memory hookData = abi.encode(r.attribution);

        uint256 n = r.path.length;
        r.cur = new Currency[](n);
        for (uint256 i = 0; i < n; i++) {
            r.cur[i] = _currency(r.path[i]);
        }

        Currency inputCurrency;
        Currency outputCurrency;
        if (r.tailIsLast) {
            // ETH -> ... -> head -> candidate
            inputCurrency = r.cur[0];
            outputCurrency = _tailOther(r.tail, r.cur[n - 1]);
        } else if (address(r.tail.hooks) != address(0)) {
            // candidate -> head -> ... -> ETH
            inputCurrency = _tailOther(r.tail, r.cur[0]);
            outputCurrency = r.cur[n - 1];
            r.amount = _swap(r.tail, inputCurrency, r.amount, hookData);
        } else {
            inputCurrency = r.cur[0];
            outputCurrency = r.cur[n - 1];
        }

        for (uint256 i = 0; i + 1 < n; i++) {
            r.amount = _leg(r.path[i], r.path[i + 1], r.cur[i], r.amount, hookData);
        }
        if (r.tailIsLast) {
            r.amount = _swap(r.tail, r.cur[n - 1], r.amount, hookData);
        }

        // L12: BOTH terminal deltas are read before either is acted on. Settling the input
        // first zeroes the router's delta for that currency, so a round trip (ETH -> ... -> ETH)
        // would otherwise read its own output as zero.
        int256 inDelta = poolManager.currencyDelta(address(this), inputCurrency);
        int256 outDelta = Currency.unwrap(inputCurrency) == Currency.unwrap(outputCurrency)
            ? inDelta
            : poolManager.currencyDelta(address(this), outputCurrency);

        uint256 spent = inDelta < 0 ? uint256(-inDelta) : 0;
        if (spent != 0) _settle(inputCurrency, spent, r.payer);

        uint256 taken = outDelta > 0 ? uint256(outDelta) : 0;
        if (taken != 0) poolManager.take(outputCurrency, r.to, taken);

        // On a ROUND TRIP the input and the output are the same currency, so the PoolManager
        // holds a single NET delta for it: the route is settled net with the payer and the
        // amount actually "taken" is zero even though the last leg really did produce something.
        // Report what the route produced (the last leg's output), which is what `minOut` is
        // about; for every other route the two are identical.
        uint256 amountOut = Currency.unwrap(inputCurrency) == Currency.unwrap(outputCurrency) ? r.amount : taken;

        // M5: intermediate legs are supposed to net to zero, but a partial fill anywhere in the
        // middle leaves a residue. Sweep every positive residue to `to`; a NEGATIVE one cannot be
        // paid from anything the route owns, so it is a hard, named failure rather than a revert
        // from deep inside the PoolManager's settlement check.
        _sweepResiduals(r, inputCurrency, outputCurrency);

        return abi.encode(amountOut, spent);
    }

    /// @dev Per-route scratch, kept in one struct because the decode has seven fields.
    struct Route {
        uint256[] path;
        PoolKey tail;
        bool tailIsLast;
        uint256 amount;
        address to;
        address payer;
        uint256 attribution;
        /// @dev {_currency} for each entry of `path`, resolved ONCE. Each resolution is an
        /// external `roundManager.canonical` call that may walk the continuation chain, and the
        /// same index is needed by the leg loop, the terminal-delta read and the residual sweep;
        /// the canonical chain cannot change inside an unlock, so one lookup per index is both
        /// correct and several external calls cheaper per route.
        Currency[] cur;
    }

    function _sweepResiduals(Route memory r, Currency inputCurrency, Currency outputCurrency) internal {
        for (uint256 i = 0; i < r.cur.length; i++) {
            Currency c = r.cur[i];
            if (Currency.unwrap(c) == Currency.unwrap(inputCurrency)) continue;
            if (Currency.unwrap(c) == Currency.unwrap(outputCurrency)) continue;
            int256 d = poolManager.currencyDelta(address(this), c);
            if (d == 0) continue;
            if (d < 0) revert IntermediateDeficit(i, uint256(-d));
            poolManager.take(c, r.to, uint256(d));
        }
        if (address(r.tail.hooks) == address(0)) return;
        Currency t = _tailOther(r.tail, r.tailIsLast ? r.cur[r.cur.length - 1] : r.cur[0]);
        if (Currency.unwrap(t) == Currency.unwrap(inputCurrency)) return;
        if (Currency.unwrap(t) == Currency.unwrap(outputCurrency)) return;
        int256 dt = poolManager.currencyDelta(address(this), t);
        if (dt < 0) revert IntermediateDeficit(r.path.length, uint256(-dt));
        if (dt > 0) poolManager.take(t, r.to, uint256(dt));
    }

    /// @dev The side of `key` that is NOT `known` (a candidate pool's candidate token).
    function _tailOther(PoolKey memory key, Currency known) internal pure returns (Currency) {
        return Currency.unwrap(key.currency0) == Currency.unwrap(known) ? key.currency1 : key.currency0;
    }

    /// @dev One hop between two adjacent path entries; returns the amount out.
    function _leg(uint256 from, uint256 to, Currency input, uint256 amount, bytes memory hookData)
        internal
        returns (uint256)
    {
        PoolKey memory key;
        if (from == ETH || to == ETH) {
            uint256 other = from == ETH ? to : from;
            if (other != 0) revert NonAdjacentPath();
            key = roundManager.poolKeyOf(0);
        } else if (to == from + 1) {
            key = roundManager.poolKeyOf(to);
        } else if (from == to + 1) {
            key = roundManager.poolKeyOf(from);
        } else {
            revert NonAdjacentPath();
        }
        if (address(key.hooks) == address(0)) revert UnknownIndex();
        return _swap(key, input, amount, hookData);
    }

    /// @dev One exact-in swap of `amount` of `input` against `key`; returns the amount out.
    function _swap(PoolKey memory key, Currency input, uint256 amount, bytes memory hookData)
        internal
        returns (uint256)
    {
        bool zeroForOne = Currency.unwrap(input) == Currency.unwrap(key.currency0);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        return out > 0 ? uint256(uint128(out)) : 0;
    }

    function _currency(uint256 index) internal view returns (Currency) {
        if (index == ETH) return Currency.wrap(address(0));
        address token = roundManager.canonical(index);
        if (token == address(0)) revert UnknownIndex();
        return Currency.wrap(token);
    }

    function _settle(Currency currency, uint256 amount, address payer) internal {
        if (currency.isAddressZero()) {
            // AUDIT 7B: `sync(native)` FIRST. The PoolManager keeps ONE transient "currency being
            // synced" slot; if anything earlier in the same unlock synced an ERC-20 (a successor's
            // router, a hook, another leg of this route), a bare native `settle` would be credited
            // against that token's reserves instead and the settlement would be wrong or revert.
            // Syncing native is a no-op for the reserve snapshot and costs one transient write.
            poolManager.sync(currency);
            poolManager.settle{value: amount}();
            return;
        }
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
    }
}
