import Foundation

/// Device identity returned by `GET /register/information`.
public struct DeviceInfo: Codable, Sendable, Hashable {
    public let serialNumber: String
    public let value: String?      // model string on some firmware
    public let modelName: String?

    enum CodingKeys: String, CodingKey {
        case serialNumber = "serial_number"
        case value
        case modelName = "model_name"
    }

    public var displayModel: String { modelName ?? value ?? "Digital Paper" }
}

/// A document or folder entry (from `/documents2`, `/folders/{id}/entries`, `/resolve`).
///
/// The device returns numeric fields (file_size, total_page_num) as JSON
/// *strings*, so those are decoded flexibly.
public struct Entry: Codable, Sendable, Hashable, Identifiable {
    public let entryId: String
    public let entryName: String
    public let entryPath: String
    public let entryType: String        // "document" | "folder"
    public let parentFolderId: String?
    public let fileSize: Int?
    public let totalPageNum: Int?
    public let createdDate: String?
    public let modifiedDate: String?

    public var id: String { entryId }
    public var isFolder: Bool { entryType == "folder" }

    enum CodingKeys: String, CodingKey {
        case entryId = "entry_id"
        case entryName = "entry_name"
        case entryPath = "entry_path"
        case entryType = "entry_type"
        case parentFolderId = "parent_folder_id"
        case fileSize = "file_size"
        case totalPageNum = "total_page_num"
        case createdDate = "created_date"
        case modifiedDate = "modified_date"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try c.decode(String.self, forKey: .entryId)
        entryName = try c.decode(String.self, forKey: .entryName)
        entryPath = try c.decode(String.self, forKey: .entryPath)
        entryType = try c.decode(String.self, forKey: .entryType)
        parentFolderId = try c.decodeIfPresent(String.self, forKey: .parentFolderId)
        createdDate = try c.decodeIfPresent(String.self, forKey: .createdDate)
        modifiedDate = try c.decodeIfPresent(String.self, forKey: .modifiedDate)
        fileSize = Self.flexibleInt(c, .fileSize)
        totalPageNum = Self.flexibleInt(c, .totalPageNum)
    }

    /// Decode an Int that may be encoded as a number or a string.
    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key) { return Int(s) }
        return nil
    }
}

struct EntryList: Codable { let entryList: [Entry]; enum CodingKeys: String, CodingKey { case entryList = "entry_list" } }

/// `GET /system/status/storage`
public struct StorageInfo: Codable, Sendable {
    public let available: String?
    public let capacity: String?

    public var availableBytes: Int64? { available.flatMap { Int64($0) } }
    public var capacityBytes: Int64? { capacity.flatMap { Int64($0) } }
}

/// `GET /system/status/battery`
public struct BatteryInfo: Codable, Sendable {
    public let level: Int?
    public let pen: Int?
    public let status: String?
    public let plugged: String?
    public let health: String?
}

/// A configured/scanned Wi-Fi access point.
public struct WifiAccessPoint: Codable, Sendable, Hashable, Identifiable {
    public let ssid: String          // base64-encoded as sent by the device
    public let security: String?
    public let signalLevel: Int?

    public var id: String { ssid + (security ?? "") }

    /// SSID decoded from base64 for display.
    public var displaySSID: String {
        if let data = Data(base64Encoded: ssid), let s = String(data: data, encoding: .utf8) { return s }
        return ssid
    }

    enum CodingKeys: String, CodingKey {
        case ssid
        case security
        case signalLevel = "signal_level"
    }
}

struct WifiList: Codable { let aplist: [WifiAccessPoint]? }

/// A note template (`GET /viewer/configs/note_templates`).
public struct NoteTemplate: Codable, Sendable, Hashable, Identifiable {
    public let templateName: String
    public let noteTemplateId: String?

    public var id: String { noteTemplateId ?? templateName }

    enum CodingKeys: String, CodingKey {
        case templateName
        case noteTemplateId = "note_template_id"
    }
}

struct TemplateList: Codable { let templateList: [NoteTemplate] }
