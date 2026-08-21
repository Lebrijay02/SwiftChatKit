// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftChatKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Headless engine: models, agent loop, tools, backends. No UI.
        .library(name: "SwiftChatKit", targets: ["ChatCore", "ChatTools", "ChatMCP", "ChatGemini"]),
        // The core alone, for hosts bringing their own backend.
        .library(name: "SwiftChatKitCore", targets: ["ChatCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.14.0"),
        // Used only for its transports and JSON-Schema value type; the JSON-RPC
        // handshake is driven by hand in `MCPClient`.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
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

        // Built-in file and shell tools. Foundation only — the file tools go
        // through `FileSystemProviding`, so nothing here binds to a real disk.
        .target(name: "ChatTools", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatToolsTests", dependencies: ["ChatTools"]),

        // The MCP bridge. Depends on the official SDK for its transports only.
        .target(name: "ChatMCP",
                dependencies: ["ChatCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "ChatMCPTests", dependencies: ["ChatMCP"]),
    ],
    swiftLanguageModes: [.v6]
)
