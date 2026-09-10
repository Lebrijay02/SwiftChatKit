//
//  DirectoryScope.swift
//  SwiftChatKit
//
//  Where a conversation is allowed to reach on disk.
//
//  A session picks its `root` while the transcript is still empty and is stuck
//  with it from the first message onward. Everything the model reads relative to
//  nothing resolves against that root, so letting it move mid-conversation would
//  silently repoint every path already in the transcript — the model would read
//  "Sources/App.swift" ten turns later and get a different file than the one it
//  was shown.
//
//  `additional` has no such problem: a directory can only ever be added, so a
//  path that resolved yesterday still resolves today.
//

import Foundation

public struct DirectoryScope: Equatable, Sendable {

    /// Base for relative paths, shell working directory, and the skills scan.
    /// Nil before a host has chosen one.
    public private(set) var root: URL?

    /// Extra directories the conversation may reach, in the order they were
    /// added. Never contains `root` and never contains duplicates.
    public private(set) var additional: [URL]

    public init(root: URL? = nil, additional: [URL] = []) {
        self.root = root?.standardizedFileURL
        self.additional = []
        for url in additional { _ = add(url) }
    }

    /// `root` first, then the additions in the order the user added them. The
    /// order is what a host renders and what the model is shown, so it stays
    /// stable rather than sorted.
    public var all: [URL] {
        (root.map { [$0] } ?? []) + additional
    }

    public var isEmpty: Bool { all.isEmpty }

    // MARK: - Mutation

    /// Only meaningful before a conversation starts; the session enforces that,
    /// not this type, which has no idea whether a transcript exists.
    mutating func setRoot(_ url: URL?) {
        root = url?.standardizedFileURL
        // A directory that was an addition becomes redundant once it *is* the
        // root, and leaving it in both lists would show it twice.
        if let root { additional.removeAll { Self.canonical($0) == Self.canonical(root) } }
    }

    /// Returns false when the directory was already reachable, so a caller can
    /// tell "added" from "you already had that one" without comparing lists.
    @discardableResult
    mutating func add(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard !contains(standardized) else { return false }
        additional.append(standardized)
        return true
    }

    // MARK: - Containment

    /// Whether `url` is one of the scope's directories or lives inside one.
    ///
    /// An empty scope allows everything. A session that was never given a
    /// directory has no opinion about where its tools may read, and answering
    /// "nowhere" would break every host that just wants a chat with file tools.
    public func contains(_ url: URL) -> Bool {
        guard !isEmpty else { return true }
        let candidate = Self.canonical(url)
        return all.contains { Self.canonical($0).isDirectoryPrefix(of: candidate) }
    }

    /// The directory `url` was admitted by, for a message that can name it.
    public func admitting(_ url: URL) -> URL? {
        let candidate = Self.canonical(url)
        return all.first { Self.canonical($0).isDirectoryPrefix(of: candidate) }
    }

    // MARK: - Canonical form

    /// Absolute, symlink-free, no `..` — the form two paths have to share before
    /// they can be compared.
    ///
    /// Symlinks are resolved on the deepest part of the path that actually
    /// exists, then the missing tail is reattached. Resolving the whole path
    /// would be a no-op for a file about to be *created*, and on macOS that is
    /// the difference between `/tmp/x` and `/private/tmp/x` — a new file under
    /// an allowed root would look like an escape.
    static func canonical(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let manager = FileManager.default
        if manager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }

        var missing: [String] = []
        var probe = standardized
        while probe.pathComponents.count > 1 {
            missing.insert(probe.lastPathComponent, at: 0)
            probe = probe.deletingLastPathComponent()
            guard manager.fileExists(atPath: probe.path) else { continue }
            return missing
                .reduce(probe.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
                .path
        }
        return standardized.path
    }
}

private extension String {

    /// True when `self` is the same path as `other` or one of its ancestors.
    ///
    /// Compared component-wise rather than with `hasPrefix`, which would let
    /// `/Users/me/app` admit `/Users/me/app-secrets`.
    func isDirectoryPrefix(of other: String) -> Bool {
        if self == other { return true }
        return other.hasPrefix(hasSuffix("/") ? self : self + "/")
    }
}
