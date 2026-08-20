//
//  ChatBackend.swift
//  SwiftChatKit
//
//  The model seam. Everything above this protocol is provider-agnostic; the
//  conformer owns SDK types, wire formats and streaming details.
//

import Foundation

// MARK: - History

/// Who authored a turn. Note that tool *results* are conventionally sent back
/// with the user role by most providers — that mapping is the backend's job,
/// not the caller's, so results carry `.model`'s counterpart here only as a part.
public enum TurnRole: String, Equatable, Sendable, Codable {
    case user
    case model
}

public enum TurnPart: Equatable, Sendable {
    case text(String)
    case inlineData(Data, mimeType: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
}

/// One entry of conversation history as the backend should replay it. Distinct
/// from `ChatMessage`, which is what the UI shows: several messages collapse
/// into one turn when a model emits parallel tool calls.
public struct ChatTurn: Equatable, Sendable {
    public let role: TurnRole
    public let parts: [TurnPart]

    public init(role: TurnRole, parts: [TurnPart]) {
        self.role = role
        self.parts = parts
    }

    public static func user(_ text: String, attachments: [Attachment] = []) -> ChatTurn {
        ChatTurn(role: .user,
                 parts: attachments.map { .inlineData($0.data, mimeType: $0.mimeType) } + [.text(text)])
    }

    public static func model(_ text: String) -> ChatTurn {
        ChatTurn(role: .model, parts: [.text(text)])
    }
}

// MARK: - Turn I/O

public struct TurnInput: Equatable, Sendable {
    public let parts: [TurnPart]

    public init(parts: [TurnPart]) { self.parts = parts }

    public static func message(_ text: String, attachments: [Attachment] = []) -> TurnInput {
        TurnInput(parts: attachments.map { .inlineData($0.data, mimeType: $0.mimeType) } + [.text(text)])
    }

    /// The follow-up turn that answers a batch of tool calls. Parallel calls are
    /// answered together — splitting them desynchronizes call/response pairing.
    public static func toolResults(_ results: [ToolResult]) -> TurnInput {
        TurnInput(parts: results.map { .toolResult($0) })
    }
}

public struct TokenUsage: Equatable, Sendable, Codable {
    public let prompt: Int
    public let completion: Int
    public let total: Int

    public init(prompt: Int, completion: Int, total: Int) {
        self.prompt = prompt
        self.completion = completion
        self.total = total
    }

    public static let zero = TokenUsage(prompt: 0, completion: 0, total: 0)

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(prompt: lhs.prompt + rhs.prompt,
                   completion: lhs.completion + rhs.completion,
                   total: lhs.total + rhs.total)
    }
}

/// One streamed increment. Backends must not emit reasoning/"thought" text as
/// `.text` — the transcript shows only what the user should read.
public enum TurnChunk: Equatable, Sendable {
    case text(String)
    case toolCall(ToolCall)
    case usage(TokenUsage)
    case finish(FinishReason)
}

// MARK: - Backend

public protocol ChatBackend: AnyObject, Sendable {

    /// Rebuilds the underlying model with a new instruction set, tool list and
    /// history. Called on init and whenever tools or context go stale, so it
    /// must be cheap enough to run between turns and must not lose history.
    func configure(systemInstruction: String,
                   tools: [ToolDeclaration],
                   history: [ChatTurn]) async

    /// Streams one turn. Appending the turn and its response to `history` is the
    /// backend's responsibility. Cancellation of the consuming task must stop
    /// the underlying request.
    func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error>

    /// Current history, used to persist and to reconfigure without loss.
    var history: [ChatTurn] { get async }

    /// Identifier of the model in use, for telemetry and the UI's model picker.
    var modelName: String { get async }
}
