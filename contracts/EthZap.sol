// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FamilyRouter} from "./FamilyRouter.sol";
import {RoundManager} from "./RoundManager.sol";

/// @title EthZap
/// @notice Stateless native-ETH entrance to the family chain. A buy swaps ETH into the edge
/// currency ($DOLL, canonical index 0) on the external venue pool $DOLL graduated on, then hands
/// that $DOLL to the unchanged {FamilyRouter} with `to = user`. A sell runs the router first,
/// into $DOLL held here for the length of the call, then swaps that $DOLL into ETH on the venue.
///
/// ATTRIBUTION IS PRESERVED because every family-pool swap is still made by the router: the
/// PoolManager reports `sender == FamilyRouter` to the family hook, which is the only sender whose
/// `hookData` it trusts. This contract never swaps a family pool itself; it only ever swaps the
/// venue pool fixed at construction.
///
/// No owner, no admin, no sweep. Every balance this contract acts on is measured against a
/// snapshot taken at the start of the call, so a call moves only what that call itself brought in
/// or produced, and ends with no allowance to the router. Tokens or ETH sent to this contract
/// outside a call (a direct transfer, a forced ETH send) are not counted by any call and are not
/// recoverable.
///
/// LEFTOVERS follow one rule, in the same transaction. Input that was never converted goes back
/// to `msg.sender`: ETH the venue did not absorb on a buy, link coin the router did not pull on a
/// sell. Everything produced from the caller's value goes to `to`, as {FamilyRouter} sweeps route
/// residue to `to`: $DOLL the route did not absorb on a buy; a middle link's residue and $DOLL the
/// venue did not absorb on a sell.
///
/// @dev Two v4 `unlock`s can never nest (`PoolManager.unlock` reverts `AlreadyUnlocked` while one
/// is live), and the router opens its own. So the venue leg runs in THIS contract's unlock, and
/// the router is called only after that unlock has closed (buy) or before it opens (sell).
contract EthZap is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    FamilyRouter public immutable router;
    IPoolManager public immutable poolManager;
    RoundManager public immutable roundManager;
    /// @notice The edge currency, canonical index 0: `currency1` of the venue pool.
    IERC20 public immutable doll;

    // The venue PoolKey, one immutable per field (a struct cannot be immutable).
    address internal immutable venueHooks;
    uint24 internal immutable venueFee;
    int24 internal immutable venueTickSpacing;

    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @dev Transient reentrancy flag; cleared at the end of every guarded call and, failing
    /// that, at the end of the transaction.
    bytes32 internal constant LOCK_SLOT = bytes32(uint256(keccak256("dollhouse.EthZap.lock")) - 1);

    error NotPoolManager();
    error Reentrancy();
    error Expired();
    error NothingIn();
    error InvalidRecipient();
    error UnknownIndex();
    error UnknownCandidate();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error EthTransferFailed();
    /// @notice The venue leg produced nothing to hand on.
    error NothingOut();
    /// @notice The venue swap left this contract a delta of the wrong sign.
    error UnexpectedDelta();
    error VenueNotNative();
    error VenueNotEdgeCurrency();
    error VenueNotInitialized();
    /// @notice The venue pool has no in-range liquidity on the router's PoolManager.
    error VenueNoLiquidity();

    /// @notice ETH in, family token out. `target` is the canonical index, or the candidate id
    /// when `candidate` is true. `ethRefunded` is the ETH the venue leg could not absorb, sent
    /// back to `user`. `dollMid` is the $DOLL the venue leg produced and the router was offered;
    /// `dollRefunded` is the part of it the route did not absorb, sent to `to`. The router spent
    /// `dollMid - dollRefunded`.
    event EthBuy(
        address indexed user,
        address indexed to,
        uint256 indexed target,
        bool candidate,
        uint256 ethIn,
        uint256 ethRefunded,
        uint256 dollMid,
        uint256 dollRefunded,
        uint256 out
    );

    /// @notice Family token in, ETH out. `coinRefunded` is the link coin the router did not
    /// pull, sent back to `user`. `dollMid` is the $DOLL the route produced and the venue leg was
    /// offered; the venue spent `dollSpent` of it and `dollRefunded` (the rest) was sent to `to`.
    /// Any middle-link residue is reported by {IntermediateReturned}.
    event EthSell(
        address indexed user,
        address indexed to,
        uint256 indexed target,
        bool candidate,
        uint256 amountIn,
        uint256 coinRefunded,
        uint256 dollMid,
        uint256 dollSpent,
        uint256 dollRefunded,
        uint256 ethOut
    );

    /// @notice A partially filled middle leg of a sell left `amount` of canonical link `token`
    /// here; it was sent to `to`.
    event IntermediateReturned(address indexed token, address indexed to, uint256 amount);

    /// @dev The constructor checks that matter for money are made here, once: the venue must be
    /// native ETH against the stack's own edge currency, and it must already exist, with in-range
    /// liquidity, on the SAME PoolManager the router settles against (both reads go to that
    /// manager).
    constructor(FamilyRouter _router, PoolKey memory _venueKey) {
        router = _router;
        poolManager = _router.poolManager();
        roundManager = _router.roundManager();
        if (Currency.unwrap(_venueKey.currency0) != address(0)) revert VenueNotNative();
        address edge = roundManager.canonical(0);
        if (edge == address(0) || Currency.unwrap(_venueKey.currency1) != edge) revert VenueNotEdgeCurrency();
        PoolId id = _venueKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert VenueNotInitialized();
        if (poolManager.getLiquidity(id) == 0) revert VenueNoLiquidity();

        doll = IERC20(edge);
        venueHooks = address(_venueKey.hooks);
        venueFee = _venueKey.fee;
        venueTickSpacing = _venueKey.tickSpacing;
    }

    modifier nonReentrant() {
        if (_entered()) revert Reentrancy();
        bytes32 slot = LOCK_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @dev ETH arrives only as the venue leg's output, taken from the PoolManager. Any other
    /// plain transfer is refused. A forced send (selfdestruct) cannot be refused; no call counts
    /// it, and it is not recoverable.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // -------------------------------------------------------------------------------------
    // views
    // -------------------------------------------------------------------------------------

    /// @notice The venue pool this contract swaps ETH and $DOLL on.
    function venueKey() public view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: NATIVE,
            currency1: Currency.wrap(address(doll)),
            fee: venueFee,
            tickSpacing: venueTickSpacing,
            hooks: IHooks(venueHooks)
        });
    }

    function venuePoolId() external view returns (PoolId) {
        return venueKey().toId();
    }

    // -------------------------------------------------------------------------------------
    // buys
    // -------------------------------------------------------------------------------------

    /// @notice Spend `msg.value` ETH on $DOLL at the venue, then buy canonical link `target` with
    /// all of it through {FamilyRouter}, delivered to `to`. `minOut` bounds the family token
    /// received. ETH the venue could not absorb goes back to the caller; $DOLL the route could
    /// not absorb goes to `to`.
    function buyWithEth(uint256 target, uint256 minOut, address to, uint256 maxHops, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        nonReentrant
        returns (uint256 out)
    {
        // refuse an unknown link before the venue swap, not after it; index 0 is $DOLL itself
        if (target == 0 || roundManager.canonical(target) == address(0)) revert UnknownIndex();
        return _buy(target, false, minOut, to, maxHops);
    }

    /// @notice As {buyWithEth}, into succession candidate `candidateId`.
    function buyCandidateWithEth(uint256 candidateId, uint256 minOut, address to, uint256 maxHops, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        nonReentrant
        returns (uint256 out)
    {
        if (candidateId >= roundManager.candidateCount()) revert UnknownCandidate();
        return _buy(candidateId, true, minOut, to, maxHops);
    }

    function _buy(uint256 target, bool candidate, uint256 minOut, address to, uint256 maxHops)
        internal
        returns (uint256 out)
    {
        if (msg.value == 0) revert NothingIn();
        _checkRecipient(to);

        uint256 dollBefore = doll.balanceOf(address(this));
        (uint256 ethSpent, uint256 dollMid) =
            abi.decode(poolManager.unlock(abi.encode(true, msg.value)), (uint256, uint256));
        if (dollMid == 0) revert NothingOut();

        // the venue unlock is closed; the router can open its own
        doll.forceApprove(address(router), dollMid);
        out = candidate
            ? router.buyCandidate(target, dollMid, minOut, to, maxHops)
            : router.buyExactIn(target, dollMid, minOut, to, maxHops);
        doll.forceApprove(address(router), 0);

        // a partially filled first family leg pulls less than offered; that $DOLL was produced
        // from the caller's ETH, so it goes where the route's output goes
        uint256 dollRefunded = doll.balanceOf(address(this)) - dollBefore;
        if (dollRefunded != 0) doll.safeTransfer(to, dollRefunded);

        // ETH the venue never converted goes back to the payer
        uint256 ethRefunded = msg.value - ethSpent;
        emit EthBuy(msg.sender, to, target, candidate, msg.value, ethRefunded, dollMid, dollRefunded, out);

        // external ETH send last
        if (ethRefunded != 0) _sendEth(msg.sender, ethRefunded);
    }

    // -------------------------------------------------------------------------------------
    // sells
    // -------------------------------------------------------------------------------------

    /// @notice Sell `amountIn` of canonical link `target` into $DOLL through {FamilyRouter}, then
    /// that $DOLL into ETH at the venue, delivered to `to`. `minEthOut` bounds the ETH received.
    /// The link coin must be approved to this contract. Link coin the router did not pull goes
    /// back to the caller; a middle link's residue and $DOLL the venue could not absorb go to
    /// `to`.
    function sellForEth(
        uint256 target,
        uint256 amountIn,
        uint256 minEthOut,
        address to,
        uint256 maxHops,
        uint256 deadline
    ) external checkDeadline(deadline) nonReentrant returns (uint256 ethOut) {
        // index 0 is $DOLL itself: there is no family route to sell it through
        if (target == 0) revert UnknownIndex();
        address coin = roundManager.canonical(target);
        if (coin == address(0)) revert UnknownIndex();
        // intermediate canonical links on the route: target - 1 down to 1
        return _sell(target, false, coin, target - 1, amountIn, minEthOut, to, maxHops);
    }

    /// @notice As {sellForEth}, out of succession candidate `candidateId`.
    function sellCandidateForEth(
        uint256 candidateId,
        uint256 amountIn,
        uint256 minEthOut,
        address to,
        uint256 maxHops,
        uint256 deadline
    ) external checkDeadline(deadline) nonReentrant returns (uint256 ethOut) {
        if (candidateId >= roundManager.candidateCount()) revert UnknownCandidate();
        RoundManager.Candidate memory c = roundManager.candidateInfo(candidateId);
        // intermediate canonical links on the route: the round's parent down to 1
        uint256 parentIndex = roundManager.roundInfo(c.roundId).parentIndex;
        return _sell(candidateId, true, c.token, parentIndex, amountIn, minEthOut, to, maxHops);
    }

    /// @dev Per-sell scratch, kept in one struct to keep the stack shallow.
    struct Sell {
        IERC20 linkCoin;
        uint256 coinBefore;
        uint256 dollBefore;
        uint256 coinRefunded;
        uint256 dollMid;
        uint256 dollSpent;
        uint256 dollRefunded;
    }

    function _sell(
        uint256 target,
        bool candidate,
        address coin,
        uint256 lastIntermediate,
        uint256 amountIn,
        uint256 minEthOut,
        address to,
        uint256 maxHops
    ) internal returns (uint256 ethOut) {
        if (amountIn == 0) revert NothingIn();
        _checkRecipient(to);

        Sell memory s;
        s.linkCoin = IERC20(coin);
        s.coinBefore = s.linkCoin.balanceOf(address(this));
        s.dollBefore = doll.balanceOf(address(this));
        (IERC20[] memory mids, uint256[] memory midsBefore) = _snapshotIntermediates(lastIntermediate);
        s.linkCoin.safeTransferFrom(msg.sender, address(this), amountIn);

        s.linkCoin.forceApprove(address(router), amountIn);
        if (candidate) router.sellCandidate(target, amountIn, 0, address(this), maxHops);
        else router.sellExactIn(target, amountIn, 0, address(this), maxHops);
        s.linkCoin.forceApprove(address(router), 0);

        // what the route delivered here, measured rather than trusted
        s.dollMid = doll.balanceOf(address(this)) - s.dollBefore;
        if (s.dollMid == 0) revert NothingOut();

        // a partially filled first family leg pulls less than approved: never converted, so it
        // goes back to the payer
        s.coinRefunded = s.linkCoin.balanceOf(address(this)) - s.coinBefore;
        if (s.coinRefunded != 0) s.linkCoin.safeTransfer(msg.sender, s.coinRefunded);
        // a partially filled MIDDLE leg makes the router sweep that link's residue to its `to`,
        // which on this route is this contract; it was produced from the caller's coin, so it goes
        // on to the caller's `to`
        _returnIntermediates(mids, midsBefore, to);

        (s.dollSpent, ethOut) = abi.decode(poolManager.unlock(abi.encode(false, s.dollMid)), (uint256, uint256));
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);

        // a partially filled venue leg spends less $DOLL than the route produced
        s.dollRefunded = s.dollMid - s.dollSpent;
        if (s.dollRefunded != 0) doll.safeTransfer(to, s.dollRefunded);

        emit EthSell(
            msg.sender, to, target, candidate, amountIn, s.coinRefunded, s.dollMid, s.dollSpent, s.dollRefunded, ethOut
        );

        // external ETH send last
        if (ethOut != 0) _sendEth(to, ethOut);
    }

    /// @dev Canonical links 1..`lastIntermediate` and this contract's balance of each before the
    /// route runs, so only what the route adds is ever moved.
    function _snapshotIntermediates(uint256 lastIntermediate)
        internal
        view
        returns (IERC20[] memory mids, uint256[] memory before)
    {
        mids = new IERC20[](lastIntermediate);
        before = new uint256[](lastIntermediate);
        for (uint256 i = 0; i < lastIntermediate; i++) {
            mids[i] = IERC20(roundManager.canonical(i + 1));
            before[i] = mids[i].balanceOf(address(this));
        }
    }

    /// @dev Send `to` whatever the route added to each intermediate link's balance. Only a
    /// partial fill in the middle of a route leaves any.
    function _returnIntermediates(IERC20[] memory mids, uint256[] memory before, address to) internal {
        for (uint256 i = 0; i < mids.length; i++) {
            uint256 residue = mids[i].balanceOf(address(this)) - before[i];
            if (residue == 0) continue;
            mids[i].safeTransfer(to, residue);
            emit IntermediateReturned(address(mids[i]), to, residue);
        }
    }

    // -------------------------------------------------------------------------------------
    // venue leg
    // -------------------------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Reached only from this contract's own `unlock`, i.e. from inside a guarded entry.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_entered()) revert NotPoolManager();
        (bool ethIn, uint256 amount) = abi.decode(data, (bool, uint256));

        Currency dollC = Currency.wrap(address(doll));
        poolManager.swap(
            venueKey(),
            SwapParams({
                zeroForOne: ethIn,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: ethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // read BOTH deltas before acting on either; the venue hook's cut is already in them
        int256 ethDelta = poolManager.currencyDelta(address(this), NATIVE);
        int256 dollDelta = poolManager.currencyDelta(address(this), dollC);

        if (ethIn) {
            if (ethDelta > 0 || dollDelta < 0) revert UnexpectedDelta();
            uint256 ethSpent = uint256(-ethDelta);
            uint256 dollOut = uint256(dollDelta);
            if (ethSpent != 0) {
                // sync(native) first so no earlier ERC-20 sync is debited against native
                poolManager.sync(NATIVE);
                poolManager.settle{value: ethSpent}();
            }
            if (dollOut != 0) poolManager.take(dollC, address(this), dollOut);
            return abi.encode(ethSpent, dollOut);
        } else {
            if (dollDelta > 0 || ethDelta < 0) revert UnexpectedDelta();
            uint256 dollSpent = uint256(-dollDelta);
            uint256 ethOut = uint256(ethDelta);
            if (dollSpent != 0) {
                poolManager.sync(dollC);
                IERC20(address(doll)).safeTransfer(address(poolManager), dollSpent);
                poolManager.settle();
            }
            if (ethOut != 0) poolManager.take(NATIVE, address(this), ethOut);
            return abi.encode(dollSpent, ethOut);
        }
    }

    // -------------------------------------------------------------------------------------
    // internals
    // -------------------------------------------------------------------------------------

    function _entered() internal view returns (bool entered) {
        bytes32 slot = LOCK_SLOT;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
    }

    /// @dev A recipient of this contract itself would strand the output here.
    function _checkRecipient(address to) internal view {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
