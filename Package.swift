// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RigRelay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RigRelay", targets: ["BridgeApp"]),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            path: "Sources/BridgeCore"
        ),
        .executableTarget(
            name: "BridgeApp",
            dependencies: ["BridgeCore"],
            path: "Sources/BridgeApp"
        ),
    ]
)
