// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cursed",
    // Liquid Glass (GlassEffectContainer, glassEffect, morphing transitions) is macOS 26.
    // Spelled as a string because this toolchain's PackageDescription predates `.v26`.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "cursed",
            path: "Sources/cursed",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
