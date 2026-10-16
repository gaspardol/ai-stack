// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AIStack",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "AIStack",
            path: "Sources/AIStack"
        )
    ]
)
