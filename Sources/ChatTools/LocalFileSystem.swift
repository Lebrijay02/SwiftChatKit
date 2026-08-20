//
//  LocalFileSystem.swift
//  SwiftChatKit
//
//  The default `FileSystemProviding`: real files on the local disk, rooted at a
//  working directory the session keeps in sync.
//

import Foundation
import ChatCore

public actor LocalFileSystem: FileSystemProviding {

    private var root: URL
    /// Whether `root` came from a security-scoped bookmark or an open panel. A
    /// sandboxed host has no access to it outside a start/stop pair, and the
    /// pairs must balance or the app leaks its access allowance.
    private let securityScoped: Bool
    private let fileManager = FileManager.default

    /// Files and directories never walked by `glob`, `grep`, or a recursive
    /// list. Descending into `.git` or `node_modules` buries the real answer.
    public static let defaultExcludedNames: Set<String> = [
        ".git", ".build", ".svn", "node_modules", "DerivedData",
        "Pods", ".venv", "venv", "__pycache__", ".next", "dist"
    ]

    private let excludedNames: Set<String>

    public init(root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                securityScoped: Bool = false,
                excludedNames: Set<String> = LocalFileSystem.defaultExcludedNames) {
        self.root = root
        self.securityScoped = securityScoped
        self.excludedNames = excludedNames
    }

    // MARK: - Directory

    public func currentDirectory() -> URL { root }

    public func setCurrentDirectory(_ url: URL) { root = url }

    /// Resolves a tool-supplied path. Absolute and `~`-prefixed paths are taken
    /// at face value; everything else hangs off the working directory.
    private func resolve(_ path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." { return root }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return root.appendingPathComponent(trimmed)
    }

    /// Runs `body` inside a balanced security-scoped access pair.
    private func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        guard securityScoped, root.startAccessingSecurityScopedResource() else {
            return try body()
        }
        defer { root.stopAccessingSecurityScopedResource() }
        return try body()
    }

    // MARK: - Reading

    public func readText(at path: String, offset: Int?, limit: Int?) throws -> String {
        let url = resolve(path)
        return try withAccess {
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileToolError.notFound(url.path)
            }
            let data = try Data(contentsOf: url)
            guard let contents = String(data: data, encoding: .utf8) else {
                throw FileToolError.notUTF8(url.path)
            }

            var lines = contents.components(separatedBy: .newlines)
            // A trailing newline yields a phantom empty last line.
            if lines.last?.isEmpty == true { lines.removeLast() }

            let start = max(0, offset ?? 0)
            guard start < lines.count else { return "" }
            let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count

            // `cat -n`: the model needs stable line numbers to write edits against.
            return lines[start..<end]
                .enumerated()
                .map { String(format: "%6d\t%@", start + $0.offset + 1, $0.element) }
                .joined(separator: "\n")
        }
    }

    public func readData(at path: String) throws -> (data: Data, mimeType: String) {
        let url = resolve(path)
        return try withAccess {
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileToolError.notFound(url.path)
            }
            return (try Data(contentsOf: url), MIMEType.forExtension(url.pathExtension))
        }
    }

    // MARK: - Writing

    public func write(_ contents: String, to path: String) throws {
        let url = resolve(path)
        try withAccess {
            let parent = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func edit(path: String, edits: [FileEdit], dryRun: Bool) throws -> String {
        let url = resolve(path)
        return try withAccess {
            guard fileManager.fileExists(atPath: url.path) else {
                throw FileToolError.notFound(url.path)
            }
            let original = try String(contentsOf: url, encoding: .utf8)
            var updated = original

            for edit in edits {
                guard let range = updated.range(of: edit.oldText) else {
                    // Failing loudly beats reporting a success that changed
                    // nothing — the model would build its next edit on a file
                    // state that never existed.
                    throw FileToolError.editTextNotFound(oldText: edit.oldText, path: url.path)
                }
                updated.replaceSubrange(range, with: edit.newText)
            }

            if !dryRun, updated != original {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
            return Self.diff(from: original, to: updated, path: url.path, dryRun: dryRun)
        }
    }

    public func createDirectory(at path: String) throws {
        let url = resolve(path)
        try withAccess {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func move(from source: String, to destination: String) throws {
        let sourceURL = resolve(source)
        let destinationURL = resolve(destination)
        try withAccess {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw FileToolError.notFound(sourceURL.path)
            }
            // Never clobber: an overwrite here is unrecoverable and the model
            // rarely means it.
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw FileToolError.destinationExists(destinationURL.path)
            }
            let parent = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    // MARK: - Listing

    public func list(at path: String, withSizes: Bool, sortBySize: Bool) throws -> String {
        let url = resolve(path)
        return try withAccess {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw FileToolError.notFound(url.path)
            }
            guard isDirectory.boolValue else { throw FileToolError.notADirectory(url.path) }

            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
            let contents = try fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [])

            var entries: [(name: String, isDirectory: Bool, size: Int64)] = []
            for item in contents where !excludedNames.contains(item.lastPathComponent) {
                let values = try? item.resourceValues(forKeys: Set(keys))
                entries.append((item.lastPathComponent,
                                values?.isDirectory ?? false,
                                Int64(values?.fileSize ?? 0)))
            }

            if withSizes && sortBySize {
                entries.sort { $0.size > $1.size }
            } else {
                // Directories first, then alphabetical — the shape people expect.
                entries.sort {
                    $0.isDirectory == $1.isDirectory
                        ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        : $0.isDirectory
                }
            }

            guard !entries.isEmpty else { return "(empty directory)" }

            let lines = entries.map { entry -> String in
                let tag = entry.isDirectory ? "[DIR] " : "[FILE]"
                guard withSizes else { return "\(tag) \(entry.name)" }
                let size = entry.isDirectory ? "-" : Self.formatSize(entry.size)
                return "\(tag) \(entry.name.padding(toLength: max(entry.name.count, 32), withPad: " ", startingAt: 0)) \(size)"
            }

            guard withSizes else { return lines.joined(separator: "\n") }

            let fileCount = entries.filter { !$0.isDirectory }.count
            let total = entries.reduce(Int64(0)) { $0 + $1.size }
            let summary = "\n\n\(fileCount) file(s), \(entries.count - fileCount) directory(ies), \(Self.formatSize(total)) total"
            return lines.joined(separator: "\n") + summary
        }
    }

    public func info(at path: String) throws -> [String: ChatValue] {
        let url = resolve(path)
        return try withAccess {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw FileToolError.notFound(url.path)
            }
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                .isReadableKey, .isWritableKey
            ])
            let size = Int64(values.fileSize ?? 0)
            let formatter = ISO8601DateFormatter()

            var result: [String: ChatValue] = [
                "name": .string(url.lastPathComponent),
                "path": .string(url.path),
                "type": .string(isDirectory.boolValue ? "directory" : "file"),
                "size": .number(Double(size)),
                "sizeFormatted": .string(Self.formatSize(size)),
                "isReadable": .bool(values.isReadable ?? false),
                "isWritable": .bool(values.isWritable ?? false)
            ]
            if let created = values.creationDate {
                result["created"] = .string(formatter.string(from: created))
            }
            if let modified = values.contentModificationDate {
                result["modified"] = .string(formatter.string(from: modified))
            }
            return result
        }
    }

    // MARK: - Search

    public func glob(pattern: String, in path: String?) throws -> [String] {
        let base = resolve(path ?? "")
        return try withAccess {
            var matches: [(path: String, modified: Date)] = []
            for url in walk(base) {
                let relative = Self.relativePath(of: url, from: base)
                guard GlobPattern.matches(relative, pattern: pattern) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                matches.append((url.path, modified))
            }
            // Newest first: when a model globs, it is usually looking for what
            // it or the user just touched.
            return matches.sorted { $0.modified > $1.modified }.map(\.path)
        }
    }

    public func grep(pattern: String,
                     in path: String?,
                     filePattern: String?,
                     caseInsensitive: Bool,
                     outputMode: GrepOutputMode) throws -> [String: ChatValue] {
        let base = resolve(path ?? "")
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            throw FileToolError.invalidRegex(pattern)
        }

        return try withAccess {
            var files: [ChatValue] = []
            var contentMatches: [ChatValue] = []
            var counts: [ChatValue] = []
            var total = 0

            for url in walk(base) {
                let relative = Self.relativePath(of: url, from: base)
                if let filePattern, !GlobPattern.matches(relative, pattern: filePattern) { continue }
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }

                var fileCount = 0
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    guard regex.firstMatch(in: line, options: [], range: range) != nil else { continue }
                    fileCount += 1
                    total += 1
                    if outputMode == .content {
                        contentMatches.append(.object([
                            "file": .string(url.path),
                            "line": .number(Double(index + 1)),
                            "text": .string(line)
                        ]))
                    }
                }

                guard fileCount > 0 else { continue }
                switch outputMode {
                case .filesWithMatches: files.append(.string(url.path))
                case .count: counts.append(.object(["file": .string(url.path),
                                                    "count": .number(Double(fileCount))]))
                case .content: break
                }
            }

            switch outputMode {
            case .filesWithMatches:
                return ["files": .array(files), "fileCount": .number(Double(files.count))]
            case .content:
                return ["matches": .array(contentMatches), "matchCount": .number(Double(total))]
            case .count:
                return ["counts": .array(counts), "matchCount": .number(Double(total))]
            }
        }
    }

    // MARK: - Walking

    /// Depth-first enumeration of files under `base`, skipping excluded
    /// directories and anything hidden.
    private func walk(_ base: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if excludedNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory { results.append(url) }
        }
        return results
    }

    // MARK: - Formatting

    static func relativePath(of url: URL, from base: URL) -> String {
        let path = url.path
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard path.hasPrefix(basePath) else { return path }
        return String(path.dropFirst(basePath.count))
    }

    static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// A unified-ish diff. Not a real Myers diff — it reports the changed span
    /// between the common prefix and suffix, which is what an edit produces.
    static func diff(from original: String, to updated: String,
                     path: String, dryRun: Bool) -> String {
        guard original != updated else { return "No changes to \(path)." }

        let oldLines = original.components(separatedBy: .newlines)
        let newLines = updated.components(separatedBy: .newlines)

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let removed = oldLines[prefix..<(oldLines.count - suffix)]
        let added = newLines[prefix..<(newLines.count - suffix)]

        var lines = ["--- \(path)", "+++ \(path)", "@@ Replacement @@"]
        lines += removed.map { "-\($0)" }
        lines += added.map { "+\($0)" }
        if dryRun { lines.append("\n(dry run — nothing was written)") }
        return lines.joined(separator: "\n")
    }
}
