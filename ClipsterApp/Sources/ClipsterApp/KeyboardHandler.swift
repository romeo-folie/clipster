import AppKit
import SwiftUI

/// Handles keyboard events for the clipboard panel via NSEvent local monitor.
/// Provides arrow key navigation, Enter (paste), ⌘Enter (copy), ⌘P (pin), Escape (close).
/// Uses NSEvent.addLocalMonitorForEvents for macOS 13+ compatibility.
final class KeyboardMonitor: ObservableObject {
    private var monitor: Any?

    func start(
        viewModel: ClipboardViewModel,
        onClose: @escaping () -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void
    ) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = Self.handleKeyEvent(
                event: event,
                viewModel: viewModel,
                onClose: onClose,
                onPaste: onPaste
            )
            return handled ? nil : event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit { stop() }

    // MARK: - Event Dispatch

    private static func handleKeyEvent(
        event: NSEvent,
        viewModel: ClipboardViewModel,
        onClose: @escaping () -> Void,
        onPaste: @escaping (ClipboardEntry) -> Void
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 126: // Up arrow
            moveSelection(by: -1, viewModel: viewModel)
            return true
        case 125: // Down arrow
            moveSelection(by: 1, viewModel: viewModel)
            return true
        case 53:  // Escape
            onClose()
            return true
        case 36:  // Return/Enter
            if flags.contains(.command) {
                copySelected(viewModel: viewModel, onClose: onClose)
            } else {
                pasteSelected(viewModel: viewModel, onPaste: onPaste)
            }
            return true
        case 48:  // Tab
            DispatchQueue.main.async {
                if viewModel.showTransformPanel {
                    viewModel.showTransformPanel = false
                } else {
                    viewModel.showTransformPanel = true
                }
            }
            return true
        default:
            // ⌘P
            if flags.contains(.command), event.charactersIgnoringModifiers == "p" {
                pinSelected(viewModel: viewModel)
                return true
            }
            return false
        }
    }

    // MARK: - Navigation

    private static func moveSelection(by delta: Int, viewModel: ClipboardViewModel) {
        let allEntries = viewModel.filteredPinned + viewModel.filteredHistory
        guard !allEntries.isEmpty else { return }

        if let currentID = viewModel.selectedID,
           let currentIndex = allEntries.firstIndex(where: { $0.id == currentID }) {
            let newIndex = max(0, min(allEntries.count - 1, currentIndex + delta))
            viewModel.selectedID = allEntries[newIndex].id
        } else {
            viewModel.selectedID = allEntries.first?.id
        }

        // When the user navigates into the list, resign the search field so the
        // blinking cursor disappears and focus clearly belongs to the list.
        // makeFirstResponder(nil) is a no-op if the search field isn't first responder.
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - Actions

    private static func pasteSelected(
        viewModel: ClipboardViewModel,
        onPaste: @escaping (ClipboardEntry) -> Void
    ) {
        guard let entry = selectedEntry(viewModel: viewModel) else { return }
        onPaste(entry)
    }

    private static func copySelected(
        viewModel: ClipboardViewModel,
        onClose: @escaping () -> Void
    ) {
        guard let entry = selectedEntry(viewModel: viewModel) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.content, forType: .string)
        onClose()
    }

    private static func pinSelected(viewModel: ClipboardViewModel) {
        guard let entry = selectedEntry(viewModel: viewModel) else { return }
        viewModel.togglePin(id: entry.id)
    }

    private static func selectedEntry(viewModel: ClipboardViewModel) -> ClipboardEntry? {
        guard let id = viewModel.selectedID else { return nil }
        let all = viewModel.filteredPinned + viewModel.filteredHistory
        return all.first(where: { $0.id == id })
    }
}
