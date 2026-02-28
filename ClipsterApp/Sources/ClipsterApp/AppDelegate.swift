import AppKit
import SwiftUI

/// AppDelegate manages the status bar item and popover panel.
/// The app runs as a menu bar agent — no dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let keyboardMonitor = KeyboardMonitor()
    private let viewModel = ClipboardViewModel()
    private var globalShortcut: GlobalShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupGlobalShortcut()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Clipster"
            )
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: Theme.panelWidth, height: Theme.panelHeight)
        popover.behavior = .transient
        popover.animates = true
        // Let SwiftUI environment drive the color scheme; no forced appearance here.

        let contentView = ClipboardPanelView(viewModel: viewModel, onPaste: { [weak self] entry in
            PasteService.pasteToFrontApp(content: entry.preview) {
                self?.closePopover()
            }
        })
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            openPopover(relativeTo: button)
        }
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        viewModel.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)

        // Start keyboard monitor for panel navigation.
        keyboardMonitor.start(
            viewModel: viewModel,
            onClose: { [weak self] in self?.closePopover() },
            onPaste: { [weak self] entry in
                PasteService.pasteToFrontApp(content: entry.preview) {
                    self?.closePopover()
                }
            }
        )
    }

    // MARK: - Global Shortcut

    private func setupGlobalShortcut() {
        // Load shortcut from UserDefaults if configured; default ⌘⇧V.
        let shortcut = loadSavedShortcut() ?? .defaultPaste
        globalShortcut = GlobalShortcut(shortcut: shortcut) { [weak self] in
            self?.togglePopover()
        }
        globalShortcut?.start()
    }

    /// Reads a persisted shortcut from UserDefaults (key "globalShortcut").
    /// Format stored: "<keyCode>:<modifierRawValue>" e.g. "9:786432"
    private func loadSavedShortcut() -> GlobalShortcut.Shortcut? {
        guard let raw = UserDefaults.standard.string(forKey: "globalShortcut"),
              case let parts = raw.split(separator: ":"),
              parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let modRaw = UInt64(parts[1]) else { return nil }
        return GlobalShortcut.Shortcut(keyCode: keyCode, modifiers: CGEventFlags(rawValue: modRaw))
    }

    func closePopover() {
        popover.performClose(nil)
        keyboardMonitor.stop()
    }

    // MARK: - Click-outside dismissal

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let self = self, self.popover.isShown {
                self.closePopover()
            }
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
