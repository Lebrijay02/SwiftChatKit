//
//  MCPClient.swift
//  SwiftChatKit
//
//  A minimal MCP client driven directly over the SDK's `Transport`, speaking
//  the JSON-RPC handshake by hand:
//  initialize → notifications/initialized → tools/list → tools/call.
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

    private let transport: any Transport
    private let clientName: String
    private let clientVersion: String
    private let requestTimeout: Duration

    private var nextID = 0
    private var pending: [Int: CheckedContinuation<MCP.Value, Error>] = [:]
    private var readTask: Task<Void, Never>?

    public init(transport: any Transport,
                clientName: String = "SwiftChatKit",
                clientVersion: String = "1.0",
                requestTimeout: Duration = .seconds(120)) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
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
                         arguments: [String: ChatValue]) async throws -> (text: String, isError: Bool) {
        let result = try await request(method: "tools/call", params: [
            "name": .string(name),
            "arguments": .object(arguments.mapValues(\.mcpValue))
        ])
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

    // MARK: - Handshake

    private func initialize() async throws {
        _ = try await request(method: "initialize", params: [
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(clientName),
                                   "version": .string(clientVersion)])
        ])
        try await notify(method: "notifications/initialized")
    }

    // MARK: - JSON-RPC

    private struct Response: Decodable {
        struct Failure: Decodable { let code: Int; let message: String }
        let id: MCP.Value?
        let result: MCP.Value?
        let error: Failure?
    }

    private func request(method: String, params: [String: MCP.Value]?) async throws -> MCP.Value {
        nextID += 1
        let id = nextID

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

    private func notify(method: String) async throws {
        let message: MCP.Value = .object(["jsonrpc": .string("2.0"), "method": .string(method)])
        try await transport.send(try JSONEncoder().encode(message))
    }

    private func handle(_ data: Data) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              case .int(let id)? = response.id
        else { return }   // notifications and server-initiated requests carry no id we own

        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = response.error {
            continuation.resume(throwing: MCPBridgeError.serverError(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: response.result ?? .object([:]))
        }
    }

    /// Resolves a single in-flight request with a failure. A no-op if it has
    /// already been answered, which is what makes the timeout race safe.
    private func fail(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }
}
