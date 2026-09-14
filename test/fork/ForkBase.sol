// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {RoundTestBase} from "../utils/RoundTestBase.sol";
import {FeeVault} from "../../contracts/FeeVault.sol";

/// @notice Tier `K` of docs/spec/PROPERTIES.md: the same stack the deploy script ships, but
/// built on the REAL Uniswap v4 `PoolManager` of chain 46630 instead of a freshly constructed
/// one. Nothing live is mutated: the fork is local and every contract under test is deployed
/// into it by `setUp`.
///
/// @dev The RPC URL is read from the environment as `RPC_TESTNET` and NOTHING else is read from
/// it: no key, no live deployment address. When the variable is absent every test skips cleanly,
/// so the suite stays green without network access.
///
/// PINNING. The chain's public endpoint serves only a short window of historical STATE: a block
/// a few thousand blocks back is still accepted for some reads and answered with
/// `metadata is not found` for others, which aborts a fork test outright. A hard-coded pin is
/// therefore not reproducible in practice, so the fork is taken at the LATEST block unless
/// `FORK_BLOCK` is set (an archive endpoint, or a replay of a recorded run).
/// {RECORDED_FORK_BLOCK} is the block the recorded run in docs/security/FORK_RESULTS.md used.
/// Identity of the singleton is pinned instead by {POOL_MANAGER_CODEHASH}, which is asserted on
/// every run and is what a reviewer should compare.
///
/// The randomness source is the labelled mock, exactly as a testnet deployment of the script
/// uses when `RANDOMNESS_SOURCE` is unset: a real drand relay needs a live beacon and a live
/// submitter, neither of which a pinned fork can provide. Scenarios that depend on beacon
/// content therefore drive the mock and say so on each test.
abstract contract ForkBase is RoundTestBase {
    /// @dev The canonical Uniswap v4 singleton on chain 46630. A public address; the only
    /// pre-existing contract any of these tests touches.
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    /// @dev The block the recorded run used; see the pinning note above.
    uint256 internal constant RECORDED_FORK_BLOCK = 118_017_927;
    uint256 internal constant FORK_CHAIN_ID = 46630;
    /// @dev The runtime code hash observed at {POOL_MANAGER}; asserted by
    /// `testFork_poolManagerIdentity` so a reviewer can confirm the same singleton.
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;

    // ---------------------------------------------------------------------------------
    // the DEPLOY constants (script/Deploy.s.sol, testnet row of docs/DEPLOY_CONSTANTS.md),
    // not the tranche-1 harness values FamilyTestBase defaults to
    // ---------------------------------------------------------------------------------
    uint256 internal constant DEPLOY_HOP_FEE_PPM = 750;
    uint256 internal constant DEPLOY_CREATOR_BPS = 4_000;
    uint256 internal constant DEPLOY_ANCESTOR_BPS = 5_000;
    uint256 internal constant DEPLOY_REINFORCE_BPS = 5_000;
    /// @dev The testnet schedule divisor: a 12-hour round is exercised in 12 minutes.
    uint64 internal constant DEPLOY_DURATION_SCALE_DIV = 60;
    /// @dev The contract floor, and what a testnet run passes as `SUNSET_DELAY_S`.
    uint64 internal constant DEPLOY_SUNSET_DELAY_S = 1 hours;

    /// @dev The parent-token buy that carries a candidate over the succession threshold.
    uint256 internal constant WINNING_BUY = 6_100_000e18;

    bool internal forked;

    function _hopFeePpm() internal view virtual override returns (uint256) {
        return DEPLOY_HOP_FEE_PPM;
    }

    function _creatorBps() internal view virtual override returns (uint256) {
        return DEPLOY_CREATOR_BPS;
    }

    function _ancestorBps() internal view virtual override returns (uint256) {
        return DEPLOY_ANCESTOR_BPS;
    }

    function _reinforceBps() internal view virtual override returns (uint256) {
        return DEPLOY_REINFORCE_BPS;
    }

    // ---------------------------------------------------------------------------------
    // fork set-up
    // ---------------------------------------------------------------------------------

    /// @dev Select the pinned fork. Returns false (and selects nothing) when `RPC_TESTNET` is
    /// unset, which is the signal for every test in the contract to skip.
    function _selectFork() internal returns (bool) {
        string memory url = vm.envOr("RPC_TESTNET", string(""));
        if (bytes(url).length == 0) return false;
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        assertEq(block.chainid, FORK_CHAIN_ID, "forked the wrong chain");
        assertGt(POOL_MANAGER.code.length, 0, "no PoolManager code at the pinned block");
        forked = true;
        return true;
    }

    /// @dev One complete stack on the real singleton, plus the genesis link and a funded actor.
    /// A single deployment per test contract keeps the number of distinct RPC reads modest.
    function _setUpForkFamily() internal returns (bool) {
        if (!_selectFork()) return false;
        sunsetDelay = DEPLOY_SUNSET_DELAY_S;
        durationScaleDiv = DEPLOY_DURATION_SCALE_DIV;

        manager = PoolManager(POOL_MANAGER);
        im = IPoolManager(POOL_MANAGER);
        swapRouter = new PoolSwapTest(manager);
        plainRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);

        _useStack(_deployStack(true, steward, priorRegistry));
        _createGenesis();
        vm.deal(address(this), 100_000 ether);
        return true;
    }

    /// @dev Every test body starts here: without an RPC URL there is nothing to assert against,
    /// and a skipped test is honest where a silently passing one is not.
    function _requireFork() internal {
        if (!forked) vm.skip(true);
    }

    // ---------------------------------------------------------------------------------
    // shared assertions and decoders
    // ---------------------------------------------------------------------------------

    /// @dev The FeeVault's own split event, decoded.
    struct Split {
        address currency;
        uint256 hopFee;
        uint256 protocolFee;
        uint256 terminalIndex;
        bool attributed;
        uint256 dev;
        uint256 creator;
        uint256 sleeve;
        uint256 reinforce;
    }

    /// @dev Every `FeeSplit` the vault emitted since the last {vm.recordLogs}, in order.
    function _splits() internal returns (Split[] memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == FeeVault.FeeSplit.selector) n++;
        }
        out = new Split[](n);
        uint256 k;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(vault) || logs[i].topics[0] != FeeVault.FeeSplit.selector) continue;
            (
                uint256 hopFee,
                uint256 protocolFee,
                uint256 terminalIndex,
                bool attributed,
                uint256 dev,
                uint256 creator,
                uint256 sleeve,
                uint256 reinforce
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool, uint256, uint256, uint256, uint256));
            out[k++] = Split({
                currency: address(uint160(uint256(logs[i].topics[1]))),
                hopFee: hopFee,
                protocolFee: protocolFee,
                terminalIndex: terminalIndex,
                attributed: attributed,
                dev: dev,
                creator: creator,
                sleeve: sleeve,
                reinforce: reinforce
            });
        }
    }

    /// @dev The published snipe schedule, with the subtraction taken at true floor division.
    function _snipePpmSpec(uint256 dt) internal view returns (uint256) {
        uint256 s = hook.SNIPE_S();
        if (dt >= s) return 0;
        uint256 start = hook.SNIPE_START_PPM();
        uint256 drop = start - hook.SNIPE_END_PPM();
        uint256 fall = (drop * dt) / s;
        if ((drop * dt) % s != 0) fall += 1; // the floor of a negative term is a ceiling of its size
        return start - fall;
    }

    /// @dev Everything the ancestor tree can ever pay out, across the whole chain.
    function _sleeveTotal() internal view returns (uint256 sum) {
        for (uint256 i = 0; i <= roundManager.headIndex(); i++) {
            sum += vault.claimableAncestor(i);
        }
    }
}
