//
//  ToolDeclaration.swift
//  SwiftChatKit
//
//  Backend-neutral description of a callable tool, plus the call/result pair
//  that flows through the agent loop. A `ChatBackend` translates these into
//  whatever its SDK wants; nothing above the backend boundary sees that type.
//

import Foundation

// MARK: - Schema

/// A JSON-Schema subset — the intersection every model provider agrees on.
/// Deliberately not the full spec: anything richer stops round-tripping.
public indirect enum ToolSchema: Equatable, Sendable {
    case string(description: String? = nil)
    /// A string constrained to a fixed set of values.
    case enumeration(values: [String], description: String? = nil)
    case integer(description: String? = nil)
    case number(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: ToolSchema, description: String? = nil)
    /// `optional` names the properties a caller may omit; everything else in
    /// `properties` is required. Stated as optional-not-required because that
    /// is the direction both Gemini and MCP express it.
    case object(properties: [String: ToolSchema],
                optional: [String] = [],
                description: String? = nil)

    public var description: String? {
        switch self {
        case .string(let d), .integer(let d), .number(let d), .boolean(let d):
            return d
        case .enumeration(_, let d), .array(_, let d), .object(_, _, let d):
            return d
        }
    }
}

// MARK: - Declaration

public struct ToolDeclaration: Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    /// Top-level parameters. Always an object in JSON-Schema terms, so this is
    /// the property map rather than a wrapping `.object` node.
    public let parameters: [String: ToolSchema]
    /// Parameter names the model may omit.
    public let optional: [String]

    public var id: String { name }

    public init(name: String,
                description: String,
                parameters: [String: ToolSchema] = [:],
                optional: [String] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.optional = optional
    }
}

// MARK: - Call and result

public struct ToolCall: Equatable, Sendable, Identifiable {
    /// Backend-supplied correlation id when there is one. Parallel calls in a
    /// single turn are matched back by this, so it is generated when absent.
    public let id: String
    public let name: String
    public let arguments: [String: ChatValue]

    public init(id: String = UUID().uuidString,
                name: String,
                arguments: [String: ChatValue] = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let payload: [String: ChatValue]

    public init(callID: String, name: String, payload: [String: ChatValue]) {
        self.callID = callID
        self.name = name
        self.payload = payload
    }

    /// The conventional success shape, so providers don't each invent one.
    public static func success(_ call: ToolCall, _ payload: [String: ChatValue]) -> ToolResult {
        ToolResult(callID: call.id, name: call.name, payload: payload)
    }

    /// Errors are returned to the model as data, never thrown past the loop —
    /// a failed tool is something the model should read and recover from.
    public static func failure(_ call: ToolCall, _ message: String) -> ToolResult {
        ToolResult(callID: call.id, name: call.name,
                   payload: ["error": .string(message)])
    }

    public var errorMessage: String? { payload["error"]?.stringValue }
}

// MARK: - Finish reason

/// Why a turn stopped. Raw values match the strings backends emit today, so a
/// backend can map straight from its own enum's `rawValue`.
public enum FinishReason: String, Equatable, Sendable {
    case stop = "STOP"
    case maxTokens = "MAX_TOKENS"
    case safety = "SAFETY"
    case recitation = "RECITATION"
    case prohibitedContent = "PROHIBITED_CONTENT"
    case malformedFunctionCall = "MALFORMED_FUNCTION_CALL"
    case language = "LANGUAGE"
    case other = "OTHER"

    public init(rawValue: String) {
        self = FinishReason.allKnown[rawValue] ?? .other
    }

    private static let allKnown: [String: FinishReason] = [
        "STOP": .stop, "MAX_TOKENS": .maxTokens, "SAFETY": .safety,
        "RECITATION": .recitation, "PROHIBITED_CONTENT": .prohibitedContent,
        "MALFORMED_FUNCTION_CALL": .malformedFunctionCall, "LANGUAGE": .language,
    ]

    /// Text appended to the assistant bubble when a turn ends abnormally. Nil
    /// for `.stop`, which is the normal path and needs no note.
    public var userFacingNote: String? {
        switch self {
        case .stop, .other:
            return nil
        case .maxTokens:
            return "The response hit the output token limit and was cut off. Ask me to continue."
        case .safety:
            return "The response was blocked by a safety filter."
        case .prohibitedContent:
            return "The response was blocked as prohibited content."
        case .recitation:
            return "The response was blocked because it reproduced protected material."
        case .malformedFunctionCall:
            return "The model produced a malformed tool call and the turn was stopped."
        case .language:
            return "The response was blocked as an unsupported language."
        }
    }
}
