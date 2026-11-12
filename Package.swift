// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Grabadora",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Grabadora",
            path: "Sources/Grabadora",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
