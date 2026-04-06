// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "localtimequota",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Shared models, IPC protocol, ledger I/O
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),

        // Root-level privileged daemon (LaunchDaemon)
        .executableTarget(
            name: "Daemon",
            dependencies: ["Shared"],
            path: "Sources/Daemon"
        ),

        // Per-user GUI session agent (LaunchAgent)
        .executableTarget(
            name: "Agent",
            dependencies: ["Shared"],
            path: "Sources/Agent"
        ),

        // Parent admin CLI tool (quotactl)
        .executableTarget(
            name: "CLI",
            dependencies: ["Shared"],
            path: "Sources/CLI"
        ),

        // Unit tests for shared layer
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"],
            path: "Tests/SharedTests"
        ),
    ]
)
