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

    /// Offers `todoWrite`. Turn off for a chat that has no multi-step work.
    public var enableTodos: Bool
    /// Offers `askUser`. Requires the host to render `questions.pending`.
    public var enableQuestions: Bool

    /// Tools that never prompt for approval. Merged with every provider's
    /// `autoAllowedToolNames`.
    public var autoAllowedTools: Set<String>
    public var permissionStore: any PermissionStore

    // MARK: Optional seams

    public var historyStore: ChatHistoryStore?
    public var compressor: (any ContextCompressor)?
    public var telemetry: (any ChatTelemetry)?

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
                enableTodos: Bool = true,
                enableQuestions: Bool = true,
                autoAllowedTools: Set<String> = [],
                permissionStore: any PermissionStore = UserDefaultsPermissionStore(),
                historyStore: ChatHistoryStore? = nil,
                compressor: (any ContextCompressor)? = nil,
                telemetry: (any ChatTelemetry)? = nil,
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
