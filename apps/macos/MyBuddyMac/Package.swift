// swift-tools-version: 6.0
// MyBuddy for Mac. Builds with the Command Line Tools (no Xcode required):
//   scripts/test.sh       — Swift Testing suites
//   scripts/build-app.sh  — release build bundled into build/MyBuddy.app (ad-hoc signed)
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MyBuddyMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyBuddy", targets: ["MyBuddyMac"]),
    ],
    dependencies: [
        // libwebrtc M150 as a checksum-pinned binary XCFramework (MIT packaging, WebRTC BSD-3-Clause).
        // Same M150 branch as the Android build (io.github.webrtc-sdk:android 150.7871.01).
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.03"),
    ],
    targets: [
        .target(name: "MyBuddyCore", swiftSettings: strict),
        .target(name: "MyBuddyHost", dependencies: ["MyBuddyCore"], swiftSettings: strict),
        .target(name: "MyBuddyDesign", swiftSettings: strict),
        // ScreenCaptureKit capture + WebRTC publishing. The only target that links libwebrtc.
        .target(
            name: "MyBuddyMedia",
            dependencies: ["MyBuddyCore", "MyBuddyHost", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MyBuddyMac",
            dependencies: ["MyBuddyCore", "MyBuddyHost", "MyBuddyDesign", "MyBuddyMedia"],
            swiftSettings: strict
        ),
        // Test-only frame sources (a labelled test pattern). Never linked into MyBuddy.app.
        .target(name: "MyBuddyTestSupport", dependencies: ["MyBuddyMedia"], swiftSettings: strict),
        // Test-only: loopback host for driving the Android app end-to-end without the GUI. Not bundled.
        .executableTarget(name: "MyBuddyInteropHost", dependencies: ["MyBuddyCore", "MyBuddyHost", "MyBuddyMedia", "MyBuddyTestSupport"],
                          swiftSettings: strict),
        .testTarget(name: "MyBuddyCoreTests", dependencies: ["MyBuddyCore"], swiftSettings: strict),
        .testTarget(name: "MyBuddyHostTests", dependencies: ["MyBuddyHost", "MyBuddyCore"], swiftSettings: strict),
        .testTarget(name: "MyBuddyMediaTests",
                    dependencies: ["MyBuddyMedia", "MyBuddyTestSupport", "MyBuddyCore", "MyBuddyHost",
                                   .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")],
                    swiftSettings: strict),
    ]
)
