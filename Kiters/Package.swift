// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KitersWatchTests",
    platforms: [
        .watchOS(.v10),
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "WatchLiveSessionCore", targets: ["WatchLiveSessionCore"]),
        .executable(name: "WatchLiveSessionCoreChecks", targets: ["WatchLiveSessionCoreChecks"]),
    ],
    targets: [
        .target(
            name: "WatchLiveSessionCore",
            path: "Kiters Watch App/Services",
            exclude: [
                "AuthService.swift",
                "BinaryLogEnvelope.swift",
                "CloudSyncService.swift",
                "GoogleSignInService.swift",
                "JumpDetecting.swift",
                "JumpDetector.swift",
                "JumpDetectorV8.swift",
                "JumpDetectorV9.swift",
                "JumpDetectorV10.swift",
                "JumpDetectorV11.swift",
                "JumpDetectorV12.swift",
                "JumpDetectorV13.swift",
                "KitesurfJumpEngine.swift",
                "KitesurfJumpEngine_old.swift",
                "KitesurfJumpEngineV8.swift",
                "KitesurfJumpEngineV9.swift",
                "KitesurfJumpEngineV10.swift",
                "KitesurfJumpEngineV11.swift",
                "LocationManager.swift",
                "MotionManager.swift",
                "SessionLogger.swift",
                "SessionManager.swift",
                "WatchAuth.swift",
                "WatchConnectivityManager.swift",
                "WatchPairingStore.swift",
                "WatchSessionUploader.swift",
                "WaterSubmersionManager.swift",
                "WorkoutManager.swift",
            ],
            sources: ["LiveSessionUploadState.swift", "JumpEngineV12.swift", "JumpEngineV13.swift"]
        ),
        .executableTarget(
            name: "WatchLiveSessionCoreChecks",
            dependencies: ["WatchLiveSessionCore"],
            path: "Tests/WatchLiveSessionCoreChecks"
        ),
    ]
)
