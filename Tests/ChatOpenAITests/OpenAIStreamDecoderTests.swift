//
//  OpenAIStreamDecoderTests.swift
//  SwiftChatKit
//
//  Tool calls arrive split across SSE frames and correlated only by index, so
//  reassembly is where this backend is most likely to lose a call — quietly,
//  and only under parallel calls or a chatty server. Hence these tests.
//

import Testing
import Foundation
@testable import ChatOpenAI
import ChatCore

@Suite("SSE framing")
struct FramingTests {

    @Test func ignoresNonDataLines() {
        var decoder = OpenAIStreamDecoder()
        #expect(decoder.chunks(forLine: "").isEmpty)
        #expect(decoder.chunks(forLine: ": keep-alive").isEmpty)
        #expect(decoder.chunks(forLine: "event: message").isEmpty)
    }

    @Test func ignoresTheDoneSentinel() {
        var decoder = OpenAIStreamDecoder()
        #expect(decoder.chunks(forLine: "data: [DONE]").isEmpty)
    }

    /// A malformed frame from a third-party server should cost one delta, not
    /// the whole turn.
    @Test func skipsUnparseableFrames() {
        var decoder = OpenAIStreamDecoder()
        #expect(decoder.chunks(forLine: "data: {not json").isEmpty)
    }

    @Test func yieldsTextDeltas() {
        var decoder = OpenAIStreamDecoder()
        let chunks = decoder.chunks(
            forLine: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#)
        #expect(chunks == [.text("Hel")])
    }

    @Test func dropsEmptyTextDeltas() {
        var decoder = OpenAIStreamDecoder()
        #expect(decoder.chunks(forLine: #"data: {"choices":[{"delta":{"content":""}}]}"#).isEmpty)
        #expect(decoder.chunks(forLine: #"data: {"choices":[{"delta":{}}]}"#).isEmpty)
    }

    @Test func readsUsageFromTheFinalChunk() {
        var decoder = OpenAIStreamDecoder()
        let chunks = decoder.chunks(
            forLine: #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14}}"#)
        #expect(chunks == [.usage(TokenUsage(prompt: 10, completion: 4, total: 14))])
    }
}

@Suite("Tool call reassembly")
struct ToolCallReassemblyTests {

    /// The canonical shape: id and name in the first frame, arguments dribbling
    /// in across the rest, nothing emitted until `finish_reason` arrives.
    @Test func assemblesACallAcrossFrames() {
        var decoder = OpenAIStreamDecoder()
        let frames = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"readFile","arguments":""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"/tmp/a\"}"}}]}}]}"#,
        ]
        for frame in frames {
            #expect(decoder.chunks(forLine: frame).isEmpty)
        }

        let final = decoder.chunks(forLine: #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        #expect(final.count == 2)
        guard case .toolCall(let call) = final[0] else {
            Issue.record("expected a tool call, got \(final[0])")
            return
        }
        #expect(call.id == "call_1")
        #expect(call.name == "readFile")
        #expect(call.arguments == ["path": .string("/tmp/a")])
        // The call must precede the finish chunk: the loop stops reading at it.
        #expect(final[1] == .finish(.stop))
    }

    @Test func keepsParallelCallsSeparateAndOrdered() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"ls","arguments":"{}"}},{"index":1,"id":"b","function":{"name":"pwd","arguments":"{}"}}]}}]}"#)
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":""}}]}}]}"#)

        let calls = decoder.flushToolCalls().compactMap { chunk -> ToolCall? in
            guard case .toolCall(let call) = chunk else { return nil }
            return call
        }
        #expect(calls.map(\.id) == ["a", "b"])
        #expect(calls.map(\.name) == ["ls", "pwd"])
    }

    /// Some servers split the name too, and some omit `index` because they only
    /// ever stream one call at a time.
    @Test func toleratesSplitNamesAndMissingIndexes() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"id":"z","function":{"name":"read"}}]}}]}"#)
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"File","arguments":"{}"}}]}}]}"#)

        guard case .toolCall(let call)? = decoder.flushToolCalls().first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.name == "readFile")
        #expect(call.id == "z")
    }

    /// Truncated arguments must not throw past the loop — an empty map lets the
    /// tool report the real problem back to the model, which it can recover from.
    @Test func degradesTruncatedArgumentsToAnEmptyMap() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"ls","arguments":"{\"path\":"}}]}}]}"#)

        guard case .toolCall(let call)? = decoder.flushToolCalls().first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(call.arguments.isEmpty)
    }

    @Test func synthesizesAnIDWhenTheServerOmitsOne() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"ls","arguments":"{}"}}]}}]}"#)

        guard case .toolCall(let call)? = decoder.flushToolCalls().first else {
            Issue.record("expected a tool call")
            return
        }
        #expect(!call.id.isEmpty)
    }

    @Test func flushingTwiceDoesNotDuplicateACall() {
        var decoder = OpenAIStreamDecoder()
        _ = decoder.chunks(forLine: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"ls","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#)
        #expect(decoder.flushToolCalls().isEmpty)
    }

    @Test func flushIsEmptyWhenNothingIsPending() {
        var decoder = OpenAIStreamDecoder()
        #expect(decoder.flushToolCalls().isEmpty)
    }
}
