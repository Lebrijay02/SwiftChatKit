import Foundation
import Testing
import MCP
import ChatCore
@testable import ChatMCP

@Suite("MCPClient")
struct MCPClientTests {

    @Test("The handshake completes and tools are discovered")
    func handshakeAndListTools() async throws {
        let transport = ScriptedTransport(tools: [
            .init("read", description: "Read a file.",
                  schema: .object([
                      "type": .string("object"),
                      "properties": .object(["path": .object(["type": .string("string")])]),
                      "required": .array([.string("path")])
                  ])),
            .init("write")
        ])
        let client = MCPClient(transport: transport)
        try await client.start()

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["read", "write"])
        #expect(tools[0].description == "Read a file.")
        #expect(await transport.connectCount == 1)
    }

    @Test("A tool call returns its text content")
    func callTool() async throws {
        let transport = ScriptedTransport(tools: [.init("read")],
                                          behaviours: ["read": .text("file contents")])
        let client = MCPClient(transport: transport)
        try await client.start()

        let response = try await client.callTool(name: "read", arguments: ["path": .string("a.txt")])
        #expect(response.text == "file contents")
        #expect(response.isError == false)

        let calls = await transport.receivedCalls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == .object(["path": .string("a.txt")]))
    }

    @Test("Arguments reach the server with integers intact")
    func argumentsConvert() async throws {
        let transport = ScriptedTransport(tools: [.init("page")])
        let client = MCPClient(transport: transport)
        try await client.start()

        _ = try await client.callTool(name: "page", arguments: ["limit": .number(50)])
        let calls = await transport.receivedCalls
        #expect(calls[0].arguments == .object(["limit": .int(50)]))
    }

    @Test("A tool reporting isError is surfaced, not thrown")
    func toolError() async throws {
        let transport = ScriptedTransport(tools: [.init("read")],
                                          behaviours: ["read": .toolError("no such file")])
        let client = MCPClient(transport: transport)
        try await client.start()

        let response = try await client.callTool(name: "read", arguments: [:])
        #expect(response.isError)
        #expect(response.text == "no such file")
    }

    @Test("Empty content reads as a stated absence rather than an empty string")
    func emptyContent() async throws {
        let transport = ScriptedTransport(tools: [.init("noop")], behaviours: ["noop": .text("")])
        let client = MCPClient(transport: transport)
        try await client.start()
        #expect(try await client.callTool(name: "noop", arguments: [:]).text == "(no output)")
    }

    @Test("A JSON-RPC error becomes a thrown server error")
    func serverError() async throws {
        let transport = ScriptedTransport(
            tools: [.init("read")],
            behaviours: ["read": .failure(code: -32602, message: "Invalid params")])
        let client = MCPClient(transport: transport)
        try await client.start()

        await #expect(throws: MCPBridgeError.serverError(code: -32602, message: "Invalid params")) {
            try await client.callTool(name: "read", arguments: [:])
        }
    }

    @Test("A silent server times out instead of hanging the turn forever")
    func requestTimeout() async throws {
        let transport = ScriptedTransport(tools: [.init("hang")], behaviours: ["hang": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .milliseconds(150))
        try await client.start()

        await #expect(throws: MCPBridgeError.self) {
            try await client.callTool(name: "hang", arguments: [:])
        }
    }

    @Test("A failing connect surfaces rather than leaving the client half-started")
    func connectFailure() async throws {
        let transport = ScriptedTransport()
        await transport.setFailConnect(true)
        let client = MCPClient(transport: transport)

        await #expect(throws: (any Error).self) { try await client.start() }
    }

    @Test("A server dying mid-call fails the request instead of stranding it")
    func streamEndFailsPendingRequests() async throws {
        let transport = ScriptedTransport(tools: [.init("hang")], behaviours: ["hang": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .seconds(30))
        try await client.start()

        // A crashed stdio child looks exactly like this: the stream just ends.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await transport.die()
        }

        await #expect(throws: MCPBridgeError.notConnected) {
            try await client.callTool(name: "hang", arguments: [:])
        }
    }

    @Test("Stopping disconnects and fails anything in flight")
    func stop() async throws {
        let transport = ScriptedTransport(tools: [.init("hang")], behaviours: ["hang": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .seconds(30))
        try await client.start()

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await client.stop()
        }
        await #expect(throws: MCPBridgeError.self) {
            try await client.callTool(name: "hang", arguments: [:])
        }
    }
}
