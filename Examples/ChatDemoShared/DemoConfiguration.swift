//
//  DemoConfiguration.swift
//  ChatDemo
//
//  What the user picks on first launch. There is no fallback backend: an
//  unconfigured demo talking to a canned echo would prove nothing about the
//  package, so the app asks and waits.
//
//  The API key is deliberately *not* a property of this type — it goes to the
//  Keychain, and the rest goes to `UserDefaults`. A key compiled into a shipped
//  app is a key that has already leaked.
//

import Foundation
import ChatGemini
import ChatOpenAI

struct DemoConfiguration: Codable, Equatable, Sendable {

    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case openAI
        case gemini

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openAI: "OpenAI-compatible"
            case .gemini: "Gemini (Firebase)"
            }
        }
    }

    var kind: Kind = .openAI

    /// Root of the API, up to but not including `chat/completions`. Any
    /// compatible server: OpenAI itself, OpenRouter, a gateway, a local vLLM.
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = OpenAIModel.gpt4oMini.rawValue

    /// Vertex AI region. `"global"` routes to the nearest available capacity.
    var location: String = "global"
    var enableGoogleSearch: Bool = true

    /// Some gateways want their own caller-attribution fields rather than
    /// OpenAI's `user`. Both are optional and are sent via `extraBody`.
    var userID: String = ""
    var email: String = ""

    // MARK: - Validity

    /// Gemini reads its project from a `GoogleService-Info.plist` in the app
    /// bundle, so it cannot be offered when the target does not ship one.
    static let hasFirebasePlist = Bundle.main.url(forResource: "GoogleService-Info",
                                                  withExtension: "plist") != nil

    /// The API key is passed in rather than stored, because the caller holds
    /// the live text while the sheet is open and the Keychain copy afterwards.
    func isComplete(apiKey: String) -> Bool {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

        switch kind {
        case .openAI:
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme != nil else { return false }
            // An empty key is legitimate — that is what an unauthenticated
            // local server wants — so it is not part of completeness.
            return true

        case .gemini:
            return Self.hasFirebasePlist
        }
    }

    /// Default kind on a fresh install: whichever one this build could possibly
    /// use without further setup.
    static var initial: DemoConfiguration {
        var configuration = DemoConfiguration()
        if hasFirebasePlist {
            configuration.kind = .gemini
            configuration.model = GeminiModel.gemini3_5Flash.rawValue
        }
        return configuration
    }
}
