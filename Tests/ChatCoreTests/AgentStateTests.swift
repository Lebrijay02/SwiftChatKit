//
//  AgentStateTests.swift
//  SwiftChatKitTests
//
//  Covers the agent-state services: questions, skills discovery, transcript
//  persistence and system-prompt assembly.
//

import Foundation
import Testing
@testable import ChatCore

// MARK: - Questions

@Suite("Question parsing")
struct QuestionServiceTests {

    private func arguments(_ json: String) -> [String: ChatValue] {
        ChatValue.parse(json)?.objectValue ?? [:]
    }

    @Test("A full payload parses into questions with options")
    func fullPayload() throws {
        let parsed = QuestionService.parse(arguments("""
        {"questions": [{
            "question": "Which backend?",
            "header": "Backend",
            "multiSelect": false,
            "options": [
                {"label": "Gemini", "description": "Vertex AI"},
                {"label": "Local", "description": "On-device"}
            ]
        }]}
        """))

        let questions = try #require(parsed)
        #expect(questions.count == 1)
        #expect(questions[0].question == "Which backend?")
        #expect(questions[0].header == "Backend")
        #expect(questions[0].multiSelect == false)
        #expect(questions[0].options.map(\.label) == ["Gemini", "Local"])
        #expect(questions[0].options[0].description == "Vertex AI")
    }

    @Test("Optional fields fall back rather than dropping the question")
    func minimalPayload() throws {
        let questions = try #require(QuestionService.parse(
            arguments(#"{"questions": [{"question": "Proceed?"}]}"#)))
        #expect(questions[0].header.isEmpty)
        #expect(questions[0].options.isEmpty)
        #expect(questions[0].multiSelect == false)
    }

    @Test("More than four questions is an interrogation, so the rest are dropped")
    func questionCap() throws {
        let items = (1...9).map { #"{"question": "Q\#($0)"}"# }.joined(separator: ",")
        let questions = try #require(QuestionService.parse(arguments("{\"questions\": [\(items)]}")))
        #expect(questions.count == QuestionService.maxQuestions)
        #expect(questions.last?.question == "Q4")
    }

    @Test("Unusable payloads return nil so the loop can report a tool error")
    func unusablePayloads() {
        #expect(QuestionService.parse([:]) == nil)
        #expect(QuestionService.parse(arguments(#"{"questions": []}"#)) == nil)
        // Entries without a question text are skipped; nothing usable remains.
        #expect(QuestionService.parse(arguments(#"{"questions": [{"header": "X"}]}"#)) == nil)
        #expect(QuestionService.parse(arguments(#"{"questions": "not an array"}"#)) == nil)
    }

    @Test("Options missing a label are skipped, but the question survives")
    func malformedOption() throws {
        let questions = try #require(QuestionService.parse(arguments("""
        {"questions": [{"question": "Pick", "options": [{"description": "no label"}, {"label": "ok"}]}]}
        """)))
        #expect(questions[0].options.map(\.label) == ["ok"])
    }
}

// MARK: - Skills

@Suite("Skill frontmatter")
struct SkillFrontmatterTests {

    @Test("Simple key/value pairs parse")
    func simple() {
        let meta = SkillsService.parseFrontmatter("""
        ---
        name: my-skill
        description: Does a thing
        ---
        Body text.
        """)
        #expect(meta["name"] == "my-skill")
        #expect(meta["description"] == "Does a thing")
    }

    @Test("Quoted values are unwrapped")
    func quoted() {
        let meta = SkillsService.parseFrontmatter("---\nname: \"quoted\"\nother: 'single'\n---\n")
        #expect(meta["name"] == "quoted")
        #expect(meta["other"] == "single")
    }

    @Test("Folded scalars join their indented continuation lines")
    func foldedScalar() {
        let meta = SkillsService.parseFrontmatter("""
        ---
        name: folded
        description: >-
          first line
          second line
        ---
        """)
        #expect(meta["description"] == "first line second line")
        #expect(meta["name"] == "folded")
    }

    @Test("A file without frontmatter yields no metadata and keeps its body")
    func noFrontmatter() {
        let text = "# Just markdown\n\nNo frontmatter here."
        #expect(SkillsService.parseFrontmatter(text).isEmpty)
        #expect(SkillsService.stripFrontmatter(text) == text)
    }

    @Test("Stripping removes the frontmatter block and surrounding blank lines")
    func strip() {
        let body = SkillsService.stripFrontmatter("---\nname: x\n---\n\n# Heading\n\nText.\n")
        #expect(body == "# Heading\n\nText.")
    }
}

@Suite("Skill discovery")
@MainActor
struct SkillDiscoveryTests {

    /// Builds a throwaway skills tree and returns its root.
    private func makeSkills(_ skills: [(name: String, description: String)]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftChatKitTests-\(UUID().uuidString)", isDirectory: true)
        for skill in skills {
            let dir = root.appendingPathComponent(skill.name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            ---
            name: \(skill.name)
            description: \(skill.description)
            ---
            Instructions for \(skill.name).
            """.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Skills are discovered, sorted, and readable")
    func discovery() throws {
        let root = try makeSkills([("zebra", "Last"), ("alpha", "First")])
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService(configuration: .init(globalDirectory: root))
        let found = service.refresh(workingDirectory: nil)

        #expect(found.map(\.name) == ["alpha", "zebra"])
        #expect(found[0].description == "First")
        #expect(found[0].scope == .global)

        let alpha = try #require(service.skill(named: "ALPHA"))  // lookup is case-insensitive
        #expect(try service.skillBody(alpha) == "Instructions for alpha.")
    }

    @Test("A local skill shadows a global one of the same name")
    func localShadowsGlobal() throws {
        let global = try makeSkills([("shared", "global version"), ("only-global", "kept")])
        let project = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftChatKitProject-\(UUID().uuidString)", isDirectory: true)
        let local = try makeSkills([("shared", "local version")])
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: local, to: project.appendingPathComponent(".claude/skills"))
        defer {
            try? FileManager.default.removeItem(at: global)
            try? FileManager.default.removeItem(at: project)
        }

        let service = SkillsService(configuration: .init(globalDirectory: global,
                                                         projectRelativePath: ".claude/skills"))
        let found = service.refresh(workingDirectory: project)

        #expect(found.count == 2)
        #expect(service.skill(named: "shared")?.description == "local version")
        #expect(service.skill(named: "shared")?.scope == .local)
        #expect(service.skill(named: "only-global") != nil)
    }

    @Test("Disabled configuration discovers nothing")
    func disabled() throws {
        let root = try makeSkills([("alpha", "First")])
        defer { try? FileManager.default.removeItem(at: root) }

        var config = SkillsConfiguration.disabled
        config.globalDirectory = root
        let service = SkillsService(configuration: config)

        #expect(service.refresh(workingDirectory: nil).isEmpty)
        #expect(service.skillsText().isEmpty)
    }

    @Test("A missing skills directory is not an error")
    func missingDirectory() {
        let service = SkillsService(configuration: .init(
            globalDirectory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))
        #expect(service.refresh(workingDirectory: nil).isEmpty)
    }

    @Test("The prompt section lists skills, and the hash tracks changes")
    func promptSection() throws {
        let root = try makeSkills([("alpha", "Does alpha things")])
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService(configuration: .init(globalDirectory: root))
        #expect(service.skillsText().isEmpty)          // nothing scanned yet
        #expect(service.skillsHash().isEmpty)

        service.refresh(workingDirectory: nil)
        #expect(service.skillsText().contains("- alpha (global): Does alpha things"))
        #expect(service.skillsText().contains(SkillsService.toolName))
        #expect(service.skillsHash() == "Global:alpha:Does alpha things")
    }

    @Test("useSkill returns the body plus the folder, and names missing skills")
    func executeTool() throws {
        let root = try makeSkills([("alpha", "Does alpha things")])
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService(configuration: .init(globalDirectory: root))
        service.refresh(workingDirectory: nil)

        let ok = service.execute(ToolCall(name: "useSkill", arguments: ["name": "alpha"]))
        #expect(ok.errorMessage == nil)
        #expect(ok.payload["instructions"]?.stringValue == "Instructions for alpha.")
        #expect(ok.payload["directory"]?.stringValue?.hasSuffix("alpha") == true)

        // A wrong name lists what is installed, so the model can self-correct.
        let missing = service.execute(ToolCall(name: "useSkill", arguments: ["name": "nope"]))
        #expect(missing.errorMessage?.contains("alpha") == true)

        let noArgs = service.execute(ToolCall(name: "useSkill"))
        #expect(noArgs.errorMessage?.contains("name") == true)
    }
}

// MARK: - History

@Suite("Chat history store")
struct ChatHistoryStoreTests {

    private func makeStore() -> ChatHistoryStore {
        ChatHistoryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftChatKitHistory-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("A session round-trips through disk with its tool payloads intact")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let call = ToolCall(name: "readTextFile", arguments: ["path": "/tmp/a.swift", "limit": 10])
        let messages: [ChatMessage] = [
            .user("Read the file"),
            .toolCall(call),
            .toolResult(.success(call, ["content": "hello"])),
            .assistant("It says hello."),
        ]

        let session = StoredSession(title: "Test",
                                    messages: messages.map(StoredMessage.init(from:)),
                                    usage: TokenUsage(prompt: 10, completion: 5, total: 15),
                                    workingDirectoryPath: "/tmp",
                                    modelName: "test-model")
        #expect(store.save(session))

        let loaded = try #require(store.load(session.id))
        #expect(loaded.title == "Test")
        #expect(loaded.usage == TokenUsage(prompt: 10, completion: 5, total: 15))
        #expect(loaded.workingDirectoryPath == "/tmp")
        #expect(loaded.messages.count == 4)

        // The exact payloads survive — this is what history replay depends on.
        #expect(loaded.messages[1].rawArguments == call.arguments)
        #expect(loaded.messages[1].rawArguments?["limit"]?.intValue == 10)
        #expect(loaded.messages[2].rawResult?["content"]?.stringValue == "hello")

        let restored = loaded.messages.map { $0.toChatMessage() }
        #expect(restored[0].role == .user)
        #expect(restored[1].role == .toolCall(toolName: "readTextFile"))
        #expect(restored[3].content == "It says hello.")
        #expect(restored.allSatisfy { !$0.isStreaming })
    }

    @Test("Attachment bytes are dropped but their names are kept")
    func attachmentsAreNotPersisted() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let big = Attachment.image(Data(repeating: 0xFF, count: 4096),
                                   mimeType: "image/png", filename: "shot.png")
        let stored = StoredMessage(from: .user("Look", attachments: [big]))
        #expect(stored.attachmentNames == ["shot.png"])
        #expect(stored.toChatMessage().attachments == nil)
    }

    @Test("A tool message without payloads is flagged unreplayable")
    func replayability() {
        var call = StoredMessage(from: .toolCall(ToolCall(name: "x", arguments: ["a": 1])))
        #expect(call.isReplayable)
        call.rawArguments = nil
        #expect(!call.isReplayable)
        // Prose messages are always replayable — they carry no structured payload.
        #expect(StoredMessage(from: .user("hi")).isReplayable)
    }

    @Test("loadAll sorts newest first and skips corrupt files")
    func loadAllOrdering() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let old = StoredSession(title: "Older", updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = StoredSession(title: "Newer", updatedAt: Date(timeIntervalSince1970: 2_000))
        store.save(old)
        store.save(new)

        // One bad transcript must not hide the rest of the user's history.
        try "{ not json".write(to: store.directory.appendingPathComponent("broken.json"),
                               atomically: true, encoding: .utf8)

        #expect(store.loadAll().map(\.title) == ["Newer", "Older"])
    }

    @Test("Deleting removes only the named session")
    func delete() {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let a = StoredSession(title: "A")
        let b = StoredSession(title: "B")
        store.save(a)
        store.save(b)
        store.delete(a.id)

        #expect(store.load(a.id) == nil)
        #expect(store.load(b.id) != nil)
    }

    @Test("Loading from a directory that was never created returns empty")
    func missingDirectory() {
        #expect(makeStore().loadAll().isEmpty)
    }

    @Test("Titles come from the first non-empty line of the first user message")
    func derivedTitles() {
        #expect(ChatHistoryStore.derivedTitle(from: []) == "New chat")
        #expect(ChatHistoryStore.derivedTitle(from: [.assistant("hi")]) == "New chat")
        #expect(ChatHistoryStore.derivedTitle(from: [.user("\n\nRefactor this\nand that")])
                == "Refactor this")

        let long = String(repeating: "a", count: 100)
        let title = ChatHistoryStore.derivedTitle(from: [.user(long)])
        #expect(title.count == 61 && title.hasSuffix("…"))
    }
}

// MARK: - System prompt

@Suite("System prompt assembly")
struct SystemPromptTests {

    @Test("The default persona includes every standing block")
    func defaultPersona() {
        let prompt = SystemPromptBuilder.build(SystemPromptContext())
        #expect(prompt.contains("# Communication"))
        #expect(prompt.contains("# Code"))
        #expect(prompt.contains("# Working with files"))
        #expect(prompt.contains("# Running commands"))
        #expect(prompt.contains("# Task management"))
        #expect(prompt.contains("# Doing tasks"))
    }

    @Test("Nil persona blocks are omitted entirely")
    func minimalPersona() {
        let prompt = SystemPromptBuilder.build(SystemPromptContext(persona: .minimal))
        #expect(prompt.contains("# Communication"))
        #expect(!prompt.contains("# Working with files"))
        #expect(!prompt.contains("# Running commands"))
        #expect(!prompt.contains("# Code"))
    }

    @Test("The package ships no host-specific identity")
    func neutralByDefault() {
        let prompt = SystemPromptBuilder.build(SystemPromptContext())
        for leak in ["Frida", "Softtek", "Xcode", "SwiftUI", "CLAUDE.md"] {
            #expect(!prompt.contains(leak), "default prompt leaked '\(leak)'")
        }
    }

    @Test("A custom identity replaces only the identity block")
    func customIdentity() {
        var persona = ChatPersona.default
        persona.identity = "You are Acme Helper."
        let prompt = SystemPromptBuilder.build(SystemPromptContext(persona: persona))
        #expect(prompt.hasPrefix("You are Acme Helper."))
        #expect(prompt.contains("# Communication"))
    }

    @Test("Conditional sections appear only when supplied")
    func conditionalSections() {
        let bare = SystemPromptBuilder.build(SystemPromptContext())
        #expect(!bare.contains("Plan mode (ACTIVE)"))
        #expect(!bare.contains("# Skills"))

        let full = SystemPromptBuilder.build(SystemPromptContext(
            planMode: true,
            skillsText: "\n# Skills\n- alpha",
            compressorInstruction: "\n# Compressed results\nDetail.",
            projectContext: "Always use tabs.",
            projectContextTitle: "Project instructions (AGENTS.md)",
            additionalSections: ["# Catalog\n- Button"]))

        #expect(full.contains("Plan mode (ACTIVE)"))
        #expect(full.contains("# Skills"))
        #expect(full.contains("# Compressed results"))
        #expect(full.contains("# Catalog"))
        #expect(full.contains("Project instructions (AGENTS.md)"))
        #expect(full.contains("Always use tabs."))
    }

    @Test("Project context is placed last so it outranks the defaults")
    func projectContextPrecedence() {
        let prompt = SystemPromptBuilder.build(SystemPromptContext(
            skillsText: "\n# Skills\n- alpha",
            projectContext: "Always use tabs."))
        let skills = try! #require(prompt.range(of: "# Skills"))
        let project = try! #require(prompt.range(of: "Always use tabs."))
        #expect(skills.lowerBound < project.lowerBound)
        #expect(prompt.contains("override your defaults"))
    }

    @Test("Empty additional sections don't leave stray blank lines")
    func emptySectionsSkipped() {
        let with = SystemPromptBuilder.build(SystemPromptContext(additionalSections: ["", ""]))
        let without = SystemPromptBuilder.build(SystemPromptContext())
        #expect(with == without)
    }

    @Test("The fingerprint changes with every input the prompt is built from")
    func fingerprintTracksInputs() {
        let base = SystemPromptContext()
        let baseline = SystemPromptBuilder.fingerprint(base)
        #expect(SystemPromptBuilder.fingerprint(base) == baseline)

        var planned = base;  planned.planMode = true
        var skilled = base;  skilled.skillsText = "# Skills"
        var context = base;  context.projectContext = "tabs"
        var extra = base;    extra.additionalSections = ["# Catalog"]
        var squashed = base; squashed.compressorInstruction = "# Compressed"

        for changed in [planned, skilled, context, extra, squashed] {
            #expect(SystemPromptBuilder.fingerprint(changed) != baseline)
        }
    }
}
