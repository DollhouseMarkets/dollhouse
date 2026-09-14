// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FamilyFactory} from "../contracts/FamilyFactory.sol";

/// @notice EIP-170. `forge test` runs with the contract size limit DISABLED, which is why a
/// 25,550-byte `FeeVault` passed 119 tests and then failed the real deploy at transaction 2
/// (docs/TESTNET_RUN.md). This test deploys the whole stack the way the deploy script does and
/// measures the runtime code of every address in it, so a regression is caught here rather than
/// on a chain.
contract CodeSizeTest is RoundTestBase {
    /// @notice The EIP-170 runtime bytecode limit.
    uint256 internal constant EIP170_LIMIT = 24_576;
    /// @notice The EIP-3860 initcode limit, which binds the DEPLOYMENT TRANSACTION.
    uint256 internal constant EIP3860_LIMIT = 49_152;

    function setUp() public {
        _setUpFamily();
    }

    function test_everyDeployedContractFitsUnderEip170() public {
        // a candidate too: its token is deployed by the factory at launch, on the same limit
        Cand memory c = _registerCandidate(address(0xC0DE), "CAND");

        _assertFits("FamilyFactory", address(factory));
        _assertFits("FamilyHook", address(hook));
        _assertFits("Locker", address(locker));
        _assertFits("RoundManager", address(roundManager));
        _assertFits("FeeVault", address(vault));
        _assertFits("BidDeployer", address(bidDeployer));
        _assertFits("FamilyRouter", address(familyRouter));
        _assertFits("FamilyLens", address(lens));
        // family tokens are EIP-1167 clones: only the one implementation carries real code,
        // so it is the only thing EIP-170 can bind on. The clones are asserted to be proxies.
        _assertFits("FamilyToken (implementation)", factory.tokenImplementation());
        // the developer allocation: the vesting contract genesis created, and the helper that
        // CREATEs it (kept out of the factory's own init code for EIP-3860)
        _assertFits("DevVesting", factory.devVesting());
        _assertFits("DevVestingDeployer", factory.devVestingDeployer());
        _assertIsClone("FamilyToken (genesis)", address(token));
        _assertIsClone("FamilyToken (candidate)", c.token);
    }

    /// @notice EIP-3860 binds the factory's whole deployment transaction: its creation code PLUS
    /// the ABI-encoded constructor arguments (the standard curve spec alone is a dozen words).
    /// `forge build --sizes` reports the creation code only, so the argument tail is measured
    /// here - the factory carries the Locker, the hook and the RoundManager in its init code and
    /// has the least room of anything in the stack.
    function test_factoryDeploymentTransactionFitsUnderEip3860() public {
        // encoded in two halves purely to keep the test itself out of stack-too-deep; the byte
        // count is identical to one `abi.encode` of the whole argument list
        bytes memory argsA = abi.encode(
            IPoolManager(address(manager)),
            feeVault,
            bidDeployerAddress,
            address(familyRouter),
            _hopFeePpm(),
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            GENESIS_UNIT
        );
        bytes memory argsB = abi.encode(
            _bondSchedule(),
            maxIndex,
            steward,
            sunsetDelay,
            priorRegistry,
            _standardCurveSpec(),
            bytes32(0),
            factory.tokenImplementation(),
            FamilyFactory.DevAllocation({
                deployer: factory.devVestingDeployer(),
                bps: devAllocationBps,
                cliff: vestingCliffS,
                duration: vestingDurationS
            })
        );
        uint256 argsLength = argsA.length + argsB.length;
        uint256 size = type(FamilyFactory).creationCode.length + argsLength;
        emit log_named_uint("FamilyFactory deployment transaction bytes", size);
        emit log_named_uint("...of which constructor arguments", argsLength);
        assertLe(size, EIP3860_LIMIT, "the factory deployment transaction exceeds the EIP-3860 limit");
    }

    /// @dev An EIP-1167 minimal proxy is exactly 45 runtime bytes.
    function _assertIsClone(string memory name, address a) internal {
        uint256 size = a.code.length;
        emit log_named_uint(string.concat(name, " runtime bytes"), size);
        assertEq(size, 45, string.concat(name, " is not a minimal proxy"));
    }

    function _assertFits(string memory name, address a) internal {
        uint256 size = a.code.length;
        emit log_named_uint(string.concat(name, " runtime bytes"), size);
        assertGt(size, 0, string.concat(name, " has no code"));
        assertLe(size, EIP170_LIMIT, string.concat(name, " exceeds the EIP-170 limit"));
    }
}
