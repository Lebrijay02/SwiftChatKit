//
//  MCPModels.swift
//  SwiftChatKit
//
//  Configuration and status types for the MCP bridge.
//

import Foundation
import ChatCore
import MCP

/// How to authenticate against a remote (HTTP) MCP server.
public enum MCPAuth: Codable, Equatable, Sendable {
    case none
    case bearer(token: String)
    /// Defers to the host's `MCPAuthorizationProvider`. The package deliberately
    /// ships no OAuth flow of its own: the browser hand-off needs a presentation
    /// anchor and a redirect scheme, both of which only the host can supply.
    case oauth
}

/// Transport used to reach an MCP server.
public enum MCPTransport: Codable, Equatable, Sendable {
    /// Remote Streamable-HTTP server.
    case http(url: URL, auth: MCPAuth)
    /// Local subprocess speaking MCP over stdio, e.g. `npx xcodebuildmcp@latest mcp`.
    case stdio(command: String, arguments: [String])
}

/// A configured MCP server.
public struct MCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransport
    public var enabled: Bool

    public init(id: UUID = UUID(),
                name: String,
                transport: MCPTransport,
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
    }
}

// MARK: - Errors

/// Named to avoid colliding with the SDK's own `MCPError`, which is in scope
/// for anyone importing `MCP` alongside this module.
public enum MCPBridgeError: LocalizedError, Equatable {
    case notConnected
    case unknownTool(String)
    case authRequired(URL)
    case invalidResponse
    case timedOut(String)
    case serverError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "MCP client is not connected."
        case .unknownTool(let name):
            return "No connected MCP server provides the tool \"\(name)\"."
        case .authRequired(let url):
            return "Authentication required for \(url.absoluteString)."
        case .invalidResponse:
            return "The MCP server returned an unexpected response."
        case .timedOut(let detail):
            return "Timed out. \(detail)"
        case .serverError(let code, let message):
            return "MCP server error \(code): \(message)"
        }
    }
}

// MARK: - Status

/// Live status of a configured server, for the host's UI to render.
public struct MCPServerStatus: Identifiable, Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case needsAuth
        case failed(String)
    }

    public let id: UUID
    public var name: String
    public var state: State
    public var toolCount: Int

    public init(id: UUID, name: String, state: State, toolCount: Int = 0) {
        self.id = id
        self.name = name
        self.state = state
        self.toolCount = toolCount
    }
}

// MARK: - Transport seam

/// Builds the transport for a server, given the session's working directory.
/// Supply one to reach a server the built-in stdio and HTTP transports can't —
/// or to drive the manager from tests without spawning anything.
public typealias MCPTransportFactory =
    @Sendable (MCPServerConfig, URL?) async throws -> any Transport

// MARK: - Auth seam

/// Supplies bearer tokens for servers configured with `.oauth`. Implement this
/// in the host, where the browser hand-off and token storage belong.
public protocol MCPAuthorizationProvider: Sendable {
    func accessToken(for url: URL) async throws -> String
}
