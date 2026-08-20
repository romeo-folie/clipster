import Foundation

/// Represents a clipboard entry for display in the panel.
struct ClipboardEntry: Identifiable {
    let id: String
    let contentType: ContentType
    let content: String   // Full original clipboard content (for paste/copy)
    let preview: String   // Truncated display text
    let sourceApp: String
    let timestamp: Date
    let isPinned: Bool

    /// Content type determines the icon shown in each row.
    enum ContentType: String, Hashable {
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

        /// User-facing keywords that make text search useful even when an entry's
        /// preview does not contain a category name (notably image entries).
        var searchTerms: [String] {
            switch self {
            case .plainText: return ["text", "plain text"]
            case .richText: return ["text", "rich text", "rtf"]
            case .image: return ["image", "images", "photo", "picture", "pic"]
            case .url: return ["url", "link", "website"]
            case .file: return ["file", "document"]
            case .code: return ["code", "snippet"]
            case .colour: return ["colour", "color", "hex", "rgb", "hsl"]
            case .email: return ["email", "mail"]
            case .phone: return ["phone", "telephone", "tel", "number"]
            }
        }
    }
}

/// A single-select content scope that composes with the free-text search field.
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case text
    case links
    case images
    case colors
    case code
    case email
    case phone
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .colors: return "Colors"
        case .code: return "Code"
        case .email: return "Email"
        case .phone: return "Phone"
        case .files: return "Files"
        }
    }

    func contains(_ contentType: ClipboardEntry.ContentType) -> Bool {
        switch self {
        case .all: return true
        case .text: return contentType == .plainText || contentType == .richText
        case .links: return contentType == .url
        case .images: return contentType == .image
        case .colors: return contentType == .colour
        case .code: return contentType == .code
        case .email: return contentType == .email
        case .phone: return contentType == .phone
        case .files: return contentType == .file
        }
    }
}

// MARK: - Sample Data (removed in task 1.4 when wired to ClipsterCore)

extension ClipboardEntry {
    static let samplePinned: [ClipboardEntry] = [
        ClipboardEntry(
            id: "pin-1",
            contentType: .plainText,
            content: "Plain text snippet that might be quite long and should truncate…",
            preview: "Plain text snippet that might be quite long and should truncate…",
            sourceApp: "Safari",
            timestamp: Date().addingTimeInterval(-3600),
            isPinned: true
        ),
        ClipboardEntry(
            id: "pin-2",
            contentType: .url,
            content: "https://example.com/long/url/path/to/resource",
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
            content: "console.log(\"Hello World\");",
            preview: "console.log(\"Hello World\");",
            sourceApp: "VS Code",
            timestamp: Date().addingTimeInterval(-600),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-2",
            contentType: .email,
            content: "example@email.com",
            preview: "example@email.com",
            sourceApp: "Safari",
            timestamp: Date().addingTimeInterval(-1800),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-3",
            contentType: .plainText,
            content: "Another clipboard entry with some longer text content here",
            preview: "Another clipboard entry with some longer text content here",
            sourceApp: "Notes",
            timestamp: Date().addingTimeInterval(-3000),
            isPinned: false
        ),
        ClipboardEntry(
            id: "hist-4",
            contentType: .url,
            content: "https://github.com/romeo-folie/clipster",
            preview: "https://github.com/romeo-folie/clipster",
            sourceApp: "Firefox",
            timestamp: Date().addingTimeInterval(-4200),
            isPinned: false
        ),
    ]
}
