import AppKit
import ClipsterCore
import SwiftUI

/// View model for the clipboard panel. Reads from ClipsterCore's SQLite database
/// and refreshes periodically. Falls back to sample data if the database is unavailable.
final class ClipboardViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var selectedID: String?
    @Published var showTransformPanel = false
    @Published var pinnedEntries: [ClipboardEntry] = []
    @Published var historyEntries: [ClipboardEntry] = []
    @Published var databaseAvailable = false

    private var db: ClipsterDatabase?
    private var refreshTimer: Timer?
    private let rowThumbnailCache = NSCache<NSString, NSImage>()
    private let expandedPreviewCache = NSCache<NSString, NSImage>()

    init() {
        rowThumbnailCache.countLimit = 400
        expandedPreviewCache.countLimit = 200
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
        return pinnedEntries.filter { matches($0, query: q) }
    }

    var filteredHistory: [ClipboardEntry] {
        guard !searchQuery.isEmpty else { return historyEntries }
        let q = searchQuery.lowercased()
        return historyEntries.filter { matches($0, query: q) }
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

    /// Suppress app via IPC. Adds the bundle/name to clipsterd's runtime suppress list.
    func suppressApp(bundleOrName: String) {
        guard !bundleOrName.isEmpty, bundleOrName != "Unknown" else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try IPCClient.send("suppress", params: IPCParams(entryID: bundleOrName))
            } catch {
                // IPC failed — daemon may not be running.
            }
        }
    }

    /// Fetch thumbnail JPEG data for an image entry, or nil if unavailable.
    func thumbnailData(for id: String) -> Data? {
        try? db?.thumbnail(for: id)
    }

    /// Fetch small image used in list-row icon slot (fast path).
    func rowThumbnailImage(for id: String) -> NSImage? {
        let key = id as NSString
        if let cached = rowThumbnailCache.object(forKey: key) {
            return cached
        }
        guard let data = thumbnailData(for: id),
              let image = ImageThumbnailer.makeThumbnail(from: data, maxSide: 56) else {
            return nil
        }
        rowThumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Fetch larger image for expanded preview pane (avoid upscaling tiny row thumb).
    func expandedPreviewImage(for id: String) -> NSImage? {
        let key = id as NSString
        if let cached = expandedPreviewCache.object(forKey: key) {
            return cached
        }
        guard let data = thumbnailData(for: id),
              let image = ImageThumbnailer.makeThumbnail(from: data, maxSide: 220) else {
            return nil
        }
        expandedPreviewCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Search

    /// Returns true if an entry matches the search query.
    /// Matches against preview text AND content type keyword so that typing
    /// "image", "url", "code" etc. filters by category regardless of display text.
    private func matches(_ entry: ClipboardEntry, query: String) -> Bool {
        if entry.preview.lowercased().contains(query) { return true }
        if entry.contentType.rawValue.lowercased().contains(query) { return true }
        // Also allow friendly aliases: "link" → url, "pic"/"photo" → image.
        switch query {
        case "link":          return entry.contentType == .url
        case "pic", "photo":  return entry.contentType == .image
        case "text":          return entry.contentType == .plainText
        case "colour", "color": return entry.contentType == .colour
        default:              return false
        }
    }

    // MARK: - Thumbnail prefetch

    /// Pre-warm the row thumbnail cache for all image entries so rows display
    /// immediately without a visible async delay when they first appear.
    private func prefetchThumbnails(for entries: [ClipboardEntry]) {
        let imageEntries = entries.filter { $0.contentType == .image }
        guard !imageEntries.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for entry in imageEntries {
                _ = self?.rowThumbnailImage(for: entry.id)
            }
        }
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
            // No sample data fallback — show empty state with daemon-not-running message.
        }
    }

    func refresh(resetSelection: Bool = false) {
        guard let db = db else { return }
        // DB reads happen on a background queue; UI updates are dispatched to main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let pinned = try db.listPinned()
                let history = try db.list(limit: 200)
                let pinnedEntries = pinned.map { ClipboardEntry(from: $0, isPinned: true) }
                let historyEntries = history
                    .filter { !$0.isPinned }
                    .map { ClipboardEntry(from: $0, isPinned: false) }
                // Pre-warm thumbnail cache before publishing so rows render instantly.
                self?.prefetchThumbnails(for: pinnedEntries + historyEntries)
                DispatchQueue.main.async {
                    self?.pinnedEntries = pinnedEntries
                    self?.historyEntries = historyEntries
                    if resetSelection {
                        self?.selectedID = self?.filteredPinned.first?.id
                            ?? self?.filteredHistory.first?.id
                    }
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
        self.content = stored.content              // Full original clipboard content
        self.preview = stored.preview ?? stored.content  // Truncated display text
        self.sourceApp = stored.sourceName ?? "Unknown"
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(stored.createdAt) / 1000.0)
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
