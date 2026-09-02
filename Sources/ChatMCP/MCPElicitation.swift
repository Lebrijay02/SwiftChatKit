//
//  MCPElicitation.swift
//  SwiftChatKit
//
//  Server→client requests. Everything else in this bridge runs in one
//  direction — the client calls, the server answers — but `elicitation/create`
//  inverts it: the server parks its own tool call and waits for a human.
//
//  The package declares the capability and routes the request; the host renders
//  the UI and decides, the same division `MCPAuthorizationProvider` draws.
//

import Foundation
import ChatCore
import MCP

/// One field parsed from an elicitation request's JSON schema.
public struct MCPElicitationField: Sendable, Hashable, Identifiable {

    public enum Kind: String, Sendable, Hashable {
        case string, boolean, number, integer, singleChoice, multiChoice
    }

    public var id: String { key }
    /// Property name to key the answer by in `MCPElicitationResponse.content`.
    public let key: String
    public let kind: Kind
    /// The schema's `title`, falling back to the property key.
    public let title: String
    public let description: String
    /// Non-empty for `.singleChoice` and `.multiChoice`, empty otherwise.
    public let options: [String]
    /// Whether the server listed this property in `required`.
    public let isRequired: Bool

    public init(key: String,
                kind: Kind,
                title: String? = nil,
                description: String = "",
                options: [String] = [],
                isRequired: Bool = false) {
        self.key = key
        self.kind = kind
        self.title = title ?? key
        self.description = description
        self.options = options
        self.isRequired = isRequired
    }
}

/// A server asking the user for something mid-tool-call.
public struct MCPElicitationRequest: Sendable, Identifiable, Hashable {
    /// The JSON-RPC request id, rendered as a string. Stable for the lifetime
    /// of the request, which is what a host needs to key a presented sheet by.
    public let id: String
    /// Name of the server that asked, for the host to attribute the prompt.
    public let serverName: String
    public let message: String
    public let fields: [MCPElicitationField]
    /// Set for the URL-form variant, used for OAuth hand-offs: there is nothing
    /// to fill in, only a page to open. `fields` is empty when this is non-nil.
    public let url: URL?

    public init(id: String,
                serverName: String = "",
                message: String,
                fields: [MCPElicitationField] = [],
                url: URL? = nil) {
        self.id = id
        self.serverName = serverName
        self.message = message
        self.fields = fields
        self.url = url
    }
}

public enum MCPElicitationAction: String, Sendable, Hashable {
    /// The user filled the form in. `content` is sent back.
    case accept
    /// The user said no. The server is expected to carry on without an answer.
    case decline
    /// The user dismissed the prompt without deciding.
    case cancel
}

public struct MCPElicitationResponse: Sendable {
    public let action: MCPElicitationAction
    /// Keyed by `MCPElicitationField.key`. Ignored unless `action == .accept`.
    public let content: [String: ChatValue]

    public init(action: MCPElicitationAction, content: [String: ChatValue] = [:]) {
        self.action = action
        self.content = content
    }

    public static let declined = MCPElicitationResponse(action: .decline)
    public static let cancelled = MCPElicitationResponse(action: .cancel)
}

/// Answers `elicitation/create`. The host owns the UI and the suspension —
/// returning is what unblocks the server's tool call, so an implementation that
/// never returns wedges the run exactly as badly as dropping the request did.
///
/// Supplying one is what makes the client advertise the capability. A client
/// that declares `elicitation` and then never answers is worse than one that
/// stays quiet, because the server waits instead of falling back.
public protocol MCPElicitationHandler: Sendable {
    func elicit(_ request: MCPElicitationRequest) async -> MCPElicitationResponse
}

// MARK: - Schema parsing

/// Reads the `requestedSchema` of an `elicitation/create` request.
///
/// Deliberately total: an unrecognised property type reads as `.string` rather
/// than failing the request, because a server parked on an answer would rather
/// have a wrong-typed one than none at all.
enum MCPElicitationParser {

    static func request(id: String,
                        serverName: String,
                        params: MCP.Value?) -> MCPElicitationRequest? {
        guard case .object(let fields)? = params else { return nil }

        var message = ""
        if case .string(let text)? = fields["message"] { message = text }

        // The URL form carries a page to open instead of a form to fill in.
        if case .string(let text)? = fields["url"], let url = URL(string: text) {
            return MCPElicitationRequest(id: id, serverName: serverName,
                                         message: message, fields: [], url: url)
        }

        return MCPElicitationRequest(id: id,
                                     serverName: serverName,
                                     message: message,
                                     fields: self.fields(from: fields["requestedSchema"]))
    }

    static func fields(from schema: MCP.Value?) -> [MCPElicitationField] {
        guard case .object(let root)? = schema,
              case .object(let properties)? = root["properties"] else { return [] }

        var required: Set<String> = []
        if case .array(let names)? = root["required"] {
            required = Set(names.compactMap { if case .string(let name) = $0 { name } else { nil } })
        }

        // Property order is not preserved by JSON decoding, so sort by key —
        // an order that changes between identical requests reads as a bug.
        return properties.keys.sorted().map { key in
            field(key: key, schema: properties[key], isRequired: required.contains(key))
        }
    }

    private static func field(key: String,
                              schema: MCP.Value?,
                              isRequired: Bool) -> MCPElicitationField {
        guard case .object(let property)? = schema else {
            return MCPElicitationField(key: key, kind: .string, isRequired: isRequired)
        }

        let title = string(property["title"])
        let description = string(property["description"]) ?? ""
        let type = string(property["type"])

        // Two shapes, both emitted by servers built on the Python SDK's choice
        // helper: `{"type":"string","enum":[…]}` and
        // `{"type":"array","items":{"enum":[…]}}`.
        if let options = strings(property["enum"]), !options.isEmpty {
            return MCPElicitationField(key: key, kind: .singleChoice, title: title,
                                       description: description, options: options,
                                       isRequired: isRequired)
        }
        if type == "array" {
            var options: [String] = []
            if case .object(let items)? = property["items"] {
                options = strings(items["enum"]) ?? []
            }
            return MCPElicitationField(key: key, kind: .multiChoice, title: title,
                                       description: description, options: options,
                                       isRequired: isRequired)
        }

        let kind = MCPElicitationField.Kind(rawValue: type ?? "string") ?? .string
        // `singleChoice`/`multiChoice` are ours, not JSON Schema's — a server
        // that literally wrote `"type": "singleChoice"` would otherwise arrive
        // here claiming options it never listed.
        let scalar: MCPElicitationField.Kind
        switch kind {
        case .string, .boolean, .number, .integer: scalar = kind
        case .singleChoice, .multiChoice: scalar = .string
        }
        return MCPElicitationField(key: key, kind: scalar, title: title,
                                   description: description, isRequired: isRequired)
    }

    private static func string(_ value: MCP.Value?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func strings(_ value: MCP.Value?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }
}
