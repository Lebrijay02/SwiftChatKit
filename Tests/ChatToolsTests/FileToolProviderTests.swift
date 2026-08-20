import Foundation
import Testing
import ChatCore
@testable import ChatTools

@Suite("FileToolProvider — dispatch")
struct FileToolProviderTests {

    private func provider(_ sandbox: Sandbox) -> FileToolProvider {
        FileToolProvider(fileSystem: sandbox.fileSystem)
    }

    private func call(_ name: String, _ arguments: [String: ChatValue] = [:]) -> ToolCall {
        ToolCall(name: name, arguments: arguments)
    }

    @Test("Every declared tool is claimed and dispatched")
    func declarationsAndDispatchAgree() async throws {
        let sandbox = try Sandbox()
        let provider = provider(sandbox)

        #expect(FileToolProvider.allDeclarations.count == 13)
        for declaration in FileToolProvider.allDeclarations {
            #expect(provider.handles(declaration.name))
            // Dispatching with no arguments must never fall through to the
            // "does not handle" branch — that would mean a declaration with no
            // implementation behind it.
            let result = await provider.execute(call(declaration.name))
            #expect(result.errorMessage?.contains("does not handle") != true)
        }
    }

    @Test("Read-only and mutating tool sets cover the whole surface without overlapping")
    func toolSetsPartition() {
        let all = Set(FileToolProvider.allDeclarations.map(\.name))
        #expect(FileToolProvider.readOnlyNames.isDisjoint(with: FileToolProvider.mutatingNames))
        #expect(FileToolProvider.readOnlyNames.union(FileToolProvider.mutatingNames) == all)
    }

    @Test("An unknown tool is reported, not crashed on")
    func unknownTool() async throws {
        let sandbox = try Sandbox()
        let result = await provider(sandbox).execute(call("notATool"))
        #expect(result.errorMessage?.contains("does not handle") == true)
    }

    @Test("getCurrentDirectory returns the working directory")
    func currentDirectory() async throws {
        let sandbox = try Sandbox()
        let result = await provider(sandbox).execute(call(FileToolName.getCurrentDirectory))
        #expect(result.payload["path"]?.stringValue == sandbox.root.path)
    }

    @Test("readTextFile returns numbered content")
    func readTextFile() async throws {
        let sandbox = try Sandbox(["a.txt": "hi\n"])
        let result = await provider(sandbox).execute(
            call(FileToolName.readTextFile, ["path": .string("a.txt")]))
        #expect(result.payload["content"]?.stringValue == "     1\thi")
    }

    @Test("readMediaFile returns base64 and a MIME type")
    func readMediaFile() async throws {
        let sandbox = try Sandbox(["note.pdf": "%PDF"])
        let result = await provider(sandbox).execute(
            call(FileToolName.readMediaFile, ["path": .string("note.pdf")]))
        #expect(result.payload["mimeType"]?.stringValue == "application/pdf")
        #expect(result.payload["base64"]?.stringValue == Data("%PDF".utf8).base64EncodedString())
    }

    @Test("readMultipleFiles reports a bad path inline instead of failing the batch")
    func readMultipleFilesPartialFailure() async throws {
        let sandbox = try Sandbox(["a.txt": "a\n"])
        let result = await provider(sandbox).execute(
            call(FileToolName.readMultipleFiles,
                 ["paths": .array([.string("a.txt"), .string("missing.txt")])]))

        #expect(result.errorMessage == nil)
        guard case .array(let files)? = result.payload["files"], files.count == 2,
              case .object(let good) = files[0], case .object(let bad) = files[1] else {
            Issue.record("expected two file entries"); return
        }
        #expect(good["content"]?.stringValue?.contains("a") == true)
        #expect(bad["error"]?.stringValue != nil)
    }

    @Test("writeFile and editFile change the disk")
    func writeAndEdit() async throws {
        let sandbox = try Sandbox()
        let provider = provider(sandbox)

        _ = await provider.execute(call(FileToolName.writeFile,
                                        ["path": .string("a.txt"), "content": .string("old")]))
        #expect(try sandbox.contents(of: "a.txt") == "old")

        let result = await provider.execute(call(FileToolName.editFile, [
            "path": .string("a.txt"),
            "edits": .array([.object(["oldText": .string("old"), "newText": .string("new")])])
        ]))
        #expect(result.payload["diff"]?.stringValue?.contains("+new") == true)
        #expect(try sandbox.contents(of: "a.txt") == "new")
    }

    @Test("A failing tool returns the error as data rather than throwing")
    func errorsBecomeData() async throws {
        let sandbox = try Sandbox()
        let result = await provider(sandbox).execute(
            call(FileToolName.readTextFile, ["path": .string("missing.txt")]))
        #expect(result.errorMessage?.contains("missing.txt") == true)
    }

    @Test("globFiles and grepFiles pass their options through")
    func searchOptions() async throws {
        let sandbox = try Sandbox(["a.swift": "NEEDLE", "b.txt": "NEEDLE"])
        let provider = provider(sandbox)

        let glob = await provider.execute(
            call(FileToolName.globFiles, ["pattern": .string("*.swift")]))
        #expect(glob.payload["count"]?.intValue == 1)

        let grep = await provider.execute(call(FileToolName.grepFiles, [
            "pattern": .string("needle"),
            "caseInsensitive": .bool(true),
            "filePattern": .string("*.txt")
        ]))
        #expect(grep.payload["fileCount"]?.intValue == 1)
    }

    @Test("listDirectoryWithSizes honours the sort option")
    func listWithSizes() async throws {
        let sandbox = try Sandbox(["small.txt": "x", "big.txt": String(repeating: "y", count: 500)])
        let result = await provider(sandbox).execute(
            call(FileToolName.listDirectoryWithSizes, ["sortBy": .string("size")]))
        #expect(result.payload["listing"]?.stringValue?.hasPrefix("[FILE] big.txt") == true)
    }
}

@Suite("FileToolProvider — approval and directory")
struct FileToolProviderApprovalTests {

    @Test("Editing asks for approval with the real diff, not the raw arguments")
    func editCardShowsDiff() async throws {
        let sandbox = try Sandbox(["a.txt": "old\n"])
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)
        let card = await provider.approvalCard(for: ToolCall(name: FileToolName.editFile, arguments: [
            "path": .string("a.txt"),
            "edits": .array([.object(["oldText": .string("old"), "newText": .string("new")])])
        ]))

        #expect(card?.title == "Edit a.txt")
        #expect(card?.detail.contains("-old") == true)
        #expect(card?.detail.contains("+new") == true)
        // Previewing must not have written anything.
        #expect(try sandbox.contents(of: "a.txt") == "old\n")
    }

    @Test("Read-only tools ask for no approval")
    func readOnlyToolsHaveNoCard() async throws {
        let sandbox = try Sandbox()
        let provider = FileToolProvider(fileSystem: sandbox.fileSystem)
        for name in FileToolProvider.readOnlyNames {
            #expect(await provider.approvalCard(for: ToolCall(name: name)) == nil)
        }
    }

    @Test("Moving shows both paths")
    func moveCard() async throws {
        let sandbox = try Sandbox()
        let card = await FileToolProvider(fileSystem: sandbox.fileSystem).approvalCard(
            for: ToolCall(name: FileToolName.moveFile,
                          arguments: ["source": .string("a"), "destination": .string("b")]))
        #expect(card?.detail == "a\n→ b")
    }

    @Test("The provider follows the session's working directory")
    func followsWorkingDirectory() async throws {
        let first = try Sandbox(["a.txt": "first"])
        let second = try Sandbox(["a.txt": "second"])
        let provider = FileToolProvider(fileSystem: first.fileSystem)

        await provider.workingDirectoryChanged(to: second.root)
        let result = await provider.execute(
            ToolCall(name: FileToolName.readTextFile, arguments: ["path": .string("a.txt")]))
        #expect(result.payload["content"]?.stringValue?.contains("second") == true)
    }
}
