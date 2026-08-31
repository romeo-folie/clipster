import ClipsterCore
import Foundation
import GRDB
import XCTest
#if canImport(AppKit)
import AppKit
#endif

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

    func testReadOnlyConnectionSeesExistingAndNewEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-read-only-test-\(UUID().uuidString).db")
        let writer = try ClipsterDatabase(url: url)
        try writer.insert(entry(content: "existing"))

        let reader = try ClipsterDatabase(url: url, accessMode: .readOnly)
        XCTAssertEqual(try reader.list(limit: 10).map(\.content), ["existing"])

        try writer.insert(entry(content: "new"))
        XCTAssertEqual(try reader.list(limit: 10).map(\.content), ["new", "existing"])
    }

    func testReadOnlyConnectionOpensAfterWriterCloses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-read-only-closed-writer-\(UUID().uuidString).db")
        var writer: ClipsterDatabase? = try ClipsterDatabase(url: url)
        try writer?.insert(entry(content: "persisted WAL entry"))
        writer = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-shm"))
        let reader = try ClipsterDatabase(url: url, accessMode: .readOnly)
        XCTAssertEqual(try reader.latestEntry()?.content, "persisted WAL entry")
    }

    func testReadOnlyConnectionRejectsWrites() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-read-only-test-\(UUID().uuidString).db")
        let writer = try ClipsterDatabase(url: url)
        let reader = try ClipsterDatabase(url: url, accessMode: .readOnly)

        XCTAssertThrowsError(try reader.insert(entry(content: "must not be written"))) { error in
            guard let databaseError = error as? DatabaseError else {
                return XCTFail("Expected a GRDB DatabaseError, got \(error)")
            }
            XCTAssertEqual(databaseError.resultCode, .SQLITE_READONLY)
        }

        XCTAssertEqual(try writer.entryCount(), 0)
    }

    func testReadOnlyConnectionDoesNotCreateMissingDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-read-only-missing-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("history.db")

        XCTAssertThrowsError(try ClipsterDatabase(url: url, accessMode: .readOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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

    func testDeduplicationRefreshesNonConsecutiveDuplicate() throws {
        let db = try makeDB()
        try db.insert(entry(content: "A"))
        try db.insert(entry(content: "B"))
        try db.insert(entry(content: "A"))
        XCTAssertEqual(try db.entryCount(), 2)
        XCTAssertEqual(try db.latestEntry()?.content, "A")
    }

    func testDeduplicationPreservesStableIDAndPinState() throws {
        let db = try makeDB()
        try db.insert(entry(content: "keep-me"))
        guard let original = try db.latestEntry() else {
            return XCTFail("Expected inserted entry")
        }
        try db.setPin(id: original.id, pinned: true)

        try db.insert(entry(content: "other"))
        try db.insert(entry(content: "keep-me"))

        XCTAssertEqual(try db.entryCount(), 2)
        XCTAssertEqual(try db.latestEntry()?.id, original.id)
        XCTAssertEqual(try db.listPinned().first?.id, original.id)
    }

    func testDeduplicationCollapsesLegacyRowsAndPreservesPinnedCanonicalEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipster-test-\(UUID().uuidString).db")
        let db = try ClipsterDatabase(url: url)
        try db.insert(entry(content: "legacy-duplicate"))
        guard let original = try db.latestEntry() else {
            return XCTFail("Expected inserted entry")
        }
        try db.setPin(id: original.id, pinned: true)

        // Seed a row shaped like history created by the old latest-only policy.
        let rawDB = try DatabaseQueue(path: url.path)
        try rawDB.write { database in
            try database.execute(
                sql: """
                    INSERT INTO entries
                        (id, content_type, content, preview, source_confidence,
                         created_at, is_pinned, content_hash)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                """,
                arguments: [
                    "legacy-copy",
                    original.contentType,
                    original.content,
                    original.preview,
                    original.sourceConfidence,
                    original.createdAt + 1,
                    original.contentHash,
                ]
            )
        }
        XCTAssertEqual(try db.entryCount(), 2)

        try db.insert(entry(content: "legacy-duplicate"))

        XCTAssertEqual(try db.entryCount(), 1)
        XCTAssertEqual(try db.latestEntry()?.id, original.id)
        XCTAssertEqual(try db.listPinned().first?.id, original.id)
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

    // MARK: - Expiry sweep (PRD §7.2.1 / §7.3.7)

    /// AC-EXP-01: Entries older than 30 days are deleted by the sweep.
    func testExpirySweepDeletesOldEntries() throws {
        let db = try makeDB()
        // Backdate to 31 days ago
        let old = entry(content: "old-entry")
        let backdated = ClipboardEntry(
            id: old.id,
            content: old.content,
            contentType: old.contentType,
            capturedAt: Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))
        )
        try db.insert(backdated)
        XCTAssertEqual(try db.entryCount(), 1)

        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 1, "Sweep must delete the 31-day-old entry")
        XCTAssertEqual(try db.entryCount(), 0)
    }

    /// AC-EXP-02: Entries younger than 30 days are NOT deleted (strict < cutoff).
    /// Uses 30 days - 1 second to stay robustly inside the retention window regardless
    /// of test execution timing. A concurrent boundary test would be flaky.
    func testExpirySweepSpares30DayBoundary() throws {
        let db = try makeDB()
        let recent = ClipboardEntry(
            content: "boundary-entry",
            contentType: .plainText,
            capturedAt: Date(timeIntervalSinceNow: -(30 * 24 * 60 * 60 - 1))  // 30d minus 1s
        )
        try db.insert(recent)
        XCTAssertEqual(try db.entryCount(), 1)

        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 0, "Entry younger than 30 days must not be deleted")
        XCTAssertEqual(try db.entryCount(), 1)
    }

    /// AC-EXP-03: Pinned entries older than 30 days are NOT deleted.
    func testExpirySweepSparesPinnedEntries() throws {
        let db = try makeDB()
        let old = ClipboardEntry(
            content: "pinned-old",
            contentType: .plainText,
            capturedAt: Date(timeIntervalSinceNow: -(60 * 24 * 60 * 60))
        )
        try db.insert(old)
        guard let stored = try db.latestEntry() else {
            return XCTFail("Entry not found after insert")
        }
        try db.setPin(id: stored.id, pinned: true)

        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 0, "Pinned entries must be exempt from expiry")
        let pins = try db.listPinned()
        XCTAssertEqual(pins.count, 1, "Pinned entry must still exist after sweep")
        XCTAssertEqual(pins.first?.content, "pinned-old")
    }

    /// AC-EXP-04: Periodic sweeps continue to clean up newly expired entries.
    func testExpirySweepIsIdempotentAndPeriodicallyCleansNewlyExpired() throws {
        let db = try makeDB()

        // First sweep on an empty database
        XCTAssertEqual(try db.expirySweep(), 0)

        // Insert a fresh entry — should survive sweep
        let fresh = ClipboardEntry(content: "fresh", contentType: .plainText)
        try db.insert(fresh)
        XCTAssertEqual(try db.expirySweep(), 0, "Fresh entry must survive second sweep")
        XCTAssertEqual(try db.entryCount(), 1)

        // Insert an old entry — should be deleted on the next sweep
        let old = ClipboardEntry(
            content: "newly-expired",
            contentType: .plainText,
            capturedAt: Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))
        )
        try db.insert(old)
        XCTAssertEqual(try db.entryCount(), 2)
        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 1, "Third sweep must delete only the newly expired entry")
        XCTAssertEqual(try db.entryCount(), 1)
    }

    /// AC-EXP-05: Sweep returns count of deleted entries (positive case).
    func testExpirySweepReturnsDeletedCount() throws {
        let db = try makeDB()
        for i in 0..<5 {
            let e = ClipboardEntry(
                content: "old-\(i)",
                contentType: .plainText,
                capturedAt: Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60))
            )
            try db.insert(e)
        }
        XCTAssertEqual(try db.entryCount(), 5)
        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 5, "Sweep must report correct delete count")
        XCTAssertEqual(try db.entryCount(), 0)
    }

    /// AC-EXP-06: Sweep returns 0 when no entries are expired.
    func testExpirySweepReturnsZeroWhenNothingExpired() throws {
        let db = try makeDB()
        // Insert recent entries only
        try db.insert(entry(content: "recent-A"))
        try db.insert(entry(content: "recent-B"))

        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 0, "No entries should be deleted when all are recent")
        XCTAssertEqual(try db.entryCount(), 2)
    }

    /// AC-EXP-07: Thumbnails for expired entries are cascade-deleted.
    /// Requires AppKit for NSImage/NSBitmapImageRep; skipped on non-AppKit platforms.
    func testExpirySweepCascadesDeleteToThumbnails() throws {
        #if canImport(AppKit)
        let db = try makeDB()

        // Build a 1×1 JPEG to satisfy the image entry path
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.red.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let jpegData = bmp.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Could not create test JPEG data")
        }

        let imageEntry = ClipboardEntry(
            content: "image-content",
            contentType: .image,
            capturedAt: Date(timeIntervalSinceNow: -(31 * 24 * 60 * 60)),
            imageData: jpegData
        )
        try db.insert(imageEntry)

        // Confirm thumbnail was stored
        let thumbBefore = try db.thumbnail(for: imageEntry.id)
        XCTAssertNotNil(thumbBefore, "Thumbnail must exist before sweep")

        let deleted = try db.expirySweep()
        XCTAssertEqual(deleted, 1, "Expired image entry must be deleted")

        // ON DELETE CASCADE must have removed the thumbnail row
        let thumbAfter = try db.thumbnail(for: imageEntry.id)
        XCTAssertNil(thumbAfter, "Thumbnail must be cascade-deleted with the entry")
        #else
        throw XCTSkip("AC-EXP-07 requires AppKit — skipped on non-AppKit platforms")
        #endif
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
