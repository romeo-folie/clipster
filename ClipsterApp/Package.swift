// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipsterApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "../clipsterd"),
    ],
    targets: [
        .executableTarget(
            name: "ClipsterApp",
            dependencies: [
                .product(name: "ClipsterCore", package: "clipsterd"),
            ],
            path: "Sources/ClipsterApp"
        ),
    ]
)
