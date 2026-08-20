//
//  Seams.swift
//  SwiftChatKit
//
//  The remaining host hooks: context compression, telemetry, and the file
//  system the built-in tools operate through. All optional — a session with
//  none of them configured is a fully working chat.
//

import Foundation

// MARK: - Compression

/// Shrinks oversized tool output before it reaches the model. Long `grep` and
/// `readFile` results otherwise dominate the context window within a few turns.
public protocol ContextCompressor: Sendable {

    /// Results longer than this are routed through `compress`.
    var threshold: Int { get }

    /// Returns a shortened stand-in for `text`. Implementations should embed a
    /// handle the model can pass to `retrieve` to get the full text back.
    /// Must fail open: on error, return `text` unchanged rather than throwing.
    func compress(_ text: String, toolName: String) async -> String

    /// Recovers previously compressed content.
    func retrieve(handle: String, query: String?) async throws -> String

    /// Tools the compressor exposes to the model — typically one retrieval tool.
    var declarations: [ToolDeclaration] { get }

    /// Instruction text explaining the compression contract, appended to the
    /// system prompt only while a compressor is active.
    var systemInstruction: String { get }
}

// MARK: - Telemetry

public struct TurnMetrics: Sendable {
    public let sessionID: UUID
    public let modelName: String
    public let userText: String
    public let assistantText: String
    public let toolsCalled: [String]
    public let usage: TokenUsage
    public let turnCount: Int
    public let duration: TimeInterval
    public let error: String?

    public init(sessionID: UUID,
                modelName: String,
                userText: String,
                assistantText: String,
                toolsCalled: [String],
                usage: TokenUsage,
                turnCount: Int,
                duration: TimeInterval,
                error: String? = nil) {
        self.sessionID = sessionID
        self.modelName = modelName
        self.userText = userText
        self.assistantText = assistantText
        self.toolsCalled = toolsCalled
        self.usage = usage
        self.turnCount = turnCount
        self.duration = duration
        self.error = error
    }
}

/// Fire-and-forget analytics hook. The session never waits on it and never
/// surfaces its failures — telemetry must not be able to break a chat.
public protocol ChatTelemetry: Sendable {
    func record(_ metrics: TurnMetrics) async
}

// MARK: - File system

/// The operations the built-in file tools need. Abstracted so a host can back
/// them with a sandboxed root, a virtual project, or a remote workspace instead
/// of the local disk.
public protocol FileSystemProviding: Sendable {

    func currentDirectory() async -> URL

    func readText(at path: String, offset: Int?, limit: Int?) async throws -> String
    func readData(at path: String) async throws -> (data: Data, mimeType: String)

    func write(_ contents: String, to path: String) async throws
    /// Replaces `find` with `replace`. Throws when `find` is absent or, unless
    /// `replaceAll`, when it appears more than once — an ambiguous edit is a bug,
    /// not something to guess at.
    func edit(path: String, find: String, replace: String, replaceAll: Bool) async throws -> String

    func createDirectory(at path: String) async throws
    func list(at path: String, withSizes: Bool) async throws -> String
    func move(from: String, to: String) async throws
    func info(at path: String) async throws -> [String: ChatValue]

    func glob(pattern: String, in path: String?) async throws -> [String]
    func grep(pattern: String, in path: String?, filePattern: String?) async throws -> String
}
