import Foundation
import Testing
import ChatCore
@testable import ChatTools

/// A throwaway directory tree, removed when the test releases it.
final class Sandbox {
    let root: URL

    init(_ files: [String: String] = [:]) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sck-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var fileSystem: LocalFileSystem { LocalFileSystem(root: root) }

    func contents(of path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite("LocalFileSystem — reading")
struct LocalFileSystemReadTests {

    @Test("Text comes back with line numbers")
    func numberedLines() async throws {
        let sandbox = try Sandbox(["a.txt": "one\ntwo\nthree\n"])
        let text = try await sandbox.fileSystem.readText(at: "a.txt", offset: nil, limit: nil)
        #expect(text == "     1\tone\n     2\ttwo\n     3\tthree")
    }

    @Test("Offset and limit page through a file, keeping absolute line numbers")
    func offsetAndLimit() async throws {
        let sandbox = try Sandbox(["a.txt": "one\ntwo\nthree\nfour\n"])
        let text = try await sandbox.fileSystem.readText(at: "a.txt", offset: 1, limit: 2)
        #expect(text == "     2\ttwo\n     3\tthree")
    }

    @Test("Reading past the end returns nothing rather than failing")
    func offsetPastEnd() async throws {
        let sandbox = try Sandbox(["a.txt": "one\n"])
        #expect(try await sandbox.fileSystem.readText(at: "a.txt", offset: 99, limit: nil) == "")
    }

    @Test("A missing file reports the path")
    func missingFile() async throws {
        let sandbox = try Sandbox()
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.readText(at: "nope.txt", offset: nil, limit: nil)
        }
    }

    @Test("Binary content is refused by the text reader and served by the data reader")
    func binaryFile() async throws {
        let sandbox = try Sandbox()
        let url = sandbox.root.appendingPathComponent("image.png")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x80]).write(to: url)

        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.readText(at: "image.png", offset: nil, limit: nil)
        }
        let (data, mimeType) = try await sandbox.fileSystem.readData(at: "image.png")
        #expect(mimeType == "image/png")
        #expect(data.count == 5)
    }

    @Test("An unknown extension still reads as bytes")
    func unknownMediaType() async throws {
        let sandbox = try Sandbox(["blob.zzz": "x"])
        let (_, mimeType) = try await sandbox.fileSystem.readData(at: "blob.zzz")
        #expect(mimeType == "application/octet-stream")
    }

    @Test("Absolute paths bypass the working directory")
    func absolutePath() async throws {
        let sandbox = try Sandbox(["a.txt": "hi\n"])
        let other = LocalFileSystem(root: URL(fileURLWithPath: "/nonexistent"))
        let text = try await other.readText(
            at: sandbox.root.appendingPathComponent("a.txt").path, offset: nil, limit: nil)
        #expect(text.hasSuffix("hi"))
    }
}

@Suite("LocalFileSystem — writing")
struct LocalFileSystemWriteTests {

    @Test("Writing creates missing parent directories")
    func writeCreatesParents() async throws {
        let sandbox = try Sandbox()
        try await sandbox.fileSystem.write("hello", to: "deep/nested/a.txt")
        #expect(try sandbox.contents(of: "deep/nested/a.txt") == "hello")
    }

    @Test("Edits apply in order and report a diff")
    func editsApplyInOrder() async throws {
        let sandbox = try Sandbox(["a.txt": "let x = 1\n"])
        let diff = try await sandbox.fileSystem.edit(
            path: "a.txt",
            edits: [FileEdit(oldText: "1", newText: "2"),
                    FileEdit(oldText: "let x = 2", newText: "let y = 2")],
            dryRun: false)

        #expect(try sandbox.contents(of: "a.txt") == "let y = 2\n")
        #expect(diff.contains("-let x = 1"))
        #expect(diff.contains("+let y = 2"))
    }

    @Test("A dry run returns the diff without touching the file")
    func dryRun() async throws {
        let sandbox = try Sandbox(["a.txt": "old\n"])
        let diff = try await sandbox.fileSystem.edit(
            path: "a.txt", edits: [FileEdit(oldText: "old", newText: "new")], dryRun: true)

        #expect(diff.contains("dry run"))
        #expect(try sandbox.contents(of: "a.txt") == "old\n")
    }

    @Test("An edit whose text is absent fails instead of silently doing nothing")
    func missingOldText() async throws {
        let sandbox = try Sandbox(["a.txt": "hello\n"])
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.edit(
                path: "a.txt", edits: [FileEdit(oldText: "goodbye", newText: "x")], dryRun: false)
        }
        #expect(try sandbox.contents(of: "a.txt") == "hello\n")
    }

    @Test("A failed edit leaves earlier edits in the batch unapplied")
    func batchIsAllOrNothing() async throws {
        let sandbox = try Sandbox(["a.txt": "one two\n"])
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.edit(
                path: "a.txt",
                edits: [FileEdit(oldText: "one", newText: "1"),
                        FileEdit(oldText: "missing", newText: "x")],
                dryRun: false)
        }
        #expect(try sandbox.contents(of: "a.txt") == "one two\n")
    }

    @Test("Moving refuses to overwrite an existing destination")
    func moveDoesNotClobber() async throws {
        let sandbox = try Sandbox(["a.txt": "a", "b.txt": "b"])
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.move(from: "a.txt", to: "b.txt")
        }
        #expect(try sandbox.contents(of: "b.txt") == "b")
    }

    @Test("Moving renames and creates the destination's parents")
    func move() async throws {
        let sandbox = try Sandbox(["a.txt": "a"])
        try await sandbox.fileSystem.move(from: "a.txt", to: "sub/b.txt")
        #expect(!sandbox.exists("a.txt"))
        #expect(try sandbox.contents(of: "sub/b.txt") == "a")
    }
}

@Suite("LocalFileSystem — listing")
struct LocalFileSystemListTests {

    @Test("Directories sort before files")
    func directoriesFirst() async throws {
        let sandbox = try Sandbox(["z.txt": "z", "sub/a.txt": "a"])
        let listing = try await sandbox.fileSystem.list(at: "", withSizes: false, sortBySize: false)
        let lines = listing.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("[DIR]") == true)
        #expect(lines.last?.contains("z.txt") == true)
    }

    @Test("Sizes mode adds a summary and can sort by size")
    func sizesAndSummary() async throws {
        let sandbox = try Sandbox(["small.txt": "x", "big.txt": String(repeating: "y", count: 500)])
        let listing = try await sandbox.fileSystem.list(at: "", withSizes: true, sortBySize: true)
        #expect(listing.contains("2 file(s)"))
        let lines = listing.components(separatedBy: "\n")
        #expect(lines.first?.contains("big.txt") == true)
    }

    @Test("An empty directory says so")
    func emptyDirectory() async throws {
        let sandbox = try Sandbox()
        #expect(try await sandbox.fileSystem.list(at: "", withSizes: false, sortBySize: false)
                == "(empty directory)")
    }

    @Test("Listing a file rather than a directory is an error")
    func listingAFile() async throws {
        let sandbox = try Sandbox(["a.txt": "a"])
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.list(at: "a.txt", withSizes: false, sortBySize: false)
        }
    }

    @Test("Info reports type, size, and timestamps")
    func fileInfo() async throws {
        let sandbox = try Sandbox(["a.txt": "hello"])
        let info = try await sandbox.fileSystem.info(at: "a.txt")
        #expect(info["type"]?.stringValue == "file")
        #expect(info["size"]?.intValue == 5)
        #expect(info["name"]?.stringValue == "a.txt")
        #expect(info["modified"]?.stringValue != nil)
    }
}

@Suite("LocalFileSystem — search")
struct LocalFileSystemSearchTests {

    @Test("Glob finds files at any depth, newest first")
    func globNewestFirst() async throws {
        let sandbox = try Sandbox(["a.swift": "a", "sub/b.swift": "b", "c.txt": "c"])
        // Make `sub/b.swift` unambiguously the newer of the two.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: sandbox.root.appendingPathComponent("sub/b.swift").path)

        let matches = try await sandbox.fileSystem.glob(pattern: "*.swift", in: nil)
        #expect(matches.count == 2)
        #expect(matches.first?.hasSuffix("sub/b.swift") == true)
    }

    @Test("Glob skips excluded directories")
    func globSkipsExcluded() async throws {
        let sandbox = try Sandbox(["a.swift": "a", "node_modules/b.swift": "b"])
        let matches = try await sandbox.fileSystem.glob(pattern: "*.swift", in: nil)
        #expect(matches.count == 1)
    }

    @Test("Grep returns matching paths by default")
    func grepFilesWithMatches() async throws {
        let sandbox = try Sandbox(["a.txt": "needle here", "b.txt": "nothing"])
        let result = try await sandbox.fileSystem.grep(
            pattern: "needle", in: nil, filePattern: nil,
            caseInsensitive: false, outputMode: .filesWithMatches)

        #expect(result["fileCount"]?.intValue == 1)
        guard case .array(let files)? = result["files"] else {
            Issue.record("expected a files array"); return
        }
        #expect(files.first?.stringValue?.hasSuffix("a.txt") == true)
    }

    @Test("Content mode returns line numbers and text")
    func grepContent() async throws {
        let sandbox = try Sandbox(["a.txt": "one\nneedle\nthree"])
        let result = try await sandbox.fileSystem.grep(
            pattern: "needle", in: nil, filePattern: nil,
            caseInsensitive: false, outputMode: .content)

        guard case .array(let matches)? = result["matches"],
              case .object(let first)? = matches.first else {
            Issue.record("expected a matches array"); return
        }
        #expect(first["line"]?.intValue == 2)
        #expect(first["text"]?.stringValue == "needle")
    }

    @Test("Count mode totals matches per file")
    func grepCount() async throws {
        let sandbox = try Sandbox(["a.txt": "x\nx\ny"])
        let result = try await sandbox.fileSystem.grep(
            pattern: "x", in: nil, filePattern: nil,
            caseInsensitive: false, outputMode: .count)
        #expect(result["matchCount"]?.intValue == 2)
    }

    @Test("filePattern narrows which files are searched")
    func grepFilePattern() async throws {
        let sandbox = try Sandbox(["a.swift": "needle", "b.txt": "needle"])
        let result = try await sandbox.fileSystem.grep(
            pattern: "needle", in: nil, filePattern: "*.swift",
            caseInsensitive: false, outputMode: .filesWithMatches)
        #expect(result["fileCount"]?.intValue == 1)
    }

    @Test("Case insensitivity is opt-in")
    func grepCaseInsensitive() async throws {
        let sandbox = try Sandbox(["a.txt": "NEEDLE"])
        let sensitive = try await sandbox.fileSystem.grep(
            pattern: "needle", in: nil, filePattern: nil,
            caseInsensitive: false, outputMode: .filesWithMatches)
        #expect(sensitive["fileCount"]?.intValue == 0)

        let insensitive = try await sandbox.fileSystem.grep(
            pattern: "needle", in: nil, filePattern: nil,
            caseInsensitive: true, outputMode: .filesWithMatches)
        #expect(insensitive["fileCount"]?.intValue == 1)
    }

    @Test("An invalid regex reports itself rather than matching nothing")
    func grepInvalidRegex() async throws {
        let sandbox = try Sandbox(["a.txt": "x"])
        await #expect(throws: FileToolError.self) {
            try await sandbox.fileSystem.grep(
                pattern: "[unclosed", in: nil, filePattern: nil,
                caseInsensitive: false, outputMode: .filesWithMatches)
        }
    }
}

@Suite("LocalFileSystem — working directory")
struct LocalFileSystemDirectoryTests {

    @Test("Relative paths follow the working directory when it changes")
    func followsWorkingDirectory() async throws {
        let first = try Sandbox(["a.txt": "first"])
        let second = try Sandbox(["a.txt": "second"])
        let fileSystem = first.fileSystem

        #expect(try await fileSystem.readText(at: "a.txt", offset: nil, limit: nil).hasSuffix("first"))
        await fileSystem.setCurrentDirectory(second.root)
        #expect(await fileSystem.currentDirectory() == second.root)
        #expect(try await fileSystem.readText(at: "a.txt", offset: nil, limit: nil).hasSuffix("second"))
    }
}
