import ClipsterCore
import Foundation

// ─── Version ─────────────────────────────────────────────────────────────────

let version = "0.2.0-phase1"
let pid = ProcessInfo.processInfo.processIdentifier

// ─── Config ───────────────────────────────────────────────────────────────────
// PRD §7.3.6 startup sequence: read config first, create defaults if missing.

let config = ConfigLoader.load()
logger.minimumLevel = config.logLevel
logger.info("Config:  \(ConfigLoader.configURL.path)")

// ─── Startup banner ───────────────────────────────────────────────────────────
// PRD §7.3.5: log version, PID, config path, DB path, socket path on startup.

logger.info("clipsterd \(version) starting (PID \(pid))")
logger.info("DB:      \(ClipsterDatabase.dbURL.path)")
logger.info("Socket:  ~/Library/Application Support/Clipster/clipster.sock [Phase 1 — IPC]")

// ─── Database ─────────────────────────────────────────────────────────────────

let database: ClipsterDatabase
do {
    database = try ClipsterDatabase(config: config)
} catch {
    logger.error("Failed to open database: \(error)")
    exit(1)
}

// ─── Clipboard monitor ────────────────────────────────────────────────────────

let monitor = ClipboardMonitor(config: config) { entry in
    do {
        try database.insert(entry)
    } catch {
        logger.error("Failed to insert entry: \(error)")
    }
}

monitor.start()
logger.info("Clipboard monitor started — poll: \(Int(monitor.pollInterval * 1000))ms, debounce: \(Int(monitor.debounceDelay * 1000))ms")

// ─── Signal handling ──────────────────────────────────────────────────────────
// PRD §7.3.7 shutdown sequence:
// 1. Stop accepting new IPC connections (Phase 1)
// 2. Finish any in-flight DB write (GRDB serialises writes — safe on stop)
// 3. Remove socket file (Phase 1)
// 4. Close DB connection cleanly (GRDB closes on dealloc; explicit below for clarity)

// Phase 1 note: replace signal() with DispatchSource.makeSignalSource for
// async-signal-safe handling. signal() is used here as it is sufficient for
// Phase 0 (no IPC, no concurrent writes beyond the monitor queue).

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let sigSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigSrc.setEventHandler {
    logger.info("Received SIGTERM — shutting down")
    monitor.stop()
    // DB closes when `database` is deallocated; GRDB flushes the write queue.
    logger.info("clipsterd stopped cleanly")
    exit(0)
}
sigSrc.resume()

let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSrc.setEventHandler {
    logger.info("Received SIGINT — shutting down")
    monitor.stop()
    logger.info("clipsterd stopped cleanly")
    exit(0)
}
intSrc.resume()

// ─── Run ──────────────────────────────────────────────────────────────────────

logger.info("clipsterd ready")
RunLoop.main.run()
