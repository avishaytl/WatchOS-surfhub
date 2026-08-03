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
            path: "Sources/JumpReplay"
        ),
    ]
)
