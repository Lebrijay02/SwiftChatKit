//
//  READMEExamples.swift
//  SwiftChatKit
//
//  Compile-check for the README's ChatGemini samples. Imports the modules the
//  way a consumer does — no `@testable` — so a sample that stops compiling
//  breaks the build rather than quietly rotting in the docs.
//
//  Nothing here is executed: the calls would need a configured Firebase project
//  and a network. Compiling is the whole assertion.
//

import Foundation
import ChatCore
import ChatGemini

private func readmeGeminiBackend() async throws {
    let backend = GeminiBackend(GeminiBackendConfig(
        model: .gemini3_5Flash,
        location: "global",
        enableGoogleSearch: true))

    await backend.configure(
        systemInstruction: SystemPromptBuilder.build(SystemPromptContext()),
        tools: [ToolDeclaration(name: "readFile", description: "Reads a file.",
                                parameters: ["path": .string()])],
        history: [])

    for try await chunk in backend.stream(.message("What changed in this file?")) {
        _ = chunk
    }

    _ = GeminiModel.known
    _ = GeminiModel.gemini3_5Flash.displayName
    _ = GeminiModel("gemini-9-ultra-preview").displayName
    await backend.setModel(.gemini2_5Pro)

    _ = await backend.history
    _ = await backend.modelName
}

// MARK: - Quickstart

private func notifyUser(_ message: String) {}

private final class MyToolProvider: ToolProvider {
    var declarations: [ToolDeclaration] {
        get async { [ToolDeclaration(name: "myTool", description: "Does the thing.")] }
    }
    func execute(_ call: ToolCall) async -> ToolResult { .success(call, ["ok": .bool(true)]) }
}

private struct MyTelemetry: ChatTelemetry {
    func record(_ metrics: TurnMetrics) async {}
}

@MainActor
private func readmeQuickstart(projectURL: URL, data: Data, storedSession: StoredSession) {
    // The minimal configuration from the top of "## Quickstart".
    _ = ChatSession(configuration: ChatSessionConfiguration(
        backend: GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash))))

    let session = ChatSession(configuration: ChatSessionConfiguration(
        backend: GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash)),
        toolProviders: [MyToolProvider()],
        persona: .codingAgent,
        workingDirectory: projectURL,
        skills: .claudeCompatible,
        maxTurns: 100,
        enableTodos: true,
        enableQuestions: true,
        historyStore: .applicationSupport("MyApp"),
        telemetry: MyTelemetry(),
        onRunFinished: { outcome in
            if outcome == .completed { notifyUser("Your request is ready.") }
        }))

    session.send("Refactor this view", attachments: [.image(data, mimeType: "image/png")])
    session.stop()

    _ = session.messages
    _ = session.isStreaming
    _ = session.error
    _ = session.todos
    _ = session.usage
    _ = session.lastTurnUsage
    _ = session.planMode
    _ = session.permissions.pending
    _ = session.questions.pending

    session.setPlanMode(true)
    session.regenerate()
    session.newChat()
    session.load(storedSession)
    session.save()
    session.workingDirectory = projectURL
}
