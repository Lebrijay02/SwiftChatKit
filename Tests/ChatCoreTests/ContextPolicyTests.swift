//
//  ContextPolicyTests.swift
//  SwiftChatKit
//
//  The two ways a session keeps itself inside the context window: capping any
//  one tool result, and compacting once the reported prompt size crosses a
//  threshold.
//

import Foundation
import Testing
@testable import ChatCore

@Suite("Context policy — thresholds")
struct ContextPolicyThresholdTests {

    @Test("An unbounded policy never compacts, however large the turn")
    func unbounded() {
        #expect(ContextPolicy.unbounded.shouldCompact(afterPromptTokens: 10_000_000) == false)
    }

    @Test("Compaction fires at the threshold, not before")
    func threshold() {
        let policy = ContextPolicy.window(1_000, threshold: 0.75)
        #expect(policy.shouldCompact(afterPromptTokens: 749) == false)
        #expect(policy.shouldCompact(afterPromptTokens: 750))
        #expect(policy.shouldCompact(afterPromptTokens: 5_000))
    }

    @Test("A turn that reported no usage does not trigger compaction")
    func zeroUsage() {
        // Providers occasionally omit usage. Treating "unknown" as "enormous"
        // would compact a conversation that had barely started.
        #expect(ContextPolicy.window(1_000).shouldCompact(afterPromptTokens: 0) == false)
    }
}

@Suite("Context policy — tool result truncation")
struct ContextPolicyTruncationTests {

    private func result(_ text: String) -> ToolResult {
        ToolResult(callID: "c", name: "readFile", payload: ["content": .string(text)])
    }

    @Test("A result under the cap is returned untouched")
    func underCap() {
        let policy = ContextPolicy(maxToolResultCharacters: 100)
        let original = result(String(repeating: "a", count: 100))
        #expect(policy.truncating(original) == original)
    }

    @Test("An oversized string is cut and marked")
    func overCap() {
        let policy = ContextPolicy(maxToolResultCharacters: 50)
        let text = policy.truncating(result(String(repeating: "a", count: 500)))
            .payload["content"]?.stringValue

        let content = try? #require(text)
        #expect(content?.hasPrefix(String(repeating: "a", count: 50)) == true)
        // The model has to be told, or it reports on a file it only half read.
        #expect(content?.contains("truncated 450 characters") == true)
    }

    @Test("No cap means no truncation")
    func noCap() {
        let original = result(String(repeating: "a", count: 1_000_000))
        #expect(ContextPolicy.unbounded.truncating(original) == original)
    }

    @Test("Non-string values are left alone")
    func nonStrings() {
        let policy = ContextPolicy(maxToolResultCharacters: 1)
        let original = ToolResult(callID: "c", name: "count",
                                  payload: ["total": .number(123_456)])
        #expect(policy.truncating(original) == original)
    }
}

@Suite("Context policy — automatic compaction")
@MainActor
struct AutoCompactionTests {

    private func turn(prompt: Int) -> [TurnChunk] {
        [.text("answered"),
         .usage(TokenUsage(prompt: prompt, completion: 10, total: prompt + 10)),
         .finish(.stop)]
    }

    private func session(_ backend: MockBackend,
                         recorder: RunRecorder) -> ChatSession {
        ChatSession(configuration: ChatSessionConfiguration(
            backend: backend,
            context: .window(1_000, threshold: 0.5),
            onRunFinished: { [recorder] outcome in recorder.record(outcome) }))
    }

    @Test("A turn that crosses the threshold compacts once the answer is in")
    func compactsAfterRun() async {
        let backend = MockBackend(script: [turn(prompt: 900)], generated: "the summary")
        let recorder = RunRecorder()
        let chat = session(backend, recorder: recorder)

        chat.send("hello")
        #expect(await Wait.runs(recorder))

        // The transcript collapses to the summary note — and the user's message
        // was answered before it was folded in.
        #expect(chat.messages.count == 1)
        #expect(chat.messages.first?.isLocalNote == true)
        #expect(chat.messages.first?.content.contains("the summary") == true)
        #expect(await backend.generatePrompts.count == 1)
    }

    @Test("A turn under the threshold leaves the transcript alone")
    func staysUnderThreshold() async {
        let backend = MockBackend(script: [turn(prompt: 100)], generated: "the summary")
        let recorder = RunRecorder()
        let chat = session(backend, recorder: recorder)

        chat.send("hello")
        #expect(await Wait.runs(recorder))

        #expect(chat.messages.count == 2)
        #expect(await backend.generatePrompts.isEmpty)
    }

    @Test("Compaction is not retried on the very next turn")
    func doesNotLoop() async {
        // The second turn reports no usage at all. A session that kept reading
        // the pre-compaction figure would summarize itself after every turn
        // from here on.
        let backend = MockBackend(script: [turn(prompt: 900), [.text("ok"), .finish(.stop)]],
                                  generated: "the summary")
        let recorder = RunRecorder()
        let chat = session(backend, recorder: recorder)

        chat.send("hello")
        #expect(await Wait.runs(recorder))
        chat.send("again")
        #expect(await Wait.runs(recorder, count: 2))

        #expect(await backend.generatePrompts.count == 1)
    }
}

@Suite("Context policy — sliding window")
@MainActor
struct SlidingWindowTests {

    private func turn(prompt: Int) -> [TurnChunk] {
        [.text("answered"),
         .usage(TokenUsage(prompt: prompt, completion: 10, total: prompt + 10)),
         .finish(.stop)]
    }

    private func session(_ backend: MockBackend, recorder: RunRecorder) -> ChatSession {
        ChatSession(configuration: ChatSessionConfiguration(
            backend: backend,
            context: .window(1_000, threshold: 0.5, overflow: .slidingWindow),
            onRunFinished: { [recorder] outcome in recorder.record(outcome) }))
    }

    @Test("Crossing the threshold keeps the transcript and never summarizes")
    func keepsTranscript() async {
        let backend = MockBackend(script: [turn(prompt: 900), turn(prompt: 100)],
                                  generated: "the summary")
        let recorder = RunRecorder()
        let chat = session(backend, recorder: recorder)

        chat.send("first")
        #expect(await Wait.runs(recorder))
        chat.send("second")
        #expect(await Wait.runs(recorder, count: 2))

        // Every message is still on screen, and no summary was ever requested.
        #expect(chat.messages.count == 4)
        #expect(chat.messages.allSatisfy { $0.isLocalNote == false })
        #expect(await backend.generatePrompts.isEmpty)
    }

    @Test("Only the recent tail is replayed to the backend")
    func replaysTail() async {
        let backend = MockBackend(script: [turn(prompt: 900), turn(prompt: 900), turn(prompt: 100)],
                                  generated: "unused")
        let recorder = RunRecorder()
        let chat = session(backend, recorder: recorder)

        chat.send("the oldest message")
        #expect(await Wait.runs(recorder))
        chat.send("the middle message")
        #expect(await Wait.runs(recorder, count: 2))
        chat.send("the newest message")
        #expect(await Wait.runs(recorder, count: 3))

        // The window slid once the transcript was long enough to have a tail,
        // so the last send configured history without the opening message.
        let replayed = await backend.configuredHistory
        let texts = replayed.flatMap { turn in
            turn.parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
        }
        #expect(!texts.contains("the oldest message"))
    }
}
