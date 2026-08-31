//
//  ChatView.swift
//  ChatDemoiOS
//
//  The whole UI: read `session.messages`, render them, call `send` and `stop`.
//  The agent cards below are the engine asking the user something mid-turn —
//  MCP tools can prompt for approval same as any other, even with no file or
//  shell tools installed.
//

import SwiftUI
import ChatCore
import ChatUI

struct ChatView: View {

    let session: ChatSession
    let onConfigure: () -> Void
    let onShowHistory: () -> Void
    let onShowSettings: () -> Void

    @State private var draft = ""
    @State private var autoScroll = ChatAutoScrollController()
    @FocusState private var composerFocused: Bool

    private static let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                cards
                composer
            }
            .navigationTitle(session.title.isEmpty ? "Chat" : session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Backend", systemImage: "gearshape", action: onConfigure)
                        Button("Settings", systemImage: "puzzlepiece.extension", action: onShowSettings)
                        Button("History", systemImage: "clock", action: onShowHistory)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(session.isStreaming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Plan mode", systemImage: session.planMode ? "hammer.fill" : "hammer") {
                        session.setPlanMode(!session.planMode)
                    }
                    .disabled(session.isStreaming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New", systemImage: "square.and.pencil") {
                        session.save()
                        session.newChat()
                    }
                    .disabled(session.isStreaming)
                }
            }
        }
        .chatPalette(.default)
        // Persists whatever landed in the transcript once a run settles,
        // whether it finished, was stopped, or hit the turn cap.
        .onChange(of: session.isStreaming) { wasStreaming, isStreaming in
            if wasStreaming, !isStreaming { session.save() }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        row(message)
                    }
                    // `isThinking` covers the silent stretch — request out, no
                    // text yet. Once tokens arrive it flips false and the second
                    // indicator takes over, so the transcript never goes quiet
                    // until the run actually ends.
                    if session.isThinking {
                        ThinkingIndicatorView()
                    } else if session.isStreaming {
                        ThinkingIndicatorView(label: "Responding…")
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding()
            }
            // `ManualScrollReporter` watches scroll-wheel events and is AppKit
            // only; on iOS a drag is the equivalent signal.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1).onChanged { _ in
                    autoScroll.userDidScroll()
                })
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.isThinking) { _, _ in
                autoScroll.followEvent(proxy, anchor: Self.bottomAnchor)
            }
            .onChange(of: session.isStreaming) { _, _ in
                autoScroll.followEvent(proxy, anchor: Self.bottomAnchor)
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
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .assistant:
            StreamingTextView(text: message.content)

        case .toolCall(let name), .toolResult(let name):
            // MCP tools arrive on both platforms; the file and shell tools
            // only on macOS. Either way, showing which tool ran is most of
            // what makes an agent legible.
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
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(.quaternary))

            Button {
                session.isStreaming ? session.stop() : send()
            } label: {
                Image(systemName: session.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title)
            }
            .disabled(!session.isStreaming && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
