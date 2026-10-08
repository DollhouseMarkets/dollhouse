// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";

import {FamilyFactory} from "../contracts/FamilyFactory.sol";
import {FamilyHook} from "../contracts/FamilyHook.sol";
import {FamilyRouter} from "../contracts/FamilyRouter.sol";
import {FamilyLens} from "../contracts/FamilyLens.sol";
import {VenueOracle} from "../contracts/VenueOracle.sol";
import {BidDeployer} from "../contracts/BidDeployer.sol";
import {FeeVault} from "../contracts/FeeVault.sol";
import {RoundManager, RoundManagerDeployer} from "../contracts/RoundManager.sol";
import {V4UnlockGuardProbe} from "../contracts/libraries/V4UnlockGuardProbe.sol";
import {MockRandomnessSource} from "../contracts/randomness/MockRandomnessSource.sol";
import {DrandSource} from "../contracts/randomness/DrandSource.sol";
import {CurveSegment} from "../contracts/types/CurveSegment.sol";
import {DeployConstantsLib} from "./DeployConstantsLib.sol";

/// @title Deploy
/// @notice Deploys the whole family stack against an EXISTING Uniswap v4 PoolManager and ADOPTS
/// the external genesis token as canonical index 0, then writes `deployments/<chainid>.json`.
///
/// @dev There is no genesis LAUNCH any more. `GENESIS_TOKEN` is an ERC-20 that was
/// minted and graduated on a venue this protocol never calls; this script records it as the
/// factory's immutable edge currency and adopts it. Everything the stack moves - bonds, fees,
/// sleeves, bounties, claims - is denominated in that token, and nothing in the stack touches
/// native ETH.
///
/// @dev The deployment order is forced by the hook: its address is CREATE2-mined against the
/// FACTORY predicted address (the factory is the CREATE2 deployer) and its constructor args
/// include the FeeVault and the FamilyRouter, which do not exist yet. So all three addresses are
/// predicted from the deployer nonce before anything is sent, exactly as `FamilyTestBase` does.
/// THERE IS NO `DevVestingDeployer` IN THIS LADDER, so every offset below counts from the three
/// contracts actually deployed, and THE HOOK SALT IS MINED HERE, in this script, against the
/// factory address this ladder predicts - see `HookMiner.find` below:
///
/// `n` is the deployer's nonce when the script starts, `v` is 1 when the venue is LIVE at deploy
/// (initialised, in-range liquidity) and 0 otherwise, `r` is 1 when RANDOMNESS_SOURCE is unset:
///
///   nonce n       : VenueOracle  -> ONLY when v = 1: broadcast first, then bound to the factory
///                                   in the same run (curve phase: none; script/BindOracle.s.sol
///                                   deploys and binds it after graduation)
///   nonce n+v     : FamilyToken  -> the implementation every family token is a 1167 clone of
///   nonce n+v+1   : RoundManagerDeployer -> CREATEs the RoundManager, out of the factory's initcode
///   nonce n+v+2   : MockRandomnessSource / DrandSource -> ONLY when r = 1
///   nonce k+0 : FamilyFactory   (k = n + v + 2 + r) -> deploys Locker (CREATE), FamilyHook
///                                (CREATE2), RoundManager
///   nonce k+1 : FeeVault
///   nonce k+2 : BidDeployer    -> the Locker's only depositor and the vault's only keeper hook
///   nonce k+3 : FamilyRouter
///   nonce k+4 : FamilyLens
///   nonce k+5 : V4UnlockGuardProbe (throwaway)
contract Deploy is Script {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------
    // deploy constants (docs/DEPLOY_CONSTANTS.md)
    // ---------------------------------------------------------------------------------------

    /// @dev Per-hop parent-side fee: DEPLOY_CONSTANTS says 7.5 bps, which is exactly 750 ppm now
    /// that the hook charges in parts-per-million. Sourced from `DeployConstantsLib`, the single
    /// place this value (and the ones below) is written, so `test/DeployConstants.t.sol` binds to
    /// the same constant this script sends on chain rather than a transcribed copy of it.
    uint256 internal constant HOP_FEE_PPM = DeployConstantsLib.HOP_FEE_PPM;
    /// @dev Fee split: dev 20% (hardcoded `FeeVault.DEV_BPS`), creator 40%, and the 40% remainder
    /// split 50/50 between the ancestor sleeve (20% of the whole) and reinforcement (20%).
    uint256 internal constant CREATOR_BPS = DeployConstantsLib.CREATOR_BPS;
    uint256 internal constant ANCESTOR_BPS = DeployConstantsLib.ANCESTOR_BPS;
    uint256 internal constant REINFORCE_BPS = DeployConstantsLib.REINFORCE_BPS;
    /// @dev Threshold: disabled in this deployment (both the base and the floor are zero).
    uint256 internal constant H_FRAC_WAD = DeployConstantsLib.H_FRAC_WAD;
    uint256 internal constant H_MIN_FRAC_WAD = DeployConstantsLib.H_MIN_FRAC_WAD;

    uint256 internal constant SUPPLY = 1e9 * 1e18;
    /// @dev Candidate bond (the contract supports a schedule: `base`, doubling every
    /// `BOND_DOUBLING_EVERY` links, capped at `max`). The bond is FLAT
    /// on mainnet, spam resistance only, so `BOND_MAX == BOND_BASE` here - `bondFor` clamps every
    /// depth to `BOND_MAX` (it detects the shift overflow and saturates instead of wrapping, so
    /// this is safe at any index up to the sleeve cap regardless of `BOND_DOUBLING_EVERY`).
    ///
    /// @dev THE UNIT IS $DOLL, NOT WEI. `BOND_BASE` is an amount of the adopted edge
    /// currency, in its own 18 decimals, and MUST be calibrated at deploy time from the graduated
    /// launch price: the figure below is a placeholder of the right order for a beta run and is
    /// meaningless until that price is known. Overridable per deployment through `BOND_BASE` /
    /// `BOND_DOUBLING_EVERY` / `BOND_MAX`.
    uint256 internal constant BOND_BASE = DeployConstantsLib.BOND_BASE;
    uint256 internal constant BOND_DOUBLING_EVERY = DeployConstantsLib.BOND_DOUBLING_EVERY;
    uint256 internal constant BOND_MAX = DeployConstantsLib.BOND_MAX;
    /// @dev Sunset delay: the public warning between `announceSunset(successor)` and
    /// the first refused round. Mainnet: 7 days. A testnet run overrides it through
    /// `SUNSET_DELAY_S` (1 hour is the contract floor) so the handover can be exercised live.
    uint64 internal constant SUNSET_DELAY_S = DeployConstantsLib.SUNSET_DELAY_S;
    /// @dev Keeper bounty floor: the 1% proportional bounty is far below the gas of a
    /// deployment at beta scale, so every deployment pays at least this much out of the same
    /// generation's entitlement (capped at 20% of what the call consumes).
    ///
    /// @dev IN $DOLL, NOT WEI. F-06 CALIBRATION (2026-09-26), so this is not a guess: gas price
    /// observed live via `eth_gasPrice` on `https://rpc.mainnet.chain.robinhood.com` was
    /// 22,634,000 wei/gas (`eth_maxPriorityFeePerGas` answered 0, so that is also the effective
    /// price). Gas per placement: `docs/spec/PROTOCOL_SPEC.md` measures a whole live
    /// `deployAncestor(1)` at ~589k gas, but `j = 1` is exactly the generation the floor does NOT
    /// bind for (no keeper capital, no TWAP walk); deeper generations carry the O(j) consult-chain
    /// walk on top (measured ~140k at j=1's chain, ~2.20M at j=32), so ~1,000,000 gas is used as
    /// the representative deeper-generation placement. Gas cost: 22,634,000 * 1,000,000 wei =
    /// 2.2634e13 wei = 0.000022634 ETH. Launch price: the Pons curve's first parcel (phantom
    /// reserve 1.68 ETH, supply 1e9, constant product) sells 30,000,000 tokens for 0.0531 ETH, so
    /// the post-buy real reserve is 1.68 + 0.0531 = 1.7331 ETH against a token reserve of
    /// 970,000,000, giving a marginal price of 1.7331 / 970,000,000 = 1.7867e-9 ETH/$DOLL. Gas
    /// cost in $DOLL: 0.000022634 / 1.7867e-9 ≈ 12,668 $DOLL, rounded up to a clean 13,000 and
    /// then HALVED per the design call (the floor should sit at about half a placement's gas at
    /// launch prices and fall further below gas as $DOLL appreciates): MIN_BOUNTY_DOLL = 6,500e18.
    /// Re-calibrate this at the actual launch price; it is not a substitute for that. Override
    /// with the `MIN_BOUNTY_DOLL` env var.
    uint256 internal constant MIN_BOUNTY_DOLL = DeployConstantsLib.MIN_BOUNTY_DOLL;
    /// @dev The one chain a missing venue key is refused on (see ALLOW_NO_VENUE_ORACLE).
    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    /// @dev Base URL every launched family token's on-chain metadata document
    /// (`FamilyToken.tokenURI` / `metadataURI`, the getters trading terminals like GMGN and DEX
    /// Screener read) is served from: the full document a terminal fetches is this string plus
    /// the token's own lowercase hex address, with no separator (so it must end in `/`).
    /// Overridable per deployment through the `METADATA_BASE` env var; the default is this
    /// prefix plus the chain actually being deployed to (`block.chainid`) and a trailing `/`.
    string internal constant METADATA_BASE_PREFIX = "https://dollhouse-meta-api.dollhousemarkets.workers.dev/token/";
    /// @dev sec.3. END_TIMEOUT_S: how long a round waits for the drand relay before
    /// ending deterministically at `T`. DURATION_SCALE_DIV: 1 on mainnet; a testnet run sets 60
    /// (through the environment) so a 12-hour round is exercised in 12 minutes. RANDOMNESS_DELAY_S
    /// is only used when this script has to deploy the labelled mock source.
    uint64 internal constant END_TIMEOUT_S = DeployConstantsLib.END_TIMEOUT_S;
    uint64 internal constant DURATION_SCALE_DIV = DeployConstantsLib.DURATION_SCALE_DIV;
    /// @dev drand `evmnet` (`bls-bn254-unchained-on-g1`, BN254, 3 s period), from
    /// `https://api.drand.sh/v2/beacons/evmnet/info`, re-verified live. The four words
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

    /// @dev The deploy-target standard curve: shares 20/25/35/20% over FDV ratios
    /// 1e-3 -> 1e-2 -> 1e-1 -> 1 -> 100 of the parent supply (the last band is the tail).
    function standardCurveSpec() public pure returns (CurveSegment[] memory spec) {
        spec = new CurveSegment[](4);
        spec[0] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e15, fdvRatioUpperWad: 1e16});
        spec[1] = CurveSegment({shareWad: 0.25e18, fdvRatioLowerWad: 1e16, fdvRatioUpperWad: 1e17});
        spec[2] = CurveSegment({shareWad: 0.35e18, fdvRatioLowerWad: 1e17, fdvRatioUpperWad: 1e18});
        spec[3] = CurveSegment({shareWad: 0.2e18, fdvRatioLowerWad: 1e18, fdvRatioUpperWad: 100e18});
    }

    /// @dev Recorded in the deployment artefact so an operator script can submit them: the
    /// RoundManager is CREATEd by the helper (EIP-3860) and the randomness source is either a
    /// `DrandSource` this script deployed or an address passed in through the environment.
    address internal roundManagerDeployerAddr;
    address internal randomnessSourceAddr;
    /// @dev The EXTERNAL reference the entrance runs through: the pool the edge currency
    /// graduated into on its launch venue. This stack NEVER calls it - it is recorded so an
    /// operator and the site can deep-link to it - and it may legitimately be empty on a testnet
    /// run, where the stand-in $DOLL has no venue behind it.
    address internal entrancePoolAddr;
    /// @dev The venue pool's v4 id, and the StateView it is read through.
    bytes32 internal entrancePoolIdValue;
    address internal stateViewAddr;
    /// @dev The result of the REN-01 guard self-check, recorded in the artefact.
    bool internal renGuardBound;
    /// @dev The VenueOracle the factory's start rule reads, or address(0) in the curve phase
    /// (no venue pool yet): the factory then opens every round on START_FALLBACK_DOLL, flagged,
    /// until script/BindOracle.s.sol deploys the oracle and binds it.
    address internal venueOracleAddr;
    /// @dev The venue the factory may be bound to (FamilyFactory.EXPECTED_VENUE_ID) and the
    /// runtime code hash of the one VenueOracle it accepts (EXPECTED_ORACLE_CODEHASH). Both zero
    /// when the deployment has no venue key (HOOKS unset): the ETH rule can then never run.
    bytes32 internal expectedVenueIdValue;
    bytes32 internal oracleCodehashValue;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address deployer = msg.sender;
        require(poolManager.code.length > 0, "PoolManager has no code");

        // GENESIS_TOKEN: the externally launched, already graduated ERC-20 this deployment adopts
        // as canonical index 0 and prices the whole chain in. REQUIRED, and immutable everywhere
        // downstream: the factory holds it, the FeeVault reads it as its edge currency, and there
        // is no setter anywhere. It must be an 18-decimal token with a non-zero supply, which
        // `FamilyFactory.wire` checks on chain below.
        address genesisToken = vm.envAddress("GENESIS_TOKEN");
        require(genesisToken.code.length > 0, "GENESIS_TOKEN has no code");
        console2.log("genesisToken", genesisToken);
        // ENTRANCE_POOL: an EXTERNAL REFERENCE ONLY - the venue pool the edge currency trades in,
        // as an ADDRESS reference for operators. Nothing in the stack reads or calls it.
        entrancePoolAddr = vm.envOr("ENTRANCE_POOL", address(0));
        // ENTRANCE_POOL_ID / STATE_VIEW: the two things a reader actually needs to price $DOLL in
        // ETH off that venue. A v4 pool is not an address: it is an id, read through
        // a periphery StateView on the same PoolManager. The site calls `getSlot0(id)` on
        // STATE_VIEW; without BOTH it prints no ETH or USD figure at all, which is the intended
        // behaviour on a chain with no venue behind the edge currency. Optional, both of them.
        entrancePoolIdValue = vm.envOr("ENTRANCE_POOL_ID", bytes32(0));
        // ...or the id an earlier run already recorded for this chain
        if (entrancePoolIdValue == bytes32(0)) entrancePoolIdValue = _recordedVenueId(genesisToken);
        stateViewAddr = vm.envOr("STATE_VIEW", address(0));
        // SAY SO. Missing either of them is a legitimate deployment and a silent one:
        // the record is written with zeros, the web build reads them, and the site prints no ETH
        // or USD figure anywhere with nothing in the log to explain why.
        if (entrancePoolIdValue == bytes32(0) || stateViewAddr == address(0)) {
            console2.log("venue pricing off: ENTRANCE_POOL_ID or STATE_VIEW not set");
        }

        // DEVELOPER: the immutable recipient of the developer share. There is no setter and no
        // transfer, ever, so it must be a DELIBERATE address: a cold wallet or a
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
        require(
            steward != deployer || vm.envOr("ALLOW_STEWARD_EQ_DEPLOYER", uint256(0)) == 1,
            "STEWARD equals the deployer key: set ALLOW_STEWARD_EQ_DEPLOYER=1 to allow it"
        );
        // CONTINUE_FROM: the RoundManager of the version this deployment continues the trunk
        // from. Unset (address(0)) = a fresh trunk, which is the only mode that has a genesis.
        address continueFrom = vm.envOr("CONTINUE_FROM", address(0));
        require(continueFrom == address(0) || continueFrom.code.length > 0, "CONTINUE_FROM has no code");
        // MAX_INDEX: deploy-time depth cap for a capped beta. 0 means the Fenwick sleeve's own
        // cap (4095), which is the deepest chain the ancestor payout can address; anything above
        // it is refused by the RoundManager constructor. Testnet: 0.
        uint256 maxIndex = vm.envOr("MAX_INDEX", uint256(0));
        // the bond is an amount of the EDGE CURRENCY, not of wei
        RoundManager.Bond memory bond = RoundManager.Bond({
            base: vm.envOr("BOND_BASE", BOND_BASE),
            doublingEvery: vm.envOr("BOND_DOUBLING_EVERY", BOND_DOUBLING_EVERY),
            max: vm.envOr("BOND_MAX", BOND_MAX)
        });
        uint64 sunsetDelay = uint64(vm.envOr("SUNSET_DELAY_S", uint256(SUNSET_DELAY_S)));
        // RANDOM END (sec.3). END_TIMEOUT bounds how long a round waits for the
        // beacon before ending deterministically at `T`. DURATION_SCALE_DIV divides EVERY value
        // of the adaptive schedule so a testnet run can exercise a 12-hour round in 12 minutes;
        // it must be 1 on mainnet, which is asserted below. The RoundManager constructor refuses
        // any divisor that would collapse the scored window onto one coarse slot:
        // `W = CLOSING_WINDOW_S / DURATION_SCALE_DIV` must stay strictly wider than
        // `scoreSlotFor(n)`, which caps the divisor at 150 rather than at the 3-minute
        // registration floor. 5 and 60, the two testnet values used so far, both pass.
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
        string memory metadataBase = vm.envOr(
            "METADATA_BASE", string.concat(METADATA_BASE_PREFIX, vm.toString(block.chainid), "/")
        );
        console2.log("metadataBase", metadataBase);
        console2.log("endTimeoutS", endTimeout);
        console2.log("durationScaleDiv", durationScaleDiv);
        console2.log("steward", steward);
        console2.log("sunsetDelayS", sunsetDelay);
        console2.log("continueFrom", continueFrom);
        console2.log("maxIndex", maxIndex);

        // ---- address predictions (all CREATEs below come from `deployer`, in this order) ----
        // FamilyToken and RoundManagerDeployer are broadcast BEFORE the factory (their code is
        // kept out of its init code for EIP-3860), and so is the randomness source when one is
        // being deployed.
        // THE VENUE ORACLE. The factory is BOUND to it once, by anyone, through
        // `bindVenueOracle`, and accepts only the oracle fixed here: the venue id
        // (EXPECTED_VENUE_ID, from the same key DeployZap uses) and the oracle's runtime code
        // hash (EXPECTED_ORACLE_CODEHASH: VenueOracle with this PoolManager, that venue and the
        // two pokers). The key is known before the venue exists, so a curve-phase deploy still
        // fixes both. Venue live now: the oracle is broadcast FIRST and bound in this run.
        (bool hasKey, bool venueLive, PoolKey memory venueKey) = _venueKey(poolManager, genesisToken);
        address pokerA;
        address pokerB;
        if (hasKey) {
            pokerA = vm.envAddress("KEEPER_ADDRESS");
            pokerB = vm.envAddress("POKER_BACKUP_ADDRESS");
            require(pokerA != address(0) && pokerB != address(0), "KEEPER_ADDRESS and POKER_BACKUP_ADDRESS must be set");
            expectedVenueIdValue = PoolId.unwrap(venueKey.toId());
            console2.log("expectedVenueId");
            console2.logBytes32(expectedVenueIdValue);
            // curve phase: the oracle cannot be deployed yet (its constructor needs a live venue),
            // so its code hash is taken from a local, never-broadcast deployment against a
            // mocked venue; the seed price lives in storage, so the code is identical
            if (!venueLive) oracleCodehashValue = _oracleCodehash(poolManager, venueKey, pokerA, pokerB);
        } else {
            require(
                block.chainid != MAINNET_CHAIN_ID || vm.envOr("ALLOW_NO_VENUE_ORACLE", uint256(0)) == 1,
                "HOOKS is not set: the ETH-anchored start could never be bound. Set ALLOW_NO_VENUE_ORACLE=1 to accept that"
            );
            console2.log("venue oracle off for good: no venue key (HOOKS unset); every start uses START_FALLBACK_DOLL");
        }
        uint256 nonce = vm.getNonce(deployer) + (randomnessSource == address(0) ? 3 : 2) + (venueLive ? 1 : 0);
        address predictedFactory = vm.computeCreateAddress(deployer, nonce);
        address predictedVault = vm.computeCreateAddress(deployer, nonce + 1);
        address predictedBidDeployer = vm.computeCreateAddress(deployer, nonce + 2);
        address predictedRouter = vm.computeCreateAddress(deployer, nonce + 3);
        address predictedLocker = vm.computeCreateAddress(predictedFactory, 1);

        // THE HOOK SALT IS RE-MINED HERE, EVERY RUN, against the factory address the CURRENT
        // nonce ladder predicts, so any salt from an earlier run - against a different nonce
        // ladder - is against a different factory address and would produce a hook whose
        // address does not encode the permission bits; the `require`s after the deployment prove
        // the mined address is the one that was actually created.
        bytes memory hookArgs =
            abi.encode(poolManager, predictedFactory, predictedLocker, predictedVault, predictedRouter, HOP_FEE_PPM);
        (address minedHook, bytes32 hookSalt) =
            HookMiner.find(predictedFactory, HOOK_FLAGS, type(FamilyHook).creationCode, hookArgs);
        console2.log("mined hook", minedHook);

        uint256 startBlock = block.number;
        vm.startBroadcast();

        if (venueLive) {
            venueOracleAddr = address(new VenueOracle(IPoolManager(poolManager), venueKey, pokerA, pokerB));
            oracleCodehashValue = venueOracleAddr.codehash;
            console2.log("venueOracle", venueOracleAddr);
        }

        // the token implementation must exist before the factory, which verifies the link back
        // it also carries the venue-lock immutables: the PoolManager, the mined hook, the Locker and
        // the FeeVault, all predictions the factory verifies against what it actually creates
        FamilyToken tokenImplementation =
            new FamilyToken(predictedFactory, poolManager, minedHook, predictedLocker, predictedVault);
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

        FamilyFactory factory = new FamilyFactory(
            IPoolManager(poolManager),
            predictedVault,
            predictedBidDeployer,
            predictedRouter,
            HOP_FEE_PPM,
            H_FRAC_WAD,
            H_MIN_FRAC_WAD,
            genesisToken,
            bond,
            maxIndex,
            steward,
            sunsetDelay,
            continueFrom,
            standardCurveSpec(),
            hookSalt,
            address(tokenImplementation),
            metadataBase,
            FamilyFactory.RoundSetup({
                deployer: address(roundManagerDeployer),
                randomness: randomnessSource,
                endTimeout: endTimeout,
                durationScaleDiv: durationScaleDiv
            }),
            _startSetup(expectedVenueIdValue, oracleCodehashValue)
        );
        FeeVault vault = new FeeVault(factory, developer, CREATOR_BPS, ANCESTOR_BPS, REINFORCE_BPS);
        BidDeployer bidDeployer = new BidDeployer(vault, vm.envOr("MIN_BOUNTY_DOLL", MIN_BOUNTY_DOLL));
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
        if (continueFrom == address(0)) {
            // ADOPT: index 0 is written into the registry, with no pool key. Adoption is part
            // of the one-time wiring step, with the creator of index 0 fixed at
            // construction as this deployer, and the factory checks the token's decimals and
            // supply here, on chain.
            factory.wire();
            token = factory.genesisToken();
            require(token == genesisToken, "genesis adoption");
            require(factory.roundManager().canonical(0) == genesisToken, "canonical 0");
        } else {
            // a continuation stack has no genesis of its own: the trunk (and its edge currency)
            // stays the original version's adopted token, resolved through the registry chain
            token = factory.genesisToken();
            require(token == genesisToken, "GENESIS_TOKEN must equal the trunk's canonical 0");
            require(factory.roundManager().headIndex() == RoundManager(continueFrom).headIndex(), "head continuity");
        }

        // THE REN-01 GUARD IS BOUND TO THIS MANAGER. `FamilyFactory.wire` has already
        // proved the guard reads `false` here (it is called by the adoption above, and by the
        // first candidate registration on a continuation stack). What it cannot prove without
        // opening an unlock is the other half - that the read answers `true` INSIDE one - and a
        // guard that never answers `true` is a guard that fails open on every `notInsideUnlock`
        // in the stack. The throwaway probe opens one and asserts it; it reverts the deployment
        // if the guard is not bound, and the answer goes into the artefact either way.
        factory.wire();
        renGuardBound = new V4UnlockGuardProbe().probe(poolManager);
        console2.log("renGuardBound", renGuardBound);

        // THE BIND, when the venue is live: the oracle was broadcast first, so it goes in now.
        // It still reads fallback (flagged) until it holds 24 h of slow history.
        if (venueLive) {
            factory.bindVenueOracle(venueOracleAddr);
            require(factory.venueOracle() == venueOracleAddr, "venue oracle bind");
        }

        vm.stopBroadcast();

        if (hasKey && !venueLive) {
            console2.log("venue oracle UNBOUND (curve phase). After graduation, deploy and bind it with:");
            console2.log("  forge script script/BindOracle.s.sol --rpc-url $RPC_URL --broadcast");
            console2.log("or, for an oracle already deployed with the same pokers and build:");
            console2.log(
                string.concat(
                    "  cast send ",
                    vm.toString(address(factory)),
                    " \"bindVenueOracle(address)\" <VENUE_ORACLE> --rpc-url $RPC_URL"
                )
            );
        }

        _write(factory, vault, bidDeployer, router, lens, token, poolManager, startBlock, continueFrom);
    }

    /// @dev The ETH-anchored start constants (DeployConstantsLib), each overridable through the env
    /// var of the same name, against the venue `venueId` and the oracle code hash `codehash` the
    /// factory may later be bound to (both zero = the permanent constant fallback).
    function _startSetup(bytes32 venueId, bytes32 codehash) internal view returns (FamilyFactory.StartSetup memory) {
        return FamilyFactory.StartSetup({
            expectedVenueId: venueId,
            oracleCodehash: codehash,
            fdvWei: vm.envOr("START_FDV_WEI", DeployConstantsLib.START_FDV_WEI),
            maxParentBps: vm.envOr("START_MAX_PARENT_BPS", DeployConstantsLib.START_MAX_PARENT_BPS),
            minParentWad: vm.envOr("START_MIN_PARENT_WAD", DeployConstantsLib.START_MIN_PARENT_WAD),
            fallbackDoll: vm.envOr("START_FALLBACK_DOLL", DeployConstantsLib.START_FALLBACK_DOLL),
            oracleGas: vm.envOr("ORACLE_GAS", DeployConstantsLib.ORACLE_GAS),
            linkMinCoverS: uint32(
                vm.envOr("START_LINK_MIN_COVER_S", uint256(DeployConstantsLib.START_LINK_MIN_COVER_S))
            ),
            walkMax: vm.envOr("START_WALK_MAX", DeployConstantsLib.START_WALK_MAX)
        });
    }

    /// @dev The `entrancePoolId` an earlier run recorded for this chain, or zero. Only a record of
    /// the SAME genesis token counts: a relaunch on a fresh token must never inherit the old
    /// token's venue.
    function _recordedVenueId(address genesisToken) internal view returns (bytes32) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        if (!vm.isFile(path)) return bytes32(0);
        string memory record = vm.readFile(path);
        if (!vm.keyExistsJson(record, ".entrancePoolId") || !vm.keyExistsJson(record, ".genesisToken")) {
            return bytes32(0);
        }
        if (vm.parseJsonAddress(record, ".genesisToken") != genesisToken) return bytes32(0);
        return vm.parseJsonBytes32(record, ".entrancePoolId");
    }

    /// @dev The venue's key, built from the same env as script/DeployZap.s.sol (POOL_FEE default
    /// 0, TICK_SPACING default 200, HOOKS): native ETH / the genesis token. `hasKey` when HOOKS is
    /// set (required when ENTRANCE_POOL_ID is); `live` when the pool is initialised with in-range
    /// liquidity (the oracle's constructor checks the same). A named venue id must match the key
    /// and be live; with no id named, a not-yet-graduated venue is the curve phase.
    function _venueKey(address poolManager, address genesisToken)
        internal
        view
        returns (bool hasKey, bool live, PoolKey memory key)
    {
        address hooks = vm.envOr("HOOKS", address(0));
        if (entrancePoolIdValue == bytes32(0) && hooks == address(0)) return (false, false, key);
        require(hooks != address(0), "HOOKS must be set with ENTRANCE_POOL_ID");
        uint256 feeRaw = vm.envOr("POOL_FEE", uint256(0));
        uint256 spacingRaw = vm.envOr("TICK_SPACING", uint256(200));
        require(feeRaw <= type(uint24).max, "POOL_FEE out of range");
        require(spacingRaw != 0 && spacingRaw <= 32_767, "TICK_SPACING out of range");
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(genesisToken),
            // casting is safe: both values are range-checked just above
            // forge-lint: disable-next-line(unsafe-typecast)
            fee: uint24(feeRaw),
            // forge-lint: disable-next-line(unsafe-typecast)
            tickSpacing: int24(int256(spacingRaw)),
            hooks: IHooks(hooks)
        });
        PoolId id = key.toId();
        (uint160 spot,,,) = IPoolManager(poolManager).getSlot0(id);
        live = spot != 0 && IPoolManager(poolManager).getLiquidity(id) > 0;
        if (entrancePoolIdValue != bytes32(0)) {
            require(PoolId.unwrap(id) == entrancePoolIdValue, "venue key does not hash to ENTRANCE_POOL_ID");
            require(spot != 0, "venue pool is not initialized: unset ENTRANCE_POOL_ID for a curve-phase deploy");
            require(live, "venue pool has no in-range liquidity");
        }
        return (true, live, key);
    }

    /// @dev The runtime code hash of `new VenueOracle(poolManager, key, pokerA, pokerB)` while
    /// the venue does not exist yet: deployed LOCALLY (outside the broadcast, so nothing is sent)
    /// against a PoolManager whose slot0 and liquidity reads for this pool are mocked. The
    /// runtime code holds only the immutables (manager, venue id, pokers); the mocked seed price
    /// goes to storage, so the hash is the one the real deployment will have on the same build.
    function _oracleCodehash(address poolManager, PoolKey memory key, address pokerA, address pokerB)
        internal
        returns (bytes32 codehash)
    {
        bytes32 stateSlot = StateLibrary._getPoolStateSlot(key.toId());
        bytes32 liquiditySlot = bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET);
        vm.mockCall(
            poolManager, abi.encodeWithSignature("extsload(bytes32)", stateSlot), abi.encode(uint256(1) << 96)
        );
        vm.mockCall(poolManager, abi.encodeWithSignature("extsload(bytes32)", liquiditySlot), abi.encode(uint256(1)));
        codehash = address(new VenueOracle(IPoolManager(poolManager), key, pokerA, pokerB)).codehash;
        vm.clearMockedCalls();
    }

    function _write(
        FamilyFactory factory,
        FeeVault vault,
        BidDeployer bidDeployer,
        FamilyRouter router,
        FamilyLens lens,
        address token,
        address poolManager,
        uint256 startBlock,
        address continueFrom
    ) internal {
        RoundManager roundManager = factory.roundManager();
        string memory o = "deployment";

        // F-25: READ-MODIFY-WRITE, the same way DeployZap.s.sol and DeployVesting.s.sol already
        // do. A re-run of this script used to overwrite the whole record with a fresh object,
        // clobbering `ethZap` / `venuePoolId` (DeployZap) and `devVesting` (DeployVesting) if
        // either had already run. Loading the existing record's keys into `o` FIRST means every
        // key below - all of them keys this script itself owns - overwrites its own prior value,
        // while any key this script never writes (the two above, and anything else appended
        // later) survives untouched.
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        if (vm.isFile(path)) {
            vm.serializeJson(o, vm.readFile(path));
        }

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
        // The ADOPTED external token, and the venue pool it trades in. The second is an
        // EXTERNAL REFERENCE only - nothing in the stack reads it - and may be empty on testnet.
        vm.serializeAddress(o, "genesisToken", token);
        vm.serializeAddress(o, "entrancePool", entrancePoolAddr);
        // `entrancePool` is the venue pool's own ADDRESS reference and nothing calls
        // it. What a reader needs is the pool ID plus the periphery StateView that answers for
        // it; the web build reads the address out of `stateView` and the id out of
        // `entrancePoolId`, and leaves every ETH and USD figure out when either is missing.
        vm.serializeBytes32(o, "entrancePoolId", entrancePoolIdValue);
        vm.serializeAddress(o, "stateView", stateViewAddr);
        // the start rule's venue oracle: zero until bound (curve phase), when script/BindOracle.s.sol
        // writes it; and the venue and oracle code the factory will accept, fixed here
        vm.serializeAddress(o, "venueOracle", factory.venueOracle());
        vm.serializeBytes32(o, "expectedVenueId", factory.EXPECTED_VENUE_ID());
        vm.serializeBytes32(o, "expectedOracleCodehash", factory.EXPECTED_ORACLE_CODEHASH());
        vm.serializeAddress(o, "developer", vault.developer());
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
        // bonds are denominated in the EDGE CURRENCY now, in its own 18 decimals
        vm.serializeUint(c, "bondBaseDoll", roundManager.BOND_BASE());
        vm.serializeUint(c, "bondDoublingEvery", roundManager.BOND_DOUBLING_EVERY());
        vm.serializeUint(c, "bondMaxDoll", roundManager.BOND_MAX());
        vm.serializeUint(c, "maxIndex", roundManager.MAX_INDEX());
        // the schedule is adaptive now (sec.2): what is constant is its SHAPE, so the
        // artefact records the shape constants plus the first rounds the schedule produces
        vm.serializeUint(c, "baseRoundS", roundManager.BASE_ROUND_S());
        vm.serializeUint(c, "maxRoundS", roundManager.MAX_ROUND_S());
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
        vm.serializeUint(c, "minBountyDoll", bidDeployer.MIN_BOUNTY_DOLL());
        vm.serializeUint(c, "snipeS", factory.hook().SNIPE_S());
        vm.serializeUint(c, "tickSpacing", uint256(int256(factory.TICK_SPACING())));
        vm.serializeUint(c, "startFdvWei", factory.START_FDV_WEI());
        vm.serializeUint(c, "startMaxParentBps", factory.START_MAX_PARENT_BPS());
        vm.serializeUint(c, "startMinParentWad", factory.START_MIN_PARENT_WAD());
        vm.serializeUint(c, "startFallbackDoll", factory.START_FALLBACK_DOLL());
        vm.serializeUint(c, "oracleGas", factory.ORACLE_GAS());
        vm.serializeUint(c, "startLinkMinCoverS", factory.START_LINK_MIN_COVER_S());
        vm.serializeUint(c, "startWalkMax", factory.START_WALK_MAX());
        string memory constantsJson = vm.serializeUint(c, "supply", SUPPLY);

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

        vm.writeJson(out, path);
        console2.log("wrote", path);
    }
}
