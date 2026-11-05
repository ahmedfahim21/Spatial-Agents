// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Agentsphere",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Agentsphere", path: "Sources/Agentsphere")
    ]
)
