// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JumpReplay",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "V16CorePackage", path: "../../../engines/engine_v16"),
    ],
    targets: [
        .executableTarget(
            name: "JumpReplay",
            dependencies: [
                .product(name: "V16Core", package: "V16CorePackage"),
            ],
            path: "Sources/JumpReplay",
            exclude: [
                // JumpReplay exercises parsing, logging, and detection. Cloud
                // upload auth belongs to the Watch app and has its own runtime
                // dependencies, so it must not be compiled into this harness.
                "WatchSources/CloudSyncService.swift",
            ]
        ),
    ]
)
