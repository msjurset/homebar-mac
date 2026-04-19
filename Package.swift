// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeBar",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "HomeBar",
            dependencies: ["Sparkle"],
            path: "Sources/HomeBar"
        ),
        .testTarget(
            name: "HomeBarTests",
            dependencies: ["HomeBar"],
            path: "Tests/HomeBarTests"
        ),
    ]
)
