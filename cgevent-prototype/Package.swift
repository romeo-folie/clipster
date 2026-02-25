// swift-tools-version: 5.9
import PackageDescription

// CGEvent paste prototype — Phase 5 Go/No-Go gate.
// PRD v3 §7.3: CGEvent paste must be proven functional with a notarised binary
// before any GUI work begins.

let package = Package(
    name: "cgevent-prototype",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "cgevent-prototype",
            path: "Sources/cgevent-prototype"
        )
    ]
)
