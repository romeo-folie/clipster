import Foundation
import SwiftUI

/// Appearance mode for the app.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark
}

/// Manages user settings, backed by UserDefaults.
/// On change, syncs relevant values to clipsterd config file.
final class SettingsViewModel: ObservableObject {
    // MARK: - General

    @AppStorage("entryLimit") var entryLimit: Int = 500
    @AppStorage("dbSizeCap") var dbSizeCap: Int = 500
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true
    @AppStorage("appearance") var appearance: AppearanceMode = .auto

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
    }

    // MARK: - Suppress List

    func addSuppressedApp() {
        let app = newSuppressApp.trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty, !suppressedApps.contains(app) else { return }
        suppressedApps.append(app)
        newSuppressApp = ""
        saveSuppressedApps()
    }

    func removeSuppressedApp(_ app: String) {
        suppressedApps.removeAll { $0 == app }
        saveSuppressedApps()
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
        // TODO: Sync to clipsterd config.ini when IPC "suppress" command is available.
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
