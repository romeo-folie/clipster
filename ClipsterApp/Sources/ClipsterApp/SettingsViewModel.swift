import ClipsterCore
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

/// Appearance mode for the app.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark
}

/// Manages user settings, backed by UserDefaults.
/// On change, syncs relevant values to clipsterd config file.
final class SettingsViewModel: ObservableObject {
    private static let launchAtLoginEnabledKey = "launchAtLoginEnabled"
    private static let fallbackLoginAgentLabel = "com.clipster.app.login"

    private static var fallbackLoginAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(fallbackLoginAgentLabel).plist")
    }

    // MARK: - General

    @AppStorage("entryLimit") var entryLimit: Int = 500
    @AppStorage("dbSizeCap") var dbSizeCap: Int = 500
    @Published var launchAtLogin: Bool = true {
        didSet {
            guard !isLoadingLaunchAtLogin else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginEnabledKey)
            updateLaunchAtLogin()
        }
    }
    private var isLoadingLaunchAtLogin = true
    @AppStorage("appearance") var appearance: AppearanceMode = .auto {
        didSet { applyAppearance() }
    }

    // MARK: - Shortcut

    @AppStorage("globalShortcut") var shortcutRaw: String = ""
    var shortcutDisplay: String {
        shortcutRaw.isEmpty ? "⌘⇧V (default)" : shortcutRaw
    }

    // MARK: - Privacy

    @Published var suppressedApps: [String] = []
    @Published var newSuppressApp: String = ""

    // MARK: - CLI

    @Published var cliInstalled: Bool = false

    init() {
        loadSuppressedApps()
        checkCLIInstalled()
        loadLaunchAtLogin()
        isLoadingLaunchAtLogin = false
        applyAppearance()
    }

    // MARK: - Appearance

    func applyAppearance() {
        let mode: NSAppearance? = {
            switch appearance {
            case .light: return NSAppearance(named: .aqua)
            case .dark:  return NSAppearance(named: .darkAqua)
            case .auto:  return nil  // nil = follow system
            }
        }()
        DispatchQueue.main.async {
            NSApp.appearance = mode
        }
    }

    /// Apply stored appearance on launch — call from AppDelegate before any windows open.
    static func applyStoredAppearance() {
        let raw = UserDefaults.standard.string(forKey: "appearance") ?? "auto"
        let mode = AppearanceMode(rawValue: raw) ?? .auto
        NSApp.appearance = {
            switch mode {
            case .light: return NSAppearance(named: .aqua)
            case .dark:  return NSAppearance(named: .darkAqua)
            case .auto:  return nil
            }
        }()
    }

    // MARK: - Launch at Login

    private func loadLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
                || FileManager.default.fileExists(atPath: Self.fallbackLoginAgentURL.path)
        }
    }

    /// Registers the current app bundle once, on first launch. Subsequent starts
    /// respect the user's explicit toggle choice, including an opt-out.
    static func enableLaunchAtLoginByDefaultIfNeeded() {
        guard #available(macOS 13.0, *) else { return }
        let storedPreference = UserDefaults.standard.object(forKey: launchAtLoginEnabledKey) as? Bool
        guard storedPreference ?? true else { return }
        if SMAppService.mainApp.status == .enabled {
            UserDefaults.standard.set(true, forKey: launchAtLoginEnabledKey)
            return
        }
        if FileManager.default.fileExists(atPath: fallbackLoginAgentURL.path) {
            // The app may have moved since the fallback was first written. Refresh
            // its bundle path on every manual launch before treating it as enabled.
            if registerFallbackLoginAgent() {
                UserDefaults.standard.set(true, forKey: launchAtLoginEnabledKey)
            }
            return
        }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: launchAtLoginEnabledKey)
        } catch {
            // Unsigned development bundles may not be eligible for SMAppService.
            // A per-user LaunchAgent provides the same login behavior for local builds.
            if registerFallbackLoginAgent() {
                UserDefaults.standard.set(true, forKey: launchAtLoginEnabledKey)
            }
        }
    }

    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    do {
                        try SMAppService.mainApp.register()
                        Self.removeFallbackLoginAgent()
                    } catch {
                        guard Self.registerFallbackLoginAgent() else { throw error }
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    Self.removeFallbackLoginAgent()
                }
            } catch {
                // Registration failed — revert state.
                DispatchQueue.main.async { [weak self] in
                    self?.isLoadingLaunchAtLogin = true
                    self?.launchAtLogin = SMAppService.mainApp.status == .enabled
                        || FileManager.default.fileExists(atPath: Self.fallbackLoginAgentURL.path)
                    self?.isLoadingLaunchAtLogin = false
                }
            }
        }
    }

    /// Installs a user LaunchAgent that asks LaunchServices to open this exact app
    /// bundle at login. Used only when SMAppService rejects an unsigned local build.
    @discardableResult
    private static func registerFallbackLoginAgent() -> Bool {
        let plist: [String: Any] = [
            "Label": fallbackLoginAgentLabel,
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            let url = fallbackLoginAgentURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
            return true
        } catch {
            return false
        }
    }

    private static func removeFallbackLoginAgent() {
        let url = fallbackLoginAgentURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        runLaunchctl(["bootout", "gui/\(getuid())", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Suppress List

    func addSuppressedApp() {
        let app = newSuppressApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !suppressedApps.contains(app) else { return }
        suppressedApps.append(app)
        newSuppressApp = ""
        saveSuppressedApps()
        // Notify daemon at runtime.
        DispatchQueue.global(qos: .userInitiated).async {
            try? IPCClient.send("suppress", params: IPCParams(entryID: app))
        }
    }

    func removeSuppressedApp(_ app: String) {
        suppressedApps.removeAll { $0 == app }
        saveSuppressedApps()
        DispatchQueue.global(qos: .userInitiated).async {
            try? IPCClient.send("unsuppress", params: IPCParams(entryID: app))
        }
    }

    private func loadSuppressedApps() {
        if let apps = UserDefaults.standard.stringArray(forKey: "suppressedApps") {
            suppressedApps = apps
        } else {
            // Default suppress list per PRD §7.8
            suppressedApps = ["1Password", "Bitwarden", "Dashlane", "LastPass"]
        }
    }

    private func saveSuppressedApps() {
        UserDefaults.standard.set(suppressedApps, forKey: "suppressedApps")
        // IPC suppress/unsuppress is sent by the caller (addSuppressedApp/removeSuppressedApp).
        // AppDelegate.syncSuppressListToDaemon() re-syncs the full list on every launch
        // so daemon restarts never lose the persisted suppress state.
    }

    // MARK: - Clear History

    func clearHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try IPCClient.send("clear")
            } catch {
                // IPC failed — daemon may not be running.
            }
        }
    }

    // MARK: - CLI Install/Uninstall

    func checkCLIInstalled() {
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/clipster")
            || FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/clipster").path
            )
    }

    func installCLI() {
        // Run the install script bundled with the app.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "scripts/install.sh"]
        process.currentDirectoryURL = Bundle.main.bundleURL
        try? process.run()
        process.waitUntilExit()
        checkCLIInstalled()
    }

    func uninstallCLI() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "scripts/uninstall.sh"]
        process.currentDirectoryURL = Bundle.main.bundleURL
        try? process.run()
        process.waitUntilExit()
        checkCLIInstalled()
    }
}
