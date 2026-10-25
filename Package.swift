// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Claudo",
    platforms: [.macOS(.v14)],
    targets: [
        // Reads Claude Code transcripts and asks the local `claude` CLI for a plan.
        .target(
            name: "ClaudoCore",
            path: "Sources/ClaudoCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Claudo",
            dependencies: ["ClaudoCore"],
            path: "Sources/Claudo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Terminal harness: print the digest or run a plan without the UI.
        .executableTarget(
            name: "claudo-cli",
            dependencies: ["ClaudoCore"],
            path: "Sources/claudo-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Merge rules, owner actions, the digest, answer decoding, compaction — no model calls.
        .testTarget(
            name: "ClaudoCoreTests",
            dependencies: ["ClaudoCore"],
            path: "Tests/ClaudoCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app's pure helpers: Today's layout and the words rows print.
        .testTarget(
            name: "ClaudoTests",
            dependencies: ["Claudo", "ClaudoCore"],
            path: "Tests/ClaudoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
