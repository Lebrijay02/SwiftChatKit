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

    /// Scope for tool path resolution and skill discovery. Setting it rescans
    /// project-local skills and marks the model stale.
    public var workingDirectory: URL? {
        didSet {
            guard workingDirectory != oldValue else { return }
            skills.refresh(workingDirectory: workingDirectory)
            configuration.workingDirectory = workingDirectory
            notifyProvidersOfWorkingDirectory()
        }
    }

    // MARK: - Sub-services

    /// Non-nil `pending` on either of these means the loop is parked waiting on
    /// the host to render a card and resolve it.
    public let permissions: PermissionService
    public let questions: QuestionService
    public let skills: SkillsService

    // MARK: - Private

    private var configuration: ChatSessionConfiguration
    private var runTask: Task<Void, Never>?
    /// Identity of the configuration the backend was last built with. Rebuilding
    /// re-uploads the system prompt and tool list, so it happens only on change.
    private var configuredFingerprint: String?
    private let createdAt = Date()

    /// Turns replayed ahead of the transcript. Compaction puts the summary here
    /// rather than in `messages`, so the model keeps the thread while the user
    /// sees one tidy note instead of the conversation it replaced.
    private var historyPrefix: [ChatTurn] = []

    // MARK: - Init

    public init(configuration: ChatSessionConfiguration) {
        self.configuration = configuration
        self.workingDirectory = configuration.workingDirectory

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
        notifyProvidersOfWorkingDirectory()
    }

    private func notifyProvidersOfWorkingDirectory() {
        let url = workingDirectory
        let providers = configuration.toolProviders
        Task {
            for provider in providers {
                await provider.workingDirectoryChanged(to: url)
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

        guard !isStreaming else { return }
        messages.append(.user(text, attachments: attachments))
        if title == "New chat" {
            title = ChatHistoryStore.derivedTitle(from: messages)
        }
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
        }
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

        let transcript = compactionTranscript()
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
            todos = []
            lastTurnUsage = .zero
            configuredFingerprint = nil
            save()
        } catch {
            self.error = "Compaction failed: \(error.localizedDescription)"
        }
    }

    /// The transcript as the summarizer should read it. Tool *results* are left
    /// out deliberately — they are the bulk of what compaction exists to shed,
    /// and the calls alone record what was done.
    private func compactionTranscript() -> String {
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
            case .toolResult:
                continue
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
        historyPrefix = []
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
        if let path = stored.workingDirectoryPath {
            workingDirectory = URL(fileURLWithPath: path)
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

    // MARK: - Model configuration

    private var promptContext: SystemPromptContext {
        SystemPromptContext(
            persona: configuration.persona,
            planMode: planMode,
            skillsText: skills.skillsText(),
            compressorInstruction: configuration.compressor?.systemInstruction ?? "",
            projectContext: configuration.projectContext,
            projectContextTitle: configuration.projectContextTitle,
            additionalSections: configuration.additionalSections)
    }

    /// Everything the model is built from. Tools that appear and disappear —
    /// an MCP server connecting mid-conversation — move this, which is why
    /// providers report a `declarationsVersion`.
    private func currentTools() async -> [ToolDeclaration] {
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
        let started = Date()

        var runUsage = TokenUsage.zero
        var toolsCalled: [String] = []
        var outcome = ChatRunOutcome.completed
        var turn = 0

        await reconfigureIfNeeded()

        var input = TurnInput.message(userText, attachments: attachments ?? [])

        while turn < configuration.maxTurns {
            if Task.isCancelled { outcome = .stopped; break }

            // Every turn starts with the model thinking again: the previous
            // turn's text stopped the indicator, and this one has produced none.
            modelIsWorking = true

            let assistantID = openAssistantMessage()
            var calls: [ToolCall] = []
            var finish: FinishReason?
            // Gemini and friends report usage cumulatively per chunk, so the
            // last value seen is the turn's total — summing them would multiply it.
            var turnUsage: TokenUsage?

            do {
                for try await chunk in configuration.backend.stream(input) {
                    if Task.isCancelled { break }
                    switch chunk {
                    case .text(let delta):
                        modelIsWorking = false
                        appendText(delta, to: assistantID)
                    case .toolCall(let call):
                        calls.append(call)
                    case .usage(let value):
                        turnUsage = value
                    case .finish(let reason):
                        finish = reason
                    }
                }
            } catch {
                let message = error.localizedDescription
                if !Task.isCancelled {
                    self.error = message
                    outcome = .failed(message)
                    finishAssistantMessage(assistantID, note: "Error: \(message)")
                } else {
                    outcome = .stopped
                    finishAssistantMessage(assistantID, note: nil)
                }
                break
            }

            if let value = turnUsage {
                usage = usage + value
                runUsage = runUsage + value
                lastTurnUsage = value
            }

            let note = finish?.userFacingNote
            finishAssistantMessage(assistantID, note: note)

            if Task.isCancelled { outcome = .stopped; break }

            // A blocked or truncated turn ends the run: continuing would feed
            // the model back a half-turn it never finished.
            if let note, calls.isEmpty {
                error = note
                outcome = .failed(note)
                break
            }

            // No tool calls means the model answered — that's the run.
            guard !calls.isEmpty else { break }

            toolsCalled += calls.map(\.name)
            // Tools produce no text, so the indicator carries the whole wait.
            modelIsWorking = true
            let results = await execute(calls)

            if Task.isCancelled { outcome = .stopped; break }

            input = .toolResults(results)
            turn += 1
        }

        if turn >= configuration.maxTurns {
            outcome = .turnLimitReached
            appendTurnLimitNote()
        }

        isStreaming = false
        modelIsWorking = false
        finalizeStreamingMessages()

        // A run that stopped or failed part-way can leave the backend holding a
        // model turn whose tool calls were never answered — it committed the
        // turn, then the loop unwound before the results were sent. Every send
        // after that is rejected, so the next run rebuilds history from the
        // transcript, where `replayableTurns` answers each call.
        if outcome != .completed { configuredFingerprint = nil }

        save()

        await recordTelemetry(userText: userText,
                              toolsCalled: toolsCalled,
                              usage: runUsage,
                              turns: turn,
                              started: started)

        // After the answer is delivered, never before. Compacting on the way in
        // would fold the message the user just typed into the summary and then
        // answer it out of a transcript they can no longer see. Doing it here
        // means the next turn starts from a small history instead.
        //
        // Ahead of `onRunFinished` so that by the time a host is told the run
        // ended, the transcript it is about to read has stopped moving.
        if outcome == .completed,
           configuration.context.shouldCompact(afterPromptTokens: lastTurnUsage.prompt) {
            await compact()
        }

        configuration.onRunFinished?(outcome)
    }

    // MARK: - Tool execution

    private func execute(_ calls: [ToolCall]) async -> [ToolResult] {
        // One message per call, appended up front so the UI shows the whole
        // batch as pending rather than revealing them one at a time.
        let messageIDs = calls.map { call -> UUID in
            let message = ChatMessage.toolCall(call)
            messages.append(message)
            return message.id
        }

        var results = [ToolResult?](repeating: nil, count: calls.count)
        var dispatched: [(index: Int, call: ToolCall, provider: any ToolProvider)] = []

        // Sequential pass: everything that can suspend the loop or mutate
        // session state. Running these in parallel would show the user several
        // permission cards at once.
        for (index, call) in calls.enumerated() {
            if Task.isCancelled {
                results[index] = .failure(call, AgentRefusal.cancelled)
                cancel(messageIDs[index])
                continue
            }

            if enabledAgentToolNames.contains(call.name) {
                results[index] = await runAgentTool(call)
                continue
            }

            if call.name == SkillsService.toolName {
                results[index] = skills.execute(call)
                continue
            }

            if let handle = call.arguments["handle"]?.stringValue,
               let compressor = configuration.compressor,
               compressor.declarations.contains(where: { $0.name == call.name }) {
                results[index] = await retrieve(call, handle: handle, using: compressor)
                continue
            }

            guard let provider = await provider(for: call.name) else {
                results[index] = .failure(call, AgentRefusal.unhandled(call.name))
                cancel(messageIDs[index])
                continue
            }

            // Plan mode outranks permissions: a tool the user already granted
            // "always allow" must still be refused while planning.
            if planMode, await provider.mutatingToolNames.contains(call.name) {
                results[index] = .failure(call, AgentRefusal.planModeBlocked)
                cancel(messageIDs[index])
                continue
            }

            if permissions.requiresApproval(call.name) {
                let card = await provider.approvalCard(for: call) ?? .generic(for: call)
                let decision = await permissions.request(card)
                if decision == .deny || Task.isCancelled {
                    results[index] = .failure(call, Task.isCancelled ? AgentRefusal.cancelled
                                                                    : AgentRefusal.denied)
                    cancel(messageIDs[index])
                    continue
                }
            }

            dispatched.append((index, call, provider))
        }

        // Everything approved runs concurrently — independent reads and searches
        // are the common case, and serializing them wastes most of a turn.
        await withTaskGroup(of: (Int, ToolResult).self) { group in
            for (index, call, provider) in dispatched {
                group.addTask {
                    (index, await Self.executeWithRetry(call, on: provider))
                }
            }
            for await (index, result) in group {
                results[index] = result
            }
        }

        var final = zip(calls, results).map { call, result in
            result ?? .failure(call, AgentRefusal.cancelled)
        }

        if let compressor = configuration.compressor {
            final = await compress(final, using: compressor)
        }

        // After the compressor, not before: it stores the full text and hands
        // back a short handle, so anything still oversized here is text nobody
        // is keeping. Truncating first would shrink what the compressor could
        // have preserved in full.
        final = final.map(configuration.context.truncating)

        for (index, result) in final.enumerated() {
            complete(messageIDs[index], failed: result.errorMessage != nil)
            messages.append(.toolResult(result))
        }

        return final
    }

    private func provider(for name: String) async -> (any ToolProvider)? {
        for provider in configuration.toolProviders where await provider.handles(name) {
            return provider
        }
        return nil
    }

    /// One retry on what looks like a transient network failure. Tool errors are
    /// data the model reads, so a flaky connection would otherwise become a
    /// wrong answer rather than a retried call.
    private static func executeWithRetry(_ call: ToolCall,
                                         on provider: any ToolProvider) async -> ToolResult {
        let result = await provider.execute(call)
        guard let message = result.errorMessage,
              ["URLError", "network", "connection", "timed out"]
                  .contains(where: { message.localizedCaseInsensitiveContains($0) })
        else { return result }
        return await provider.execute(call)
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

        for message in messages {
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
