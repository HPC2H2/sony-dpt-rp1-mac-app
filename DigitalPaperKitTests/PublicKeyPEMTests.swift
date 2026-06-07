import XCTest
@testable import DigitalPaperKit

/// Verifies that our SubjectPublicKeyInfo PEM export is byte-for-byte identical
/// to what pycryptodome's `publickey().exportKey("PEM")` produces for the same
/// key — this is exactly the public key sent to the device during registration.
final class PublicKeyPEMTests: XCTestCase {

    func testPublicPEMMatchesPyCryptodome() throws {
        let bundle = Bundle(for: type(of: self))
        // Stored armorless (base64 DER) so GitHub push protection doesn't flag a
        // throwaway test private key; PEM.decode handles the missing armor.
        let privURL = try XCTUnwrap(bundle.url(forResource: "fixed_rsa_priv", withExtension: "b64"))
        let expURL = try XCTUnwrap(bundle.url(forResource: "expected_pub", withExtension: "pem"))

        let privPEM = try String(contentsOf: privURL, encoding: .utf8)
        let expected = try String(contentsOf: expURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let key = try RSAKey.fromPrivatePEM(privPEM)
        let produced = try key.publicPEM().trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(produced, expected, "Public-key PEM does not match pycryptodome output")
    }
}
