//
//  OpenAIModel.swift
//  SwiftChatKit
//
//  Configuration for any server that speaks the OpenAI `/chat/completions`
//  wire format — OpenAI itself, but equally OpenRouter, Groq, Together,
//  vLLM, Ollama, LM Studio or a gateway of the host's own.
//
//  A struct of static constants rather than an enum: the whole point of this
//  backend is that the model list is open, so a host must be able to pass an
//  identifier this package has never heard of.
//

import Foundation

public struct OpenAIModel: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let gpt5 = OpenAIModel("gpt-5")
    public static let gpt5Mini = OpenAIModel("gpt-5-mini")
    public static let gpt4o = OpenAIModel("gpt-4o")
    public static let gpt4oMini = OpenAIModel("gpt-4o-mini")
    public static let gpt4Turbo = OpenAIModel("gpt-4-turbo")

    /// The models this package knows a display name for. An `OpenAIModel` built
    /// from an unknown string is still valid — it just isn't in this list, and
    /// for third-party servers it usually won't be.
    public static let known: [OpenAIModel] = [
        .gpt5, .gpt5Mini, .gpt4o, .gpt4oMini, .gpt4Turbo,
    ]

    /// Title-cased identifier, used by the UI's model picker.
    public var displayName: String {
        rawValue
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.count <= 3 ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }
}

// MARK: - Configuration

public struct OpenAIBackendConfig: Sendable {

    /// Root of the API, up to but not including `chat/completions`. Trailing
    /// slashes are tolerated. Point this at any compatible server.
    public var baseURL: URL

    /// Sent as `Authorization: Bearer`. Empty is allowed and sends no header,
    /// which is what unauthenticated local servers want.
    ///
    /// Read this from the Keychain or a server-side proxy. A key compiled into
    /// a shipped app is a key that has already leaked.
    public var apiKey: String

    public var model: OpenAIModel

    /// Nil leaves the parameter out entirely, so the server's own default
    /// applies. Some compatible servers reject values they don't implement.
    public var temperature: Double?
    public var maxCompletionTokens: Int?

    /// Asks for a final usage-only chunk. Off for servers that reject the
    /// `stream_options` parameter outright rather than ignoring it.
    public var includeUsage: Bool

    /// Merged into every request body, last write wins over the keys this
    /// backend sets. The escape hatch for provider-specific parameters —
    /// OpenRouter routing, vLLM sampling knobs, reasoning effort.
    public var extraBody: [String: ChatValue]

    /// Merged into every request's headers. `HTTP-Referer` and `X-Title` for
    /// OpenRouter, a tenant id for a gateway, and so on.
    public var extraHeaders: [String: String]

    /// Cap on one streaming request, measured end to end.
    public var timeout: TimeInterval

    public init(baseURL: URL,
                apiKey: String,
                model: OpenAIModel,
                temperature: Double? = nil,
                maxCompletionTokens: Int? = nil,
                includeUsage: Bool = true,
                extraBody: [String: ChatValue] = [:],
                extraHeaders: [String: String] = [:],
                timeout: TimeInterval = 300) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxCompletionTokens = maxCompletionTokens
        self.includeUsage = includeUsage
        self.extraBody = extraBody
        self.extraHeaders = extraHeaders
        self.timeout = timeout
    }

    /// Convenience for the common case of a string URL. Returns nil rather than
    /// trapping, since this value usually comes from user input or a config file.
    public init?(baseURL: String,
                 apiKey: String,
                 model: OpenAIModel,
                 temperature: Double? = nil,
                 maxCompletionTokens: Int? = nil,
                 includeUsage: Bool = true,
                 extraBody: [String: ChatValue] = [:],
                 extraHeaders: [String: String] = [:],
                 timeout: TimeInterval = 300) {
        guard let url = URL(string: baseURL), url.scheme != nil else { return nil }
        self.init(baseURL: url,
                  apiKey: apiKey,
                  model: model,
                  temperature: temperature,
                  maxCompletionTokens: maxCompletionTokens,
                  includeUsage: includeUsage,
                  extraBody: extraBody,
                  extraHeaders: extraHeaders,
                  timeout: timeout)
    }

    /// OpenAI's own endpoint, for the case where there is nothing to configure
    /// but a key and a model.
    public static func openAI(apiKey: String, model: OpenAIModel = .gpt5) -> OpenAIBackendConfig {
        OpenAIBackendConfig(baseURL: URL(string: "https://api.openai.com/v1")!,
                            apiKey: apiKey,
                            model: model)
    }

    /// `baseURL` with the chat-completions path appended, however the host
    /// spelled the root.
    var completionsURL: URL {
        var url = baseURL
        while url.path.hasSuffix("/") {
            url.deleteLastPathComponent()
        }
        // A host that already pointed at the endpoint gets it left alone rather
        // than doubled — pasting the full URL is the likelier mistake to make.
        guard !url.path.hasSuffix("/chat/completions") else { return url }
        return url.appendingPathComponent("chat/completions")
    }
}
