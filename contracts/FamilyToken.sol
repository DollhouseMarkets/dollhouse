// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";
import {IFamilyFactory} from "./interfaces/IFamilyFactory.sol";

/// @dev The getters the successor-hook resolution reads, across versions (RoundManager and
/// FamilyFactory ABIs). Only the selectors are used: every call is a raw, gas-capped staticcall.
interface ISuccessorResolution {
    function roundManager() external view returns (address);
    function isSunsetEffective() external view returns (bool);
    function successor() external view returns (address);
    function priorRegistry() external view returns (address);
    function factory() external view returns (address);
    function poolManager() external view returns (address);
    function hook() external view returns (address);
    function locker() external view returns (address);
    function feeVault() external view returns (address);
}

/// @dev The two getters a v2/v3-shaped pool answers.
interface IPairShape {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// The fixed supply of every family token: 1e9 tokens with 18 decimals. Declared at file level
// so other contracts can read it without an instance (a contract-level `constant` cannot be
// reached through the type).
uint256 constant FAMILY_TOTAL_SUPPLY = 1e9 * 1e18;

/// @title FamilyToken
/// @notice Fixed-supply family link token. The entire supply is minted once, at initialization,
/// to the Locker, which places it as permanently locked liquidity. There is no owner, no
/// minter, and no function other than ERC20 plus holder-initiated `burn`.
///
/// @dev Deployed as an EIP-1167 minimal proxy (`Clones.clone`) of a single implementation
/// deployed just BEFORE the FamilyFactory, with the factory's predicted address. `factory` is an
/// immutable, so it lives in the implementation's code and every clone delegatecalls to the
/// same, correct value; `initialize` is therefore callable by the factory only, exactly once per
/// clone. The implementation itself is permanently sealed because its constructor sets
/// `_initialized`, which clones do not inherit (a clone starts with empty storage). The factory
/// checks the link back (`implementation.factory() == address(this)`) in its own constructor, so
/// a mismatched pair cannot be wired up.
///
/// @dev THE VENUE LOCK (private/V2_SIDE_TAX_DESIGN.md, see its superseding note). This token
/// trades only in its canonical Dollhouse pool: a transfer that would move it through any other
/// pool is refused ({NonCanonicalVenue}). Nothing is ever charged on the token itself. The
/// implementation also carries the PoolManager, the hook, the Locker and the FeeVault as
/// immutables (predicted addresses, verified by the factory), so every clone reads them from the
/// shared code. The rule, in {_update}:
///   - mint, burn, zero-value and every transfer to or from the Locker or the FeeVault: allowed;
///   - a transfer INTO the PoolManager is allowed when the canonical INBOUND allowance (what the
///     canonical hook recorded that swappers owe the PoolManager in this token during this
///     transaction) covers ALL of it, and spends it; a transfer OUT of the PoolManager likewise
///     against the OUTBOUND allowance (what the PoolManager owes swappers). A transfer the
///     allowance in its direction covers only in part is refused whole (reason 1 inbound, 2
///     outbound);
///   - any other transfer is refused (reason 3) only when one side is a pool of this token, i.e.
///     a contract answering `token0()` or `token1()` with this token's address (v2/v3 shapes);
///   - a transfer refused above is still allowed to or from a resolved successor's Locker or
///     FeeVault (without spending allowance);
///   - everything else (wallet to wallet, smart wallets, routers, the zap) is allowed.
/// The allowance is two transient counters, one per direction ({IN_SLOT}, {OUT_SLOT}): a
/// negative canonical delta adds to the inbound allowance, a positive one to the outbound, and
/// each transfer spends only its own direction. The two never offset, so a leftover of an
/// earlier step in the same transaction (a claims mint or burn, a `clear`, a delta netted
/// against another pool, another user's operation in the same bundle) cannot make a later
/// canonical settlement in the other direction revert. The price is that both allowances stay
/// open for the rest of the transaction where a single counter would have netted them: the
/// extra room this opens for transfers of other pools' trades within one transaction never
/// exceeds canonical volume that already paid the fee in that transaction. Only the canonical
/// hook, or the hook of a successor version resolved through the registry chain
/// ({isCanonicalHook}), may add to it; that successor's Locker and FeeVault are exempt
/// endpoints exactly like this version's own.
///
/// @dev THE SUCCESSOR CACHE IS A STEWARD-TRUST PATH. Once this version's sunset has taken effect,
/// the registry the steward named as `successor` in the one-shot sunset notice decides, through
/// its factory, which hook may credit this token and which Locker and FeeVault are exempt. The
/// checks in {_resolveSuccessor} (the `priorRegistry` backlink, the shared PoolManager, a bounded
/// walk) pin the SHAPE of the handover, not the successor's code: a steward who names a hostile
/// successor can, once the notice period has run, give that successor's hook the power to
/// record canonical allowance, i.e. to let chosen PoolManager transfers through the venue lock,
/// and make any address it lists as Locker or FeeVault an exempt endpoint. The exposure is the
/// venue lock alone (nothing here can move a balance), it is public for the whole notice period
/// before it can take effect, and every grant is logged ({SuccessorTrusted},
/// {CanonicalHookAccepted}).
contract FamilyToken is ERC20, IBurnableERC20 {
    /// @notice The fixed supply of every family token: 1e9 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = FAMILY_TOTAL_SUPPLY;

    /// @notice The FamilyFactory that clones this implementation. Immutable, so it is read out
    /// of the implementation's code by every clone.
    address public immutable factory;
    /// @notice The v4 PoolManager every canonical pool of this token lives in.
    address public immutable POOL_MANAGER;
    /// @notice The canonical hook: the only contract (with a resolved successor version's hook)
    /// that may record a canonical settlement allowance.
    address public immutable HOOK;
    /// @notice The Locker and the FeeVault: both exempt as endpoints, in either direction.
    address public immutable LOCKER;
    address public immutable FEE_VAULT;

    /// @notice Gas given to each `token0()` / `token1()` probe of a transfer counterparty.
    uint256 public constant PROBE_GAS = 10_000;
    /// @notice Gas given to each leg of the successor-hook resolution.
    uint256 public constant RESOLVE_GAS = 30_000;
    /// @notice Most successor versions the resolution walks (RoundManager.MAX_CONTINUATION_HOPS).
    uint256 public constant MAX_SUCCESSOR_HOPS = 8;
    /// @dev What a probe costs on top of {PROBE_GAS} (a cold account access and the call frame),
    /// so the callee always receives its full budget under the 63/64 rule.
    uint256 internal constant PROBE_OVERHEAD = 3_000;
    /// @dev Transient slots of the canonical settlement allowance (uint256 each): {IN_SLOT} for
    /// transfers INTO the PoolManager, {OUT_SLOT} for transfers OUT of it. A clone runs this code
    /// by delegatecall, so the slots live in each clone's own transient storage.
    bytes32 internal constant IN_SLOT = keccak256("family.token.canonicalIn");
    bytes32 internal constant OUT_SLOT = keccak256("family.token.canonicalOut");

    /// @dev name/symbol live in this contract's storage rather than the ERC20 base's because a
    /// clone has no constructor: the base's strings can only be written by `ERC20`'s
    /// constructor, which runs on the implementation. {name} and {symbol} are overridden to
    /// read these instead, so ERC20 semantics are unchanged.
    string private _tokenName;
    string private _tokenSymbol;

    /// @notice Off-chain metadata pointer, immutable after initialization.
    string public uri;

    /// @dev True once this instance has been initialized. Set in the constructor so that the
    /// implementation can never be initialized, and by {initialize} on each clone.
    bool private _initialized;
    /// @notice What a SUCCESSOR version's contract is to this token, once resolved through the
    /// registry chain: {ROLE_HOOK} (may record canonical allowance) or {ROLE_ENDPOINT} (its
    /// Locker or FeeVault: exempt, like {LOCKER} and {FEE_VAULT}). Write-once cache: a sunset
    /// that has taken effect can never be cancelled, so a resolved answer is final.
    mapping(address => uint8) public successorRole;
    uint8 internal constant ROLE_HOOK = 1;
    uint8 internal constant ROLE_ENDPOINT = 2;

    /// @notice A successor version's stack was resolved: its hook may credit this token, and its
    /// Locker and FeeVault are exempt endpoints, from now on.
    event SuccessorTrusted(address indexed hook, address locker, address feeVault);
    /// @notice `hook` asked to credit this token at pool registration ({acceptCanonicalHook})
    /// and was accepted. `locker` and `feeVault` are that stack's exempt endpoints when known in
    /// this call: this version's own for {HOOK}, the resolved ones for a successor resolved by
    /// this call; zero for a successor resolved earlier (its endpoints are in {SuccessorTrusted}).
    event CanonicalHookAccepted(address indexed hook, address locker, address feeVault);

    /// @notice Only the FamilyFactory may initialize a clone.
    error NotFactory();
    /// @notice This instance has already been initialized (or is the sealed implementation).
    error AlreadyInitialized();
    /// @notice A transfer of `from` to `to` would trade this token outside its canonical pool,
    /// for `reason`: 1, INTO the PoolManager beyond the canonical inbound allowance; 2, OUT of
    /// it beyond the outbound allowance; 3, to or from a contract that answered the pool probe
    /// (`token0()` / `token1()`). `available` is the allowance left in that direction (zero for
    /// reason 3).
    error NonCanonicalVenue(address from, address to, uint8 reason, uint256 available);
    /// @notice {creditCanonical} was called by neither the canonical hook nor a successor's.
    error NotHook();
    /// @notice Too little gas is left to give a counterparty probe its full {PROBE_GAS}: the
    /// transfer reverts rather than let a starved probe pass a pool off as a wallet.
    error ProbeGasShort();

    /// @dev Deploys the implementation for `factory_` and the rest of the stack (all predicted
    /// addresses; the factory verifies every one). Sealed immediately; holds no supply.
    constructor(address factory_, address poolManager_, address hook_, address locker_, address feeVault_)
        ERC20("", "")
    {
        factory = factory_;
        POOL_MANAGER = poolManager_;
        HOOK = hook_;
        LOCKER = locker_;
        FEE_VAULT = feeVault_;
        _initialized = true;
    }

    /// @notice One-time initialization of a clone: sets the metadata and mints the whole fixed
    /// supply to `locker`. Callable only by the factory, and only once.
    /// @dev There is no developer allocation and no vesting contract any more. Every
    /// family token, without exception, is 100% locked liquidity: the whole of
    /// {TOTAL_SUPPLY} goes to the Locker and nothing is ever minted anywhere else.
    function initialize(string calldata name_, string calldata symbol_, string calldata uri_, address locker)
        external
    {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        uri = uri_;
        _mint(locker, TOTAL_SUPPLY);
    }

    // -------------------------------------------------------------------------------------
    // the venue lock
    // -------------------------------------------------------------------------------------

    /// @notice Record `delta` of canonical swapper delta in this token (the v4 sign: negative is
    /// owed to the PoolManager, positive is owed by it) for the rest of this transaction: a
    /// negative delta adds its size to the inbound allowance, a positive one to the outbound.
    /// Callable by the canonical hook and by a successor version's hook only.
    function creditCanonical(int256 delta) external {
        if (msg.sender != HOOK && successorRole[msg.sender] != ROLE_HOOK && !_trustSuccessor(msg.sender)) {
            revert NotHook();
        }
        bytes32 slot = delta < 0 ? IN_SLOT : OUT_SLOT;
        uint256 allowance;
        assembly ("memory-safe") {
            allowance := tload(slot)
        }
        allowance += delta < 0 ? uint256(-delta) : uint256(delta);
        assembly ("memory-safe") {
            tstore(slot, allowance)
        }
    }

    /// @notice Called by a hook registering a pool of this token: true when the caller may
    /// credit it ({creditCanonical}). A successor version's hook is resolved and cached HERE,
    /// together with that version's Locker and FeeVault, so the whole successor stack is
    /// recognised before its first pool of this token can hold a position or trade.
    function acceptCanonicalHook() external returns (bool) {
        if (msg.sender == HOOK) {
            emit CanonicalHookAccepted(msg.sender, LOCKER, FEE_VAULT);
            return true;
        }
        if (successorRole[msg.sender] == ROLE_HOOK) {
            emit CanonicalHookAccepted(msg.sender, address(0), address(0));
            return true;
        }
        (bool found, address locker_, address vault_) = _resolveSuccessor(msg.sender);
        if (!found) return false;
        _cacheSuccessor(msg.sender, locker_, vault_);
        emit CanonicalHookAccepted(msg.sender, locker_, vault_);
        return true;
    }

    /// @notice The canonical settlement allowance left in this transaction, per direction: what
    /// may still move INTO the PoolManager ({IN_SLOT}) and OUT of it ({OUT_SLOT}).
    function canonicalAllowance() external view returns (uint256 inAllowance, uint256 outAllowance) {
        bytes32 inSlot = IN_SLOT;
        bytes32 outSlot = OUT_SLOT;
        assembly ("memory-safe") {
            inAllowance := tload(inSlot)
            outAllowance := tload(outSlot)
        }
    }

    /// @notice True when `h` may record canonical allowance: the canonical hook, or the hook of
    /// a successor version this version's registry chain has handed over to.
    function isCanonicalHook(address h) external view returns (bool) {
        if (h == HOOK || successorRole[h] == ROLE_HOOK) return true;
        (bool found,,) = _resolveSuccessor(h);
        return found;
    }

    /// @dev Resolve `h` as a successor version's hook and, if it is one, cache that stack.
    function _trustSuccessor(address h) internal returns (bool) {
        (bool found, address locker_, address vault_) = _resolveSuccessor(h);
        if (!found) return false;
        _cacheSuccessor(h, locker_, vault_);
        return true;
    }

    /// @dev Write a resolved successor stack into {successorRole}.
    function _cacheSuccessor(address h, address locker_, address vault_) internal {
        successorRole[h] = ROLE_HOOK;
        if (locker_ != address(0)) successorRole[locker_] = ROLE_ENDPOINT;
        if (vault_ != address(0)) successorRole[vault_] = ROLE_ENDPOINT;
        emit SuccessorTrusted(h, locker_, vault_);
    }

    /// @dev THE SUCCESSOR RESOLUTION (design risk 2). A continuation stack trades this token in
    /// its own pools, behind its own hook, in the same PoolManager. Walk the sunset handover
    /// forward: this version's RoundManager (off {factory}), once sunset-effective, names a
    /// `successor` registry; that registry must name the one before it as its `priorRegistry`
    /// (the continuation link it adopts the trunk through), and its factory must share
    /// {POOL_MANAGER}. That factory's `hook()` is then canonical too, and its `locker()` and
    /// `feeVault()` are endpoints; the walk repeats from the successor, at most
    /// {MAX_SUCCESSOR_HOPS} versions deep. Every leg is a gas-capped, checked static call; any
    /// nonsense ends the walk unresolved.
    function _resolveSuccessor(address h) internal view returns (bool found, address locker_, address vault_) {
        if (h.code.length == 0) return (false, address(0), address(0));
        address rm = _staticAddress(factory, ISuccessorResolution.roundManager.selector);
        for (uint256 i = 0; i < MAX_SUCCESSOR_HOPS && rm != address(0); ++i) {
            // `isSunsetEffective()` answers a bool: a clean `true` is the word 1
            if (_staticAddress(rm, ISuccessorResolution.isSunsetEffective.selector) != address(1)) break;
            address next = _staticAddress(rm, ISuccessorResolution.successor.selector);
            if (next == address(0) || _staticAddress(next, ISuccessorResolution.priorRegistry.selector) != rm) break;
            address f = _staticAddress(next, ISuccessorResolution.factory.selector);
            if (f == address(0) || _staticAddress(f, ISuccessorResolution.poolManager.selector) != POOL_MANAGER) break;
            if (_staticAddress(f, ISuccessorResolution.hook.selector) == h) {
                return (
                    true,
                    _staticAddress(f, ISuccessorResolution.locker.selector),
                    _staticAddress(f, ISuccessorResolution.feeVault.selector)
                );
            }
            rm = next;
        }
    }

    /// @dev A {RESOLVE_GAS}-capped static call of a no-argument getter, copying exactly one word,
    /// read as an address: `address(0)` on a revert, a short answer or dirty upper bits.
    function _staticAddress(address target, bytes4 selector) internal view returns (address a) {
        uint256 g = RESOLVE_GAS;
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(g, target, 0, 4, 0, 0x20)
            let w := mload(0)
            if and(and(ok, iszero(lt(returndatasize(), 0x20))), iszero(shr(160, w))) { a := w }
        }
    }

    /// @dev The transfer rule; see the contract notes and private/V2_SIDE_TAX_DESIGN.md.
    /// A transfer that would be refused is first checked against the successor endpoints (a
    /// storage read only on that rare path); the allowance a PoolManager transfer spends is
    /// committed only when the transfer is not such an endpoint.
    function _update(address from, address to, uint256 value) internal override {
        if (
            from == address(0) || to == address(0) || value == 0 || from == LOCKER || from == FEE_VAULT
                || to == LOCKER || to == FEE_VAULT
        ) {
            super._update(from, to, value);
            return;
        }

        bool covered = true;
        uint256 available;
        uint8 reason;
        bytes32 slot;
        bool touchesManager = to == POOL_MANAGER || from == POOL_MANAGER;
        if (touchesManager) {
            // each direction spends only its own allowance, all or nothing: a transfer it covers
            // only in part is not covered at all (nothing is split)
            bool inbound = to == POOL_MANAGER;
            slot = inbound ? IN_SLOT : OUT_SLOT;
            assembly ("memory-safe") {
                available := tload(slot)
            }
            covered = value <= available;
            reason = inbound ? 1 : 2;
        } else if (_isPool(from) || _isPool(to)) {
            covered = false;
            reason = 3;
        }
        if (!covered) {
            if (successorRole[from] != ROLE_ENDPOINT && successorRole[to] != ROLE_ENDPOINT) {
                revert NonCanonicalVenue(from, to, reason, available);
            }
        } else if (touchesManager) {
            uint256 left = available - value;
            assembly ("memory-safe") {
                tstore(slot, left)
            }
        }
        super._update(from, to, value);
    }

    /// @dev `a` is a pool of this token: a contract whose `token0()` or `token1()` answers this
    /// token's address. Each probe gets exactly {PROBE_GAS} and copies exactly one word.
    function _isPool(address a) internal view returns (bool) {
        if (a.code.length == 0) return false;
        return _probe(a, IPairShape.token0.selector) || _probe(a, IPairShape.token1.selector);
    }

    /// @dev A caller that leaves too little gas for a full probe is refused ({ProbeGasShort}), so
    /// a pool can never be passed off as a wallet by starving the probe.
    function _probe(address a, bytes4 selector) internal view returns (bool hit) {
        uint256 g = PROBE_GAS;
        if (gasleft() < g + g / 63 + PROBE_OVERHEAD) revert ProbeGasShort();
        address self = address(this);
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(g, a, 0, 4, 0, 0x20)
            hit := and(ok, and(iszero(lt(returndatasize(), 0x20)), eq(mload(0), self)))
        }
    }

    /// @inheritdoc ERC20
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    /// @inheritdoc ERC20
    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @inheritdoc IBurnableERC20
    /// @notice Burn `amount` from the caller's balance. Supply is fixed downward-only.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice The on-chain metadata JSON document trading terminals that read a `tokenURI`
    /// getter (the Doppler/Long token shape) expect, under this token's own address.
    /// @dev Identical to {metadataURI}; a second name because indexers query one or the other
    /// getter depending on which convention they were written against, never both.
    function tokenURI() external view returns (string memory) {
        return metadataURI();
    }

    /// @notice The on-chain metadata JSON document trading terminals that read a `metadataURI`
    /// getter (the MILKERS shape) expect: `metadataBase + <this token's own lowercase hex
    /// address>`, e.g. `"https://.../token/4663/" + "0xabc...def"`.
    /// @dev `metadataBase` lives on {factory}, not copied into this clone's storage at
    /// {initialize}. Every family token is a freshly cloned contract, so writing the same string
    /// into a fresh storage slot on every launch would cost a fresh-slot SSTORE (~20k gas) EVERY
    /// SINGLE LAUNCH, forever, to save a `staticcall` that only an off-chain indexer ever pays for
    /// (nothing on this chain's hot path calls `tokenURI`/`metadataURI`). Reading it off the
    /// factory instead costs nothing at launch and a few hundred gas of `staticcall` at read time,
    /// which is exactly the cheaper trade for a value that is identical across every clone anyway.
    function metadataURI() public view returns (string memory) {
        return string.concat(IFamilyFactory(factory).metadataBase(), _toHexAddress(address(this)));
    }

    /// @dev Lowercase `0x`-hex encoding of an address: 42 characters, no EIP-55 checksum casing.
    /// Trading-terminal metadata endpoints match on the plain hex address, so skipping checksum
    /// casing keeps this helper - and the bytecode it costs the shared implementation - tiny.
    function _toHexAddress(address account) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes20 data = bytes20(account);
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            buffer[2 + i * 2] = hexSymbols[uint8(data[i] >> 4)];
            buffer[3 + i * 2] = hexSymbols[uint8(data[i] & 0x0f)];
        }
        return string(buffer);
    }
}
