import Foundation

// MARK: - InstallMode

/// How the running clipsterd process was launched.
///
/// - `launchAgent`: Classic headless daemon managed by launchd via plist.
///   This is the install mode for Phases 0–3.
/// - `appBundle`:   Launched directly by a parent macOS app bundle (Phase 4+).
///   In this mode launchd no longer manages the process lifecycle.
public enum InstallMode: String, Equatable {
    case launchAgent
    case appBundle
}

// MARK: - MigrationPhase

/// Tracks where a given install sits in the LaunchAgent → app lifecycle migration.
public enum MigrationPhase: String, Equatable, CaseIterable {
    /// Only the legacy LaunchAgent plist is present. No migration needed.
    case legacyOnly
    /// Both install modes are present (transient state during migration).
    case dual
    /// Only the app-bundle mode is active. Migration complete.
    case appOnly
}

// MARK: - MigrationState

/// Detects the current install mode and migration phase by inspecting the file system.
/// All paths are injectable for testability.
public struct MigrationState: Equatable {

    public let installMode: InstallMode
    public let migrationPhase: MigrationPhase

    /// `true` when the legacy LaunchAgent plist is present at its canonical location.
    public let hasLaunchAgentPlist: Bool

    /// `true` when a daemon process was started by an app bundle
    /// (detected via the CLIPSTER_RUNTIME_MODE=app environment variable).
    public let hasAppModeEnv: Bool

    // MARK: - Init

    public init(installMode: InstallMode, migrationPhase: MigrationPhase,
                hasLaunchAgentPlist: Bool, hasAppModeEnv: Bool) {
        self.installMode = installMode
        self.migrationPhase = migrationPhase
        self.hasLaunchAgentPlist = hasLaunchAgentPlist
        self.hasAppModeEnv = hasAppModeEnv
    }

    // MARK: - Detection

    /// Canonical plist path: `~/Library/LaunchAgents/com.clipster.daemon.plist`
    public static var defaultPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.clipster.daemon.plist")
    }

    /// Detect migration state from the live system.
    public static func detect() -> MigrationState {
        detect(
            plistURL: defaultPlistURL,
            env: ProcessInfo.processInfo.environment
        )
    }

    /// Injectable overload used by unit tests.
    public static func detect(plistURL: URL, env: [String: String]) -> MigrationState {
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        let hasApp   = env["CLIPSTER_RUNTIME_MODE"]?.lowercased() == "app"

        let mode: InstallMode
        let phase: MigrationPhase

        switch (hasPlist, hasApp) {
        case (true,  false):
            mode  = .launchAgent
            phase = .legacyOnly
        case (false, true):
            mode  = .appBundle
            phase = .appOnly
        case (true,  true):
            // Both present — mid-migration; prefer app-capable mode
            mode  = .appBundle
            phase = .dual
        case (false, false):
            // Fresh install or LaunchAgent plist not yet written
            mode  = .launchAgent
            phase = .legacyOnly
        }

        return MigrationState(
            installMode:         mode,
            migrationPhase:      phase,
            hasLaunchAgentPlist: hasPlist,
            hasAppModeEnv:       hasApp
        )
    }

    // MARK: - Rollback helpers

    /// Returns rollback guidance for the current phase.
    ///
    /// Rollback procedure:
    /// 1. `clipster daemon stop` (stops whichever mode is active)
    /// 2. Remove app-mode environment injection (e.g. Xcode scheme, plist env key)
    /// 3. Verify plist is at canonical path; if absent, re-run `scripts/install.sh`
    /// 4. `clipster daemon start` to resume legacy LaunchAgent mode
    public var rollbackSteps: [String] {
        switch migrationPhase {
        case .legacyOnly:
            return ["Already in legacy mode — no rollback needed."]
        case .dual:
            return [
                "Run: clipster daemon stop",
                "Remove CLIPSTER_RUNTIME_MODE=app from the launching environment.",
                "Verify plist at ~/Library/LaunchAgents/com.clipster.daemon.plist.",
                "Run: clipster daemon start",
            ]
        case .appOnly:
            return [
                "Run: clipster daemon stop",
                "Run: scripts/install.sh (re-installs LaunchAgent plist)",
                "Run: clipster daemon start",
            ]
        }
    }

    // MARK: - Compatibility check

    /// Verify that a `clipster daemon <cmd>` invocation is safe given the current mode.
    ///
    /// - Returns: `nil` if safe, or a human-readable warning string if degraded.
    public func compatibilityWarning(for daemonCommand: String) -> String? {
        if migrationPhase == .dual {
            return """
            [clipster] Warning: both LaunchAgent plist and app-mode environment detected (dual mode).
            daemon \(daemonCommand) will target the LaunchAgent. To manage the app-mode process, \
            quit the app directly or set CLIPSTER_RUNTIME_MODE=app.
            """
        }
        if migrationPhase == .appOnly && ["start", "stop", "restart"].contains(daemonCommand) {
            return """
            [clipster] Warning: LaunchAgent plist not found — daemon is running under an app bundle.
            'clipster daemon \(daemonCommand)' has no effect; manage the process via the app.
            """
        }
        return nil
    }
}
