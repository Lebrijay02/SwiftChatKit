//
//  ChatDemoView.swift
//  ChatDemo
//
//  The whole UI: read `session.messages`, render them, call `send` and `stop`.
//  The agent cards below are the engine asking the user something mid-turn.
//

import SwiftUI
import ChatCore
import ChatUI

struct ChatDemoView: View {

    let session: ChatSession

    @State private var draft = ""
    @State private var autoScroll = ChatAutoScrollController()

    private static let bottomAnchor = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            cards
            composer
        }
        .chatPalette(.default)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        row(message)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding()
                .background(ManualScrollReporter { autoScroll.userDidScroll() })
            }
            .onChange(of: session.messages.last?.content) { _, _ in
                autoScroll.followStream(proxy, anchor: Self.bottomAnchor)
            }
            .onChange(of: session.messages.count) { _, _ in
                autoScroll.followEvent(proxy, anchor: Self.bottomAnchor)
            }
            .overlay(alignment: .bottom) {
                if autoScroll.isAwayFromBottom {
                    JumpToBottomButton {
                        autoScroll.jumpToBottom(proxy, anchor: Self.bottomAnchor)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.content)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            StreamingTextView(text: message.content)

        case .toolCall(let name), .toolResult(let name):
            // Tool traffic is part of the transcript, not hidden protocol chatter:
            // seeing which tool ran is most of what makes an agent legible.
            Label(name, systemImage: message.status == .incomplete
                  ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Agent cards

    @ViewBuilder
    private var cards: some View {
        if !session.todos.isEmpty {
            TodoListPanelView(todos: session.todos).padding([.horizontal, .top], 10)
        }
        if let request = session.permissions.pending {
            PermissionRequestView(request: request, permissions: session.permissions)
                .padding([.horizontal, .top], 10)
        }
        if let questions = session.questions.pending {
            QuestionCardView(questions: questions,
                             service: session.questions,
                             assistantName: "The demo")
                .padding([.horizontal, .top], 10)
        }
        if let error = session.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .padding([.horizontal, .top], 10)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit(send)

            Button(session.isStreaming ? "Stop" : "Send") {
                session.isStreaming ? session.stop() : send()
            }
            .disabled(!session.isStreaming && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        session.send(text)
    }
}
