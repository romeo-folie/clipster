import ClipsterCore
import Foundation
import XCTest

final class PermissionPreflightTests: XCTestCase {

    // MARK: - CapabilityReport

    func testIsReadyWhenGranted() {
        let report = CapabilityReport(pasteboardAccess: .granted, accessibilityAccess: .denied)
        XCTAssertTrue(report.isReady)
    }

    func testIsReadyWhenNotApplicable() {
        let report = CapabilityReport(pasteboardAccess: .notApplicable, accessibilityAccess: .denied)
        XCTAssertTrue(report.isReady)
    }

    func testIsReadyWhenNotDetermined() {
        // notDetermined = "not yet denied" — daemon starts optimistically
        let report = CapabilityReport(pasteboardAccess: .notDetermined, accessibilityAccess: .granted)
        XCTAssertTrue(report.isReady)
    }

    func testIsNotReadyWhenDenied() {
        let report = CapabilityReport(pasteboardAccess: .denied, accessibilityAccess: .granted)
        XCTAssertFalse(report.isReady)
    }

    // MARK: - Diagnostics

    func testDiagnosticsEmptyWhenGranted() {
        let report = CapabilityReport(pasteboardAccess: .granted, accessibilityAccess: .granted)
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    func testDiagnosticsContainsPasteboardDeniedLine() {
        let report = CapabilityReport(pasteboardAccess: .denied, accessibilityAccess: .granted)
        XCTAssertFalse(report.diagnostics.isEmpty)
        XCTAssertTrue(report.diagnostics.joined().contains("Pasteboard access denied"))
    }

    func testDiagnosticsContainsPasteboardNotDeterminedLine() {
        let report = CapabilityReport(pasteboardAccess: .notDetermined, accessibilityAccess: .granted)
        XCTAssertFalse(report.diagnostics.isEmpty)
        XCTAssertTrue(report.diagnostics.joined().contains("not yet requested"))
    }

    func testDiagnosticsContainsAccessibilityDeniedLine() {
        let report = CapabilityReport(pasteboardAccess: .granted, accessibilityAccess: .denied)
        XCTAssertFalse(report.diagnostics.isEmpty)
        XCTAssertTrue(report.diagnostics.joined().contains("Accessibility access denied"))
    }

    func testDiagnosticsNotApplicableGeneratesNoLines() {
        let report = CapabilityReport(pasteboardAccess: .notApplicable, accessibilityAccess: .notApplicable)
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    // MARK: - SecurityChecklist

    func testSecurityChecklistIsNonEmpty() {
        XCTAssertFalse(SecurityChecklist.items.isEmpty)
    }

    func testSecurityChecklistContainsNotarisation() {
        let items = SecurityChecklist.items
        XCTAssertTrue(items.contains(where: { $0.item == "Notarisation" }))
    }

    func testSecurityChecklistContainsTCC() {
        let items = SecurityChecklist.items
        XCTAssertTrue(items.contains(where: { $0.item.contains("Pasteboard") }))
    }

    func testSecurityChecklistContainsIPCSocket() {
        let items = SecurityChecklist.items
        XCTAssertTrue(items.contains(where: { $0.item.contains("IPC socket") }))
    }

    // MARK: - PermissionPreflight.run()

    func testRunReturnsAReport() {
        let report = PermissionPreflight.run()
        // Smoke: the method runs without crashing and returns a valid status
        let valid: [CapabilityStatus] = [.granted, .denied, .notDetermined, .notApplicable]
        XCTAssertTrue(valid.contains(report.pasteboardAccess))
        XCTAssertTrue(valid.contains(report.accessibilityAccess))
    }
}
