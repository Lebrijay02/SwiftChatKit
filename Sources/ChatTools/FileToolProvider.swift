//
//  FileToolProvider.swift
//  SwiftChatKit
//
//  The built-in file tools, expressed against `FileSystemProviding` so a host
//  can swap the local disk for a sandboxed root, a virtual project, or a remote
//  workspace without the declarations changing.
//

import Foundation
import ChatCore

public enum FileToolName {
    public static let getCurrentDirectory = "getCurrentDirectory"
    public static let readTextFile = "readTextFile"
    public static let readMediaFile = "readMediaFile"
    public static let readMultipleFiles = "readMultipleFiles"
    public static let writeFile = "writeFile"
    public static let editFile = "editFile"
    public static let createDirectory = "createDirectory"
    public static let listDirectory = "listDirectory"
    public static let listDirectoryWithSizes = "listDirectoryWithSizes"
    public static let moveFile = "moveFile"
    public static let getFileInfo = "getFileInfo"
    public static let globFiles = "globFiles"
    public static let grepFiles = "grepFiles"
}

public final class FileToolProvider: ToolProvider {

    private let fileSystem: any FileSystemProviding

    public init(fileSystem: any FileSystemProviding) {
        self.fileSystem = fileSystem
    }

    // MARK: - Tool sets

    /// Tools that only observe. Safe to auto-allow: pass to
    /// `ChatSessionConfiguration.autoAllowedTools`, or rely on the session
    /// merging `autoAllowedToolNames` for you.
    public static let readOnlyNames: Set<String> = [
        FileToolName.getCurrentDirectory, FileToolName.readTextFile,
        FileToolName.readMediaFile, FileToolName.readMultipleFiles,
        FileToolName.listDirectory, FileToolName.listDirectoryWithSizes,
        FileToolName.getFileInfo, FileToolName.globFiles, FileToolName.grepFiles
    ]

    /// Tools that change the disk. Blocked outright in plan mode.
    public static let mutatingNames: Set<String> = [
        FileToolName.writeFile, FileToolName.editFile,
        FileToolName.createDirectory, FileToolName.moveFile
    ]

    public var autoAllowedToolNames: Set<String> { Self.readOnlyNames }
    public var mutatingToolNames: Set<String> { Self.mutatingNames }

    // MARK: - Declarations

    public var declarations: [ToolDeclaration] { Self.allDeclarations }

    public static let allDeclarations: [ToolDeclaration] = [
        ToolDeclaration(
            name: FileToolName.getCurrentDirectory,
            description: """
                Returns the absolute path of the working directory. Every other \
                file tool resolves relative paths against it. Call this first \
                when you need to report or construct an absolute path.
                """),

        ToolDeclaration(
            name: FileToolName.readTextFile,
            description: """
                Reads a UTF-8 text file and returns it with line numbers. Use \
                offset and limit to page through a large file instead of \
                reading all of it.
                """,
            parameters: [
                "path": .string(description: "File path, absolute or relative to the working directory."),
                "offset": .integer(description: "0-indexed line to start from."),
                "limit": .integer(description: "Maximum number of lines to return.")
            ],
            optional: ["offset", "limit"]),

        ToolDeclaration(
            name: FileToolName.readMediaFile,
            description: """
                Reads an image, audio, video, or PDF file and returns it as \
                base64 with its MIME type. Use this for anything that is not \
                UTF-8 text.
                """,
            parameters: ["path": .string(description: "File path.")]),

        ToolDeclaration(
            name: FileToolName.readMultipleFiles,
            description: """
                Reads several text files at once. Faster than repeated \
                readTextFile calls; a file that fails to read reports its error \
                inline instead of failing the batch.
                """,
            parameters: [
                "paths": .array(items: .string(), description: "File paths to read.")
            ]),

        ToolDeclaration(
            name: FileToolName.writeFile,
            description: """
                Writes content to a file, creating parent directories as needed \
                and overwriting any existing file. Prefer editFile for changes \
                to a file that already exists.
                """,
            parameters: [
                "path": .string(description: "File path."),
                "content": .string(description: "Full contents to write.")
            ]),

        ToolDeclaration(
            name: FileToolName.editFile,
            description: """
                Applies one or more exact find-and-replace edits to a file, in \
                order, and returns a diff. Each oldText must appear in the file \
                or the whole call fails. Include enough surrounding context to \
                make each oldText unique. Set dryRun to preview the diff \
                without writing.
                """,
            parameters: [
                "path": .string(description: "File path."),
                "edits": .array(
                    items: .object(properties: [
                        "oldText": .string(description: "Exact text to find."),
                        "newText": .string(description: "Text to replace it with.")
                    ]),
                    description: "Edits applied in order."),
                "dryRun": .boolean(description: "Preview only; do not write.")
            ],
            optional: ["dryRun"]),

        ToolDeclaration(
            name: FileToolName.createDirectory,
            description: "Creates a directory, including any missing parents.",
            parameters: ["path": .string(description: "Directory path.")]),

        ToolDeclaration(
            name: FileToolName.listDirectory,
            description: """
                Lists the entries of a directory, marked [DIR] or [FILE]. \
                Omit path to list the working directory.
                """,
            parameters: ["path": .string(description: "Directory path.")],
            optional: ["path"]),

        ToolDeclaration(
            name: FileToolName.listDirectoryWithSizes,
            description: """
                Lists a directory with file sizes and a total summary. Use \
                sortBy to order by size instead of name.
                """,
            parameters: [
                "path": .string(description: "Directory path."),
                "sortBy": .enumeration(values: ["name", "size"],
                                       description: "Sort order. Defaults to name.")
            ],
            optional: ["path", "sortBy"]),

        ToolDeclaration(
            name: FileToolName.moveFile,
            description: """
                Moves or renames a file or directory. Fails if the destination \
                already exists — nothing is ever overwritten.
                """,
            parameters: [
                "source": .string(description: "Path to move."),
                "destination": .string(description: "New path.")
            ]),

        ToolDeclaration(
            name: FileToolName.getFileInfo,
            description: "Returns size, type, timestamps, and permissions for a path.",
            parameters: ["path": .string(description: "File or directory path.")]),

        ToolDeclaration(
            name: FileToolName.globFiles,
            description: """
                Finds files by name pattern, newest first. Supports *, **, ?, \
                and [abc] classes. A pattern with no slash matches at any depth, \
                so "*.swift" finds nested files.
                """,
            parameters: [
                "pattern": .string(description: "Glob pattern, e.g. **/*.swift."),
                "path": .string(description: "Directory to search. Defaults to the working directory.")
            ],
            optional: ["path"]),

        ToolDeclaration(
            name: FileToolName.grepFiles,
            description: """
                Searches file contents with a regular expression. Prefer the \
                default files_with_matches output mode — it costs far less \
                context than content — and narrow the search with filePattern.
                """,
            parameters: [
                "pattern": .string(description: "Regular expression to search for."),
                "path": .string(description: "Directory to search. Defaults to the working directory."),
                "filePattern": .string(description: "Glob limiting which files are searched, e.g. *.swift."),
                "caseInsensitive": .boolean(description: "Ignore case. Defaults to false."),
                "outputMode": .enumeration(
                    values: ["files_with_matches", "content", "count"],
                    description: "What to return. Defaults to files_with_matches.")
            ],
            optional: ["path", "filePattern", "caseInsensitive", "outputMode"])
    ]

    public func handles(_ name: String) -> Bool {
        Self.allDeclarations.contains { $0.name == name }
    }

    public func workingDirectoryChanged(to url: URL?) async {
        guard let url else { return }
        await fileSystem.setCurrentDirectory(url)
    }

    // MARK: - Approval

    public func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        let arguments = call.arguments
        switch call.name {
        case FileToolName.writeFile:
            let path = arguments["path"]?.stringValue ?? "?"
            return PermissionRequest(
                toolName: call.name,
                title: "Write \((path as NSString).lastPathComponent)",
                detail: path)

        case FileToolName.editFile:
            let path = arguments["path"]?.stringValue ?? "?"
            // Show the actual diff rather than the arguments: the user is being
            // asked to approve a change, so show them the change.
            let preview = (try? await fileSystem.edit(
                path: path, edits: Self.edits(from: arguments), dryRun: true)) ?? path
            return PermissionRequest(
                toolName: call.name,
                title: "Edit \((path as NSString).lastPathComponent)",
                detail: preview)

        case FileToolName.createDirectory:
            let path = arguments["path"]?.stringValue ?? "?"
            return PermissionRequest(toolName: call.name,
                                     title: "Create directory", detail: path)

        case FileToolName.moveFile:
            let source = arguments["source"]?.stringValue ?? "?"
            let destination = arguments["destination"]?.stringValue ?? "?"
            return PermissionRequest(toolName: call.name, title: "Move file",
                                     detail: "\(source)\n→ \(destination)")

        default:
            return nil
        }
    }

    // MARK: - Dispatch

    public func execute(_ call: ToolCall) async -> ToolResult {
        let arguments = call.arguments
        func string(_ key: String) -> String { arguments[key]?.stringValue ?? "" }
        func optionalString(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        func integer(_ key: String) -> Int? { arguments[key]?.intValue }

        do {
            switch call.name {
            case FileToolName.getCurrentDirectory:
                return .success(call, ["path": .string(await fileSystem.currentDirectory().path)])

            case FileToolName.readTextFile:
                let contents = try await fileSystem.readText(
                    at: string("path"), offset: integer("offset"), limit: integer("limit"))
                return .success(call, ["content": .string(contents)])

            case FileToolName.readMediaFile:
                let (data, mimeType) = try await fileSystem.readData(at: string("path"))
                return .success(call, [
                    "base64": .string(data.base64EncodedString()),
                    "mimeType": .string(mimeType),
                    "byteCount": .number(Double(data.count))
                ])

            case FileToolName.readMultipleFiles:
                guard case .array(let paths)? = arguments["paths"] else {
                    return .failure(call, "readMultipleFiles requires a `paths` array.")
                }
                var files: [ChatValue] = []
                for path in paths.compactMap(\.stringValue) {
                    // One unreadable file must not sink the batch — report it
                    // in place so the model can still use the rest.
                    do {
                        let contents = try await fileSystem.readText(at: path, offset: nil, limit: nil)
                        files.append(.object(["path": .string(path), "content": .string(contents)]))
                    } catch {
                        files.append(.object(["path": .string(path),
                                              "error": .string(error.localizedDescription)]))
                    }
                }
                return .success(call, ["files": .array(files)])

            case FileToolName.writeFile:
                try await fileSystem.write(string("content"), to: string("path"))
                return .success(call, ["written": .string(string("path"))])

            case FileToolName.editFile:
                let diff = try await fileSystem.edit(
                    path: string("path"),
                    edits: Self.edits(from: arguments),
                    dryRun: arguments["dryRun"]?.boolValue ?? false)
                return .success(call, ["diff": .string(diff)])

            case FileToolName.createDirectory:
                try await fileSystem.createDirectory(at: string("path"))
                return .success(call, ["created": .string(string("path"))])

            case FileToolName.listDirectory:
                let listing = try await fileSystem.list(
                    at: optionalString("path") ?? "", withSizes: false, sortBySize: false)
                return .success(call, ["listing": .string(listing)])

            case FileToolName.listDirectoryWithSizes:
                let listing = try await fileSystem.list(
                    at: optionalString("path") ?? "",
                    withSizes: true,
                    sortBySize: string("sortBy") == "size")
                return .success(call, ["listing": .string(listing)])

            case FileToolName.moveFile:
                try await fileSystem.move(from: string("source"), to: string("destination"))
                return .success(call, ["moved": .string(string("destination"))])

            case FileToolName.getFileInfo:
                return .success(call, try await fileSystem.info(at: string("path")))

            case FileToolName.globFiles:
                let paths = try await fileSystem.glob(
                    pattern: string("pattern"), in: optionalString("path"))
                return .success(call, [
                    "files": .array(paths.map { .string($0) }),
                    "count": .number(Double(paths.count))
                ])

            case FileToolName.grepFiles:
                return .success(call, try await fileSystem.grep(
                    pattern: string("pattern"),
                    in: optionalString("path"),
                    filePattern: optionalString("filePattern"),
                    caseInsensitive: arguments["caseInsensitive"]?.boolValue ?? false,
                    outputMode: GrepOutputMode(rawValue: string("outputMode"))))

            default:
                return .failure(call, "FileToolProvider does not handle \(call.name).")
            }
        } catch {
            return .failure(call, error.localizedDescription)
        }
    }

    private static func edits(from arguments: [String: ChatValue]) -> [FileEdit] {
        guard case .array(let raw)? = arguments["edits"] else { return [] }
        return raw.compactMap { value in
            guard case .object(let fields) = value,
                  let oldText = fields["oldText"]?.stringValue,
                  let newText = fields["newText"]?.stringValue
            else { return nil }
            return FileEdit(oldText: oldText, newText: newText)
        }
    }
}
