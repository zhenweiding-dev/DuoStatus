// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DuoStatus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DuoStatus",
            path: "Sources/DuoStatus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
