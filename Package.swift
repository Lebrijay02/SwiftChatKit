// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftChatKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The engine: models, agent loop, protocol seams. No backend, no tools,
        // no UI — a host that takes only this gets a chat with nothing wired in
        // and decides for itself what to add.
        .library(name: "SwiftChatKit", targets: ["ChatCore"]),

        // Every capability is its own product, so nothing arrives unasked. Each
        // re-exports ChatCore, so one import is enough.
        .library(name: "SwiftChatKitGemini", targets: ["ChatGemini"]),
        .library(name: "SwiftChatKitOpenAI", targets: ["ChatOpenAI"]),
        .library(name: "SwiftChatKitTools", targets: ["ChatTools"]),
        .library(name: "SwiftChatKitMCP", targets: ["ChatMCP"]),
        .library(name: "SwiftChatKitUI", targets: ["ChatUI"]),
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

        // Any server speaking OpenAI's `/chat/completions` format. Foundation
        // only — no SDK, because the point is to reach servers no SDK covers.
        .target(name: "ChatOpenAI", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatOpenAITests", dependencies: ["ChatOpenAI"]),

        // Built-in file and shell tools. Foundation only — the file tools go
        // through `FileSystemProviding`, so nothing here binds to a real disk.
        .target(name: "ChatTools", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatToolsTests", dependencies: ["ChatTools"]),

        // The MCP bridge. Depends on the official SDK for its transports only.
        .target(name: "ChatMCP",
                dependencies: ["ChatCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "ChatMCPTests", dependencies: ["ChatMCP"]),

        // SwiftUI renderer and agent cards. Depends on ChatCore only — the UI
        // never needs to know which backend or tools are in play.
        .target(name: "ChatUI", dependencies: ["ChatCore"]),
        .testTarget(name: "ChatUITests", dependencies: ["ChatUI"]),
    ],
    swiftLanguageModes: [.v6]
)
