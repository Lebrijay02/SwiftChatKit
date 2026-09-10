//
//  DirectoryScopeTests.swift
//  SwiftChatKit
//

import Foundation
import Testing
@testable import ChatCore

// MARK: - The value type

@Suite("Directory scope")
struct DirectoryScopeTests {

    @Test("An empty scope allows everything")
    func emptyScopeAllowsAnything() {
        #expect(DirectoryScope().contains(URL(fileURLWithPath: "/anywhere/at/all")))
    }

    @Test("A directory contains itself and its descendants")
    func containment() {
        let scope = DirectoryScope(root: URL(fileURLWithPath: "/Users/me/app"))
        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/app")))
        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/app/Sources/A.swift")))
        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/other")) == false)
    }

    @Test("A sibling sharing a name prefix is not inside")
    func siblingPrefixIsNotContainment() {
        let scope = DirectoryScope(root: URL(fileURLWithPath: "/Users/me/app"))
        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/app-secrets/key.pem")) == false)
    }

    @Test("A path that climbs out with .. is not inside")
    func dotDotEscape() {
        let scope = DirectoryScope(root: URL(fileURLWithPath: "/Users/me/app"))
        #expect(scope.contains(URL(fileURLWithPath: "/Users/me/app/../../etc/hosts")) == false)
    }

    @Test("Additions widen the scope and keep the order they were added in")
    func additionsWiden() {
        var scope = DirectoryScope(root: URL(fileURLWithPath: "/a"))
        let addedB = scope.add(URL(fileURLWithPath: "/b"))
        let addedC = scope.add(URL(fileURLWithPath: "/c"))
        #expect(addedB)
        #expect(addedC)
        #expect(scope.all.map(\.path) == ["/a", "/b", "/c"])
        #expect(scope.contains(URL(fileURLWithPath: "/b/deep/file.txt")))
    }

    @Test("Adding something already reachable reports no change")
    func duplicateAddIsRejected() {
        var scope = DirectoryScope(root: URL(fileURLWithPath: "/a"))
        let addedSelf = scope.add(URL(fileURLWithPath: "/a"))
        let addedNested = scope.add(URL(fileURLWithPath: "/a/nested"))
        #expect(addedSelf == false)
        #expect(addedNested == false)
        #expect(scope.additional.isEmpty)
    }

    @Test("A path under a directory that does not exist yet still resolves")
    func nonexistentPathIsStillPlaced() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The file to be created does not exist, so the symlink resolution that
        // turns /var into /private/var has to come from its parent.
        #expect(DirectoryScope(root: root).contains(root.appendingPathComponent("new/file.swift")))
    }
}

// MARK: - The session

@Suite("Session directories")
@MainActor
struct SessionDirectoryTests {

    private func session(root: URL?) -> ChatSession {
        ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(script: [[.text("ok"), .finish(.stop)]]),
            workingDirectory: root,
            slashCommands: SlashCommandsConfiguration(builtIns: [.addDirectory, .help]),
            permissionStore: EphemeralPermissionStore()))
    }

    @Test("The root can be changed while the transcript is empty")
    func rootIsEditableBeforeTheFirstMessage() async {
        let session = session(root: URL(fileURLWithPath: "/a"))
        #expect(session.workingDirectoryIsLocked == false)
        #expect(await session.setWorkingDirectory(URL(fileURLWithPath: "/b")))
        #expect(session.workingDirectory?.path == "/b")
    }

    @Test("The root is fixed once the conversation starts")
    func rootIsLockedAfterTheFirstMessage() async {
        let recorder = RunRecorder()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(script: [[.text("ok"), .finish(.stop)]]),
            workingDirectory: URL(fileURLWithPath: "/a"),
            permissionStore: EphemeralPermissionStore(),
            onRunFinished: { [recorder] outcome in recorder.record(outcome) }))

        session.send("hello")
        #expect(await Wait.runs(recorder))

        #expect(session.workingDirectoryIsLocked)
        #expect(await session.setWorkingDirectory(URL(fileURLWithPath: "/b")) == false)
        #expect(session.workingDirectory?.path == "/a")
    }

    @Test("Directories can still be added after the conversation starts")
    func additionsSurviveTheLock() async throws {
        let extra = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extra) }

        let recorder = RunRecorder()
        let session = ChatSession(configuration: ChatSessionConfiguration(
            backend: MockBackend(script: [[.text("ok"), .finish(.stop)]]),
            workingDirectory: URL(fileURLWithPath: "/a"),
            permissionStore: EphemeralPermissionStore(),
            onRunFinished: { [recorder] outcome in recorder.record(outcome) }))

        session.send("hello")
        #expect(await Wait.runs(recorder))

        #expect(session.workingDirectoryIsLocked)
        #expect(await session.addDirectory(extra))
        #expect(session.directories.all.count == 2)
    }

    @Test("/add-dir reports what it did, and refuses what isn't there")
    func addDirCommand() async throws {
        let extra = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extra) }

        let session = session(root: URL(fileURLWithPath: "/a"))

        // Waits on the note, not on the count: the scope widens one await
        // before the note lands.
        session.send("/add-dir \(extra.path)")
        #expect(await Wait.until { session.messages.last?.content.contains("Added") == true })
        #expect(session.directories.all.count == 2)

        session.send("/add-dir \(extra.path)")
        #expect(await Wait.until { session.messages.last?.content.contains("Already") == true })

        session.send("/add-dir /no/such/place")
        #expect(await Wait.until { session.messages.last?.content.contains("No such") == true })
        #expect(session.directories.all.count == 2)
    }

    @Test("A slash command never starts a run, so it cannot lock the root")
    func slashCommandsDoNotLock() async {
        let session = session(root: URL(fileURLWithPath: "/a"))
        session.send("/help")
        #expect(await Wait.until { !session.messages.isEmpty })
        // A note is still a message, so the transcript is no longer empty —
        // which is exactly the lock's test.
        #expect(session.workingDirectoryIsLocked)
    }

    @Test("Directories round-trip through a saved session")
    func directoriesPersist() async throws {
        let extra = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extra) }

        let first = session(root: URL(fileURLWithPath: "/a"))
        #expect(await first.addDirectory(extra))
        first.appendNote("something happened")
        let stored = first.snapshot()

        #expect(stored.additionalDirectoryPaths == [extra.standardizedFileURL.path])

        let second = session(root: nil)
        second.load(stored)
        #expect(second.workingDirectory?.path == "/a")
        #expect(second.directories.additional.map(\.path) == [extra.standardizedFileURL.path])
        // A restored conversation has a transcript, so it comes back locked.
        #expect(second.workingDirectoryIsLocked)
    }

    @Test("A new chat keeps the root as a default and drops the additions")
    func newChatResetsAdditions() async throws {
        let extra = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extra) }

        let session = session(root: URL(fileURLWithPath: "/a"))
        #expect(await session.addDirectory(extra))
        session.appendNote("something happened")

        session.newChat()
        #expect(session.workingDirectory?.path == "/a")
        #expect(session.directories.additional.isEmpty)
        #expect(session.workingDirectoryIsLocked == false)
    }

    @Test("The model is told which directories it has")
    func promptNamesTheDirectories() {
        let prompt = SystemPromptBuilder.build(
            SystemPromptContext(directories: ["/a", "/b"]))
        #expect(prompt.contains("Your working directory is /a"))
        #expect(prompt.contains("/b"))
        #expect(prompt.contains("/add-dir"))
    }

    @Test("Adding a directory changes the prompt fingerprint")
    func fingerprintCoversDirectories() {
        let before = SystemPromptBuilder.fingerprint(SystemPromptContext(directories: ["/a"]))
        let after = SystemPromptBuilder.fingerprint(SystemPromptContext(directories: ["/a", "/b"]))
        #expect(before != after)
    }
}
