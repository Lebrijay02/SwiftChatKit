//
//  OpenAIStreamDecoder.swift
//  SwiftChatKit
//
//  Reassembles a `text/event-stream` of chat-completion deltas into `TurnChunk`s.
//
//  Text arrives ready to forward, but tool calls do not: name and arguments are
//  split across chunks and correlated only by an `index`, so a call can be
//  emitted only once the choice reports it is finished. That buffering is the
//  whole reason this is a type and not a `map`.
//

import Foundation
import ChatCore

// MARK: - Wire types

/// Only the fields this backend acts on. Unknown keys — and there are many,
/// varying per provider — are ignored by `JSONDecoder` rather than rejected.
struct OpenAIStreamChunk: Decodable {

    struct FunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let function: FunctionDelta?
    }

    struct Delta: Decodable {
        let content: String?
        let toolCalls: [ToolCallDelta]?
    }

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
    }

    let choices: [Choice]?
    let usage: Usage?

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// The error envelope every compatible server returns, give or take. `message`
/// is the only field worth surfacing; the rest is provider-specific.
struct OpenAIErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }
    let error: Payload?
}

// MARK: - Decoder

/// Not thread-safe by design — one instance belongs to one stream, which is
/// consumed by one task.
struct OpenAIStreamDecoder {

    /// A tool call under construction, keyed by the `index` the server assigns.
    private struct PendingCall {
        var id: String?
        var name = ""
        var arguments = ""
    }

    private var pending: [Int: PendingCall] = [:]

    /// The chunks `line` produces, in order. Empty for keep-alives, comments,
    /// the `[DONE]` sentinel and anything unparseable — a malformed frame from a
    /// third-party server should cost a delta, not the turn.
    mutating func chunks(forLine line: String) -> [TurnChunk] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return [] }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let chunk = try? OpenAIStreamChunk.decoder.decode(OpenAIStreamChunk.self, from: data)
        else { return [] }

        return self.chunks(for: chunk)
    }

    mutating func chunks(for chunk: OpenAIStreamChunk) -> [TurnChunk] {
        var output: [TurnChunk] = []

        for choice in chunk.choices ?? [] {
            if let content = choice.delta?.content, !content.isEmpty {
                output.append(.text(content))
            }

            for delta in choice.delta?.toolCalls ?? [] {
                // A server that omits `index` is one that streams a single call
                // at a time; slot 0 is then the only slot in play.
                let index = delta.index ?? 0
                var call = pending[index] ?? PendingCall()
                if let id = delta.id { call.id = id }
                if let name = delta.function?.name { call.name += name }
                if let arguments = delta.function?.arguments { call.arguments += arguments }
                pending[index] = call
            }

            if let reason = choice.finishReason {
                // Calls must land before the finish chunk — the loop treats
                // `.finish` as the end of the turn and stops reading.
                output.append(contentsOf: flushToolCalls())
                output.append(.finish(FinishReason(openAI: reason)))
            }
        }

        if let usage = chunk.usage {
            output.append(.usage(TokenUsage(prompt: usage.promptTokens ?? 0,
                                            completion: usage.completionTokens ?? 0,
                                            total: usage.totalTokens ?? 0)))
        }

        return output
    }

    /// Emits whatever calls are buffered. Called on `finish_reason`, and again
    /// at end of stream for servers that close without sending one.
    mutating func flushToolCalls() -> [TurnChunk] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }

        return pending.keys.sorted().compactMap { index in
            guard let call = pending[index], !call.name.isEmpty else { return nil }
            // Truncated or absent arguments parse to nothing; an empty argument
            // map lets the tool report the real problem back to the model,
            // which is recoverable in a way a thrown error is not.
            let arguments = ChatValue.parse(call.arguments)?.objectValue ?? [:]
            return .toolCall(ToolCall(id: call.id ?? UUID().uuidString,
                                      name: call.name,
                                      arguments: arguments))
        }
    }
}
