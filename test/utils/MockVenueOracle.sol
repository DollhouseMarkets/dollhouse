// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev A venue oracle whose answers - and misbehaviour - a test sets directly. Mode 0 answers
/// (sqrtP, status) and (sqrtP, t, streak) like {VenueOracle}; 1 reverts; 2 burns all gas it is
/// given; 3 returns one word only; 4 returns out-of-range words.
contract MockVenueOracle {
    uint160 public sqrtP;
    uint8 public status;
    uint32 public streak;
    uint8 public mode;
    /// @dev What {venueId} and {poolManager} report, for the factory's bind checks.
    bytes32 public venueId;
    address public poolManager;

    function setVenue(bytes32 _venueId, address _poolManager) external {
        venueId = _venueId;
        poolManager = _poolManager;
    }

    function set(uint160 _sqrtP, uint8 _status, uint32 _streak, uint8 _mode) external {
        sqrtP = _sqrtP;
        status = _status;
        streak = _streak;
        mode = _mode;
    }

    function startPrice() external view returns (uint160, uint8) {
        _misbehave();
        return (sqrtP, status);
    }

    function latest() external view returns (uint160, uint64, uint32) {
        _misbehave();
        return (sqrtP, uint64(block.timestamp), streak);
    }

    function _misbehave() internal view {
        uint8 m = mode;
        if (m == 1) revert("oracle down");
        if (m == 2) {
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        if (m == 3) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (m == 4) {
            assembly {
                mstore(0, not(0))
                mstore(32, 999)
                mstore(64, not(0))
                return(0, 96)
            }
        }
    }
}
