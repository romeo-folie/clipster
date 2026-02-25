import ClipsterCore
import Foundation
import XCTest

/// IPC v1 contract tests — PRD §7.6, §14.1.
///
/// These tests verify that the wire protocol has not regressed. Every assertion
/// maps to a specific PRD requirement. They must pass unchanged for any future
/// GUI client to remain compatible with the existing daemon.
final class IPCContractTests: XCTestCase {

    // MARK: - Protocol version

    func testProtocolVersionIsOne() {
        // PRD §7.6: protocol_version must be 1 for v1 wire format.
        XCTAssertEqual(ipcProtocolVersion, 1)
    }

    // MARK: - Command encoding (client → daemon)

    func testCommandEncodeContainsVersion() throws {
        let cmd = IPCCommand(command: "history")
        let data = try JSONEncoder().encode(cmd)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    func testCommandEncodeContainsId() throws {
        let cmd = IPCCommand(command: "history")
        let data = try JSONEncoder().encode(cmd)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["id"] as? String)
        XCTAssertFalse((json["id"] as! String).isEmpty)
    }

    func testCommandEncodeContainsCommand() throws {
        let cmd = IPCCommand(command: "ping")
        let data = try JSONEncoder().encode(cmd)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["command"] as? String, "ping")
    }

    func testCommandParamsEntryIDUsesSnakeCase() throws {
        let params = IPCParams(entryID: "abc-123")
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // PRD §7.6: field must be "entry_id" not "entryID"
        XCTAssertEqual(json["entry_id"] as? String, "abc-123")
        XCTAssertNil(json["entryID"])
    }

    // MARK: - Response encoding (daemon → client)

    func testSuccessResponseContainsProtocolVersion() throws {
        let resp = IPCResponse.success(id: "1", data: .empty)
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // PRD §7.6: response must carry "protocol_version" (snake_case)
        XCTAssertEqual(json["protocol_version"] as? Int, 1)
        XCTAssertNil(json["protocolVersion"])
    }

    func testSuccessResponseOkIsTrue() throws {
        let resp = IPCResponse.success(id: "1", data: .empty)
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testFailureResponseOkIsFalse() throws {
        let resp = IPCResponse.failure(id: "1", error: "not_found")
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "not_found")
    }

    func testVersionErrorUsesCanonicalErrorString() throws {
        let resp = IPCResponse.versionError(id: "9")
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // PRD §7.6: version error string must be exactly "unsupported_protocol_version"
        XCTAssertEqual(json["error"] as? String, "unsupported_protocol_version")
        XCTAssertEqual(json["ok"] as? Bool, false)
    }

    func testResponseIdEchoesRequest() {
        let requestID = "test-request-id-42"
        let resp = IPCResponse.success(id: requestID, data: .empty)
        XCTAssertEqual(resp.id, requestID)
    }

    // MARK: - Entry DTO field names (snake_case)

    func testIPCEntryFieldsAreSnakeCase() throws {
        // Build a minimal StoredEntry-compatible IPCEntry
        let entry = IPCEntry(
            id: "e1", contentType: "text", content: "hello", preview: nil,
            sourceBundle: "com.apple.Safari", sourceName: "Safari",
            sourceConfidence: "high", createdAt: 1_700_000_000, isPinned: false
        )
        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // All keys must use PRD §7.6 snake_case names
        XCTAssertNotNil(json["content_type"],      "missing content_type")
        XCTAssertNotNil(json["source_bundle"],     "missing source_bundle")
        XCTAssertNotNil(json["source_name"],       "missing source_name")
        XCTAssertNotNil(json["source_confidence"], "missing source_confidence")
        XCTAssertNotNil(json["created_at"],        "missing created_at")
        XCTAssertNotNil(json["is_pinned"],         "missing is_pinned")

        // Ensure no camelCase variants leaked through
        XCTAssertNil(json["contentType"])
        XCTAssertNil(json["sourceBundle"])
        XCTAssertNil(json["sourceName"])
        XCTAssertNil(json["sourceConfidence"])
        XCTAssertNil(json["createdAt"])
        XCTAssertNil(json["isPinned"])
    }

    // MARK: - Framing (4-byte big-endian length prefix)

    func testFramingRoundtrip() throws {
        let cmd = IPCCommand(command: "ping")
        let framed = try IPCFraming.encode(cmd)

        // Must have at least 4 bytes of header
        XCTAssertGreaterThan(framed.count, 4)

        // Decode the length prefix
        let length = framed.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).byEndianSwap() }
        XCTAssertEqual(Int(length), framed.count - 4)
    }

    func testReadFrameReturnBodyAndEmptyRemaining() throws {
        let cmd = IPCCommand(command: "ping")
        let framed = try IPCFraming.encode(cmd)

        let result = IPCFraming.readFrame(from: framed)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.remaining.isEmpty)
        XCTAssertFalse(result!.body.isEmpty)
    }

    func testReadFrameReturnsNilOnIncompleteBuffer() {
        // Only 3 bytes — not enough to read the 4-byte length prefix
        let partial = Data([0x00, 0x00, 0x01])
        XCTAssertNil(IPCFraming.readFrame(from: partial))
    }

    func testReadFrameReturnsNilWhenBodyIncomplete() throws {
        let cmd = IPCCommand(command: "ping")
        let framed = try IPCFraming.encode(cmd)
        // Truncate to 5 bytes (header + 1 body byte — incomplete)
        let truncated = framed.prefix(5)
        XCTAssertNil(IPCFraming.readFrame(from: Data(truncated)))
    }

    func testReadFrameHandlesMultipleMessages() throws {
        let cmd1 = IPCCommand(command: "ping")
        let cmd2 = IPCCommand(command: "history")
        var buffer = try IPCFraming.encode(cmd1)
        buffer.append(try IPCFraming.encode(cmd2))

        let first = IPCFraming.readFrame(from: buffer)
        XCTAssertNotNil(first)
        let second = IPCFraming.readFrame(from: first!.remaining)
        XCTAssertNotNil(second)
        XCTAssertTrue(second!.remaining.isEmpty)
    }

    // MARK: - Known v1 command names (backward-compat contract)

    func testKnownCommandNamesAreStrings() {
        // These are the 9 commands defined in PRD §7.5.
        // Adding new commands is fine; removing or renaming any of these is a breaking change.
        let v1Commands = [
            "ping", "history", "latest", "pins",
            "pin", "unpin", "delete", "transform", "status",
        ]
        // Verify no accidental whitespace or casing drift in the constant list
        for cmd in v1Commands {
            XCTAssertEqual(cmd, cmd.trimmingCharacters(in: .whitespaces).lowercased(),
                           "Command name '\(cmd)' must be lowercase trimmed")
        }
        XCTAssertEqual(v1Commands.count, 9)
    }
}

// MARK: - Test helpers

private extension UInt32 {
    func byEndianSwap() -> UInt32 { UInt32(bigEndian: self) }
}
