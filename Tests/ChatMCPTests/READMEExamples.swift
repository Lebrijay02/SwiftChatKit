//
//  READMEExamples.swift
//  SwiftChatKitTests
//
//  Every ChatMCP snippet in README.md, compiled. Docs that no longer build are
//  docs that lie, and this target is what catches that.
//

import Foundation
import Testing
import ChatCore
import ChatMCP

@Suite("README — ChatMCP examples")
struct ChatMCPREADMEExamples {

    @Test("Configuring a manager and handing it to a session")
    func setup() async {
        let manager = MCPManager(
            store: MCPServerStore(defaults: UserDefaults(suiteName: "readme.\(UUID())")!),
            seedServers: [
                MCPServerConfig(name: "Docs",
                                transport: .http(url: URL(string: "https://example.com/mcp")!,
                                                 auth: .bearer(token: "…")))
            ])

        await manager.loadAndConnectEnabled()
        await manager.setReadOnly(["search_docs"])

        let configuration = ChatSessionConfiguration(backend: NullBackend(),
                                                     toolProviders: [manager])
        #expect(configuration.toolProviders.count == 1)
    }

    @Test("Importing a standard mcpServers config")
    func importConfig() {
        let json = Data("""
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
            }
          }
        }
        """.utf8)

        let servers = MCPServerConfig.decodeMCPServers(from: json)
        #expect(servers.map(\.name) == ["filesystem"])
    }

    @Test("Observing connection state from a host")
    func observeStatus() async {
        let manager = MCPManager(
            store: MCPServerStore(defaults: UserDefaults(suiteName: "readme.\(UUID())")!),
            onStatusChange: { statuses in
                for status in statuses.values where status.state == .needsAuth {
                    _ = status.id   // prompt the user to sign in
                }
            })
        await manager.loadAndConnectEnabled()
        #expect(await manager.declarations.isEmpty)
    }
}

/// A backend that never runs — the examples above only need something that
/// satisfies `ChatConfiguration`.
private final class NullBackend: ChatBackend {
    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) async {}
    var history: [ChatTurn] { get async { [] } }
    var modelName: String { get async { "null" } }
    func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
