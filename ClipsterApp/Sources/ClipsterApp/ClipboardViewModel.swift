import ClipsterCore
import SwiftUI

/// View model for the clipboard panel. Reads from ClipsterCore's SQLite database
/// and refreshes periodically. Falls back to sample data if the database is unavailable.
final class ClipboardViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var selectedID: String?
    @Published var pinnedEntries: [ClipboardEntry] = []
    @Published var historyEntries: [ClipboardEntry] = []
    @Published var databaseAvailable = false

    private var db: ClipsterDatabase?
    private var refreshTimer: Timer?

    init() {
        openDatabase()
        refresh()
        startAutoRefresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Filtering

    var filteredPinned: [ClipboardEntry] {
        guard !searchQuery.isEmpty else { return pinnedEntries }
        let q = searchQuery.lowercased()
        return pinnedEntries.filter { $0.preview.lowercased().contains(q) }
    }

    var filteredHistory: [ClipboardEntry] {
        guard !searchQuery.isEmpty else { return historyEntries }
        let q = searchQuery.lowercased()
        return historyEntries.filter { $0.preview.lowercased().contains(q) }
    }

    // MARK: - Write Actions (all writes go through IPC to clipsterd)

    /// Toggle pin state. Sends pin/unpin via IPC to preserve clipsterd's sole-write-owner invariant.
    func togglePin(id: String) {
        let isPinned = pinnedEntries.contains(where: { $0.id == id })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if isPinned {
                    try IPCClient.unpin(id: id)
                } else {
                    try IPCClient.pin(id: id)
                }
                self?.refresh()
            } catch {
                // IPC failed (daemon not running) — silently ignore.
            }
        }
    }

    /// Appends the app name/bundle to the suppress list in the daemon config.
    /// Takes effect on next daemon restart. Writes to ~/.config/clipster/config.ini.
    func suppressApp(bundleOrName: String) {
        guard !bundleOrName.isEmpty, bundleOrName != "Unknown" else { return }
        let configURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clipster/config.ini")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        // Avoid duplicates.
        if contents.contains(bundleOrName) { return }
        // Append to [privacy] section if present, otherwise append at end.
        var updated = contents
        if let range = contents.range(of: "suppress_bundles = [") {
            // Insert before the closing bracket.
            if let closeRange = contents.range(of: "]", range: range.upperBound..<contents.endIndex) {
                updated.insert(contentsOf: "\n    \"\(bundleOrName)\",", at: closeRange.lowerBound)
            }
        }
        try? updated.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func deleteEntry(id: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try IPCClient.delete(id: id)
                self?.refresh()
            } catch {
                // IPC failed — silently ignore.
            }
        }
    }

    // MARK: - Database

    private func openDatabase() {
        do {
            // Open read-only against the daemon's database.
            db = try ClipsterDatabase()
            databaseAvailable = true
        } catch {
            db = nil
            databaseAvailable = false
            // Load sample data as fallback.
            pinnedEntries = ClipboardEntry.samplePinned
            historyEntries = ClipboardEntry.sampleHistory
        }
    }

    func refresh() {
        guard let db = db else { return }
        // DB reads happen on a background queue; UI updates are dispatched to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let pinned = try db.listPinned()
                let history = try db.list(limit: 200)
                DispatchQueue.main.async {
                    self?.pinnedEntries = pinned.map { ClipboardEntry(from: $0, isPinned: true) }
                    self?.historyEntries = history
                        .filter { !$0.isPinned }
                        .map { ClipboardEntry(from: $0, isPinned: false) }
                }
            } catch {
                // Refresh failed — keep existing data.
            }
        }
    }

    private func startAutoRefresh() {
        // Poll every 2 seconds for new entries. The timer fires on the main RunLoop
        // but refresh() dispatches work to a background queue.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}

// MARK: - StoredEntry → ClipboardEntry Conversion

extension ClipboardEntry {
    init(from stored: ClipsterCore.StoredEntry, isPinned: Bool) {
        self.id = stored.id
        self.contentType = ContentType.from(stored.contentType)
        self.preview = stored.preview ?? stored.content
        self.sourceApp = stored.sourceName ?? "Unknown"
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(stored.createdAt))
        self.isPinned = isPinned
    }
}

extension ClipboardEntry.ContentType {
    static func from(_ raw: String) -> Self {
        switch raw {
        case "plain-text": return .plainText
        case "rich-text": return .richText
        case "image": return .image
        case "url": return .url
        case "file": return .file
        case "code": return .code
        case "colour": return .colour
        case "email": return .email
        case "phone": return .phone
        default: return .plainText
        }
    }
}
