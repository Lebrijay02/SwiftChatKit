//
//  GeminiModel.swift
//  SwiftChatKit
//
//  Model identifiers available through Firebase AI Logic.
//
//  A struct of static constants rather than an enum: Google ships new model IDs
//  faster than this package ships releases, and a host must be able to pass one
//  that didn't exist when it was compiled.
//

import Foundation

public struct GeminiModel: RawRepresentable, Hashable, Sendable, Codable {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let gemini3_5Flash    = GeminiModel("gemini-3.5-flash")
    public static let gemini3_1Pro      = GeminiModel("gemini-3.1-pro-preview")
    public static let gemini3_1FlashLite = GeminiModel("gemini-3.1-flash-lite")
    public static let gemini3Flash      = GeminiModel("gemini-3-flash-preview")
    public static let gemini2_5Pro      = GeminiModel("gemini-2.5-pro")
    public static let gemini2_5Flash    = GeminiModel("gemini-2.5-flash")
    public static let gemini2_5FlashLite = GeminiModel("gemini-2.5-flash-lite")

    /// The models this package knows a display name for. A `GeminiModel` built
    /// from an unknown string is still valid — it just isn't in this list.
    public static let known: [GeminiModel] = [
        .gemini3_5Flash, .gemini3_1Pro, .gemini3_1FlashLite, .gemini3Flash,
        .gemini2_5Pro, .gemini2_5Flash, .gemini2_5FlashLite,
    ]

    /// Title-cased name for a model picker. Derived for unknown IDs rather than
    /// falling back to a placeholder, so a newly released model still reads well.
    public var displayName: String {
        switch self {
        case .gemini3_5Flash:     return "Gemini 3.5 Flash"
        case .gemini3_1Pro:       return "Gemini 3.1 Pro"
        case .gemini3_1FlashLite: return "Gemini 3.1 Flash-Lite"
        case .gemini3Flash:       return "Gemini 3 Flash"
        case .gemini2_5Pro:       return "Gemini 2.5 Pro"
        case .gemini2_5Flash:     return "Gemini 2.5 Flash"
        case .gemini2_5FlashLite: return "Gemini 2.5 Flash-Lite"
        default:
            return rawValue
                .replacingOccurrences(of: "-preview", with: "")
                .split(separator: "-")
                .map { $0.count <= 2 ? $0.uppercased() : $0.capitalized }
                .joined(separator: " ")
        }
    }
}

// MARK: - Configuration

public struct GeminiBackendConfig: Sendable {

    public var model: GeminiModel
    /// Vertex AI region. `"global"` routes to the nearest available capacity and
    /// is the right default for everything but data-residency requirements.
    public var location: String
    /// Offers the built-in Google Search tool alongside the declared functions.
    public var enableGoogleSearch: Bool

    public init(model: GeminiModel = .gemini3_5Flash,
                location: String = "global",
                enableGoogleSearch: Bool = true) {
        self.model = model
        self.location = location
        self.enableGoogleSearch = enableGoogleSearch
    }
}
