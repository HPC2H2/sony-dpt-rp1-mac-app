import Foundation
import OSLog

let dpLog = Logger(subsystem: "com.danielkao.digitalpaper", category: "protocol")

/// Format a host for use inside a URL. IPv6 literals must be bracketed, and a
/// link-local zone id ("%en5") must be preserved and percent-encoded ("%25en5")
/// or the address is unroutable. Hostnames and IPv4 pass through unchanged.
func dpHostForURL(_ host: String) -> String {
    guard host.contains(":") else { return host }   // not IPv6
    if host.hasPrefix("[") { return host }           // already bracketed
    let escaped = host.replacingOccurrences(of: "%", with: "%25")
    return "[\(escaped)]"
}

public enum DigitalPaperError: Error, LocalizedError {
    case http(status: Int, message: String?)
    case notAuthenticated
    case resolveFailed(path: String, message: String?)
    case decoding(String)
    case missingCookie

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "HTTP \(status)\(message.map { ": \($0)" } ?? "")"
        case .notAuthenticated: return "Not authenticated with the device."
        case .resolveFailed(let path, let message): return "Could not resolve \(path)\(message.map { ": \($0)" } ?? "")"
        case .decoding(let what): return "Failed to decode \(what)."
        case .missingCookie: return "Device did not return a session cookie."
        }
    }
}

/// Async client for the Sony Digital Paper local API.
///
/// Mirrors the protocol implemented by `dptrp1.py`: registration over
/// `http://host:8080`, the authenticated API over `https://host:8443` (with a
/// self-signed certificate), RSA-SHA256 nonce signing, and a manually managed
/// `Credentials` session cookie.
public actor DigitalPaperClient {

    public let host: String
    private let session: URLSession
    private let delegate: InsecureTLSDelegate
    private var credentials: String?   // value of the Credentials cookie
    public private(set) var deviceInfo: DeviceInfo?

    public init(host: String) {
        self.host = host
        self.delegate = InsecureTLSDelegate(trustedHost: host)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false           // we manage the cookie ourselves
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Base URLs

    private var apiBase: String { "https://\(dpHostForURL(host)):8443" }
    private var regBase: String { "http://\(dpHostForURL(host)):8080" }

    // MARK: - Low-level request

    private func request(
        method: String,
        base: String,
        path: String,
        json: [String: Any]? = nil,
        body: Data? = nil,
        contentType: String? = nil,
        authenticated: Bool = true
    ) async throws -> Data {
        guard let url = URL(string: base + path) else {
            throw DigitalPaperError.http(status: -1, message: "Bad URL \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method

        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        }

        if authenticated, let credentials {
            req.setValue("Credentials=\(credentials)", forHTTPHeaderField: "Cookie")
        }

        dpLog.debug("→ \(method, privacy: .public) \(url.absoluteString, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            dpLog.error("✗ \(method, privacy: .public) \(url.absoluteString, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw DigitalPaperError.http(status: -1, message: "No HTTP response")
        }
        dpLog.debug("← \(http.statusCode) \(url.absoluteString, privacy: .public) (\(data.count) bytes)")
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            dpLog.error("← HTTP \(http.statusCode) body: \(body, privacy: .public)")
            throw DigitalPaperError.http(status: http.statusCode, message: message ?? (body.isEmpty ? nil : body))
        }
        return data
    }

    private func getJSON<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await request(method: "GET", base: apiBase, path: path)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            let body = String(data: data.prefix(1024), encoding: .utf8) ?? ""
            dpLog.error("decode \(String(describing: T.self), privacy: .public) failed: \(error.localizedDescription, privacy: .public) — body: \(body, privacy: .public)")
            throw DigitalPaperError.decoding("\(T.self)")
        }
    }

    // MARK: - Device info (registration server, unauthenticated)

    @discardableResult
    public func fetchDeviceInfo() async throws -> DeviceInfo {
        let data = try await request(method: "GET", base: regBase, path: "/register/information", authenticated: false)
        let info = try JSONDecoder().decode(DeviceInfo.self, from: data)
        deviceInfo = info
        return info
    }

    // MARK: - Authentication

    /// Authenticate using stored client id + private key PEM. Stores the session cookie.
    public func authenticate(clientID: String, privateKeyPEM: String) async throws {
        let key = try RSAKey.fromPrivatePEM(privateKeyPEM)
        let nonceData = try await request(method: "GET", base: apiBase,
                                          path: "/auth/nonce/\(clientID)", authenticated: false)
        guard let nonceObj = try JSONSerialization.jsonObject(with: nonceData) as? [String: Any],
              let nonce = nonceObj["nonce"] as? String else {
            throw DigitalPaperError.decoding("nonce")
        }
        let signed = try key.signRSASHA256Base64(Data(nonce.utf8))

        // PUT /auth — read Set-Cookie manually (the device's cookie format is
        // non-standard, hence cookie handling is disabled on the session).
        guard let url = URL(string: apiBase + "/auth") else { throw DigitalPaperError.notAuthenticated }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "nonce_signed": signed])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DigitalPaperError.notAuthenticated
        }
        guard let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") else {
            throw DigitalPaperError.missingCookie
        }
        // Format: "Credentials=<value>; Path=/; ..."
        let firstPair = setCookie.split(separator: ";").first.map(String.init) ?? setCookie
        let value = firstPair.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        guard let value else { throw DigitalPaperError.missingCookie }
        credentials = value
    }

    public var isAuthenticated: Bool { credentials != nil }

    public func ping() async throws {
        _ = try await request(method: "GET", base: apiBase, path: "/ping")
    }

    // MARK: - Documents & folders

    /// Flat listing of everything (fast path). Folders + documents.
    public func listAll() async throws -> [Entry] {
        try await getJSON(EntryList.self, path: "/documents2?entry_type=all").entryList
    }

    public func listFolderEntries(folderID: String) async throws -> [Entry] {
        try await getJSON(EntryList.self, path: "/folders/\(folderID)/entries").entryList
    }

    public func resolve(path: String) async throws -> Entry {
        let encoded = Self.quotePlus(path)
        do {
            return try await getJSON(Entry.self, path: "/resolve/entry/path/\(encoded)")
        } catch DigitalPaperError.http(_, let message) {
            throw DigitalPaperError.resolveFailed(path: path, message: message)
        }
    }

    public func objectID(path: String) async throws -> String {
        try await resolve(path: path).entryId
    }

    public func download(entryID: String) async throws -> Data {
        try await request(method: "GET", base: apiBase, path: "/documents/\(entryID)/file")
    }

    /// Create a folder under `parentID`, returns the new folder's entry id.
    @discardableResult
    public func createFolder(name: String, parentID: String) async throws -> String {
        let data = try await request(method: "POST", base: apiBase, path: "/folders2",
                                     json: ["folder_name": name, "parent_folder_id": parentID])
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["folder_id"] as? String else { throw DigitalPaperError.decoding("folder_id") }
        return id
    }

    /// Ensure a folder path exists (creating intermediate folders), returns its id.
    /// `path` is relative to and including the `Document` root, e.g. "Document/A/B".
    @discardableResult
    public func ensureFolder(path: String) async throws -> String {
        if let existing = try? await objectID(path: path) { return existing }
        let components = path.split(separator: "/").map(String.init)
        var current = components.first ?? "Document"
        var parentID = try await objectID(path: current)
        for component in components.dropFirst() {
            let next = current + "/" + component
            if let existing = try? await objectID(path: next) {
                parentID = existing
            } else {
                parentID = try await createFolder(name: component, parentID: parentID)
            }
            current = next
        }
        return parentID
    }

    /// Upload `data` as `filename` into folder `parentID`, overwriting if a file
    /// already exists at `parentPath/filename` (pass the parent folder's
    /// `entry_path` to enable overwrite detection).
    public func upload(data: Data, filename: String, parentID: String, parentPath: String? = nil) async throws {
        let remotePath = parentPath.map { "\($0)/\(filename)" }
        var docID: String
        if let remotePath, let existing = try? await objectID(path: remotePath) {
            docID = existing
        } else {
            let created = try await request(method: "POST", base: apiBase, path: "/documents2",
                                            json: ["file_name": filename,
                                                   "parent_folder_id": parentID,
                                                   "document_source": ""])
            let obj = try JSONSerialization.jsonObject(with: created) as? [String: Any]
            guard let id = obj?["document_id"] as? String else { throw DigitalPaperError.decoding("document_id") }
            docID = id
        }
        let (body, contentType) = Self.multipartBody(fieldName: "file", filename: filename, fileData: data)
        _ = try await request(method: "PUT", base: apiBase, path: "/documents/\(docID)/file",
                              body: body, contentType: contentType)
    }

    public func delete(entryID: String) async throws {
        _ = try await request(method: "DELETE", base: apiBase, path: "/documents/\(entryID)")
    }

    public func deleteFolder(folderID: String) async throws {
        _ = try await request(method: "DELETE", base: apiBase, path: "/folders/\(folderID)")
    }

    public func move(entryID: String, toParentID parentID: String, newName: String? = nil) async throws {
        var json: [String: Any] = ["parent_folder_id": parentID]
        if let newName { json["file_name"] = newName }
        _ = try await request(method: "PUT", base: apiBase, path: "/documents/\(entryID)", json: json)
    }

    public func copy(entryID: String, toParentID parentID: String, newName: String? = nil) async throws {
        var json: [String: Any] = ["parent_folder_id": parentID]
        if let newName { json["file_name"] = newName }
        _ = try await request(method: "POST", base: apiBase, path: "/documents/\(entryID)/copy", json: json)
    }

    public func displayDocument(entryID: String, page: Int = 1) async throws {
        _ = try await request(method: "PUT", base: apiBase, path: "/viewer/controls/open2",
                              json: ["document_id": entryID, "page": page])
    }

    // MARK: - Status

    public func storage() async throws -> StorageInfo { try await getJSON(StorageInfo.self, path: "/system/status/storage") }
    public func battery() async throws -> BatteryInfo { try await getJSON(BatteryInfo.self, path: "/system/status/battery") }

    public func firmwareVersion() async throws -> String {
        let data = try await request(method: "GET", base: apiBase, path: "/system/status/firmware_version")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["value"] as? String) ?? ""
    }

    public func screenshot() async throws -> Data {
        try await request(method: "GET", base: apiBase, path: "/system/controls/screen_shot")
    }

    // MARK: - Wi-Fi

    public func wifiEnabled() async throws -> Bool {
        let data = try await request(method: "GET", base: apiBase, path: "/system/configs/wifi")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["value"] as? String) == "on"
    }

    public func setWifi(enabled: Bool) async throws {
        _ = try await request(method: "PUT", base: apiBase, path: "/system/configs/wifi",
                              json: ["value": enabled ? "on" : "off"])
    }

    public func listWifi() async throws -> [WifiAccessPoint] {
        try await getJSON(WifiList.self, path: "/system/configs/wifi_accesspoints").aplist ?? []
    }

    public func scanWifi() async throws -> [WifiAccessPoint] {
        let data = try await request(method: "POST", base: apiBase, path: "/system/controls/wifi_accesspoints/scan")
        return ((try? JSONDecoder().decode(WifiList.self, from: data))?.aplist) ?? []
    }

    public func addWifi(ssid: String, security: String, passphrase: String) async throws {
        let encodedSSID = Data(ssid.utf8).base64EncodedString()
        _ = try await request(method: "PUT", base: apiBase, path: "/system/controls/wifi_accesspoints/register",
                              json: [
                                "ssid": encodedSSID,
                                "security": security,
                                "passwd": passphrase,
                                "dhcp": "true",
                                "static_address": "",
                                "gateway": "",
                                "network_mask": "",
                                "dns1": "",
                                "dns2": "",
                                "proxy": "false",
                              ])
    }

    public func deleteWifi(ssidBase64: String, security: String) async throws {
        _ = try await request(method: "DELETE", base: apiBase,
                              path: "/system/configs/wifi_accesspoints/\(Self.quotePlus(ssidBase64))/\(security)")
    }

    // MARK: - System config

    public func owner() async throws -> String {
        let data = try await request(method: "GET", base: apiBase, path: "/system/configs/owner")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["value"] as? String) ?? ""
    }

    public func setOwner(_ name: String) async throws {
        _ = try await request(method: "PUT", base: apiBase, path: "/system/configs/owner", json: ["value": name])
    }

    public func timezone() async throws -> String {
        let data = try await request(method: "GET", base: apiBase, path: "/system/configs/timezone")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["value"] as? String) ?? ""
    }

    public func setTimezone(_ tz: String) async throws {
        _ = try await request(method: "PUT", base: apiBase, path: "/system/configs/timezone", json: ["value": tz])
    }

    // MARK: - Templates

    public func listTemplates() async throws -> [NoteTemplate] {
        try await getJSON(TemplateList.self, path: "/viewer/configs/note_templates").templateList
    }

    public func uploadTemplate(data: Data, name: String) async throws {
        let created = try await request(method: "POST", base: apiBase, path: "/viewer/configs/note_templates",
                                        json: ["template_name": name, "document_source": ""])
        let obj = try JSONSerialization.jsonObject(with: created) as? [String: Any]
        guard let id = obj?["note_template_id"] as? String else { throw DigitalPaperError.decoding("note_template_id") }
        let (body, contentType) = Self.multipartBody(fieldName: "file", filename: name, fileData: data)
        _ = try await request(method: "PUT", base: apiBase, path: "/viewer/configs/note_templates/\(id)/file",
                              body: body, contentType: contentType)
    }

    public func deleteTemplate(id: String) async throws {
        _ = try await request(method: "DELETE", base: apiBase, path: "/viewer/configs/note_templates/\(id)")
    }

    // MARK: - Registration handshake hook
    //
    // The full pairing flow lives in Registration.swift; it needs to talk to the
    // registration server, so expose a helper here.
    func registrationRequest(method: String, path: String, json: [String: Any]?) async throws -> Data {
        try await request(method: method, base: regBase, path: path, json: json, authenticated: false)
    }

    func setCredentials(_ value: String?) { credentials = value }

    // MARK: - Helpers

    /// Multipart/form-data body for a single file field (mirrors requests' `files=`).
    static func multipartBody(fieldName: String, filename: String, fileData: Data) -> (Data, String) {
        let boundary = "----DigitalPaperBoundary\(UUID().uuidString)"
        var body = Data()
        let encodedName = quotePlus(filename)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(encodedName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// Python `urllib.parse.quote_plus` equivalent: keep [A-Za-z0-9_.-~],
    /// space → "+", everything else → percent-encoded.
    static func quotePlus(_ s: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")
        var out = ""
        for byte in Array(s.utf8) {
            let scalar = Character(UnicodeScalar(byte))
            if byte == 0x20 {
                out += "+"
            } else if byte < 128, unreserved.contains(scalar) {
                out.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
