//
//  AgentRuntimeTests.swift
//  SwiftChatKit
//

import Foundation
import Testing
@testable import ChatCore

@MainActor
private func runtimeSession(backend: any ChatBackend,
                            providers: [any ToolProvider] = [],
                            budget: AgentBudget? = nil,
                            retry: RetryPolicy = RetryPolicy(maxAttempts: 2,
                                                             initialDelay: .milliseconds(1)),
                            inputPolicy: InFlightInputPolicy = .reject,
                            validators: [any CompletionValidator] = [],
                            transitionTelemetry: (any AgentTransitionTelemetry)? = nil,
                            fallbackBackend: (any ChatBackend)? = nil,
                            recorder: RunRecorder) -> ChatSession {
    ChatSession(configuration: ChatSessionConfiguration(
        backend: backend,
        toolProviders: providers,
        budget: budget,
        modelRetryPolicy: retry,
        fallbackBackend: fallbackBackend,
        maximumConcurrentTools: 4,
        inFlightInputPolicy: inputPolicy,
        autoAllowedTools: providers.reduce(into: Set<String>()) {
            $0.formUnion($1.autoAllowedToolNames)
        },
        permissionStore: EphemeralPermissionStore(),
        transitionTelemetry: transitionTelemetry,
        completionValidators: validators,
        onRunFinished: { [recorder] outcome in recorder.record(outcome) }))
}

@Suite("Agent runtime — recovery and transitions")
@MainActor
struct AgentRuntimeTests {

    @Test("A retryable backend failure retries the same turn")
    func modelRetry() async {
        let backend = RetryBackend()
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend, recorder: recorder)

        session.send("hello")
        #expect(await Wait.runs(recorder))
        #expect(await backend.attempts == 2)
        #expect(session.messages.last?.content == "recovered")
    }

    @Test("A run that exhausts its retries falls back, then hands the next run back to the primary")
    func fallbackIsPerRunNotPermanent() async {
        // Exactly as many failures as the retry policy has attempts, so run one
        // exhausts them and run two finds the primary healthy again.
        let primary = FlakyBackend(failedStreams: 2, reply: "primary")
        let fallback = MockBackend(script: [[.text("fallback"), .finish(.stop)]])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: primary,
                                     fallbackBackend: fallback,
                                     recorder: recorder)

        session.send("hello")
        #expect(await Wait.runs(recorder))
        #expect(session.messages.last?.content == "fallback")

        session.send("again")
        #expect(await Wait.runs(recorder, count: 2))
        #expect(session.messages.last?.content == "primary")
        #expect(await primary.attempts == 3)
    }

    @Test("An output limit automatically continues without user input")
    func outputContinuation() async {
        let backend = MockBackend(script: [
            [.text("part one"), .finish(.maxTokens)],
            [.text("part two"), .finish(.stop)],
        ])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend, recorder: recorder)

        session.send("long answer")
        #expect(await Wait.runs(recorder))
        #expect(session.messages.filter { $0.role == .assistant }.map(\.content) == ["part one", "part two"])
        #expect(session.error == nil)
        #expect(await backend.receivedInputs.count == 2)
    }

    @Test("Malformed tool input becomes a tool result and never executes")
    func schemaValidation() async {
        let provider = MockProvider.readFile()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "bad", name: "readFile")), .finish(.stop)],
            [.text("fixed"), .finish(.stop)],
        ])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend, providers: [provider], recorder: recorder)

        session.send("read")
        #expect(await Wait.runs(recorder))
        #expect(await provider.executed.isEmpty)
        let result = session.messages.first { $0.callID == "bad" && $0.rawResult != nil }
        #expect(result?.rawResult?["errorKind"]?.stringValue == ToolFailureKind.invalidInput.rawValue)
    }

    @Test("A completion validator can send feedback back through the model")
    func completionValidator() async {
        let validator = RetryOnceValidator()
        let backend = MockBackend(script: [
            [.text("first"), .finish(.stop)],
            [.text("verified"), .finish(.stop)],
        ])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend,
                                     validators: [validator],
                                     recorder: recorder)

        session.send("do it")
        #expect(await Wait.runs(recorder))
        #expect(await backend.receivedInputs.count == 2)
        #expect(session.messages.last?.content == "verified")
    }

    @Test("Exclusive calls never overlap")
    func exclusiveScheduling() async {
        let provider = ExclusiveProvider()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "a", name: "exclusive")),
             .toolCall(ToolCall(id: "b", name: "exclusive")),
             .finish(.stop)],
            [.text("done"), .finish(.stop)],
        ])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend, providers: [provider], recorder: recorder)

        session.send("two")
        #expect(await Wait.runs(recorder))
        #expect(await provider.maximumActive == 1)
    }

    @Test("Token budget stops before another model turn")
    func tokenBudget() async {
        let backend = MockBackend(script: [[
            .toolCall(ToolCall(id: "a", name: "readFile", arguments: ["path": "a"])),
            .usage(TokenUsage(prompt: 10, completion: 1, total: 11)),
            .finish(.stop),
        ]])
        let provider = MockProvider.readFile()
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend,
                                     providers: [provider],
                                     budget: AgentBudget(maxTurns: 10, maxTotalTokens: 10),
                                     recorder: recorder)

        session.send("read")
        #expect(await Wait.runs(recorder))
        #expect(recorder.outcomes == [.budgetExceeded])
        #expect(await backend.receivedInputs.count == 1)
    }

    @Test("Queued input runs after the current turn")
    func queuedInput() async {
        let backend = MockBackend(script: [
            [.text("first"), .finish(.stop)],
            [.text("second"), .finish(.stop)],
        ], turnDelay: .milliseconds(100))
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend,
                                     inputPolicy: .queue,
                                     recorder: recorder)

        session.send("one")
        #expect(await Wait.until { session.isStreaming })
        session.send("two")
        #expect(await Wait.runs(recorder, count: 2))
        #expect(await backend.receivedInputs.count == 2)
        #expect(session.messages.filter { $0.role == .user }.map(\.content) == ["one", "two"])
    }

    @Test("Transition telemetry records tool continuation and completion")
    func transitionTelemetry() async {
        let telemetry = TransitionRecorder()
        let backend = MockBackend(script: [
            [.toolCall(ToolCall(id: "a", name: "readFile", arguments: ["path": "a"])),
             .finish(.stop)],
            [.text("done"), .finish(.stop)],
        ])
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend,
                                     providers: [MockProvider.readFile()],
                                     transitionTelemetry: telemetry,
                                     recorder: recorder)

        session.send("read")
        #expect(await Wait.runs(recorder))
        let events = await telemetry.events
        #expect(events.contains { $0.reason == .toolResults })
        #expect(events.contains { $0.termination == .completed })
    }

    @Test("A safe tool can finish before the model stream closes")
    func streamingToolOverlap() async {
        let provider = OverlapProvider()
        let backend = DelayedFinishBackend(provider: provider)
        let recorder = RunRecorder()
        let session = runtimeSession(backend: backend, providers: [provider], recorder: recorder)

        session.send("read")
        #expect(await Wait.runs(recorder))
        #expect(await provider.completed)
        #expect(await provider.attempts == 1)
    }
}

private actor RetryBackend: ChatBackend {
    private(set) var attempts = 0
    var history: [ChatTurn] { [] }
    var modelName: String { "retry" }
    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {}
    func generate(_ prompt: String) async throws -> String { "summary" }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let attempt = await nextAttempt()
                if attempt == 1 {
                    continuation.finish(throwing: BackendFailure.connection("offline"))
                } else {
                    continuation.yield(.text("recovered"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }
}

/// Fails its first `failedStreams` attempts with a retryable error, then answers
/// normally — a backend that recovers between runs rather than within one.
private actor FlakyBackend: ChatBackend {
    private let failedStreams: Int
    private let reply: String
    private(set) var attempts = 0

    init(failedStreams: Int, reply: String) {
        self.failedStreams = failedStreams
        self.reply = reply
    }

    var history: [ChatTurn] { [] }
    var modelName: String { "flaky" }
    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {}
    func generate(_ prompt: String) async throws -> String { "summary" }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if await nextAttempt() <= failedStreams {
                    continuation.finish(throwing: BackendFailure.connection("offline"))
                } else {
                    continuation.yield(.text(reply))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }
}

private actor RetryOnceValidator: CompletionValidator {
    private var attempts = 0
    func validate(_ context: CompletionContext) async -> CompletionDecision {
        attempts += 1
        return attempts == 1 ? .continueWithFeedback("Verify it and answer again.") : .accept
    }
}

private actor ExclusiveProvider: ToolProvider {
    nonisolated let autoAllowedToolNames: Set<String> = ["exclusive"]
    private var active = 0
    private(set) var maximumActive = 0
    var declarations: [ToolDeclaration] { [ToolDeclaration(name: "exclusive", description: "Exclusive")] }
    func executionMode(for call: ToolCall) async -> ToolExecutionMode { .exclusive }

    func execute(_ call: ToolCall) async -> ToolResult {
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(50))
        active -= 1
        return .success(call, ["ok": true])
    }
}

private actor TransitionRecorder: AgentTransitionTelemetry {
    private(set) var events: [AgentTransitionEvent] = []
    func record(_ event: AgentTransitionEvent) async { events.append(event) }
}

private actor OverlapProvider: ToolProvider {
    nonisolated let autoAllowedToolNames: Set<String> = ["overlap"]
    private(set) var completed = false
    private(set) var attempts = 0
    var declarations: [ToolDeclaration] { [ToolDeclaration(name: "overlap", description: "Safe read")] }
    func executionMode(for call: ToolCall) async -> ToolExecutionMode { .concurrent }
    func retrySafety(for call: ToolCall) async -> ToolRetrySafety { .idempotent }

    func execute(_ call: ToolCall) async -> ToolResult {
        attempts += 1
        try? await Task.sleep(for: .milliseconds(20))
        completed = true
        return .success(call, ["ok": true])
    }
}

private actor DelayedFinishBackend: ChatBackend {
    private let provider: OverlapProvider
    private var turn = 0

    init(provider: OverlapProvider) {
        self.provider = provider
    }

    var history: [ChatTurn] { [] }
    var modelName: String { "delayed" }
    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {}
    func generate(_ prompt: String) async throws -> String { "summary" }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let current = await nextTurn()
                if current == 1 {
                    continuation.yield(.toolCall(ToolCall(id: "o", name: "overlap")))
                    while await !provider.completed {
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    continuation.yield(.finish(.stop))
                } else {
                    continuation.yield(.text("done"))
                    continuation.yield(.finish(.stop))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextTurn() -> Int {
        turn += 1
        return turn
    }
}
