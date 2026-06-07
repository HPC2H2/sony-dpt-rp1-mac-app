import Foundation

/// Authenticated key wrapping used during registration, mirroring the `wrap` /
/// `unwrap` helpers in `dptrp1.py:1223-1262`.
///
/// Layout (must match exactly):
///   plaintext = data || HMAC-SHA256(authKey, data)[0..8]
///   wrapped   = AES-128-CBC(keyWrapKey, iv, PKCS7(plaintext)) || iv
/// The IV is appended at the **end** of the ciphertext.
public enum KeyWrap {

    public static func wrap(_ data: Data, authKey: Data, keyWrapKey: Data, iv: Data? = nil) -> Data {
        let kwa = CryptoPrimitives.hmacSHA256(key: authKey, message: data).prefix(8)
        let iv = iv ?? CryptoPrimitives.randomBytes(16)
        let padded = CryptoPrimitives.pkcs7Pad(data + kwa)
        let ciphertext = CryptoPrimitives.aesCBCEncrypt(key: keyWrapKey, iv: iv, data: padded)
        return ciphertext + iv
    }

    @discardableResult
    public static func unwrap(_ wrapped: Data, authKey: Data, keyWrapKey: Data) -> (data: Data, kwaMatches: Bool) {
        let iv = wrapped.suffix(16)
        let ciphertext = wrapped.prefix(wrapped.count - 16)
        let decrypted = CryptoPrimitives.aesCBCDecrypt(key: keyWrapKey, iv: Data(iv), data: Data(ciphertext))
        let unpadded = CryptoPrimitives.pkcs7Unpad(decrypted)
        let kwa = unpadded.suffix(8)
        let payload = unpadded.prefix(unpadded.count - 8)
        let localKwa = CryptoPrimitives.hmacSHA256(key: authKey, message: Data(payload)).prefix(8)
        return (Data(payload), Data(kwa) == Data(localKwa))
    }
}
