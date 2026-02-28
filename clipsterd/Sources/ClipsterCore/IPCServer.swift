import Foundation

/// Unix domain socket IPC server.
///
/// PRD §7.6 — versioned protocol, 4-byte framing, all 9 commands, write ownership invariant.
/// One server per daemon. Clients connect, send one command, receive one response, disconnect.
/// Long-lived connections are also supported (client can pipeline commands).
///
/// Write ownership: all DB writes go through this server's `database` reference.
/// The Go CLI never writes directly to SQLite — that invariant is enforced by design.
public final class IPCServer {

    // MARK: - State

    private let database: ClipsterDatabase
    private weak var monitor: ClipboardMonitor?
    private var listenerSocket: Int32 = -1
    private var isRunning = false

    private let serverQueue = DispatchQueue(
        label: "com.clipster.ipc.server",
        qos: .userInteractive
    )

    // MARK: - Init

    public init(database: ClipsterDatabase, monitor: ClipboardMonitor? = nil) {
        self.database = database
        self.monitor = monitor
    }

    // MARK: - Lifecycle

    /// Bind the Unix socket and begin accepting connections.
    /// Removes any stale socket file first.
    public func start() throws {
        let socketPath = IPCPaths.socketURL.path
        try ensureSocketDirectory()
        removeStaleSocket(at: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.socketCreationFailed(errno)
        }

        // SO_REUSEADDR
        var reuseVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseVal, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            pathBytes.withUnsafeBytes { src in
                ptr.copyMemory(from: src)
            }
        }

        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw IPCError.bindFailed(errno)
        }

        guard listen(fd, 10) == 0 else {
            close(fd)
            throw IPCError.listenFailed(errno)
        }

        listenerSocket = fd
        isRunning = true
        logger.info("IPC socket listening at \(socketPath)")

        serverQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    /// Stop accepting connections and remove the socket file. PRD §7.3.7.
    public func stop() {
        isRunning = false
        if listenerSocket >= 0 {
            shutdown(listenerSocket, SHUT_RDWR)
            close(listenerSocket)
            listenerSocket = -1
        }
        removeStaleSocket(at: IPCPaths.socketURL.path)
        logger.info("IPC server stopped")
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while isRunning {
            let clientFD = accept(listenerSocket, nil, nil)
            guard clientFD >= 0 else {
                if isRunning {
                    logger.warn("IPC accept error: \(errno)")
                }
                break
            }
            logger.debug("IPC client connected (fd \(clientFD))")
            // Handle each client on its own thread (clients are short-lived)
            let db = database
            let mon = monitor
            DispatchQueue.global(qos: .userInteractive).async {
                IPCServer.handleClient(clientFD, database: db, monitor: mon)
            }
        }
    }

    // MARK: - Client handling

    private static func handleClient(_ fd: Int32, database: ClipsterDatabase, monitor: ClipboardMonitor?) {
        defer {
            close(fd)
            logger.debug("IPC client disconnected (fd \(fd))")
        }

        var readBuffer = Data()

        // Read loop — accumulate data until we have a complete frame
        while true {
            var chunk = Data(count: 4096)
            let bytesRead = chunk.withUnsafeMutableBytes { ptr in
                recv(fd, ptr.baseAddress, 4096, 0)
            }

            if bytesRead <= 0 { break }
            readBuffer.append(chunk.prefix(bytesRead))

            // Try to parse and respond to all complete frames in the buffer
            while let (body, remaining) = IPCFraming.readFrame(from: readBuffer) {
                readBuffer = remaining
                let responseData = processMessage(body, database: database, monitor: monitor)
                do {
                    let frame = try IPCFraming.encode(responseData)
                    _ = frame.withUnsafeBytes { ptr in
                        send(fd, ptr.baseAddress, frame.count, 0)
                    }
                } catch {
                    logger.error("IPC encode error: \(error)")
                    break
                }
            }
        }
    }

    // MARK: - Message dispatch

    private static func processMessage(_ data: Data, database: ClipsterDatabase, monitor: ClipboardMonitor?) -> IPCResponse {
        let decoder = JSONDecoder()

        guard let command = try? decoder.decode(IPCCommand.self, from: data) else {
            return IPCResponse.failure(id: "unknown", error: "invalid_json")
        }

        guard command.version == ipcProtocolVersion else {
            return IPCResponse.versionError(id: command.id)
        }

        do {
            let responseData = try Self.dispatch(command: command, database: database, monitor: monitor)
            return IPCResponse.success(id: command.id, data: responseData)
        } catch let e as IPCError {
            return IPCResponse.failure(id: command.id, error: e.errorCode)
        } catch {
            logger.error("IPC command '\(command.command)' error: \(error)")
            return IPCResponse.failure(id: command.id, error: "internal_error")
        }
    }

    // MARK: - Command dispatch

    private static func dispatch(command: IPCCommand, database: ClipsterDatabase, monitor: ClipboardMonitor?) throws -> IPCResponseData {
        switch command.command {

        case "list":
            let limit  = command.params.limit  ?? 50
            let offset = command.params.offset ?? 0
            let entries = try database.list(limit: limit, offset: offset)
            return .entries(entries.map(IPCEntry.init))

        case "pins":
            let pins = try database.listPinned()
            return .entries(pins.map(IPCEntry.init))

        case "last":
            guard let entry = try database.latestEntry() else {
                throw IPCError.notFound
            }
            return .entry(IPCEntry(from: entry))

        case "pin":
            guard let id = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            try database.setPin(id: id, pinned: true)
            return .empty

        case "unpin":
            guard let id = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            try database.setPin(id: id, pinned: false)
            return .empty

        case "delete":
            guard let id = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            try database.delete(id: id)
            return .empty

        case "clear":
            let count = try database.clearHistory()
            return .deleted(count)

        case "transform":
            guard let id = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            guard let transformName = command.params.transform else { throw IPCError.missingParam("transform") }
            guard let entry = try database.findEntry(id: id) else { throw IPCError.notFound }
            let result = try Transform.apply(transformName, to: entry.content)
            return .transform(result)

        case "suppress":
            guard let bundleID = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            monitor?.addSuppressedBundle(bundleID)
            return .empty

        case "unsuppress":
            guard let bundleID = command.params.entryID else { throw IPCError.missingParam("entry_id") }
            monitor?.removeSuppressedBundle(bundleID)
            return .empty

        case "suppress_list":
            let bundles = monitor?.suppressedBundles() ?? []
            // Return as entries format for consistency — empty list if monitor not available.
            return .transform(bundles.joined(separator: "\n"))

        case "daemon_status":
            let status = IPCDaemonStatus(
                running: true,
                pid: ProcessInfo.processInfo.processIdentifier,
                version: "0.2.0-phase1"
            )
            return .daemonStatus(status)

        default:
            throw IPCError.unknownCommand(command.command)
        }
    }

    // MARK: - Helpers

    private func ensureSocketDirectory() throws {
        let dir = IPCPaths.socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func removeStaleSocket(at path: String) {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - IPCError

public enum IPCError: Error {
    case socketCreationFailed(Int32)
    case socketPathTooLong
    case bindFailed(Int32)
    case listenFailed(Int32)
    case missingParam(String)
    case notFound
    case unknownCommand(String)
    case transformFailed(String)

    var errorCode: String {
        switch self {
        case .socketCreationFailed: return "socket_creation_failed"
        case .socketPathTooLong:    return "socket_path_too_long"
        case .bindFailed:           return "bind_failed"
        case .listenFailed:         return "listen_failed"
        case .missingParam(let p):  return "missing_param_\(p)"
        case .notFound:             return "not_found"
        case .unknownCommand(let c): return "unknown_command_\(c)"
        case .transformFailed(let msg): return msg
        }
    }
}
