//
//  ChatSessionSupport.swift
//  SwiftChatKit
//
//  Test doubles for the agent loop: a backend that replays a script instead of
//  calling a model, and a provider that records what it was asked to run.
//

import Foundation
@testable import ChatCore

// MARK: - Backend

/// Replays a scripted list of turns. Each element is one model turn's chunks;
/// running out of script yields a bare `.finish(.stop)`, which the loop treats
/// as "the model answered with nothing" and ends the run.
actor MockBackend: ChatBackend {

    private var script: [[TurnChunk]]
    /// Set to have every turn take long enough to be cancelled.
    private let turnDelay: Duration?

    private(set) var configuredInstruction = ""
    private(set) var configuredTools: [ToolDeclaration] = []
    private(set) var configuredHistory: [ChatTurn] = []
    private(set) var configureCount = 0
    private(set) var receivedInputs: [TurnInput] = []

    init(script: [[TurnChunk]] = [], turnDelay: Duration? = nil) {
        self.script = script
        self.turnDelay = turnDelay
    }

    var history: [ChatTurn] { configuredHistory }
    var modelName: String { "mock-1" }

    func configure(systemInstruction: String,
                   tools: [ToolDeclaration],
                   history: [ChatTurn]) {
        configuredInstruction = systemInstruction
        configuredTools = tools
        configuredHistory = history
        configureCount += 1
    }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let chunks = await self.next(input)
                if let delay = await self.turnDelay {
                    try await Task.sleep(for: delay)
                }
                for chunk in chunks {
                    try Task.checkCancellation()
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func next(_ input: TurnInput) -> [TurnChunk] {
        receivedInputs.append(input)
        guard !script.isEmpty else { return [.finish(.stop)] }
        return script.removeFirst()
    }
}

/// A backend whose every turn throws, for the error path.
actor FailingBackend: ChatBackend {
    struct Failure: LocalizedError {
        var errorDescription: String? { "the network went away" }
    }

    var history: [ChatTurn] { [] }
    var modelName: String { "failing-1" }
    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {}

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: Failure()) }
    }
}

// MARK: - Provider

actor MockProvider: ToolProvider {

    nonisolated let autoAllowedToolNames: Set<String>
    nonisolated let mutatingToolNames: Set<String>
    private let tools: [ToolDeclaration]
    private let handler: @Sendable (ToolCall) -> ToolResult

    private(set) var executed: [ToolCall] = []

    init(tools: [ToolDeclaration],
         autoAllowed: Set<String> = [],
         mutating: Set<String> = [],
         handler: @escaping @Sendable (ToolCall) -> ToolResult = { .success($0, ["ok": .bool(true)]) }) {
        self.tools = tools
        self.autoAllowedToolNames = autoAllowed
        self.mutatingToolNames = mutating
        self.handler = handler
    }

    /// A single read-only tool, auto-allowed — the common shape in these tests.
    static func readFile(handler: @escaping @Sendable (ToolCall) -> ToolResult
                             = { .success($0, ["content": "hello"]) }) -> MockProvider {
        MockProvider(tools: [ToolDeclaration(name: "readFile",
                                             description: "Reads a file.",
                                             parameters: ["path": .string()])],
                     autoAllowed: ["readFile"],
                     handler: handler)
    }

    var declarations: [ToolDeclaration] { tools }

    func execute(_ call: ToolCall) async -> ToolResult {
        executed.append(call)
        return handler(call)
    }
}

/// Fails the first attempt with a network-shaped error, succeeds on the second —
/// the exact case the loop's single retry exists for.
actor FlakyProvider: ToolProvider {
    nonisolated let autoAllowedToolNames: Set<String> = ["fetch"]
    private(set) var attempts = 0

    var declarations: [ToolDeclaration] {
        [ToolDeclaration(name: "fetch", description: "Fetches something.")]
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        attempts += 1
        return attempts == 1
            ? .failure(call, "URLError: the connection timed out")
            : .success(call, ["body": "ok"])
    }
}

// MARK: - Compressor

struct MockCompressor: ContextCompressor {
    let threshold = 20
    var declarations: [ToolDeclaration] {
        [ToolDeclaration(name: "retrieveContext", description: "Recovers compressed text.",
                         parameters: ["handle": .string(), "query": .string()],
                         optional: ["query"])]
    }
    var systemInstruction: String { "\n\n# Compression\nLarge results are shortened." }

    func compress(_ text: String, toolName: String) async -> String {
        "[compressed \(text.count) chars from \(toolName)]"
    }

    func retrieve(handle: String, query: String?) async throws -> String {
        "recovered:\(handle):\(query ?? "-")"
    }
}

// MARK: - Run observation

/// The loop is asynchronous and can park on a permission card, so tests observe
/// completion through `onRunFinished` rather than guessing at a sleep duration.
@MainActor
final class RunRecorder {
    private(set) var outcomes: [ChatRunOutcome] = []
    func record(_ outcome: ChatRunOutcome) { outcomes.append(outcome) }
}

@MainActor
enum Wait {

    /// Polls a condition on the main actor. Returns false on timeout, so a
    /// caller can report a useful failure instead of hanging the suite.
    @discardableResult
    static func until(_ condition: @MainActor () -> Bool,
                      timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    static func runs(_ recorder: RunRecorder, count: Int = 1) async -> Bool {
        await until { recorder.outcomes.count >= count }
    }
}
