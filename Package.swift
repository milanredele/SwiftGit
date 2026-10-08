// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GitUI",
    platforms: [.macOS(.v14)],
    targets: [
        // All app code lives in the library so tests can drive it in-process.
        .target(
            name: "GitUIKit",
            path: "Sources/GitUIKit"
        ),
        .executableTarget(
            name: "GitUI",
            dependencies: ["GitUIKit"],
            path: "Sources/GitUI"
        ),
        .testTarget(
            name: "GitUITests",
            dependencies: ["GitUIKit"],
            path: "Tests/GitUITests"
        ),
    ]
)
