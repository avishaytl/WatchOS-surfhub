// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V16CorePackage",
    platforms: [
        .watchOS(.v10),
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "V16Core", targets: ["V16Core"]),
    ],
    targets: [
        .target(
            name: "V16Core",
            path: ".",
            exclude: [
                "JumpDetectorV16.swift",
                "V16SettingsView.swift",
                "V16_SPEC_HE.pdf",
                "V16_WATCH_INTEGRATION_REVIEW_HE.pdf",
                "V16_HANDOFF",
                "V16_1_HANDOFF",
                "V16_2_HANDOFF",
                "V16_3_HANDOFF",
                "V16_4_HANDOFF",
                "V16_5_HANDOFF",
                "V16_7_HANDOFF",
                "V16_7_INTEGRATION_NOTES.md",
                "Tests",
            ],
            sources: ["JumpEngineV16.swift"]
        ),
        .testTarget(
            name: "V16CoreTests",
            dependencies: ["V16Core"],
            path: "Tests/V16CoreTests"
        ),
    ]
)
