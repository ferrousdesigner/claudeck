// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Claudeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Claudeck",
            path: "Sources/Claudeck"
        )
    ]
)
