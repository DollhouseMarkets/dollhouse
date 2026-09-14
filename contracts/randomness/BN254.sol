// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BN254
/// @notice BLS signature verification on the alt_bn128 (BN254) curve, with signatures in G1 and
/// public keys in G2 - the shape drand's `evmnet` beacon produces, and the only pairing an EVM
/// can check natively (precompile 0x08).
///
/// @dev REIMPLEMENTED, NOT VENDORED. The algorithms are the public specifications:
///   - hash-to-curve: RFC 9380, `expand_msg_xmd` with keccak256 and the Shallue-van de
///     Woestijne map (RFC 9380 sec.6.6.1), domain-separated exactly as the beacon's scheme
///     name says - `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_`;
///   - the pairing check: EIP-197.
/// The reference implementations this was written against for behaviour (Randamu's
/// `randomness-solidity` `BLS.sol`, itself descended from the Hubble project's BN254 library) are
/// cited, not copied: no code from either is reproduced here.
///
/// The curve is `y^2 = x^3 + 3` over F_p with `p % 4 == 3`, so square roots are `a^((p+1)/4)`.
library BN254 {
    /// @notice Field modulus of BN254.
    uint256 internal constant P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
    /// @notice Curve parameter `b`. `a` is zero.
    uint256 internal constant B = 3;
    /// @notice `Z` of the SVDW map for this curve.
    uint256 internal constant SVDW_Z = 1;
    /// @notice `g(Z) = Z^3 + b`.
    uint256 internal constant SVDW_C1 = 4;
    /// @notice `-Z / 2 mod P`.
    uint256 internal constant SVDW_C2 = 10944121435919637611123202872628637544348155578648911831344518947322613104291;
    /// @notice `-4 * g(Z) / (3 * Z^2) mod P`, i.e. `-16/3`.
    uint256 internal constant SVDW_C4 = 7296080957279758407415468581752425029565437052432607887563012631548408736189;

    /// @notice Length in bytes each field element is expanded to before reduction (RFC 9380 `L`
    /// for a 254-bit field at the 128-bit security level).
    uint256 internal constant L = 48;
    /// @notice Input block size of keccak256, RFC 9380 `s_in_bytes`.
    uint256 internal constant S_IN_BYTES = 136;

    struct G1Point {
        uint256 x;
        uint256 y;
    }

    /// @notice A G2 point in EIP-197 order: `x = x[0] * i + x[1]`, `y = y[0] * i + y[1]`.
    struct G2Point {
        uint256[2] x;
        uint256[2] y;
    }

    error PairingFailed();
    error MapToPointFailed();
    error ExpandFailed();

    /// @notice The BLS check `e(H(message), publicKey) == e(signature, G2)`, rearranged into the
    /// single product the precompile evaluates: `e(H(m), pk) * e(sig, -G2) == 1`.
    function verifySingle(G1Point memory signature, G2Point memory publicKey, G1Point memory messagePoint)
        internal
        view
        returns (bool)
    {
        uint256[12] memory input;
        input[0] = messagePoint.x;
        input[1] = messagePoint.y;
        input[2] = publicKey.x[0];
        input[3] = publicKey.x[1];
        input[4] = publicKey.y[0];
        input[5] = publicKey.y[1];
        input[6] = signature.x;
        input[7] = signature.y;
        // the NEGATED G2 generator (EIP-197 order)
        input[8] = 11559732032986387107991004021392285783925812861821192530917403151452391805634;
        input[9] = 10857046999023057135944570762232829481370756359578518086990519993285655852781;
        input[10] = 17805874995975841540914202342111839520379459829704422454583296818431106115052;
        input[11] = 13392588948715843804641432497768002650278120570034223513918757245338268106653;

        uint256[1] memory out;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x08, input, 384, out, 32)
        }
        if (!ok) revert PairingFailed();
        return out[0] == 1;
    }

    /// @notice RFC 9380 `hash_to_curve`: two field elements from `expand_msg_xmd`, each mapped to
    /// the curve by SVDW, then added. The addition is done through the EIP-196 precompile.
    function hashToPoint(bytes memory domain, bytes memory message) internal view returns (G1Point memory) {
        (uint256 u0, uint256 u1) = hashToField(domain, message);
        uint256 c3 = svdwC3();
        G1Point memory p0 = mapToPoint(u0, c3);
        G1Point memory p1 = mapToPoint(u1, c3);
        return add(p0, p1);
    }

    /// @notice `c3 = sqrt(-g(Z) * 3 * Z^2)`, normalised to the even root (RFC 9380 sec.6.6.1).
    /// @dev Derived rather than hardcoded: it is one modexp, and a wrong constant here would be
    /// invisible except as "every signature fails".
    function svdwC3() internal view returns (uint256 c3) {
        // -g(Z) * (3 * Z^2 + 4a) = -4 * 3 = -12
        c3 = sqrt(P - 12);
        if (c3 & 1 == 1) c3 = P - c3;
    }

    /// @notice RFC 9380 `hash_to_field` for two elements of F_p.
    function hashToField(bytes memory domain, bytes memory message) internal pure returns (uint256 u0, uint256 u1) {
        bytes memory expanded = expandMsgXmd(domain, message, 2 * L);
        u0 = reduce48(expanded, 0);
        u1 = reduce48(expanded, L);
    }

    /// @dev `OS2IP(b[offset : offset + 48]) mod P`, without ever forming a 384-bit integer: the
    /// top 16 bytes are multiplied back in one byte at a time.
    function reduce48(bytes memory b, uint256 offset) internal pure returns (uint256 r) {
        uint256 hi;
        uint256 lo;
        assembly ("memory-safe") {
            // the 16 high bytes, right-aligned
            hi := shr(128, mload(add(add(b, 32), offset)))
            lo := mload(add(add(b, 32), add(offset, 16)))
        }
        r = hi;
        for (uint256 i = 0; i < 32; i++) {
            r = mulmod(r, 256, P);
        }
        r = addmod(r, lo % P, P);
    }

    /// @notice RFC 9380 `expand_msg_xmd` with keccak256.
    function expandMsgXmd(bytes memory domain, bytes memory message, uint256 outLen)
        internal
        pure
        returns (bytes memory out)
    {
        if (domain.length > 255 || outLen > 65535) revert ExpandFailed();
        uint256 ell = (outLen + 31) / 32;
        bytes1 dstLen = bytes1(uint8(domain.length));

        bytes32 b0 = keccak256(
            abi.encodePacked(new bytes(S_IN_BYTES), message, bytes2(uint16(outLen)), bytes1(0x00), domain, dstLen)
        );
        bytes32 bi = keccak256(abi.encodePacked(b0, bytes1(0x01), domain, dstLen));

        out = new bytes(outLen);
        _write(out, 0, bi, outLen);
        for (uint256 i = 2; i <= ell; i++) {
            bi = keccak256(abi.encodePacked(b0 ^ bi, bytes1(uint8(i)), domain, dstLen));
            _write(out, (i - 1) * 32, bi, outLen);
        }
    }

    /// @dev Copy up to 32 bytes of `word` into `out` at `at`, truncated to `outLen`.
    function _write(bytes memory out, uint256 at, bytes32 word, uint256 outLen) private pure {
        uint256 n = outLen - at;
        if (n > 32) n = 32;
        for (uint256 k = 0; k < n; k++) {
            out[at + k] = word[k];
        }
    }

    /// @notice RFC 9380 sec.6.6.1, the Shallue-van de Woestijne map, for `a == 0`.
    function mapToPoint(uint256 u, uint256 c3) internal view returns (G1Point memory) {
        uint256 tv1 = mulmod(mulmod(u, u, P), SVDW_C1, P);
        uint256 tv2 = addmod(1, tv1, P);
        tv1 = addmod(1, P - tv1, P);
        uint256 tv3 = inv0(mulmod(tv1, tv2, P));
        uint256 tv4 = mulmod(mulmod(mulmod(u, tv1, P), tv3, P), c3, P);

        uint256 x1 = addmod(SVDW_C2, P - tv4, P);
        uint256 gx1 = addmod(mulmod(mulmod(x1, x1, P), x1, P), B, P);

        uint256 x2 = addmod(SVDW_C2, tv4, P);
        uint256 gx2 = addmod(mulmod(mulmod(x2, x2, P), x2, P), B, P);

        uint256 x3 = mulmod(tv2, tv2, P);
        x3 = mulmod(x3, tv3, P);
        x3 = mulmod(x3, x3, P);
        x3 = mulmod(x3, SVDW_C4, P);
        x3 = addmod(x3, SVDW_Z, P);

        uint256 x;
        uint256 gx;
        if (isSquare(gx1)) {
            (x, gx) = (x1, gx1);
        } else if (isSquare(gx2)) {
            (x, gx) = (x2, gx2);
        } else {
            (x, gx) = (x3, addmod(mulmod(mulmod(x3, x3, P), x3, P), B, P));
        }

        uint256 y = sqrt(gx);
        if (mulmod(y, y, P) != gx) revert MapToPointFailed();
        // sgn0(u) must equal sgn0(y)
        if ((u & 1) != (y & 1)) y = P - y;
        return G1Point({x: x, y: y});
    }

    /// @notice `a^((P + 1) / 4) mod P`, the square root when one exists.
    function sqrt(uint256 a) internal view returns (uint256) {
        return expmod(a, (P + 1) / 4);
    }

    /// @notice `a^((P - 1) / 2) == 1`, with zero counted as a square.
    function isSquare(uint256 a) internal view returns (bool) {
        if (a == 0) return true;
        return expmod(a, (P - 1) / 2) == 1;
    }

    /// @notice `a^(P - 2) mod P`, i.e. the inverse, with `inv0(0) == 0` as RFC 9380 requires.
    function inv0(uint256 a) internal view returns (uint256) {
        if (a == 0) return 0;
        return expmod(a, P - 2);
    }

    function expmod(uint256 base, uint256 e) internal view returns (uint256 result) {
        uint256[6] memory input = [uint256(32), 32, 32, base, e, P];
        uint256[1] memory out;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x05, input, 192, out, 32)
        }
        if (!ok) revert PairingFailed();
        return out[0];
    }

    /// @notice G1 addition through the EIP-196 precompile (0x06).
    function add(G1Point memory a, G1Point memory b) internal view returns (G1Point memory r) {
        uint256[4] memory input = [a.x, a.y, b.x, b.y];
        uint256[2] memory out;
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x06, input, 128, out, 64)
        }
        if (!ok) revert PairingFailed();
        r.x = out[0];
        r.y = out[1];
    }

    /// @notice True when `p` is on the curve (and not the point at infinity).
    function isOnCurve(G1Point memory p) internal pure returns (bool) {
        if (p.x >= P || p.y >= P) return false;
        return mulmod(p.y, p.y, P) == addmod(mulmod(mulmod(p.x, p.x, P), p.x, P), B, P);
    }
}
