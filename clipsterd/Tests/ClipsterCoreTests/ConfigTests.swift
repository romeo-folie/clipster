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

    // MARK: - File creation

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

    /// AC-CFG-01: config created with defaults on fresh install contains all required fields.
    func testCreatedConfigContainsAllRequiredFields() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-config-allkeys-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try ConfigLoader.createDefault(at: tmp)
        let content = try String(contentsOf: tmp, encoding: .utf8)

        // All sections present
        XCTAssertTrue(content.contains("[history]"), "Missing [history] section")
        XCTAssertTrue(content.contains("[privacy]"), "Missing [privacy] section")
        XCTAssertTrue(content.contains("[daemon]"), "Missing [daemon] section")

        // All keys present
        XCTAssertTrue(content.contains("entry_limit"), "Missing entry_limit key")
        XCTAssertTrue(content.contains("db_size_cap_mb"), "Missing db_size_cap_mb key")
        XCTAssertTrue(content.contains("suppress_bundles"), "Missing suppress_bundles key")
        XCTAssertTrue(content.contains("log_level"), "Missing log_level key")

        // Default password manager bundle IDs present
        XCTAssertTrue(content.contains("com.1password.1password"), "Missing 1Password bundle ID")
        XCTAssertTrue(content.contains("com.bitwarden.desktop"), "Missing Bitwarden bundle ID")

        // All config fields parse correctly to expected defaults
        let config = ConfigLoader.parse(content)
        XCTAssertEqual(config.entryLimit, 500)
        XCTAssertEqual(config.dbSizeCapMB, 500)
        XCTAssertEqual(config.logLevel, .info)
        XCTAssertEqual(config.suppressBundles.count, 4)
    }

    /// AC-CFG-01: createDefault is idempotent — calling it a second time does not throw
    /// (the file already exists; callers guard with fileExists but createDefault itself must not corrupt it).
    func testCreateDefaultIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-config-idempotent-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }

        try ConfigLoader.createDefault(at: tmp)
        let firstContent = try String(contentsOf: tmp, encoding: .utf8)

        // Write again (simulates a race or double-call)
        try ConfigLoader.createDefault(at: tmp)
        let secondContent = try String(contentsOf: tmp, encoding: .utf8)

        XCTAssertEqual(firstContent, secondContent)
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
