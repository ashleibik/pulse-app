// swift-tools-version: 6.0
//
// PulseCore: the platform-independent heart of Pulse.
//
// Rule for this package: Foundation only. No SwiftUI, SwiftData, CoreBluetooth or HealthKit.
// That's what lets it compile and run its tests on Windows and Linux too (`swift test`),
// not just in Xcode. The iOS app (ios/Pulse) depends on it.
//
// Contents grow by phase:
//   Phase 2  Models (+ a fake data generator, in the tests only)
//   Phase 3  Metrics                (HRV, resting HR, sleep, strain, recovery)
//   Phase 5  WhoopProtocol          (Swift port of re-toolkit/protocol)

import PackageDescription

let package = Package(
    name: "PulseCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
    ],
    targets: [
        .target(name: "PulseCore"),
        // The fake data generator and the simulated band live in Tests/PulseCoreTests/Support,
        // so they are never part of the app build.
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    ]
)
