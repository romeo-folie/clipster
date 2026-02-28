import ClipsterCore
import Combine
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

    // MARK: - Actions

    func togglePin(id: String) {
        guard let db = db else { return }
        do {
            if let entry = try db.findEntry(id: id) {
                try db.setPin(id: id, pinned: !entry.isPinned)
                refresh()
            }
        } catch {
            // Pin toggle failed — silently ignore for now.
        }
    }

    func deleteEntry(id: String) {
        guard let db = db else { return }
        do {
            try db.delete(id: id)
            refresh()
        } catch {
            // Delete failed — silently ignore.
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
        do {
            let pinned = try db.listPinned()
            let history = try db.list(limit: 200)

            DispatchQueue.main.async { [weak self] in
                self?.pinnedEntries = pinned.map { ClipboardEntry(from: $0, isPinned: true) }
                self?.historyEntries = history
                    .filter { !$0.isPinned }
                    .map { ClipboardEntry(from: $0, isPinned: false) }
            }
        } catch {
            // Refresh failed — keep existing data.
        }
    }

    private func startAutoRefresh() {
        // Poll every 2 seconds for new clipboard entries.
        // In a future iteration this could use IPC notifications from the daemon.
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
