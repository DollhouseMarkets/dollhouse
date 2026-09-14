// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {DevVestingDeployer} from "../contracts/DevVesting.sol";

import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {FamilyLens} from "../contracts/FamilyLens.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {Locker} from "../contracts/Locker.sol";
import {RoundManager, RoundManagerDeployer} from "../contracts/RoundManager.sol";
import {V4UnlockGuardProbe} from "../contracts/libraries/V4UnlockGuardProbe.sol";
import {MockRandomnessSource} from "../contracts/randomness/MockRandomnessSource.sol";
import {DrandSource} from "../contracts/randomness/DrandSource.sol";
import {CurveSegment} from "../contracts/types/CurveSegment.sol";

/// @title Deploy
/// @notice Deploys the whole family stack against an EXISTING Uniswap v4 PoolManager and creates
/// the one genesis link, then writes `deployments/<chainid>.json`.
///
/// @dev The deployment order is forced by the hook: its address is CREATE2-mined against the
/// FACTORY predicted address (the factory is the CREATE2 deployer) and its constructor args
/// include the FeeVault and the FamilyRouter, which do not exist yet. So all three addresses are
/// predicted from the deployer nonce before anything is sent, exactly as `FamilyTestBase` does:
///
///   nonce n+0 : FamilyToken    -> the implementation every family token is a 1167 clone of
///   nonce n+1 : DevVestingDeployer -> CREATEs the genesis DevVesting, out of the factory's initcode
///   nonce n+2 : RoundManagerDeployer -> CREATEs the RoundManager, likewise (EIP-3860)
///   nonce n+3 : MockRandomnessSource -> ONLY when RANDOMNESS_SOURCE is unset (testnet)
///   nonce k+0 : FamilyFactory   -> deploys Locker (CREATE), FamilyHook (CREATE2), RoundManager
///   nonce k+1 : FeeVault
///   nonce k+2 : BidDeployer    -> the Locker's only depositor and the vault's only keeper hook
///   nonce k+3 : FamilyRouter
///   nonce k+4 : FamilyLens
contract Deploy is Script {
    // ---------------------------------------------------------------------------------------
    // deploy constants (docs/DEPLOY_CONSTANTS.md)
    // ---------------------------------------------------------------------------------------

    /// @dev Per-hop parent-side fee: DEPLOY_CONSTANTS says 7.5 bps, which is exactly 750 ppm now
    /// that the hook charges in parts-per-million.
    uint256 internal constant HOP_FEE_PPM = 750;
    /// @dev Fee split: dev 20% (hardcoded `FeeVault.DEV_BPS`), creator 40%, and the 40% remainder
    /// split 50/50 between the ancestor sleeve (20% of the whole) and reinforcement (20%).
    uint256 internal constant CREATOR_BPS = 4_000;
    uint256 internal constant ANCESTOR_BPS = 5_000;
    uint256 internal constant REINFORCE_BPS = 5_000;
    /// @dev Threshold: 0.15% of parent supply, decaying to a floor of 0.25x that.
    uint256 internal constant H_FRAC_WAD = 1.5e15;
    uint256 internal constant H_MIN_FRAC_WAD = 3.75e14;

    uint256 internal constant SUPPLY = 1e9 * 1e18;
    /// @dev The genesis curve is the standard shape denominated in GENESIS_UNIT instead of a
    /// parent supply: start FDV 1 ETH, ladder to 1000 ETH, tail to 100,000 ETH.
    uint256 internal constant GENESIS_UNIT = 1000 ether;
    /// @dev Candidate bond (F6 schedule the contract still supports: `base`, doubling every
    /// `BOND_DOUBLING_EVERY` links, capped at `max`). Design decision 2026-09-13: the bond is FLAT
    /// on mainnet, spam resistance only, so `BOND_MAX_WEI == BOND_BASE_WEI` here - `bondFor`
    /// clamps every depth to `BOND_MAX_WEI` (it detects the shift overflow and saturates instead
    /// of wrapping, so this is safe at any index up to the sleeve cap regardless of
    /// `BOND_DOUBLING_EVERY`). These are the MAINNET defaults, overridable per deployment through
    /// the environment; a testnet run overrides them with the doubling schedule of
    /// docs/DEPLOY_CONSTANTS.md instead (`BOND_BASE_WEI` / `BOND_DOUBLING_EVERY` / `BOND_MAX_WEI`
    /// env vars).
    uint256 internal constant BOND_BASE_WEI = 0.008 ether;
    uint256 internal constant BOND_DOUBLING_EVERY = 4;
    uint256 internal constant BOND_MAX_WEI = 0.008 ether;
    /// @dev Sunset delay (audit 2): the public warning between `announceSunset(successor)` and
    /// the first refused round. Mainnet: 7 days. A testnet run overrides it through
    /// `SUNSET_DELAY_S` (1 hour is the contract floor) so the handover can be exercised live.
    uint64 internal constant SUNSET_DELAY_S = 7 days;
    /// @dev Keeper bounty floor (audit 5): the 1% proportional bounty is far below the gas of a
    /// deployment at beta scale, so every ETH deployment pays at least this much out of the same
    /// generation's entitlement (capped at 20% of the ETH the call consumes). Testnet default;
    /// override with `MIN_BOUNTY_WEI`.
    uint256 internal constant MIN_BOUNTY_WEI = 3e14;
    /// @dev Developer allocation (design decision 2026-09-11): 3% of the GENESIS supply, minted at
    /// genesis to an immutable `DevVesting` contract - 1-month cliff, then 12-month linear, no
    /// clawback and no acceleration. Candidate tokens have no allocation at all. Overridable per
    /// deployment (`DEV_ALLOCATION_BPS`, `VESTING_CLIFF_S`, `VESTING_DURATION_S`); the testnet run
    /// shortens the schedule to 3600 s / 7200 s so the cliff and a release can be exercised live.
    uint256 internal constant DEV_ALLOCATION_BPS = 300;
    uint64 internal constant VESTING_CLIFF_S = 30 days;
    uint64 internal constant VESTING_DURATION_S = 365 days;
    /// @dev MECHANISM_v3 sec.3. END_TIMEOUT_S: how long a round waits for the drand relay before
    /// ending deterministically at `T`. DURATION_SCALE_DIV: 1 on mainnet; a testnet run sets 60
    /// (through the environment) so a 12-hour round is exercised in 12 minutes. RANDOMNESS_DELAY_S
    /// is only used when this script has to deploy the labelled mock source.
    uint64 internal constant END_TIMEOUT_S = 30 minutes;
    uint64 internal constant DURATION_SCALE_DIV = 1;
    /// @dev drand `evmnet` (`bls-bn254-unchained-on-g1`, BN254, 3 s period), from
    /// `https://api.drand.sh/v2/beacons/evmnet/info`, re-verified live 2026-09-11. The four words
    /// are the beacon's 128-byte G2 group key in the order the API serves it; `test/Drand.t.sol`
    /// proves real beacons of this chain verify against exactly these constants on chain.
    /// `DRAND_SAFETY_S` is how far into the future `pin()` reaches: two beacon periods, so the
    /// pinned round cannot already exist when the pinning transaction lands.
    uint64 internal constant DRAND_GENESIS_TIME = 1727521075;
    uint64 internal constant DRAND_PERIOD_S = 3;
    uint64 internal constant DRAND_SAFETY_S = 6;
    uint256 internal constant DRAND_PK_0 = 0x07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382;
    uint256 internal constant DRAND_PK_1 = 0x0557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f;
    uint256 internal constant DRAND_PK_2 = 0x0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6;
    uint256 internal constant DRAND_PK_3 = 0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b;

    /// @dev The permission bits the mined hook address must encode; must equal
    /// `FamilyHook.HOOK_FLAGS`, which the hook constructor asserts against its own address.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    string internal constant GENESIS_NAME = "Dollhouse";
    string internal constant GENESIS_SYMBOL = "DOLL";
    string internal constant GENESIS_URI = "ipfs://family-genesis";

    /// @dev The deploy-target standard curve: shares 20/25/35/20% over FDV ratios
    /// 1e-3 -> 1e-2 -> 1e-1 -> 1 -> 100 of the parent supply (the last band is the tail).
    function standardCurveSpec() public pure returns (CurveSegment[] memory spec) {
        spec = new CurveSegment[](4);
        spec[0] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e15, fdvRatioUpperWad: 1e16});
        spec[1] = CurveSegment({shareWad: 0.25e18, fdvRatioLowerWad: 1e16, fdvRatioUpperWad: 1e17});
        spec[2] = CurveSegment({shareWad: 0.35e18, fdvRatioLowerWad: 1e17, fdvRatioUpperWad: 1e18});
        spec[3] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e18, fdvRatioUpperWad: 100e18});
    }

    /// @dev Recorded in the deployment artefact so `script/live/verify.sh` can submit them: the
    /// RoundManager is CREATEd by the helper (EIP-3860) and the randomness source is either a
    /// `DrandSource` this script deployed or an address passed in through the environment.
    address internal roundManagerDeployerAddr;
    address internal randomnessSourceAddr;
    /// @dev REVIEW 2: the result of the REN-01 guard self-check, recorded in the artefact.
    bool internal renGuardBound;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address deployer = msg.sender;
        require(poolManager.code.length > 0, "PoolManager has no code");

        // DEVELOPER: the immutable recipient of the developer share. There is no setter and no
        // transfer, ever, so it must be a DELIBERATE address (audit F8): a cold wallet or a
        // multisig, not whichever hot key happens to broadcast this script. Set
        // ALLOW_DEV_EQ_DEPLOYER=1 only for a throwaway testnet run.
        address developer = vm.envAddress("DEVELOPER");
        require(developer != address(0), "DEVELOPER must be set");
        require(
            developer != deployer || vm.envOr("ALLOW_DEV_EQ_DEPLOYER", uint256(0)) == 1,
            "DEVELOPER equals the deployer key: set ALLOW_DEV_EQ_DEPLOYER=1 to allow it"
        );
        console2.log("developer", developer);

        // STEWARD: the only privileged address in the whole system, and its only power is
        // `RoundManager.announceSunset` - stop opening NEW rounds, 7 days after a public
        // announcement, once and irreversibly (README "Upgrade model"). Defaults to the deployer,
        // which is right for a testnet run; a MAINNET deploy must pass a MULTISIG here (or
        // address(0), which makes the deployment un-sunsettable and therefore un-upgradeable).
        // ...and it must be set EXPLICITLY too: `address(0)` is a legitimate, deliberate choice
        // (the deployment can then never be sunset), so it cannot be distinguished from "forgot
        // to set it" unless the variable is required.
        address steward = vm.envAddress("STEWARD");
        // CONTINUE_FROM: the RoundManager of the version this deployment continues the trunk
        // from. Unset (address(0)) = a fresh trunk, which is the only mode that has a genesis.
        address continueFrom = vm.envOr("CONTINUE_FROM", address(0));
        require(continueFrom == address(0) || continueFrom.code.length > 0, "CONTINUE_FROM has no code");
        // MAX_INDEX: deploy-time depth cap for a capped beta. 0 means the Fenwick sleeve's own
        // cap (4095), which is the deepest chain the ancestor payout can address; anything above
        // it is refused by the RoundManager constructor. Testnet: 0.
        uint256 maxIndex = vm.envOr("MAX_INDEX", uint256(0));
        RoundManager.Bond memory bond = RoundManager.Bond({
            base: vm.envOr("BOND_BASE_WEI", BOND_BASE_WEI),
            doublingEvery: vm.envOr("BOND_DOUBLING_EVERY", BOND_DOUBLING_EVERY),
            max: vm.envOr("BOND_MAX_WEI", BOND_MAX_WEI)
        });
        uint64 sunsetDelay = uint64(vm.envOr("SUNSET_DELAY_S", uint256(SUNSET_DELAY_S)));
        // RANDOM END (MECHANISM_v3 sec.3). END_TIMEOUT bounds how long a round waits for the
        // beacon before ending deterministically at `T`. DURATION_SCALE_DIV divides EVERY value
        // of the adaptive schedule so a testnet run can exercise a 12-hour round in 12 minutes;
        // it must be 1 on mainnet, which is asserted below.
        uint64 endTimeout = uint64(vm.envOr("END_TIMEOUT_S", uint256(END_TIMEOUT_S)));
        uint64 durationScaleDiv = uint64(vm.envOr("DURATION_SCALE_DIV", uint256(DURATION_SCALE_DIV)));
        require(durationScaleDiv != 0, "DURATION_SCALE_DIV must be at least 1");
        require(
            durationScaleDiv == 1 || vm.envOr("ALLOW_SCALED_SCHEDULE", uint256(0)) == 1,
            "DURATION_SCALE_DIV != 1 shortens every round: set ALLOW_SCALED_SCHEDULE=1 for a testnet run"
        );
        // RANDOMNESS_SOURCE: the IRandomnessSource this deployment draws its random end from.
        // Unset deploys a clearly labelled MockRandomnessSource, which is acceptable ONLY on a
        // testnet: see docs/DEPLOY_CONSTANTS.md.
        address randomnessSource = vm.envOr("RANDOMNESS_SOURCE", address(0));
        console2.log("endTimeoutS", endTimeout);
        console2.log("durationScaleDiv", durationScaleDiv);
        FamilyFactory.DevAllocation memory devAllocation = FamilyFactory.DevAllocation({
            deployer: address(0), // filled in once the DevVestingDeployer is broadcast
            bps: vm.envOr("DEV_ALLOCATION_BPS", DEV_ALLOCATION_BPS),
            cliff: uint64(vm.envOr("VESTING_CLIFF_S", uint256(VESTING_CLIFF_S))),
            duration: uint64(vm.envOr("VESTING_DURATION_S", uint256(VESTING_DURATION_S)))
        });
        console2.log("devAllocationBps", devAllocation.bps);
        console2.log("vestingCliffS", devAllocation.cliff);
        console2.log("vestingDurationS", devAllocation.duration);
        console2.log("steward", steward);
        console2.log("sunsetDelayS", sunsetDelay);
        console2.log("continueFrom", continueFrom);
        console2.log("maxIndex", maxIndex);

        // ---- address predictions (all CREATEs below come from `deployer`, in this order) ----
        // FamilyToken, DevVestingDeployer and RoundManagerDeployer are all broadcast BEFORE the
        // factory (their code is kept out of its init code for EIP-3860), and so is the mock
        // randomness source when one is being deployed.
        uint256 nonce = vm.getNonce(deployer) + (randomnessSource == address(0) ? 4 : 3);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedBidDeployer = vm.computeCreateAddress(deployer, nonce + 2);
        address predictedRouter = vm.computeCreateAddress(deployer, nonce + 3);
        address predictedLocker = vm.computeCreateAddress(predictedFactory, 1);

        bytes memory hookArgs =
            abi.encode(poolManager, predictedFactory, predictedLocker, predictedVault, predictedRouter, HOP_FEE_PPM);
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(predictedFactory, HOOK_FLAGS, type(FamilyHook).creationCode, hookArgs);
        console2.log("mined hook", minedHook);

        uint256 startBlock = block.number;
        vm.startBroadcast();

        // the token implementation must exist before the factory, which verifies the link back;
        // so must the DevVestingDeployer, whose code the factory would otherwise have to carry
        FamilyToken tokenImplementation = new FamilyToken(predictedFactory);
        DevVestingDeployer vestingDeployer = new DevVestingDeployer();
        // the RoundManager is CREATEd through a helper for the same EIP-3860 reason: the adaptive
        // schedule and the random end pushed the factory's deployment transaction over the limit
        RoundManagerDeployer roundManagerDeployer = new RoundManagerDeployer();
        if (randomnessSource == address(0)) {
            if (vm.envOr("USE_MOCK_RANDOMNESS", uint256(0)) == 1) {
                randomnessSource = address(new MockRandomnessSource(DRAND_SAFETY_S));
                console2.log("WARNING: deployed a MockRandomnessSource - TESTNET ONLY", randomnessSource);
            } else {
                randomnessSource = address(
                    new DrandSource(
                        DRAND_GENESIS_TIME,
                        DRAND_PERIOD_S,
                        DRAND_SAFETY_S,
                        [DRAND_PK_0, DRAND_PK_1, DRAND_PK_2, DRAND_PK_3]
                    )
                );
            }
        }
        console2.log("randomnessSource", randomnessSource);
        roundManagerDeployerAddr = address(roundManagerDeployer);
        randomnessSourceAddr = randomnessSource;

        devAllocation.deployer = address(vestingDeployer);
        FamilyFactory factory = new FamilyFactory(
            IPoolManager(poolManager),
            predictedVault,
            predictedBidDeployer,
            predictedRouter,
            HOP_FEE_PPM,
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            GENESIS_UNIT,
            bond,
            maxIndex,
            steward,
            sunsetDelay,
            continueFrom,
            standardCurveSpec(),
            hookSalt,
            address(tokenImplementation),
            devAllocation,
            FamilyFactory.RoundSetup({
                deployer: address(roundManagerDeployer),
                randomness: randomnessSource,
                endTimeout: endTimeout,
                durationScaleDiv: durationScaleDiv
            })
        );
        FeeVault vault = new FeeVault(factory, developer, CREATOR_BPS, ANCESTOR_BPS, REINFORCE_BPS);
        BidDeployer bidDeployer = new BidDeployer(vault, vm.envOr("MIN_BOUNTY_WEI", MIN_BOUNTY_WEI));
        FamilyRouter router = new FamilyRouter(factory);
        FamilyLens lens = new FamilyLens(factory);

        require(address(factory) == predictedFactory, "factory address prediction");
        require(address(vault) == predictedVault, "fee vault address prediction");
        require(address(bidDeployer) == predictedBidDeployer, "bid deployer address prediction");
        require(address(router) == predictedRouter, "router address prediction");
        require(address(factory.hook()) == minedHook, "mined hook address");
        require(factory.hook().HOOK_FLAGS() == HOOK_FLAGS, "hook flag mismatch");
        require(address(factory.locker()) == predictedLocker, "locker address prediction");

        address token;
        PoolKey memory key;
        uint160 initSqrtPriceX96;
        if (continueFrom == address(0)) {
            (token, key) = factory.createGenesis(GENESIS_NAME, GENESIS_SYMBOL, GENESIS_URI);
            // the factory derives the curve and the opening price on-chain now, so read back what
            // it actually registered rather than recomputing it here
            initSqrtPriceX96 = factory.hook().poolInfo(key.toId()).initSqrtPriceX96;
        } else {
            // a continuation stack has no genesis of its own: the trunk (and its ETH edge) stays
            // the original version's genesis pool, resolved through the registry chain
            token = factory.genesisToken();
            key = factory.roundManager().poolKeyOf(0);
            require(factory.roundManager().headIndex() == RoundManager(continueFrom).headIndex(), "head continuity");
            initSqrtPriceX96 = 0;
        }

        // REVIEW 2 - THE REN-01 GUARD IS BOUND TO THIS MANAGER. `FamilyFactory.wire` has already
        // proved the guard reads `false` here (it is called by the genesis launch above, and by
        // the first candidate registration on a continuation stack). What it cannot prove without
        // opening an unlock is the other half - that the read answers `true` INSIDE one - and a
        // guard that never answers `true` is a guard that fails open on every `notInsideUnlock`
        // in the stack. The throwaway probe opens one and asserts it; it reverts the deployment
        // if the guard is not bound, and the answer goes into the artefact either way.
        factory.wire();
        renGuardBound = new V4UnlockGuardProbe().probe(poolManager);
        console2.log("renGuardBound", renGuardBound);

        vm.stopBroadcast();

        _write(
            factory,
            vault,
            bidDeployer,
            router,
            lens,
            token,
            key,
            initSqrtPriceX96,
            poolManager,
            startBlock,
            continueFrom
        );
    }

    function _write(
        FamilyFactory factory,
        FeeVault vault,
        BidDeployer bidDeployer,
        FamilyRouter router,
        FamilyLens lens,
        address token,
        PoolKey memory key,
        uint160 initSqrtPriceX96,
        address poolManager,
        uint256 startBlock,
        address continueFrom
    ) internal {
        RoundManager roundManager = factory.roundManager();
        string memory o = "deployment";

        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployBlock", startBlock);
        vm.serializeAddress(o, "deployer", msg.sender);
        vm.serializeAddress(o, "poolManager", poolManager);
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "hook", address(factory.hook()));
        vm.serializeAddress(o, "locker", address(factory.locker()));
        vm.serializeAddress(o, "roundManager", address(roundManager));
        vm.serializeAddress(o, "tokenImplementation", factory.tokenImplementation());
        vm.serializeAddress(o, "feeVault", address(vault));
        vm.serializeAddress(o, "bidDeployer", address(bidDeployer));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "lens", address(lens));
        vm.serializeAddress(o, "genesisToken", token);
        vm.serializeBytes32(o, "genesisPoolId", PoolId.unwrap(key.toId()));
        vm.serializeUint(o, "genesisInitSqrtPriceX96", initSqrtPriceX96);
        vm.serializeAddress(o, "developer", vault.developer());
        vm.serializeAddress(o, "devVesting", factory.devVesting());
        vm.serializeAddress(o, "devVestingDeployer", factory.devVestingDeployer());
        vm.serializeAddress(o, "roundManagerDeployer", roundManagerDeployerAddr);
        vm.serializeAddress(o, "randomnessSource", randomnessSourceAddr);
        vm.serializeAddress(o, "steward", roundManager.steward());
        vm.serializeAddress(o, "continuesFrom", continueFrom);
        vm.serializeUint(o, "startIndex", roundManager.headIndex());

        string memory c = "constants";
        vm.serializeUint(c, "hopFeePpm", HOP_FEE_PPM);
        vm.serializeUint(c, "protocolFeePpm", factory.hook().PROTOCOL_FEE_PPM());
        vm.serializeUint(c, "devBps", vault.DEV_BPS());
        vm.serializeUint(c, "creatorBps", CREATOR_BPS);
        vm.serializeUint(c, "ancestorBps", ANCESTOR_BPS);
        vm.serializeUint(c, "reinforceBps", REINFORCE_BPS);
        vm.serializeUint(c, "hFracWad", H_FRAC_WAD);
        vm.serializeUint(c, "hMinFracWad", H_MIN_FRAC_WAD);
        vm.serializeUint(c, "bondBaseWei", roundManager.BOND_BASE_WEI());
        vm.serializeUint(c, "bondDoublingEvery", roundManager.BOND_DOUBLING_EVERY());
        vm.serializeUint(c, "bondMaxWei", roundManager.BOND_MAX_WEI());
        vm.serializeUint(c, "maxIndex", roundManager.MAX_INDEX());
        // the schedule is adaptive now (MECHANISM_v3 sec.2): what is constant is its SHAPE, so the
        // artefact records the shape constants plus the first rounds the schedule produces
        vm.serializeUint(c, "baseTradingS", roundManager.BASE_TRADING_S());
        vm.serializeUint(c, "maxTradingS", roundManager.MAX_TRADING_S());
        vm.serializeUint(c, "minRegistrationS", roundManager.MIN_REGISTRATION_S());
        vm.serializeUint(c, "maxRegistrationS", roundManager.MAX_REGISTRATION_S());
        vm.serializeUint(c, "durationScaleDiv", roundManager.DURATION_SCALE_DIV());
        vm.serializeUint(c, "round1TradingS", roundManager.durationFor(1));
        vm.serializeUint(c, "round1RegistrationS", roundManager.registrationFor(1));
        vm.serializeUint(c, "round13TradingS", roundManager.durationFor(13));
        vm.serializeUint(c, "round13RegistrationS", roundManager.registrationFor(13));
        vm.serializeUint(c, "round13LateEntryS", roundManager.lateEntryUntil(13));
        vm.serializeUint(c, "randomEndS", roundManager.RANDOM_END_S());
        vm.serializeUint(c, "endTimeoutS", roundManager.END_TIMEOUT());
        vm.serializeBool(c, "renGuardBound", renGuardBound);
        vm.serializeAddress(c, "randomnessSource", address(roundManager.randomness()));
        vm.serializeUint(c, "round1ClosingWindowS", roundManager.closingWindowFor(1));
        vm.serializeUint(c, "round13ClosingWindowS", roundManager.closingWindowFor(13));
        vm.serializeUint(c, "submitS", roundManager.SUBMIT_S());
        vm.serializeUint(c, "sunsetDelayS", roundManager.sunsetDelay());
        vm.serializeUint(c, "roleTransferDelayS", roundManager.ROLE_TRANSFER_DELAY());
        vm.serializeUint(c, "devAllocationBps", factory.DEV_ALLOCATION_BPS());
        vm.serializeUint(c, "vestingCliffS", factory.VESTING_CLIFF_S());
        vm.serializeUint(c, "vestingDurationS", factory.VESTING_DURATION_S());
        vm.serializeUint(c, "minBountyWei", bidDeployer.MIN_BOUNTY_WEI());
        vm.serializeUint(c, "snipeS", factory.hook().SNIPE_S());
        vm.serializeUint(c, "tickSpacing", uint256(int256(factory.TICK_SPACING())));
        vm.serializeUint(c, "supply", SUPPLY);
        string memory constantsJson = vm.serializeUint(c, "genesisUnitWei", GENESIS_UNIT);

        string memory h = "hookFlags";
        uint160 flags = uint160(address(factory.hook()));
        vm.serializeUint(h, "hookFlagsMask", uint256(factory.hook().HOOK_FLAGS()));
        vm.serializeBool(h, "beforeInitialize", flags & Hooks.BEFORE_INITIALIZE_FLAG != 0);
        vm.serializeBool(h, "beforeAddLiquidity", flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0);
        vm.serializeBool(h, "beforeRemoveLiquidity", flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0);
        vm.serializeBool(h, "beforeSwap", flags & Hooks.BEFORE_SWAP_FLAG != 0);
        vm.serializeBool(h, "afterSwap", flags & Hooks.AFTER_SWAP_FLAG != 0);
        vm.serializeBool(h, "beforeDonate", flags & Hooks.BEFORE_DONATE_FLAG != 0);
        vm.serializeBool(h, "beforeSwapReturnsDelta", flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0);
        string memory flagsJson =
            vm.serializeBool(h, "afterSwapReturnsDelta", flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0);

        vm.serializeString(o, "constants", constantsJson);
        string memory out = vm.serializeString(o, "hookPermissions", flagsJson);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("wrote", path);
    }
}
