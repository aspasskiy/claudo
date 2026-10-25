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
        // Merge rules, owner actions, the digest, answer decoding, compaction — no model calls.
        .testTarget(
            name: "ClaudoCoreTests",
            dependencies: ["ClaudoCore"],
            path: "Tests/ClaudoCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
