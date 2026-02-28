// swift-tools-version: 5.9
import PackageDescription

// ClipsterCore is a library target so it can be:
// 1. Imported by tests without the executable entry point
// 2. Extended by the GUI phase (AppKit layer) without rewriting core
// See PRD §14.1 — architectural decision (binding).

let package = Package(
    name: "clipsterd",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ClipsterCore", targets: ["ClipsterCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "6.0.0"
        ),
    ],
    targets: [
        // Core library — clipboard monitoring, storage, logging.
        // Deliberately no IPC or AppKit dependencies at this layer.
        // IPC server will be a separate target in Phase 1.
        .target(
            name: "ClipsterCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/ClipsterCore"
        ),

        // Thin executable — wires Core together, handles signals, runs RunLoop.
        .executableTarget(
            name: "clipsterd",
            dependencies: [
                "ClipsterCore",
            ],
            path: "Sources/clipsterd"
        ),

        // Tests for ClipsterCore
        .testTarget(
            name: "ClipsterCoreTests",
            dependencies: [
                "ClipsterCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/ClipsterCoreTests"
        ),
    ]
)
