// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dott",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Dott",
            path: "Sources/Dott",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
