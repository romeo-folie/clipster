import AppKit
import CryptoKit
import Foundation
import GRDB

/// SQLite storage layer for Clipster. Write-owner: `clipsterd` exclusively.
///
/// Design notes (PRD §7.2):
/// - WAL mode enabled at initialisation.
/// - Versioned migrations via GRDB's DatabaseMigrator.
/// - Full PRD schema defined in v1 migration even in Phase 0 — avoids
///   schema drift between phases and makes migrations trivially backward-compatible.
/// - The Go CLI (`clipster`) never writes to this database. This is an
///   architectural invariant enforced by design, not a runtime check.
/// - Phase 0: only plain-text entries. Source attribution fields (source_bundle,
///   source_name, source_confidence) are written as NULL / "high" default.
public final class ClipsterDatabase {

    // MARK: - Paths

    /// ~/Library/Application Support/Clipster/history.db
    public static var dbURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let clipsterDir = appSupport.appendingPathComponent("Clipster", isDirectory: true)
        // Directory is created by ensureDirectories() at init — not here to keep this pure.
        return clipsterDir.appendingPathComponent("history.db")
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue

    // MARK: - Stored config

    private let clipsterConfig: ClipsterConfig

    // MARK: - Init

    /// Opens (or creates) the SQLite database, applies migrations, and enables WAL.
    /// - Parameters:
    ///   - url: Override DB path (used in tests). Defaults to the production path.
    ///   - config: Parsed app config. Defaults to `.default`.
    public init(url: URL? = nil, config: ClipsterConfig = .default) throws {
        self.clipsterConfig = config
        let target = url ?? ClipsterDatabase.dbURL
        try Self.ensureParentDirectory(for: target)

        var grdbConfig = Configuration()
        grdbConfig.label = "com.clipster.database"
        // PRAGMA journal_mode=WAL must be set *outside* any transaction.
        // GRDB's prepareDatabase callback runs before migrations and before
        // any transaction is opened — the correct place for this pragma.
        grdbConfig.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }

        dbQueue = try DatabaseQueue(path: target.path, configuration: grdbConfig)
        try applyMigrations()
        logger.info("Database opened at: \(target.path)")
    }

    // MARK: - Migrations

    private func applyMigrations() throws {
        var migrator = DatabaseMigrator()

        // v1 — full PRD §7.2 schema.
        // Even in Phase 0, we create the full schema so Phase 1 never needs
        // a schema migration for columns that were "added later".
        migrator.registerMigration("v1_initial") { db in
            // Note: WAL mode is set in config.prepareDatabase (outside any transaction).
            // It must not be set here as GRDB wraps migrations in a transaction and
            // SQLite forbids changing journal_mode inside a transaction.

            try db.create(table: "entries", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("content_type", .text).notNull()
                t.column("content", .blob).notNull()
                t.column("preview", .text)
                t.column("source_bundle", .text)
                t.column("source_name", .text)
                t.column("source_confidence", .text).notNull().defaults(to: "high")
                t.column("created_at", .integer).notNull()
                t.column("is_pinned", .integer).notNull().defaults(to: 0)
                t.column("content_hash", .text).notNull()
            }

            try db.create(table: "thumbnails", ifNotExists: true) { t in
                t.column("entry_id", .text)
                    .primaryKey()
                    .references("entries", onDelete: .cascade)
                t.column("data", .blob).notNull()
            }

            // Index content_hash for deduplication lookups.
            try db.create(
                index: "idx_entries_created_at",
                on: "entries",
                columns: ["created_at"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_entries_content_hash",
                on: "entries",
                columns: ["content_hash"],
                ifNotExists: true
            )
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Writes

    /// Insert a captured clipboard entry.
    ///
    /// Deduplication: if the most recent entry shares the same content hash,
    /// the write is silently dropped (PRD §7.1 deduplication rule).
    ///
    /// - Throws: `DatabaseError` on SQLite failure.
    public func insert(_ entry: ClipboardEntry) throws {
        let hash = sha256(entry.content)
        let preview = String(entry.content.prefix(200))
        let createdAt = Int64(entry.capturedAt.timeIntervalSince1970 * 1000)

        // Deduplication check — most recent entry only (PRD §7.1).
        // String.fetchOne returns nil when history is empty — not a duplicate.
        let isDuplicate = try dbQueue.read { db -> Bool in
            let latestHash = try String.fetchOne(
                db,
                sql: "SELECT content_hash FROM entries ORDER BY created_at DESC LIMIT 1"
            )
            return latestHash == hash
        }

        if isDuplicate {
            logger.debug("Duplicate content — discarding entry")
            return
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO entries
                        (id, content_type, content, preview,
                         source_bundle, source_name, source_confidence,
                         created_at, is_pinned, content_hash)
                    VALUES
                        (?, ?, ?, ?,
                         ?, ?, ?,
                         ?, 0, ?)
                """,
                arguments: [
                    entry.id,
                    entry.contentType.rawValue,
                    entry.content,
                    preview,
                    entry.sourceBundle,
                    entry.sourceName,
                    entry.sourceConfidence.rawValue,
                    createdAt,
                    hash,
                ]
            )

            // Image thumbnail — PRD §7.1 / AC-CAP-04
            if entry.contentType == .image, let rawData = entry.imageData {
                if let thumb = generateThumbnail(from: rawData) {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO thumbnails (entry_id, data) VALUES (?, ?)",
                        arguments: [entry.id, thumb]
                    )
                } else {
                    logger.warn("Thumbnail generation failed for entry \(entry.id) — storing entry without thumbnail")
                }
            }
        }

        logger.debug("Inserted entry \(entry.id) [\(entry.contentType.rawValue)]")

        // History pruning — PRD §7.2 / AC-DB-01 + AC-DB-02
        try pruneIfNeeded()
    }

    // MARK: - Reads

    /// Count of all entries in history.
    public func entryCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") ?? 0
        }
    }

    /// Paginated history list, newest first. Excludes pinned entries (returned via `listPinned`).
    public func list(limit: Int = 50, offset: Int = 0) throws -> [StoredEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM entries
                    ORDER BY created_at DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return rows.map(StoredEntry.init)
        }
    }

    /// All pinned entries, newest first.
    public func listPinned() throws -> [StoredEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM entries WHERE is_pinned = 1 ORDER BY created_at DESC"
            )
            return rows.map(StoredEntry.init)
        }
    }

    /// The most recently inserted entry, or nil if history is empty.
    public func latestEntry() throws -> StoredEntry? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM entries ORDER BY created_at DESC LIMIT 1"
            )
            return row.map(StoredEntry.init)
        }
    }

    /// Fetch thumbnail JPEG data for an entry, or nil if no thumbnail exists.
    public func thumbnail(for entryID: String) throws -> Data? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT data FROM thumbnails WHERE entry_id = ?",
                arguments: [entryID]
            )
            return row?["data"] as? Data
        }
    }

    /// Find a single entry by ID, or nil if not found.
    public func findEntry(id: String) throws -> StoredEntry? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM entries WHERE id = ?",
                arguments: [id]
            )
            return row.map(StoredEntry.init)
        }
    }

    // MARK: - Writes (clipsterd only — PRD §7.2 write ownership invariant)

    /// Pin or unpin an entry.
    public func setPin(id: String, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entries SET is_pinned = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, id]
            )
        }
    }

    /// Delete a single entry by ID.
    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM entries WHERE id = ?", arguments: [id])
        }
    }

    /// Delete all non-pinned entries. Returns the number of deleted rows.
    public func clearHistory() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM entries WHERE is_pinned = 0")
            return db.changesCount
        }
    }

    // MARK: - Pruning

    /// Enforce entry_limit and db_size_cap_mb after each insert.
    /// Pinned entries are never pruned (PRD §7.2).
    private func pruneIfNeeded() throws {
        let limit = clipsterConfig.entryLimit
        let sizeCap = clipsterConfig.dbSizeCapMB

        var deletedTotal = 0

        // --- Count-based pruning ---
        if limit > 0 {
            let count = try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE is_pinned = 0") ?? 0
            }
            let excess = count - limit
            if excess > 0 {
                let deleted = try dbQueue.write { db -> Int in
                    try db.execute(sql: """
                        DELETE FROM entries
                        WHERE id IN (
                            SELECT id FROM entries
                            WHERE is_pinned = 0
                            ORDER BY created_at ASC
                            LIMIT ?
                        )
                    """, arguments: [excess])
                    return db.changesCount
                }
                deletedTotal += deleted
                logger.debug("Pruned \(deleted) entries (count limit: \(limit))")
            }
        }

        // --- Size-based pruning ---
        if sizeCap > 0 {
            let capBytes = Int64(sizeCap) * 1024 * 1024
            while true {
                let dbSize = try dbQueue.read { db -> Int64 in
                    let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                    let pageSize  = try Int64.fetchOne(db, sql: "PRAGMA page_size")  ?? 4096
                    return pageCount * pageSize
                }
                guard dbSize > capBytes else { break }

                let deleted = try dbQueue.write { db -> Int in
                    try db.execute(sql: """
                        DELETE FROM entries
                        WHERE id IN (
                            SELECT id FROM entries
                            WHERE is_pinned = 0
                            ORDER BY created_at ASC
                            LIMIT 10
                        )
                    """)
                    return db.changesCount
                }
                if deleted == 0 { break }  // only pinned entries left — can't shrink further
                deletedTotal += deleted
            }
            if deletedTotal > 0 {
                logger.debug("Pruned \(deletedTotal) entries total (size cap: \(sizeCap) MB)")
            }
        }

        // --- VACUUM after bulk deletes (threshold: ≥ 10 deletions) ---
        if deletedTotal >= 10 {
            try dbQueue.write { db in try db.execute(sql: "PRAGMA incremental_vacuum(100)") }
        }
    }

    // MARK: - Thumbnail generation

    /// Generate a JPEG thumbnail from raw image data.
    /// - Returns: JPEG data ≤ 2MB with width ≤ 400px, or nil on failure.
    private func generateThumbnail(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }

        let maxWidth: CGFloat = 400
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let targetSize: NSSize
        if originalSize.width > maxWidth {
            let scale = maxWidth / originalSize.width
            targetSize = NSSize(width: maxWidth, height: originalSize.height * scale)
        } else {
            targetSize = originalSize
        }

        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        let maxBytes = 2 * 1024 * 1024
        // Try decreasing quality until ≤ 2MB
        for quality in [0.75, 0.5, 0.3, 0.1] {
            if let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: NSNumber(value: quality)]
            ), jpeg.count <= maxBytes {
                return jpeg
            }
        }
        return nil  // Cannot fit in 2MB even at lowest quality
    }

    // MARK: - Helpers

    private static func ensureParentDirectory(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - StoredEntry

/// A row from the entries table. Minimal — Phase 1 expands to full model.
public struct StoredEntry {
    public let id: String
    public let contentType: String
    public let content: String
    public let preview: String?
    public let sourceBundle: String?
    public let sourceName: String?
    public let sourceConfidence: String
    public let createdAt: Int64
    public let isPinned: Bool
    public let contentHash: String

    // Internal — only called from ClipsterDatabase read methods.
    // Tests access StoredEntry via the public read API, never construct it directly.
    init(row: Row) {
        id               = row["id"] ?? ""
        contentType      = row["content_type"] ?? ""
        content          = row["content"] ?? ""
        preview          = row["preview"]
        sourceBundle     = row["source_bundle"]
        sourceName       = row["source_name"]
        sourceConfidence = row["source_confidence"] ?? "high"
        let createdAtMs: Int64 = row["created_at"] ?? 0
        createdAt        = createdAtMs
        let pinnedInt: Int64 = row["is_pinned"] ?? 0
        isPinned         = pinnedInt != 0
        contentHash      = row["content_hash"] ?? ""
    }
}
