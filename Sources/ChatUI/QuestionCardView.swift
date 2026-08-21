//
//  QuestionCardView.swift
//  SwiftChatKit
//
//  Interactive card for the askUser tool: renders the model's structured questions
//  with selectable options (plus a free-text "Other") and resumes the agent loop
//  through QuestionService on submit. Visual language mirrors PermissionRequestView.
//

import SwiftUI
import ChatCore

public struct QuestionCardView: View {

    @Environment(\.chatPalette) private var palette

    public let questions: [UserQuestion]
    public let service: QuestionService
    /// What to call the assistant in the card's title. The package has no product
    /// name of its own, so the host supplies one.
    public let assistantName: String

    /// Chosen option labels per question (a set to support multiSelect).
    @State private var selected: [UUID: Set<String>] = [:]
    /// Free-text "Other" answer per question; combines with option choices.
    @State private var otherText: [UUID: String] = [:]
    /// Questions are paged one at a time so the card fits on screen.
    @State private var currentIndex = 0

    public init(questions: [UserQuestion],
                service: QuestionService,
                assistantName: String = "The assistant") {
        self.questions = questions
        self.service = service
        self.assistantName = assistantName
    }

    private var allAnswered: Bool { questions.allSatisfy { answer(for: $0) != nil } }
    private var isLastQuestion: Bool { currentIndex >= questions.count - 1 }
    private var currentAnswered: Bool {
        guard questions.indices.contains(currentIndex) else { return false }
        return answer(for: questions[currentIndex]) != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                Text("\(assistantName) has \(questions.count == 1 ? "a question" : "questions")")
                    .fontWeight(.semibold)
                Spacer()
                if questions.count > 1 {
                    Text("\(currentIndex + 1) of \(questions.count)")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if questions.indices.contains(currentIndex) {
                questionSection(questions[currentIndex])
            }

            HStack(spacing: 8) {
                if questions.count > 1 && currentIndex > 0 {
                    actionButton("Back") { withAnimation { currentIndex -= 1 } }
                }

                if isLastQuestion {
                    actionButton("Submit", prominent: true) {
                        var answers: [String: String] = [:]
                        for question in questions {
                            answers[question.question] = answer(for: question) ?? ""
                        }
                        service.resolve(answers)
                    }
                    .disabled(!allAnswered)
                    .opacity(allAnswered ? 1 : 0.5)
                } else {
                    actionButton("Next", prominent: true) {
                        withAnimation { currentIndex += 1 }
                    }
                    .disabled(!currentAnswered)
                    .opacity(currentAnswered ? 1 : 0.5)
                }

                // Dismissing answers nothing; the loop resumes and the model is told
                // the user declined rather than being left waiting.
                actionButton("Dismiss") { service.resolve(nil) }
                Spacer()
            }
        }
        .font(.footnote)
        .foregroundStyle(palette.primaryText)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)
                .stroke(palette.outline)
        )
    }

    // MARK: - Per-question section

    private func questionSection(_ question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.accent.opacity(0.18)))
                        .foregroundStyle(palette.accent)
                }
                if question.multiSelect {
                    Text("select all that apply")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            Text(question.question).fontWeight(.medium)

            ForEach(question.options) { option in
                optionRow(option, for: question)
            }

            TextField("Other…", text: otherBinding(for: question))
                .textFieldStyle(.plain)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.codeBackground.opacity(0.6))
                )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(palette.codeBackground.opacity(0.35))
        )
    }

    private func optionRow(_ option: UserQuestionOption, for question: UserQuestion) -> some View {
        let isSelected = selected[question.id, default: []].contains(option.label)
        return Button {
            toggle(option, for: question)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .foregroundStyle(palette.primaryText)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Answer state

    private func toggle(_ option: UserQuestionOption, for question: UserQuestion) {
        var set = selected[question.id, default: []]
        if question.multiSelect {
            if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
        } else {
            set = set.contains(option.label) ? [] : [option.label]
        }
        selected[question.id] = set
    }

    private func otherBinding(for question: UserQuestion) -> Binding<String> {
        Binding(get: { otherText[question.id] ?? "" },
                set: { otherText[question.id] = $0 })
    }

    /// The final answer string for a question, or nil when unanswered. Free text
    /// and option picks combine; free text alone is also valid.
    func answer(for question: UserQuestion) -> String? {
        let picks = question.options
            .map(\.label)
            .filter { selected[question.id, default: []].contains($0) }
        let custom = (otherText[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (picks.isEmpty, custom.isEmpty) {
        case (false, false): return "\(picks.joined(separator: ", ")) — \(custom)"
        case (false, true):  return picks.joined(separator: ", ")
        case (true, false):  return custom
        case (true, true):   return nil
        }
    }

    private func actionButton(_ label: String,
                              prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(prominent ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent ? palette.accent.opacity(0.9)
                                        : palette.codeBackground.opacity(0.8))
                )
                .foregroundStyle(prominent ? Color.white : palette.primaryText)
        }
        .buttonStyle(.plain)
    }
}
