import AppKit
import Foundation

/// Classifies a pasteboard change into a typed `ClipboardEntry`.
///
/// PRD §7.1 — all 9 content types, code heuristic, source attribution, source_confidence.
/// This type has no side effects — it reads from `NSPasteboard` and returns a value.
/// Password manager suppression is handled by the caller (ClipboardMonitor).
public enum ContentClassifier {

    // MARK: - Public API

    /// Classify the current NSPasteboard contents into a ClipboardEntry.
    /// Returns `nil` if the pasteboard has no supported content.
    public static func classify(
        pasteboard: NSPasteboard = .general,
        sourceApp: SourceAttribution
    ) -> ClipboardEntry? {

        // Priority order matches PRD §7.1 type detection table.
        // Rich-text / image / file are detected first (UTI-based, unambiguous).
        // Plain-text sub-types (url, code, colour, email, phone) follow.

        // 1. Image
        if let imageData = imageData(from: pasteboard) {
            return ClipboardEntry(
                content: imageData,
                contentType: .image,
                sourceBundle: sourceApp.bundleID,
                sourceName: sourceApp.name,
                sourceConfidence: sourceApp.confidence
            )
        }

        // 2. File URL
        if let fileURL = fileURL(from: pasteboard) {
            return ClipboardEntry(
                content: fileURL,
                contentType: .file,
                sourceBundle: sourceApp.bundleID,
                sourceName: sourceApp.name,
                sourceConfidence: sourceApp.confidence
            )
        }

        // 3. Rich text (RTF or HTML)
        if let rtf = richText(from: pasteboard) {
            return ClipboardEntry(
                content: rtf,
                contentType: .richText,
                sourceBundle: sourceApp.bundleID,
                sourceName: sourceApp.name,
                sourceConfidence: sourceApp.confidence
            )
        }

        // 4. Plain text — further classified into url / code / colour / email / phone / plain-text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }

        let textType = classifyText(text)
        return ClipboardEntry(
            content: text,
            contentType: textType,
            sourceBundle: sourceApp.bundleID,
            sourceName: sourceApp.name,
            sourceConfidence: sourceApp.confidence
        )
    }

    // MARK: - Text sub-classification (PRD §7.1)

    /// Classify a plain-text string into the most specific content type.
    public static func classifyText(_ text: String) -> ContentType {
        if isURL(text)    { return .url }
        if isEmail(text)  { return .email }
        if isPhone(text)  { return .phone }
        if isColour(text) { return .colour }
        if isCode(text)   { return .code }
        return .plainText
    }

    // MARK: - URL detection

    static func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme,
              ["http", "https", "ftp"].contains(scheme.lowercased()),
              url.host != nil else { return false }
        return true
    }

    // MARK: - Email detection (RFC 5322 simplified)

    private static let emailRegex: NSRegularExpression? = {
        // A reasonable practical approximation of RFC 5322
        let pattern = #"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func isEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), trimmed.count <= 254 else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return emailRegex?.firstMatch(in: trimmed, range: range) != nil
    }

    // MARK: - Phone detection (E.164 and common regional formats)

    private static let phoneRegex: NSRegularExpression? = {
        // E.164: +[1-9][0-9]{1,14}
        // Common US/international formats with spaces, dashes, parens
        let pattern = #"^\+?[0-9\s\-\.\(\)]{7,20}$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func isPhone(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return false }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 7 && digits.count <= 15 else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return phoneRegex?.firstMatch(in: trimmed, range: range) != nil
    }

    // MARK: - Colour detection (PRD §7.1 — full-value match only)

    private static let hexColourRegex: NSRegularExpression? = {
        // #RRGGBB or #RRGGBBAA (case insensitive)
        let pattern = #"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let rgbColourRegex: NSRegularExpression? = {
        let pattern = #"^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}(\s*,\s*[\d.]+)?\s*\)$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    private static let hslColourRegex: NSRegularExpression? = {
        let pattern = #"^hsla?\(\s*\d{1,3}\s*,\s*\d{1,3}%\s*,\s*\d{1,3}%(\s*,\s*[\d.]+)?\s*\)$"#
        return try? NSRegularExpression(pattern: pattern)
    }()

    static func isColour(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if hexColourRegex?.firstMatch(in: trimmed, range: range) != nil { return true }
        if rgbColourRegex?.firstMatch(in: trimmed, range: range) != nil { return true }
        if hslColourRegex?.firstMatch(in: trimmed, range: range) != nil { return true }
        return false
    }

    // MARK: - Code detection heuristic (PRD §7.1.1)
    //
    // Fires when ≥2 of 5 signals are detected. Best-effort; false positives accepted.

    static func isCode(_ text: String) -> Bool {
        var signals = 0

        // Signal 1: language keywords
        if containsKeywords(text) { signals += 1 }

        // Signal 2: bracket density
        if hasBracketDensity(text) { signals += 1 }

        // Signal 3: consistent indentation across ≥3 lines
        if hasConsistentIndentation(text) { signals += 1 }

        // Signal 4: shebang line
        if text.hasPrefix("#!/usr/bin/") || text.hasPrefix("#!/usr/local/bin/") { signals += 1 }

        // Signal 5: code operator patterns
        if containsOperators(text) { signals += 1 }

        return signals >= 2
    }

    // Signal 1 — keywords
    private static let keywords: [String] = [
        "function", "def ", "class ", "import ", "return ", "const ", "let ",
        "var ", "fn ", "pub ", "if (", "if(", "else {", "else{",
        "for (", "for(", "while (", "while(",
    ]

    private static func containsKeywords(_ text: String) -> Bool {
        keywords.contains(where: { text.contains($0) })
    }

    // Signal 2 — bracket density: ratio of brackets to total chars
    private static func hasBracketDensity(_ text: String) -> Bool {
        guard text.count >= 20 else { return false }
        let brackets = text.filter { "{}[]()<>".contains($0) }
        return Double(brackets.count) / Double(text.count) > 0.05
    }

    // Signal 3 — consistent indentation
    private static func hasConsistentIndentation(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 3 else { return false }
        let indented = lines.filter { line in
            line.hasPrefix("  ") || line.hasPrefix("\t")
        }
        return indented.count >= 3
    }

    // Signal 5 — operator patterns
    private static let operators: [String] = [
        "=>", "->", "::", "===", "!==", "&&", "||", "??",
    ]

    private static func containsOperators(_ text: String) -> Bool {
        operators.contains(where: { text.contains($0) })
    }

    // MARK: - UTI-based detectors

    private static func imageData(from pb: NSPasteboard) -> String? {
        // We don't store raw image data as String — return a marker and handle
        // the actual JPEG thumbnail creation in ClipboardMonitor (Phase 1 image handling).
        // Returns nil here; image path handled separately.
        return nil  // Placeholder — full image handling in ClipboardMonitor.capture()
    }

    private static func fileURL(from pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let first = urls.first(where: { $0.isFileURL }) else { return nil }
        return first.absoluteString
    }

    private static func richText(from pb: NSPasteboard) -> String? {
        // RTF
        if let rtfData = pb.data(forType: .rtf),
           let str = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            return str.string.isEmpty ? nil : str.string
        }
        // HTML
        if let htmlData = pb.data(forType: .html),
           let html = String(data: htmlData, encoding: .utf8), !html.isEmpty {
            return html
        }
        return nil
    }
}

// MARK: - SourceAttribution

/// Source app attribution captured at debounce-expiry time.
public struct SourceAttribution {
    public let bundleID: String?
    public let name: String?
    public let confidence: SourceConfidence

    public static let unknown = SourceAttribution(bundleID: nil, name: nil, confidence: .high)
}

/// Whether the source app changed during the debounce window.
public enum SourceConfidence: String {
    case high = "high"
    case low  = "low"
}
