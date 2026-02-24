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

    // MARK: - Callback

    /// Called on `monitorQueue` when a clipboard change is committed (post-debounce).
    /// The caller is responsible for hopping off this queue if needed.
    private let onChange: (ClipboardEntry) -> Void

    // MARK: - Init

    public init(onChange: @escaping (ClipboardEntry) -> Void) {
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.onChange = onChange
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

        // Cancel any pending debounce and schedule a new one.
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.capture()
        }
        debounceWorkItem = work
        monitorQueue.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    private func capture() {
        // Called on monitorQueue after debounce window expires.
        let pb = NSPasteboard.general

        // Phase 0: plain text only.
        // Phase 1 will expand to all content types in PRD §7.1 (rich-text, image, url, file, code, colour, email, phone).
        guard let content = pb.string(forType: .string), !content.isEmpty else {
            logger.debug("Pasteboard change detected but no plain-text content — skipping")
            return
        }

        let entry = ClipboardEntry(
            content: content,
            contentType: .plainText
        )
        logger.debug("Captured: \(content.prefix(60).replacingOccurrences(of: "\n", with: "↵"))")
        onChange(entry)
    }
}

// MARK: - ClipboardEntry

/// A captured clipboard snapshot. Phase 0 carries only content and type.
/// Phase 1 adds source attribution, source_confidence, and full content type detection.
public struct ClipboardEntry {
    public let id: String
    public let content: String
    public let contentType: ContentType
    public let capturedAt: Date

    public init(
        id: String = UUID().uuidString,
        content: String,
        contentType: ContentType,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.capturedAt = capturedAt
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
