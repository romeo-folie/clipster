import Foundation

/// Runtime mode for clipsterd process orchestration.
///
/// PRD §14.1 binding decision: GUI phase evolves the same daemon binary
/// into an app-capable runtime without replacing core services.
public enum RuntimeMode: String, CaseIterable {
    case headless
    case app
}

public struct RuntimeOptions {
    public let mode: RuntimeMode

    public init(mode: RuntimeMode) {
        self.mode = mode
    }

    /// Parse runtime mode from CLI args and/or environment.
    ///
    /// Precedence:
    /// 1) CLI arg: `--runtime-mode=<headless|app>`
    /// 2) Env var: `CLIPSTER_RUNTIME_MODE=<headless|app>`
    /// 3) Default: headless
    public static func parse(args: [String], env: [String: String]) -> RuntimeOptions {
        if let argMode = args.first(where: { $0.hasPrefix("--runtime-mode=") })?
            .split(separator: "=", maxSplits: 1)
            .last,
           let mode = RuntimeMode(rawValue: String(argMode).lowercased()) {
            return RuntimeOptions(mode: mode)
        }

        if let envMode = env["CLIPSTER_RUNTIME_MODE"]?.lowercased(),
           let mode = RuntimeMode(rawValue: envMode) {
            return RuntimeOptions(mode: mode)
        }

        return RuntimeOptions(mode: .headless)
    }
}

/// Process runtime that owns service startup/shutdown.
///
/// The current implementation runs the same core services in both modes.
/// GUI/AppKit wiring is intentionally deferred; this class creates the seam.
public final class ClipsterRuntime {
    public let options: RuntimeOptions
    public let config: ClipsterConfig

    private let database: ClipsterDatabase
    private let monitor: ClipboardMonitor
    private let ipcServer: IPCServer

    public init(options: RuntimeOptions) throws {
        self.options = options

        let cfg = ConfigLoader.load()
        self.config = cfg
        logger.minimumLevel = cfg.logLevel

        self.database = try ClipsterDatabase(config: cfg)
        self.monitor = ClipboardMonitor(config: cfg) { [weak database] entry in
            do {
                try database?.insert(entry)
            } catch {
                logger.error("Failed to insert entry: \(error)")
            }
        }
        self.ipcServer = IPCServer(database: database, monitor: monitor)
    }

    public func start(version: String, pid: Int32) {
        logger.info("Config:  \(ConfigLoader.configURL.path)")
        logger.info("clipsterd \(version) starting (PID \(pid))")
        logger.info("Runtime mode: \(options.mode.rawValue)")
        logger.info("DB:      \(ClipsterDatabase.dbURL.path)")
        logger.info("Socket:  \(IPCPaths.socketURL.path)")

        // PRD §14.1 — migration state logging
        let migration = MigrationState.detect()
        logger.info("Install mode: \(migration.installMode.rawValue), migration phase: \(migration.migrationPhase.rawValue)")
        if migration.migrationPhase == .dual {
            logger.warn("Dual install mode detected — both LaunchAgent plist and app-capable environment are active.")
        }

        // PRD §9 — permission preflight (informational; daemon continues on failure)
        let caps = PermissionPreflight.run()
        for line in caps.diagnostics {
            logger.warn(line)
        }
        if caps.isReady {
            logger.info("Permission preflight: OK")
        } else {
            logger.warn("Permission preflight: degraded — some capabilities are restricted. Clipboard monitoring may be affected.")
        }

        switch options.mode {
        case .headless:
            logger.info("Starting in headless mode")
        case .app:
            logger.info("Starting in app-capable mode (core services only in Phase 4)")
        }

        monitor.start()
        logger.info("Clipboard monitor started — poll: \(Int(monitor.pollInterval * 1000))ms, debounce: \(Int(monitor.debounceDelay * 1000))ms")

        do {
            try ipcServer.start()
        } catch {
            logger.error("Failed to start IPC server: \(error)")
            logger.warn("Continuing without IPC; CLI will fall back to SQLite read-only mode")
        }

        logger.info("clipsterd ready")
    }

    public func stop() {
        ipcServer.stop()
        monitor.stop()
    }
}
