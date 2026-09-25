// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockDoll} from "./MockDoll.sol";

/// @notice THE EDGE CURRENCY, BADLY BEHAVED. The protocol adopts an ERC-20 it did not
/// write as canonical index 0, and every bond, fee and payout is denominated in it. This asks
/// what happens when that token is not the well-behaved one the suite assumes, so
/// this one can be switched into each shape a real launch token can take:
///
///   feeBps      a FEE ON TRANSFER: the recipient receives less than was sent
///   returnsFalse    the non-standard `false` return instead of a revert
///   paused      every transfer reverts, as a pausable token does once it is paused
///   blocked[a]  a blacklist: transfers to or from `a` revert
///   burnsGasTo  a transfer TO that address consumes all the gas it was given
///   reenters    a transfer FROM that address calls `flushForfeits()` back on it
///   registerVia a transfer FROM `registerFrom` calls `registerCandidate` on the factory
///   feeFrom     narrows the transfer fee above to transfers out of one address
///
/// It shares {MockDoll}'s storage layout (both add nothing before the OpenZeppelin ERC-20 slots),
/// so a test etches this code over the deployed $DOLL and keeps every balance already minted.
/// The switches start off, so an etch on its own changes nothing.
contract HostileDoll is MockDoll {
    /// @dev Where a transfer fee goes. Burning it instead would move `totalSupply`, which the
    /// adoption checks read, so it is swept to a sink nobody in the suite is.
    address public constant FEE_SINK = address(0x000000000000000000000000000000000000Fee5);

    uint256 public feeBps;
    bool public returnsFalse;
    bool public paused;
    mapping(address => bool) public blocked;
    /// @dev A token that eats every drop of gas the caller forwarded it, on transfers
    /// to this one address. A call made with `try` gets 63/64 of what is left, so this is the
    /// shape that tests whether the remaining 64th is enough for the round to crown anyway. It is
    /// aimed at ONE recipient so that a test can starve exactly the delivery it means to.
    address public burnsGasTo;
    /// @dev The RoundManager to re-enter mid-transfer. Set it and any transfer OUT of
    /// that address calls `flushForfeits()` on it, from inside the transfer the flush is making.
    address public reenters;
    /// @dev The factory to re-enter mid-transfer, and the address whose OUTGOING
    /// transfers trigger it. Set both and any transfer out of `registerFrom` calls
    /// `registerCandidate` on `registerVia`, from inside the transfer the protocol is making.
    address public registerVia;
    address public registerFrom;
    /// @dev Whether the re-entrant registration was attempted, whether it was REFUSED, and the
    /// bytes it was refused with - recorded rather than bubbled, so the outer call finishes and a
    /// test can name the guard that rejected it.
    bool public registerAttempted;
    bool public registerRejected;
    bytes public registerRevertData;
    /// @dev A latch, so the transfers the re-entrant registration itself makes cannot recurse.
    bool private _registering;
    /// @dev When set, the transfer fee applies ONLY to transfers out of this address.
    /// Unset (the default) it applies to every transfer.
    address public feeFrom;

    /// @dev Whether the re-entrant call above was REFUSED. The call is made with `call` and its
    /// result is recorded rather than bubbled, so the outer flush finishes and a test can assert
    /// both halves: the guard held, and the forfeits were delivered exactly once.
    bool public reentryRejected;

    constructor(uint8 decimals_) MockDoll(decimals_) {}

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setReturnsFalse(bool on) external {
        returnsFalse = on;
    }

    function setPaused(bool on) external {
        paused = on;
    }

    function setBlocked(address who, bool on) external {
        blocked[who] = on;
    }

    /// @dev Arming and DISARMING both go through here. What was recorded is deliberately left
    /// alone: a test disarms the token before it reads the record, and a setter that wiped it
    /// would erase the evidence it is about to assert on.
    function setRegisterReentry(address factory, address from) external {
        registerVia = factory;
        registerFrom = from;
    }

    function setFeeFrom(address who) external {
        feeFrom = who;
    }

    function setBurnsGasTo(address to) external {
        burnsGasTo = to;
    }

    function setReenters(address roundManager) external {
        reenters = roundManager;
        reentryRejected = false;
    }

    /// @dev The `false` return is only interesting on the push side: a token that answers `false`
    /// and moves nothing is what `SafeERC20` exists to catch.
    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnsFalse) return false;
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert("paused");
        if (blocked[from] || blocked[to]) revert("blocked");
        if (reenters != address(0) && from == reenters) {
            (bool ok,) = reenters.call(abi.encodeWithSignature("flushForfeits()"));
            reentryRejected = !ok;
        }
        if (registerVia != address(0) && from == registerFrom && !_registering) {
            _registering = true;
            (bool ok, bytes memory ret) = registerVia.call(
                abi.encodeWithSignature(
                    "registerCandidate(string,string,string,uint256)", "REENTRY", "REENTRY", "", type(uint256).max
                )
            );
            _registering = false;
            registerAttempted = true;
            registerRejected = !ok;
            registerRevertData = ret;
        }
        if (burnsGasTo != address(0) && to == burnsGasTo) {
            // leave just enough to unwind this frame: the caller keeps its 64th and nothing else
            while (gasleft() > 2_000) {
                keccak256(abi.encode(gasleft()));
            }
        }
        bool feeApplies = feeFrom == address(0) || from == feeFrom;
        uint256 fee = from == address(0) || to == address(0) || !feeApplies ? 0 : (value * feeBps) / 10_000;
        if (fee != 0) {
            super._update(from, FEE_SINK, fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
