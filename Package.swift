// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftGit",
    platforms: [.macOS(.v14)],
    targets: [
        // All app code lives in the library so tests can drive it in-process.
        .target(
            name: "SwiftGitKit",
            path: "Sources/SwiftGitKit"
        ),
        .executableTarget(
            name: "SwiftGit",
            dependencies: ["SwiftGitKit"],
            path: "Sources/SwiftGit"
        ),
        .testTarget(
            name: "SwiftGitTests",
            dependencies: ["SwiftGitKit"],
            path: "Tests/SwiftGitTests"
        ),
    ]
)
