import ClipsterCore
import Foundation
import XCTest

/// Tests for ClipsterDatabase — Phase 0 coverage.
///
/// Uses temp-file databases to avoid side effects. Each test gets its own DB.
final class DatabaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB(config: ClipsterConfig = .default) throws -> ClipsterDatabase {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-test-\(UUID().uuidString).db")
        return try ClipsterDatabase(url: tmp, config: config)
    }

    private func entry(
        content: String = "Hello, world!",
        type: ContentType = .plainText
    ) -> ClipboardEntry {
        ClipboardEntry(content: content, contentType: type)
    }

    // MARK: - Schema

    func testOpenAndMigrate() throws {
        _ = try makeDB()
    }

    func testEmptyCount() throws {
        let db = try makeDB()
        XCTAssertEqual(try db.entryCount(), 0)
    }

    func testLatestOnEmpty() throws {
        let db = try makeDB()
        XCTAssertNil(try db.latestEntry())
    }

    // MARK: - Insert

    func testInsertPlainText() throws {
        let db = try makeDB()
        try db.insert(entry())
        XCTAssertEqual(try db.entryCount(), 1)
    }

    func testInsertedIsLatest() throws {
        let db = try makeDB()
        let e = entry(content: "clipboard-test-\(UUID().uuidString)")
        try db.insert(e)

        let stored = try db.latestEntry()
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.content, e.content)
        XCTAssertEqual(stored?.contentType, e.contentType.rawValue)
    }

    func testPreviewTruncation() throws {
        let db = try makeDB()
        let long = String(repeating: "x", count: 500)
        try db.insert(entry(content: long))

        let stored = try db.latestEntry()
        XCTAssertLessThanOrEqual(stored?.preview?.count ?? Int.max, 200)
    }

    // MARK: - Deduplication

    func testDeduplicationDropsConsecutiveDuplicate() throws {
        let db = try makeDB()
        let e = entry(content: "dup-test")
        try db.insert(e)
        try db.insert(e)  // same content — must be dropped
        XCTAssertEqual(try db.entryCount(), 1)
    }

    func testDeduplicationDoesNotBlockDifferentContent() throws {
        let db = try makeDB()
        try db.insert(entry(content: "first"))
        try db.insert(entry(content: "second"))
        XCTAssertEqual(try db.entryCount(), 2)
    }

    func testDeduplicationOnlyChecksLatestEntry() throws {
        let db = try makeDB()
        try db.insert(entry(content: "A"))
        try db.insert(entry(content: "B"))
        // "A" is no longer the most recent — re-inserting it must succeed
        try db.insert(entry(content: "A"))
        XCTAssertEqual(try db.entryCount(), 3)
    }

    // MARK: - IDs and timestamps

    func testUniqueIDs() throws {
        let db = try makeDB()
        // If IDs collide the second insert raises a PRIMARY KEY violation
        try db.insert(entry(content: "alpha"))
        try db.insert(entry(content: "beta"))
        XCTAssertEqual(try db.entryCount(), 2)
    }

    func testCreatedAtIsApproximatelyNow() throws {
        let db = try makeDB()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try db.insert(entry())
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let stored = try db.latestEntry()
        guard let ts = stored?.createdAt else {
            return XCTFail("No stored entry found")
        }
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, after + 200)  // 200ms slop
    }

    func testIsPinnedDefaultsFalse() throws {
        let db = try makeDB()
        try db.insert(entry())
        let stored = try db.latestEntry()
        XCTAssertEqual(stored?.isPinned, false)
    }

    // MARK: - Content hash

    func testContentHashIsConsistent() throws {
        let db = try makeDB()
        let content = "hash-me-\(UUID().uuidString)"
        try db.insert(entry(content: content))

        let stored = try db.latestEntry()
        XCTAssertNotNil(stored?.contentHash)
        XCTAssertFalse(stored?.contentHash.isEmpty ?? true)
    }

    // MARK: - Pruning: entry_limit

    func testEntryLimitPrunesOldestUnpinned() throws {
        let config = ClipsterConfig(
            entryLimit: 3,
            dbSizeCapMB: 0,     // disable size pruning for this test
            suppressBundles: [],
            logLevel: .error
        )
        let db = try makeDB(config: config)

        try db.insert(entry(content: "A"))
        try db.insert(entry(content: "B"))
        try db.insert(entry(content: "C"))
        try db.insert(entry(content: "D"))  // triggers prune — A should be removed

        XCTAssertEqual(try db.entryCount(), 3)
        let entries = try db.list(limit: 10)
        let contents = entries.map(\.content)
        XCTAssertFalse(contents.contains("A"), "Oldest entry 'A' should be pruned")
        XCTAssertTrue(contents.contains("D"), "Newest entry 'D' must be retained")
    }

    func testEntryLimitZeroMeansNoCountPruning() throws {
        let config = ClipsterConfig(
            entryLimit: 0,      // no count limit
            dbSizeCapMB: 0,
            suppressBundles: [],
            logLevel: .error
        )
        let db = try makeDB(config: config)

        for i in 0..<20 {
            try db.insert(entry(content: "item-\(i)"))
        }
        XCTAssertEqual(try db.entryCount(), 20)
    }

    func testPinnedEntriesSurvivePruning() throws {
        let config = ClipsterConfig(
            entryLimit: 2,
            dbSizeCapMB: 0,
            suppressBundles: [],
            logLevel: .error
        )
        let db = try makeDB(config: config)

        try db.insert(entry(content: "pinned-item"))
        let pinned = try db.latestEntry()
        XCTAssertNotNil(pinned)
        try db.setPin(id: pinned!.id, pinned: true)

        // Insert 3 more to trigger pruning past the limit
        try db.insert(entry(content: "X"))
        try db.insert(entry(content: "Y"))
        try db.insert(entry(content: "Z"))

        // Pinned entry must survive
        let all = try db.list(limit: 100)
        let pins = try db.listPinned()
        XCTAssertEqual(pins.count, 1)
        XCTAssertTrue(all.map(\.content).contains("Z") || pins.map(\.content).contains("pinned-item"))
    }
}
