//
//  SlashCommandTests.swift
//  SwiftChatKit
//
//  Leading-slash input the session answers itself, and the compaction that
//  `/compact` drives. The through-line of these tests is what the *model* ends
//  up seeing: a command is a conversation with the app, not with the model, and
//  most of the bugs here are things leaking across that line.
//

import Testing
import Foundation
@testable import ChatCore

@MainActor
private func makeSession(
    backend: any ChatBackend,
    commands: SlashCommandsConfiguration,
    store: ChatHistoryStore? = nil,
    recorder: RunRecorder
) -> ChatSession {
    ChatSession(configuration: ChatSessionConfiguration(
        backend: backend,
        slashCommands: commands,
        permissionStore: EphemeralPermissionStore(),
        historyStore: store,
        onRunFinished: { [recorder] outcome in recorder.record(outcome) }))
}

// MARK: - Parsing

@Suite("Slash commands — parsing")
struct SlashCommandParsingTests {

    @Test("A bare name parses with empty arguments")
    func bareName() {
        let parsed = SlashCommandParser.parse("/clear")
        #expect(parsed?.name == "clear")
        #expect(parsed?.arguments == "")
    }

    @Test("Everything after the name is the argument string, spaces included")
    func arguments() {
        let parsed = SlashCommandParser.parse("/review the auth module, please")
        #expect(parsed?.name == "review")
        #expect(parsed?.arguments == "the auth module, please")
    }

    @Test("Ordinary text is not a command")
    func plainText() {
        #expect(SlashCommandParser.parse("what does / mean") == nil)
    }

    @Test("A path is not a command")
    func pathsAreNotCommands() {
        // The case that makes this worth a rule: "//" reads as a name of "/"
        // under a naive parser, and the user's actual text never reaches the model.
        #expect(SlashCommandParser.parse("//server/share") == nil)
        #expect(SlashCommandParser.parse("/ leading space") == nil)
        #expect(SlashCommandParser.parse("/") == nil)
    }
}

// MARK: - Dispatch

@Suite("Slash commands — dispatch")
@MainActor
struct SlashCommandDispatchTests {

    @Test("With no commands configured, a slash goes to the model as text")
    func disabledByDefault() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [[.text("ok"), .finish(.stop)]])
        let session = makeSession(backend: backend, commands: .disabled, recorder: recorder)

        session.send("/clear")
        #expect(await Wait.runs(recorder))

        #expect(session.messages.first?.role == .user)
        #expect(session.messages.first?.content == "/clear")
    }

    @Test("An unknown command is answered locally and never reaches the model")
    func unknownCommand() async {
        let backend = MockBackend()
        let session = makeSession(backend: backend,
                                  commands: SlashCommandsConfiguration(builtIns: [.clear]),
                                  recorder: RunRecorder())

        session.send("/nope")

        #expect(session.messages.count == 1)
        #expect(session.messages[0].isLocalNote)
        #expect(session.messages[0].content.contains("Unknown command"))
        #expect(session.messages[0].content.contains("/clear"), "it should list what is available")
        #expect(await backend.receivedInputs.isEmpty)
    }

    @Test("/plan toggles plan mode and says so without asking the model")
    func planToggles() async {
        let backend = MockBackend()
        let session = makeSession(backend: backend,
                                  commands: SlashCommandsConfiguration(builtIns: [.plan]),
                                  recorder: RunRecorder())

        session.send("/plan")
        #expect(session.planMode)
        #expect(session.messages.last?.isLocalNote == true)

        session.send("/plan")
        #expect(session.planMode == false)
        #expect(await backend.receivedInputs.isEmpty)
    }

    @Test("A host command outranks the built-in of the same name")
    func customOverridesBuiltIn() async {
        let session = makeSession(
            backend: MockBackend(),
            commands: SlashCommandsConfiguration(
                builtIns: [.clear],
                custom: [SlashCommand(name: "clear", summary: "mine") { _ in .note("mine ran") }]),
            recorder: RunRecorder())

        session.send("/clear")

        #expect(session.messages.count == 1)
        #expect(session.messages[0].content == "mine ran")
    }

    @Test("A host command receives its arguments and the raw line")
    func customReceivesContext() async {
        let seen = Captured()
        let session = makeSession(
            backend: MockBackend(),
            commands: SlashCommandsConfiguration(
                custom: [SlashCommand(name: "greet", summary: "") { context in
                    seen.arguments = context.arguments
                    seen.rawInput = context.rawInput
                    return .none
                }]),
            recorder: RunRecorder())

        session.send("/greet world over")

        #expect(seen.arguments == "world over")
        #expect(seen.rawInput == "/greet world over")
        #expect(session.messages.isEmpty, ".none appends nothing")
    }

    @Test("A .prompt command shows what was typed but sends the expansion")
    func promptActionHidesExpansion() async {
        let recorder = RunRecorder()
        let backend = MockBackend(script: [[.text("done"), .finish(.stop)]])
        let session = makeSession(
            backend: backend,
            commands: SlashCommandsConfiguration(
                custom: [SlashCommand(name: "init", summary: "") { _ in
                    .prompt("A long expansion the user should never have to read.")
                }]),
            recorder: recorder)

        session.send("/init")
        #expect(await Wait.runs(recorder))

        #expect(session.messages[0].content == "/init", "the transcript shows the command")
        let sent = await backend.receivedInputs.first
        #expect(sent?.parts.contains { part in
            if case .text(let text) = part { return text.contains("A long expansion") }
            return false
        } == true, "the model gets the expansion")
    }

    @Test("/help lists commands and skills without calling the model")
    func help() async {
        let backend = MockBackend()
        let session = makeSession(
            backend: backend,
            commands: SlashCommandsConfiguration(
                builtIns: [.help, .compact],
                custom: [SlashCommand(name: "deploy", summary: "Ship it") { _ in .none }]),
            recorder: RunRecorder())

        session.send("/help")

        let text = session.messages.last?.content ?? ""
        #expect(text.contains("/deploy"))
        #expect(text.contains("Ship it"))
        #expect(text.contains("/compact"))
        #expect(await backend.receivedInputs.isEmpty)
    }

    @Test("Commands work mid-run, where a normal message would be ignored")
    func commandsInterruptWhereMessagesDoNot() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("working"), .finish(.stop)]],
                                 turnDelay: .milliseconds(400)),
            commands: SlashCommandsConfiguration(builtIns: [.plan]),
            recorder: recorder)

        session.send("hi")
        #expect(await Wait.until { session.isStreaming })

        session.send("second message")
        #expect(session.messages.contains { $0.content == "second message" } == false,
                "a concurrent run would interleave two conversations")

        session.send("/plan")
        #expect(session.planMode, "a command is not a second conversation")
    }
}

// MARK: - Local notes

@Suite("Slash commands — local notes")
@MainActor
struct LocalNoteTests {

    @Test("A local note is shown but never replayed as something the model said")
    func notesAreNotHistory() async {
        let recorder = RunRecorder()
        let session = makeSession(
            backend: MockBackend(script: [[.text("hi"), .finish(.stop)]]),
            commands: SlashCommandsConfiguration(builtIns: [.plan]),
            recorder: recorder)

        session.send("hello")
        #expect(await Wait.runs(recorder))
        session.send("/plan")

        let replayed = session.replayableTurns()
        let containsNote = replayed.contains { turn in
            turn.parts.contains { part in
                if case .text(let text) = part { return text.contains("Plan mode") }
                return false
            }
        }
        #expect(containsNote == false)
        #expect(session.messages.last?.content.contains("Plan mode") == true, "but the user sees it")
    }

    @Test("A note survives a save/load round trip as a note")
    func notesPersist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ChatHistoryStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stored = StoredSession(title: "t", messages: [
            StoredMessage(from: .user("hi")),
            StoredMessage(from: .note("**Plan mode on.**")),
        ])
        #expect(store.save(stored))

        let loaded = try #require(store.load(stored.id))
        #expect(loaded.messages[1].isLocalNote == true)
        #expect(loaded.messages[1].toChatMessage().isLocalNote)
        #expect(loaded.messages[0].toChatMessage().isLocalNote == false)
    }
}

// MARK: - Compaction

@Suite("Compaction")
@MainActor
struct CompactionTests {

    @Test("/compact replaces the transcript with one summary note")
    func compactReplacesTranscript() async {
        let backend = MockBackend(script: [[.text("a long answer"), .finish(.stop)]],
                                  generated: "They asked X; I did Y.")
        let recorder = RunRecorder()
        let session = makeSession(backend: backend,
                                  commands: SlashCommandsConfiguration(builtIns: [.compact]),
                                  recorder: recorder)

        session.send("do the thing")
        #expect(await Wait.runs(recorder))
        #expect(session.messages.count == 2)

        session.send("/compact")
        #expect(await Wait.until { session.messages.count == 1 && !session.isStreaming })

        #expect(session.messages[0].isLocalNote)
        #expect(session.messages[0].content.contains("They asked X; I did Y."))
    }

    @Test("The summary is replayed as an exchange the model took part in")
    func summarySeedsHistory() async {
        let backend = MockBackend(script: [[.text("ok"), .finish(.stop)]],
                                  generated: "Recap of the work.")
        let recorder = RunRecorder()
        let session = makeSession(backend: backend,
                                  commands: SlashCommandsConfiguration(builtIns: [.compact]),
                                  recorder: recorder)

        session.send("hi")
        #expect(await Wait.runs(recorder))
        session.send("/compact")
        #expect(await Wait.until { session.messages.count == 1 && !session.isStreaming })

        let turns = session.replayableTurns()
        // A history of one model turn is a shape most providers reject, which is
        // why the summary goes in as a user turn the model then acknowledges.
        #expect(turns.count == 2)
        #expect(turns[0].role == .user)
        #expect(turns[1].role == .model)
        #expect(turns[0].parts.contains { part in
            if case .text(let text) = part { return text.contains("Recap of the work.") }
            return false
        } == true)
    }

    @Test("Compaction sends the transcript but not the bulky tool results")
    func toolResultsAreDroppedFromTheSummaryPrompt() async {
        let backend = MockBackend(generated: "summary")
        let session = makeSession(backend: backend,
                                  commands: SlashCommandsConfiguration(builtIns: [.compact]),
                                  recorder: RunRecorder())

        session.send("/compact")   // nothing to compact yet
        #expect(await backend.generatePrompts.isEmpty)

        let call = ToolCall(id: "1", name: "readFile", arguments: ["path": "a.txt"])
        session.appendForTesting(.user("read a.txt"))
        session.appendForTesting(.toolCall(call))
        session.appendForTesting(.toolResult(.success(call, ["content": "SECRET_BULK"])))

        session.send("/compact")
        #expect(await Wait.until { !session.isStreaming && session.messages.count == 1 })

        let prompt = try? #require(await backend.generatePrompts.first)
        #expect(prompt?.contains("read a.txt") == true)
        #expect(prompt?.contains("Tool call: readFile") == true)
        #expect(prompt?.contains("SECRET_BULK") == false,
                "shedding this bulk is the point of compacting")
    }

    @Test("A failed compaction reports and leaves the conversation intact")
    func failureIsNonDestructive() async {
        let recorder = RunRecorder()
        let session = makeSession(backend: FailingBackend(),
                                  commands: SlashCommandsConfiguration(builtIns: [.compact]),
                                  recorder: recorder)

        session.appendForTesting(.user("something worth keeping"))
        session.send("/compact")
        #expect(await Wait.until { session.error != nil })

        #expect(session.messages.count == 1)
        #expect(session.messages[0].content == "something worth keeping")
        #expect(session.isStreaming == false)
    }

    @Test("/clear deletes the saved transcript, /new keeps it")
    func clearVersusNew() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = ChatHistoryStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = RunRecorder()
        let session = makeSession(backend: MockBackend(script: [[.text("ok"), .finish(.stop)]]),
                                  commands: SlashCommandsConfiguration(builtIns: [.clear, .newChat]),
                                  store: store,
                                  recorder: recorder)

        session.send("keep me")
        #expect(await Wait.runs(recorder))
        let firstID = session.sessionID

        session.send("/new")
        #expect(session.messages.isEmpty)
        #expect(store.load(firstID) != nil, "/new saves what it closes")

        session.send("hello again")
        #expect(await Wait.runs(recorder, count: 2))
        let secondID = session.sessionID

        session.send("/clear")
        #expect(session.messages.isEmpty)
        #expect(store.load(secondID) == nil, "/clear is meant to leave nothing behind")
    }
}

// MARK: - Support

/// Box for values a command handler captures; the handler is `@Sendable` and
/// cannot write to a local.
@MainActor
private final class Captured {
    var arguments = ""
    var rawInput = ""
}

private extension ChatSession {
    /// Seeds the transcript without a round trip, for tests about what happens
    /// to an existing conversation rather than about how it got there.
    func appendForTesting(_ message: ChatMessage) {
        messages.append(message)
    }
}
