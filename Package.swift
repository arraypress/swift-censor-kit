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
