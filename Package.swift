// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexProfiles",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexProfilesApp", targets: ["CodexProfilesApp"]),
        .executable(name: "relay-cli", targets: ["RelayCLI"]),
    ],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(
            name: "CodexProfilesApp",
            dependencies: ["RelayCore"]
        ),
        .executableTarget(name: "RelayCLI", dependencies: ["RelayCore"]),
    ]
)
