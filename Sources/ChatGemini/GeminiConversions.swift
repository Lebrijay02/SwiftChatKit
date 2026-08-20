//
//  GeminiConversions.swift
//  SwiftChatKit
//
//  The translation layer between ChatCore's neutral types and FirebaseAILogic's.
//  Everything SDK-shaped stops here: nothing above `ChatBackend` imports
//  FirebaseAILogic, which is what lets a host swap providers without touching
//  its tools.
//

import Foundation
import FirebaseAILogic
import ChatCore

// MARK: - ChatValue ↔ JSONValue

extension ChatValue {

    init(_ json: JSONValue) {
        switch json {
        case .null:              self = .null
        case .bool(let b):       self = .bool(b)
        case .number(let n):     self = .number(n)
        case .string(let s):     self = .string(s)
        case .array(let items):  self = .array(items.map(ChatValue.init))
        case .object(let obj):   self = .object(obj.mapValues(ChatValue.init))
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .null:              return .null
        case .bool(let b):       return .bool(b)
        case .number(let n):     return .number(n)
        case .string(let s):     return .string(s)
        case .array(let items):  return .array(items.map(\.jsonValue))
        case .object(let obj):   return .object(obj.mapValues(\.jsonValue))
        }
    }
}

extension Dictionary where Key == String, Value == ChatValue {
    var jsonObject: JSONObject { mapValues(\.jsonValue) }
}

extension Dictionary where Key == String, Value == JSONValue {
    var chatValues: [String: ChatValue] { mapValues(ChatValue.init) }
}

// MARK: - Tool declarations

extension ToolSchema {

    /// Maps onto the JSON-Schema subset Vertex AI accepts. `.number` becomes
    /// `.double` — the SDK's spelling for the same wire type.
    var geminiSchema: Schema {
        switch self {
        case .string(let d):
            return .string(description: d)
        case .enumeration(let values, let d):
            return .enumeration(values: values, description: d)
        case .integer(let d):
            return .integer(description: d)
        case .number(let d):
            return .double(description: d)
        case .boolean(let d):
            return .boolean(description: d)
        case .array(let items, let d):
            return .array(items: items.geminiSchema, description: d)
        case .object(let properties, let optional, let d):
            return .object(properties: properties.mapValues(\.geminiSchema),
                           optionalProperties: optional,
                           description: d)
        }
    }
}

extension ToolDeclaration {

    var geminiDeclaration: FunctionDeclaration {
        FunctionDeclaration(name: name,
                            description: description,
                            parameters: parameters.mapValues(\.geminiSchema),
                            optionalParameters: optional)
    }
}

// MARK: - Calls and results

extension ToolCall {

    init(_ part: FunctionCallPart) {
        // Vertex omits the call id on single-call turns; synthesize one so the
        // loop can still pair the response back to its call.
        self.init(id: part.functionId ?? UUID().uuidString,
                  name: part.name,
                  arguments: part.args.chatValues)
    }
}

extension ToolResult {

    var geminiPart: FunctionResponsePart {
        FunctionResponsePart(name: name, response: payload.jsonObject, functionId: callID)
    }
}

// MARK: - Turns

extension TurnPart {

    /// Nil for parts with no Gemini equivalent, so a caller can `compactMap`
    /// rather than fabricate an empty part.
    var geminiPart: (any Part)? {
        switch self {
        case .text(let text):
            // The SDK rejects empty text parts; an empty assistant turn is
            // meaningless history anyway.
            return text.isEmpty ? nil : TextPart(text)
        case .inlineData(let data, let mimeType):
            return InlineDataPart(data: data, mimeType: mimeType)
        case .toolCall(let call):
            return FunctionCallPart(name: call.name,
                                    args: call.arguments.jsonObject,
                                    id: call.id)
        case .toolResult(let result):
            return result.geminiPart
        }
    }

    init?(_ part: any Part) {
        switch part {
        case let text as TextPart:
            // Reasoning traces are not transcript content.
            guard !text.isThought else { return nil }
            self = .text(text.text)
        case let inline as InlineDataPart:
            self = .inlineData(inline.data, mimeType: inline.mimeType)
        case let call as FunctionCallPart:
            self = .toolCall(ToolCall(call))
        case let response as FunctionResponsePart:
            self = .toolResult(ToolResult(callID: response.functionId ?? "",
                                          name: response.name,
                                          payload: response.response.chatValues))
        default:
            return nil
        }
    }
}

extension ChatTurn {

    /// Function *responses* go back with role "user" — that is what Vertex AI
    /// requires, and it is why `TurnRole` has no separate tool case.
    var modelContent: ModelContent {
        ModelContent(role: role == .model ? "model" : "user",
                     parts: parts.compactMap(\.geminiPart))
    }

    init(_ content: ModelContent) {
        self.init(role: content.role == "model" ? .model : .user,
                  parts: content.parts.compactMap(TurnPart.init))
    }
}
