// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RoundTestBase} from "./utils/RoundTestBase.sol";
import {FamilyToken} from "../contracts/FamilyToken.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Trading terminals (GMGN, DEX Screener) read on-chain metadata getters and expect a
/// JSON document at `metadataBase + <token address>`. These tests pin down that both getter
/// names answer identically, that the address half is lowercase hex with no checksum casing, and
/// that {FamilyToken.uri} - the field the site itself reads - is untouched by any of this.
contract TokenMetadataTest is RoundTestBase {
    function setUp() public {
        _setUpEdge();
    }

    /// @notice Link one's `tokenURI()` and `metadataURI()` both equal the factory's
    /// `metadataBase` plus this token's own lowercase hex address.
    function test_tokenURIAndMetadataURI_equalBasePlusLowercaseAddress() public view {
        string memory expected = string.concat(factory.metadataBase(), _lowercaseHex(address(token)));
        assertEq(FamilyToken(address(token)).tokenURI(), expected, "tokenURI");
        assertEq(FamilyToken(address(token)).metadataURI(), expected, "metadataURI");
        assertEq(
            FamilyToken(address(token)).tokenURI(),
            FamilyToken(address(token)).metadataURI(),
            "the two getters agree"
        );
    }

    /// @notice A freshly registered candidate answers the same way, under ITS OWN address - the
    /// metadata document is per-token, not a constant string shared by the whole chain.
    function testFuzz_freshCandidate_metadataURI_isBasePlusItsOwnAddress(uint256 creatorSeed) public {
        address creator = address(uint160(bound(creatorSeed, 1, type(uint160).max)));
        vm.assume(creator.code.length == 0);
        Cand memory c = _registerCandidate(creator, "FRESH");

        string memory expected = string.concat(factory.metadataBase(), _lowercaseHex(c.token));
        assertEq(FamilyToken(c.token).tokenURI(), expected, "tokenURI of the fresh candidate");
        assertEq(FamilyToken(c.token).metadataURI(), expected, "metadataURI of the fresh candidate");
        assertTrue(c.token != address(token), "sanity: a different token than link one");
        assertTrue(
            keccak256(bytes(FamilyToken(c.token).metadataURI())) != keccak256(bytes(FamilyToken(address(token)).metadataURI())),
            "two different tokens get two different documents"
        );
    }

    /// @notice {FamilyToken.uri} keeps answering the registered image link untouched: adding the
    /// two new getters must not disturb the field the site itself reads.
    function test_uri_stillReturnsTheRegisteredImageLink() public {
        Cand memory c = _registerCandidate(address(0xF00D), "IMG");
        // RoundTestBase._registerCandidate always registers with an empty uri today; assert that
        // empty is exactly what comes back, unmangled by the new getters.
        assertEq(FamilyToken(c.token).uri(), "", "uri is whatever was registered, untouched");
    }

    /// @dev Reference lowercase hex encoding, built off OpenZeppelin's `Strings.toHexString`
    /// (which is documented to emit lowercase, unchecksummed hex) so the test does not duplicate
    /// {FamilyToken._toHexAddress}'s own implementation.
    function _lowercaseHex(address account) internal pure returns (string memory) {
        return Strings.toHexString(account);
    }
}
