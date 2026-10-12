// swift-tools-version: 6.2
import PackageDescription

// RCKit: the RC-N3 input layer. No UI code lives here so the flight simulator can reuse it.
// Swift 6 language mode (strict concurrency) is the default for tools-version 6.x.
let package = Package(
    name: "RCKit",
    platforms: [
        .iOS(.v18),
        // macOS only so `swift test` can run the pure protocol tests on the Mac.
        .macOS(.v15),
    ],
    products: [
        .library(name: "RCKit", targets: ["RCKit"]),
    ],
    targets: [
        .target(name: "RCKit"),
        .testTarget(name: "RCKitTests", dependencies: ["RCKit"]),
    ]
)
