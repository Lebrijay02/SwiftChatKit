import Foundation
import Testing
import MCP
import ChatCore
@testable import ChatMCP

/// Records what it was asked and answers with a scripted reply.
private actor RecordingHandler: MCPElicitationHandler {
    private let response: MCPElicitationResponse
    private(set) var requests: [MCPElicitationRequest] = []

    init(_ response: MCPElicitationResponse = .init(action: .accept)) {
        self.response = response
    }

    func elicit(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        requests.append(request)
        return response
    }
}

/// A handler that never returns, standing in for a sheet the user has not
/// answered yet.
private struct HangingHandler: MCPElicitationHandler {
    func elicit(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        try? await Task.sleep(for: .seconds(60))
        return .cancelled
    }
}

@Suite("MCP elicitation")
struct MCPElicitationTests {

    private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": .string("object"),
                 "properties": .object(properties),
                 "required": .array(required.map { .string($0) })])
    }

    // MARK: - Capability

    @Test("The capability is advertised only when a handler is supplied")
    func capabilityAdvertised() async throws {
        let bare = ScriptedTransport()
        try await MCPClient(transport: bare).start()
        #expect(await bare.declaredCapabilities == .object([:]))

        let wired = ScriptedTransport()
        try await MCPClient(transport: wired, elicitation: RecordingHandler()).start()
        #expect(await wired.declaredCapabilities == .object(["elicitation": .object([:])]))
    }

    // MARK: - Round trip

    @Test("A request reaches the handler and its answer reaches the server")
    func roundTrip() async throws {
        let handler = RecordingHandler(
            MCPElicitationResponse(action: .accept,
                                   content: ["framework": .string("SwiftUI"),
                                             "count": .number(3)]))
        let transport = ScriptedTransport()
        try await MCPClient(transport: transport,
                            elicitation: handler,
                            serverName: "Frida").start()

        let reply = await transport.serverRequest(
            method: "elicitation/create",
            params: .object([
                "message": .string("Which framework?"),
                "requestedSchema": schema(["framework": .object(["type": .string("string")]),
                                           "count": .object(["type": .string("integer")])])
            ]))

        guard case .object(let frame) = reply else { Issue.record("no reply"); return }
        #expect(frame["result"] == .object([
            "action": .string("accept"),
            "content": .object(["framework": .string("SwiftUI"), "count": .int(3)])
        ]))

        let requests = await handler.requests
        #expect(requests.count == 1)
        #expect(requests[0].message == "Which framework?")
        #expect(requests[0].serverName == "Frida")
        #expect(requests[0].fields.map(\.key) == ["count", "framework"])
    }

    @Test("Content is withheld on anything but accept")
    func declineCarriesNoContent() async throws {
        let handler = RecordingHandler(
            MCPElicitationResponse(action: .decline, content: ["secret": .string("leaked")]))
        let transport = ScriptedTransport()
        try await MCPClient(transport: transport, elicitation: handler).start()

        let reply = await transport.serverRequest(
            method: "elicitation/create",
            params: .object(["message": .string("?"), "requestedSchema": schema([:])]))

        guard case .object(let frame) = reply,
              case .object(let result)? = frame["result"] else { Issue.record("no reply"); return }
        #expect(result["action"] == .string("decline"))
        #expect(result["content"] == nil)
    }

    @Test("Without a handler the server is declined rather than left waiting")
    func noHandlerDeclines() async throws {
        let transport = ScriptedTransport()
        try await MCPClient(transport: transport).start()

        let reply = await transport.serverRequest(
            method: "elicitation/create",
            params: .object(["message": .string("?"), "requestedSchema": schema([:])]))

        guard case .object(let frame) = reply,
              case .object(let result)? = frame["result"] else { Issue.record("no reply"); return }
        #expect(result["action"] == .string("decline"))
    }

    @Test("An unsupported server request is answered with method-not-found")
    func unknownMethod() async throws {
        let transport = ScriptedTransport()
        try await MCPClient(transport: transport).start()

        let reply = await transport.serverRequest(method: "sampling/createMessage",
                                                  params: .object([:]))
        guard case .object(let frame) = reply,
              case .object(let error)? = frame["error"] else { Issue.record("no reply"); return }
        #expect(error["code"] == .int(-32601))
    }

    @Test("A ping is answered, so the server doesn't judge the client dead")
    func ping() async throws {
        let transport = ScriptedTransport()
        try await MCPClient(transport: transport).start()

        let reply = await transport.serverRequest(method: "ping", params: .object([:]))
        guard case .object(let frame) = reply else { Issue.record("no reply"); return }
        #expect(frame["result"] == .object([:]))
    }

    @Test("An unanswered elicitation does not block the client's own calls")
    func elicitationIsNotSerialisedBehindCalls() async throws {
        let transport = ScriptedTransport(tools: [.init("read")],
                                          behaviours: ["read": .text("contents")])
        let client = MCPClient(transport: transport, elicitation: HangingHandler())
        try await client.start()

        // The handler is still parked on a human; the tool call must not be.
        _ = await transport.serverRequest(method: "ping", params: .object([:]))
        let response = try await client.callTool(name: "read", arguments: [:])
        #expect(response.text == "contents")
    }

    @Test("A human-length wait is not cut short by the request timeout")
    func elicitationIgnoresRequestTimeout() async throws {
        let transport = ScriptedTransport()
        let client = MCPClient(transport: transport,
                               requestTimeout: .milliseconds(50),
                               elicitation: SlowHandler())
        try await client.start()

        // The deadline covers outbound calls only. A handler that takes longer
        // than it must still have its answer delivered.
        let reply = await transport.serverRequest(
            method: "elicitation/create",
            params: .object(["message": .string("?"), "requestedSchema": schema([:])]))
        guard case .object(let frame) = reply,
              case .object(let result)? = frame["result"] else { Issue.record("no reply"); return }
        #expect(result["action"] == .string("accept"))
    }

    // MARK: - Schema parsing

    @Test("A string enum reads as a single choice")
    func singleChoice() {
        let fields = MCPElicitationParser.fields(from: schema([
            "pick": .object(["type": .string("string"),
                             "enum": .array([.string("a"), .string("b")]),
                             "title": .string("Pick one")])
        ]))
        #expect(fields.count == 1)
        #expect(fields[0].kind == .singleChoice)
        #expect(fields[0].options == ["a", "b"])
        #expect(fields[0].title == "Pick one")
    }

    @Test("An array of enum items reads as a multi choice")
    func multiChoice() {
        let fields = MCPElicitationParser.fields(from: schema([
            "picks": .object(["type": .string("array"),
                              "items": .object(["enum": .array([.string("x"), .string("y")])])])
        ]))
        #expect(fields[0].kind == .multiChoice)
        #expect(fields[0].options == ["x", "y"])
    }

    @Test("Scalar types carry through, and required is recorded")
    func scalars() {
        let fields = MCPElicitationParser.fields(from: schema([
            "name": .object(["type": .string("string")]),
            "agree": .object(["type": .string("boolean")]),
            "size": .object(["type": .string("number")]),
            "count": .object(["type": .string("integer")])
        ], required: ["name"]))

        let kinds = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.kind) })
        #expect(kinds == ["name": .string, "agree": .boolean,
                          "size": .number, "count": .integer])
        #expect(fields.first { $0.key == "name" }?.isRequired == true)
        #expect(fields.first { $0.key == "agree" }?.isRequired == false)
    }

    @Test("An unrecognised type degrades to a string rather than failing the request")
    func unknownType() {
        let fields = MCPElicitationParser.fields(from: schema([
            "odd": .object(["type": .string("geopoint")]),
            // Our own kind names are not JSON Schema types, and a server that
            // sent one listed no options to go with it.
            "sneaky": .object(["type": .string("singleChoice")])
        ]))
        #expect(fields.allSatisfy { $0.kind == .string })
        #expect(fields.allSatisfy { $0.options.isEmpty })
    }

    @Test("A title falls back to the property key")
    func titleFallback() {
        let fields = MCPElicitationParser.fields(from: schema([
            "bundle_id": .object(["type": .string("string")])
        ]))
        #expect(fields[0].title == "bundle_id")
    }

    @Test("The URL form parses as a page to open, not a form to fill in")
    func urlForm() {
        let request = MCPElicitationParser.request(
            id: "1", serverName: "Frida",
            params: .object(["message": .string("Sign in"),
                             "url": .string("https://example.com/oauth")]))
        #expect(request?.url == URL(string: "https://example.com/oauth"))
        #expect(request?.fields.isEmpty == true)
    }

    @Test("A schema with no properties parses as a message-only prompt")
    func emptySchema() {
        let request = MCPElicitationParser.request(
            id: "1", serverName: "",
            params: .object(["message": .string("Continue?")]))
        #expect(request?.message == "Continue?")
        #expect(request?.fields.isEmpty == true)
        #expect(request?.url == nil)
    }
}

/// Takes longer than the client's request timeout, as a real person would.
private struct SlowHandler: MCPElicitationHandler {
    func elicit(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        try? await Task.sleep(for: .milliseconds(200))
        return MCPElicitationResponse(action: .accept)
    }
}
