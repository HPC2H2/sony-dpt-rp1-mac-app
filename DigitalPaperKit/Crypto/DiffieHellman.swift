import Foundation
import BigInt

/// Diffie-Hellman key exchange using RFC 3526 MODP group 14 (2048-bit),
/// mirroring `dptrp1/pyDH.py` (private exponent = 32 random bytes, generator 2).
public struct DiffieHellman {

    /// RFC 3526 group 14 prime (2048-bit).
    public static let prime: BigUInt = {
        let hex =
            "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08" +
            "8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B" +
            "302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9" +
            "A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6" +
            "49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8" +
            "FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D" +
            "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C" +
            "180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
            "3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFF" +
            "FFFFFFFF"
        return BigUInt(hex, radix: 16)!
    }()

    public static let generator: BigUInt = 2

    public let privateKey: BigUInt

    public init() {
        // Private exponent: 32 random bytes interpreted as a big-endian integer,
        // matching `int(binascii.hexlify(os.urandom(32)), 16)`.
        self.privateKey = BigUInt(CryptoPrimitives.randomBytes(32))
    }

    /// For deterministic testing.
    public init(privateKeyBytes: Data) {
        self.privateKey = BigUInt(privateKeyBytes)
    }

    /// A = g^a mod p
    public func publicKey() -> BigUInt {
        DiffieHellman.generator.power(privateKey, modulus: DiffieHellman.prime)
    }

    /// Shared secret zz = B^a mod p
    public func sharedSecret(peerPublicKey: BigUInt) -> BigUInt {
        peerPublicKey.power(privateKey, modulus: DiffieHellman.prime)
    }
}

extension BigUInt {
    /// Big-endian, left-padded with zero bytes to exactly `length` (mirrors
    /// Python `int.to_bytes(length, "big")`).
    func toBytes(_ length: Int) -> Data {
        let raw = self.serialize() // big-endian, no leading zeros
        if raw.count >= length {
            return raw.suffix(length)
        }
        return Data(repeating: 0, count: length - raw.count) + raw
    }
}
