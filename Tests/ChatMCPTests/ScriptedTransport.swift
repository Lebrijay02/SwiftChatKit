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
    /// The `capabilities` object the client sent with `initialize`.
    private(set) var declaredCapabilities: Value = .object([:])
    /// Progress tokens the client attached, keyed by tool name.
    private(set) var progressTokens: [String: Value] = [:]
    /// Requests the client asked to be cancelled.
    private(set) var cancelledRequests: [Int] = []
    /// Replies to requests this transport initiated, keyed by their id.
    private var inbound: [Int: CheckedContinuation<Value, Never>] = [:]
    private var nextServerID = 10_000
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

    /// Sends a server→client request and waits for the client's response
    /// frame — the direction `elicitation/create` runs in.
    func serverRequest(method: String, params: Value) async -> Value {
        nextServerID += 1
        let id = nextServerID
        return await withCheckedContinuation { continuation in
            inbound[id] = continuation
            send(.object(["jsonrpc": .string("2.0"), "id": .int(id),
                          "method": .string(method), "params": params]))
        }
    }

    /// Reports progress against a token the client handed out.
    func sendProgress(token: Value, progress: Double, total: Double?, message: String?) {
        var params: [String: Value] = ["progressToken": token, "progress": .double(progress)]
        if let total { params["total"] = .double(total) }
        if let message { params["message"] = .string(message) }
        send(.object(["jsonrpc": .string("2.0"),
                      "method": .string("notifications/progress"),
                      "params": .object(params)]))
    }

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
        guard case .object(let request)? = try? JSONDecoder().decode(Value.self, from: data)
        else { return }

        // A frame with no method is the client answering something this
        // transport asked it.
        guard case .string(let method)? = request["method"] else {
            if case .int(let id)? = request["id"] {
                inbound.removeValue(forKey: id)?.resume(returning: .object(request))
            }
            return
        }

        if method == "notifications/cancelled",
           case .object(let params)? = request["params"],
           case .int(let requestID)? = params["requestId"] {
            cancelledRequests.append(requestID)
        }

        // Notifications carry no id and expect no reply.
        guard case .int(let id)? = request["id"] else { return }

        switch method {
        case "initialize":
            if case .object(let params)? = request["params"],
               let capabilities = params["capabilities"] {
                declaredCapabilities = capabilities
            }
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
            if case .object(let meta)? = params["_meta"], let token = meta["progressToken"] {
                progressTokens[name] = token
            }

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
