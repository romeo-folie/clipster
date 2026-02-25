import ClipsterCore
import XCTest

final class RuntimeTests: XCTestCase {
    func testDefaultModeIsHeadless() {
        let options = RuntimeOptions.parse(args: ["clipsterd"], env: [:])
        XCTAssertEqual(options.mode, .headless)
    }

    func testEnvModeApp() {
        let options = RuntimeOptions.parse(
            args: ["clipsterd"],
            env: ["CLIPSTER_RUNTIME_MODE": "app"]
        )
        XCTAssertEqual(options.mode, .app)
    }

    func testEnvInvalidFallsBackToHeadless() {
        let options = RuntimeOptions.parse(
            args: ["clipsterd"],
            env: ["CLIPSTER_RUNTIME_MODE": "weird"]
        )
        XCTAssertEqual(options.mode, .headless)
    }

    func testArgOverridesEnv() {
        let options = RuntimeOptions.parse(
            args: ["clipsterd", "--runtime-mode=headless"],
            env: ["CLIPSTER_RUNTIME_MODE": "app"]
        )
        XCTAssertEqual(options.mode, .headless)
    }

    func testArgModeApp() {
        let options = RuntimeOptions.parse(
            args: ["clipsterd", "--runtime-mode=app"],
            env: [:]
        )
        XCTAssertEqual(options.mode, .app)
    }
}
