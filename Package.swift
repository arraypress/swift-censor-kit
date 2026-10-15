// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "swift-censor-kit",
    platforms: [
        // Matches the fleet's media libraries; the Vision and
        // SensitiveContentAnalysis surface used here is present from 26.
        .macOS(.v26)
    ],
    products: [
        .library(name: "CensorKit", targets: ["CensorKit"]),
    ],
    dependencies: [
        // The writer settings and the deadlock-free writer feeding — one
        // copy, shared with `vid`, rather than a fork of each here.
        .package(url: "https://github.com/arraypress/swift-video-forge.git", from: "0.5.0"),
    ],
    targets: [
        .target(name: "CensorKit", dependencies: [
            .product(name: "VideoForge", package: "swift-video-forge"),
        ]),
        .testTarget(name: "CensorKitTests", dependencies: [
            "CensorKit",
            .product(name: "VideoForge", package: "swift-video-forge"),
        ]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
