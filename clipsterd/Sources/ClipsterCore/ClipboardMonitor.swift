import AppKit
import Foundation

/// Monitors NSPasteboard for changes and fires a callback on each new entry.
///
/// Design notes (see PRD §7.1 and §14.1):
/// - Polling at 250ms with a 50ms debounce. Only the final state within the
///   debounce window is captured; intermediate values are discarded.
/// - Source attribution is intentionally Phase 1 — Phase 0 captures content only.
/// - This class has no knowledge of storage. The `onChange` callback owns persistence.
///   That separation is deliberate so the GUI phase can swap in AppKit UI without
///   touching the monitoring logic.
/// - Thread safety: all state mutations run on `monitorQueue` (serial).
public final class ClipboardMonitor {

    // MARK: - Configuration

    /// NSPasteboard polling interval. PRD §7.1: 250ms.
    public let pollInterval: TimeInterval = 0.250

    /// Debounce window after a change is detected. PRD §7.1: 50ms.
    /// If the pasteboard changes again within this window, the timer resets.
    public let debounceDelay: TimeInterval = 0.050

    // MARK: - State

    private var lastChangeCount: Int
    private var pollTimer: DispatchSourceTimer?
    private var debounceWorkItem: DispatchWorkItem?

    private let monitorQueue = DispatchQueue(
        label: "com.clipster.monitor",
        qos: .utility
    )

    // MARK: - Config

    private let config: ClipsterConfig

    /// Runtime-mutable suppress set. Initialized from config, modified via IPC.
    private var runtimeSuppressBundles: Set<String>
    private let suppressLock = NSLock()

    // MARK: - Callback

    /// Called on `monitorQueue` when a clipboard change is committed (post-debounce).
    /// The caller is responsible for hopping off this queue if needed.
    private let onChange: (ClipboardEntry) -> Void

    // MARK: - Init

    public init(config: ClipsterConfig = .default, onChange: @escaping (ClipboardEntry) -> Void) {
        self.config = config
        self.runtimeSuppressBundles = Set(config.suppressBundles)
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.onChange = onChange
    }

    // MARK: - Runtime Suppress List

    /// Add a bundle ID to the runtime suppress list. Thread-safe.
    public func addSuppressedBundle(_ bundleID: String) {
        suppressLock.lock()
        runtimeSuppressBundles.insert(bundleID)
        suppressLock.unlock()
    }

    /// Remove a bundle ID from the runtime suppress list. Thread-safe.
    public func removeSuppressedBundle(_ bundleID: String) {
        suppressLock.lock()
        runtimeSuppressBundles.remove(bundleID)
        suppressLock.unlock()
    }

    /// Get the current suppress list. Thread-safe.
    public func suppressedBundles() -> [String] {
        suppressLock.lock()
        defer { suppressLock.unlock() }
        return Array(runtimeSuppressBundles).sorted()
    }

    // MARK: - Lifecycle

    /// Start polling. Safe to call once. Subsequent calls are no-ops.
    public func start() {
        monitorQueue.async { [weak self] in
            guard let self, self.pollTimer == nil else { return }
            self.lastChangeCount = NSPasteboard.general.changeCount

            let timer = DispatchSource.makeTimerSource(
                flags: [],
                queue: self.monitorQueue
            )
            timer.schedule(
                deadline: .now() + self.pollInterval,
                repeating: self.pollInterval,
                leeway: .milliseconds(10)
            )
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            timer.resume()
            self.pollTimer = timer
        }
    }

    /// Stop polling and cancel any pending debounce. Idempotent.
    public func stop() {
        monitorQueue.sync {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    // MARK: - Internal

    private func poll() {
        // Called on monitorQueue
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Capture frontmost app at detection time (start of debounce window).
        // source_confidence is 'high' if it doesn't change before capture() fires.
        // NSWorkspace must be accessed on main thread.
        let appSnapshot = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication
        }
        // Cancel any pending debounce and schedule a new one.
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.capture(detectedApp: appSnapshot)
        }
        debounceWorkItem = work
        monitorQueue.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func capture(detectedApp: NSRunningApplication?) {
        // Called on monitorQueue after debounce window expires.

        // Get frontmost app at debounce expiry for source_confidence determination.
        let appAtCapture = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication
        }

        // source_confidence: 'high' if app hasn't changed since detection; 'low' if it has.
        let confidence: SourceConfidence = (detectedApp?.bundleIdentifier == appAtCapture?.bundleIdentifier)
            ? .high : .low

        // Password manager suppression — PRD §7.1.
        // Use the app at detection time (the app that triggered the copy).
        let isSuppressed: Bool
        suppressLock.lock()
        if let bundleID = detectedApp?.bundleIdentifier {
            isSuppressed = runtimeSuppressBundles.contains(bundleID)
        } else {
            isSuppressed = false
        }
        suppressLock.unlock()
        if isSuppressed {
            let bundleID = detectedApp?.bundleIdentifier ?? "unknown"
            logger.debug("Suppressed entry from \(bundleID)")
            return
        }

        let sourceAttribution = SourceAttribution(
            bundleID: detectedApp?.bundleIdentifier,
            name: detectedApp?.localizedName,
            confidence: confidence
        )

        // Classify pasteboard contents using ContentClassifier (PRD §7.1 — all 9 types).
        guard let entry = ContentClassifier.classify(
            pasteboard: .general,
            sourceApp: sourceAttribution
        ) else {
            logger.debug("Pasteboard change detected but no supported content — skipping")
            return
        }

        logger.debug("Captured [\(entry.contentType.rawValue)] from \(detectedApp?.localizedName ?? "unknown"): \(entry.content.prefix(60).replacingOccurrences(of: "\n", with: "↵"))")
        onChange(entry)
    }
}

// MARK: - ClipboardEntry

/// A captured clipboard snapshot.
public struct ClipboardEntry {
    public let id: String
    public let content: String
    public let contentType: ContentType
    public let sourceBundle: String?
    public let sourceName: String?
    public let sourceConfidence: SourceConfidence
    public let capturedAt: Date
    /// Raw image data for `.image` entries. Nil for all other content types.
    /// The database layer generates and stores a JPEG thumbnail from this data.
    public let imageData: Data?

    public init(
        id: String = UUID().uuidString,
        content: String,
        contentType: ContentType,
        sourceBundle: String? = nil,
        sourceName: String? = nil,
        sourceConfidence: SourceConfidence = .high,
        capturedAt: Date = Date(),
        imageData: Data? = nil
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceBundle = sourceBundle
        self.sourceName = sourceName
        self.sourceConfidence = sourceConfidence
        self.capturedAt = capturedAt
        self.imageData = imageData
    }
}

// MARK: - ContentType

/// PRD §7.1 content types. Phase 0 uses only `.plainText`.
/// All remaining cases are stubs — Phase 1 implements detection logic.
public enum ContentType: String, Codable {
    case plainText  = "plain-text"
    case richText   = "rich-text"
    case image      = "image"
    case url        = "url"
    case file       = "file"
    case code       = "code"
    case colour     = "colour"
    case email      = "email"
    case phone      = "phone"
}
