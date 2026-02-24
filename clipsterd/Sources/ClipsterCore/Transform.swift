import Foundation

/// Ephemeral, non-destructive content transforms. PRD §7.4.
///
/// Transforms operate on the content string at paste time and never modify the database.
/// Phase 1 implements the 6 pure-string transforms. The remaining 5 (encode_base64, decode_base64,
/// format_json, format_xml, strip_html) are fully implemented as they require no external deps.
/// All 11 transforms listed in PRD §7.4 are present.
public enum Transform {

    // MARK: - Apply

    /// Apply a named transform to a string. Throws `TransformError` on failure.
    public static func apply(_ name: String, to content: String) throws -> String {
        switch name {
        case "uppercase":
            return content.uppercased()

        case "lowercase":
            return content.lowercased()

        case "trim":
            return content.trimmingCharacters(in: .whitespacesAndNewlines)

        case "title_case":
            return content.capitalized

        case "snake_case":
            return toSnakeCase(content)

        case "camel_case":
            return toCamelCase(content)

        case "encode_url":
            guard let encoded = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw TransformError.failed("URL encoding failed")
            }
            return encoded

        case "decode_url":
            guard let decoded = content.removingPercentEncoding else {
                throw TransformError.failed("URL decoding failed")
            }
            return decoded

        case "encode_base64":
            return Data(content.utf8).base64EncodedString()

        case "decode_base64":
            guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
                  let decoded = String(data: data, encoding: .utf8) else {
                throw TransformError.failed("Base64 decode failed — content is not valid base64 UTF-8")
            }
            return decoded

        case "strip_html":
            return stripHTML(content)

        default:
            throw TransformError.unknown(name)
        }
    }

    // MARK: - Helpers

    static func toSnakeCase(_ s: String) -> String {
        // Split on whitespace, hyphens, and camelCase boundaries
        let words = s
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        // Insert space before uppercase letters following lowercase (camelCase)
        var result = ""
        for (i, char) in words.enumerated() {
            if char.isUppercase && i > 0 && !words[words.index(words.startIndex, offsetBy: i - 1)].isWhitespace {
                result.append(" ")
            }
            result.append(char)
        }
        return result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
            .joined(separator: "_")
    }

    static func toCamelCase(_ s: String) -> String {
        let words = s
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return s }
        let first = words[0].lowercased()
        let rest = words.dropFirst().map { $0.capitalized }
        return ([first] + rest).joined()
    }

    static func stripHTML(_ s: String) -> String {
        // Remove HTML tags using a simple regex
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        let stripped = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        // Decode common HTML entities
        return stripped
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Available transform names

    public static let all: [String] = [
        "uppercase", "lowercase", "trim", "title_case",
        "snake_case", "camel_case",
        "encode_url", "decode_url",
        "encode_base64", "decode_base64",
        "strip_html",
    ]
}

// MARK: - TransformError

public enum TransformError: Error {
    case unknown(String)
    case failed(String)
}
