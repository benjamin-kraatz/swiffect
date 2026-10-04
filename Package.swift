// swift-tools-version: 6.4

import PackageDescription

// Concurrency settings
//
// The package builds in the Swift 6 language mode with strict concurrency checking and
// deliberately does NOT enable the `ApproachableConcurrency` feature set. Its main component,
// `NonisolatedNonsendingByDefault`, makes nonisolated `async` functions and closures inherit
// the caller's actor. Swiffect's runtime stores `@Sendable async` closures inside effects and
// runs them later on fibers (unstructured tasks) that are never bound to an actor. With the
// classic Swift 6 rules a nonisolated async function always runs on the global concurrent
// executor, so the place where an effect body executes does not depend on who happens to call
// `run()`. That keeps scheduling, interruption and stack behaviour the same everywhere.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "Swiffect",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "Swiffect",
            targets: ["Swiffect"]
        ),
    ],
    targets: [
        .target(
            name: "Swiffect",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SwiffectTests",
            dependencies: ["Swiffect"],
            swiftSettings: swiftSettings
        ),
    ]
)
