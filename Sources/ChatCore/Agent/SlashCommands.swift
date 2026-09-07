//
//  SlashCommands.swift
//  SwiftChatKit
//
//  Leading-slash input the session answers itself instead of sending to the
//  model: /clear, /compact, /plan, /help, plus whatever the host registers.
//
//  A command reports what it wants done rather than doing it, so a host can add
//  one without a reference back to the session — the same reason `ToolProvider`
//  returns a `ToolResult` instead of mutating the transcript.
//

import Foundation

// MARK: - Action

/// What the session should do once a command has been read. Anything a command
/// needs that isn't here belongs in its own closure, not in this enum — the
/// cases are the session's own state, which a host cannot reach directly.
public enum SlashCommandAction: Equatable, Sendable {

    /// The host handled it. Nothing is appended and no run starts.
    case none

    /// Show `text` to the user without telling the model. Command feedback is
    /// not conversation: replaying it would have the model answer for it.
    case note(String)

    /// Start a run with `text` as the prompt. The transcript shows whatever the
    /// user typed, not this — a skill's whole body is not something to read back.
    case prompt(String)

    /// Wipe the conversation, including its saved transcript.
    case clear

    /// Summarize and restart, freeing context while keeping continuity.
    case compact

    /// Save the current conversation and open an empty one.
    case newChat

    case setPlanMode(Bool)
    case togglePlanMode
}

// MARK: - Command

/// Everything a command handler is allowed to see. A snapshot rather than the
/// live session: a handler that could mutate mid-parse would be reentrant on
/// the state the session is about to act on.
public struct SlashCommandContext: Sendable {
    /// Everything after the command name, whitespace-trimmed. Empty when none.
    public let arguments: String
    /// The full line as typed, leading slash included.
    public let rawInput: String
    public let workingDirectory: URL?
    public let planMode: Bool

    public init(arguments: String, rawInput: String, workingDirectory: URL?, planMode: Bool) {
        self.arguments = arguments
        self.rawInput = rawInput
        self.workingDirectory = workingDirectory
        self.planMode = planMode
    }
}

public struct SlashCommand: Identifiable, Sendable {

    /// Without the leading slash. Matched case-insensitively.
    public let name: String
    /// One line, shown by `/help` and when an unknown command is typed.
    public let summary: String
    public let handler: @MainActor @Sendable (SlashCommandContext) -> SlashCommandAction

    public var id: String { name }

    public init(name: String,
                summary: String,
                handler: @escaping @MainActor @Sendable (SlashCommandContext) -> SlashCommandAction) {
        self.name = name
        self.summary = summary
        self.handler = handler
    }
}

// MARK: - Configuration

/// The commands the session answers. Built-ins are opt-in by name so a host that
/// wants `/clear` but not `/compact` doesn't have to reimplement either, and a
/// host that wants neither gets a chat where `/` is just a character.
public struct SlashCommandsConfiguration: Sendable {

    public enum BuiltIn: String, CaseIterable, Sendable {
        case clear
        case compact
        case plan
        case newChat = "new"
        case help

        var summary: String {
            switch self {
            case .clear:   return "Delete this conversation and start over"
            case .compact: return "Summarize the conversation to free up context"
            case .plan:    return "Toggle plan mode: research and propose before changing anything"
            case .newChat: return "Save this conversation and open a new one"
            case .help:    return "List the available commands"
            }
        }
    }

    public var builtIns: Set<BuiltIn>
    /// Consulted before the built-ins, so a host can replace `/compact` with its
    /// own by registering that name rather than by disabling anything.
    public var custom: [SlashCommand]
    /// Whether an installed skill can be invoked as `/skill-name [args]`.
    /// Matched only after commands, so a skill cannot shadow `/clear`.
    public var skillsAsCommands: Bool

    public init(builtIns: Set<BuiltIn> = [],
                custom: [SlashCommand] = [],
                skillsAsCommands: Bool = false) {
        self.builtIns = builtIns
        self.custom = custom
        self.skillsAsCommands = skillsAsCommands
    }

    /// No commands at all: a session that ships nothing it wasn't asked for.
    public static let disabled = SlashCommandsConfiguration()

    /// Every built-in, plus skills as commands.
    public static let standard = SlashCommandsConfiguration(
        builtIns: Set(BuiltIn.allCases), skillsAsCommands: true)

    public var isEnabled: Bool {
        !builtIns.isEmpty || !custom.isEmpty || skillsAsCommands
    }
}

// MARK: - Parsing

public enum SlashCommandParser {

    /// Splits `/name rest` into its parts, or nil when `text` isn't a command.
    ///
    /// A bare "/" and a leading "//" are both rejected: the first is a typo and
    /// the second is a path, and treating either as a command name would swallow
    /// input the model should have seen.
    public static func parse(_ text: String) -> (name: String, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else { return nil }

        let body = trimmed.dropFirst()
        guard let first = body.first, !first.isWhitespace else { return nil }

        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let arguments = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (name, arguments)
    }
}
