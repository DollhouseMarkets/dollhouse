// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @title DeployVesting
/// @notice One launch-day run, from the launcher wallet, of the developer's 3% lock: deploys a
/// plain OpenZeppelin {VestingWallet} (linear release from `START` to `START + 365 days`, no
/// cliff), transfers `AMOUNT` of `TOKEN` into it, and reads the result back to prove the lock is
/// exactly what it should be before moving on.
///
/// @dev Env:
///   BENEFICIARY  the developer address that will own the wallet and receive releases
///   START        unix seconds the vesting clock starts at - required, no default. Pass the
///                launch block timestamp so START matches the graduation buy (§3a).
///   TOKEN        the $DOLL token address
///   AMOUNT       amount of TOKEN to lock (default 30,000,000e18, the developer's 3%)
contract DeployVesting is Script {
    uint64 constant DURATION_SECONDS = 365 days;
    uint256 constant DEFAULT_AMOUNT = 30_000_000e18;

    function run() external {
        address beneficiary = vm.envAddress("BENEFICIARY");
        require(beneficiary != address(0), "BENEFICIARY not set");
        uint64 start = uint64(vm.envUint("START"));
        address token = vm.envAddress("TOKEN");
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);

        vm.startBroadcast();
        VestingWallet wallet = _deployAndFund(token, beneficiary, start, amount);
        vm.stopBroadcast();

        _verify(wallet, token, beneficiary, start, amount);

        console2.log(string.concat('"devVesting": "', vm.toString(address(wallet)), '"'));
        console2.log("start", start);
        console2.log("fully vested", start + DURATION_SECONDS);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        if (vm.isFile(path)) {
            string memory record = vm.readFile(path);
            string memory o = "deployment";
            vm.serializeJson(o, record);
            string memory out = vm.serializeAddress(o, "devVesting", address(wallet));
            vm.writeJson(out, path);
            console2.log("updated", path);
        } else {
            console2.log("no deployment record at", path, "- add the line above to it");
        }
    }

    /// @dev Deploys the wallet and moves `amount` of `token` from the broadcaster into it.
    /// Broadcast-agnostic so a test can call it directly against a mock token.
    function _deployAndFund(address token, address beneficiary, uint64 start, uint256 amount)
        internal
        returns (VestingWallet wallet)
    {
        uint256 senderBalance = IERC20(token).balanceOf(msg.sender);
        require(senderBalance >= amount, "broadcaster balance below AMOUNT");

        wallet = new VestingWallet(beneficiary, start, DURATION_SECONDS);
        require(IERC20(token).transfer(address(wallet), amount), "token transfer failed");
    }

    /// @dev Reads the deployed wallet back and requires it matches the lock the script promised.
    function _verify(VestingWallet wallet, address token, address beneficiary, uint64 start, uint256 amount)
        internal
        view
    {
        require(IERC20(token).balanceOf(address(wallet)) == amount, "wallet token balance != AMOUNT");
        require(wallet.vestedAmount(token, start + DURATION_SECONDS) == amount, "vestedAmount at end != AMOUNT");
        uint256 expectedReleasable = block.timestamp <= start ? 0 : wallet.vestedAmount(token, uint64(block.timestamp));
        require(wallet.releasable(token) == expectedReleasable, "releasable inconsistent with linear schedule");
        require(wallet.owner() == beneficiary, "owner() != BENEFICIARY");
        require(wallet.start() == start, "start() != START");
        require(wallet.duration() == DURATION_SECONDS, "duration() != 365 days");
    }
}
