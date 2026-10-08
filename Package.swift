// swift-tools-version:5.9
import PackageDescription

/// Tree-sitter grammars used for syntax highlighting in diffs: (package, product).
let grammars: [(package: String, product: String)] = [
    ("tree-sitter-swift", "TreeSitterSwift"),
    ("tree-sitter-javascript", "TreeSitterJavaScript"),
    ("tree-sitter-typescript", "TreeSitterTypeScript"),
    ("tree-sitter-python", "TreeSitterPython"),
    ("tree-sitter-go", "TreeSitterGo"),
    ("tree-sitter-rust", "TreeSitterRust"),
    ("tree-sitter-c", "TreeSitterC"),
    ("tree-sitter-cpp", "TreeSitterCPP"),
    ("tree-sitter-java", "TreeSitterJava"),
    ("tree-sitter-json", "TreeSitterJSON"),
    ("tree-sitter-bash", "TreeSitterBash"),
    ("tree-sitter-ruby", "TreeSitterRuby"),
    ("tree-sitter-css", "TreeSitterCSS"),
    ("tree-sitter-html", "TreeSitterHTML"),
    ("tree-sitter-c-sharp", "TreeSitterCSharp"),
    ("tree-sitter-ada", "TreeSitterAda"),
]

let package = Package(
    name: "SwiftGit",
    platforms: [.macOS(.v14)],
    // javascript/python/css are held at 0.23.x: their 0.25 manifests look for
    // src/scanner.c relative to the wrong directory and drop the scanner.
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        // The Swift grammar only ships its generated parser on this branch.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", .upToNextMinor(from: "0.23.0")),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", .upToNextMinor(from: "0.23.0")),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", .upToNextMinor(from: "0.23.0")),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp", from: "0.23.0"),
        // No semver tags on this repo yet, so track its main branch.
        .package(url: "https://github.com/briot/tree-sitter-ada", branch: "master"),
    ],
    targets: [
        // All app code lives in the library so tests can drive it in-process.
        .target(
            name: "SwiftGitKit",
            dependencies: [.product(name: "SwiftTreeSitter", package: "swift-tree-sitter")]
                + grammars.map { .product(name: $0.product, package: $0.package) },
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
