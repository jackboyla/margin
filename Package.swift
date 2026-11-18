// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Margin", targets: ["Margin"])],
    targets: [
        .target(name: "MarginCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Margin", dependencies: ["MarginCore"],
                          resources: [.copy("Resources/BrowserHighlights.js"), .copy("Resources/PDFViewport.js")]),
        .testTarget(name: "MarginCoreTests", dependencies: ["MarginCore", "Margin"]),
    ],
    swiftLanguageModes: [.v5]
)
