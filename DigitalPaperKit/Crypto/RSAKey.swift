import Foundation
import Security

public enum RSAKeyError: Error {
    case generationFailed(String)
    case exportFailed(String)
    case importFailed(String)
    case signFailed(String)
}

/// RSA-2048 key handling: generation, PEM import/export, and RSA-SHA256 signing.
///
/// Matches the Python reference:
///  - private key exported as PKCS#1 PEM (`BEGIN RSA PRIVATE KEY`)
///  - public key exported as SubjectPublicKeyInfo PEM (`BEGIN PUBLIC KEY`),
///    which is what `pycryptodome`'s `publickey().exportKey("PEM")` emits and
///    what the device expects during registration.
///  - nonce signing uses RSA PKCS#1 v1.5 over SHA-256 (the `httpsig` rsa-sha256
///    algorithm), returned base64-encoded.
public struct RSAKey {

    public let secKey: SecKey

    public init(secKey: SecKey) {
        self.secKey = secKey
    }

    /// Generate a fresh RSA-2048 key (e = 65537, as in `RSA.generate(2048, e=65537)`).
    public static func generate() throws -> RSAKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw RSAKeyError.generationFailed(String(describing: error?.takeRetainedValue()))
        }
        return RSAKey(secKey: key)
    }

    /// Load a private key from a PKCS#1 PEM string.
    public static func fromPrivatePEM(_ pem: String) throws -> RSAKey {
        let der = try PEM.decode(pem, expectedLabels: ["RSA PRIVATE KEY", "PRIVATE KEY"])
        // SecKeyCreateWithData expects PKCS#1 for RSA private keys.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw RSAKeyError.importFailed(String(describing: error?.takeRetainedValue()))
        }
        return RSAKey(secKey: key)
    }

    /// PKCS#1 DER of the private key.
    private func privateDER() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw RSAKeyError.exportFailed(String(describing: error?.takeRetainedValue()))
        }
        return data
    }

    /// PKCS#1 DER of the public key.
    private func publicDER() throws -> Data {
        guard let pub = SecKeyCopyPublicKey(secKey) else {
            throw RSAKeyError.exportFailed("SecKeyCopyPublicKey returned nil")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw RSAKeyError.exportFailed(String(describing: error?.takeRetainedValue()))
        }
        return data
    }

    /// Private key as PKCS#1 PEM.
    public func privatePEM() throws -> String {
        PEM.encode(try privateDER(), label: "RSA PRIVATE KEY")
    }

    /// Public key as SubjectPublicKeyInfo PEM (matches pycryptodome output).
    public func publicPEM() throws -> String {
        let spki = DER.subjectPublicKeyInfo(rsaPKCS1: try publicDER())
        return PEM.encode(spki, label: "PUBLIC KEY")
    }

    /// RSA-SHA256 (PKCS#1 v1.5) signature over `message`, base64-encoded.
    public func signRSASHA256Base64(_ message: Data) throws -> String {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            message as CFData,
            &error
        ) as Data? else {
            throw RSAKeyError.signFailed(String(describing: error?.takeRetainedValue()))
        }
        return signature.base64EncodedString()
    }
}

// MARK: - PEM helpers

public enum PEM {
    public static func encode(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    public static func decode(_ pem: String, expectedLabels: [String]) throws -> Data {
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else {
            throw RSAKeyError.importFailed("Invalid base64 in PEM")
        }
        return data
    }
}

// MARK: - Minimal DER encoder (just enough to build a SubjectPublicKeyInfo)

public enum DER {
    /// DER length encoding.
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var value = n
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    /// AlgorithmIdentifier for rsaEncryption: SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }.
    static let rsaEncryptionAlgID = Data([
        0x30, 0x0d,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
        0x05, 0x00,
    ])

    /// Wrap a PKCS#1 RSAPublicKey DER into a SubjectPublicKeyInfo DER.
    public static func subjectPublicKeyInfo(rsaPKCS1: Data) -> Data {
        let bitString = tagged(0x03, Data([0x00]) + rsaPKCS1) // BIT STRING with 0 unused bits
        return tagged(0x30, rsaEncryptionAlgID + bitString)   // SEQUENCE
    }
}
