//
//  ChatValueTests.swift
//  SwiftChatKitTests
//
//  ChatValue is the type every tool argument, tool result and persisted payload
//  passes through, so its round-trips are the package's load-bearing invariant.
//

import Foundation
import Testing
@testable import ChatCore

@Suite("ChatValue")
struct ChatValueTests {

    private let sample: ChatValue = [
        "path": "/tmp/Notes.swift",
        "lines": 42,
        "ratio": 0.5,
        "replaceAll": false,
        "tags": ["a", "b"],
        "nested": ["deep": ["deeper": nil]],
    ]

    @Test("Codable round-trip preserves every case")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ChatValue.self, from: data)
        #expect(decoded == sample)
    }

    @Test("Booleans survive encoding rather than collapsing to 0 and 1")
    func boolIsNotANumber() throws {
        let data = try JSONEncoder().encode(ChatValue.bool(true))
        #expect(String(data: data, encoding: .utf8) == "true")
        #expect(try JSONDecoder().decode(ChatValue.self, from: data) == .bool(true))
    }

    @Test("JSONSerialization bridging round-trips, including bool-vs-number")
    func jsonObjectRoundTrip() {
        let bridged = ChatValue(json: sample.jsonObject)
        #expect(bridged == sample)
        #expect(bridged["replaceAll"] == .bool(false))
        #expect(bridged["lines"] == .number(42))
    }

    @Test("Serialized keys are sorted, so persisted sessions diff cleanly")
    func sortedKeys() {
        let value: ChatValue = ["zebra": 1, "apple": 2, "mango": 3]
        #expect(value.jsonString() == #"{"apple":2,"mango":3,"zebra":1}"#)
    }

    @Test("Parsing a malformed payload returns nil instead of trapping")
    func malformedParse() {
        // Models really do emit truncated arguments; this has to be recoverable.
        #expect(ChatValue.parse(#"{"path": "/tmp/a.swift", "conte"#) == nil)
        #expect(ChatValue.parse("") == nil)
    }

    @Test("Accessors are type-strict")
    func accessors() {
        #expect(sample["path"]?.stringValue == "/tmp/Notes.swift")
        #expect(sample["lines"]?.intValue == 42)
        // 0.5 has a fractional part, so it is not an Int — no silent truncation.
        #expect(sample["ratio"]?.intValue == nil)
        #expect(sample["ratio"]?.doubleValue == 0.5)
        #expect(sample["tags"]?.arrayValue?.count == 2)
        #expect(sample["missing"] == nil)
        #expect(sample["nested"]?["deep"]?["deeper"]?.isNull == true)
    }
}

@Suite("Finish reasons")
struct FinishReasonTests {

    @Test("Known backend raw values map to cases")
    func knownReasons() {
        #expect(FinishReason(rawValue: "STOP") == .stop)
        #expect(FinishReason(rawValue: "MAX_TOKENS") == .maxTokens)
        #expect(FinishReason(rawValue: "MALFORMED_FUNCTION_CALL") == .malformedFunctionCall)
    }

    @Test("An unrecognized reason degrades to .other rather than failing")
    func unknownReason() {
        #expect(FinishReason(rawValue: "SOME_FUTURE_REASON") == .other)
        #expect(FinishReason(rawValue: "SOME_FUTURE_REASON").userFacingNote == nil)
    }

    @Test("Only abnormal endings produce a note in the transcript")
    func notes() {
        #expect(FinishReason.stop.userFacingNote == nil)
        #expect(FinishReason.safety.userFacingNote != nil)
        #expect(FinishReason.maxTokens.userFacingNote?.contains("continue") == true)
    }
}

@Suite("Tool results")
struct ToolResultTests {

    @Test("Failures carry the message as data, keyed for the model to read")
    func failure() {
        let call = ToolCall(name: "editFile", arguments: ["path": "/tmp/a.swift"])
        let result = ToolResult.failure(call, "File not found")
        #expect(result.errorMessage == "File not found")
        #expect(result.callID == call.id)
        #expect(result.name == "editFile")
    }

    @Test("Successes report no error")
    func success() {
        let call = ToolCall(name: "readTextFile")
        #expect(ToolResult.success(call, ["content": "hi"]).errorMessage == nil)
    }

    @Test("A tool-call message keeps the exact arguments for history replay")
    func replayFidelity() {
        let call = ToolCall(name: "writeFile", arguments: ["path": "/tmp/a", "contents": "x"])
        let message = ChatMessage.toolCall(call)
        #expect(message.rawArguments == call.arguments)
        #expect(message.callID == call.id)
        #expect(message.toolName == "writeFile")
    }
}
