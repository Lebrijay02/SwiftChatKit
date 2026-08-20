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

/// One find-and-replace within a file. A list of these is applied in order, so
/// a later edit sees the result of an earlier one.
public struct FileEdit: Equatable, Sendable {
    public let oldText: String
    public let newText: String

    public init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }
}

/// What a content search should return. Paths alone are usually enough and are
/// far cheaper in context than the matching lines.
public enum GrepOutputMode: String, Equatable, Sendable {
    case filesWithMatches = "files_with_matches"
    case content
    case count

    public init(rawValue: String) {
        switch rawValue {
        case "content": self = .content
        case "count": self = .count
        default: self = .filesWithMatches
        }
    }
}

/// The operations the built-in file tools need. Abstracted so a host can back
/// them with a sandboxed root, a virtual project, or a remote workspace instead
/// of the local disk.
///
/// Paths are relative to `currentDirectory()` unless absolute. The tools never
/// pass a base directory — a model repeating a stale one back is a whole class
/// of error that not having the parameter removes.
public protocol FileSystemProviding: Sendable {

    func currentDirectory() async -> URL
    /// Called when the session's working directory changes.
    func setCurrentDirectory(_ url: URL) async

    /// Numbered lines, `cat -n` style. `offset` is 0-indexed.
    func readText(at path: String, offset: Int?, limit: Int?) async throws -> String
    func readData(at path: String) async throws -> (data: Data, mimeType: String)

    func write(_ contents: String, to path: String) async throws
    /// Applies `edits` in order and returns a diff of what changed. Throws when
    /// any `oldText` is absent — an edit that silently matched nothing is a bug,
    /// not something to report as success. `dryRun` returns the diff unwritten.
    func edit(path: String, edits: [FileEdit], dryRun: Bool) async throws -> String

    func createDirectory(at path: String) async throws
    func list(at path: String, withSizes: Bool, sortBySize: Bool) async throws -> String
    func move(from: String, to: String) async throws
    func info(at path: String) async throws -> [String: ChatValue]

    func glob(pattern: String, in path: String?) async throws -> [String]
    func grep(pattern: String,
              in path: String?,
              filePattern: String?,
              caseInsensitive: Bool,
              outputMode: GrepOutputMode) async throws -> [String: ChatValue]
}
