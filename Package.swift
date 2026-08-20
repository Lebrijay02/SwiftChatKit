// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftChatKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Headless engine: models, agent loop, tools, backends. No UI.
        .library(name: "SwiftChatKit", targets: ["ChatCore"]),
    ],
    targets: [
        // Foundation only. The zero-dependency rule here is what keeps the
        // package portable — backends and transports live in their own targets.
        .target(name: "ChatCore"),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
