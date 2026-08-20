// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftChatKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Headless engine: models, agent loop, tools, backends. No UI.
        .library(name: "SwiftChatKit", targets: ["ChatCore", "ChatGemini"]),
        // The core alone, for hosts bringing their own backend.
        .library(name: "SwiftChatKitCore", targets: ["ChatCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.14.0"),
    ],
    targets: [
        // Foundation only. The zero-dependency rule here is what keeps the
        // package portable — backends and transports live in their own targets.
        .target(name: "ChatCore"),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),

        // Gemini via Firebase AI Logic. The only target that sees an SDK type.
        .target(
            name: "ChatGemini",
            dependencies: [
                "ChatCore",
                .product(name: "FirebaseAILogic", package: "firebase-ios-sdk"),
            ]),
        .testTarget(name: "ChatGeminiTests", dependencies: ["ChatGemini"]),
    ],
    swiftLanguageModes: [.v6]
)
