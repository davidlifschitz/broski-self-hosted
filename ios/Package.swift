// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BroskiApp",
    platforms: [.iOS(.v16)],
    targets: [
        .executableTarget(
            name: "BroskiApp",
            path: "BroskiApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
