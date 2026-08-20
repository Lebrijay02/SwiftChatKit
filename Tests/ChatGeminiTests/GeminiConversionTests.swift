//
//  GeminiConversionTests.swift
//  SwiftChatKit
//
//  The conversion layer is the only place a ChatCore type meets an SDK type, so
//  it is the only place a mismatch can silently corrupt a tool payload. These
//  tests need no network and no Firebase configuration.
//

import Testing
import Foundation
import FirebaseAILogic
@testable import ChatGemini
import ChatCore

@Suite("ChatValue ↔ JSONValue")
struct ChatValueBridgeTests {

    /// Values the model actually sends: nested objects, mixed arrays, nulls.
    private let sample: ChatValue = .object([
        "path": .string("/tmp/a.swift"),
        "line": .number(42),
        "dryRun": .bool(false),
        "missing": .null,
        "edits": .array([
            .object(["old": .string("a"), "new": .string("b")]),
            .object(["old": .string("c"), "new": .string("d")]),
        ]),
    ])

    @Test func roundTripsUnchanged() {
        #expect(ChatValue(sample.jsonValue) == sample)
    }

    @Test func preservesEveryCase() {
        let cases: [ChatValue] = [.null, .bool(true), .bool(false), .number(0),
                                  .number(-1.5), .string(""), .string("x"),
                                  .array([]), .object([:])]
        for value in cases {
            #expect(ChatValue(value.jsonValue) == value)
        }
    }

    /// Booleans and numbers share a representation in some JSON encoders; a
    /// `true` arriving back as `1` would break every boolean tool argument.
    @Test func boolsDoNotBecomeNumbers() {
        guard case .bool = ChatValue.bool(true).jsonValue else {
            Issue.record("bool converted to a non-bool JSONValue")
            return
        }
        #expect(ChatValue(JSONValue.bool(true)) == .bool(true))
        #expect(ChatValue(JSONValue.number(1)) == .number(1))
    }

    @Test func dictionaryHelpersMirrorEachOther() {
        let payload: [String: ChatValue] = ["ok": .bool(true), "count": .number(3)]
        #expect(payload.jsonObject.chatValues == payload)
    }
}

@Suite("Tool declaration conversion")
struct ToolDeclarationConversionTests {

    /// `FunctionDeclaration`'s stored properties are internal to the SDK, so the
    /// encoded wire form is the only thing a test can inspect — and it is the
    /// thing that actually reaches Vertex AI anyway.
    private func wireForm(_ declaration: ToolDeclaration) throws -> [String: Any] {
        let data = try JSONEncoder().encode(declaration.geminiDeclaration)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func carriesNameDescriptionAndOptionality() throws {
        let json = try wireForm(ToolDeclaration(
            name: "readFile",
            description: "Reads a file.",
            parameters: [
                "path": .string(description: "Absolute path"),
                "limit": .integer(description: "Max lines"),
            ],
            optional: ["limit"]))

        #expect(json["name"] as? String == "readFile")
        #expect(json["description"] as? String == "Reads a file.")

        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "OBJECT")
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["limit", "path"])
        // Optionality is expressed as "everything not listed is required".
        #expect(parameters["required"] as? [String] == ["path"])
    }

    /// Every schema case must survive the trip with its type intact — a lost
    /// type means a rejected or misinterpreted tool call.
    @Test func convertsEverySchemaCase() throws {
        let expected: [(ToolSchema, String)] = [
            (.string(description: "s"), "STRING"),
            (.enumeration(values: ["a", "b"], description: "e"), "STRING"),
            (.integer(description: "i"), "INTEGER"),
            (.number(description: "n"), "NUMBER"),
            (.boolean(description: "b"), "BOOLEAN"),
            (.array(items: .string(), description: "arr"), "ARRAY"),
            (.object(properties: [:], description: "o"), "OBJECT"),
        ]

        for (schema, type) in expected {
            let json = try wireForm(ToolDeclaration(name: "t", description: "d",
                                                   parameters: ["p": schema]))
            let properties = try #require(
                (json["parameters"] as? [String: Any])?["properties"] as? [String: Any])
            let property = try #require(properties["p"] as? [String: Any])
            #expect(property["type"] as? String == type)
            #expect(property["description"] as? String == schema.description)
        }
    }

    @Test func enumerationCarriesItsValues() throws {
        let json = try wireForm(ToolDeclaration(
            name: "t", description: "d",
            parameters: ["mode": .enumeration(values: ["read", "write"])]))
        let property = try #require(
            ((json["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["mode"]
                as? [String: Any])
        #expect(property["enum"] as? [String] == ["read", "write"])
    }

    @Test func nestedSchemasRecurse() throws {
        let json = try wireForm(ToolDeclaration(
            name: "t", description: "d",
            parameters: ["edits": .array(items: .object(properties: [
                "old": .string(), "new": .string(),
            ]))]))
        let edits = try #require(
            ((json["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["edits"]
                as? [String: Any])
        let items = try #require(edits["items"] as? [String: Any])
        #expect(items["type"] as? String == "OBJECT")
        #expect((items["properties"] as? [String: Any])?.keys.sorted() == ["new", "old"])
    }

    @Test func toolWithNoParametersConverts() throws {
        let json = try wireForm(ToolDeclaration(name: "listTodos", description: "Lists todos."))
        #expect(json["name"] as? String == "listTodos")
    }
}

@Suite("Part and turn conversion")
struct PartConversionTests {

    @Test func textPartRoundTrips() throws {
        let part = try #require(TurnPart.text("hello").geminiPart)
        #expect(TurnPart(part) == .text("hello"))
    }

    /// Vertex rejects empty text parts, and an empty assistant turn carries no
    /// information worth replaying.
    @Test func emptyTextIsDropped() {
        #expect(TurnPart.text("").geminiPart == nil)
    }

    @Test func inlineDataRoundTrips() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        let part = try #require(TurnPart.inlineData(bytes, mimeType: "image/jpeg").geminiPart)
        #expect(TurnPart(part) == .inlineData(bytes, mimeType: "image/jpeg"))
    }

    @Test func toolCallRoundTripsWithArgumentsAndID() throws {
        let call = ToolCall(id: "call-1", name: "grep",
                            arguments: ["pattern": .string("TODO"), "caseSensitive": .bool(false)])
        let part = try #require(TurnPart.toolCall(call).geminiPart)
        guard case .toolCall(let decoded) = try #require(TurnPart(part)) else {
            Issue.record("expected a tool call")
            return
        }
        #expect(decoded == call)
    }

    @Test func toolResultRoundTrips() throws {
        let result = ToolResult(callID: "call-1", name: "grep",
                                payload: ["matches": .array([.string("a.swift:3")])])
        let part = try #require(TurnPart.toolResult(result).geminiPart)
        guard case .toolResult(let decoded) = try #require(TurnPart(part)) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(decoded == result)
    }

    /// A model's parallel calls are one turn; splitting them would desynchronize
    /// the response pairing on the way back.
    @Test func turnKeepsParallelCallsTogether() {
        let turn = ChatTurn(role: .model, parts: [
            .toolCall(ToolCall(id: "a", name: "readFile")),
            .toolCall(ToolCall(id: "b", name: "readFile")),
        ])
        let content = turn.modelContent
        #expect(content.role == "model")
        #expect(content.parts.count == 2)
        #expect(ChatTurn(content).parts.count == 2)
    }

    /// Function responses must go back as role "user" regardless of who
    /// produced them, or Vertex rejects the turn.
    @Test func toolResultsAreSentAsUser() {
        let turn = ChatTurn(role: .user, parts: [
            .toolResult(ToolResult(callID: "a", name: "readFile", payload: ["ok": .bool(true)])),
        ])
        #expect(turn.modelContent.role == "user")
    }

    @Test func userTurnCarriesAttachmentsBeforeText() {
        let attachment = Attachment.image(Data([0x00]), mimeType: "image/png")
        let content = ChatTurn.user("describe this", attachments: [attachment]).modelContent
        #expect(content.parts.count == 2)
        #expect(content.parts.first is InlineDataPart)
    }
}

@Suite("Gemini models")
struct GeminiModelTests {

    @Test func knownModelsHaveDisplayNames() {
        #expect(GeminiModel.gemini3_5Flash.displayName == "Gemini 3.5 Flash")
        #expect(GeminiModel.known.count == 7)
    }

    /// A model released after this package was compiled must still be usable.
    @Test func unknownModelStillReadsWell() {
        #expect(GeminiModel("gemini-9-ultra-preview").displayName == "Gemini 9 Ultra")
    }

    @Test func rawValueRoundTrips() {
        #expect(GeminiModel(rawValue: "gemini-2.5-pro") == .gemini2_5Pro)
    }
}
