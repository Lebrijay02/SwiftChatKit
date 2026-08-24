//
//  OpenAIConversionTests.swift
//  SwiftChatKit
//
//  There is no SDK to reject a malformed request here, so a mistake in the
//  conversion layer reaches the network as a 400 with a vague message. These
//  tests pin the wire shape instead. No network, no key.
//

import Testing
import Foundation
@testable import ChatOpenAI
import ChatCore

@Suite("Tool declarations")
struct ToolDeclarationTests {

    private let declaration = ToolDeclaration(
        name: "readFile",
        description: "Reads a file.",
        parameters: [
            "path": .string(description: "Path to read."),
            "offset": .integer(),
            "mode": .enumeration(values: ["text", "binary"]),
            "tags": .array(items: .string()),
        ],
        optional: ["offset", "mode"])

    @Test func wrapsInAFunctionEnvelope() {
        let json = declaration.openAIDeclaration
        #expect(json["type"]?.stringValue == "function")
        #expect(json["function"]?["name"]?.stringValue == "readFile")
        #expect(json["function"]?["description"]?.stringValue == "Reads a file.")
        #expect(json["function"]?["parameters"]?["type"]?.stringValue == "object")
    }

    /// ChatCore states optionality; JSON Schema states requiredness. Getting the
    /// inversion wrong makes every optional parameter mandatory.
    @Test func invertsOptionalIntoRequired() {
        let required = declaration.openAIDeclaration["function"]?["parameters"]?["required"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(required == ["path", "tags"])
    }

    @Test func mapsEveryScalarType() {
        let cases: [(ToolSchema, String)] = [
            (.string(), "string"),
            (.integer(), "integer"),
            (.number(), "number"),
            (.boolean(), "boolean"),
            (.array(items: .string()), "array"),
            (.object(properties: [:]), "object"),
        ]
        for (schema, expected) in cases {
            #expect(schema.jsonSchema["type"]?.stringValue == expected)
        }
    }

    /// An enumeration is a constrained string, not a type of its own — a server
    /// receiving `"type": "enum"` rejects the tool list outright.
    @Test func rendersEnumerationAsConstrainedString() {
        let json = ToolSchema.enumeration(values: ["a", "b"], description: "Pick.").jsonSchema
        #expect(json["type"]?.stringValue == "string")
        #expect(json["enum"]?.arrayValue?.compactMap(\.stringValue) == ["a", "b"])
        #expect(json["description"]?.stringValue == "Pick.")
    }

    @Test func nestsArrayItemSchemas() {
        let json = ToolSchema.array(items: .object(properties: ["k": .boolean()])).jsonSchema
        #expect(json["items"]?["properties"]?["k"]?["type"]?.stringValue == "boolean")
    }

    @Test func omitsDescriptionWhenAbsent() {
        #expect(ToolSchema.string().jsonSchema["description"] == nil)
    }
}

@Suite("Turns → messages")
struct MessageConversionTests {

    @Test func putsSystemInstructionFirst() {
        let messages = [ChatTurn.user("hi")].openAIMessages(systemInstruction: "Be brief.")
        #expect(messages.count == 2)
        #expect(messages[0]["role"]?.stringValue == "system")
        #expect(messages[0]["content"]?.stringValue == "Be brief.")
        #expect(messages[1]["role"]?.stringValue == "user")
    }

    @Test func omitsSystemMessageWhenInstructionIsEmpty() {
        let messages = [ChatTurn.user("hi")].openAIMessages(systemInstruction: "")
        #expect(messages.count == 1)
        #expect(messages[0]["role"]?.stringValue == "user")
    }

    /// A lone text part goes as a plain string. The array form is valid in the
    /// spec and rejected by a few compatible servers.
    @Test func sendsPlainTextAsAString() {
        let messages = ChatTurn.user("hello").openAIMessages
        #expect(messages[0]["content"]?.stringValue == "hello")
    }

    @Test func sendsAttachmentsAsDataURLs() {
        let data = Data([0xFF, 0xD8, 0xFF])
        let turn = ChatTurn.user("look", attachments: [
            Attachment(kind: .image, data: data, mimeType: "image/jpeg"),
        ])
        let content = turn.openAIMessages[0]["content"]?.arrayValue
        #expect(content?.count == 2)
        #expect(content?[0]["type"]?.stringValue == "image_url")
        #expect(content?[0]["image_url"]?["url"]?.stringValue
                == "data:image/jpeg;base64,\(data.base64EncodedString())")
        #expect(content?[1]["text"]?.stringValue == "look")
    }

    /// Arguments travel as a JSON *string*, not an object. Sending the object
    /// is the single most common way to get a 400 out of this API.
    @Test func encodesToolCallArgumentsAsAString() {
        let turn = ChatTurn(role: .model, parts: [
            .toolCall(ToolCall(id: "call_1", name: "readFile",
                               arguments: ["path": .string("/tmp/a"), "offset": .number(3)])),
        ])
        let call = turn.openAIMessages[0]["tool_calls"]?.arrayValue?[0]
        #expect(call?["id"]?.stringValue == "call_1")
        #expect(call?["type"]?.stringValue == "function")
        #expect(call?["function"]?["name"]?.stringValue == "readFile")
        #expect(call?["function"]?["arguments"]?.stringValue == #"{"offset":3,"path":"\/tmp\/a"}"#)
    }

    /// Servers differ on whether a missing `content` is allowed alongside
    /// `tool_calls`; an explicit null is accepted everywhere.
    @Test func keepsContentPresentOnAPureToolCallTurn() {
        let turn = ChatTurn(role: .model, parts: [.toolCall(ToolCall(name: "ls"))])
        #expect(turn.openAIMessages[0]["content"] == ChatValue.null)
    }

    @Test func coalescesModelTextIntoOneMessage() {
        let turn = ChatTurn(role: .model, parts: [
            .text("Reading "), .text("the file."), .toolCall(ToolCall(id: "c", name: "ls")),
        ])
        #expect(turn.openAIMessages.count == 1)
        #expect(turn.openAIMessages[0]["content"]?.stringValue == "Reading the file.")
    }

    /// Parallel results are one `tool` message each. Folding them together
    /// loses the call/result pairing and the server rejects the conversation.
    @Test func splitsParallelToolResultsIntoOneMessageEach() {
        let turn = ChatTurn(role: .user, parts: [
            .toolResult(ToolResult(callID: "c1", name: "ls", payload: ["out": .string("a")])),
            .toolResult(ToolResult(callID: "c2", name: "pwd", payload: ["out": .string("/")])),
        ])
        let messages = turn.openAIMessages
        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0["role"]?.stringValue == "tool" })
        #expect(messages[0]["tool_call_id"]?.stringValue == "c1")
        #expect(messages[1]["tool_call_id"]?.stringValue == "c2")
        #expect(messages[0]["content"]?.stringValue == #"{"out":"a"}"#)
    }

    @Test func producesNoMessageForAnEmptyTurn() {
        #expect(ChatTurn(role: .model, parts: []).openAIMessages.isEmpty)
        #expect(ChatTurn(role: .user, parts: []).openAIMessages.isEmpty)
    }
}

@Suite("Finish reasons")
struct FinishReasonTests {

    @Test func mapsTheWireVocabulary() {
        #expect(FinishReason(openAI: "stop") == .stop)
        #expect(FinishReason(openAI: "tool_calls") == .stop)
        #expect(FinishReason(openAI: "length") == .maxTokens)
        #expect(FinishReason(openAI: "content_filter") == .safety)
        #expect(FinishReason(openAI: "something_new") == .other)
    }
}

@Suite("Endpoint URL")
struct EndpointTests {

    private func url(_ base: String) -> String? {
        OpenAIBackendConfig(baseURL: base, apiKey: "k", model: .gpt4o)?
            .completionsURL.absoluteString
    }

    @Test func appendsThePathToARoot() {
        #expect(url("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
    }

    @Test func toleratesATrailingSlash() {
        #expect(url("https://api.openai.com/v1/") == "https://api.openai.com/v1/chat/completions")
    }

    /// Pasting the full endpoint is likelier than pasting the root, so it must
    /// not produce `/chat/completions/chat/completions`.
    @Test func leavesAFullEndpointAlone() {
        #expect(url("http://localhost:11434/v1/chat/completions")
                == "http://localhost:11434/v1/chat/completions")
    }

    @Test func rejectsAStringThatIsNotAURL() {
        #expect(OpenAIBackendConfig(baseURL: "not a url", apiKey: "k", model: .gpt4o) == nil)
    }
}
