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
                "CloudSyncService.swift",
                "GoogleSignInService.swift",
                "JumpDetector.swift",
                "KitesurfJumpEngine.swift",
                "KitesurfJumpEngine_old.swift",
                "LocationManager.swift",
                "MotionManager.swift",
                "SessionLogger.swift",
                "SessionManager.swift",
                "WatchAuth.swift",
                "WatchConnectivityManager.swift",
                "WatchPairingStore.swift",
                "WatchSessionUploader.swift",
                "WorkoutManager.swift",
            ],
            sources: ["LiveSessionUploadState.swift"]
        ),
        .executableTarget(
            name: "WatchLiveSessionCoreChecks",
            dependencies: ["WatchLiveSessionCore"],
            path: "Tests/WatchLiveSessionCoreChecks"
        ),
    ]
)
