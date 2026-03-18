import Foundation
import ClipsterCore

/// Unix domain socket IPC client for communicating with clipsterd.
/// Sends a single command and waits for the response (request/response pattern).
/// Protocol: 4-byte big-endian length prefix + UTF-8 JSON body (same as clipsterd IPCServer).
///
/// All writes (pin, unpin, delete) go through the daemon to preserve
/// the clipsterd sole-write-owner invariant (PRD §7.6 + MEMORY.md).
final class IPCClient {
    // MARK: - Constants

    static var socketPath: String { IPCPaths.socketURL.path }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Command Dispatch

    /// Sends a command to clipsterd and decodes the response.
    /// This is a synchronous call — callers must dispatch to a background queue.
    @discardableResult
    static func send(_ command: String, params: IPCParams = .empty) throws -> IPCResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed(errno: errno)
        }
        defer { Darwin.close(fd) }

        // Connect to daemon socket.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, byte) in path.enumerated() { ptr[i] = UInt8(bitPattern: byte) }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrSize)
            }
        }
        guard connected == 0 else {
            throw IPCError.connectionFailed(errno: errno)
        }

        // Encode command.
        let cmd = IPCCommand(command: command, params: params)
        let bodyData = try Self.encoder.encode(cmd)
        let frame = Self.encodeFrame(bodyData)

        // Send frame.
        try writeAll(fd: fd, data: frame)

        // Read response.
        let responseData = try readFrame(fd: fd)
        return try Self.decoder.decode(IPCResponse.self, from: responseData)
    }

    // MARK: - Convenience helpers

    static func pin(id: String) throws {
        try send("pin", params: IPCParams(entryID: id))
    }

    static func unpin(id: String) throws {
        try send("unpin", params: IPCParams(entryID: id))
    }

    @discardableResult
    static func delete(id: String) throws -> IPCResponse {
        try send("delete", params: IPCParams(entryID: id))
    }

    /// Tell clipsterd to pause clipboard monitoring (e.g. before writing to NSPasteboard).
    static func pauseMonitoring() throws {
        try send("pause_monitoring")
    }

    /// Tell clipsterd to resume clipboard monitoring (after paste completes).
    static func resumeMonitoring() throws {
        try send("resume_monitoring")
    }

    // MARK: - Framing (mirrors IPCFraming in ClipsterCore)

    private static func encodeFrame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    private static func readFrame(fd: Int32) throws -> Data {
        // Read 4-byte length prefix.
        var header = Data(count: 4)
        try header.withUnsafeMutableBytes { ptr in
            var bytesRead = 0
            while bytesRead < 4 {
                let n = Darwin.recv(fd, ptr.baseAddress!.advanced(by: bytesRead), 4 - bytesRead, 0)
                guard n > 0 else { throw IPCError.connectionClosed }
                bytesRead += n
            }
        }
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0, length < 4 * 1024 * 1024 else { // 4 MB sanity cap
            throw IPCError.invalidFrame
        }

        // Read body.
        var body = Data(count: length)
        try body.withUnsafeMutableBytes { ptr in
            var bytesRead = 0
            while bytesRead < length {
                let n = Darwin.recv(fd, ptr.baseAddress!.advanced(by: bytesRead), length - bytesRead, 0)
                guard n > 0 else { throw IPCError.connectionClosed }
                bytesRead += n
            }
        }
        return body
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
                guard n > 0 else { throw IPCError.sendFailed(errno: errno) }
                sent += n
            }
        }
    }
}

// MARK: - Errors

enum IPCError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong
    case connectionFailed(errno: Int32)
    case connectionClosed
    case sendFailed(errno: Int32)
    case invalidFrame
    case daemonNotRunning

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Clipster daemon not running"
        case .daemonNotRunning: return "Clipster daemon not running"
        default: return "IPC error: \(self)"
        }
    }
}
