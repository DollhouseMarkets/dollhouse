// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILocker} from "./interfaces/ILocker.sol";
import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";
import {CurveRange} from "./types/CurveRange.sol";

/// @title Locker
/// @notice Sole owner of every family position, forever. It is the only address the hook lets
/// add liquidity, and it has no function that removes liquidity, transfers a position, or moves
/// tokens out. Whatever it places is locked for the life of the chain.
///
/// @dev The factory mints the full token supply straight to this contract and then calls
/// {placeStandardCurve}; any rounding remainder that does not fit into the curve's positions is
/// burned, so no family supply is ever held outside locked liquidity. The BidDeployer's keeper path
/// calls {depositBid} to add protocol-owned parent liquidity below spot; that liquidity is
/// locked on exactly the same terms as the launch curve.
contract Locker is ILocker, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @dev Action tags for {unlockCallback}.
    uint8 internal constant ACTION_CURVE = 0;
    uint8 internal constant ACTION_BID = 1;

    IPoolManager public immutable poolManager;
    address public immutable factory;
    /// @notice The keeper contract - the ONLY address that may ever deposit a bid here. It is an
    /// address PREDICTION at construction time (the BidDeployer reads the factory and the vault,
    /// which do not exist yet), verified by `FamilyFactory.wire` before anything can launch.
    address public immutable bidDeployer;

    constructor(IPoolManager _poolManager, address _factory, address _bidDeployer) {
        poolManager = _poolManager;
        factory = _factory;
        bidDeployer = _bidDeployer;
    }

    receive() external payable {}

    /// @inheritdoc ILocker
    /// @param tokenIsCurrency0 Orientation of the pool: true when the freshly launched token
    /// sorts below its parent (only possible for candidate pools; genesis is always paired
    /// against native ETH, which sorts first).
    function placeStandardCurve(PoolKey calldata key, CurveRange[] calldata ranges, bool tokenIsCurrency0) external {
        if (msg.sender != factory) revert NotFactory();
        if (ranges.length == 0) revert NoRanges();

        uint256 placed =
            abi.decode(poolManager.unlock(abi.encode(ACTION_CURVE, key, ranges, tokenIsCurrency0)), (uint256));

        // burn the rounding remainder: all supply must live inside the locked positions
        IERC20 token = IERC20(Currency.unwrap(tokenIsCurrency0 ? key.currency0 : key.currency1));
        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) IBurnableERC20(address(token)).burn(dust);

        emit CurvePlaced(PoolId.unwrap(key.toId()), ranges.length, placed, dust);
    }

    /// @inheritdoc ILocker
    /// @notice Deploy protocol-owned parent liquidity as a permanently locked bid on
    /// `[tickLower, tickUpper]`, which must lie strictly on one side of spot — the side that
    /// takes the parent currency only. The BidDeployer must have delivered `parentAmount` of the
    /// parent currency first (ERC-20 transfer, or `msg.value` for native ETH under genesis).
    /// @dev The orientation is derived from the pool's own tick rather than trusted from the
    /// caller: a range entirely at or above spot is currency0-only, entirely at or below spot is
    /// currency1-only, and anything straddling spot is refused.
    function depositBid(PoolKey calldata key, uint256 parentAmount, int24 tickLower, int24 tickUpper)
        external
        payable
        returns (uint128 liquidity)
    {
        if (msg.sender != bidDeployer) revert NotBidDeployer();
        if (parentAmount == 0) revert NothingToDeposit();
        if (tickUpper <= tickLower) revert BidStraddlesSpot();

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        bool parentIsCurrency0;
        if (tickLower > currentTick) {
            parentIsCurrency0 = true;
        } else if (tickUpper <= currentTick) {
            parentIsCurrency0 = false;
        } else {
            revert BidStraddlesSpot();
        }

        Currency parent = parentIsCurrency0 ? key.currency0 : key.currency1;
        if (parent.isAddressZero()) {
            if (msg.value != parentAmount) revert WrongValue();
        } else if (msg.value != 0) {
            revert WrongValue();
        }

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        // L2: `getLiquidityForAmount*` rounds the LIQUIDITY down, but `modifyLiquidity` charges
        // the amount for that liquidity rounded UP, so the two can disagree by a wei and the
        // settlement would then be short of what the vault actually delivered. Price the
        // position the way the PoolManager will, and shave one wei off the input if it does not
        // fit; the leftover wei stays in this contract, which can never move it out.
        liquidity = _liquidityFor(sqrtLower, sqrtUpper, parentAmount, parentIsCurrency0);
        if (liquidity != 0 && _owedFor(sqrtLower, sqrtUpper, liquidity, parentIsCurrency0) > parentAmount) {
            liquidity = _liquidityFor(sqrtLower, sqrtUpper, parentAmount - 1, parentIsCurrency0);
            if (liquidity != 0 && _owedFor(sqrtLower, sqrtUpper, liquidity, parentIsCurrency0) > parentAmount) {
                revert NothingToDeposit();
            }
        }
        if (liquidity == 0) revert NothingToDeposit();

        poolManager.unlock(abi.encode(ACTION_BID, key, tickLower, tickUpper, liquidity, parentIsCurrency0));

        emit BidDeposited(PoolId.unwrap(key.toId()), parentAmount, tickLower, tickUpper, liquidity);
    }

    /// @dev Liquidity for `amount` of the single-sided currency, rounded DOWN.
    function _liquidityFor(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount, bool isCurrency0)
        internal
        pure
        returns (uint128)
    {
        if (amount == 0) return 0;
        return isCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
    }

    /// @dev What the PoolManager will actually charge for `liquidity`, rounded UP exactly as
    /// `modifyLiquidity` does.
    function _owedFor(uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity, bool isCurrency0)
        internal
        pure
        returns (uint256)
    {
        return isCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint8 action = abi.decode(data[:32], (uint8));
        if (action == ACTION_CURVE) return _placeCurve(data);
        return _placeBid(data);
    }

    function _placeCurve(bytes calldata data) internal returns (bytes memory) {
        (, PoolKey memory key, CurveRange[] memory ranges, bool tokenIsCurrency0) =
            abi.decode(data, (uint8, PoolKey, CurveRange[], bool));

        int256 owed0;
        int256 owed1;
        for (uint256 i = 0; i < ranges.length; i++) {
            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: ranges[i].tickLower,
                    tickUpper: ranges[i].tickUpper,
                    liquidityDelta: int256(uint256(ranges[i].liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            owed0 -= int256(delta.amount0());
            owed1 -= int256(delta.amount1());
        }

        // the standard curve is single-sided family-token liquidity: the parent side must never
        // be owed, because this contract holds no parent currency and never will
        uint256 placed;
        if (tokenIsCurrency0) {
            if (owed1 > 0) revert ParentOwed();
            if (owed0 > 0) {
                placed = uint256(owed0);
                _settle(key.currency0, placed);
            }
        } else {
            if (owed0 > 0) revert ParentOwed();
            if (owed1 > 0) {
                placed = uint256(owed1);
                _settle(key.currency1, placed);
            }
        }
        return abi.encode(placed);
    }

    function _placeBid(bytes calldata data) internal returns (bytes memory) {
        (, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity, bool parentIsCurrency0) =
            abi.decode(data, (uint8, PoolKey, int24, int24, uint128, bool));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        int256 owed0 = -int256(delta.amount0());
        int256 owed1 = -int256(delta.amount1());

        // a bid is single-sided parent liquidity: the child-token side must never be owed
        if (parentIsCurrency0) {
            if (owed1 > 0) revert TokenOwed();
            if (owed0 > 0) _settle(key.currency0, uint256(owed0));
        } else {
            if (owed0 > 0) revert TokenOwed();
            if (owed1 > 0) _settle(key.currency1, uint256(owed1));
        }
        return "";
    }

    function _settle(Currency currency, uint256 amount) internal {
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
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }
}
