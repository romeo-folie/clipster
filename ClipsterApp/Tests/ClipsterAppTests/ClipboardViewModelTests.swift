import ClipsterCore
import Combine
import Foundation
import XCTest
@testable import ClipsterApp

final class ClipboardViewModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testRefreshReconnectsAfterInitialDatabaseFailure() throws {
        let databaseURL = temporaryDatabaseURL(prefix: "clipster-view-model-test")

        let writer = try ClipsterDatabase(url: databaseURL)
        try writer.insert(ClipboardEntry(content: "existing entry", contentType: .plainText))

        let initialFailure = expectation(description: "initial database open fails")
        let attemptLock = NSLock()
        var attempts = 0
        let viewModel = ClipboardViewModel(
            databaseFactory: {
                attemptLock.lock()
                defer { attemptLock.unlock() }
                attempts += 1
                if attempts == 1 {
                    initialFailure.fulfill()
                    throw TestError.transientOpenFailure
                }
                return try ClipsterDatabase(url: databaseURL, accessMode: .readOnly)
            },
            autoRefreshInterval: 0.1
        )

        wait(for: [initialFailure], timeout: 2)
        XCTAssertFalse(viewModel.databaseAvailable)
        XCTAssertTrue(viewModel.historyEntries.isEmpty)

        let existingHistoryLoaded = expectation(description: "existing history loads after retry")
        viewModel.$historyEntries
            .dropFirst()
            .filter { $0.map(\.content) == ["existing entry"] }
            .sink { _ in existingHistoryLoaded.fulfill() }
            .store(in: &cancellables)

        wait(for: [existingHistoryLoaded], timeout: 2)
        XCTAssertTrue(viewModel.databaseAvailable)

        try writer.insert(ClipboardEntry(content: "new copy", contentType: .plainText))
        let newCopyLoaded = expectation(description: "new copy appears without recreating view model")
        viewModel.$historyEntries
            .dropFirst()
            .filter { $0.map(\.content) == ["new copy", "existing entry"] }
            .sink { _ in newCopyLoaded.fulfill() }
            .store(in: &cancellables)

        viewModel.refresh()
        wait(for: [newCopyLoaded], timeout: 2)
        XCTAssertTrue(viewModel.databaseAvailable)
    }

    func testEmptyDatabaseIsAvailableRatherThanUnavailable() throws {
        let databaseURL = temporaryDatabaseURL(prefix: "clipster-empty-view-model-test")
        _ = try ClipsterDatabase(url: databaseURL)

        let viewModel = ClipboardViewModel(
            databaseFactory: {
                try ClipsterDatabase(url: databaseURL, accessMode: .readOnly)
            },
            autoRefreshInterval: nil
        )
        let available = expectation(description: "empty database is available")
        viewModel.$databaseAvailable
            .filter { $0 }
            .sink { _ in available.fulfill() }
            .store(in: &cancellables)

        wait(for: [available], timeout: 2)
        XCTAssertTrue(viewModel.historyEntries.isEmpty)
        XCTAssertTrue(viewModel.pinnedEntries.isEmpty)
    }

    private func temporaryDatabaseURL(prefix: String) -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).db")
        addTeardownBlock {
            let directory = databaseURL.deletingLastPathComponent()
            let filename = databaseURL.lastPathComponent
            for url in (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? [] where url.lastPathComponent.hasPrefix(filename) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return databaseURL
    }
}

private enum TestError: Error {
    case transientOpenFailure
}
