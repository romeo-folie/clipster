import Foundation

/// Parsed representation of `~/.config/clipster/config.toml`.
///
/// PRD §7.4 — all fields, defaults, validation.
/// Config is read at daemon startup only. Changes require a daemon restart.
/// Invalid field values produce a log warning and fall back to defaults — the daemon never exits on bad config.
public struct ClipsterConfig: Equatable {

    // MARK: - [history]

    /// Maximum number of history entries. 0 = no count limit (DB size cap still applies).
    /// Valid values: 100, 500, 1000, 0. Invalid values fall back to 500.
    public let entryLimit: Int

    /// Maximum SQLite DB size in MB. Valid values: 100, 250, 500, 1000. Default: 500.
    public let dbSizeCapMB: Int

    // MARK: - [privacy]

    /// Bundle IDs whose clipboard activity is silently suppressed.
    public let suppressBundles: [String]

    // MARK: - [daemon]

    /// Minimum log level. Valid values: "debug", "info", "warn", "error". Default: "info".
    public let logLevel: LogLevel

    // MARK: - Defaults

    public static let `default` = ClipsterConfig(
        entryLimit: 500,
        dbSizeCapMB: 500,
        suppressBundles: [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "com.dashlane.dashlane",
            "com.lastpass.LastPass",
        ],
        logLevel: .info
    )

    // MARK: - Init

    public init(
        entryLimit: Int,
        dbSizeCapMB: Int,
        suppressBundles: [String],
        logLevel: LogLevel
    ) {
        self.entryLimit = entryLimit
        self.dbSizeCapMB = dbSizeCapMB
        self.suppressBundles = suppressBundles
        self.logLevel = logLevel
    }
}

// MARK: - ConfigLoader

/// Loads, validates, and (on first run) creates `~/.config/clipster/config.toml`.
public final class ConfigLoader {

    // MARK: - Path

    public static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("clipster", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    // MARK: - Load

    /// Load config from `configURL`, creating the file with defaults if absent.
    /// Never throws — returns `.default` and logs a warning on any error.
    public static func load() -> ClipsterConfig {
        let url = configURL

        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try createDefault(at: url)
                logger.info("Config: created default config at \(url.path)")
            } catch {
                logger.warn("Config: could not create default config: \(error) — using built-in defaults")
                return .default
            }
        }

        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let config = parse(raw)
            logger.info("Config: loaded from \(url.path)")
            return config
        } catch {
            logger.warn("Config: failed to read \(url.path): \(error) — using built-in defaults")
            return .default
        }
    }

    // MARK: - Parse (minimal TOML)

    /// Parse a minimal TOML string into a ClipsterConfig.
    /// Handles sections, integer values, quoted string values, single-line and
    /// multi-line inline string arrays. Any unrecognised key or invalid value is
    /// ignored (logs a warning; default used).
    public static func parse(_ toml: String) -> ClipsterConfig {
        var entryLimit: Int? = nil
        var dbSizeCapMB: Int? = nil
        var suppressBundles: [String]? = nil
        var logLevel: LogLevel? = nil

        var currentSection = ""

        // Pre-process: collapse multi-line arrays into a single logical line.
        // A multi-line array starts with `key = [` (no closing `]` on that line)
        // and ends at the first line containing `]`.
        let lines = joinMultilineArrays(toml.components(separatedBy: .newlines))

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip blanks and comments
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Section header: [history], [privacy], [daemon]
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.contains("=") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Key = value
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eqIdx]
                .trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eqIdx)...]
                .trimmingCharacters(in: .whitespaces)
                // Strip inline comment after value (only outside string/array context)
                .components(separatedBy: " #").first ?? ""

            switch (currentSection, key) {

            case ("history", "entry_limit"):
                if let v = Int(rawValue) {
                    if [0, 100, 500, 1000].contains(v) {
                        entryLimit = v
                    } else {
                        logger.warn("Config: invalid history.entry_limit '\(rawValue)' — valid: 100, 500, 1000, 0. Using default 500.")
                    }
                } else {
                    logger.warn("Config: history.entry_limit is not an integer: '\(rawValue)' — using default 500.")
                }

            case ("history", "db_size_cap_mb"):
                if let v = Int(rawValue) {
                    if [100, 250, 500, 1000].contains(v) {
                        dbSizeCapMB = v
                    } else {
                        logger.warn("Config: invalid history.db_size_cap_mb '\(rawValue)' — valid: 100, 250, 500, 1000. Using default 500.")
                    }
                } else {
                    logger.warn("Config: history.db_size_cap_mb is not an integer: '\(rawValue)' — using default 500.")
                }

            case ("privacy", "suppress_bundles"):
                // Only attempt array parse if value starts with '['.
                // A non-array value (e.g. a bare string) is invalid — log and use default.
                if rawValue.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                    suppressBundles = parseStringArray(rawValue)
                } else {
                    logger.warn("Config: suppress_bundles is not an array: '\(rawValue)' — using default.")
                }

            case ("daemon", "log_level"):
                let s = unquote(rawValue)
                if let l = LogLevel(rawValue: s.uppercased()) {
                    logLevel = l
                } else {
                    logger.warn("Config: invalid daemon.log_level '\(s)' — valid: debug, info, warn, error. Using default 'info'.")
                }

            default:
                break
            }
        }

        return ClipsterConfig(
            entryLimit:      entryLimit     ?? ClipsterConfig.default.entryLimit,
            dbSizeCapMB:     dbSizeCapMB    ?? ClipsterConfig.default.dbSizeCapMB,
            suppressBundles: suppressBundles ?? ClipsterConfig.default.suppressBundles,
            logLevel:        logLevel        ?? ClipsterConfig.default.logLevel
        )
    }

    // MARK: - Helpers

    /// Parse an inline TOML string array: `["a", "b", "c"]`
    /// Returns an empty array for malformed input.
    public static func parseStringArray(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return [] }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner
            .components(separatedBy: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Collapse multi-line TOML inline arrays into single logical lines.
    /// Input:  ["key = [", "  \"a\",", "  \"b\"", "]"]
    /// Output: ["key = [\"a\",\"b\"]"]
    public static func joinMultilineArrays(_ lines: [String]) -> [String] {
        var result: [String] = []
        var accumulating = false
        var accumulated = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if accumulating {
                // Append non-comment content to the accumulated value
                let content = trimmed.hasPrefix("#") ? "" : trimmed
                accumulated += content
                if trimmed.contains("]") {
                    result.append(accumulated)
                    accumulated = ""
                    accumulating = false
                }
            } else {
                // Check if this line starts a multi-line array (has `[` but no closing `]` on same line)
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    let value = trimmed[trimmed.index(after: eqIdx)...]
                        .trimmingCharacters(in: .whitespaces)
                    let openCount = value.filter { $0 == "[" }.count
                    let closeCount = value.filter { $0 == "]" }.count
                    if openCount > closeCount {
                        accumulating = true
                        accumulated = trimmed.trimmingCharacters(in: .whitespaces)
                        continue
                    }
                }
                result.append(line)
            }
        }

        // Unterminated array — append what we have
        if accumulating { result.append(accumulated) }
        return result
    }

    /// Strip surrounding double quotes from a TOML string value.
    public static func unquote(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("\"") { result = String(result.dropFirst()) }
        if result.hasSuffix("\"") { result = String(result.dropLast()) }
        return result
    }

    // MARK: - Default file creation

    public static func createDefault(at url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try defaultTOML.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Default TOML content

    public static let defaultTOML = """
# Clipster configuration
# Changes take effect after: clipster daemon restart

[history]
entry_limit = 500          # 100 | 500 | 1000 | 0 (no count limit)
db_size_cap_mb = 500       # max DB size in MB: 100 | 250 | 500 | 1000

[privacy]
suppress_bundles = [
  "com.1password.1password",
  "com.bitwarden.desktop",
  "com.dashlane.dashlane",
  "com.lastpass.LastPass"
]

[daemon]
log_level = "info"         # debug | info | warn | error
"""
}
