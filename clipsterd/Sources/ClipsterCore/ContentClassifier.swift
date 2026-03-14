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
        if let imgData = imageData(from: pasteboard) {
            // Try to extract a human-readable filename from the pasteboard.
            // Covers: files dragged in, "copy image" from Finder, screenshotted files.
            // Falls back to "[image]" when no file reference is available (e.g. browser
            // screenshot, copy-from-app image).
            let imageName = imageFilename(from: pasteboard) ?? "[image]"
            return ClipboardEntry(
                content: imageName,
                contentType: .image,
                sourceBundle: sourceApp.bundleID,
                sourceName: sourceApp.name,
                sourceConfidence: sourceApp.confidence,
                imageData: imgData       // raw data → thumbnail generated in Database.insert
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

        // 3. Rich text (RTF only — HTML is handled below)
        if let rtf = richText(from: pasteboard) {
            return ClipboardEntry(
                content: rtf,
                contentType: .richText,
                sourceBundle: sourceApp.bundleID,
                sourceName: sourceApp.name,
                sourceConfidence: sourceApp.confidence
            )
        }

        // 3b. HTML without plain-text companion → extract visible text, store as plain text.
        //
        // When an app copies text it usually writes both `public.html` and
        // `public.utf8-plain-text`. Step 4 handles that — we read the plain-text form.
        //
        // When only `public.html` is present (some Electron apps, web clipboards, Google
        // Docs, etc.) we previously stored raw HTML including <meta> tags. Now we strip
        // tags and decode entities so the user always sees readable text in the GUI.
        //
        // If the resulting text is empty (e.g. a purely structural HTML fragment with no
        // visible content) we skip the entry entirely.
        if pasteboard.string(forType: .string) == nil,
           let htmlData = pasteboard.data(forType: .html),
           let rawHTML = String(data: htmlData, encoding: .utf8),
           !rawHTML.isEmpty,
           let plainFromHTML = htmlToPlainText(rawHTML) {
            let textType = classifyText(plainFromHTML)
            return ClipboardEntry(
                content: plainFromHTML,
                contentType: textType,
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

    public static func isURL(_ text: String) -> Bool {
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

    public static func isCode(_ text: String) -> Bool {
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

    private static func imageData(from pb: NSPasteboard) -> Data? {
        // Prefer TIFF (NSPasteboard native), fall back to PNG, then any NSImage-readable UTI.
        if let tiff = pb.data(forType: .tiff), !tiff.isEmpty { return tiff }
        if let png  = pb.data(forType: NSPasteboard.PasteboardType("public.png")), !png.isEmpty { return png }
        for uti in NSImage.imageTypes {
            if let data = pb.data(forType: NSPasteboard.PasteboardType(uti)), !data.isEmpty { return data }
        }
        return nil
    }

    /// Extract the filename of an image from the pasteboard, if a file reference is
    /// present (e.g. copied from Finder, dragged image file). Returns nil when the
    /// clipboard holds raw pixel data only (screenshots, copy-from-browser).
    private static func imageFilename(from pb: NSPasteboard) -> String? {
        // Prefer the public.file-url type which is reliably present for file-backed images.
        if let fileURLString = pb.string(forType: NSPasteboard.PasteboardType("public.file-url")),
           let url = URL(string: fileURLString), url.isFileURL {
            return url.lastPathComponent
        }
        // Fallback: NSURL objects on the pasteboard (e.g. NSFilenamesPboardType bridge).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first(where: { $0.isFileURL }) {
            return first.lastPathComponent
        }
        return nil
    }

    private static func fileURL(from pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let first = urls.first(where: { $0.isFileURL }) else { return nil }
        return first.absoluteString
    }

    // RTF: always extract to plain text via NSAttributedString.
    // HTML is handled separately in classify() — never stored as raw markup.
    private static func richText(from pb: NSPasteboard) -> String? {
        guard let rtfData = pb.data(forType: .rtf),
              let str = NSAttributedString(rtf: rtfData, documentAttributes: nil),
              !str.string.isEmpty else { return nil }
        return str.string
    }

    // Extract visible plain text from an HTML string.
    //
    // Strategy: regex-strip all tags, then decode common HTML entities and
    // normalise whitespace. This is intentionally simple — no WebKit dependency,
    // no threading constraints. Complex nested HTML (tables, lists) will lose
    // structure, but the readable text content is preserved.
    //
    // Used when `public.html` is on the pasteboard but `public.utf8-plain-text`
    // is not (i.e. the app wrote only HTML). Rather than storing raw markup with
    // `<meta charset='utf-8'>` and styling tags, we extract what the user
    // actually sees and store that as plain text.
    static func htmlToPlainText(_ html: String) -> String? {
        // 1. Strip all HTML tags.
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // 2. Decode common HTML entities.
        let entities: [(String, String)] = [
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&#39;",  "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#160;", " "),
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        // 3. Collapse runs of whitespace / newlines to single spaces / newlines.
        //    First: normalize CRLF/CR to LF.
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        //    Second: collapse horizontal whitespace runs (excluding newlines).
        text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        //    Third: collapse blank lines.
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
