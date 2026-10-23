// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ZashDockCore", platforms: [.macOS("26.0")],
    products: [.library(name: "ZashDockCore", targets: ["ZashDockCore"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "ZashDockCore", dependencies: ["CZlib"]),
        .testTarget(name: "ZashDockCoreTests", dependencies: ["ZashDockCore", "CZlib"])
    ]
)
