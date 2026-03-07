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

    // Daemon reconnect monitor — detects mid-session daemon restarts and re-syncs
    // the suppress list so the user never silently loses suppression coverage.
    private var daemonMonitorTimer: Timer?
    private var daemonWasReachable: Bool = false

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

        // Start background monitor that detects daemon restarts and re-syncs.
        startDaemonReconnectMonitor()
    }

    /// Pushes every entry in the persisted suppress list to the daemon over IPC.
    /// Safe to call on launch and on reconnect — the daemon deduplicates internally.
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

    // MARK: - Daemon Reconnect Monitor

    /// Polls `daemon_status` every 30 seconds on a background queue.
    /// When the daemon transitions from unreachable → reachable, the full suppress
    /// list is re-synced automatically. This covers the mid-session daemon restart
    /// scenario where the daemon flushes its in-memory suppress set on startup.
    ///
    /// Cost: one lightweight IPC round-trip every 30s (< 1ms on localhost Unix socket).
    private func startDaemonReconnectMonitor() {
        // Mark initial state based on the launch sync attempt.
        DispatchQueue.global(qos: .background).async { [weak self] in
            let reachable = (try? IPCClient.send("daemon_status")) != nil
            DispatchQueue.main.async {
                self?.daemonWasReachable = reachable
            }
        }

        // Schedule a repeating timer on the main run loop. The actual IPC work
        // dispatches to a background queue so the main thread is never blocked.
        daemonMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkDaemonReachability()
        }
    }

    private func checkDaemonReachability() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let reachable = (try? IPCClient.send("daemon_status")) != nil

            DispatchQueue.main.async {
                guard let self = self else { return }
                if reachable && !self.daemonWasReachable {
                    // Daemon just came back — re-sync the suppress list.
                    self.syncSuppressListToDaemon()
                }
                self.daemonWasReachable = reachable
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
            self?.paste(entry: entry)
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
        viewModel.refresh(resetSelection: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)

        // Start keyboard monitor for panel navigation.
        keyboardMonitor.start(
            viewModel: viewModel,
            onClose: { [weak self] in self?.closePopover() },
            onPaste: { [weak self] entry in
                self?.paste(entry: entry)
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

    // MARK: - Paste

    /// Paste the selected entry to the frontmost app.
    ///
    /// Image entries are pasted as TIFF/PNG image data fetched from the thumbnail store.
    /// All other entry types are pasted as plain text.
    private func paste(entry: ClipboardEntry) {
        if entry.contentType == .image,
           let jpegData = viewModel.thumbnailData(for: entry.id) {
            PasteService.pasteImageToFrontApp(jpegData: jpegData) { [weak self] in
                self?.closePopover()
            }
        } else {
            PasteService.pasteToFrontApp(content: entry.content) { [weak self] in
                self?.closePopover()
            }
        }
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
        daemonMonitorTimer?.invalidate()
    }
}
