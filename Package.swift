// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mercury-recorder",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "mercury-recorder",
            path: "Sources/MercuryRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
