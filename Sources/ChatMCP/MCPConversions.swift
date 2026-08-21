//
//  MCPConversions.swift
//  SwiftChatKit
//
//  The boundary where MCP's value and schema types meet ChatCore's. Nothing
//  above this file sees `MCP.Value`.
//

import Foundation
import MCP
import ChatCore

// MARK: - Values

extension ChatValue {
    init(_ value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .int(let number): self = .number(Double(number))
        case .double(let number): self = .number(number)
        case .string(let text): self = .string(text)
        // ChatValue has no binary case; a data URL keeps the bytes addressable
        // as a string rather than dropping them.
        case .data(let mimeType, let data):
            self = .string("data:\(mimeType ?? "application/octet-stream");base64,\(data.base64EncodedString())")
        case .array(let items): self = .array(items.map(ChatValue.init))
        case .object(let fields): self = .object(fields.mapValues(ChatValue.init))
        }
    }

    var mcpValue: MCP.Value {
        switch self {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number):
            // MCP distinguishes int from double, and servers with integer-typed
            // parameters reject 3.0 where they expect 3.
            return number == number.rounded() && abs(number) < 9_007_199_254_740_992
                ? .int(Int(number))
                : .double(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(\.mcpValue))
        case .object(let fields): return .object(fields.mapValues(\.mcpValue))
        }
    }
}

// MARK: - Schema

/// Translates an MCP tool's JSON-Schema `inputSchema` into `ToolSchema`.
enum MCPSchemaConverter {

    /// A tool's `inputSchema` is always a JSON-Schema object, so this returns
    /// the property map plus the names of the optional properties.
    static func parameters(_ value: MCP.Value?) -> (properties: [String: ToolSchema], optional: [String]) {
        guard let value, case .object(let fields) = value else { return ([:], []) }
        return objectProperties(from: fields)
    }

    static func convert(_ value: MCP.Value) -> ToolSchema {
        guard case .object(let fields) = value else { return .string() }
        // An untyped node is treated as an object, matching JSON Schema's own
        // default and the shape servers most often omit the type on.
        let type = string(fields["type"]) ?? "object"

        switch type {
        case "string":
            if let values = stringArray(fields["enum"]), !values.isEmpty {
                return .enumeration(values: values, description: description(fields))
            }
            return .string(description: description(fields))
        case "integer":
            return .integer(description: description(fields))
        case "number":
            return .number(description: description(fields))
        case "boolean":
            return .boolean(description: description(fields))
        case "array":
            let items = fields["items"].map(convert) ?? .string()
            return .array(items: items, description: description(fields))
        default:
            let (properties, optional) = objectProperties(from: fields)
            return .object(properties: properties,
                           optional: optional,
                           description: description(fields))
        }
    }

    // MARK: - Helpers

    private static func objectProperties(
        from fields: [String: MCP.Value]
    ) -> (properties: [String: ToolSchema], optional: [String]) {
        var properties: [String: ToolSchema] = [:]
        if case .object(let raw)? = fields["properties"] {
            for (key, value) in raw where !metaKeys.contains(key) {
                properties[key] = convert(value)
            }
        }
        let required = Set(stringArray(fields["required"]) ?? [])
        // Stated as optional-not-required because that is the direction both
        // Gemini and `ToolDeclaration` express it.
        return (properties, properties.keys.filter { !required.contains($0) }.sorted())
    }

    /// JSON-Schema keywords that are not properties. Composition keywords are
    /// dropped rather than approximated — a wrong schema is worse than a
    /// missing constraint, because the model believes it.
    private static let metaKeys: Set<String> = [
        "$schema", "$id", "$ref", "$defs", "definitions", "additionalProperties",
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else"
    ]

    private static func description(_ fields: [String: MCP.Value]) -> String? {
        string(fields["description"])
    }

    private static func string(_ value: MCP.Value?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func stringArray(_ value: MCP.Value?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }
}
