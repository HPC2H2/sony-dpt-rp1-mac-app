import Foundation
import BigInt
import OSLog

public struct DeviceCredentials: Sendable, Codable {
    public let clientID: String
    public let privateKeyPEM: String
    public let certificatePEM: String
}

public enum RegistrationError: Error, LocalizedError {
    case protocolMismatch(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .protocolMismatch(let s): return "Pairing failed: \(s)"
        case .server(let s): return "Device error during pairing: \(s)"
        }
    }
}

/// Two-phase device pairing handshake, ported from `dptrp1.py:178-348`.
///
/// Usage:
///   let reg = Registration(client: client)
///   try await reg.begin()                 // shows a PIN on the device
///   let creds = try await reg.complete(pin: "1234")
public actor Registration {

    private let client: DigitalPaperClient

    // Intermediate state carried between begin() and complete().
    private var n1 = Data(), n2 = Data(), mac = Data()
    private var yb256 = Data(), ya257 = Data()
    private var authKey = Data(), keyWrapKey = Data()
    private var eHash = Data(), m2hmac = Data(), m3hmac = Data()

    public init(client: DigitalPaperClient) {
        self.client = client
    }

    private func reg(_ method: String, _ path: String, _ json: [String: Any]? = nil) async throws -> [String: Any] {
        let data = try await client.registrationRequest(method: method, path: path, json: json)
        // Several registration responses (cleanup, final register) have an empty
        // or non-JSON body — tolerate that instead of throwing a decode error.
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func b64(_ d: Data) -> String { d.base64EncodedString() }
    private func d64(_ s: Any?) -> Data { (s as? String).flatMap { Data(base64Encoded: $0) } ?? Data() }
    private func hmac(_ message: Data) -> Data { CryptoPrimitives.hmacSHA256(key: authKey, message: message) }

    /// Phase 1: DH exchange + nonce verification. After this returns, a 4-digit
    /// PIN is shown on the device screen.
    public func begin() async throws {
        dpLog.info("registration: cleanup")
        _ = try await reg("PUT", "/register/cleanup")

        dpLog.info("registration: request PIN")
        let m1 = try await reg("POST", "/register/pin")
        dpLog.info("registration: m1 keys=\(m1.keys.sorted(), privacy: .public)")
        n1 = d64(m1["a"])
        mac = d64(m1["b"])
        let ybInt = BigUInt(d64(m1["c"]))
        n2 = CryptoPrimitives.randomBytes(16)

        let dh = DiffieHellman()
        let yaInt = dh.publicKey()
        ya257 = Data([0x00]) + yaInt.toBytes(256)              // b"\x00" + ya.to_bytes(256)
        let zz = dh.sharedSecret(peerPublicKey: ybInt).toBytes(256)
        yb256 = ybInt.toBytes(256)

        let derived = CryptoPrimitives.pbkdf2SHA256(password: zz, salt: n1 + mac + n2,
                                                    iterations: 10000, length: 48)
        authKey = derived.prefix(32)
        keyWrapKey = derived.suffix(16)

        m2hmac = hmac(n1 + mac + yb256 + n1 + n2 + mac + ya257)
        dpLog.info("registration: send hash (m2)")
        let m3 = try await reg("POST", "/register/hash", [
            "a": b64(n1), "b": b64(n2), "c": b64(mac), "d": b64(ya257), "e": b64(m2hmac),
        ])

        guard d64(m3["a"]) == n2 else { throw RegistrationError.protocolMismatch("nonce N2 mismatch (m3)") }
        eHash = d64(m3["b"])
        m3hmac = d64(m3["e"])
        let expected = hmac(n1 + n2 + mac + ya257 + m2hmac + n2 + eHash)
        guard m3hmac == expected else { throw RegistrationError.protocolMismatch("M3 HMAC mismatch") }
        dpLog.info("registration: PIN should now be visible on device")
    }

    /// Phase 2: prove knowledge of the PIN, receive the CA cert, register a fresh
    /// RSA key + client id. Returns the persistent credentials.
    public func complete(pin: String) async throws -> DeviceCredentials {
        let psk = hmac(Data(pin.utf8))

        let rs = CryptoPrimitives.randomBytes(16)
        let rHash = hmac(rs + psk + yb256 + ya257)
        let wrappedRs = KeyWrap.wrap(rs, authKey: authKey, keyWrapKey: keyWrapKey)
        let m4hmac = hmac(n2 + eHash + m3hmac + n1 + rHash + wrappedRs)

        let m5 = try await reg("POST", "/register/ca", [
            "a": b64(n1), "b": b64(rHash), "d": b64(wrappedRs), "e": b64(m4hmac),
        ])
        guard d64(m5["a"]) == n2 else { throw RegistrationError.protocolMismatch("nonce N2 mismatch (m5)") }

        let wrappedEsCert = d64(m5["d"])
        let m5hmac = d64(m5["e"])
        let expected5 = hmac(n1 + rHash + wrappedRs + m4hmac + n2 + wrappedEsCert)
        guard m5hmac == expected5 else { throw RegistrationError.protocolMismatch("M5 HMAC mismatch") }

        let (esCert, _) = KeyWrap.unwrap(wrappedEsCert, authKey: authKey, keyWrapKey: keyWrapKey)
        let es = esCert.prefix(16)
        let cert = esCert.suffix(esCert.count - 16)

        let eHashCheck = hmac(Data(es) + psk + yb256 + ya257)
        guard eHashCheck == eHash else { throw RegistrationError.protocolMismatch("eHash mismatch (wrong PIN?)") }

        // Fresh RSA-2048 key + client id.
        let newKey = try RSAKey.generate()
        // pycryptodome emits the public key with no trailing newline; match it so
        // the device parses the wrapped payload identically.
        let keyPubC = try newKey.publicPEM().trimmingTrailingNewline()
        // Python uses str(uuid.uuid4()) which is lowercase; the device validates
        // the client-id format, so match it exactly.
        let clientID = UUID().uuidString.lowercased()
        let payload = Data(clientID.utf8) + Data(keyPubC.utf8)

        let wrappedPayload = KeyWrap.wrap(payload, authKey: authKey, keyWrapKey: keyWrapKey)
        let m6hmac = hmac(n2 + wrappedEsCert + m5hmac + n1 + wrappedPayload)

        _ = try await reg("POST", "/register", [
            "a": b64(n1), "d": b64(wrappedPayload), "e": b64(m6hmac),
        ])
        _ = try await reg("PUT", "/register/cleanup")

        let privatePEM = try newKey.privatePEM()
        let certPEM = String(data: Data(cert), encoding: .utf8) ?? ""
        return DeviceCredentials(clientID: clientID, privateKeyPEM: privatePEM, certificatePEM: certPEM)
    }
}

private extension String {
    func trimmingTrailingNewline() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
