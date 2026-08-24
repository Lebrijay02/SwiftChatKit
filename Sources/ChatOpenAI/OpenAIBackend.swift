//
//  OpenAIBackend.swift
//  SwiftChatKit
//
//  `ChatBackend` over any server speaking OpenAI's `/chat/completions` format.
//
//  URLSession and Foundation only — no SDK. That is deliberate: the value of
//  this backend is that it reaches servers no SDK was written for, so binding
//  it to one would defeat the point.
//
//  Unlike `GeminiBackend`, there is no chat object holding history for us, so
//  the actor below owns it outright and every request is stateless and complete.
//

import Foundation
import ChatCore

public final class OpenAIBackend: ChatBackend {

    private let state: State

    public init(_ configuration: OpenAIBackendConfig, session: URLSession? = nil) {
        state = State(configuration: configuration, session: session ?? .shared)
    }

    /// OpenAI's own endpoint, for hosts with nothing to configure but a key.
    public convenience init(apiKey: String, model: OpenAIModel = .gpt5) {
        self.init(.openAI(apiKey: apiKey, model: model))
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

    /// Switches models mid-conversation. History, instruction and tools are
    /// held on this side, so nothing has to be rebuilt to carry them across.
    public func setModel(_ model: OpenAIModel) async {
        await state.setModel(model)
    }

    public func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await state.send(input)
                    try await State.checkStatus(of: response, bytes: bytes)

                    var decoder = OpenAIStreamDecoder()
                    var parts: [TurnPart] = []

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for chunk in decoder.chunks(forLine: line) {
                            OpenAIBackend.record(chunk, into: &parts)
                            continuation.yield(chunk)
                        }
                    }

                    // Servers that close without a `finish_reason` — some proxies
                    // do — would otherwise strand a fully assembled call.
                    for chunk in decoder.flushToolCalls() {
                        OpenAIBackend.record(chunk, into: &parts)
                        continuation.yield(chunk)
                    }

                    await state.commit(input: input, modelParts: parts)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // History is left untouched on failure, so a retry replays
                    // the same turn rather than a conversation with a hole in it.
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Accumulates the assistant turn as it streams. Text is coalesced into a
    /// single part so replayed history matches what was sent originally.
    private static func record(_ chunk: TurnChunk, into parts: inout [TurnPart]) {
        switch chunk {
        case .text(let text):
            if case .text(let existing) = parts.last {
                parts[parts.count - 1] = .text(existing + text)
            } else {
                parts.append(.text(text))
            }
        case .toolCall(let call):
            parts.append(.toolCall(call))
        case .usage, .finish:
            break
        }
    }
}

// MARK: - State

private actor State {

    private(set) var configuration: OpenAIBackendConfig
    private let session: URLSession

    private var systemInstruction = ""
    private var tools: [ToolDeclaration] = []
    private(set) var history: [ChatTurn] = []

    init(configuration: OpenAIBackendConfig, session: URLSession) {
        self.configuration = configuration
        self.session = session
    }

    func configure(systemInstruction: String,
                   tools: [ToolDeclaration],
                   history: [ChatTurn]) {
        self.systemInstruction = systemInstruction
        self.tools = tools
        self.history = history
    }

    func setModel(_ model: OpenAIModel) {
        configuration.model = model
    }

    /// Appends the turn only once it succeeded. The input turn carries the user
    /// role even when it holds tool results — that is the same convention
    /// `TurnRole` documents, and `openAIMessages` splits them back out.
    func commit(input: TurnInput, modelParts: [TurnPart]) {
        history.append(ChatTurn(role: .user, parts: input.parts))
        guard !modelParts.isEmpty else { return }
        history.append(ChatTurn(role: .model, parts: modelParts))
    }

    func send(_ input: TurnInput) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard !input.parts.isEmpty else { throw OpenAIBackendError.emptyTurn }

        let turns = history + [ChatTurn(role: .user, parts: input.parts)]
        var body: [String: ChatValue] = [
            "model": .string(configuration.model.rawValue),
            "messages": .array(turns.openAIMessages(systemInstruction: systemInstruction)),
            "stream": .bool(true),
        ]

        if !tools.isEmpty {
            body["tools"] = .array(tools.map(\.openAIDeclaration))
        }
        if let temperature = configuration.temperature {
            body["temperature"] = .number(temperature)
        }
        if let maxTokens = configuration.maxCompletionTokens {
            body["max_completion_tokens"] = .number(Double(maxTokens))
        }
        if configuration.includeUsage {
            body["stream_options"] = ["include_usage": true]
        }
        // Host overrides land last so they can correct anything above.
        body.merge(configuration.extraBody) { _, override in override }

        var request = URLRequest(url: configuration.completionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(ChatValue.object(body))

        return try await session.bytes(for: request)
    }

    /// Drains the body on a non-2xx response to recover the server's message.
    /// The stream is unusable past this point either way.
    static func checkStatus(of response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }

        var text = ""
        for try await line in bytes.lines {
            text += line
            // Enough to carry any real error message; a server answering an
            // error with megabytes is not worth reading to the end.
            if text.count > 8_192 { break }
        }

        let decoded = text.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: $0) }
        throw OpenAIBackendError.http(
            status: http.statusCode,
            message: decoded?.error?.message ?? (text.isEmpty ? nil : text))
    }
}

// MARK: - Errors

public enum OpenAIBackendError: LocalizedError {
    /// A turn with nothing sendable in it. Reaching the network with this would
    /// return a 400, so it is caught here where the cause is still legible.
    case emptyTurn
    case http(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .emptyTurn:
            return "The turn had no content to send."
        case .http(let status, let message):
            guard let message, !message.isEmpty else {
                return "The server returned HTTP \(status)."
            }
            return "The server returned HTTP \(status): \(message)"
        }
    }
}
