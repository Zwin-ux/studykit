// swift-tools-version: 5.9
import PackageDescription

// Shared engine for Nursebook and One More Shift (Zwin-ux/nursebook#297).
// No third-party dependencies. The ad SDK itself lives in the game app, behind `RewardedAdProvider`.
let package = Package(
    name: "StudyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StudyKit", targets: ["StudyKit"]),
        // One More Shift only. Nursebook never links this (its tools/test_no_ads.py fails if it does).
        .library(name: "StudyKitAds", targets: ["StudyKitAds"]),
    ],
    targets: [
        .target(name: "StudyKit"),
        .target(name: "StudyKitAds", dependencies: ["StudyKit"]),
        .testTarget(name: "StudyKitTests", dependencies: ["StudyKit"]),
        .testTarget(name: "StudyKitAdsTests", dependencies: ["StudyKitAds"]),
    ]
)
