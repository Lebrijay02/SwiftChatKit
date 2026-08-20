//
//  TodoItem.swift
//  SwiftChatKit
//
//  The visible checklist the model maintains for a multi-step job.
//

import Foundation

public struct TodoItem: Identifiable, Sendable, Codable {

    public enum Status: String, Sendable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public let id: UUID
    public var content: String
    public var status: Status

    public init(id: UUID = UUID(), content: String, status: Status = .pending) {
        self.id = id
        self.content = content
        self.status = status
    }
}

/// Identity is deliberately excluded. `todoWrite` sends the whole list every
/// time, so ids are regenerated on each call — comparing them would report a
/// change on every write and defeat the point of diffing.
extension TodoItem: Equatable {
    public static func == (lhs: TodoItem, rhs: TodoItem) -> Bool {
        lhs.content == rhs.content && lhs.status == rhs.status
    }
}

public extension Array where Element == TodoItem {

    /// The one item a well-behaved model marks in progress, if any.
    var inProgress: TodoItem? { first { $0.status == .inProgress } }

    var completedCount: Int { lazy.filter { $0.status == .completed }.count }

    /// Parses the `todos` argument of a `todoWrite` call. Items with an
    /// unrecognized status fall back to `.pending` rather than being dropped —
    /// losing a step silently is worse than mislabelling one.
    static func parse(_ arguments: [String: ChatValue]) -> [TodoItem]? {
        guard let items = arguments["todos"]?.arrayValue else { return nil }
        return items.compactMap { item in
            guard let content = item["content"]?.stringValue else { return nil }
            let status = item["status"]?.stringValue.flatMap(TodoItem.Status.init(rawValue:))
            return TodoItem(content: content, status: status ?? .pending)
        }
    }
}
