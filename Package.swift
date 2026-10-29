// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileQueue",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "FileQueue", path: "Sources/FileQueue")
    ]
)
