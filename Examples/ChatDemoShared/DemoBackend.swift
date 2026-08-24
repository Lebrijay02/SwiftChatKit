//
//  DemoBackend.swift
//  ChatDemo
//
//  Turning a `DemoConfiguration` into the one thing `ChatSession` actually
//  needs. Both branches are a single initializer — that is the whole backend
//  seam, and the reason a host can swap providers without touching the engine.
//

import Foundation
import ChatCore
import ChatGemini
import ChatOpenAI
import FirebaseCore

enum DemoBackend {

    static func make(_ configuration: DemoConfiguration, apiKey: String) -> (any ChatBackend)? {
        switch configuration.kind {
        case .openAI:
            return openAICompatible(configuration, apiKey: apiKey)
        case .gemini:
            return gemini(configuration)
        }
    }

    private static func openAICompatible(_ configuration: DemoConfiguration,
                                         apiKey: String) -> (any ChatBackend)? {
        var extraBody: [String: ChatValue] = [:]
        if !configuration.userID.isEmpty { extraBody["user_id"] = .string(configuration.userID) }
        if !configuration.email.isEmpty { extraBody["email"] = .string(configuration.email) }

        guard let backendConfiguration = OpenAIBackendConfig(
            baseURL: configuration.baseURL.trimmingCharacters(in: .whitespaces),
            apiKey: apiKey,
            model: OpenAIModel(configuration.model),
            extraBody: extraBody)
        else { return nil }

        return OpenAIBackend(backendConfiguration)
    }

    /// Firebase reads the project out of the bundled plist, so there is nothing
    /// to configure here beyond the model. Configuring twice throws, hence the
    /// check — the sheet can be reopened and the session rebuilt.
    private static func gemini(_ configuration: DemoConfiguration) -> (any ChatBackend)? {
        guard DemoConfiguration.hasFirebasePlist else { return nil }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }

        return GeminiBackend(GeminiBackendConfig(
            model: GeminiModel(configuration.model),
            location: configuration.location,
            enableGoogleSearch: configuration.enableGoogleSearch))
    }
}
