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
    /// Directories beyond `workingDirectory` the session starts out able to
    /// reach. Kept in step by the session as `/add-dir` widens the scope.
    public var additionalDirectories: [URL]

    public var skills: SkillsConfiguration

    /// Leading-slash input the session answers itself. Empty by default: a host
    /// that never registers one gets a chat where `/` is an ordinary character.
    public var slashCommands: SlashCommandsConfiguration

    /// Limits that keep a long session inside the model's context window.
    /// `.unbounded` by default; see `ContextPolicy` for why a host has to state
    /// the window size itself.
    public var context: ContextPolicy

    // MARK: Behavior

    /// Hard cap on tool round-trips in a single run. Reaching it appends a note
    /// and stops — a model in a loop should cost a bounded amount of money.
    public var maxTurns: Int
    public var budget: AgentBudget
    public var modelRetryPolicy: RetryPolicy
    public var toolRetryPolicy: RetryPolicy
    public var fallbackBackend: (any ChatBackend)?
    public var maximumOutputRecoveries: Int
    public var maximumCompletionValidationAttempts: Int
    public var maximumConcurrentTools: Int
    public var inFlightInputPolicy: InFlightInputPolicy

    /// Offers `todoWrite`. Off by default: a session ships no tools it wasn't
    /// asked for, and a chat with no multi-step work has no use for a checklist.
    public var enableTodos: Bool
    /// Offers `askUser`. Off by default, and requires the host to render
    /// `questions.pending` — a question nobody displays parks the run forever.
    public var enableQuestions: Bool

    /// Tools withheld from the prompt until the model goes looking for them.
    ///
    /// Every declaration costs tokens on every single request, and a tool used
    /// once a week is paying that rent all week. Naming one here replaces its
    /// schema with a line in `toolSearch`'s index; the full schema is sent only
    /// after the model searches for it, and stays for the rest of the session.
    /// Empty by default, which offers no `toolSearch` at all.
    public var deferredToolNames: Set<String>

    /// Tools that never prompt for approval. Merged with every provider's
    /// `autoAllowedToolNames`.
    public var autoAllowedTools: Set<String>
    public var permissionStore: any PermissionStore

    // MARK: Optional seams

    public var historyStore: ChatHistoryStore?
    public var compressor: (any ContextCompressor)?
    public var telemetry: (any ChatTelemetry)?
    public var transitionTelemetry: (any AgentTransitionTelemetry)?
    public var tokenEstimator: any TokenEstimating
    public var toolHooks: [any ToolHook]
    public var completionValidators: [any CompletionValidator]

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
                additionalDirectories: [URL] = [],
                skills: SkillsConfiguration = .disabled,
                slashCommands: SlashCommandsConfiguration = .disabled,
                context: ContextPolicy = .unbounded,
                maxTurns: Int = 100,
                budget: AgentBudget? = nil,
                modelRetryPolicy: RetryPolicy = RetryPolicy(),
                toolRetryPolicy: RetryPolicy = RetryPolicy(maxAttempts: 2),
                fallbackBackend: (any ChatBackend)? = nil,
                maximumOutputRecoveries: Int = 3,
                maximumCompletionValidationAttempts: Int = 3,
                maximumConcurrentTools: Int = 8,
                inFlightInputPolicy: InFlightInputPolicy = .reject,
                enableTodos: Bool = false,
                enableQuestions: Bool = false,
                deferredToolNames: Set<String> = [],
                autoAllowedTools: Set<String> = [],
                permissionStore: any PermissionStore = UserDefaultsPermissionStore(),
                historyStore: ChatHistoryStore? = nil,
                compressor: (any ContextCompressor)? = nil,
                telemetry: (any ChatTelemetry)? = nil,
                transitionTelemetry: (any AgentTransitionTelemetry)? = nil,
                tokenEstimator: any TokenEstimating = CharacterTokenEstimator(),
                toolHooks: [any ToolHook] = [],
                completionValidators: [any CompletionValidator] = [],
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
        self.additionalDirectories = additionalDirectories
        self.skills = skills
        self.slashCommands = slashCommands
        self.context = context
        self.maxTurns = maxTurns
        self.budget = budget ?? AgentBudget(maxTurns: maxTurns)
        self.budget.maxTurns = maxTurns
        self.modelRetryPolicy = modelRetryPolicy
        self.toolRetryPolicy = toolRetryPolicy
        self.fallbackBackend = fallbackBackend
        self.maximumOutputRecoveries = max(0, maximumOutputRecoveries)
        self.maximumCompletionValidationAttempts = max(0, maximumCompletionValidationAttempts)
        self.maximumConcurrentTools = max(1, maximumConcurrentTools)
        self.inFlightInputPolicy = inFlightInputPolicy
        self.enableTodos = enableTodos
        self.enableQuestions = enableQuestions
        self.deferredToolNames = deferredToolNames
        self.autoAllowedTools = autoAllowedTools
        self.permissionStore = permissionStore
        self.historyStore = historyStore
        self.compressor = compressor
        self.telemetry = telemetry
        self.transitionTelemetry = transitionTelemetry
        self.tokenEstimator = tokenEstimator
        self.toolHooks = toolHooks
        self.completionValidators = completionValidators
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
    case budgetExceeded
    case failed(String)
}
