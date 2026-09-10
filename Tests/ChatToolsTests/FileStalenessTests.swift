import Foundation
import Testing
import ChatCore
@testable import ChatTools

@Suite("FileToolProvider — staleness protection")
struct FileStalenessTests {

    private func call(_ name: String, _ arguments: [String: ChatValue] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: arguments)
    }

    private func edit(_ path: String, from oldText: String, to newText: String,
                      dryRun: Bool = false) -> ToolCall {
        var arguments: [String: ChatValue] = [
            "path": .string(path),
            "edits": .array([.object([
                "oldText": .string(oldText),
                "newText": .string(newText),
            ])]),
        ]
        if dryRun { arguments["dryRun"] = .bool(true) }
        return ToolCall(name: FileToolName.editFile, arguments: arguments)
    }

    /// Moves a file's mtime decisively past the ledger's tolerance, standing in
    /// for the user saving in Xcode. Sleeping would work too and be slower and
    /// flakier.
    private func touch(_ sandbox: Sandbox, _ path: String, contents: String) throws {
        let url = sandbox.root.appendingPathComponent(path)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    }

    @Test("Editing a file the model never read is refused")
    func editWithoutReadIsRefused() async throws {
        let sandbox = try Sandbox(["a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        let result = await provider.execute(edit("a.swift", from: "let x = 1", to: "let x = 2"))

        #expect(result.errorMessage?.contains("have not read this file") == true)
        // The refusal has to be total: a partially applied edit would be worse
        // than either outcome.
        #expect(try sandbox.contents(of: "a.swift") == "let x = 1\n")
    }

    @Test("Reading first makes the edit go through")
    func readThenEditSucceeds() async throws {
        let sandbox = try Sandbox(["a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("a.swift")]))
        let result = await provider.execute(edit("a.swift", from: "let x = 1", to: "let x = 2"))

        #expect(result.errorMessage == nil)
        #expect(try sandbox.contents(of: "a.swift") == "let x = 2\n")
    }

    @Test("A file changed on disk after the read is refused")
    func externalChangeIsRefused() async throws {
        let sandbox = try Sandbox(["a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("a.swift")]))
        // The user saves in Xcode while the model is still thinking.
        try touch(sandbox, "a.swift", contents: "let x = 1\nlet y = 99\n")

        let result = await provider.execute(edit("a.swift", from: "let x = 1", to: "let x = 2"))

        #expect(result.errorMessage?.contains("changed on disk") == true)
        // The user's line survives, which is the entire point.
        #expect(try sandbox.contents(of: "a.swift").contains("let y = 99"))
    }

    @Test("Re-reading after an external change clears the refusal")
    func rereadRecovers() async throws {
        let sandbox = try Sandbox(["a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("a.swift")]))
        try touch(sandbox, "a.swift", contents: "let x = 1\nlet y = 99\n")
        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("a.swift")]))

        let result = await provider.execute(edit("a.swift", from: "let x = 1", to: "let x = 2"))
        #expect(result.errorMessage == nil)
    }

    @Test("Consecutive edits work without re-reading between them")
    func editRebaselines() async throws {
        let sandbox = try Sandbox(["a.swift": "one\ntwo\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("a.swift")]))
        let first = await provider.execute(edit("a.swift", from: "one", to: "ONE"))
        let second = await provider.execute(edit("a.swift", from: "two", to: "TWO"))

        #expect(first.errorMessage == nil)
        #expect(second.errorMessage == nil)
        #expect(try sandbox.contents(of: "a.swift") == "ONE\nTWO\n")
    }

    @Test("A dry run does not count as having read the file")
    func dryRunDoesNotRebaseline() async throws {
        let sandbox = try Sandbox(["a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        let preview = await provider.execute(
            edit("a.swift", from: "let x = 1", to: "let x = 2", dryRun: true))
        #expect(preview.errorMessage == nil)

        let real = await provider.execute(edit("a.swift", from: "let x = 1", to: "let x = 2"))
        #expect(real.errorMessage?.contains("have not read this file") == true)
    }

    @Test("Writing a brand new file needs no prior read")
    func writeNewFileIsAllowed() async throws {
        let sandbox = try Sandbox()
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        let result = await provider.execute(call(FileToolName.writeFile, [
            "path": .string("new.swift"),
            "content": .string("fresh\n"),
        ]))

        #expect(result.errorMessage == nil)
        #expect(try sandbox.contents(of: "new.swift") == "fresh\n")
    }

    @Test("Overwriting an existing file the model never read is refused")
    func overwriteWithoutReadIsRefused() async throws {
        let sandbox = try Sandbox(["a.swift": "precious\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        let result = await provider.execute(call(FileToolName.writeFile, [
            "path": .string("a.swift"),
            "content": .string("clobbered\n"),
        ]))

        #expect(result.errorMessage?.contains("have not read this file") == true)
        #expect(try sandbox.contents(of: "a.swift") == "precious\n")
    }

    @Test("A file read by one spelling is not stale under another")
    func pathSpellingsAgree() async throws {
        let sandbox = try Sandbox(["dir/a.swift": "let x = 1\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readTextFile, ["path": .string("dir/a.swift")]))
        let absolute = sandbox.root.appendingPathComponent("dir/a.swift").path
        let result = await provider.execute(edit(absolute, from: "let x = 1", to: "let x = 2"))

        #expect(result.errorMessage == nil)
    }

    @Test("readMultipleFiles baselines every file it returned")
    func batchReadBaselines() async throws {
        let sandbox = try Sandbox(["a.swift": "aaa\n", "b.swift": "bbb\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)

        _ = await provider.execute(call(FileToolName.readMultipleFiles, [
            "paths": .array([.string("a.swift"), .string("b.swift")]),
        ]))

        let a = await provider.execute(edit("a.swift", from: "aaa", to: "AAA"))
        let b = await provider.execute(edit("b.swift", from: "bbb", to: "BBB"))
        #expect(a.errorMessage == nil)
        #expect(b.errorMessage == nil)
    }
}
