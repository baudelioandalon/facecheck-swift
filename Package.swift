// swift-tools-version: 6.0

import PackageDescription

// The Swift 6 language mode, on both targets rather than just the library.
//
// Under tools-version 5.9 every data-race diagnostic was a warning, so the
// `@unchecked Sendable` reasoning in `AVCameraController`, `StateStream` and
// `ChallengeMachine` was documented but never checked: the first change that
// introduced a real race would have compiled, with a warning CI does not break
// on. In the v6 mode those are errors.
//
// The test target gets the same mode because it exercises the very Sendable
// boundaries the SDK promises integrators — a `ChallengeMachine` fed from one
// task and observed from another — and compiling the tests under looser rules
// would hide exactly the races that matter.
//
// Note the spelling: `StrictConcurrency` is an *upcoming* feature, so the old
// `.enableExperimentalFeature("StrictConcurrency")` was both obsolete and, in
// the Swift 5 mode, warnings-only. The language mode subsumes it.
let swift6: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]

let package = Package(
    name: "FaceCheck",
    // iOS 15 is the floor, and several port decisions hang off it: no Swift
    // `Regex` (16), no `OSAllocatedUnfairLock` (16), no `Duration`/`ContinuousClock`
    // (16), no `Synchronization.Mutex` (18), no `@Observable` (17). Raising the
    // floor later is a simplification, never a behaviour change.
    platforms: [
        .iOS(.v15),
        // macOS is here **only** so `swift build` and `swift test` work from the
        // command line: SwiftPM builds for the host platform by default, and
        // with no macOS floor declared it falls back to 10.13, where async/await,
        // `Date(_:strategy: .iso8601)` and `URLSession.upload(for:from:)` do not
        // exist. Everything outside the camera layer is plain Foundation and
        // compiles fine there; the AVFoundation/UIKit controller is `#if
        // canImport(UIKit)`-gated and simply is not part of a macOS build.
        // This is a build-tooling affordance, not a shipping macOS product.
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "FaceCheck",
            targets: ["FaceCheck"]
        )
    ],
    // No third-party dependencies, deliberately. A biometric SDK that drags in a
    // networking stack forces its version choices onto every host app, and the
    // one thing this package must be is installable.
    //
    // No trailing commas anywhere in this file either: those are SE-0439, which
    // landed in Swift 6.1, and a manifest that fails to *parse* on an older
    // toolchain reports a syntax error rather than a minimum-version message.
    // Tools-version 6.0 keeps Xcode 16.0 able to resolve the package.
    targets: [
        .target(
            name: "FaceCheck",
            swiftSettings: swift6
        ),
        .testTarget(
            name: "FaceCheckTests",
            dependencies: ["FaceCheck"],
            swiftSettings: swift6
        )
    ]
)
