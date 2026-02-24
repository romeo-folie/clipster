import ClipsterCore
import Foundation
import XCTest

/// Tests for ClipboardMonitor — Phase 0 coverage.
///
/// Integration tests that mutate NSPasteboard run on the main thread and
/// require the test runner to have pasteboard access (normal for a user session).
final class ClipboardMonitorTests: XCTestCase {

    // MARK: - Configuration

    func testPollIntervalIs250ms() {
        let monitor = ClipboardMonitor { _ in }
        XCTAssertEqual(monitor.pollInterval, 0.250, accuracy: 0.001)
    }

    func testDebounceDelayIs50ms() {
        let monitor = ClipboardMonitor { _ in }
        XCTAssertEqual(monitor.debounceDelay, 0.050, accuracy: 0.001)
    }

    // MARK: - Lifecycle

    func testStopBeforeStartIsSafe() {
        let monitor = ClipboardMonitor { _ in }
        monitor.stop()  // must not crash
    }

    func testStopIsIdempotent() {
        let monitor = ClipboardMonitor { _ in }
        monitor.start()
        monitor.stop()
        monitor.stop()  // second stop — must not crash
    }

    // MARK: - Change detection (integration — requires pasteboard access)

    func testCapturesPlainTextChange() {
        let uniqueContent = "clipster-test-\(UUID().uuidString)"
        let captured = LockProtected<[ClipboardEntry]>([])
        let expectation = expectation(description: "Entry captured")
        expectation.assertForOverFulfill = false

        let monitor = ClipboardMonitor { entry in
            if entry.content == uniqueContent {
                captured.mutate { $0.append(entry) }
                expectation.fulfill()
            }
        }
        monitor.start()

        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uniqueContent, forType: .string)
        }

        // poll (250ms) + debounce (50ms) + margin (200ms)
        wait(for: [expectation], timeout: 1.0)
        monitor.stop()

        XCTAssertTrue(captured.value.contains(where: { $0.content == uniqueContent }))
    }

    func testDebounceCapturesFinalValue() {
        let finalContent = "clipster-final-\(UUID().uuidString)"
        let captured = LockProtected<[ClipboardEntry]>([])
        let expectation = expectation(description: "Final entry captured")
        expectation.assertForOverFulfill = false

        let monitor = ClipboardMonitor { entry in
            if entry.content == finalContent {
                captured.mutate { $0.append(entry) }
                expectation.fulfill()
            }
        }
        monitor.start()

        // Wait for monitor to establish baseline changeCount
        Thread.sleep(forTimeInterval: 0.300)

        // Rapid writes within a single debounce window
        // Note: NSPasteboard.general is safe to write from any thread.
        // Avoid DispatchQueue.main.sync here — tests run on the main thread
        // and self-dispatching synchronously would deadlock.
        for i in 0..<5 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("intermediate-\(i)", forType: .string)
            Thread.sleep(forTimeInterval: 0.010)
        }
        // Final value — this is what should be captured
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalContent, forType: .string)

        wait(for: [expectation], timeout: 1.5)
        monitor.stop()

        XCTAssertTrue(captured.value.contains(where: { $0.content == finalContent }))
    }

    func testStoppedMonitorDoesNotCapture() {
        let uniqueContent = "clipster-stopped-\(UUID().uuidString)"
        let captured = LockProtected<[ClipboardEntry]>([])

        let monitor = ClipboardMonitor { entry in
            captured.mutate { $0.append(entry) }
        }
        monitor.start()
        monitor.stop()

        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uniqueContent, forType: .string)
        }

        Thread.sleep(forTimeInterval: 0.600)

        XCTAssertFalse(captured.value.contains(where: { $0.content == uniqueContent }))
    }
}

// MARK: - Helpers

/// Thread-safe value wrapper for capturing results from background callbacks.
final class LockProtected<T: Sendable>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T { lock.withLock { _value } }

    func mutate(_ block: (inout T) -> Void) {
        lock.withLock { block(&_value) }
    }
}
