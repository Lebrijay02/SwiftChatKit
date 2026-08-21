import Foundation
import Logging
import MCP
@testable import ChatMCP

/// An in-memory MCP server: answers the handshake, serves a fixed tool list,
/// and returns scripted results — so the client and manager can be tested
/// without spawning a subprocess or opening a socket.
actor ScriptedTransport: Transport {

    struct Tool: Sendable {
        let name: String
        let description: String
        let schema: Value

        init(_ name: String, description: String = "", schema: Value = .object(["type": .string("object")])) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    enum Behaviour: Sendable {
        /// Answer `tools/call` with this text.
        case text(String)
        /// Answer with `isError: true`.
        case toolError(String)
        /// Answer with a JSON-RPC error object.
        case failure(code: Int, message: String)
        /// Never answer at all.
        case silent
    }

    nonisolated let logger = Logger(label: "scripted-transport")

    private let tools: [Tool]
    private var behaviours: [String: Behaviour]
    private var stream: AsyncThrowingStream<Data, Swift.Error>!
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!

    private(set) var connectCount = 0
    private(set) var receivedCalls: [(name: String, arguments: Value)] = []
    /// Set to fail the next `connect`, to exercise the reconnect path.
    var failConnect = false

    init(tools: [Tool] = [], behaviours: [String: Behaviour] = [:]) {
        self.tools = tools
        self.behaviours = behaviours
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func setBehaviour(_ behaviour: Behaviour, for tool: String) {
        behaviours[tool] = behaviour
    }

    func setFailConnect(_ value: Bool) { failConnect = value }

    // MARK: - Transport

    func connect() async throws {
        connectCount += 1
        if failConnect { throw MCPBridgeError.notConnected }
    }

    func disconnect() async {
        continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

    func send(_ data: Data) async throws {
        guard case .object(let request)? = try? JSONDecoder().decode(Value.self, from: data),
              case .string(let method)? = request["method"] else { return }

        // Notifications carry no id and expect no reply.
        guard case .int(let id)? = request["id"] else { return }

        switch method {
        case "initialize":
            reply(id: id, result: .object(["protocolVersion": .string("2025-06-18")]))

        case "tools/list":
            reply(id: id, result: .object(["tools": .array(tools.map {
                .object(["name": .string($0.name),
                         "description": .string($0.description),
                         "inputSchema": $0.schema])
            })]))

        case "tools/call":
            guard case .object(let params)? = request["params"],
                  case .string(let name)? = params["name"] else { return }
            receivedCalls.append((name, params["arguments"] ?? .object([:])))

            switch behaviours[name] ?? .text("ok") {
            case .text(let text):
                reply(id: id, result: content(text, isError: false))
            case .toolError(let text):
                reply(id: id, result: content(text, isError: true))
            case .failure(let code, let message):
                send(.object(["jsonrpc": .string("2.0"), "id": .int(id),
                              "error": .object(["code": .int(code),
                                                "message": .string(message)])]))
            case .silent:
                break
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    private func content(_ text: String, isError: Bool) -> Value {
        .object(["content": .array([.object(["type": .string("text"),
                                             "text": .string(text)])]),
                 "isError": .bool(isError)])
    }

    private func reply(id: Int, result: Value) {
        send(.object(["jsonrpc": .string("2.0"), "id": .int(id), "result": result]))
    }

    private func send(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        continuation.yield(data)
    }

    /// Ends the stream as a dead subprocess would, without a clean disconnect.
    func die() { continuation.finish() }
}
