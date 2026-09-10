//
//  FileReadLedger.swift
//  SwiftChatKit
//
//  Remembers what the model has read, and what the file looked like when it
//  read it.
//
//  Without this a session that read a file, thought for two minutes, and then
//  wrote it back would silently discard whatever the user typed into Xcode in
//  between. The edit still looks like it applied — the diff is real, the tool
//  reports success — and the user's work is simply gone. Refusing the write and
//  making the model re-read costs one tool call.
//

import Foundation
import ChatCore

actor FileReadLedger {

    /// Filesystem timestamps are not exact to the nanosecond across a read and a
    /// later stat, so a hair of slack keeps an untouched file from reading as
    /// modified. Well under any interval a human edit could occupy.
    private static let tolerance: TimeInterval = 0.001

    private var seen: [String: Date?] = [:]

    /// Notes that the model now knows this file's contents as of `modifiedAt`.
    func record(_ resolvedPath: String, modifiedAt: Date?) {
        seen[resolvedPath] = modifiedAt
    }

    func forget(_ resolvedPath: String) {
        seen.removeValue(forKey: resolvedPath)
    }

    enum Verdict: Equatable {
        /// The model has read this file and it has not changed since.
        case fresh
        /// The model has never read this file in this session.
        case neverRead
        /// Something outside the session wrote to it after the model read it.
        case changedOnDisk
    }

    /// `currentModifiedAt` is nil for a file that does not exist, which is not
    /// staleness — creating a new file needs no prior read.
    func check(_ resolvedPath: String, currentModifiedAt: Date?) -> Verdict {
        guard let current = currentModifiedAt else { return .fresh }
        guard let recorded = seen[resolvedPath] else { return .neverRead }
        // A recorded nil means the model read it when it did not exist; anything
        // on disk now arrived from elsewhere.
        guard let recorded = recorded else { return .changedOnDisk }
        return abs(recorded.timeIntervalSince(current)) <= Self.tolerance ? .fresh : .changedOnDisk
    }
}

// MARK: - Refusals

/// Phrased as the next action rather than as a complaint: a model that reads
/// "call readTextFile first" does that, where one that reads "stale file" apologises
/// and tries the same write again.
extension FileReadLedger.Verdict {

    func refusal(path: String, toolName: String) -> String? {
        switch self {
        case .fresh:
            return nil
        case .neverRead:
            return """
            Refusing \(toolName) on \(path): you have not read this file in this conversation, so \
            you cannot know what you are about to overwrite. Call readTextFile on it first, then \
            retry this edit.
            """
        case .changedOnDisk:
            return """
            Refusing \(toolName) on \(path): the file changed on disk after you last read it — \
            the user or another tool edited it. Your version is out of date and writing it would \
            discard their work. Call readTextFile on it again, rebase your change onto what you \
            find, then retry.
            """
        }
    }
}
