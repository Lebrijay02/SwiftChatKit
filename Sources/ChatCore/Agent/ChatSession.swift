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
    public private(set) var messages: [ChatMessage] = []

    /// True from `send` until the run ends, including while a permission card
    /// or question is parked waiting on the user.
    public private(set) var isStreaming = false

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
    }

    // MARK: - Sending

    /// Starts a run. Ignored while one is in flight — a second concurrent run
    /// would interleave two conversations into one history.
    public func send(_ text: String, attachments: [Attachment]? = nil) {
        guard !isStreaming else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !(attachments ?? []).isEmpty else { return }

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
        if let path = stored.workingDirectoryPath {
            workingDirectory = URL(fileURLWithPath: path)
        }
        configuredFingerprint = nil
    }

    @discardableResult
    public func save() -> Bool {
        guard let store = configuration.historyStore, !messages.isEmpty else { return false }
        return store.save(StoredSession(
            id: sessionID,
            title: title,
            createdAt: createdAt,
            updatedAt: Date(),
            messages: messages.map(StoredMessage.init),
            usage: usage,
            workingDirectoryPath: workingDirectory?.path,
            workingDirectoryDisplayName: workingDirectory?.lastPathComponent,
            modelName: nil))
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
        finalizeStreamingMessages()
        save()

        await recordTelemetry(userText: userText,
                              toolsCalled: toolsCalled,
                              usage: runUsage,
                              turns: turn,
                              started: started)

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

            if AgentTools.allNames.contains(call.name) {
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
            if planMode, provider.mutatingToolNames.contains(call.name) {
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
        var turns: [ChatTurn] = []
        var pendingCalls: [TurnPart] = []
        var pendingResults: [TurnPart] = []

        func flush() {
            if !pendingCalls.isEmpty {
                turns.append(ChatTurn(role: .model, parts: pendingCalls))
                pendingCalls = []
            }
            if !pendingResults.isEmpty {
                turns.append(ChatTurn(role: .user, parts: pendingResults))
                pendingResults = []
            }
        }

        for message in messages {
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
                pendingCalls.append(.toolCall(ToolCall(id: message.callID ?? UUID().uuidString,
                                                       name: name,
                                                       arguments: arguments)))
            case .toolResult(let name):
                if !pendingCalls.isEmpty {
                    turns.append(ChatTurn(role: .model, parts: pendingCalls))
                    pendingCalls = []
                }
                guard let payload = message.rawResult else { continue }
                pendingResults.append(.toolResult(ToolResult(callID: message.callID ?? "",
                                                             name: name,
                                                             payload: payload)))
            }
        }
        flush()

        // A trailing model turn of unanswered calls makes the next send invalid.
        if let last = turns.last, last.role == .model,
           last.parts.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
            turns.removeLast()
        }
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
