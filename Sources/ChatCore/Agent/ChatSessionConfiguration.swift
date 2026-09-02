//
//  ChatSessionConfiguration.swift
//  SwiftChatKit
//
//  Everything a session needs, supplied once at init. The point of collecting
//  it here is that a host configures a chat in one place and then only ever
//  calls `send` / `stop` and reads `messages`.
//

import Foundation

public struct ChatSessionConfiguration: Sendable {

    // MARK: Model and tools

    /// The only required element. Everything else has a working default.
    public var backend: any ChatBackend

    /// Consulted in order; the first provider that claims a call runs it.
    public var toolProviders: [any ToolProvider]

    // MARK: Prompt

    public var persona: ChatPersona
    /// Instructions read from the working directory, appended last so they
    /// outrank the persona's defaults where they conflict.
    public var projectContext: String
    public var projectContextTitle: String
    /// Host-supplied prompt sections, e.g. a component catalog.
    public var additionalSections: [String]

    // MARK: Context

    /// Directory the conversation is scoped to. Tools resolve relative paths
    /// against it, and it is persisted with the transcript so reopening a
    /// session doesn't silently retarget the current folder.
    public var workingDirectory: URL?

    public var skills: SkillsConfiguration

    // MARK: Behavior

    /// Hard cap on tool round-trips in a single run. Reaching it appends a note
    /// and stops — a model in a loop should cost a bounded amount of money.
    public var maxTurns: Int

    /// Offers `todoWrite`. Off by default: a session ships no tools it wasn't
    /// asked for, and a chat with no multi-step work has no use for a checklist.
    public var enableTodos: Bool
    /// Offers `askUser`. Off by default, and requires the host to render
    /// `questions.pending` — a question nobody displays parks the run forever.
    public var enableQuestions: Bool

    /// Tools that never prompt for approval. Merged with every provider's
    /// `autoAllowedToolNames`.
    public var autoAllowedTools: Set<String>
    public var permissionStore: any PermissionStore

    // MARK: Optional seams

    public var historyStore: ChatHistoryStore?
    public var compressor: (any ContextCompressor)?
    public var telemetry: (any ChatTelemetry)?

    /// Called on every `save()`; whatever it returns lands in
    /// `StoredSession.metadata`. The seam for a host's own per-session record —
    /// a log of runs, a build status — that has to stay in step with the
    /// transcript it describes.
    public var sessionMetadata: (@MainActor @Sendable () -> [String: ChatValue])?
    /// Called on `load(_:)` with whatever was persisted, or an empty dictionary
    /// for a transcript saved before the host had any metadata to store.
    public var onSessionMetadataLoaded: (@MainActor @Sendable ([String: ChatValue]) -> Void)?

    /// Called on the main actor when a run ends, however it ended. The hook for
    /// a notification, a sound, or a dock badge — none of which belong in here.
    public var onRunFinished: (@MainActor @Sendable (ChatRunOutcome) -> Void)?

    public init(backend: any ChatBackend,
                toolProviders: [any ToolProvider] = [],
                persona: ChatPersona = .default,
                projectContext: String = "",
                projectContextTitle: String = "Project instructions",
                additionalSections: [String] = [],
                workingDirectory: URL? = nil,
                skills: SkillsConfiguration = .disabled,
                maxTurns: Int = 100,
                enableTodos: Bool = false,
                enableQuestions: Bool = false,
                autoAllowedTools: Set<String> = [],
                permissionStore: any PermissionStore = UserDefaultsPermissionStore(),
                historyStore: ChatHistoryStore? = nil,
                compressor: (any ContextCompressor)? = nil,
                telemetry: (any ChatTelemetry)? = nil,
                sessionMetadata: (@MainActor @Sendable () -> [String: ChatValue])? = nil,
                onSessionMetadataLoaded: (@MainActor @Sendable ([String: ChatValue]) -> Void)? = nil,
                onRunFinished: (@MainActor @Sendable (ChatRunOutcome) -> Void)? = nil) {
        self.backend = backend
        self.toolProviders = toolProviders
        self.persona = persona
        self.projectContext = projectContext
        self.projectContextTitle = projectContextTitle
        self.additionalSections = additionalSections
        self.workingDirectory = workingDirectory
        self.skills = skills
        self.maxTurns = maxTurns
        self.enableTodos = enableTodos
        self.enableQuestions = enableQuestions
        self.autoAllowedTools = autoAllowedTools
        self.permissionStore = permissionStore
        self.historyStore = historyStore
        self.compressor = compressor
        self.telemetry = telemetry
        self.sessionMetadata = sessionMetadata
        self.onSessionMetadataLoaded = onSessionMetadataLoaded
        self.onRunFinished = onRunFinished
    }
}

/// How a run ended. Passed to `onRunFinished` so a host can distinguish "your
/// answer is ready" from "that stopped because you cancelled it".
public enum ChatRunOutcome: Equatable, Sendable {
    case completed
    case stopped
    case turnLimitReached
    case failed(String)
}
