//
//  EchoBackend.swift
//  ChatDemo
//
//  A `ChatBackend` with no network behind it, so the demo runs with no Firebase
//  project configured. It also shows how small the backend seam is: streaming
//  text, calling a tool and finishing is the whole contract.
//

import Foundation
import ChatCore

actor EchoBackend: ChatBackend {

    private(set) var history: [ChatTurn] = []
    let modelName = "echo"

    private var tools: [ToolDeclaration] = []

    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {
        self.tools = tools
        self.history = history
    }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let reply = await self.reply(to: input)

                // Emitted a word at a time so the throttling in `StreamingTextView`
                // has something to actually throttle.
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try? await Task.sleep(for: .milliseconds(30))
                    continuation.yield(.text(String(word) + " "))
                }
                continuation.yield(.usage(.zero))
                continuation.yield(.finish(.stop))
                continuation.finish()
            }
        }
    }

    private func reply(to input: TurnInput) -> String {
        history.append(ChatTurn(role: .user, parts: input.parts))

        let prompt = input.parts.compactMap {
            if case .text(let text) = $0 { return text } else { return nil }
        }.joined(separator: " ")

        let listing = tools.isEmpty
            ? "_No tools are configured._"
            : tools.prefix(8).map { "- `\($0.name)`" }.joined(separator: "\n")

        return """
        You said: **\(prompt)**

        There is no model behind this demo — it echoes so the UI can be driven
        without a Firebase project. Swap in `GeminiBackend` for a real one.

        Tools the session offered me:

        \(listing)

        ```swift
        let session = ChatSession(configuration: .init(backend: GeminiBackend()))
        session.send("Hello")
        ```
        """
    }
}
