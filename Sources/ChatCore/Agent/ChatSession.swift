//
//  ChatSession.swift
//  SwiftChatKit
//
//  The engine. One object a host configures once and then drives with `send`,
//  `stop`, and reading `messages`.
//
//  It runs the agentic loop: stream a turn, execute whatever tools the model
//  called, feed the results back, repeat until the model answers without
//  calling anything or the turn cap is reached. Permission gating, plan mode,
//  the todo checklist and structured questions all live inside that loop
//  because they can all suspend it mid-run.
//

import Foundation

@MainActor
@Observable
public final class ChatSession {

    // MARK: - Observable state

    /// The visible transcript, including tool calls and their results.
    ///
    /// Settable within the module so tests can seed a conversation directly;
    /// read-only to a host, which changes it by sending.
    public internal(set) var messages: [ChatMessage] = []

    /// True from `send` until the run ends, including while a permission card
    /// or question is parked waiting on the user.
    public private(set) var isStreaming = false

    /// True while the model is working and there is nothing yet to look at: the
    /// request is out but no text has arrived, or tools are running between
    /// turns. Goes false on the first token of a turn, because streaming text is
    /// its own indicator.
    ///
    /// It is also false while a permission card or a question is parked — the
    /// run is waiting on the *user* then, and telling them the model is thinking
    /// while it waits for their answer is a lie that reads as a hang.
    public var isThinking: Bool {
        modelIsWorking && permissions.pending == nil && questions.pending == nil
    }

    /// Backs `isThinking`. Separate because the parked case is derived from the
    /// sub-services rather than from the loop's own progress.
    private var modelIsWorking = false

    /// Last run's failure, if any. Cleared at the start of each run.
    public private(set) var error: String?

    public private(set) var todos: [TodoItem] = []

    /// Cumulative token usage for this session, and for the last turn alone.
    public private(set) var usage: TokenUsage = .zero
    public private(set) var lastTurnUsage: TokenUsage = .zero

    /// While true, tools that mutate state are refused before they run.
    public private(set) var planMode = false

    public private(set) var sessionID = UUID()
    public private(set) var title = "New chat"

    /// Where this conversation may reach on disk. Read-only: the root is chosen
    /// through `setWorkingDirectory` while the transcript is empty and fixed
    /// afterwards, and directories are added through `addDirectory`.
    public private(set) var directories = DirectoryScope()

    /// Base for relative paths, shell commands, and the skills scan.
    public var workingDirectory: URL? { directories.root }

    /// True once the conversation has started, after which the root is fixed.
    ///
    /// The transcript is the test rather than a flag, so it survives save and
    /// reload for free: a restored conversation has messages, and is therefore
    /// still locked.
    public var workingDirectoryIsLocked: Bool { !messages.isEmpty }

    // MARK: - Sub-services

    /// Non-nil `pending` on either of these means the loop is parked waiting on
    /// the host to render a card and resolve it.
    public let permissions: PermissionService
    public let questions: QuestionService
    public let skills: SkillsService

    // MARK: - Private

    private var configuration: ChatSessionConfiguration
    private var runTask: Task<Void, Never>?
    private let agentRunner = AgentRunner()
    private var queuedInputs: [(text: String, attachments: [Attachment]?)] = []
    /// Identity of the configuration the backend was last built with. Rebuilding
    /// re-uploads the system prompt and tool list, so it happens only on change.
    private var configuredFingerprint: String?

    /// Deferred tools the model has found with `toolSearch` and may now call.
    /// Grows over a session and never shrinks: a tool it needed once it will
    /// plausibly need again, and re-hiding it would cost a second search.
    private var loadedDeferredTools: Set<String> = []
    /// Set by a `toolSearch` call, cleared once the model has been rebuilt with
    /// what it found. See `reconfigureMidRun`.
    private var deferredToolsChanged = false
    private let createdAt = Date()

    /// The backend displaced by `fallbackBackend`, held so the run can hand the
    /// session back to it. Nil whenever the primary is the one running.
    private var displacedPrimaryBackend: (any ChatBackend)?

    /// The in-flight fan-out of a scope change to the tool providers.
    ///
    /// Awaited before a run starts. Providers are actors, so telling them is
    /// asynchronous, and a host that set the directory and immediately sent a
    /// message would otherwise race the first tool call against a provider that
    /// still holds the old root.
    private var directoryPropagation: Task<Void, Never>?

    /// Turns replayed ahead of the transcript. Compaction puts the summary here
    /// rather than in `messages`, so the model keeps the thread while the user
    /// sees one tidy note instead of the conversation it replaced.
    private var historyPrefix: [ChatTurn] = []

    /// First message index replayed to the backend. Non-zero only under
    /// `ContextPolicy.Overflow.slidingWindow`, where the transcript stays whole
    /// on screen and only its tail is sent.
    private var replayStart = 0

    // MARK: - Init

    public init(configuration: ChatSessionConfiguration) {
        self.configuration = configuration
        self.directories = DirectoryScope(root: configuration.workingDirectory,
                                          additional: configuration.additionalDirectories)

        // Agent bookkeeping tools never prompt: they act on the session's own
        // state, and a confirmation dialog for "update the checklist" is noise.
        var autoAllowed = configuration.autoAllowedTools
        autoAllowed.formUnion([AgentTools.todoWrite, AgentTools.askUser, SkillsService.toolName])
        for provider in configuration.toolProviders {
            autoAllowed.formUnion(provider.autoAllowedToolNames)
        }

        permissions = PermissionService(autoAllowed: autoAllowed,
                                        store: configuration.permissionStore)
        questions = QuestionService()
        skills = SkillsService(configuration: configuration.skills)
        skills.refresh(workingDirectory: configuration.workingDirectory)
        notifyProvidersOfDirectoryScope()
    }

    // MARK: - Directories

    /// Points the conversation at `url`. Refused, and returns false, once the
    /// transcript has anything in it.
    ///
    /// Async because it does not return until every provider has the new root:
    /// the alternative is a host that sets a directory, sends a message, and
    /// watches the first tool read the previous project.
    @discardableResult
    public func setWorkingDirectory(_ url: URL?) async -> Bool {
        guard !workingDirectoryIsLocked else { return false }
        guard url?.standardizedFileURL != directories.root else { return true }
        directories.setRoot(url)
        skills.refresh(workingDirectory: directories.root)
        configuration.workingDirectory = directories.root
        configuration.additionalDirectories = directories.additional
        notifyProvidersOfDirectoryScope()
        await directoryPropagation?.value
        return true
    }

    /// Widens the conversation's reach. Allowed at any point, including
    /// mid-conversation: adding a directory cannot change what a path already in
    /// the transcript resolves to.
    ///
    /// Returns false only when the directory was already reachable.
    @discardableResult
    public func addDirectory(_ url: URL) async -> Bool {
        guard directories.add(url) else { return false }
        configuration.additionalDirectories = directories.additional
        // The model is told which directories it has, so the prompt it was built
        // with no longer describes reality.
        configuredFingerprint = nil
        notifyProvidersOfDirectoryScope()
        await directoryPropagation?.value
        return true
    }

    private func notifyProvidersOfDirectoryScope() {
        let scope = directories
        let providers = configuration.toolProviders
        let previous = directoryPropagation
        directoryPropagation = Task {
            // Serialized behind the previous fan-out so two rapid changes cannot
            // land on a provider out of order.
            await previous?.value
            for provider in providers {
                await provider.directoryScopeChanged(to: scope)
            }
        }
    }

    // MARK: - Sending

    /// Starts a run, or answers a slash command without involving the model.
    ///
    /// Ignored while a run is in flight — a second concurrent run would
    /// interleave two conversations into one history. Commands are the
    /// exception: `/clear` and `/compact` exist partly to interrupt.
    public func send(_ text: String, attachments: [Attachment]? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(attachments ?? []).isEmpty else { return }

        if configuration.slashCommands.isEnabled,
           let parsed = SlashCommandParser.parse(trimmed) {
            dispatch(name: parsed.name, arguments: parsed.arguments, rawInput: trimmed)
            return
        }

        guard !isStreaming else {
            switch configuration.inFlightInputPolicy {
            case .reject:
                return
            case .queue:
                messages.append(.user(text, attachments: attachments))
                queuedInputs.append((text, attachments))
                save()
                return
            case .interrupt:
                messages.append(.user(text, attachments: attachments))
                queuedInputs.insert((text, attachments), at: 0)
                save()
                stop()
                return
            }
        }
        messages.append(.user(text, attachments: attachments))
        if title == "New chat" {
            title = ChatHistoryStore.derivedTitle(from: messages)
        }
        save()
        startRun(userText: text, attachments: attachments)
    }

    /// Cancels the run. Anything parked on a permission card or question is
    /// resolved as declined so the loop can unwind rather than leak a
    /// continuation.
    public func stop() {
        runTask?.cancel()
        permissions.cancelPending()
        questions.cancelPending()
    }

    /// Drops the last assistant response and re-runs the preceding user message.
    public func regenerate() {
        guard !isStreaming,
              let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return }

        let message = messages[userIndex]
        messages.removeSubrange((userIndex + 1)...)
        configuredFingerprint = nil          // force a rebuild from the truncated history
        startRun(userText: message.content, attachments: message.attachments)
    }

    private func startRun(userText: String, attachments: [Attachment]?) {
        runTask = Task { [weak self] in
            await self?.run(userText: userText, attachments: attachments)
        }
    }

    // MARK: - Slash commands

    /// Every command currently available, built-ins and host-registered alike,
    /// with skills last. Exposed for autocomplete — a host shouldn't have to
    /// keep its own copy of this list in step with the configuration.
    public var availableCommands: [SlashCommand] {
        let configured = configuration.slashCommands
        var commands = configured.custom
        let taken = Set(commands.map { $0.name.lowercased() })

        for builtIn in SlashCommandsConfiguration.BuiltIn.allCases
        where configured.builtIns.contains(builtIn) && !taken.contains(builtIn.rawValue) {
            commands.append(SlashCommand(name: builtIn.rawValue,
                                         summary: builtIn.summary) { _ in .none })
        }

        if configured.skillsAsCommands {
            for skill in skills.skills where !taken.contains(skill.name.lowercased()) {
                commands.append(SlashCommand(name: skill.name, summary: skill.description) { _ in .none })
            }
        }
        return commands
    }

    private func dispatch(name: String, arguments: String, rawInput: String) {
        let configured = configuration.slashCommands
        let key = name.lowercased()
        let context = SlashCommandContext(arguments: arguments,
                                          rawInput: rawInput,
                                          workingDirectory: workingDirectory,
                                          directories: directories.all,
                                          planMode: planMode)

        // Host commands first, so registering a name replaces the built-in
        // rather than requiring it to be disabled separately.
        if let custom = configured.custom.first(where: { $0.name.lowercased() == key }) {
            perform(custom.handler(context), rawInput: rawInput)
            return
        }

        if let builtIn = SlashCommandsConfiguration.BuiltIn(rawValue: key),
           configured.builtIns.contains(builtIn) {
            perform(action(for: builtIn, context: context), rawInput: rawInput)
            return
        }

        if configured.skillsAsCommands {
            // Rescan first: a skill added since launch should be callable
            // without restarting the app.
            skills.refresh(workingDirectory: workingDirectory)
            if let skill = skills.skill(named: name) {
                perform(skillAction(skill, arguments: arguments), rawInput: rawInput)
                return
            }
        }

        let known = availableCommands.map { "`/\($0.name)`" }
        messages.append(.note(known.isEmpty
            ? "Unknown command `/\(name)`."
            : "Unknown command `/\(name)`. Available: \(known.joined(separator: ", "))"))
    }

    private func action(for builtIn: SlashCommandsConfiguration.BuiltIn,
                        context: SlashCommandContext) -> SlashCommandAction {
        switch builtIn {
        case .clear:   return .clear
        case .compact: return .compact
        case .newChat: return .newChat
        case .plan:    return .togglePlanMode
        case .addDirectory:
            guard !context.arguments.isEmpty else {
                return .note("Usage: `/add-dir <path>` — for example `/add-dir ../SharedKit`.")
            }
            return .addDirectory(context.arguments)
        case .help:
            let lines = availableCommands
                .map { "- `/\($0.name)` — \($0.summary)" }
                .joined(separator: "\n")
            return .note(lines.isEmpty ? "No commands are available." : "**Commands**\n\n\(lines)")
        }
    }

    /// Turns `/skill-name args` into a run carrying the skill's instructions.
    /// The body is loaded eagerly here — unlike the `useSkill` tool, the user
    /// has already committed to running this one, so there is nothing to defer.
    private func skillAction(_ skill: AgentSkill, arguments: String) -> SlashCommandAction {
        let body: String
        do {
            body = try skills.skillBody(skill)
        } catch {
            return .note("Couldn't read skill `\(skill.name)`: \(error.localizedDescription)")
        }

        var prompt = """
        The user invoked the skill "/\(skill.name)". Follow these skill instructions to complete \
        the request. The skill's support files live at \(skill.directory.path) — read any file it \
        references relative to that directory.

        --- SKILL INSTRUCTIONS ---
        \(body)
        --- END SKILL INSTRUCTIONS ---
        """
        if !arguments.isEmpty {
            prompt += "\n\nThe user's arguments to the skill: \(arguments)"
        }
        return .prompt(prompt)
    }

    private func perform(_ action: SlashCommandAction, rawInput: String) {
        switch action {
        case .none:
            break

        case .note(let text):
            messages.append(.note(text))

        case .prompt(let text):
            guard !isStreaming else { return }
            // The transcript shows what was typed; the model gets the expansion.
            // Showing a skill's whole body back to the user helps nobody.
            messages.append(.user(rawInput))
            if title == "New chat" {
                title = ChatHistoryStore.derivedTitle(from: messages)
            }
            startRun(userText: text, attachments: nil)

        case .clear:
            clearConversation()

        case .newChat:
            stop()
            save()
            newChat()

        case .compact:
            stop()
            runTask = Task { [weak self] in await self?.compact() }

        case .setPlanMode(let enabled):
            setPlanMode(enabled)
            messages.append(.note(planModeNote))

        case .togglePlanMode:
            setPlanMode(!planMode)
            messages.append(.note(planModeNote))

        case .addDirectory(let path):
            Task { [weak self] in await self?.performAddDirectory(path) }
        }
    }

    /// Resolves, checks, and adds a `/add-dir` argument.
    ///
    /// Every outcome ends in a note rather than an `error`: the user typed this
    /// themselves and is waiting to hear what happened, and a failed directory
    /// add is not a failed run.
    private func performAddDirectory(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : (workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .appendingPathComponent(expanded)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path,
                                             isDirectory: &isDirectory) else {
            messages.append(.note("No such directory: `\(url.standardizedFileURL.path)`"))
            return
        }
        guard isDirectory.boolValue else {
            messages.append(.note("`\(url.standardizedFileURL.path)` is a file, not a directory."))
            return
        }

        guard await addDirectory(url) else {
            messages.append(.note("Already available: `\(url.standardizedFileURL.path)`"))
            return
        }
        messages.append(.note("Added `\(url.standardizedFileURL.path)` to this conversation."))
        save()
    }

    private var planModeNote: String {
        planMode
            ? "**Plan mode on.** Research and a proposed plan first — nothing will be changed."
            : "**Plan mode off.**"
    }

    /// Clears the conversation and deletes its saved transcript. Distinct from
    /// `newChat`, which keeps what was there.
    public func clearConversation() {
        stop()
        configuration.historyStore?.delete(sessionID)
        newChat()
    }

    // MARK: - Compaction

    /// Replaces the transcript with a summary of itself and reseeds the backend
    /// from it, freeing context without losing the thread.
    ///
    /// The summary is seeded as a user/model exchange rather than left as a
    /// local note: a conversation whose entire history is one model turn is one
    /// most providers reject, and the model needs to have "heard" the recap for
    /// it to carry weight.
    public func compact() async {
        guard !messages.isEmpty else { return }
        isStreaming = true
        modelIsWorking = true
        error = nil
        defer {
            isStreaming = false
            modelIsWorking = false
        }

        let transcript = await compactionTranscript()
        guard !transcript.isEmpty else { return }

        do {
            let summary = try await configuration.backend.generate("""
            Summarize the following assistant conversation so it can continue in a fresh session. \
            Preserve the user's goals, what has been done so far, files created or modified, key \
            decisions and constraints, and the immediate next steps. Be dense and factual, and use \
            Markdown.

            \(transcript)
            """)

            let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.error = "Compaction produced an empty summary; the conversation is unchanged."
                return
            }

            historyPrefix = [
                .user("This conversation was compacted. Here is everything so far:\n\n\(text)"),
                .model("Understood — I'll continue from that context."),
            ]
            messages = [.note("**Conversation compacted.**\n\n\(text)")]
            replayStart = 0
            todos = []
            lastTurnUsage = .zero
            configuredFingerprint = nil
            save()
        } catch {
            self.error = "Compaction failed: \(error.localizedDescription)"
        }
    }

    /// Advances the replay window past the oldest turns.
    ///
    /// Nothing is removed from `messages`: the user keeps the whole
    /// conversation, and only what the backend is shown shrinks. The window
    /// starts at a user message so the tail reads as a conversation rather than
    /// as a reply to something the model can no longer see.
    private func slideWindow() {
        let retained = max(1, Int(Double(messages.count) * configuration.context.retainedFraction))
        var start = messages.count - retained
        guard start > replayStart else { return }
        while start < messages.count, messages[start].role != .user { start += 1 }
        guard start < messages.count else { return }

        replayStart = start
        lastTurnUsage = .zero
        configuredFingerprint = nil
    }

    /// The transcript as the summarizer should read it. Tool *results* are left
    /// out deliberately — they are the bulk of what compaction exists to shed,
    /// and the calls alone record what was done.
    private func compactionTranscript() async -> String {
        var out = ""
        for message in messages {
            switch message.role {
            case .user:
                out += "User: \(message.content)\n\n"
            case .assistant:
                let prefix = message.isLocalNote ? "Note" : "Assistant"
                out += "\(prefix): \(message.content)\n\n"
            case .toolCall(let name):
                out += "Tool call: \(name)\n"
            case .toolResult(let name):
                guard let provider = await provider(for: name) else { continue }
                switch await provider.resultRetention(for: ToolCall(id: message.callID ?? UUID().uuidString,
                                                                     name: name)) {
                case .discard:
                    continue
                case .summarize:
                    let status = message.rawResult?["error"] == nil ? "succeeded" : "failed"
                    out += "Tool result: \(name) \(status)\n"
                case .retain:
                    if let payload = message.rawResult {
                        out += "Tool result: \(name) \(ChatValue.object(payload).jsonString())\n"
                    }
                case .retainFields(let fields):
                    if let payload = message.rawResult {
                        let retained = payload.filter { fields.contains($0.key) }
                        out += "Tool result: \(name) \(ChatValue.object(retained).jsonString())\n"
                    }
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session lifecycle

    public func newChat() {
        stop()
        messages = []
        todos = []
        error = nil
        usage = .zero
        lastTurnUsage = .zero
        sessionID = UUID()
        title = "New chat"
        configuredFingerprint = nil
        // The root carries over as the obvious default for the next
        // conversation — and an empty transcript means it is editable again.
        // The additions do not: they were widened for the work that just ended.
        if !directories.additional.isEmpty {
            directories = DirectoryScope(root: directories.root)
            configuration.additionalDirectories = []
            notifyProvidersOfDirectoryScope()
        }
        historyPrefix = []
        replayStart = 0
    }

    /// Restores a persisted transcript. Turns that were saved without their raw
    /// payloads are shown but not replayed to the model.
    public func load(_ stored: StoredSession) {
        stop()
        sessionID = stored.id
        title = stored.title
        messages = stored.messages.map { $0.toChatMessage() }
        usage = stored.usage ?? .zero
        lastTurnUsage = .zero
        todos = []
        error = nil
        // A loaded transcript brings its own history; anything a previous
        // compaction seeded belongs to the session being replaced.
        historyPrefix = []
        replayStart = 0
        // Assigned directly rather than through `setWorkingDirectory`, which
        // refuses once a transcript exists — and the transcript was just loaded.
        // A restored conversation comes back locked to the directories it was
        // working in, which is the point of persisting them.
        let restored = DirectoryScope(
            root: stored.workingDirectoryPath.map { URL(fileURLWithPath: $0) } ?? directories.root,
            additional: (stored.additionalDirectoryPaths ?? []).map { URL(fileURLWithPath: $0) })
        if restored != directories {
            directories = restored
            skills.refresh(workingDirectory: directories.root)
            configuration.workingDirectory = directories.root
            configuration.additionalDirectories = directories.additional
            configuredFingerprint = nil
            notifyProvidersOfDirectoryScope()
        }
        // Always called, even for a transcript that predates the host having
        // any metadata: the host has to clear the last session's state either
        // way, and only hearing about sessions that carry data wouldn't let it.
        configuration.onSessionMetadataLoaded?(stored.metadata ?? [:])
        configuredFingerprint = nil
    }

    /// The session as it would be persisted. Exposed so a host that wants to
    /// write the transcript through its own store, or add fields this type
    /// doesn't have, can do so without reimplementing the mapping.
    public func snapshot() -> StoredSession {
        StoredSession(
            id: sessionID,
            title: title,
            createdAt: createdAt,
            updatedAt: Date(),
            messages: messages.map(StoredMessage.init),
            usage: usage,
            workingDirectoryPath: workingDirectory?.path,
            workingDirectoryDisplayName: workingDirectory?.lastPathComponent,
            additionalDirectoryPaths: directories.additional.map(\.path),
            modelName: nil,
            metadata: configuration.sessionMetadata?())
    }

    @discardableResult
    public func save() -> Bool {
        guard let store = configuration.historyStore, !messages.isEmpty else { return false }
        return store.save(snapshot())
    }

    /// Plan mode offers `exitPlanMode` and refuses mutating tools outright, so
    /// the model researches and proposes instead of acting.
    public func setPlanMode(_ enabled: Bool) {
        guard planMode != enabled else { return }
        planMode = enabled
        configuredFingerprint = nil
    }

    // MARK: - Host edits to the transcript

    /// Drops `index` and everything after it, so the host can re-run an edited
    /// message. The model is marked stale because the history it was configured
    /// with no longer matches what is on screen.
    public func truncate(from index: Int) {
        guard !isStreaming, messages.indices.contains(index) else { return }
        messages.removeSubrange(index...)
        replayStart = min(replayStart, messages.count)
        configuredFingerprint = nil
    }

    /// Shows `text` to the user without telling the model — the same treatment
    /// slash-command feedback gets. For host-side notices like "directory
    /// added" that would otherwise read as something the assistant said.
    public func appendNote(_ text: String) {
        messages.append(.note(text))
    }

    /// Surfaces a host-side failure in the same place the session shows its own.
    public func reportError(_ message: String) {
        error = message
    }

    /// Adds or removes a tool provider on a live session.
    ///
    /// Providers whose tools should appear only in a mode — research, say — are
    /// added and removed rather than left in place and filtered: a model that
    /// can see a tool will eventually call it.
    public func setToolProvider(_ provider: any ToolProvider, enabled: Bool) {
        let existing = configuration.toolProviders.firstIndex { $0 === provider }
        if enabled {
            guard existing == nil else { return }
            configuration.toolProviders.append(provider)
            permissions.addAutoAllowed(provider.autoAllowedToolNames)
            let scope = directories
            Task { await provider.directoryScopeChanged(to: scope) }
        } else if let existing {
            configuration.toolProviders.remove(at: existing)
        } else {
            return
        }
        configuredFingerprint = nil
    }

    /// Registers a host command after init, for one that needs to call back
    /// into the object that owns the session.
    public func registerCommand(_ command: SlashCommand) {
        configuration.slashCommands.custom.removeAll { $0.name == command.name }
        configuration.slashCommands.custom.append(command)
    }

    // MARK: - Reconfiguration

    /// Swaps the model this session talks to, keeping the transcript.
    ///
    /// The next run replays the existing history into the new backend, so a
    /// mid-conversation model change continues the thread rather than starting
    /// over. Refused while streaming: the in-flight turn belongs to the backend
    /// that started it.
    @discardableResult
    public func setBackend(_ backend: any ChatBackend) -> Bool {
        guard !isStreaming else { return false }
        configuration.backend = backend
        configuredFingerprint = nil
        return true
    }

    /// Replaces the context pruning and compaction policy.
    public func setContextPolicy(_ policy: ContextPolicy) {
        configuration.context = policy
    }

    /// Identifier of the model currently in use.
    public var modelName: String {
        get async { await configuration.backend.modelName }
    }

    /// Replaces the host-supplied prompt sections. Marks the model stale, so
    /// the new sections reach it on the next run rather than the one after.
    public func setAdditionalSections(_ sections: [String]) {
        guard sections != configuration.additionalSections else { return }
        configuration.additionalSections = sections
        configuredFingerprint = nil
    }

    /// Replaces the instructions read from the working directory.
    public func setProjectContext(_ text: String, title: String? = nil) {
        guard text != configuration.projectContext || title != nil else { return }
        configuration.projectContext = text
        if let title { configuration.projectContextTitle = title }
        configuredFingerprint = nil
    }

    /// Forces a rebuild of the system prompt and tool list before the next turn.
    /// Needed when something the session cannot observe changes — an MCP server
    /// finishing its handshake, say.
    public func invalidateModel() {
        configuredFingerprint = nil
    }

    // MARK: - Model configuration

    private var promptContext: SystemPromptContext {
        SystemPromptContext(
            persona: configuration.persona,
            planMode: planMode,
            skillsText: skills.skillsText(),
            compressorInstruction: configuration.compressor?.systemInstruction ?? "",
            projectContext: configuration.projectContext,
            projectContextTitle: configuration.projectContextTitle,
            additionalSections: configuration.additionalSections,
            directories: directories.all.map(\.path))
    }

    /// Everything the model is built from. Tools that appear and disappear —
    /// an MCP server connecting mid-conversation — move this, which is why
    /// providers report a `declarationsVersion`.
    private func currentTools() async -> [ToolDeclaration] {
        let all = await allDeclarations()
        guard !configuration.deferredToolNames.isEmpty else { return all }

        let hidden = all.filter { isHidden($0.name) }
        var visible = all.filter { !isHidden($0.name) }
        // No point offering a search once everything has been found.
        if !hidden.isEmpty { visible.append(AgentTools.toolSearchDeclaration) }
        return visible
    }

    /// Every tool that exists, before deferral hides any of them.
    private func allDeclarations() async -> [ToolDeclaration] {
        var tools: [ToolDeclaration] = []
        for provider in configuration.toolProviders {
            tools += await provider.declarations
        }
        if configuration.enableTodos { tools.append(AgentTools.todoWriteDeclaration) }
        if configuration.enableQuestions { tools.append(AgentTools.askUserDeclaration) }
        if planMode { tools.append(AgentTools.exitPlanModeDeclaration) }
        if !skills.skills.isEmpty { tools.append(SkillsService.declaration) }
        tools += configuration.compressor?.declarations ?? []
        return tools
    }

    /// Deferred and not yet found.
    private func isHidden(_ name: String) -> Bool {
        configuration.deferredToolNames.contains(name) && !loadedDeferredTools.contains(name)
    }

    private func reconfigureIfNeeded() async {
        let tools = await currentTools()
        var versions = ""
        for provider in configuration.toolProviders {
            versions += "\(await provider.declarationsVersion),"
        }
        let fingerprint = [
            SystemPromptBuilder.fingerprint(promptContext),
            tools.map(\.name).joined(separator: ","),
            versions,
            loadedDeferredTools.sorted().joined(separator: ","),
        ].joined(separator: "|")

        guard fingerprint != configuredFingerprint else { return }
        await configuration.backend.configure(
            systemInstruction: SystemPromptBuilder.build(promptContext),
            tools: tools,
            history: replayableTurns())
        configuredFingerprint = fingerprint
    }

    // MARK: - The loop

    private func run(userText: String, attachments: [Attachment]?) async {
        isStreaming = true
        modelIsWorking = true
        error = nil
        let started = ContinuousClock.now
        let startedDate = Date()
        let runID = UUID()

        var state = AgentRunState(input: .message(userText, attachments: attachments ?? []))
        var outcome = ChatRunOutcome.completed
        var completionValidationAttempts = 0

        // A directory set moments ago may still be in flight to the providers.
        await directoryPropagation?.value
        await reconfigureIfNeeded()

        agentLoop: while state.turn < configuration.budget.maxTurns {
            if Task.isCancelled {
                outcome = .stopped
                await recordTransition(runID: runID, state: state, termination: .stopped)
                break
            }
            if configuration.budget.isExceeded(by: state.usage) {
                outcome = .budgetExceeded
                await recordTransition(runID: runID, state: state, termination: .tokenBudget)
                break
            }
            if let maximumDuration = configuration.budget.maximumDuration,
               started.duration(to: .now) >= maximumDuration {
                outcome = .budgetExceeded
                await recordTransition(runID: runID, state: state, termination: .durationBudget)
                break
            }

            modelIsWorking = true
            let assistantID = openAssistantMessage()
            await Task.yield()
            let observation: TurnObservation

            do {
                observation = try await streamTurnWithRetry(state.input,
                                                            assistantID: assistantID,
                                                            runID: runID,
                                                            state: state)
            } catch {
                let failure = BackendFailure.classify(error)
                if case .contextOverflow = failure, !state.contextRecoveryAttempted {
                    finishAssistantMessage(assistantID, note: nil)
                    state.contextRecoveryAttempted = true
                    state.continuation = .contextRecovery
                    await recordTransition(runID: runID, state: state, reason: .contextRecovery)
                    if await compactForRecovery() { continue }
                }

                let message = failure.localizedDescription
                if failure == .cancelled || Task.isCancelled {
                    outcome = .stopped
                    finishAssistantMessage(assistantID, note: nil)
                    await recordTransition(runID: runID, state: state, termination: .stopped)
                } else {
                    self.error = message
                    outcome = .failed(message)
                    finishAssistantMessage(assistantID, note: "Error: \(message)")
                    await recordTransition(runID: runID, state: state,
                                           termination: .backendFailure(message))
                }
                break
            }

            if let value = observation.usage {
                usage = usage + value
                state.usage = state.usage + value
                lastTurnUsage = value
            }

            let abnormalNote = observation.finish?.userFacingNote
            let recoverOutput = observation.calls.isEmpty
                && observation.finish == .maxTokens
                && state.outputRecoveryCount < configuration.maximumOutputRecoveries

            finishAssistantMessage(assistantID, note: recoverOutput ? nil : abnormalNote)

            if Task.isCancelled {
                outcome = .stopped
                await recordTransition(runID: runID, state: state, termination: .stopped)
                break
            }

            if recoverOutput {
                state.outputRecoveryCount += 1
                state.input = .message("""
                Continue directly from where the response was cut off. Do not apologize or recap. \
                Complete the remaining work in smaller sections.
                """)
                state.continuation = .outputLimitRecovery(attempt: state.outputRecoveryCount)
                await recordTransition(runID: runID, state: state,
                                       reason: state.continuation)
                continue
            }

            if let abnormalNote, observation.calls.isEmpty {
                error = abnormalNote
                outcome = .failed(abnormalNote)
                await recordTransition(runID: runID, state: state,
                                       termination: .backendFailure(abnormalNote))
                break
            }

            if observation.calls.isEmpty {
                let decision = await validateCompletion(state)
                switch decision {
                case .accept:
                    await recordTransition(runID: runID, state: state, termination: .completed)
                    break agentLoop
                case .continueWithFeedback(let feedback)
                    where completionValidationAttempts < configuration.maximumCompletionValidationAttempts:
                    completionValidationAttempts += 1
                    state.input = .message(feedback)
                    state.continuation = .completionFeedback
                    await recordTransition(runID: runID, state: state, reason: .completionFeedback)
                    continue
                case .continueWithFeedback(let feedback), .reject(let feedback):
                    error = feedback
                    outcome = .failed(feedback)
                    await recordTransition(runID: runID, state: state,
                                           termination: .completionRejected(feedback))
                    break agentLoop
                }
            }

            state.toolsCalled += observation.calls.map(\.name)
            modelIsWorking = true
            let execution = await execute(observation.calls,
                                          turn: state.turn,
                                          prestarted: observation.prestartedTools)
            if execution.stopReason != nil {
                let reason = execution.stopReason ?? "A tool hook stopped the run."
                error = reason
                outcome = .failed(reason)
                await recordTransition(runID: runID, state: state,
                                       termination: .completionRejected(reason))
                break
            }

            if Task.isCancelled {
                outcome = .stopped
                await recordTransition(runID: runID, state: state, termination: .stopped)
                break
            }

            state.input = .toolResults(execution.results)
            state.turn += 1
            state.outputRecoveryCount = 0
            state.contextRecoveryAttempted = false
            state.continuation = .toolResults
            await recordTransition(runID: runID, state: state,
                                   reason: .toolResults,
                                   toolCallIDs: observation.calls.map(\.id))

            if deferredToolsChanged {
                deferredToolsChanged = false
                await reconfigureMidRun()
            }
        }

        if state.turn >= configuration.budget.maxTurns {
            outcome = .turnLimitReached
            appendTurnLimitNote()
            await recordTransition(runID: runID, state: state, termination: .turnLimit)
        }

        isStreaming = false
        modelIsWorking = false
        finalizeStreamingMessages()
        restorePrimaryBackend()
        if outcome != .completed { configuredFingerprint = nil }
        save()

        await recordTelemetry(userText: userText,
                              toolsCalled: state.toolsCalled,
                              usage: state.usage,
                              turns: state.turn,
                              started: startedDate)

        if outcome == .completed,
           configuration.context.shouldCompact(afterPromptTokens: lastTurnUsage.prompt) {
            switch configuration.context.overflow {
            case .compact:       await compact()
            case .slidingWindow: await slideWindowToBudget()
            }
        }

        configuration.onRunFinished?(outcome)
        startNextQueuedInputIfNeeded()
    }

    private struct TurnObservation {
        var calls: [ToolCall] = []
        var finish: FinishReason?
        var usage: TokenUsage?
        var prestartedTools: [String: Task<ToolResult, Never>] = [:]
    }

    private func streamTurnWithRetry(_ input: TurnInput,
                                     assistantID: UUID,
                                     runID: UUID,
                                     state: AgentRunState) async throws -> TurnObservation {
        let originalText = messages.first(where: { $0.id == assistantID })?.content ?? ""
        var lastFailure: BackendFailure = .permanent("The model request failed.")

        for attempt in 1...configuration.modelRetryPolicy.maxAttempts {
            if Task.isCancelled { throw BackendFailure.cancelled }
            resetAssistantMessage(assistantID, to: originalText)
            var observation = TurnObservation()

            do {
                try await collectTurn(from: configuration.backend,
                                      input: input,
                                      assistantID: assistantID,
                                      into: &observation)
                return observation
            } catch {
                observation.prestartedTools.values.forEach { $0.cancel() }
                lastFailure = BackendFailure.classify(error)
                guard lastFailure.isRetryable,
                      attempt < configuration.modelRetryPolicy.maxAttempts else { break }
                configuredFingerprint = nil
                await reconfigureIfNeeded()
                await recordTransition(runID: runID,
                                       state: state,
                                       reason: .modelRetry(attempt: attempt))
                try await Task.sleep(for: configuration.modelRetryPolicy.delay(forAttempt: attempt))
            }
        }

        if let fallback = configuration.fallbackBackend, lastFailure.isRetryable {
            switchToFallback(fallback, announcingAbove: assistantID)
            await reconfigureIfNeeded()
            resetAssistantMessage(assistantID, to: originalText)
            await recordTransition(runID: runID, state: state, reason: .modelFallback)
            var observation = TurnObservation()
            do {
                try await collectTurn(from: fallback,
                                      input: input,
                                      assistantID: assistantID,
                                      into: &observation)
                return observation
            } catch {
                observation.prestartedTools.values.forEach { $0.cancel() }
                throw error
            }
        }

        throw lastFailure
    }

    /// Drains one backend stream into `observation`, appending text to the open
    /// assistant message and opening streaming tools as their calls arrive.
    ///
    /// Reports through `inout` rather than a return value so a throwing stream
    /// still leaves the caller holding whatever tools were prestarted before the
    /// failure — they have to be cancelled, and a return would lose them. The
    /// local copy exists because the chunk closure cannot capture an `inout`.
    private func collectTurn(from backend: any ChatBackend,
                             input: TurnInput,
                             assistantID: UUID,
                             into observation: inout TurnObservation) async throws {
        // A `before` hook can deny or rewrite a call, so nothing may start early
        // while hooks are installed. Once one call has been passed over the rest
        // must wait too, to keep tools running in the order the model asked for.
        var earlyStartOpen = configuration.toolHooks.isEmpty
        var collected = observation
        defer { observation = collected }

        let snapshot = try await agentRunner.collect(
            from: backend,
            input: input,
            onChunk: { [weak self] chunk in
                guard let self else { return }
                switch chunk {
                case .text(let delta):
                    self.modelIsWorking = false
                    self.appendText(delta, to: assistantID)
                case .toolCall(let call):
                    guard earlyStartOpen,
                          let task = await self.startStreamingToolIfSafe(call) else {
                        earlyStartOpen = false
                        break
                    }
                    collected.prestartedTools[call.id] = task
                case .usage, .finish:
                    break
                }
            })
        collected.calls = snapshot.calls
        collected.usage = snapshot.usage
        collected.finish = snapshot.finish
        guard collected.finish != nil else { throw BackendFailure.incompleteStream }
    }

    /// Hands the rest of this run to `fallback`, remembering the primary so
    /// `restorePrimaryBackend()` can put it back when the run ends.
    ///
    /// The note goes *above* the assistant message being retried, so it reads as
    /// a header for the answer it explains rather than as a remark trailing it.
    private func switchToFallback(_ fallback: any ChatBackend, announcingAbove assistantID: UUID) {
        if displacedPrimaryBackend == nil {
            displacedPrimaryBackend = configuration.backend
            let note = ChatMessage.note("Switched to the fallback model for this response.")
            if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages.insert(note, at: index)
            } else {
                messages.append(note)
            }
        }
        configuration.backend = fallback
        configuredFingerprint = nil
    }

    /// Returns the session to its primary backend once the run is over.
    ///
    /// The fallback covers a blip, not the rest of the session: without this one
    /// retryable failure silently downgrades every later turn. The primary's own
    /// history stopped at the failure, so the fingerprint is cleared and the next
    /// run reconfigures it from the transcript, which is authoritative.
    private func restorePrimaryBackend() {
        guard let primary = displacedPrimaryBackend else { return }
        configuration.backend = primary
        displacedPrimaryBackend = nil
        configuredFingerprint = nil
    }

    private func validateCompletion(_ state: AgentRunState) async -> CompletionDecision {
        let context = CompletionContext(messages: messages,
                                        usage: state.usage,
                                        toolsCalled: state.toolsCalled,
                                        turn: state.turn)
        for validator in configuration.completionValidators {
            let decision = await validator.validate(context)
            if decision != .accept { return decision }
        }
        return .accept
    }

    private func recordTransition(runID: UUID,
                                  state: AgentRunState,
                                  reason: AgentContinuationReason? = nil,
                                  termination: AgentTerminationReason? = nil,
                                  toolCallIDs: [String] = []) async {
        guard let telemetry = configuration.transitionTelemetry else { return }
        await telemetry.record(AgentTransitionEvent(runID: runID,
                                                    iteration: state.turn,
                                                    reason: reason,
                                                    termination: termination,
                                                    toolCallIDs: toolCallIDs))
    }

    private func compactForRecovery() async -> Bool {
        let transcript = await compactionTranscript()
        guard !transcript.isEmpty else { return false }
        do {
            let summary = try await configuration.backend.generate("""
            Summarize this conversation for continuation. Preserve goals, completed work, changed \
            files, important tool outcomes, constraints, and immediate next steps. Be dense and factual.

            \(transcript)
            """).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return false }
            historyPrefix = [
                .user("This conversation was compacted. Here is everything so far:\n\n\(summary)"),
                .model("Understood — I'll continue from that context."),
            ]
            messages.append(.note("**Context recovered by compaction.**"))
            replayStart = messages.count
            configuredFingerprint = nil
            await reconfigureIfNeeded()
            return true
        } catch {
            return false
        }
    }

    private func slideWindowToBudget() async {
        guard let window = configuration.context.contextWindow else {
            slideWindow()
            return
        }
        let budget = Int(Double(window) * configuration.context.compactionThreshold)
        let retained = max(1, Int(Double(messages.count) * configuration.context.retainedFraction))
        var start = max(min(replayStart, messages.count), messages.count - retained)
        while start < messages.count, messages[start].role != .user { start += 1 }
        while start < messages.count {
            replayStart = start
            let estimate = await configuration.tokenEstimator.estimate(replayableTurns())
            if estimate <= budget { break }
            start += 1
            while start < messages.count, messages[start].role != .user { start += 1 }
        }
        configuredFingerprint = nil
    }

    private func startNextQueuedInputIfNeeded() {
        guard !queuedInputs.isEmpty else { return }
        let next = queuedInputs.removeFirst()
        startRun(userText: next.text, attachments: next.attachments)
    }

    // MARK: - Tool execution

    private func startStreamingToolIfSafe(_ call: ToolCall) async -> Task<ToolResult, Never>? {
        guard enabledAgentToolNames.contains(call.name) == false,
              call.name != SkillsService.toolName,
              permissions.requiresApproval(call.name) == false,
              let provider = await provider(for: call.name),
              await provider.mutatingToolNames.contains(call.name) == false,
              await provider.executionMode(for: call) == .concurrent,
              let declaration = await provider.declarations.first(where: { $0.name == call.name })
        else { return nil }

        guard case .success = ToolInputValidator.validate(call.arguments, against: declaration) else {
            return nil
        }
        let policy = configuration.toolRetryPolicy
        return Task {
            await Self.executeWithRetry(call, on: provider, policy: policy)
        }
    }

    private struct ToolExecutionOutcome {
        var results: [ToolResult]
        var stopReason: String?
    }

    private struct DispatchedTool: Sendable {
        let index: Int
        let call: ToolCall
        let provider: any ToolProvider
        let mode: ToolExecutionMode
    }

    private func execute(_ calls: [ToolCall],
                         turn: Int,
                         prestarted: [String: Task<ToolResult, Never>] = [:]) async -> ToolExecutionOutcome {
        let messageIDs = calls.map { call -> UUID in
            let message = ChatMessage.toolCall(call)
            messages.append(message)
            return message.id
        }

        var results = [ToolResult?](repeating: nil, count: calls.count)
        var dispatched: [DispatchedTool] = []
        var stopReason: String?

        for (index, originalCall) in calls.enumerated() {
            if Task.isCancelled {
                results[index] = .failure(originalCall, AgentRefusal.cancelled, kind: .cancelled)
                cancel(messageIDs[index])
                continue
            }

            if enabledAgentToolNames.contains(originalCall.name) {
                results[index] = await runAgentTool(originalCall)
                continue
            }

            if originalCall.name == SkillsService.toolName {
                results[index] = skills.execute(originalCall)
                continue
            }

            if let handle = originalCall.arguments["handle"]?.stringValue,
               let compressor = configuration.compressor,
               compressor.declarations.contains(where: { $0.name == originalCall.name }) {
                results[index] = await retrieve(originalCall, handle: handle, using: compressor)
                continue
            }

            guard let provider = await provider(for: originalCall.name) else {
                results[index] = .failure(originalCall, AgentRefusal.unhandled(originalCall.name),
                                          kind: .invalidInput)
                cancel(messageIDs[index])
                continue
            }

            guard let declaration = await provider.declarations.first(where: { $0.name == originalCall.name }) else {
                results[index] = .failure(originalCall, AgentRefusal.unhandled(originalCall.name),
                                          kind: .invalidInput)
                cancel(messageIDs[index])
                continue
            }

            switch ToolInputValidator.validate(originalCall.arguments, against: declaration) {
            case .success:
                break
            case .failure(let validationError):
                results[index] = .failure(originalCall,
                                          "InputValidationError: \(validationError.localizedDescription)",
                                          kind: .invalidInput)
                cancel(messageIDs[index])
                continue
            }

            var call = originalCall
            for hook in configuration.toolHooks {
                switch await hook.before(ToolInvocation(call: call, turn: turn)) {
                case .proceed:
                    continue
                case .proceedWithArguments(let arguments):
                    call = ToolCall(id: call.id, name: call.name, arguments: arguments)
                case .deny(let message):
                    results[index] = .failure(call, message, kind: .permissionDenied)
                    cancel(messageIDs[index])
                case .stopRun(let message):
                    results[index] = .failure(call, message, kind: .permanent)
                    cancel(messageIDs[index])
                    stopReason = message
                }
                if results[index] != nil { break }
            }
            if results[index] != nil { continue }

            if planMode, await provider.mutatingToolNames.contains(call.name) {
                results[index] = .failure(call, AgentRefusal.planModeBlocked, kind: .permissionDenied)
                cancel(messageIDs[index])
                continue
            }

            if permissions.requiresApproval(call.name) {
                let card = await provider.approvalCard(for: call) ?? .generic(for: call)
                let decision = await permissions.request(card)
                if decision == .deny || Task.isCancelled {
                    results[index] = .failure(call,
                                              Task.isCancelled ? AgentRefusal.cancelled : AgentRefusal.denied,
                                              kind: Task.isCancelled ? .cancelled : .permissionDenied)
                    cancel(messageIDs[index])
                    continue
                }
            }

            dispatched.append(DispatchedTool(index: index,
                                             call: call,
                                             provider: provider,
                                             mode: await provider.executionMode(for: call)))
        }

        for item in dispatched where prestarted[item.call.id] != nil {
            results[item.index] = await prestarted[item.call.id]?.value
        }
        let pending = dispatched.filter { prestarted[$0.call.id] == nil }

        for batch in toolBatches(pending) {
            if batch.first?.mode == .exclusive {
                for item in batch {
                    results[item.index] = await executeExternal(item, turn: turn)
                }
            } else {
                for chunk in batch.chunked(into: configuration.maximumConcurrentTools) {
                    await withTaskGroup(of: (Int, ToolResult).self) { group in
                        for item in chunk {
                            group.addTask { [toolRetryPolicy = configuration.toolRetryPolicy,
                                             hooks = configuration.toolHooks] in
                                let result = await Self.executeWithRetry(item.call,
                                                                         on: item.provider,
                                                                         policy: toolRetryPolicy)
                                var transformed = result
                                for hook in hooks {
                                    transformed = await hook.after(
                                        ToolInvocation(call: item.call, turn: turn),
                                        result: transformed)
                                }
                                return (item.index, transformed)
                            }
                        }
                        for await (index, result) in group { results[index] = result }
                    }
                }
            }
        }

        var final = zip(calls, results).map { call, result in
            result ?? .failure(call, AgentRefusal.cancelled, kind: .cancelled)
        }

        if let compressor = configuration.compressor {
            final = await compress(final, using: compressor)
        }
        final = final.map(configuration.context.truncating)

        for (index, result) in final.enumerated() {
            complete(messageIDs[index], failed: result.errorMessage != nil)
            messages.append(.toolResult(result))
        }
        save()
        return ToolExecutionOutcome(results: final, stopReason: stopReason)
    }

    private func toolBatches(_ tools: [DispatchedTool]) -> [[DispatchedTool]] {
        var batches: [[DispatchedTool]] = []
        for tool in tools {
            if tool.mode == .concurrent, batches.last?.first?.mode == .concurrent {
                batches[batches.count - 1].append(tool)
            } else {
                batches.append([tool])
            }
        }
        return batches
    }

    private func executeExternal(_ item: DispatchedTool, turn: Int) async -> ToolResult {
        var result = await Self.executeWithRetry(item.call,
                                                 on: item.provider,
                                                 policy: configuration.toolRetryPolicy)
        for hook in configuration.toolHooks {
            result = await hook.after(ToolInvocation(call: item.call, turn: turn), result: result)
        }
        return result
    }

    private func provider(for name: String) async -> (any ToolProvider)? {
        for provider in configuration.toolProviders where await provider.handles(name) {
            return provider
        }
        return nil
    }

    private static func executeWithRetry(_ call: ToolCall,
                                         on provider: any ToolProvider,
                                         policy: RetryPolicy) async -> ToolResult {
        let safety = await provider.retrySafety(for: call)
        let timeout = await provider.timeout(for: call)
        var last = ToolResult.failure(call, "Tool execution failed.", kind: .permanent)

        for attempt in 1...policy.maxAttempts {
            if Task.isCancelled {
                return .failure(call, AgentRefusal.cancelled, kind: .cancelled)
            }
            last = await execute(call, on: provider, timeout: timeout)
            guard last.failureKind == .transient || last.failureKind == .rateLimited else {
                return last
            }
            guard attempt < policy.maxAttempts else { return last }
            switch safety {
            case .never:
                return last
            case .idempotent, .idempotencyKey:
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
        return last
    }

    private static func execute(_ call: ToolCall,
                                on provider: any ToolProvider,
                                timeout: Duration?) async -> ToolResult {
        guard let timeout else { return await provider.execute(call) }
        return await withTaskGroup(of: ToolResult.self, returning: ToolResult.self) { group in
            group.addTask { await provider.execute(call) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(call, "Tool execution timed out.", kind: .timedOut)
            }
            let first = await group.next() ?? .failure(call, "Tool execution failed.", kind: .permanent)
            group.cancelAll()
            return first
        }
    }

    // MARK: - Session-owned tools

    /// Only the session tools currently offered. A disabled one falls through to
    /// the providers and then to `unhandled`, so a model that invented the name
    /// can't reach state the host switched off.
    private var enabledAgentToolNames: Set<String> {
        var names: Set<String> = []
        if configuration.enableTodos { names.insert(AgentTools.todoWrite) }
        if configuration.enableQuestions { names.insert(AgentTools.askUser) }
        if planMode { names.insert(AgentTools.exitPlanMode) }
        if !configuration.deferredToolNames.isEmpty { names.insert(AgentTools.toolSearch) }
        return names
    }

    private func runAgentTool(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case AgentTools.todoWrite:
            guard let items = [TodoItem].parse(call.arguments) else {
                return .failure(call, "Missing or malformed 'todos' array.")
            }
            todos = items
            return .success(call, ["ok": .bool(true), "count": .number(Double(items.count))])

        case AgentTools.askUser:
            guard let asked = QuestionService.parse(call.arguments) else {
                return .failure(call, "Missing or malformed 'questions' array.")
            }
            guard let answers = await questions.request(asked) else {
                return .failure(call, """
                The user dismissed the questions without answering. Continue with reasonable \
                defaults, or ask in prose.
                """)
            }
            return .success(call, ["answers": .object(answers.mapValues(ChatValue.string))])

        case AgentTools.toolSearch:
            return await runToolSearch(call)

        case AgentTools.exitPlanMode:
            let plan = call.arguments["plan"]?.stringValue ?? ""
            let decision = await permissions.request(PermissionRequest(
                kind: .plan,
                toolName: AgentTools.exitPlanMode,
                title: "Approve this plan?",
                detail: plan))
            guard decision != .deny, !Task.isCancelled else {
                return .success(call, [
                    "approved": .bool(false),
                    "note": .string("""
                    The user did not approve the plan. Stay in plan mode and revise it based on \
                    their feedback — do not start making changes.
                    """),
                ])
            }
            planMode = false
            configuredFingerprint = nil
            return .success(call, [
                "approved": .bool(true),
                "note": .string("Plan approved and plan mode is off. Start executing the plan."),
            ])

        default:
            return .failure(call, AgentRefusal.unhandled(call.name))
        }
    }

    /// Finds withheld tools matching the model's query and makes them callable.
    ///
    /// The result carries only a signature per match. The real schemas arrive
    /// with the next request, once `reconfigureMidRun` has rebuilt the model —
    /// sending them here as well would pay for them twice.
    private func runToolSearch(_ call: ToolCall) async -> ToolResult {
        let query = call.arguments["query"]?.stringValue ?? ""
        let hidden = await allDeclarations().filter { isHidden($0.name) }

        guard !hidden.isEmpty else {
            return .success(call, ["note": .string("""
            Every available tool is already listed in your prompt — there is nothing further to \
            load. Don't search again; if you can't find a tool for this, say so instead.
            """)])
        }

        let matches = DeferredToolIndex.search(query, in: hidden)
        guard !matches.isEmpty else {
            return .success(call, [
                "found": .number(0),
                "note": .string("""
                No hidden tool matches that. The available ones are: \
                \(hidden.map(\.name).sorted().joined(separator: ", ")). If none of them fit, this \
                capability doesn't exist — tell the user rather than searching again.
                """),
            ])
        }

        loadedDeferredTools.formUnion(matches.map(\.name))
        deferredToolsChanged = true

        return .success(call, [
            "found": .number(Double(matches.count)),
            "tools": .string(matches.map(DeferredToolIndex.summary).joined(separator: "\n\n")),
            "note": .string("""
            These are now loaded and callable from your next step onwards, with their full \
            parameter schemas. Continue with the task — don't call toolSearch again for them.
            """),
        ])
    }

    /// Rebuilds the model in the middle of a run, so a tool the model just found
    /// is callable on the very next step rather than in the next conversation.
    ///
    /// History comes from the backend rather than `replayableTurns()`. The model
    /// has already committed a turn whose tool calls are about to be answered,
    /// and only the backend still holds it — rebuilding from the transcript
    /// would drop that turn and the pending results would answer nothing.
    private func reconfigureMidRun() async {
        let tools = await currentTools()
        let history = await configuration.backend.history
        await configuration.backend.configure(
            systemInstruction: SystemPromptBuilder.build(promptContext),
            tools: tools,
            history: history)
        // The fingerprint no longer describes what the backend holds, and the
        // history it was rebuilt from isn't the transcript's. Force the next run
        // to configure itself from scratch.
        configuredFingerprint = nil
    }

    private func retrieve(_ call: ToolCall,
                          handle: String,
                          using compressor: any ContextCompressor) async -> ToolResult {
        do {
            let text = try await compressor.retrieve(handle: handle,
                                                     query: call.arguments["query"]?.stringValue)
            return .success(call, ["result": .string(text)])
        } catch {
            return .failure(call, error.localizedDescription)
        }
    }

    /// Routes oversized string values through the compressor. Only strings, and
    /// only over the threshold — compressing a short structured result costs
    /// more than it saves.
    private func compress(_ results: [ToolResult],
                          using compressor: any ContextCompressor) async -> [ToolResult] {
        var output: [ToolResult] = []
        for result in results {
            var payload = result.payload
            var changed = false
            for (key, value) in payload {
                guard let text = value.stringValue, text.count > compressor.threshold else { continue }
                let compressed = await compressor.compress(text, toolName: result.name)
                if compressed != text {
                    payload[key] = .string(compressed)
                    changed = true
                }
            }
            output.append(changed
                ? ToolResult(callID: result.callID, name: result.name, payload: payload)
                : result)
        }
        return output
    }

    // MARK: - Transcript maintenance

    private func openAssistantMessage() -> UUID {
        let message = ChatMessage.assistant(isStreaming: true)
        messages.append(message)
        return message.id
    }

    private func appendText(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta
    }

    private func resetAssistantMessage(_ id: UUID, to text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = text
    }

    /// Closes a streaming bubble. A turn that produced only tool calls leaves an
    /// empty bubble, which is removed rather than rendered as a blank reply.
    private func finishAssistantMessage(_ id: UUID, note: String?) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isStreaming = false
        messages[index].completedAt = Date()
        messages[index].status = .completed

        if let note {
            messages[index].content += messages[index].content.isEmpty ? note : "\n\n_\(note)_"
        } else if messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.remove(at: index)
        }
    }

    private func appendTurnLimitNote() {
        let note = "Reached the \(configuration.maxTurns)-turn tool limit; stopping."
        if let index = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[index].content += messages[index].content.isEmpty ? note : "\n\n_\(note)_"
        } else {
            messages.append(.assistant(note))
        }
        error = note
    }

    /// Safety net for a cancelled run: nothing should stay visibly streaming
    /// once `isStreaming` is false.
    private func finalizeStreamingMessages() {
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].completedAt = Date()
            messages[index].status = .cancelled
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].status = .cancelled
        messages[index].completedAt = Date()
    }

    private func complete(_ id: UUID, failed: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // A call refused before it ran is already marked cancelled; overwriting
        // that with "incomplete" would lose why it never happened.
        guard messages[index].status != .cancelled else { return }
        messages[index].status = failed ? .incomplete : .completed
        messages[index].completedAt = Date()
    }

    // MARK: - History replay

    /// Rebuilds backend history from the transcript.
    ///
    /// Tool turns are replayed as real call/response parts so the model sees
    /// what it actually did, not its prose about it. Consecutive calls (and
    /// their results) coalesce into one turn, mirroring how the loop emits them:
    /// parallel calls are a single model turn, their results a single user turn.
    func replayableTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = historyPrefix
        var pendingCalls: [ToolCall] = []
        var pendingResults: [ToolResult] = []

        func flush() {
            if !pendingCalls.isEmpty {
                // Every call has to be answered. A run stopped mid-tool leaves
                // calls with no result, and replaying an unanswered call makes
                // that send — and every send after it — invalid.
                let answered = Set(pendingResults.map(\.callID))
                for call in pendingCalls where !answered.contains(call.id) {
                    pendingResults.append(.failure(call, AgentRefusal.cancelled))
                }
                turns.append(ChatTurn(role: .model, parts: pendingCalls.map(TurnPart.toolCall)))
                pendingCalls = []
            }
            if !pendingResults.isEmpty {
                turns.append(ChatTurn(role: .user, parts: pendingResults.map(TurnPart.toolResult)))
                pendingResults = []
            }
        }

        for message in messages.dropFirst(min(replayStart, messages.count)) {
            // Local notes were never the model's words, and replaying them as
            // such makes it defend statements the host wrote.
            if message.isLocalNote { continue }

            switch message.role {
            case .user:
                flush()
                turns.append(.user(message.content))
            case .assistant:
                flush()
                if !message.content.isEmpty { turns.append(.model(message.content)) }
            case .toolCall(let name):
                // A call after results belongs to the next turn.
                if !pendingResults.isEmpty { flush() }
                guard let arguments = message.rawArguments else { continue }
                pendingCalls.append(ToolCall(id: message.callID ?? UUID().uuidString,
                                             name: name,
                                             arguments: arguments))
            case .toolResult(let name):
                guard let payload = message.rawResult,
                      let callID = message.callID,
                      // A result whose call was dropped above is as invalid as
                      // an unanswered call, just from the other side.
                      pendingCalls.contains(where: { $0.id == callID })
                else { continue }
                pendingResults.append(ToolResult(callID: callID, name: name, payload: payload))
            }
        }
        flush()

        return turns
    }

    // MARK: - Telemetry

    private func recordTelemetry(userText: String,
                                 toolsCalled: [String],
                                 usage: TokenUsage,
                                 turns: Int,
                                 started: Date) async {
        guard let telemetry = configuration.telemetry else { return }
        let assistantText = messages
            .filter { $0.role == .assistant }
            .map(\.content)
            .joined(separator: "\n")

        await telemetry.record(TurnMetrics(
            sessionID: sessionID,
            modelName: await configuration.backend.modelName,
            userText: userText,
            assistantText: assistantText,
            toolsCalled: toolsCalled,
            usage: usage,
            turnCount: turns,
            duration: Date().timeIntervalSince(started),
            error: error))
    }
}
