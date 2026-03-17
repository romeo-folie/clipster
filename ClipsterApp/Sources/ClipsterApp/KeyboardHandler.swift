import AppKit
import SwiftUI

extension Notification.Name {
    static let transformNavigate = Notification.Name("clipster.transform.navigate")
    static let transformApplySelected = Notification.Name("clipster.transform.applySelected")
}

/// Handles keyboard events for the clipboard panel via NSEvent local monitor.
/// Provides arrow key navigation, Enter (paste), ⌘Enter (copy), ⌘P (pin/unpin),
/// ⌘D (delete), Tab (transform panel), Escape (close).
/// Delete/Backspace pass through to the search field and do not affect list entries.
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

        // ⌘P / ⌘D are global — intercept before any panel-state branch so they
        // work whether the transform panel is open or closed, and with Caps Lock on.
        // Caps Lock, numeric-pad, function, and help flags are intentionally ignored
        // so that e.g. ⌘P with Caps Lock active still triggers pin/unpin.
        // Strip Caps Lock (and other non-significant modifiers) so ⌘P/⌘D fire
        // regardless of Caps Lock state. Use lowercased() on the character so
        // ⌘P with Caps Lock on ("P") still matches ("p").
        let cmdSignificant = flags.subtracting([.capsLock, .numericPad, .function, .help])
        if cmdSignificant == .command {
            if event.charactersIgnoringModifiers?.lowercased() == "p" {
                pinSelected(viewModel: viewModel)
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "d" {
                deleteSelected(viewModel: viewModel)
                return true
            }
        }

        if viewModel.showTransformPanel,
           let selected = selectedEntry(viewModel: viewModel),
           selected.contentType != .image {
            switch event.keyCode {
            case 126: // Up arrow
                NotificationCenter.default.post(name: .transformNavigate, object: nil, userInfo: ["delta": -1])
                return true
            case 125: // Down arrow
                NotificationCenter.default.post(name: .transformNavigate, object: nil, userInfo: ["delta": 1])
                return true
            case 36: // Return/Enter
                NotificationCenter.default.post(name: .transformApplySelected, object: nil)
                return true
            case 48, 53: // Tab / Escape closes transform panel first
                viewModel.showTransformPanel = false
                return true
            default:
                return false
            }
        }

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
        case 51,  // Backspace (⌫)
             117: // Forward Delete (⌦, also fn+Delete on laptop keyboards)
            // Pass through — Delete/Backspace are forwarded to the search field
            // when it holds focus (otherwise the event may be silently ignored).
            // Use ⌘D to delete a list entry regardless of focus state.
            return false
        case 48:  // Tab
            // Image entries are not transformable; Tab should be a no-op.
            if let entry = selectedEntry(viewModel: viewModel), entry.contentType == .image {
                return true
            }
            DispatchQueue.main.async {
                if viewModel.showTransformPanel {
                    viewModel.showTransformPanel = false
                } else {
                    viewModel.showTransformPanel = true
                }
            }
            return true
        default:
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

        if entry.contentType == .image,
           let jpegData = viewModel.thumbnailData(for: entry.id),
           let image = NSImage(data: jpegData) {
            if let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                pasteboard.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
            }
        } else {
            pasteboard.setString(entry.content, forType: .string)
        }

        onClose()
    }

    private static func pinSelected(viewModel: ClipboardViewModel) {
        guard let entry = selectedEntry(viewModel: viewModel) else { return }
        viewModel.togglePin(id: entry.id)
    }

    private static func deleteSelected(viewModel: ClipboardViewModel) {
        guard let entry = selectedEntry(viewModel: viewModel) else { return }
        // Advance selection to the next item before deleting so the panel
        // doesn't snap back to the top.
        let allEntries = viewModel.filteredPinned + viewModel.filteredHistory
        if let idx = allEntries.firstIndex(where: { $0.id == entry.id }) {
            let nextIdx = idx < allEntries.count - 1 ? idx + 1 : (idx > 0 ? idx - 1 : nil)
            viewModel.selectedID = nextIdx.map { allEntries[$0].id }
        }
        viewModel.deleteEntry(id: entry.id)
    }

    private static func selectedEntry(viewModel: ClipboardViewModel) -> ClipboardEntry? {
        guard let id = viewModel.selectedID else { return nil }
        let all = viewModel.filteredPinned + viewModel.filteredHistory
        return all.first(where: { $0.id == id })
    }
}
