//
//  TodoListPanelView.swift
//  SwiftChatKit
//
//  The agent's task list. Collapsed it shows only the task in progress, which is
//  the one thing worth a line of chrome while a long turn runs.
//

import SwiftUI
import ChatCore

public struct TodoListPanelView: View {

    @Environment(\.chatPalette) private var palette
    @State private var isExpanded = false

    public let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }

    private var doneCount: Int { todos.filter { $0.status == .completed }.count }
    private var currentItem: TodoItem? { todos.first { $0.status == .inProgress } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .foregroundStyle(palette.accent)
                    if isExpanded || currentItem == nil {
                        Text("Tasks (\(doneCount)/\(todos.count))")
                    } else {
                        Text(currentItem!.content).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .foregroundStyle(palette.secondaryText)
                }
                .foregroundStyle(palette.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(todos) { todo in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: icon(for: todo.status))
                                .foregroundStyle(color(for: todo.status))
                                .frame(width: 14)
                            Text(todo.content)
                                .strikethrough(todo.status == .completed)
                                .foregroundStyle(todo.status == .completed
                                                 ? palette.secondaryText : palette.primaryText)
                                .fontWeight(todo.status == .inProgress ? .semibold : .regular)
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 2)
            }
        }
        .font(.footnote)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)
                .stroke(palette.outline)
        )
    }

    private func icon(for status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return palette.secondaryText
        case .inProgress: return palette.accent
        case .completed: return .green
        }
    }
}
