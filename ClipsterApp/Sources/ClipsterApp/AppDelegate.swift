import AppKit
import ClipsterCore
import SwiftUI

/// AppDelegate manages the status bar item and popover panel.
/// The app runs as a menu bar agent — no dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var statusBarMenu: NSMenu?
    private let keyboardMonitor = KeyboardMonitor()
    private let viewModel = ClipboardViewModel()
    private var globalShortcut: GlobalShortcut?
    // Sparkle auto-update controller. Strong reference required — Sparkle stores
    // the controller weakly internally and it must stay alive for the lifetime of the app.
    private let updateManager = UpdateManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply stored appearance before any windows open.
        SettingsViewModel.applyStoredAppearance()

        // Hide dock icon — menu bar only.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        setupGlobalShortcut()

        // Re-sync suppress list to daemon on every launch.
        // The daemon holds suppress state only in memory (runtime set) and reads
        // config.ini on startup. If the daemon restarts while the app is running,
        // or starts fresh, it loses any GUI-added suppressions. Sending the full
        // list on our launch ensures the daemon's runtime set always reflects
        // what the user configured — UserDefaults is the source of truth for the list.
        syncSuppressListToDaemon()
    }

    /// Pushes every entry in the persisted suppress list to the daemon over IPC.
    /// Safe to call on launch — the daemon deduplicates internally.
    private func syncSuppressListToDaemon() {
        let defaults: [String] = ["1Password", "Bitwarden", "Dashlane", "LastPass"]
        let apps = UserDefaults.standard.stringArray(forKey: "suppressedApps") ?? defaults
        guard !apps.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            for app in apps {
                try? IPCClient.send("suppress", params: IPCParams(entryID: app))
            }
        }
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Right-click menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = nil // Set dynamically on right-click
        statusBarMenu = menu
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: Theme.panelWidth, height: Theme.panelHeight)
        popover.behavior = .transient
        popover.animates = true
        // Let SwiftUI environment drive the color scheme; no forced appearance here.

        let contentView = ClipboardPanelView(viewModel: viewModel, onPaste: { [weak self] entry in
            PasteService.pasteToFrontApp(content: entry.content) {
                self?.closePopover()
            }
        })
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        // Right-click → show menu
        if event?.type == .rightMouseUp, let menu = statusBarMenu {
            statusItem.menu = menu
            button.performClick(nil)
            // Clear menu after display so left-click works normally
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.menu = nil
            }
            return
        }
        // Left-click → toggle popover
        if popover.isShown {
            closePopover()
        } else {
            openPopover(relativeTo: button)
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        updateManager.checkForUpdates()
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
                PasteService.pasteToFrontApp(content: entry.content) {
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
