//
//  QuestionService.swift
//  SwiftChatKit
//
//  Structured questions back to the user. The agent loop suspends on `request`
//  while a question card is shown, mirroring PermissionService's continuation
//  pattern, and resumes with the answers.
//
//  This is how a model asks for a decision it cannot make on its own without
//  guessing — a wrong guess costs a whole turn of wasted work.
//

import Foundation

// MARK: - Models

public struct UserQuestionOption: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let label: String
    public let description: String

    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}

public struct UserQuestion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    /// Short category label shown above the question, e.g. "Backend".
    public let header: String
    /// Offered choices. May be empty, in which case the host should collect
    /// free-form text.
    public let options: [UserQuestionOption]
    public let multiSelect: Bool

    public init(id: UUID = UUID(),
                question: String,
                header: String = "",
                options: [UserQuestionOption] = [],
                multiSelect: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

// MARK: - Service

@MainActor
@Observable
public final class QuestionService {

    /// Questions awaiting answers. Non-nil means the agent loop is parked.
    public private(set) var pending: [UserQuestion]?

    private var continuation: CheckedContinuation<[String: String]?, Never>?

    public init() {}

    /// Suspends until the host submits the question card. Answers are keyed by
    /// question text. Returns nil when the request was cancelled or dismissed,
    /// which the loop should treat as "the user declined to answer".
    public func request(_ questions: [UserQuestion]) async -> [String: String]? {
        // An unanswered previous batch would deadlock the loop.
        if continuation != nil { resolve(nil) }

        return await withCheckedContinuation { cont in
            continuation = cont
            pending = questions
        }
    }

    /// Called by the question card's submit button.
    public func resolve(_ answers: [String: String]?) {
        pending = nil
        continuation?.resume(returning: answers)
        continuation = nil
    }

    /// Dismisses anything pending unanswered — used when the user stops streaming.
    public func cancelPending() {
        guard continuation != nil else { return }
        resolve(nil)
    }

    // MARK: - Tool argument parsing

    /// Maximum questions accepted from one tool call. More than this stops being
    /// a clarification and becomes an interrogation.
    public nonisolated static let maxQuestions = 4

    /// Builds questions from the `askUser` tool's arguments. Returns nil when the
    /// payload is unusable, so the loop can report a tool error instead of
    /// showing an empty card.
    public nonisolated static func parse(_ arguments: [String: ChatValue]) -> [UserQuestion]? {
        guard let items = arguments["questions"]?.arrayValue else { return nil }

        let questions: [UserQuestion] = items.prefix(maxQuestions).compactMap { item in
            guard let text = item["question"]?.stringValue else { return nil }

            let options = (item["options"]?.arrayValue ?? []).compactMap { opt -> UserQuestionOption? in
                guard let label = opt["label"]?.stringValue else { return nil }
                return UserQuestionOption(label: label,
                                          description: opt["description"]?.stringValue ?? "")
            }

            return UserQuestion(question: text,
                                header: item["header"]?.stringValue ?? "",
                                options: options,
                                multiSelect: item["multiSelect"]?.boolValue ?? false)
        }

        return questions.isEmpty ? nil : questions
    }
}
