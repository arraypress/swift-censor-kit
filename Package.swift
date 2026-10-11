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
    targets: [
        .target(name: "CensorKit"),
        .testTarget(name: "CensorKitTests", dependencies: ["CensorKit"]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
