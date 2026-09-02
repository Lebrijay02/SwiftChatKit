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
public enum MCPTransport: Equatable, Sendable {
    /// Remote Streamable-HTTP server.
    case http(url: URL, auth: MCPAuth)
    /// Local subprocess speaking MCP over stdio, e.g. `npx xcodebuildmcp@latest mcp`.
    ///
    /// - Parameters:
    ///   - environment: Merged *over* the inherited environment, so a caller
    ///     can override `PATH` while everyone who passes nothing still gets the
    ///     Homebrew and `nvm` augmentation.
    ///   - workingDirectory: Overrides the session's working directory when
    ///     set. A server checked out somewhere other than the user's project
    ///     has to run from its own directory.
    ///
    /// Swift does not allow default values on an enum case's associated
    /// values; the static overloads below stand in for them.
    case stdio(command: String,
               arguments: [String],
               environment: [String: String],
               workingDirectory: URL?)

    public static func stdio(command: String, arguments: [String]) -> MCPTransport {
        .stdio(command: command, arguments: arguments, environment: [:], workingDirectory: nil)
    }

    public static func stdio(command: String,
                             arguments: [String],
                             environment: [String: String]) -> MCPTransport {
        .stdio(command: command, arguments: arguments,
               environment: environment, workingDirectory: nil)
    }

    public static func stdio(command: String,
                             arguments: [String],
                             workingDirectory: URL?) -> MCPTransport {
        .stdio(command: command, arguments: arguments,
               environment: [:], workingDirectory: workingDirectory)
    }
}

// MARK: - Transport persistence

/// Hand-written rather than synthesized for two reasons: a payload written
/// before `environment` and `workingDirectory` existed must still decode, and
/// `environment` must never be written out at all.
///
/// The wire shape matches what the synthesized conformance produced, so
/// existing stored server lists load unchanged.
extension MCPTransport: Codable {

    private enum CodingKeys: String, CodingKey { case http, stdio }
    private enum HTTPKeys: String, CodingKey { case url, auth }
    private enum StdioKeys: String, CodingKey {
        case command, arguments, environment, workingDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.http) {
            let nested = try container.nestedContainer(keyedBy: HTTPKeys.self, forKey: .http)
            self = .http(url: try nested.decode(URL.self, forKey: .url),
                         auth: try nested.decode(MCPAuth.self, forKey: .auth))
            return
        }

        let nested = try container.nestedContainer(keyedBy: StdioKeys.self, forKey: .stdio)
        self = .stdio(
            command: try nested.decode(String.self, forKey: .command),
            arguments: try nested.decodeIfPresent([String].self, forKey: .arguments) ?? [],
            environment: try nested.decodeIfPresent([String: String].self,
                                                    forKey: .environment) ?? [:],
            workingDirectory: try nested.decodeIfPresent(URL.self, forKey: .workingDirectory))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .http(let url, let auth):
            var nested = container.nestedContainer(keyedBy: HTTPKeys.self, forKey: .http)
            try nested.encode(url, forKey: .url)
            try nested.encode(auth, forKey: .auth)

        case .stdio(let command, let arguments, _, let workingDirectory):
            var nested = container.nestedContainer(keyedBy: StdioKeys.self, forKey: .stdio)
            try nested.encode(command, forKey: .command)
            try nested.encode(arguments, forKey: .arguments)
            // `environment` is deliberately dropped. It carries the API keys and
            // credentials the server needs, and `MCPServerStore` writes this
            // into `UserDefaults` — a plist on disk in the clear. The host
            // re-supplies it through `seedServers` on every launch instead.
            try nested.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        }
    }
}

/// A configured MCP server.
public struct MCPServerConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransport
    public var enabled: Bool
    /// Overrides the manager's `requestTimeout` for this server's calls.
    ///
    /// Stored as seconds rather than a `Duration` so the persisted JSON stays
    /// legible. One server running a half-hour job should not force every other
    /// server's calls to hang for half an hour before they give up.
    public var requestTimeoutSeconds: Double?

    public init(id: UUID = UUID(),
                name: String,
                transport: MCPTransport,
                enabled: Bool = true,
                requestTimeoutSeconds: Double? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.enabled = enabled
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    /// The override as a `Duration`, or nil to take the manager's default.
    public var requestTimeout: Duration? {
        requestTimeoutSeconds.map { .seconds($0) }
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
    case cancelled
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
        case .cancelled:
            return "The MCP tool call was cancelled."
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

/// Progress reported by an in-flight MCP tool call, for the host to render.
///
/// A long tool otherwise gives the UI nothing to show for minutes at a stretch,
/// which is indistinguishable from being wedged.
public struct MCPToolProgress: Equatable, Sendable {
    public let serverID: UUID
    public let serverName: String
    /// The name the model called, not the server's own name for the tool.
    public let toolName: String
    /// 0…1 when the server sent a total to measure against, nil otherwise.
    public let fraction: Double?
    public let message: String?

    public init(serverID: UUID,
                serverName: String,
                toolName: String,
                fraction: Double?,
                message: String?) {
        self.serverID = serverID
        self.serverName = serverName
        self.toolName = toolName
        self.fraction = fraction
        self.message = message
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
