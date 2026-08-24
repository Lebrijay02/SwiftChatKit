//
//  ChatView.swift
//  ChatDemoiOS
//
//  The whole UI: read `session.messages`, render them, call `send` and `stop`.
//

import SwiftUI
import ChatCore
import ChatUI

struct ChatView: View {

    let session: ChatSession
    let onConfigure: () -> Void

    @State private var draft = ""
    @State private var autoScroll = ChatAutoScrollController()
    @FocusState private var composerFocused: Bool

    private static let bottomAnchor = "bottom"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                errorLabel
                composer
            }
            .navigationTitle(session.title.isEmpty ? "Chat" : session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Backend", systemImage: "gearshape", action: onConfigure)
                        .disabled(session.isStreaming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New", systemImage: "square.and.pencil") {
                        session.newChat()
                    }
                    .disabled(session.isStreaming)
                }
            }
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

        case .toolCall, .toolResult:
            // No tool providers are configured, so these never arrive.
            EmptyView()
        }
    }

    // MARK: - Error

    @ViewBuilder
    private var errorLabel: some View {
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
