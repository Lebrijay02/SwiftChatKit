// swift-tools-version: 6.2

import PackageDescription

// A separate package, depending on SwiftChatKit by path exactly the way a real
// consumer would. That is the point of it: if the demo builds, the package
// stands on its own rather than only inside its own test target.
let package = Package(
    name: "ChatDemo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ChatDemo",
            dependencies: [
                // One product per capability: the engine, then only the
                // backend, tools and UI this demo actually uses.
                .product(name: "SwiftChatKit", package: "SwiftChatKit"),
                .product(name: "SwiftChatKitGemini", package: "SwiftChatKit"),
                .product(name: "SwiftChatKitTools", package: "SwiftChatKit"),
                .product(name: "SwiftChatKitUI", package: "SwiftChatKit"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
