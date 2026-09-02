//
//  MCPClient.swift
//  SwiftChatKit
//
//  A minimal MCP client driven directly over the SDK's `Transport`, speaking
//  the JSON-RPC handshake by hand:
//  initialize → notifications/initialized → tools/list → tools/call.
//
//  Traffic runs both ways. Outbound calls get a deadline; inbound requests —
//  `elicitation/create`, `ping` — are answered, because a server waiting on an
//  unanswered request hangs exactly as badly as one waiting on a dropped one.
//

import Foundation
import MCP
import ChatCore

public actor MCPClient {

    public struct DiscoveredTool: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: MCP.Value?
    }

    /// Progress reported by a long-running tool call: a fraction in 0…1 where
    /// the server sent a total, and whatever message it attached.
    public typealias ProgressHandler = @Sendable (Double?, String?) -> Void

    private let transport: any Transport
    private let clientName: String
    private let clientVersion: String
    private let requestTimeout: Duration
    private let elicitation: (any MCPElicitationHandler)?
    /// Only used to attribute a prompt in the host's UI.
    private let serverName: String

    private var nextID = 0
    private var pending: [Int: CheckedContinuation<MCP.Value, Error>] = [:]
    private var progressHandlers: [Int: ProgressHandler] = [:]
    private var readTask: Task<Void, Never>?
    /// Inbound requests being answered, so `stop()` doesn't leave a host's
    /// elicitation sheet up with nothing left to answer it.
    private var inboundTasks: [Task<Void, Never>] = []

    public init(transport: any Transport,
                clientName: String = "SwiftChatKit",
                clientVersion: String = "1.0",
                requestTimeout: Duration = .seconds(120),
                elicitation: (any MCPElicitationHandler)? = nil,
                serverName: String = "") {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
        self.elicitation = elicitation
        self.serverName = serverName
    }

    /// Connects the transport, starts the read loop, and performs the handshake.
    public func start() async throws {
        try await transport.connect()
        let stream = await transport.receive()
        readTask = Task { [weak self] in
            do {
                for try await data in stream {
                    await self?.handle(data)
                }
                // A clean end of stream still strands anything in flight.
                await self?.failAll(MCPBridgeError.notConnected)
            } catch {
                await self?.failAll(error)
            }
        }
        try await initialize()
    }

    public func stop() async {
        readTask?.cancel()
        readTask = nil
        for task in inboundTasks { task.cancel() }
        inboundTasks.removeAll()
        await transport.disconnect()
        failAll(MCPBridgeError.notConnected)
    }

    // MARK: - Operations

    public func listTools() async throws -> [DiscoveredTool] {
        let result = try await request(method: "tools/list", params: nil)
        guard case .object(let fields) = result,
              case .array(let tools)? = fields["tools"] else { return [] }

        return tools.compactMap { tool in
            guard case .object(let entry) = tool,
                  case .string(let name)? = entry["name"] else { return nil }
            let description: String
            if case .string(let text)? = entry["description"] { description = text } else { description = "" }
            return DiscoveredTool(name: name, description: description,
                                  inputSchema: entry["inputSchema"])
        }
    }

    public func callTool(name: String,
                         arguments: [String: ChatValue],
                         progress: ProgressHandler? = nil) async throws -> (text: String, isError: Bool) {
        let result = try await request(method: "tools/call", params: [
            "name": .string(name),
            "arguments": .object(arguments.mapValues(\.mcpValue))
        ], progress: progress)
        guard case .object(let fields) = result else { throw MCPBridgeError.invalidResponse }

        var text = ""
        if case .array(let content)? = fields["content"] {
            text = content.compactMap { block -> String? in
                guard case .object(let entry) = block,
                      case .string("text")? = entry["type"],
                      case .string(let value)? = entry["text"] else { return nil }
                return value
            }.joined(separator: "\n")
        }

        var isError = false
        if case .bool(let flag)? = fields["isError"] { isError = flag }
        // An empty result is a valid outcome; say so rather than returning "".
        return (text.isEmpty ? "(no output)" : text, isError)
    }

    /// Abandons every in-flight call, telling the server to stop work on each.
    ///
    /// Without this, pressing Stop leaves a twenty-minute tool call running to
    /// completion on the far side and the continuation parked until the
    /// timeout — the user's cancellation would only look like it took effect.
    public func cancelActiveCalls(reason: String = "Cancelled by the user.") async {
        let ids = Array(pending.keys)
        guard !ids.isEmpty else { return }
        for id in ids {
            try? await notify(method: "notifications/cancelled",
                              params: ["requestId": .int(id), "reason": .string(reason)])
            fail(id, with: MCPBridgeError.cancelled)
        }
    }

    // MARK: - Handshake

    private func initialize() async throws {
        // Advertised only when there is something behind it. See
        // `MCPElicitationHandler` for why declaring it emptily is worse.
        var capabilities: [String: MCP.Value] = [:]
        if elicitation != nil { capabilities["elicitation"] = .object([:]) }

        _ = try await request(method: "initialize", params: [
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object(capabilities),
            "clientInfo": .object(["name": .string(clientName),
                                   "version": .string(clientVersion)])
        ])
        try await notify(method: "notifications/initialized")
    }

    // MARK: - JSON-RPC

    private func request(method: String,
                         params: [String: MCP.Value]?,
                         progress: ProgressHandler? = nil) async throws -> MCP.Value {
        nextID += 1
        let id = nextID

        var params = params
        if progress != nil {
            // The token the server echoes on every progress notification. The
            // request id doubles as one: it is already unique per connection.
            var meta: [String: MCP.Value] = [:]
            if case .object(let existing)? = params?["_meta"] { meta = existing }
            meta["progressToken"] = .int(id)
            params = (params ?? [:]).merging(["_meta": .object(meta)]) { _, new in new }
            progressHandlers[id] = progress
        }

        var message: [String: MCP.Value] = [
            "jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method)
        ]
        if let params { message["params"] = .object(params) }
        let data = try JSONEncoder().encode(MCP.Value.object(message))

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation

            Task {
                do {
                    try await transport.send(data)
                } catch {
                    self.fail(id, with: error)
                }
            }
            // Without this a wedged server strands the turn forever: the only
            // other timeout in the stack covers connecting, not calling.
            Task {
                try? await Task.sleep(for: requestTimeout)
                self.fail(id, with: MCPBridgeError.timedOut("\(method) did not respond."))
            }
        }
    }

    private func notify(method: String, params: [String: MCP.Value]? = nil) async throws {
        var message: [String: MCP.Value] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = .object(params) }
        try await transport.send(try JSONEncoder().encode(MCP.Value.object(message)))
    }

    /// Writes an outbound *response*. Deliberately not routed through
    /// `request`: there is no continuation to park, and the id is the server's.
    private func respond(id: MCP.Value, result: MCP.Value) async {
        await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func respond(id: MCP.Value, errorCode: Int, message: String) async {
        await send(.object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .int(errorCode),
                                              "message": .string(message)])]))
    }

    private func send(_ value: MCP.Value) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? await transport.send(data)
    }

    // MARK: - Inbound frames

    private func handle(_ data: Data) {
        guard case .object(let frame)? = try? JSONDecoder().decode(MCP.Value.self, from: data)
        else { return }

        // A frame carrying a method is something the server initiated: a
        // request when it also carries an id, a notification when it doesn't.
        if case .string(let method)? = frame["method"] {
            let id = frame["id"]
            if let id, !id.isNull {
                serve(id: id, method: method, params: frame["params"])
            } else {
                receive(notification: method, params: frame["params"])
            }
            return
        }

        guard case .int(let id)? = frame["id"] else { return }
        progressHandlers[id] = nil
        guard let continuation = pending.removeValue(forKey: id) else { return }

        if case .object(let failure)? = frame["error"] {
            var code = 0
            if case .int(let value)? = failure["code"] { code = value }
            var message = "Unknown error"
            if case .string(let text)? = failure["message"] { message = text }
            continuation.resume(throwing: MCPBridgeError.serverError(code: code, message: message))
        } else {
            continuation.resume(returning: frame["result"] ?? .object([:]))
        }
    }

    private func serve(id: MCP.Value, method: String, params: MCP.Value?) {
        switch method {
        case "elicitation/create":
            guard let elicitation,
                  let request = MCPElicitationParser.request(id: Self.describe(id),
                                                             serverName: serverName,
                                                             params: params)
            else {
                // Not silence: a decline lets the server carry on, where no
                // reply at all leaves it parked until something kills it.
                answer(id: id, with: .declined)
                return
            }
            let task = Task { [weak self] in
                let response = await elicitation.elicit(request)
                await self?.answer(id: id, with: response)
            }
            inboundTasks.append(task)

        // Servers ping to check the client is still alive. An empty result is
        // the whole of the expected reply.
        case "ping":
            Task { await respond(id: id, result: .object([:])) }

        default:
            Task {
                await respond(id: id, errorCode: -32601,
                              message: "Method \(method) is not supported by this client.")
            }
        }
    }

    private func answer(id: MCP.Value, with response: MCPElicitationResponse) {
        var result: [String: MCP.Value] = ["action": .string(response.action.rawValue)]
        // The spec carries content only on accept, and a server reading it
        // regardless would otherwise see answers the user declined to give.
        if response.action == .accept {
            result["content"] = .object(response.content.mapValues(\.mcpValue))
        }
        Task { await respond(id: id, result: .object(result)) }
    }

    private func receive(notification method: String, params: MCP.Value?) {
        guard method == "notifications/progress",
              case .object(let fields)? = params,
              case .int(let token)? = fields["progressToken"],
              let handler = progressHandlers[token] else { return }

        let progress = Self.double(fields["progress"])
        let total = Self.double(fields["total"])
        var message: String?
        if case .string(let text)? = fields["message"] { message = text }

        // A fraction only means anything against a total, and a server may
        // send progress without one.
        let fraction: Double?
        if let progress, let total, total > 0 {
            fraction = min(max(progress / total, 0), 1)
        } else {
            fraction = nil
        }
        handler(fraction, message)
    }

    private static func double(_ value: MCP.Value?) -> Double? {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return nil
        }
    }

    /// JSON-RPC ids may be numbers or strings; hosts only ever need to key by
    /// one, so both render to a string.
    private static func describe(_ id: MCP.Value) -> String {
        switch id {
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        default: return ""
        }
    }

    /// Resolves a single in-flight request with a failure. A no-op if it has
    /// already been answered, which is what makes the timeout race safe.
    private func fail(_ id: Int, with error: Error) {
        progressHandlers[id] = nil
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        progressHandlers.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}
