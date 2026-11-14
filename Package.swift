// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Margin", targets: ["Margin"])],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3"),
        // Keep collection types compatible with the macOS 26.5 SDK and Swift 6.1.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
    ],
    targets: [
        .target(name: "MarginCore", dependencies: [
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "Margin", dependencies: ["MarginCore"]),
        .testTarget(name: "MarginCoreTests", dependencies: [
            "MarginCore",
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "Logging", package: "swift-log"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
