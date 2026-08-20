//
//  GeminiBackend.swift
//  SwiftChatKit
//
//  `ChatBackend` over Firebase AI Logic's Vertex AI path.
//
//  Mutable state lives in a private actor rather than on the class, because
//  `stream` must be synchronous to satisfy the protocol while the model and
//  chat objects it reads are shared across turns.
//

import Foundation
import FirebaseAILogic
import ChatCore

public final class GeminiBackend: ChatBackend {

    private let state: State

    /// Firebase must already be configured — `FirebaseApp.configure()` is the
    /// host's call to make, since it owns the plist and the app lifecycle.
    public init(_ configuration: GeminiBackendConfig = GeminiBackendConfig()) {
        state = State(configuration: configuration)
    }

    // MARK: - ChatBackend

    public func configure(systemInstruction: String,
                          tools: [ToolDeclaration],
                          history: [ChatTurn]) async {
        await state.configure(systemInstruction: systemInstruction,
                              tools: tools,
                              history: history)
    }

    public var history: [ChatTurn] {
        get async { await state.history }
    }

    public var modelName: String {
        get async { await state.configuration.model.rawValue }
    }

    /// Switches models mid-conversation, preserving the instruction, tools and
    /// history the session was last configured with.
    public func setModel(_ model: GeminiModel) async {
        await state.setModel(model)
    }

    public func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let responses = try await state.send(input)
                    for try await response in responses {
                        try Task.checkCancellation()

                        for part in response.candidates.first?.content.parts ?? [] {
                            switch part {
                            case let text as TextPart where !text.isThought:
                                guard !text.text.isEmpty else { continue }
                                continuation.yield(.text(text.text))
                            case let call as FunctionCallPart:
                                continuation.yield(.toolCall(ToolCall(call)))
                            default:
                                continue
                            }
                        }

                        if let usage = response.usageMetadata {
                            continuation.yield(.usage(TokenUsage(
                                prompt: usage.promptTokenCount,
                                completion: usage.candidatesTokenCount,
                                total: usage.totalTokenCount)))
                        }

                        if let reason = response.candidates.first?.finishReason {
                            continuation.yield(.finish(FinishReason(rawValue: reason.rawValue)))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - State

private actor State {

    private(set) var configuration: GeminiBackendConfig

    /// Retained so a model rebuild — a new tool arriving, plan mode toggling —
    /// doesn't have to be handed the same inputs again.
    private var systemInstruction = ""
    private var tools: [ToolDeclaration] = []

    private var model: GenerativeModel
    private var chat: Chat

    init(configuration: GeminiBackendConfig) {
        self.configuration = configuration
        let model = State.buildModel(configuration: configuration,
                                     systemInstruction: "",
                                     tools: [])
        self.model = model
        self.chat = model.startChat()
    }

    var history: [ChatTurn] {
        chat.history.map(ChatTurn.init)
    }

    func configure(systemInstruction: String,
                   tools: [ToolDeclaration],
                   history: [ChatTurn]) {
        self.systemInstruction = systemInstruction
        self.tools = tools
        rebuild(history: history.map(\.modelContent))
    }

    func setModel(_ model: GeminiModel) {
        guard model != configuration.model else { return }
        configuration.model = model
        // Carry the live history across, or switching models would silently
        // start a new conversation.
        rebuild(history: chat.history)
    }

    func send(_ input: TurnInput) throws -> AsyncThrowingStream<GenerateContentResponse, Error> {
        let parts = input.parts.compactMap(\.geminiPart)
        guard !parts.isEmpty else {
            throw GeminiBackendError.emptyTurn
        }
        // Role "user" for both a user message and a batch of function
        // responses — Vertex AI rejects any other role on an incoming turn.
        return try chat.sendMessageStream([ModelContent(role: "user", parts: parts)])
    }

    private func rebuild(history: [ModelContent]) {
        model = State.buildModel(configuration: configuration,
                                 systemInstruction: systemInstruction,
                                 tools: tools)
        chat = model.startChat(history: history)
    }

    private static func buildModel(configuration: GeminiBackendConfig,
                                   systemInstruction: String,
                                   tools: [ToolDeclaration]) -> GenerativeModel {
        var geminiTools: [Tool] = []
        if !tools.isEmpty {
            geminiTools.append(.functionDeclarations(tools.map(\.geminiDeclaration)))
        }
        if configuration.enableGoogleSearch {
            geminiTools.append(Tool.googleSearch())
        }

        return FirebaseAI.firebaseAI(backend: .vertexAI(location: configuration.location))
            .generativeModel(
                modelName: configuration.model.rawValue,
                tools: geminiTools.isEmpty ? nil : geminiTools,
                systemInstruction: systemInstruction.isEmpty
                    ? nil
                    : ModelContent(parts: [TextPart(systemInstruction)]))
    }
}

// MARK: - Errors

public enum GeminiBackendError: LocalizedError {
    /// A turn with nothing sendable in it. Reaching the network with this would
    /// return a 400, so it is caught here where the cause is still legible.
    case emptyTurn

    public var errorDescription: String? {
        switch self {
        case .emptyTurn:
            return "The turn had no content to send."
        }
    }
}
