import ClipsterCore
import Foundation
import XCTest

final class ConfigTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ toml: String) -> ClipsterConfig {
        ConfigLoader.parse(toml)
    }

    // MARK: - Default config

    func testDefaultEntryLimit() {
        XCTAssertEqual(ClipsterConfig.default.entryLimit, 500)
    }

    func testDefaultDbSizeCap() {
        XCTAssertEqual(ClipsterConfig.default.dbSizeCapMB, 500)
    }

    func testDefaultLogLevel() {
        XCTAssertEqual(ClipsterConfig.default.logLevel, .info)
    }

    func testDefaultSuppressBundlesContains1Password() {
        XCTAssertTrue(ClipsterConfig.default.suppressBundles.contains("com.1password.1password"))
    }

    // MARK: - Parse: entry_limit

    func testParseEntryLimit100() {
        let config = parse("[history]\nentry_limit = 100")
        XCTAssertEqual(config.entryLimit, 100)
    }

    func testParseEntryLimit0NoCountLimit() {
        let config = parse("[history]\nentry_limit = 0")
        XCTAssertEqual(config.entryLimit, 0)
    }

    func testParseEntryLimit1000() {
        let config = parse("[history]\nentry_limit = 1000")
        XCTAssertEqual(config.entryLimit, 1000)
    }

    func testInvalidEntryLimitFallsBackToDefault() {
        // 999 is not a valid value
        let config = parse("[history]\nentry_limit = 999")
        XCTAssertEqual(config.entryLimit, 500)
    }

    func testNonIntegerEntryLimitFallsBackToDefault() {
        let config = parse("[history]\nentry_limit = notanumber")
        XCTAssertEqual(config.entryLimit, 500)
    }

    // MARK: - Parse: db_size_cap_mb

    func testParseDbSizeCap100() {
        let config = parse("[history]\ndb_size_cap_mb = 100")
        XCTAssertEqual(config.dbSizeCapMB, 100)
    }

    func testParseDbSizeCap1000() {
        let config = parse("[history]\ndb_size_cap_mb = 1000")
        XCTAssertEqual(config.dbSizeCapMB, 1000)
    }

    func testInvalidDbSizeCapFallsBackToDefault() {
        let config = parse("[history]\ndb_size_cap_mb = 750")
        XCTAssertEqual(config.dbSizeCapMB, 500)
    }

    // MARK: - Parse: log_level

    func testParseLogLevelDebug() {
        let config = parse("[daemon]\nlog_level = \"debug\"")
        XCTAssertEqual(config.logLevel, .debug)
    }

    func testParseLogLevelWarn() {
        let config = parse("[daemon]\nlog_level = \"warn\"")
        XCTAssertEqual(config.logLevel, .warn)
    }

    func testParseLogLevelError() {
        let config = parse("[daemon]\nlog_level = \"error\"")
        XCTAssertEqual(config.logLevel, .error)
    }

    func testInvalidLogLevelFallsBackToInfo() {
        let config = parse("[daemon]\nlog_level = \"verbose\"")
        XCTAssertEqual(config.logLevel, .info)
    }

    // MARK: - Parse: suppress_bundles

    func testParseSuppressBundles() {
        let toml = "[privacy]\nsuppress_bundles = [\"com.foo.app\", \"com.bar.app\"]"
        let config = parse(toml)
        XCTAssertEqual(config.suppressBundles, ["com.foo.app", "com.bar.app"])
    }

    func testEmptySupressBundlesArray() {
        let config = parse("[privacy]\nsuppress_bundles = []")
        XCTAssertEqual(config.suppressBundles, [])
    }

    func testMalformedSuppressBundlesFallsBackToDefault() {
        let config = parse("[privacy]\nsuppress_bundles = not-an-array")
        XCTAssertEqual(config.suppressBundles, ClipsterConfig.default.suppressBundles)
    }

    // MARK: - Parse: comments and blanks

    func testCommentsAreIgnored() {
        let toml = """
        # This is a comment
        [history]
        # another comment
        entry_limit = 100
        """
        let config = parse(toml)
        XCTAssertEqual(config.entryLimit, 100)
    }

    func testInlineCommentStripped() {
        let config = parse("[history]\nentry_limit = 100 # compact preset")
        XCTAssertEqual(config.entryLimit, 100)
    }

    func testBlankLinesIgnored() {
        let toml = "\n\n[history]\n\nentry_limit = 1000\n\n"
        let config = parse(toml)
        XCTAssertEqual(config.entryLimit, 1000)
    }

    // MARK: - Parse: full default TOML roundtrip

    func testDefaultTomlParsesCorrectly() {
        let config = parse(ConfigLoader.defaultTOML)
        XCTAssertEqual(config.entryLimit, 500)
        XCTAssertEqual(config.dbSizeCapMB, 500)
        XCTAssertEqual(config.logLevel, .info)
        XCTAssertTrue(config.suppressBundles.contains("com.1password.1password"))
        XCTAssertTrue(config.suppressBundles.contains("com.bitwarden.desktop"))
    }

    // MARK: - Parse: unknown keys ignored

    func testUnknownSectionIgnored() {
        let toml = "[unknown]\nfoo = 123\n[history]\nentry_limit = 100"
        let config = parse(toml)
        XCTAssertEqual(config.entryLimit, 100)
    }

    func testUnknownKeyIgnored() {
        let toml = "[history]\nentry_limit = 100\nunknown_key = true"
        let config = parse(toml)
        XCTAssertEqual(config.entryLimit, 100)
    }

    // MARK: - File creation (unit)

    func testCreatesDefaultFileIfAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-config-test-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        try ConfigLoader.createDefault(at: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let content = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(content.contains("entry_limit = 500"))

        // Cleanup
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    // MARK: - First-run integration (load(at:))

    /// Verifies: when no config file exists, load(at:) creates it and returns the default config.
    func testFirstRunCreatesFileAndReturnsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-firstrun-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "Pre-condition: file must not exist before first run")

        let config = ConfigLoader.load(at: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "load(at:) must create the config file on first run")
        XCTAssertEqual(config, ClipsterConfig.default,
                       "First-run config must equal the static default")
    }

    /// Verifies: the file created on first run contains valid TOML that round-trips to defaults.
    func testFirstRunFileContentIsValidTOML() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-firstrun-toml-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = ConfigLoader.load(at: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        let reparsed = ConfigLoader.parse(raw)
        XCTAssertEqual(reparsed, ClipsterConfig.default,
                       "Default TOML written on first run must parse back to ClipsterConfig.default")
    }

    /// Verifies: when a valid config file already exists, load(at:) reads and honours its values.
    func testLoadReadsExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-existing-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let custom = """
        [history]
        entry_limit = 100
        db_size_cap_mb = 250

        [daemon]
        log_level = "debug"

        [privacy]
        suppress_bundles = ["com.foo.bar"]
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try custom.write(to: url, atomically: true, encoding: .utf8)

        let config = ConfigLoader.load(at: url)
        XCTAssertEqual(config.entryLimit, 100)
        XCTAssertEqual(config.dbSizeCapMB, 250)
        XCTAssertEqual(config.logLevel, .debug)
        XCTAssertEqual(config.suppressBundles, ["com.foo.bar"])
    }

    /// Verifies: load(at:) is idempotent — calling twice returns the same config.
    func testLoadIsIdempotent() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-idempotent-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first  = ConfigLoader.load(at: url)
        let second = ConfigLoader.load(at: url)
        XCTAssertEqual(first, second, "load(at:) must be idempotent")
    }

    // MARK: - Multi-line array

    func testMultilineSupressBundlesParsed() {
        let toml = """
        [privacy]
        suppress_bundles = [
          "com.foo.app",
          "com.bar.app"
        ]
        """
        let config = parse(toml)
        XCTAssertEqual(config.suppressBundles, ["com.foo.app", "com.bar.app"])
    }

    func testDefaultTomlMultilineArrayParsesCorrectly() {
        // The default TOML uses multi-line suppress_bundles — ensure it round-trips.
        let config = parse(ConfigLoader.defaultTOML)
        XCTAssertTrue(config.suppressBundles.contains("com.1password.1password"))
        XCTAssertTrue(config.suppressBundles.contains("com.lastpass.LastPass"))
        XCTAssertEqual(config.suppressBundles.count, 4)
    }

    // MARK: - parseStringArray

    func testParseStringArraySingleItem() {
        XCTAssertEqual(ConfigLoader.parseStringArray("[\"com.foo.app\"]"), ["com.foo.app"])
    }

    func testParseStringArrayMultipleItems() {
        let result = ConfigLoader.parseStringArray("[\"a\", \"b\", \"c\"]")
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func testParseStringArrayEmptyReturnsEmpty() {
        XCTAssertEqual(ConfigLoader.parseStringArray("[]"), [])
    }

    func testParseStringArrayMissingBracketsReturnsEmpty() {
        XCTAssertEqual(ConfigLoader.parseStringArray("\"a\", \"b\""), [])
    }

    // MARK: - unquote

    func testUnquoteStripsDoubleQuotes() {
        XCTAssertEqual(ConfigLoader.unquote("\"hello\""), "hello")
    }

    func testUnquoteNoQuotesUnchanged() {
        XCTAssertEqual(ConfigLoader.unquote("hello"), "hello")
    }
}
