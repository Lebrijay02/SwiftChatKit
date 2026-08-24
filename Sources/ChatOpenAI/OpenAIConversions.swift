//
//  OpenAIConversions.swift
//  SwiftChatKit
//
//  The translation layer between ChatCore's neutral types and the
//  `/chat/completions` wire format. There is no SDK here to hide behind, so
//  "the SDK type" is `ChatValue` shaped into JSON — which is also why the
//  request side is built as values rather than Codable structs: tool arguments
//  are arbitrary JSON and have to pass through untouched.
//

import Foundation
import ChatCore

// MARK: - Tool declarations

extension ToolSchema {

    /// A JSON-Schema node. `.enumeration` becomes a string with an `enum`
    /// constraint, which is the only spelling every compatible server accepts.
    var jsonSchema: ChatValue {
        var node: [String: ChatValue] = [:]

        switch self {
        case .string:
            node["type"] = .string("string")
        case .enumeration(let values, _):
            node["type"] = .string("string")
            node["enum"] = .array(values.map(ChatValue.string))
        case .integer:
            node["type"] = .string("integer")
        case .number:
            node["type"] = .string("number")
        case .boolean:
            node["type"] = .string("boolean")
        case .array(let items, _):
            node["type"] = .string("array")
            node["items"] = items.jsonSchema
        case .object(let properties, let optional, _):
            node["type"] = .string("object")
            node["properties"] = .object(properties.mapValues(\.jsonSchema))
            node["required"] = .array(
                properties.keys.filter { !optional.contains($0) }.sorted().map(ChatValue.string))
        }

        if let description {
            node["description"] = .string(description)
        }
        return .object(node)
    }
}

extension ToolDeclaration {

    /// Keys are sorted throughout so two equal declarations serialize
    /// identically — providers cache on the request body.
    var openAIDeclaration: ChatValue {
        [
            "type": "function",
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": ToolSchema.object(properties: parameters,
                                                optional: optional).jsonSchema,
            ]),
        ]
    }
}

// MARK: - Turns → messages

extension ChatTurn {

    /// One turn can span several wire messages: a model turn with parallel tool
    /// calls is a single assistant message, but the results answering it are one
    /// `tool` message each, keyed by call id.
    var openAIMessages: [ChatValue] {
        role == .model ? Self.assistantMessages(parts) : Self.userMessages(parts)
    }

    private static func assistantMessages(_ parts: [TurnPart]) -> [ChatValue] {
        var text = ""
        var toolCalls: [ChatValue] = []

        for part in parts {
            switch part {
            case .text(let value):
                text += value
            case .toolCall(let call):
                toolCalls.append([
                    "id": .string(call.id),
                    "type": "function",
                    "function": .object([
                        "name": .string(call.name),
                        // Arguments travel as a JSON *string*, not an object.
                        "arguments": .string(ChatValue.object(call.arguments).jsonString()),
                    ]),
                ])
            case .inlineData, .toolResult:
                // Neither has an assistant-side representation on this API.
                continue
            }
        }

        guard !text.isEmpty || !toolCalls.isEmpty else { return [] }

        var message: [String: ChatValue] = ["role": "assistant"]
        // `content` stays present-but-null on a pure tool-call turn; several
        // compatible servers reject the message when the key is missing.
        message["content"] = text.isEmpty ? .null : .string(text)
        if !toolCalls.isEmpty {
            message["tool_calls"] = .array(toolCalls)
        }
        return [.object(message)]
    }

    private static func userMessages(_ parts: [TurnPart]) -> [ChatValue] {
        var messages: [ChatValue] = []
        var content: [ChatValue] = []

        for part in parts {
            switch part {
            case .text(let value):
                guard !value.isEmpty else { continue }
                content.append(["type": "text", "text": .string(value)])
            case .inlineData(let data, let mimeType):
                content.append([
                    "type": "image_url",
                    "image_url": .object([
                        "url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
                    ]),
                ])
            case .toolResult(let result):
                // Results are their own role and must not be folded into the
                // user message — the call/result pairing is by id, and a server
                // that can't find the pair rejects the whole conversation.
                messages.append([
                    "role": "tool",
                    "tool_call_id": .string(result.callID),
                    "content": .string(ChatValue.object(result.payload).jsonString()),
                ])
            case .toolCall:
                continue
            }
        }

        if !content.isEmpty {
            // A lone text part goes as a plain string: the array form is valid
            // everywhere in theory and rejected by a few servers in practice.
            let value: ChatValue
            if content.count == 1, let text = content[0]["text"]?.stringValue {
                value = .string(text)
            } else {
                value = .array(content)
            }
            messages.append(["role": "user", "content": value])
        }

        // Tool results before any new user text, matching the order the loop
        // produced them in.
        return messages
    }
}

extension Array where Element == ChatTurn {

    /// The full `messages` array, with the system instruction at the head.
    func openAIMessages(systemInstruction: String) -> [ChatValue] {
        let system: [ChatValue] = systemInstruction.isEmpty
            ? []
            : [["role": "system", "content": .string(systemInstruction)]]
        return system + flatMap(\.openAIMessages)
    }
}

// MARK: - Finish reason

extension FinishReason {

    /// The wire vocabulary is lowercase and shorter than `FinishReason`'s, so
    /// the raw-value initializer can't do this one.
    init(openAI raw: String) {
        switch raw {
        case "stop", "tool_calls", "function_call": self = .stop
        case "length", "max_tokens":                self = .maxTokens
        case "content_filter":                      self = .safety
        default:                                    self = .other
        }
    }
}
