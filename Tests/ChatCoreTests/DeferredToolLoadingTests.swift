//
//  DeferredToolLoadingTests.swift
//  SwiftChatKit
//
//  The deferral mechanism end to end: a tool the model cannot see, a search
//  that finds it, and the rebuild that makes it callable on the next step.
//

import Foundation
import Testing
@testable import ChatCore

@MainActor
private func makeSession(backend: any ChatBackend,
                         providers: [any ToolProvider],
                         deferred: Set<String>) -> ChatSession {
    ChatSession(configuration: ChatSessionConfiguration(
        backend: backend,
        toolProviders: providers,
        deferredToolNames: deferred,
        permissionStore: EphemeralPermissionStore()))
}

private func specialist() -> MockProvider {
    MockProvider(
        tools: [
            ToolDeclaration(name: "readFile", description: "Reads a file.",
                            parameters: ["path": .string()]),
            ToolDeclaration(name: "createXcodeProject",
                            description: "Scaffolds a new Xcode project on disk.",
                            parameters: ["name": .string()]),
        ],
        autoAllowed: ["readFile", "createXcodeProject"])
}

private func searchCall(_ query: String) -> TurnChunk {
    .toolCall(ToolCall(name: AgentTools.toolSearch, arguments: ["query": .string(query)]))
}

@Suite("Deferred tools — loading")
@MainActor
struct DeferredToolLoadingTests {

    @Test("A deferred tool is withheld and toolSearch is offered in its place")
    func deferredToolIsHidden() async {
        let backend = MockBackend(script: [[.text("hi"), .finish(.stop)]])
        let session = makeSession(backend: backend,
                                  providers: [specialist()],
                                  deferred: ["createXcodeProject"])

        session.send("hello")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        let configured = await backend.configuredTools
        let names = configured.map(\.name)
        #expect(names.contains("readFile"))
        #expect(names.contains("createXcodeProject") == false)
        #expect(names.contains(AgentTools.toolSearch))
    }

    @Test("With nothing deferred, no toolSearch is offered at all")
    func noDeferralNoSearch() async {
        let backend = MockBackend(script: [[.text("hi"), .finish(.stop)]])
        let session = makeSession(backend: backend, providers: [specialist()], deferred: [])

        session.send("hello")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        let configured = await backend.configuredTools
        let names = configured.map(\.name)
        #expect(names.contains("createXcodeProject"))
        #expect(names.contains(AgentTools.toolSearch) == false)
    }

    @Test("Searching loads the tool and rebuilds the model mid-run")
    func searchLoadsTool() async {
        let backend = MockBackend(script: [
            [searchCall("create a new Xcode project"), .finish(.stop)],
            [.text("Found it."), .finish(.stop)],
        ])
        let session = makeSession(backend: backend,
                                  providers: [specialist()],
                                  deferred: ["createXcodeProject"])

        session.send("make me an app")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        // The rebuild happened before the tool results were sent, so the very
        // next turn can call what was just found.
        let configured = await backend.configuredTools
        let names = configured.map(\.name)
        #expect(names.contains("createXcodeProject"))
        // Nothing left to find, so the search tool retires.
        #expect(names.contains(AgentTools.toolSearch) == false)
    }

    @Test("The rebuild keeps the history, so the pending tool call is still answerable")
    func rebuildPreservesHistory() async {
        let backend = MockBackend(script: [
            [searchCall("xcode project"), .finish(.stop)],
            [.text("done"), .finish(.stop)],
        ])
        let session = makeSession(backend: backend,
                                  providers: [specialist()],
                                  deferred: ["createXcodeProject"])

        session.send("make me an app")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        // The turn after the search must be the tool results — if the rebuild
        // had dropped the model's committed call, this would be a fresh message.
        let inputs = await backend.receivedInputs
        #expect(inputs.count == 2)
        let isToolResults = inputs[1].parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
        #expect(isToolResults)
    }

    @Test("The search result names what it found without shipping full schemas")
    func searchResultShape() async {
        let backend = MockBackend(script: [
            [searchCall("create an xcode project"), .finish(.stop)],
        ])
        let session = makeSession(backend: backend,
                                  providers: [specialist()],
                                  deferred: ["createXcodeProject"])

        session.send("go")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        let inputs = await backend.receivedInputs
        guard case .toolResult(let result) = inputs[1].parts.first else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.payload["found"]?.intValue == 1)
        #expect(result.payload["tools"]?.stringValue?.contains("createXcodeProject") == true)
    }

    @Test("A search that matches nothing lists what does exist instead of failing")
    func noMatchIsGuidance() async {
        let backend = MockBackend(script: [
            [searchCall("send an email"), .finish(.stop)],
        ])
        let session = makeSession(backend: backend,
                                  providers: [specialist()],
                                  deferred: ["createXcodeProject"])

        session.send("go")
        #expect(await Wait.until { !session.isStreaming && session.messages.count >= 2 })

        let inputs = await backend.receivedInputs
        guard case .toolResult(let result) = inputs[1].parts.first else {
            Issue.record("expected a tool result")
            return
        }
        // Not an error: an error invites a retry, and retrying finds nothing again.
        #expect(result.errorMessage == nil)
        #expect(result.payload["found"]?.intValue == 0)
        #expect(result.payload["note"]?.stringValue?.contains("createXcodeProject") == true)
    }
}
