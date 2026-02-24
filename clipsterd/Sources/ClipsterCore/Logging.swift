import Foundation

/// Minimal structured logger for Phase 0.
///
/// Phase 1 will extend this to respect `[daemon] log_level` from config.toml
/// and add structured JSON output for potential future tooling.
public enum LogLevel: String, Comparable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warn, .error]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else {
            return false
        }
        return l < r
    }
}

public final class Logger {
    public static let shared = Logger()

    /// Minimum level to emit. Phase 1: loaded from config.toml.
    public var minimumLevel: LogLevel = .info

    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let queue = DispatchQueue(label: "com.clipster.logger", qos: .utility)

    private init() {}

    public func log(_ level: LogLevel, _ message: String, file: String = #fileID, function: String = #function) {
        guard level >= minimumLevel else { return }
        let timestamp = formatter.string(from: Date())
        let output = "[\(timestamp)] [\(level.rawValue)] \(message)"
        queue.async {
            print(output)
            fflush(stdout)
        }
    }

    public func debug(_ message: String, file: String = #fileID, function: String = #function) {
        log(.debug, message, file: file, function: function)
    }

    public func info(_ message: String, file: String = #fileID, function: String = #function) {
        log(.info, message, file: file, function: function)
    }

    public func warn(_ message: String, file: String = #fileID, function: String = #function) {
        log(.warn, message, file: file, function: function)
    }

    public func error(_ message: String, file: String = #fileID, function: String = #function) {
        log(.error, message, file: file, function: function)
    }
}

// Convenience shorthand
public let logger = Logger.shared
