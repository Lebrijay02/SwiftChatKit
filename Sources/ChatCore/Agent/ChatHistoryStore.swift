//
//  ChatHistoryStore.swift
//  SwiftChatKit
//
//  Local transcript persistence: one JSON file per session. File-based rather
//  than UserDefaults-backed because transcripts get large — a long agentic run
//  with tool payloads is megabytes, not kilobytes.
//

import Foundation

// MARK: - Persisted models

/// Codable snapshot of one conversation, written after every completed turn.
///
/// Named `StoredSession` rather than `ChatSession` because the latter is the
/// live engine type — this is its serialized form, not the same thing.
public struct StoredSession: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [StoredMessage]
    public var usage: TokenUsage?
    /// Working directory the conversation was scoped to, so reopening a session
    /// restores its context rather than silently retargeting the current folder.
    public var workingDirectoryPath: String?
    public var workingDirectoryDisplayName: String?
    public var modelName: String?
    /// Host-owned data persisted alongside the transcript. The package never
    /// reads it — it exists so a host doesn't need a second file kept in sync
    /// with this one, which is one crash away from disagreeing with it.
    ///
    /// Populated from `ChatSessionConfiguration.sessionMetadata` on save and
    /// handed back through `onSessionMetadataLoaded` on load.
    public var metadata: [String: ChatValue]?

    public init(id: UUID = UUID(),
                title: String,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                messages: [StoredMessage] = [],
                usage: TokenUsage? = nil,
                workingDirectoryPath: String? = nil,
                workingDirectoryDisplayName: String? = nil,
                modelName: String? = nil,
                metadata: [String: ChatValue]? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.usage = usage
        self.workingDirectoryPath = workingDirectoryPath
        self.workingDirectoryDisplayName = workingDirectoryDisplayName
        self.modelName = modelName
        self.metadata = metadata
    }
}

/// Codable mirror of `ChatMessage`.
///
/// Attachment *payloads* are not persisted — inlining image and PDF bytes would
/// bloat every transcript by megabytes. Restored messages keep their text and a
/// record that attachments existed, but not the data.
public struct StoredMessage: Codable, Equatable, Sendable {

    public enum Role: String, Codable, Sendable {
        case user, assistant, toolCall, toolResult
    }

    public let role: Role
    public let content: String
    public let timestamp: Date
    public var completedAt: Date?
    public var status: MessageStatus?
    public var toolName: String?
    public var callID: String?
    /// Exact tool payloads, stored as structured JSON rather than an escaped
    /// string. Absent for messages saved before a session had them, in which
    /// case history replay skips that turn rather than fabricating one.
    public var rawArguments: [String: ChatValue]?
    public var rawResult: [String: ChatValue]?
    /// Filenames of dropped attachments, kept so the UI can show what was sent.
    public var attachmentNames: [String]?

    public init(from message: ChatMessage) {
        switch message.role {
        case .user:       role = .user
        case .assistant:  role = .assistant
        case .toolCall:   role = .toolCall
        case .toolResult: role = .toolResult
        }
        content = message.content
        timestamp = message.timestamp
        completedAt = message.completedAt
        status = message.status
        toolName = message.toolName
        callID = message.callID
        rawArguments = message.rawArguments
        rawResult = message.rawResult
        attachmentNames = message.attachments?.compactMap(\.filename)
    }

    public func toChatMessage() -> ChatMessage {
        let messageRole: MessageRole
        switch role {
        case .user:       messageRole = .user
        case .assistant:  messageRole = .assistant
        case .toolCall:   messageRole = .toolCall(toolName: toolName ?? "unknown")
        case .toolResult: messageRole = .toolResult(toolName: toolName ?? "unknown")
        }
        return ChatMessage(role: messageRole,
                           content: content,
                           timestamp: timestamp,
                           completedAt: completedAt,
                           isStreaming: false,
                           status: status,
                           callID: callID,
                           rawArguments: rawArguments,
                           rawResult: rawResult)
    }

    /// Whether this message carries a replayable tool payload. A `.toolCall`
    /// without `rawArguments` cannot be rebuilt into a real function-call part.
    public var isReplayable: Bool {
        switch role {
        case .toolCall:   return rawArguments != nil
        case .toolResult: return rawResult != nil
        case .user, .assistant: return true
        }
    }
}

// MARK: - Store

public struct ChatHistoryStore: Sendable {

    /// Directory holding one JSON file per session.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/<appFolder>/ChatSessions`.
    public static func applicationSupport(_ appFolder: String) -> ChatHistoryStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ChatHistoryStore(
            directory: base.appendingPathComponent("\(appFolder)/ChatSessions", isDirectory: true))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys keep saved transcripts diff-stable between writes.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// All saved sessions, newest first. Unreadable or corrupt files are skipped
    /// rather than failing the whole load — one bad transcript should not hide
    /// the rest of the user's history.
    public func loadAll() -> [StoredSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }

        let decoder = Self.decoder
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StoredSession.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(_ id: UUID) -> StoredSession? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(StoredSession.self, from: data)
    }

    /// Writes atomically, so an interrupted save cannot truncate an existing
    /// transcript.
    @discardableResult
    public func save(_ session: StoredSession) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(session)
            try data.write(to: fileURL(for: session.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    // MARK: - Titles

    /// First line of the first user message, trimmed to a sensible length.
    /// Falls back to a dated title when the conversation opened with an image.
    public static func derivedTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == .user }),
              let line = first.content
                  .components(separatedBy: .newlines)
                  .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return "New chat" }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
