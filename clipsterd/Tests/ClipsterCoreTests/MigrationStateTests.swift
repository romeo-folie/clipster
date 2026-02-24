import ClipsterCore
import Foundation
import XCTest

final class MigrationStateTests: XCTestCase {

    // MARK: - Helpers

    private func tmpPlistURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.clipster.test-\(UUID().uuidString).plist")
    }

    // MARK: - Legacy-only (plist present, no app env)

    func testLegacyOnlyWhenPlistExistsAndNoEnv() throws {
        let plist = tmpPlistURL()
        try "dummy".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }

        let state = MigrationState.detect(plistURL: plist, env: [:])
        XCTAssertEqual(state.installMode, .launchAgent)
        XCTAssertEqual(state.migrationPhase, .legacyOnly)
        XCTAssertTrue(state.hasLaunchAgentPlist)
        XCTAssertFalse(state.hasAppModeEnv)
    }

    // MARK: - App-only (no plist, app env set)

    func testAppOnlyWhenNoPlistAndAppEnv() {
        let missing = tmpPlistURL() // guaranteed not to exist
        let state = MigrationState.detect(plistURL: missing, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertEqual(state.installMode, .appBundle)
        XCTAssertEqual(state.migrationPhase, .appOnly)
        XCTAssertFalse(state.hasLaunchAgentPlist)
        XCTAssertTrue(state.hasAppModeEnv)
    }

    // MARK: - Dual mode (plist + app env)

    func testDualModeWhenBothPresent() throws {
        let plist = tmpPlistURL()
        try "dummy".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }

        let state = MigrationState.detect(plistURL: plist, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertEqual(state.installMode, .appBundle)
        XCTAssertEqual(state.migrationPhase, .dual)
        XCTAssertTrue(state.hasLaunchAgentPlist)
        XCTAssertTrue(state.hasAppModeEnv)
    }

    // MARK: - Fresh install (nothing present)

    func testFreshInstallFallsToLegacy() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: [:])
        XCTAssertEqual(state.installMode, .launchAgent)
        XCTAssertEqual(state.migrationPhase, .legacyOnly)
        XCTAssertFalse(state.hasLaunchAgentPlist)
        XCTAssertFalse(state.hasAppModeEnv)
    }

    // MARK: - Env case-insensitive

    func testEnvValueIsCaseInsensitive() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: ["CLIPSTER_RUNTIME_MODE": "APP"])
        XCTAssertEqual(state.installMode, .appBundle)
        XCTAssertEqual(state.migrationPhase, .appOnly)
    }

    // MARK: - Rollback steps

    func testRollbackStepsLegacyIsEmpty() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: [:])
        XCTAssertEqual(state.rollbackSteps.count, 1) // "no rollback needed"
    }

    func testRollbackStepsDualHasInstructions() throws {
        let plist = tmpPlistURL()
        try "dummy".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }

        let state = MigrationState.detect(plistURL: plist, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertGreaterThan(state.rollbackSteps.count, 1)
    }

    func testRollbackStepsAppOnlyHasInstructions() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertGreaterThan(state.rollbackSteps.count, 1)
    }

    // MARK: - Compatibility warning

    func testCompatibilityWarningLegacyIsNil() throws {
        let plist = tmpPlistURL()
        try "dummy".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }

        let state = MigrationState.detect(plistURL: plist, env: [:])
        XCTAssertNil(state.compatibilityWarning(for: "start"))
    }

    func testCompatibilityWarningDualIsNotNil() throws {
        let plist = tmpPlistURL()
        try "dummy".write(to: plist, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plist) }

        let state = MigrationState.detect(plistURL: plist, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertNotNil(state.compatibilityWarning(for: "start"))
    }

    func testCompatibilityWarningAppOnlyStartIsNotNil() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertNotNil(state.compatibilityWarning(for: "start"))
    }

    func testCompatibilityWarningAppOnlyStatusIsNil() {
        let missing = tmpPlistURL()
        let state = MigrationState.detect(plistURL: missing, env: ["CLIPSTER_RUNTIME_MODE": "app"])
        XCTAssertNil(state.compatibilityWarning(for: "status"))
    }
}
