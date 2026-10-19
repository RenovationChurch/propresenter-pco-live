// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PCOSync",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PCOSync", targets: ["PCOSync"]),
    ],
    targets: [
        // Everything except the menu bar: engine, API clients, config, web UI.
        // Builds on Linux too, so it can be tested without a Mac.
        .target(name: "PCOSyncCore"),
        .executableTarget(name: "PCOSync", dependencies: ["PCOSyncCore"]),
        .testTarget(name: "PCOSyncCoreTests", dependencies: ["PCOSyncCore"]),
    ]
)
