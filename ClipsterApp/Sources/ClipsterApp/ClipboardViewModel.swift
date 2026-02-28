import Combine
import SwiftUI

/// View model for the clipboard panel. Manages search filtering and selection state.
/// In task 1.4 this will be wired to ClipsterCore's database; for now it uses sample data.
final class ClipboardViewModel: ObservableObject {
    @Published var searchQuery = ""
    @Published var selectedID: String?
    @Published var pinnedEntries: [ClipboardEntry] = ClipboardEntry.samplePinned
    @Published var historyEntries: [ClipboardEntry] = ClipboardEntry.sampleHistory

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
}
