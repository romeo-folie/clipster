import Foundation

/// Represents a clipboard entry for display in the panel.
struct ClipboardEntry: Identifiable {
    let id: String
    let contentType: ContentType
    let preview: String
    let sourceApp: String
    let timestamp: Date
    let isPinned: Bool

    /// Content type determines the icon shown in each row.
    enum ContentType: String {
        case plainText = "plain-text"
        case richText = "rich-text"
        case image = "image"
        case url = "url"
        case file = "file"
        case code = "code"
        case colour = "colour"
        case email = "email"
        case phone = "phone"

        /// SF Symbol name or unicode glyph for this content type.
        var icon: String {
            switch self {
            case .plainText: return "¶"
            case .richText: return "A"
            case .image: return "photo"      // SF Symbol
            case .url: return "link"          // SF Symbol
            case .file: return "doc"          // SF Symbol
            case .code: return "</>"
            case .colour: return "■"
            case .email: return "@"
            case .phone: return "phone"       // SF Symbol
            }
        }

        /// Whether the icon is an SF Symbol (vs. plain text glyph).
        var isSFSymbol: Bool {
            switch self {
            case .image, .url, .file, .phone: return true
            default: return false
            }
        }
    }
}

// MARK: - Sample Data (removed in task 1.4 when wired to ClipsterCore)

extension ClipboardEntry {
    static let samplePinned: [ClipboardEntry] = [
        ClipboardEntry(
            id: "pin-1",
            contentType: .plainText,
            preview: "Plain text snippet that might be quite long and should truncate…",
            sourceApp: "Safari",
            timestamp: Date().addingTimeInterval(-3600),
            isPinned: true
        ),
        ClipboardEntry(
            id: "pin-2",
            contentType: .url,
            preview: "https://example.com/long/url/path/to/resource",
            sourceApp: "Chrome",
            timestamp: Date().addingTimeInterval(-7200),
            isPinned: true
        ),
    ]

    static let sampleHistory: [ClipboardEntry] = [
        ClipboardEntry(
            id: "hist-1",
            contentType: .code,
            preview: "console.log(\"Hello World\");",
            sourceApp: "VS Code",
            timestamp: Date().addingTimeInterval(-600),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-2",
            contentType: .email,
            preview: "example@email.com",
            sourceApp: "Safari",
            timestamp: Date().addingTimeInterval(-1800),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-3",
            contentType: .plainText,
            preview: "Another clipboard entry with some longer text content here",
            sourceApp: "Notes",
            timestamp: Date().addingTimeInterval(-3000),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-4",
            contentType: .url,
            preview: "https://github.com/romeo-folie/clipster",
            sourceApp: "Firefox",
            timestamp: Date().addingTimeInterval(-4200),
            isPinned: false
        ),
    ]
}
