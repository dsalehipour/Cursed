// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cursed",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "cursed",
            path: "Sources/cursed",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
