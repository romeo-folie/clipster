// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipsterApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../clipsterd"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            from: "2.9.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "ClipsterApp",
            dependencies: [
                .product(name: "ClipsterCore", package: "clipsterd"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClipsterApp",
            // Info.plist and .entitlements are consumed by scripts/build-app.sh
            // at bundle assembly time — not compiled by SPM.
            exclude: [
                "Info.plist",
                "ClipsterApp.entitlements",
            ]
        ),
    ]
)
