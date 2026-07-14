// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "AIUsageBar",
            dependencies: ["Sparkle"],
            path: "Sources/AIUsageBar"
        )
    ]
)
