import ClipsterCore
import Foundation
import XCTest

/// Tests for ClipsterDatabase — Phase 0 coverage.
///
/// Uses temp-file databases to avoid side effects. Each test gets its own DB.
final class DatabaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> ClipsterDatabase {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-test-\(UUID().uuidString).db")
        return try ClipsterDatabase(url: tmp)
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
}
