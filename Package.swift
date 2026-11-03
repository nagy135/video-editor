// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoEditor",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VideoEditor", targets: ["VideoEditor"])],
    targets: [
        .target(name: "VideoEditorCore"),
        .executableTarget(name: "VideoEditor", dependencies: ["VideoEditorCore"]),
        .testTarget(name: "VideoEditorCoreTests", dependencies: ["VideoEditorCore"]),
        .testTarget(name: "VideoEditorTests", dependencies: ["VideoEditor", "VideoEditorCore"]),
    ]
)
