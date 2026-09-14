// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBurnableERC20} from "./interfaces/IBurnableERC20.sol";

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
contract FamilyToken is ERC20, IBurnableERC20 {
    /// @notice The fixed supply of every family token: 1e9 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = FAMILY_TOTAL_SUPPLY;

    /// @notice The FamilyFactory that clones this implementation. Immutable, so it is read out
    /// of the implementation's code by every clone.
    address public immutable factory;

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

    /// @notice Only the FamilyFactory may initialize a clone.
    error NotFactory();
    /// @notice This instance has already been initialized (or is the sealed implementation).
    error AlreadyInitialized();

    /// @dev Deploys the implementation for `factory_` (its predicted address). The
    /// implementation is sealed immediately and holds no supply.
    constructor(address factory_) ERC20("", "") {
        factory = factory_;
        _initialized = true;
    }

    /// @notice One-time initialization of a clone: sets the metadata and mints the whole fixed
    /// supply, `devAmount` of it to `devRecipient` and all the rest to `locker`. Callable only by
    /// the factory, and only once.
    /// @dev `devAmount` is the GENESIS token's vested developer allocation and goes to an
    /// immutable `DevVesting` contract the factory deploys in the same transaction; every
    /// candidate token is initialized with `devAmount == 0`, so its entire supply is locked
    /// liquidity. The total minted is `TOTAL_SUPPLY` either way.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata uri_,
        address locker,
        address devRecipient,
        uint256 devAmount
    ) external {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _tokenName = name_;
        _tokenSymbol = symbol_;
        uri = uri_;
        if (devAmount != 0) _mint(devRecipient, devAmount);
        _mint(locker, TOTAL_SUPPLY - devAmount);
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
}
