// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ZashDock", platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "Packages/ZashDockCore"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(name: "ZashDock", dependencies: ["ZashDockCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/ZashDock"),
        .testTarget(name: "ZashDockIntegrationTests", dependencies: ["ZashDock", "ZashDockCore"], path: "Tests/ZashDockIntegrationTests")
    ]
)
