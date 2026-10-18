// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EyeTrackKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "EyeTrackCore", targets: ["EyeTrackCore"]),
        .library(name: "EyeTrackUI", targets: ["EyeTrackUI"]),
        .library(name: "EyeTrackVisionCamera", targets: ["EyeTrackVisionCamera"]),
        .library(name: "EyeTrackARKit", targets: ["EyeTrackARKit"]),
        .library(name: "EyeTrackMacWindowing", targets: ["EyeTrackMacWindowing"]),
        .library(name: "EyeSpyFeed", targets: ["EyeSpyFeed"]),
        .executable(name: "EyeSpy", targets: ["EyeSpy"])
    ],
    targets: [
        .target(name: "EyeTrackCore"),
        .target(name: "EyeTrackVisionCamera", dependencies: ["EyeTrackCore"]),
        .target(name: "EyeTrackARKit", dependencies: ["EyeTrackCore", "EyeTrackVisionCamera"]),
        .target(name: "EyeTrackUI", dependencies: ["EyeTrackCore"]),
        .target(name: "EyeTrackMacWindowing", dependencies: ["EyeTrackCore"]),
        .target(name: "EyeSpyFeed", dependencies: ["EyeTrackCore"]),
        .executableTarget(name: "EyeSpy", dependencies: ["EyeTrackUI", "EyeTrackVisionCamera", "EyeTrackMacWindowing", "EyeSpyFeed"]),
        .testTarget(name: "EyeTrackCoreTests", dependencies: ["EyeTrackCore"]),
        .testTarget(name: "EyeSpyFeedTests", dependencies: ["EyeSpyFeed"]),
        .testTarget(name: "EyeTrackProviderTests", dependencies: ["EyeTrackVisionCamera", "EyeTrackMacWindowing"])
    ]
)
