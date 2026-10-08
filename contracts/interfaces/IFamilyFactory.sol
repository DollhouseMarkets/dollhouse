// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice The getters other contracts need off a {FamilyFactory} without importing it: the base
/// URL every family token's on-chain metadata document is served from ({FamilyToken}), and the
/// curve basis a token was launched against ({BidDeployer}). A tiny, standalone interface rather
/// than an import of `FamilyFactory` itself, which would be circular (`FamilyFactory` already
/// imports `FamilyToken`).
interface IFamilyFactory {
    /// @notice The base URL {FamilyToken.metadataURI} appends this token's own lowercase hex
    /// address to, e.g. `"https://.../token/4663/"` + `"0xabc...def"`. Set once at the factory's
    /// construction; there is no setter.
    function metadataBase() external view returns (string memory);

    /// @notice The parent-unit basis `token`'s launch curve was built against (the
    /// `parentSupply` argument of {StandardCurve.build}); zero for a token the factory never
    /// launched. Absent on factories that predate it, so callers read it inside `try`.
    function curveBasisOf(address token) external view returns (uint256);
}
