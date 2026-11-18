// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HierarchySize",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HierarchySize", path: "Sources/HierarchySize")
    ]
)
