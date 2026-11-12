// swift-tools-version: 5.9
import PackageDescription

// Shared engine for Nursebook and One More Shift (Zwin-ux/nursebook#297).
// No third-party dependencies. Ads live in a separate target (added with the AdGate issue) that Nursebook never links.
let package = Package(
    name: "StudyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StudyKit", targets: ["StudyKit"])],
    targets: [
        .target(name: "StudyKit"),
        .testTarget(name: "StudyKitTests", dependencies: ["StudyKit"]),
    ]
)
