//
//  AgentRunner.swift
//  SwiftChatKit
//

import Foundation

public struct AgentTurnSnapshot: Sendable {
    public var calls: [ToolCall]
    public var finish: FinishReason?
    public var usage: TokenUsage?

    public init(calls: [ToolCall] = [],
                finish: FinishReason? = nil,
                usage: TokenUsage? = nil) {
        self.calls = calls
        self.finish = finish
        self.usage = usage
    }
}

/// Consumes backend streams away from the UI actor. The host callback is invoked
/// on the main actor only for chunks that need immediate presentation or
/// streaming-tool coordination.
public actor AgentRunner {
    public init() {}

    public func collect(from backend: any ChatBackend,
                        input: TurnInput,
                        onChunk: @MainActor @escaping @Sendable (TurnChunk) async -> Void)
        async throws -> AgentTurnSnapshot {
        var snapshot = AgentTurnSnapshot()
        for try await chunk in backend.stream(input) {
            try Task.checkCancellation()
            switch chunk {
            case .toolCall(let call): snapshot.calls.append(call)
            case .usage(let usage): snapshot.usage = usage
            case .finish(let finish): snapshot.finish = finish
            case .text: break
            }
            await onChunk(chunk)
        }
        return snapshot
    }
}
