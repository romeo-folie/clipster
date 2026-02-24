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

    // MARK: - Init

    /// Opens (or creates) the SQLite database, applies migrations, and enables WAL.
    /// Throws on any database error.
    public init(url: URL? = nil) throws {
        let target = url ?? ClipsterDatabase.dbURL
        try Self.ensureParentDirectory(for: target)

        var config = Configuration()
        config.label = "com.clipster.database"
        // PRAGMA journal_mode=WAL must be set *outside* any transaction.
        // GRDB's prepareDatabase callback runs before migrations and before
        // any transaction is opened — the correct place for this pragma.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }

        dbQueue = try DatabaseQueue(path: target.path, configuration: config)
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
                         NULL, NULL, 'high',
                         ?, 0, ?)
                """,
                arguments: [
                    entry.id,
                    entry.contentType.rawValue,
                    entry.content,
                    preview,
                    createdAt,
                    hash,
                ]
            )
        }

        logger.debug("Inserted entry \(entry.id) [\(entry.contentType.rawValue)]")
    }

    // MARK: - Reads (Phase 0 minimal — expanded in Phase 1)

    /// Count of entries in history.
    public func entryCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") ?? 0
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
    public let createdAt: Int64
    public let isPinned: Bool
    public let contentHash: String

    // Internal — only called from ClipsterDatabase.latestEntry() and future read methods.
    // Tests access StoredEntry via the public read API, never construct it directly.
    init(row: Row) {
        // All NOT NULL columns use ?? fallbacks for defensive safety.
        // In practice these will never be nil given the schema constraints.
        id          = row["id"] ?? ""
        contentType = row["content_type"] ?? ""
        // content is declared BLOB in schema but stored as TEXT for plain-text entries.
        // SQLite weak typing: GRDB reads it back as String correctly.
        content     = row["content"] ?? ""
        preview     = row["preview"]   // nullable column — String? is correct
        // SQLite INTEGER maps to Int64 — explicit type annotation avoids platform-width
        // ambiguity and makes the GRDB subscript resolve to the right overload.
        let createdAtMs: Int64 = row["created_at"] ?? 0
        createdAt   = createdAtMs
        let pinnedInt: Int64 = row["is_pinned"] ?? 0
        isPinned    = pinnedInt != 0
        contentHash = row["content_hash"] ?? ""
    }
}
