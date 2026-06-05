// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JumpReplay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JumpReplay",
            path: "Sources/JumpReplay"
        ),
    ]
)
