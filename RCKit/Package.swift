// swift-tools-version: 6.2
import PackageDescription

// RCKit: the RC-N3 input layer. No UI code, so the flight simulator can reuse it.
// RCKitProbe: reverse-engineering diagnostics built on RCKit, used by the probe dashboard.
// Swift 6 language mode (strict concurrency) is the default for tools-version 6.x.
let package = Package(
    name: "RCKit",
    platforms: [
        .iOS(.v18),
        // macOS only so `swift test` can run the protocol tests on the Mac.
        .macOS(.v15),
    ],
    products: [
        .library(name: "RCKit", targets: ["RCKit"]),
        .library(name: "RCKitProbe", targets: ["RCKitProbe"]),
    ],
    targets: [
        .target(name: "RCKit"),
        .target(name: "RCKitProbe", dependencies: ["RCKit"]),
        // Fixtures/ holds recordings read by path in tests (not bundled resources).
        .testTarget(name: "RCKitTests", dependencies: ["RCKit"], exclude: ["Fixtures"]),
        .testTarget(name: "RCKitProbeTests", dependencies: ["RCKitProbe"]),
    ]
)
