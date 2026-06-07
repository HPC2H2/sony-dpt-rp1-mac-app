import Foundation
import CommonCrypto
import CryptoKit

/// Low-level cryptographic primitives used by the DPT-RP1 pairing handshake.
///
/// These are deliberately thin wrappers that mirror, byte-for-byte, the behaviour
/// of the Python reference implementation in `dptrp1.py` so the Swift port can be
/// validated against reference test vectors.
public enum CryptoPrimitives {

    // MARK: Random

    /// Cryptographically secure random bytes (mirrors `os.urandom`).
    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    // MARK: HMAC-SHA256

    /// HMAC-SHA256 (mirrors `Crypto.Hash.HMAC` with SHA256).
    public static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey)
        return Data(mac)
    }

    // MARK: SHA256

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: PBKDF2-HMAC-SHA256

    /// PBKDF2 with HMAC-SHA256 (mirrors `pbkdf2.PBKDF2(...).read(length)`).
    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                password.withUnsafeBytes { passwordBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        length
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    // MARK: AES-128-CBC (no padding — caller pads/unpads to match Python)

    public static func aesCBCEncrypt(key: Data, iv: Data, data: Data) -> Data {
        crypt(operation: CCOperation(kCCEncrypt), key: key, iv: iv, data: data)
    }

    public static func aesCBCDecrypt(key: Data, iv: Data, data: Data) -> Data {
        crypt(operation: CCOperation(kCCDecrypt), key: key, iv: iv, data: data)
    }

    /// CBC mode, no internal padding (options = 0). Input length must be a
    /// multiple of the block size; the caller is responsible for PKCS#7
    /// padding so the layout matches the Python `wrap`/`unwrap` exactly.
    private static func crypt(operation: CCOperation, key: Data, iv: Data, data: Data) -> Data {
        precondition(data.count % kCCBlockSizeAES128 == 0, "AES-CBC input not block-aligned")
        var output = Data(count: data.count)
        let outputCount = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // CBC, no padding
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES-CBC failed: \(status)")
        return output.prefix(moved)
    }

    // MARK: PKCS#7 padding (mirrors the helpers in dptrp1.py)

    public static func pkcs7Pad(_ data: Data, blockSize: Int = 16) -> Data {
        let value = blockSize - (data.count % blockSize)
        return data + Data(repeating: UInt8(value), count: value)
    }

    public static func pkcs7Unpad(_ data: Data, blockSize: Int = 16) -> Data {
        guard let last = data.last, last > 0, Int(last) <= data.count else { return data }
        return data.dropLast(Int(last))
    }
}
