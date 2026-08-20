// Compile-check for the code samples in README.md. Imports ChatCore without
// @testable, so anything here is genuinely part of the public surface.
import Foundation
import ChatCore

// --- Markdown ---
func readme_markdown() {
    let blocks = MarkdownBlockParser.parse("# Title\n\nSome **bold** text.")
    for block in blocks {
        switch block {
        case .heading(let level, let content, _): _ = (level, content)
        case .paragraph(let inlines): _ = inlines
        case .codeBlock(let language, let code): _ = (language, code)
        case .list(let items): _ = items.map { ($0.depth, $0.marker) }
        case .table(let t): _ = (t.headers, t.alignments, t.rows)
        case .blockQuote(let depth, let content): _ = (depth, content)
        case .mathBlock(let m): _ = m
        case .thematicBreak: break
        case .definitionList(let d): _ = d
        case .footnoteDefinition(let label, let content): _ = (label, content)
        }
    }
    _ = MarkdownInlineParser.parse("a `code` span and [a link](https://example.com)")
    _ = MarkdownMath.render(#"\frac{a}{b}"#)
    _ = MarkdownMath.looksLikeMath("x^2")
}

// --- ChatValue ---
func readme_chatValue() throws {
    let args: ChatValue = ["path": "/tmp/a.swift", "limit": 100, "replaceAll": false, "tags": ["x"]]
    _ = args["path"]?.stringValue
    _ = args["limit"]?.intValue
    _ = args["replaceAll"]?.boolValue
    _ = args["tags"]?.arrayValue
    _ = args.jsonString(prettyPrinted: true)
    _ = ChatValue.parse(#"{"ok":true}"#)
    _ = ChatValue(json: ["k": 1] as [String: Any])
    _ = args.jsonObject
    _ = try JSONEncoder().encode(args)
}

// --- Tool declarations ---
let readme_tool = ToolDeclaration(
    name: "readTextFile",
    description: "Read a UTF-8 text file.",
    parameters: [
        "path": .string(description: "Absolute path to the file."),
        "limit": .integer(description: "Maximum number of lines."),
        "mode": .enumeration(values: ["head", "tail"], description: "Which end to read."),
        "options": .object(properties: ["trim": .boolean()], optional: ["trim"]),
        "globs": .array(items: .string(), description: "Filters."),
    ],
    optional: ["limit", "mode", "options", "globs"])

// --- Attachments ---
func readme_attachments(jpeg: Data, url: URL) {
    _ = Attachment.image(jpeg, mimeType: "image/jpeg", filename: "shot.jpg")
    _ = Attachment.pdf(Data(), filename: "spec.pdf")
    _ = Attachment.contentsOf(url)
    _ = Attachment(kind: .image, data: jpeg, mimeType: "image/png")
}

// --- Messages ---
func readme_messages() {
    var transcript: [ChatMessage] = [.user("Hi", attachments: nil), .assistant("Hello", isStreaming: true)]
    let call = ToolCall(name: "readTextFile", arguments: ["path": "/tmp/a"])
    transcript.append(.toolCall(call))
    transcript.append(.toolResult(.success(call, ["content": "hi"])))
    transcript.append(.toolResult(.failure(call, "No such file")))
    for m in transcript {
        _ = (m.id, m.role, m.content, m.timestamp, m.isStreaming, m.status, m.callID, m.duration)
        _ = (m.rawArguments, m.rawResult, m.attachments, m.toolName)
        if case .toolCall(let name) = m.role { _ = name }
    }
}

// --- Permissions ---
@MainActor
func readme_permissions() async {
    let permissions = PermissionService(
        autoAllowed: ["readTextFile", "listDirectory"],
        store: UserDefaultsPermissionStore(key: "MyApp.alwaysAllowedTools"))
    _ = PermissionService(autoAllowed: [], store: EphemeralPermissionStore())
    if permissions.requiresApproval("writeFile") {
        let decision = await permissions.request(
            PermissionRequest(kind: .tool, toolName: "writeFile",
                              title: "Write Notes.swift", detail: "…diff…"))
        _ = decision == .allowOnce
    }
    permissions.resolve(.alwaysAllow)
    permissions.cancelPending()
    permissions.revokeAlwaysAllow("writeFile")
    _ = (permissions.pending, permissions.alwaysAllowed, permissions.autoAllowed)
    _ = PermissionRequest.generic(for: ToolCall(name: "x"))
}

// --- Implementing a ToolProvider ---
final class EchoToolProvider: ToolProvider {
    var declarations: [ToolDeclaration] {
        get async {
            [ToolDeclaration(name: "echo", description: "Echo text back.",
                             parameters: ["text": .string()])]
        }
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        guard let text = call.arguments["text"]?.stringValue else {
            return .failure(call, "Missing required argument: text")
        }
        return .success(call, ["echoed": .string(text)])
    }

    func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        PermissionRequest(toolName: call.name, title: "Echo",
                          detail: call.arguments["text"]?.stringValue ?? "")
    }

    var autoAllowedToolNames: Set<String> { ["echo"] }
    var mutatingToolNames: Set<String> { [] }
}

// --- Implementing a ChatBackend ---
actor EchoBackend: ChatBackend {
    private var turns: [ChatTurn] = []
    var history: [ChatTurn] { turns }
    var modelName: String { "echo-1" }

    func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) {
        turns = history
    }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            for part in input.parts {
                if case .text(let t) = part { continuation.yield(.text(t)) }
            }
            continuation.yield(.usage(TokenUsage(prompt: 1, completion: 1, total: 2)))
            continuation.yield(.finish(.stop))
            continuation.finish()
        }
    }
}

func readme_backend() async throws {
    let backend = EchoBackend()
    await backend.configure(systemInstruction: "Be brief.", tools: [readme_tool], history: [
        .user("earlier question"), .model("earlier answer"),
    ])
    var reply = ""
    for try await chunk in backend.stream(.message("Hello", attachments: [])) {
        switch chunk {
        case .text(let t): reply += t
        case .toolCall(let c): _ = c
        case .usage(let u): _ = u.total
        case .finish(let reason): _ = reason.userFacingNote
        }
    }
    _ = try await (backend.history, backend.modelName, reply)
    _ = TurnInput.toolResults([.success(ToolCall(name: "x"), [:])])
    _ = TokenUsage.zero + TokenUsage(prompt: 1, completion: 2, total: 3)
    _ = ChatTurn(role: .user, parts: [.text("hi"), .inlineData(Data(), mimeType: "image/png")])
    _ = TurnPart.toolCall(ToolCall(name: "x"))
}

// --- Other seams ---
struct NoopTelemetry: ChatTelemetry {
    func record(_ metrics: TurnMetrics) async {
        _ = (metrics.sessionID, metrics.modelName, metrics.usage.total,
             metrics.toolsCalled, metrics.turnCount, metrics.duration, metrics.error)
    }
}

struct TruncatingCompressor: ContextCompressor {
    var threshold: Int { 4_000 }
    var declarations: [ToolDeclaration] { [] }
    var systemInstruction: String { "Long results are truncated." }
    func compress(_ text: String, toolName: String) async -> String { String(text.prefix(threshold)) }
    func retrieve(handle: String, query: String?) async throws -> String { "" }
}

// --- Questions ---
@MainActor
func readme_questions() async {
    let questions = QuestionService()
    let parsed = QuestionService.parse(["questions": [
        ["question": "Which backend?", "header": "Backend", "multiSelect": false,
         "options": [["label": "Gemini", "description": "Vertex AI"]]],
    ]])
    if let parsed {
        let answers = await questions.request(parsed)
        _ = answers?["Which backend?"]
    }
    _ = questions.pending
    questions.resolve(["Which backend?": "Gemini"])
    questions.cancelPending()
    _ = QuestionService.maxQuestions
    _ = UserQuestion(question: "Proceed?", header: "Scope",
                     options: [UserQuestionOption(label: "Yes", description: "")],
                     multiSelect: true)
}

// --- Skills ---
@MainActor
func readme_skills(projectURL: URL) throws {
    let skills = SkillsService(configuration: .claudeCompatible)
    _ = SkillsService(configuration: .disabled)
    _ = SkillsService(configuration: SkillsConfiguration(
        globalDirectory: URL(fileURLWithPath: "/opt/skills"),
        projectRelativePath: ".myapp/skills"))

    for skill in skills.refresh(workingDirectory: projectURL) {
        _ = (skill.id, skill.name, skill.description, skill.scope, skill.directory)
    }
    if let skill = skills.skill(named: "my-skill") {
        _ = try skills.skillBody(skill)
    }
    _ = skills.execute(ToolCall(name: SkillsService.toolName, arguments: ["name": "my-skill"]))
    _ = (skills.skillsText(), skills.skillsHash(), SkillsService.declaration)
    _ = SkillsService.parseFrontmatter("---\nname: x\n---\n")
    _ = SkillsService.stripFrontmatter("---\nname: x\n---\nBody")
}

// --- History ---
func readme_history(messages: [ChatMessage]) {
    let store = ChatHistoryStore.applicationSupport("MyApp")
    _ = ChatHistoryStore(directory: URL(fileURLWithPath: "/tmp/sessions"))

    var session = StoredSession(title: ChatHistoryStore.derivedTitle(from: messages),
                                messages: messages.map(StoredMessage.init(from:)),
                                usage: TokenUsage(prompt: 10, completion: 5, total: 15),
                                workingDirectoryPath: "/tmp",
                                modelName: "some-model")
    session.updatedAt = Date()
    store.save(session)

    for saved in store.loadAll() {
        _ = (saved.id, saved.title, saved.updatedAt, saved.usage, saved.workingDirectoryPath)
    }
    if let loaded = store.load(session.id) {
        _ = loaded.messages.filter(\.isReplayable).map { $0.toChatMessage() }
        _ = loaded.messages.first?.attachmentNames
    }
    store.delete(session.id)
    _ = store.directory
}

// --- System prompt ---
func readme_prompt() {
    var persona = ChatPersona.default
    persona.identity = "You are Acme Helper, Acme's assistant for the Acme SDK."
    persona.additionalBlocks = ["\n# House rules\nAlways prefer the Acme SDK."]
    _ = ChatPersona.minimal
    _ = ChatPersona(identity: "You answer questions.", code: nil,
                    fileOperations: nil, runningCommands: nil, taskManagement: nil)

    let context = SystemPromptContext(
        persona: persona,
        planMode: false,
        skillsText: "",
        compressorInstruction: "",
        projectContext: "Use tabs.",
        projectContextTitle: "Project instructions (AGENTS.md)",
        additionalSections: ["# Component catalog\n- Button"])

    _ = SystemPromptBuilder.build(context)
    _ = SystemPromptBuilder.fingerprint(context)
}
