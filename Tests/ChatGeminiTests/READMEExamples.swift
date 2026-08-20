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
