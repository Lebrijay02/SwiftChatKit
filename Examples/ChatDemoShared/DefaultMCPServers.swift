//
//  DefaultMCPServers.swift
//  ChatDemo
//
//  Seed data for the settings screen: public test/mock MCP servers that need
//  no key of their own, so both demos have something real to connect to
//  without asking for a credential first. Ids are fixed rather than `UUID()`
//  so `MCPServerStore.loadOrSeed` recognizes them across launches instead of
//  re-adding them — and so a server the user disables stays disabled.
//

import Foundation
import ChatMCP

enum DefaultMCPServers {

    static let all: [MCPServerConfig] = [
        // Predictable-behavior test servers, good for exercising a client
        // against one protocol concern at a time.
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "MCP Complex Server",
            transport: .http(url: URL(string: "https://mcpplaygroundonline.com/mcp-complex-server")!,
                             auth: .none)),
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "MCP Error Server",
            transport: .http(url: URL(string: "https://mcpplaygroundonline.com/mcp-error-server")!,
                             auth: .none)),
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "MCP Apps Server",
            transport: .http(url: URL(string: "https://mcpplaygroundonline.com/mcp-app-server")!,
                             auth: .none)),
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "MCP Stateless Server",
            transport: .http(url: URL(string: "https://mcpplaygroundonline.com/mcp-stateless-server")!,
                             auth: .none)),

        // Real-world-shaped servers: ordinary CRUD tools and read-only
        // documentation lookups, rather than protocol edge cases.
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            name: "Petstore MCP",
            transport: .http(url: URL(string: "https://petstore.run.mcp.com.ai/mcp")!, auth: .none)),
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            name: "DeepWiki MCP",
            transport: .http(url: URL(string: "https://mcp.deepwiki.com/mcp")!, auth: .none)),

        // The reference implementation of the full spec — tools, resources,
        // prompts, sampling, elicitation, OAuth, both Streamable HTTP and SSE.
        // https://github.com/modelcontextprotocol/example-remote-server
        // Off by default: unlike the others above, its hosted URL isn't
        // published anywhere stable enough to hardcode with confidence. Flip
        // it on once you've pointed it at wherever you're running it.
        MCPServerConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            name: "MCP Example Remote Server",
            transport: .http(url: URL(string: "https://example-server.modelcontextprotocol.io/mcp")!,
                             auth: .none),
            enabled: false),
    ]
}
