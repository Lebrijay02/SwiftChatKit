//
//  READMEExamples.swift
//  SwiftChatKitTests
//
//  Every ChatUI snippet in README.md, compiled. Docs that no longer build are
//  docs that lie, and this target is what catches that.
//

import SwiftUI
import Testing
import ChatCore
import ChatUI

@Suite("README — ChatUI examples")
@MainActor
struct ChatUIREADMEExamples {

    @Test("Rendering a message and theming the renderer")
    func transcript() {
        let view = TranscriptExample(messages: [.assistant("Hello **world**")])
        #expect(view.messages.count == 1)
    }

    @Test("A custom palette")
    func palette() {
        let palette = ChatPalette(
            accent: .blue,
            background: Color(white: 0.1),
            codeBackground: Color(white: 0.16),
            header: Color(white: 0.2),
            divider: Color(white: 0.3),
            outline: Color(white: 0.3),
            primaryText: .white,
            secondaryText: Color(white: 0.65))

        let style = MarkdownStyle.from(palette: palette, appearanceIsDark: true)
        #expect(style.bodyFontSize > 0)
    }

    @Test("Rendering Markdown outside SwiftUI")
    func headlessRender() {
        let style = MarkdownStyle.from(palette: .default, appearanceIsDark: false)
        let blocks = MarkdownBlockParser.parse("# Title\n\nBody")
        let result = MarkdownAttributedBuilder.build(blocks, style: style)

        #expect(result.attributed.string.contains("Title"))
    }

    @Test("The agent cards")
    func agentCards() {
        let permissions = PermissionService()
        let request = PermissionRequest(toolName: "writeFile",
                                        title: "Write notes.md",
                                        detail: "hello")
        _ = PermissionRequestView(request: request, permissions: permissions)
        _ = TodoListPanelView(todos: [TodoItem(content: "Ship it", status: .inProgress)])
        _ = QuestionCardView(questions: [], service: QuestionService(), assistantName: "Ada")
    }

    @Test("Auto-scroll follows until the reader scrolls away")
    func autoScroll() {
        let controller = ChatAutoScrollController()
        #expect(controller.isFollowing)

        controller.reportDistanceFromBottom(600)
        controller.userDidScroll()
        #expect(!controller.isFollowing)
        #expect(controller.isAwayFromBottom)
    }
}

/// The transcript sketch from the README's ChatUI section.
private struct TranscriptExample: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { message in
                    StreamingTextView(text: message.content)
                }
            }
            .padding()
        }
        .chatPalette(.default)
    }
}
