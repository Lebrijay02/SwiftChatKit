//
//  READMEExamples.swift
//  SwiftChatKit
//
//  Compile-check for the README's ChatOpenAI samples. Imports the modules the
//  way a consumer does — no `@testable` — so a sample that stops compiling
//  breaks the build rather than quietly rotting in the docs.
//
//  Nothing here is executed: the calls would need a reachable server and a key.
//  Compiling is the whole assertion.
//

import Foundation
import ChatCore
import ChatOpenAI

private func readmeOpenAIBackend(key: String) async throws {
    let backend = OpenAIBackend(OpenAIBackendConfig(
        baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        apiKey: key,
        model: OpenAIModel("anthropic/claude-sonnet-4.5")))

    await backend.configure(
        systemInstruction: SystemPromptBuilder.build(SystemPromptContext()),
        tools: [ToolDeclaration(name: "readFile", description: "Reads a file.",
                                parameters: ["path": .string()])],
        history: [])

    for try await chunk in backend.stream(.message("What changed in this file?")) {
        _ = chunk
    }

    _ = await backend.history
    _ = await backend.modelName
}

private func readmeOpenAIConvenience(key: String) {
    _ = OpenAIBackend(apiKey: key, model: .gpt5)
}

private enum ConfigResult { case invalidEndpoint, ok }

private func readmeFailableConfig(userTypedURL: String,
                                  userTypedModel: String,
                                  key: String) -> ConfigResult {
    guard let config = OpenAIBackendConfig(baseURL: userTypedURL, apiKey: key,
                                           model: OpenAIModel(userTypedModel))
    else { return .invalidEndpoint }
    _ = config
    return .ok
}

private func readmeOpenAIModels(backend: OpenAIBackend) async {
    _ = OpenAIModel.known
    _ = OpenAIModel("qwen3-coder:30b")
    await backend.setModel(.gpt4oMini)
}

/// The configuration table in the README, as fields that must keep existing.
private func readmeOpenAIConfiguration(key: String) {
    var config = OpenAIBackendConfig.openAI(apiKey: key)
    config.temperature = 0.2
    config.maxCompletionTokens = 4_096
    config.includeUsage = false
    config.extraBody = ["reasoning_effort": .string("low")]
    config.extraHeaders = ["X-Title": "MyApp"]
    config.timeout = 120
}
