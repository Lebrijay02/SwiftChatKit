//
//  ChatMessage.swift
//  SwiftChatKit
//
//  One entry in the visible transcript. Tool calls and tool results are
//  first-class messages rather than hidden protocol traffic, because the UI
//  renders them and because replaying them is how history is rebuilt.
//

import Foundation

public enum MessageRole: Equatable, Sendable {
    case user
    case assistant
    case toolCall(toolName: String)
    case toolResult

    public var toolName: String? {
        if case .toolCall(let name) = self { return name }
        return nil
    }
}

public enum MessageStatus: String, Equatable, Sendable, Codable {
    case queued
    case inProgress
    case completed
    case cancelled
    case incomplete
}

public struct ChatMessage: Identifiable, Equatable, Sendable {

    public let id: UUID
    public let role: MessageRole
    /// Display text. For a tool call or result this is a lossy, human-readable
    /// rendering — `rawArguments`/`rawResult` hold the payload that matters.
    public var content: String
    public let timestamp: Date
    /// When streaming finished; drives the elapsed-time label.
    public var completedAt: Date?
    public var isStreaming: Bool
    public var status: MessageStatus?

    /// Correlates a `.toolCall` with its `.toolResult`.
    public var callID: String?
    /// Exact JSON of the call's arguments (`.toolCall`) or the tool's response
    /// (`.toolResult`). Kept verbatim so a reloaded session can be replayed to
    /// the backend as real function call/response parts rather than prose.
    public var rawArguments: [String: ChatValue]?
    public var rawResult: [String: ChatValue]?

    public var attachments: [Attachment]?

    public init(id: UUID = UUID(),
                role: MessageRole,
                content: String = "",
                timestamp: Date = Date(),
                completedAt: Date? = nil,
                isStreaming: Bool = false,
                status: MessageStatus? = nil,
                callID: String? = nil,
                rawArguments: [String: ChatValue]? = nil,
                rawResult: [String: ChatValue]? = nil,
                attachments: [Attachment]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.completedAt = completedAt
        self.isStreaming = isStreaming
        self.status = status
        self.callID = callID
        self.rawArguments = rawArguments
        self.rawResult = rawResult
        self.attachments = attachments
    }

    public var toolName: String? { role.toolName }

    /// Seconds spent streaming, once the message is finished.
    public var duration: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(timestamp) }
    }
}

// MARK: - Factories

public extension ChatMessage {
    static func user(_ text: String, attachments: [Attachment]? = nil) -> ChatMessage {
        ChatMessage(role: .user, content: text, attachments: attachments)
    }

    static func assistant(_ text: String = "", isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: text, isStreaming: isStreaming,
                    status: isStreaming ? .inProgress : .completed)
    }

    static func toolCall(_ call: ToolCall) -> ChatMessage {
        ChatMessage(role: .toolCall(toolName: call.name),
                    content: ChatValue.object(call.arguments).jsonString(),
                    status: .inProgress,
                    callID: call.id,
                    rawArguments: call.arguments)
    }

    static func toolResult(_ result: ToolResult) -> ChatMessage {
        ChatMessage(role: .toolResult,
                    content: ChatValue.object(result.payload).jsonString(),
                    completedAt: Date(),
                    status: result.errorMessage == nil ? .completed : .incomplete,
                    callID: result.callID,
                    rawResult: result.payload)
    }
}
