// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Margin", targets: ["Margin"])],
    targets: [
        .target(name: "MarginCore"),
        .executableTarget(name: "Margin", dependencies: ["MarginCore"]),
        .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore"]),
    ],
    swiftLanguageModes: [.v5]
)
