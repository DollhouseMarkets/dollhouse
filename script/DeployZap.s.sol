// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {EthZap} from "../contracts/EthZap.sol";

/// @title DeployZap
/// @notice Deploys the native-ETH {EthZap} against an existing {FamilyRouter} and the graduated
/// ETH/$DOLL venue pool. Separate from `Deploy.s.sol`: the zap is periphery, keeps no balance
/// between calls, and can be redeployed at any time without touching the stack.
///
/// @dev Env:
///   ROUTER            the deployed FamilyRouter
///   DOLL              the edge currency, canonical index 0 (the venue's currency1)
///   POOL_FEE          the venue's LP fee (default 0)
///   TICK_SPACING      the venue's tick spacing (default 200)
///   HOOKS             the venue's hook (must have code)
///   ENTRANCE_POOL_ID  the venue pool id the site prices $DOLL in ETH with. Optional when the
///                     deployment record `deployments/<chainid>.json` exists: its `entrancePoolId`
///                     is used, and when both are given they must agree.
/// The venue's currency0 is always native ETH. The key built from the env must hash to that pool
/// id, so the zap can only ever swap the pool the site shows a price for; the pool must hold
/// in-range liquidity; and ROUTER must equal the record's `router` when a record exists. The
/// constructor separately refuses a key that is not native against canonical index 0, or whose
/// pool is not initialised or has no liquidity on the router's PoolManager.
///
/// When the record exists, `ethZap` and `venuePoolId` are added to it, the rest of it unchanged,
/// so `script/check-artefact-keys.mjs` can confirm `venuePoolId == entrancePoolId`. Both are also
/// printed as JSON lines in the record's format.
contract DeployZap is Script {
    using StateLibrary for IPoolManager;

    function run() external {
        address router = vm.envAddress("ROUTER");
        require(router.code.length > 0, "ROUTER has no code");
        address dollToken = vm.envAddress("DOLL");
        uint256 feeRaw = vm.envOr("POOL_FEE", uint256(0));
        uint256 spacingRaw = vm.envOr("TICK_SPACING", uint256(200));
        require(feeRaw <= type(uint24).max, "POOL_FEE out of range");
        require(spacingRaw != 0 && spacingRaw <= 32_767, "TICK_SPACING out of range");
        // casting is safe: both values are range-checked just above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 fee = uint24(feeRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 tickSpacing = int24(int256(spacingRaw));
        address hooks = vm.envAddress("HOOKS");
        require(hooks.code.length > 0, "HOOKS has no code");

        // the record Deploy.s.sol wrote for this chain, if there is one
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        bool hasRecord = vm.isFile(path);
        string memory record = hasRecord ? vm.readFile(path) : "";

        // the pool the zap must swap: env first, the record second, and never neither
        bytes32 expected = vm.envOr("ENTRANCE_POOL_ID", bytes32(0));
        if (hasRecord) {
            require(router == vm.parseJsonAddress(record, ".router"), "ROUTER differs from the record's router");
            bytes32 recorded = vm.parseJsonBytes32(record, ".entrancePoolId");
            if (expected == bytes32(0)) expected = recorded;
            else require(recorded == bytes32(0) || recorded == expected, "ENTRANCE_POOL_ID differs from the record");
        }
        require(expected != bytes32(0), "ENTRANCE_POOL_ID not set and not in the deployment record");

        PoolKey memory venueKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(dollToken),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        require(PoolId.unwrap(venueKey.toId()) == expected, "venue key does not hash to ENTRANCE_POOL_ID");
        IPoolManager poolManager = FamilyRouter(router).poolManager();
        require(poolManager.getLiquidity(PoolId.wrap(expected)) > 0, "venue pool has no in-range liquidity");

        vm.startBroadcast();
        EthZap zap = new EthZap(FamilyRouter(router), venueKey);
        vm.stopBroadcast();

        bytes32 venuePoolId = PoolId.unwrap(zap.venuePoolId());
        require(venuePoolId == expected, "deployed zap swaps a different pool");

        console2.log(string.concat('"ethZap": "', vm.toString(address(zap)), '"'));
        console2.log(string.concat('"venuePoolId": "', vm.toString(venuePoolId), '"'));

        if (hasRecord) {
            string memory o = "deployment";
            vm.serializeJson(o, record);
            vm.serializeAddress(o, "ethZap", address(zap));
            string memory out = vm.serializeBytes32(o, "venuePoolId", venuePoolId);
            vm.writeJson(out, path);
            console2.log("updated", path);
        } else {
            console2.log("no deployment record at", path, "- add the two lines above to it");
        }
    }
}
