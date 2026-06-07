import Foundation
import Security

/// Persists device credentials in the Keychain, keyed by device serial, and can
/// import credentials previously created by the `dpt-rp1-py` CLI or Sony's
/// Digital Paper App (mirrors `find_auth_files()` in `dptrp1.py:40-73`).
public enum CredentialStore {

    private static let service = "com.danielkao.digitalpaper.credentials"

    // MARK: Keychain

    public static func save(_ credentials: DeviceCredentials, serial: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    public static func load(serial: String) -> DeviceCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    public static func allSerials() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]] else { return [] }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public static func delete(serial: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serial,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Import from existing CLI / Sony app files

    /// Search the default `dpt-rp1-py` location and Sony's app directories for an
    /// existing `deviceid.dat` + `privatekey.dat` pair. Returns credentials with
    /// an empty certificate (the device API ignores it; TLS validation is off).
    public static func importExisting() -> DeviceCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. Default dpt-rp1-py path.
        let defaultDir = home.appendingPathComponent(".config/dpt")
        if let creds = read(deviceID: defaultDir.appendingPathComponent("deviceid.dat"),
                            privateKey: defaultDir.appendingPathComponent("privatekey.dat")) {
            return creds
        }

        // 2. Recursively search Sony's Digital Paper App directories.
        let searchRoots = [
            home.appendingPathComponent("Library/Application Support/Sony Corporation/Digital Paper App"),
            home.appendingPathComponent("AppData/Roaming/Sony Corporation/Digital Paper App"),
        ]
        for root in searchRoots {
            if let (idURL, keyURL) = findPair(under: root),
               let creds = read(deviceID: idURL, privateKey: keyURL) {
                return creds
            }
        }
        return nil
    }

    private static func read(deviceID: URL, privateKey: URL) -> DeviceCredentials? {
        guard let id = try? String(contentsOf: deviceID, encoding: .utf8),
              let key = try? String(contentsOf: privateKey, encoding: .utf8) else { return nil }
        let clientID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, key.contains("PRIVATE KEY") else { return nil }
        return DeviceCredentials(clientID: clientID, privateKeyPEM: key, certificatePEM: "")
    }

    private static func findPair(under root: URL) -> (deviceID: URL, privateKey: URL)? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var idURL: URL?, keyURL: URL?
        for case let url as URL in enumerator {
            if url.lastPathComponent == "deviceid.dat" { idURL = idURL ?? url }
            if url.lastPathComponent == "privatekey.dat" { keyURL = keyURL ?? url }
            if let i = idURL, let k = keyURL { return (i, k) }
        }
        return nil
    }
}
