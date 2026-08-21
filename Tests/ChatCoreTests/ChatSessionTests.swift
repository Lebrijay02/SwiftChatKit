//
//  ChatSessionTests.swift
//  SwiftChatKit
//
//  The agent loop, driven end to end against a scripted backend. These are the
//  behavioral regression tests for the engine: what lands in the transcript,
//  what the model is told when a call is refused, and when the loop stops.
//

import Testing
import Foundation
@testable import ChatCore

@MainActor
private func makeSession(
    backend: any ChatBackend,
    providers: [any ToolProvider] = [],
    maxTurns: Int = 100,
    compressor: (any ContextCompressor)? = nil,
    sessionTools: Bool = false,
    recorder: RunRecorder
) -> ChatSession {
    ChatSession(configuration: ChatSessionConfiguration(
        backend: backend,
        toolProviders: providers,
        maxTurns: maxTurns,
        enableTodos: sessionTools,
        enableQuestions: sessionTools,
        permissionStore: EphemeralPermissionStore(),
        compressor: compressor,
        onRunFinished: { [recorder] outcome in recorder.record(outcome) }))
}

// MARK: - Plain turns

@Suite("Agent loop — plain turns")
@MainActor
struct PlainTurnTests {

    @Test("A text-only turn produces one assistant message")
    func plainAnswer() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("Hello, "), .text("world."), .finish(.stop)]]),
            recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[1].content == "Hello, world.")
        #expect(session.messages[1].isStreaming == false)
        #expect(session.isStreaming == false)
        #expect(recorder.outcomes == [.completed])
    }

    @Test("Thinking runs from the request until the first token")
    func thinkingIndicator() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("Hello."), .finish(.stop)]],
                                 turnDelay: .milliseconds(200)),
            recorder: recorder)

        #expect(session.isThinking == false, "nothing has been asked yet")

        session.send("hi")
        #expect(await Wait.until { session.isThinking })
        #expect(session.messages.last?.content.isEmpty == true, "no text yet — hence the indicator")

        // The first token replaces the indicator: streaming text is its own.
        #expect(await Wait.until { !session.isThinking })
        #expect(session.messages.last?.content.isEmpty == false)

        #expect(await Wait.runs(recorder))
        #expect(session.isThinking == false)
    }

    @Test("Thinking resumes between turns, while tools run and nothing is shown")
    func thinkingBetweenTurns() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [
                [.toolCall(ToolCall(id: "r", name: "readFile", arguments: ["path": "a"])),
                 .finish(.stop)],
                [.text("Read it."), .finish(.stop)],
            ], turnDelay: .milliseconds(200)),
            providers: [MockProvider.readFile()],
            recorder: recorder)

        session.send("read it")
        #expect(await Wait.until { session.isThinking })
        // The tool call produced a message but no prose, so the wait continues
        // right through it into the next turn.
        #expect(await Wait.until { session.messages.contains { $0.toolName == "readFile" } })
        #expect(session.isThinking)

        #expect(await Wait.runs(recorder))
        #expect(session.isThinking == false)
    }

    @Test("Usage is the last value reported, not the sum of every chunk")
    func usageIsNotDoubleCounted() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[
                .text("x"),
                .usage(TokenUsage(prompt: 10, completion: 1, total: 11)),
                .usage(TokenUsage(prompt: 10, completion: 4, total: 14)),
                .finish(.stop),
            ]]),
            recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        #expect(session.usage == TokenUsage(prompt: 10, completion: 4, total: 14))
        #expect(session.lastTurnUsage.total == 14)
    }

    @Test("An abnormal finish is written into the bubble and ends the run")
    func abnormalFinish() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("Partial"), .finish(.maxTokens)]]),
            recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        #expect(session.messages.last?.content.contains("Partial") == true)
        #expect(session.messages.last?.content.contains("output token limit") == true)
        #expect(session.error != nil)
    }

    @Test("A backend failure surfaces on the message and on the session")
    func backendFailure() async {
        let recorder = RunRecorder()
        let session = makeSession(backend: FailingBackend(), recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        #expect(session.error == "the network went away")
        #expect(session.messages.last?.content.contains("the network went away") == true)
        #expect(recorder.outcomes == [.failed("the network went away")])
    }

    @Test("An empty message is not sent")
    func emptyInputIgnored() async {
        let recorder = RunRecorder()
        let session = makeSession(backend: MockBackend(), recorder: recorder)
        session.send("   ")
        #expect(session.messages.isEmpty)
        #expect(session.isStreaming == false)
    }
}

// MARK: - Tools

@Suite("Agent loop — tools")
@MainActor
struct ToolLoopTests {

    private func toolCallScript(_ name: String,
                                arguments: [String: ChatValue] = [:],
                                then reply: String = "Done.") -> [[TurnChunk]] {
        [[.toolCall(ToolCall(id: "c1", name: name, arguments: arguments)), .finish(.stop)],
         [.text(reply), .finish(.stop)]]
    }

    @Test("A tool call round-trips and the empty bubble it came in is removed")
    func toolRoundTrip() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        let session = makeSession(backend: MockBackend(script: toolCallScript("readFile")),
                                  providers: [provider],
                                  recorder: recorder)

        session.send("read it")
        #expect(await Wait.runs(recorder))

        // user, toolCall, toolResult, assistant — no blank bubble for the
        // tool-only turn.
        #expect(session.messages.map(\.role) == [
            .user, .toolCall(toolName: "readFile"), .toolResult(toolName: "readFile"), .assistant,
        ])
        #expect(session.messages[1].status == .completed)
        #expect(session.messages[2].rawResult?["content"]?.stringValue == "hello")
        #expect(await provider.executed.count == 1)
    }

    @Test("Parallel calls in one turn all run and all report back")
    func parallelCalls() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "a", name: "readFile", arguments: ["path": "a"])),
             .toolCall(ToolCall(id: "b", name: "readFile", arguments: ["path": "b"])),
             .finish(.stop)],
            [.text("Both read."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, providers: [provider], recorder: recorder)

        session.send("read both")
        #expect(await Wait.runs(recorder))

        #expect(await provider.executed.count == 2)
        let results = session.messages.filter { $0.role == .toolResult(toolName: "readFile") }
        #expect(results.count == 2)
        // Results are answered as one turn, in call order.
        #expect(results.map(\.callID) == ["a", "b"])
    }

    @Test("An unknown tool is refused without reaching a provider")
    func unknownTool() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        let session = makeSession(backend: MockBackend(script: toolCallScript("deleteEverything")),
                                  providers: [provider],
                                  recorder: recorder)

        session.send("go")
        #expect(await Wait.runs(recorder))

        #expect(await provider.executed.isEmpty)
        let result = session.messages.first { $0.role == .toolResult(toolName: "deleteEverything") }
        #expect(result?.rawResult?["error"]?.stringValue?.contains("No tool named") == true)
    }

    @Test("A transient network error is retried once")
    func retriesOnNetworkError() async {
        let recorder = RunRecorder()
        let provider = FlakyProvider()
        let session = makeSession(backend: MockBackend(script: toolCallScript("fetch")),
                                  providers: [provider],
                                  recorder: recorder)

        session.send("fetch")
        #expect(await Wait.runs(recorder))

        #expect(await provider.attempts == 2)
        let result = session.messages.first { $0.role == .toolResult(toolName: "fetch") }
        #expect(result?.rawResult?["body"]?.stringValue == "ok")
    }

    @Test("Reaching the turn cap stops the run and says so")
    func turnCap() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        // Never stops calling tools.
        let backend = MockBackend(script: Array(repeating:
            [.toolCall(ToolCall(name: "readFile")), .finish(.stop)], count: 20))
        let session = makeSession(backend: backend, providers: [provider],
                                  maxTurns: 3, recorder: recorder)

        session.send("loop forever")
        #expect(await Wait.runs(recorder))

        #expect(recorder.outcomes == [.turnLimitReached])
        #expect(await provider.executed.count == 3)
        #expect(session.messages.last?.content.contains("3-turn tool limit") == true)
    }
}

// MARK: - Permissions and plan mode

@Suite("Agent loop — permissions and plan mode")
@MainActor
struct PermissionLoopTests {

    private let writeTool = ToolDeclaration(name: "writeFile", description: "Writes a file.",
                                            parameters: ["path": .string()])

    private func writeScript() -> [[TurnChunk]] {
        [[.toolCall(ToolCall(id: "w1", name: "writeFile", arguments: ["path": "/tmp/x"])),
          .finish(.stop)],
         [.text("Handled."), .finish(.stop)]]
    }

    @Test("A denied call never runs, and the model is told not to retry it")
    func denial() async {
        let recorder = RunRecorder()
        let provider = MockProvider(tools: [writeTool], mutating: ["writeFile"])
        let session = makeSession(backend: MockBackend(script: writeScript()),
                                  providers: [provider], recorder: recorder)

        session.send("write it")
        #expect(await Wait.until { session.permissions.pending != nil })
        session.permissions.resolve(.deny)
        #expect(await Wait.runs(recorder))

        #expect(await provider.executed.isEmpty)
        let result = session.messages.first { $0.role == .toolResult(toolName: "writeFile") }
        #expect(result?.rawResult?["error"]?.stringValue == AgentRefusal.denied)
        // The call itself is marked cancelled, not completed.
        #expect(session.messages.first { $0.role == .toolCall(toolName: "writeFile") }?.status
                == .cancelled)
    }

    @Test("A parked permission card is the user's wait, not the model's")
    func thinkingIsFalseWhileParked() async {
        let recorder = RunRecorder()
        let provider = MockProvider(tools: [writeTool], mutating: ["writeFile"])
        let session = makeSession(backend: MockBackend(script: writeScript()),
                                  providers: [provider], recorder: recorder)

        session.send("write it")
        #expect(await Wait.until { session.permissions.pending != nil })
        #expect(session.isStreaming, "the run is parked, not finished")
        #expect(session.isThinking == false)

        session.permissions.resolve(.allowOnce)
        #expect(await Wait.runs(recorder))
        #expect(session.isThinking == false)
    }

    @Test("An approved call runs, and Always allow stops the next prompt")
    func approvalAndAlwaysAllow() async {
        let recorder = RunRecorder()
        let provider = MockProvider(tools: [writeTool], mutating: ["writeFile"])
        let session = makeSession(backend: MockBackend(script: writeScript()),
                                  providers: [provider], recorder: recorder)

        session.send("write it")
        #expect(await Wait.until { session.permissions.pending != nil })
        #expect(session.permissions.pending?.toolName == "writeFile")
        session.permissions.resolve(.alwaysAllow)
        #expect(await Wait.runs(recorder))

        #expect(await provider.executed.count == 1)
        #expect(session.permissions.requiresApproval("writeFile") == false)
    }

    @Test("Plan mode refuses a mutating tool without even asking")
    func planModeBlocks() async {
        let recorder = RunRecorder()
        let provider = MockProvider(tools: [writeTool], mutating: ["writeFile"])
        let session = makeSession(backend: MockBackend(script: writeScript()),
                                  providers: [provider], recorder: recorder)
        session.setPlanMode(true)

        session.send("write it")
        #expect(await Wait.runs(recorder))

        #expect(session.permissions.pending == nil)
        #expect(await provider.executed.isEmpty)
        let result = session.messages.first { $0.role == .toolResult(toolName: "writeFile") }
        #expect(result?.rawResult?["error"]?.stringValue == AgentRefusal.planModeBlocked)
    }

    @Test("Plan mode outranks a previously granted Always allow")
    func planModeOutranksAlwaysAllow() async {
        let recorder = RunRecorder()
        let provider = MockProvider(tools: [writeTool], autoAllowed: ["writeFile"],
                                    mutating: ["writeFile"])
        let session = makeSession(backend: MockBackend(script: writeScript()),
                                  providers: [provider], recorder: recorder)
        session.setPlanMode(true)

        session.send("write it")
        #expect(await Wait.runs(recorder))

        #expect(await provider.executed.isEmpty)
    }

    @Test("exitPlanMode is offered only in plan mode, and approval turns it off")
    func exitPlanMode() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "p", name: AgentTools.exitPlanMode,
                                arguments: ["plan": "1. Do the thing"])),
             .finish(.stop)],
            [.text("Starting."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, recorder: recorder)

        #expect(await backend.configuredTools.map(\.name).contains(AgentTools.exitPlanMode) == false)
        session.setPlanMode(true)

        session.send("plan it")
        #expect(await Wait.until { session.permissions.pending?.kind == .plan })
        #expect(session.permissions.pending?.detail == "1. Do the thing")
        session.permissions.resolve(.allowOnce)
        #expect(await Wait.runs(recorder))

        #expect(session.planMode == false)
        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.exitPlanMode) }
        #expect(result?.rawResult?["approved"]?.boolValue == true)
        #expect(await backend.configuredTools.map(\.name).contains(AgentTools.exitPlanMode))
    }

    @Test("A rejected plan keeps plan mode on")
    func rejectedPlan() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "p", name: AgentTools.exitPlanMode, arguments: ["plan": "x"])),
             .finish(.stop)],
            [.text("Revising."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, recorder: recorder)
        session.setPlanMode(true)

        session.send("plan it")
        #expect(await Wait.until { session.permissions.pending != nil })
        session.permissions.resolve(.deny)
        #expect(await Wait.runs(recorder))

        #expect(session.planMode == true)
        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.exitPlanMode) }
        #expect(result?.rawResult?["approved"]?.boolValue == false)
    }
}

// MARK: - Session-owned tools

@Suite("Agent loop — session-owned tools")
@MainActor
struct AgentToolTests {

    @Test("todoWrite replaces the checklist and never prompts")
    func todoWrite() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "t", name: AgentTools.todoWrite, arguments: [
                "todos": .array([
                    .object(["content": "Read the file", "status": "completed"]),
                    .object(["content": "Edit it", "status": "in_progress"]),
                    .object(["content": "Test it", "status": "pending"]),
                ]),
            ])), .finish(.stop)],
            [.text("Working."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, sessionTools: true, recorder: recorder)

        session.send("do the thing")
        #expect(await Wait.runs(recorder))

        #expect(session.permissions.pending == nil)
        #expect(session.todos.count == 3)
        #expect(session.todos.inProgress?.content == "Edit it")
        #expect(session.todos.completedCount == 1)
    }

    @Test("A malformed todoWrite is reported to the model, not crashed on")
    func malformedTodoWrite() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "t", name: AgentTools.todoWrite)), .finish(.stop)],
            [.text("ok"), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, sessionTools: true, recorder: recorder)

        session.send("go")
        #expect(await Wait.runs(recorder))

        #expect(session.todos.isEmpty)
        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.todoWrite) }
        #expect(result?.rawResult?["error"] != nil)
    }

    @Test("askUser parks the loop until the questions are answered")
    func askUser() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "q", name: AgentTools.askUser, arguments: [
                "questions": .array([
                    .object(["question": "Which database?",
                             "header": "Storage",
                             "options": .array([.object(["label": "SQLite"]),
                                                .object(["label": "Postgres"])])]),
                ]),
            ])), .finish(.stop)],
            [.text("Using Postgres."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, sessionTools: true, recorder: recorder)

        session.send("build it")
        #expect(await Wait.until { session.questions.pending != nil })
        #expect(session.questions.pending?.first?.options.count == 2)
        #expect(session.isStreaming, "the run is parked, not finished")
        session.questions.resolve(["Which database?": "Postgres"])
        #expect(await Wait.runs(recorder))

        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.askUser) }
        #expect(result?.rawResult?["answers"]?["Which database?"]?.stringValue == "Postgres")
    }

    @Test("Dismissing the questions tells the model to carry on")
    func dismissedQuestions() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "q", name: AgentTools.askUser, arguments: [
                "questions": .array([.object(["question": "Which one?"])]),
            ])), .finish(.stop)],
            [.text("Picking a default."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, sessionTools: true, recorder: recorder)

        session.send("build it")
        #expect(await Wait.until { session.questions.pending != nil })
        session.questions.resolve(nil)
        #expect(await Wait.runs(recorder))

        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.askUser) }
        #expect(result?.rawResult?["error"]?.stringValue?.contains("reasonable defaults") == true)
    }
}

// MARK: - Configuration and compression

@Suite("Agent loop — configuration")
@MainActor
struct SessionConfigurationTests {

    @Test("The tool list offered to the model reflects the configuration")
    func toolListAssembly() async {
        let recorder = RunRecorder()
        let backend = MockBackend()
        let session = makeSession(backend: backend, providers: [MockProvider.readFile()],
                                  sessionTools: true, recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        let names = Set(await backend.configuredTools.map(\.name))
        #expect(names.contains("readFile"))
        #expect(names.contains(AgentTools.todoWrite))
        #expect(names.contains(AgentTools.askUser))
        // Not in plan mode, so the exit tool is withheld.
        #expect(names.contains(AgentTools.exitPlanMode) == false)
    }

    @Test("A session with no providers offers no tools at all")
    func blankCanvas() async {
        let recorder = RunRecorder()
        let backend = MockBackend()
        let session = makeSession(backend: backend, recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))

        #expect(await backend.configuredTools.isEmpty)
    }

    @Test("A disabled session tool is not dispatched even if the model calls it")
    func disabledSessionTool() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "t", name: AgentTools.todoWrite, arguments: [
                "todos": .array([.object(["content": "Sneak in", "status": "pending"])]),
            ])), .finish(.stop)],
            [.text("ok"), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, recorder: recorder)

        session.send("go")
        #expect(await Wait.runs(recorder))

        #expect(session.todos.isEmpty)
        let result = session.messages.first { $0.role == .toolResult(toolName: AgentTools.todoWrite) }
        #expect(result?.rawResult?["error"]?.stringValue?.contains("No tool named") == true)
    }

    @Test("The model is rebuilt only when its inputs change")
    func rebuildIsSkippedWhenNothingChanged() async {
        let recorder = RunRecorder()
        let backend = MockBackend()
        let session = makeSession(backend: backend, recorder: recorder)

        session.send("one")
        #expect(await Wait.runs(recorder, count: 1))
        let afterFirst = await backend.configureCount

        session.send("two")
        #expect(await Wait.runs(recorder, count: 2))
        #expect(await backend.configureCount == afterFirst)

        session.setPlanMode(true)
        session.send("three")
        #expect(await Wait.runs(recorder, count: 3))
        #expect(await backend.configureCount == afterFirst + 1)
    }

    @Test("An active compressor shrinks oversized results and adds its tool")
    func compression() async {
        let recorder = RunRecorder()
        let long = String(repeating: "x", count: 500)
        let provider = MockProvider.readFile { .success($0, ["content": .string(long)]) }
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "r", name: "readFile")), .finish(.stop)],
            [.text("Read."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, providers: [provider],
                                  compressor: MockCompressor(), recorder: recorder)

        session.send("read it")
        #expect(await Wait.runs(recorder))

        let result = session.messages.first { $0.role == .toolResult(toolName: "readFile") }
        #expect(result?.rawResult?["content"]?.stringValue == "[compressed 500 chars from readFile]")
        #expect(await backend.configuredTools.map(\.name).contains("retrieveContext"))
        #expect(await backend.configuredInstruction.contains("# Compression"))
    }

    @Test("Short results are left alone")
    func shortResultsAreNotCompressed() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "r", name: "readFile")), .finish(.stop)],
            [.text("Read."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, providers: [provider],
                                  compressor: MockCompressor(), recorder: recorder)

        session.send("read it")
        #expect(await Wait.runs(recorder))

        let result = session.messages.first { $0.role == .toolResult(toolName: "readFile") }
        #expect(result?.rawResult?["content"]?.stringValue == "hello")
    }
}

// MARK: - Lifecycle and replay

@Suite("Agent loop — lifecycle")
@MainActor
struct SessionLifecycleTests {

    @Test("Stopping a run unwinds it and leaves nothing streaming")
    func stop() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("never arrives"), .finish(.stop)]],
                                 turnDelay: .seconds(30)),
            recorder: recorder)

        session.send("hi")
        #expect(await Wait.until { session.isStreaming })
        session.stop()
        #expect(await Wait.runs(recorder))

        #expect(recorder.outcomes == [.stopped])
        #expect(session.isStreaming == false)
        #expect(session.messages.contains { $0.isStreaming } == false)
    }

    @Test("newChat clears everything the previous conversation left behind")
    func newChat() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("hi"),
                                           .usage(TokenUsage(prompt: 1, completion: 1, total: 2)),
                                           .finish(.stop)]]),
            recorder: recorder)

        session.send("hello")
        #expect(await Wait.runs(recorder))
        let firstID = session.sessionID

        session.newChat()
        #expect(session.messages.isEmpty)
        #expect(session.usage == .zero)
        #expect(session.todos.isEmpty)
        #expect(session.title == "New chat")
        #expect(session.sessionID != firstID)
    }

    @Test("The title is derived from the first user message")
    func title() async {
        let recorder = RunRecorder()
        let session = makeSession(backend: MockBackend(), recorder: recorder)
        session.send("Refactor the settings screen")
        #expect(await Wait.runs(recorder))
        #expect(session.title == "Refactor the settings screen")
    }

    @Test("History replay coalesces parallel calls into one turn each way")
    func replayCoalescesToolTurns() async {
        let recorder = RunRecorder()
        let provider = MockProvider.readFile()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "a", name: "readFile")),
             .toolCall(ToolCall(id: "b", name: "readFile")),
             .finish(.stop)],
            [.text("Both read."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend, providers: [provider], recorder: recorder)

        session.send("read both")
        #expect(await Wait.runs(recorder))

        let turns = session.replayableTurns()
        // user → model(2 calls) → user(2 results) → model(text)
        #expect(turns.map(\.role) == [.user, .model, .user, .model])
        #expect(turns[1].parts.count == 2)
        #expect(turns[2].parts.count == 2)
    }

    @Test("A tool call saved without its payload is shown but not replayed")
    func unreplayableTurnsAreDropped() {
        let recorder = RunRecorder()
        let session = makeSession(backend: MockBackend(), recorder: recorder)
        session.load(StoredSession(title: "old", messages: [
            StoredMessage(from: .user("hi")),
            StoredMessage(from: ChatMessage(role: .toolCall(toolName: "readFile"),
                                            content: "readFile", callID: "x")),
            StoredMessage(from: .assistant("I read it.")),
        ]))

        #expect(session.messages.count == 3)
        #expect(session.replayableTurns().map(\.role) == [.user, .model])
    }

    @Test("A trailing unanswered call is dropped, since it would invalidate the next send")
    func trailingUnansweredCallDropped() {
        let recorder = RunRecorder()
        let session = makeSession(backend: MockBackend(), recorder: recorder)
        session.load(StoredSession(title: "old", messages: [
            StoredMessage(from: .user("hi")),
            StoredMessage(from: .toolCall(ToolCall(id: "x", name: "readFile",
                                                   arguments: ["path": "a"]))),
        ]))

        #expect(session.replayableTurns().map(\.role) == [.user])
    }

    @Test("A saved session round-trips back into a live one")
    func persistence() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RunRecorder()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(script: [[.text("Answered."), .finish(.stop)]]),
            permissionStore: EphemeralPermissionStore(),
            historyStore: ChatHistoryStore(directory: directory),
            onRunFinished: { [recorder] outcome in recorder.record(outcome) }))

        session.send("remember this")
        #expect(await Wait.runs(recorder))

        let stored = try #require(ChatHistoryStore(directory: directory).load(session.sessionID))
        #expect(stored.title == "remember this")
        #expect(stored.messages.count == 2)

        let reopened = makeSession(backend: MockBackend(), recorder: RunRecorder())
        reopened.load(stored)
        #expect(reopened.messages.map(\.content) == ["remember this", "Answered."])
        #expect(reopened.sessionID == session.sessionID)
    }
}
