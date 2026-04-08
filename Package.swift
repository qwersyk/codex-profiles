// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexProfiles",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexProfilesApp", targets: ["CodexProfilesApp"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexProfilesApp"
        ),
    ]
)
