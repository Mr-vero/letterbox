// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Letterbox",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Letterbox",
            path: "Sources/Letterbox",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "LetterboxTests", dependencies: ["Letterbox"], path: "Tests/LetterboxTests"),
    ],
    swiftLanguageModes: [.v5]
)
