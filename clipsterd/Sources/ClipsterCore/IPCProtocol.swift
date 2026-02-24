import Foundation

// MARK: - Socket path

public enum IPCPaths {
    /// ~/Library/Application Support/Clipster/clipster.sock
    public static var socketURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Clipster", isDirectory: true)
            .appendingPathComponent("clipster.sock")
    }
}

// MARK: - Wire protocol constants

/// Supported protocol version. Clients sending a different version receive
/// `unsupported_protocol_version` and the connection is closed. PRD §7.6.
public let ipcProtocolVersion = 1

// MARK: - Command envelope (client → daemon)

public struct IPCCommand: Codable {
    public let version: Int
    public let id: String
    public let command: String
    public let params: IPCParams

    public init(version: Int = ipcProtocolVersion, id: String = UUID().uuidString, command: String, params: IPCParams = .empty) {
        self.version = version
        self.id = id
        self.command = command
        self.params = params
    }
}

/// Flexible params bag — decoded per command by the handler.
public struct IPCParams: Codable {
    public var limit: Int?
    public var offset: Int?
    public var entryID: String?
    public var transform: String?

    public init(limit: Int? = nil, offset: Int? = nil, entryID: String? = nil, transform: String? = nil) {
        self.limit     = limit
        self.offset    = offset
        self.entryID   = entryID
        self.transform = transform
    }

    public static let empty = IPCParams()

    enum CodingKeys: String, CodingKey {
        case limit, offset
        case entryID  = "entry_id"
        case transform
    }
}

// MARK: - Response envelope (daemon → client)

public struct IPCResponse: Codable {
    public let protocolVersion: Int
    public let id: String
    public let ok: Bool
    public let data: IPCResponseData?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case id, ok, data, error
    }

    public static func success(id: String, data: IPCResponseData) -> IPCResponse {
        IPCResponse(protocolVersion: ipcProtocolVersion, id: id, ok: true, data: data, error: nil)
    }

    public static func failure(id: String, error: String) -> IPCResponse {
        IPCResponse(protocolVersion: ipcProtocolVersion, id: id, ok: false, data: nil, error: error)
    }

    public static func versionError(id: String) -> IPCResponse {
        failure(id: id, error: "unsupported_protocol_version")
    }
}

// MARK: - Response data variants

public enum IPCResponseData: Codable {
    case entries([IPCEntry])
    case entry(IPCEntry)
    case deleted(Int)
    case transform(String)
    case daemonStatus(IPCDaemonStatus)
    case empty

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .entries(let list):
            try container.encode(["entries": list])
        case .entry(let e):
            try container.encode(["entry": e])
        case .deleted(let count):
            try container.encode(["deleted_count": count])
        case .transform(let result):
            try container.encode(["result": result])
        case .daemonStatus(let status):
            try container.encode(status)
        case .empty:
            try container.encode([String: String]())
        }
    }

    public init(from decoder: Decoder) throws {
        // Decoding is not needed server-side; stub for Codable conformance.
        self = .empty
    }
}

// MARK: - Entry DTO

public struct IPCEntry: Codable {
    public let id: String
    public let contentType: String
    public let content: String
    public let preview: String?
    public let sourceBundle: String?
    public let sourceName: String?
    public let sourceConfidence: String
    public let createdAt: Int64
    public let isPinned: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case contentType     = "content_type"
        case content, preview
        case sourceBundle    = "source_bundle"
        case sourceName      = "source_name"
        case sourceConfidence = "source_confidence"
        case createdAt       = "created_at"
        case isPinned        = "is_pinned"
    }

    public init(from entry: StoredEntry) {
        id               = entry.id
        contentType      = entry.contentType
        content          = entry.content
        preview          = entry.preview
        sourceBundle     = entry.sourceBundle
        sourceName       = entry.sourceName
        sourceConfidence = entry.sourceConfidence
        createdAt        = entry.createdAt
        isPinned         = entry.isPinned
    }

    /// Memberwise init used by tests and GUI clients that construct entries directly.
    public init(id: String, contentType: String, content: String, preview: String?,
                sourceBundle: String?, sourceName: String?, sourceConfidence: String,
                createdAt: Int64, isPinned: Bool) {
        self.id               = id
        self.contentType      = contentType
        self.content          = content
        self.preview          = preview
        self.sourceBundle     = sourceBundle
        self.sourceName       = sourceName
        self.sourceConfidence = sourceConfidence
        self.createdAt        = createdAt
        self.isPinned         = isPinned
    }
}

// MARK: - Daemon status DTO

public struct IPCDaemonStatus: Codable {
    public let running: Bool
    public let pid: Int32
    public let version: String
}

// MARK: - Framing

/// PRD §7.6 — 4-byte big-endian length prefix + UTF-8 JSON body.
public enum IPCFraming {
    /// Encode a Codable value as a framed message.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Read one complete framed message from a buffer.
    /// Returns the decoded body data and remaining buffer, or nil if the buffer
    /// doesn't yet contain a complete message.
    public static func readFrame(from buffer: Data) -> (body: Data, remaining: Data)? {
        guard buffer.count >= 4 else { return nil }
        let lengthBytes = buffer.prefix(4)
        let length = lengthBytes.withUnsafeBytes { ptr in
            UInt32(bigEndian: ptr.load(as: UInt32.self))
        }
        let totalNeeded = 4 + Int(length)
        guard buffer.count >= totalNeeded else { return nil }
        let body = buffer[4..<totalNeeded]
        let remaining = buffer.dropFirst(totalNeeded)
        return (Data(body), Data(remaining))
    }
}
