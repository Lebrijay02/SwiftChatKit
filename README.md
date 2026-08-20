# SwiftChatKit

A reusable, backend-neutral agentic chat engine for Swift. Configure one object
up front, then `send` / `stop` / read `messages`. UI handling stays outside the
engine.

The design goal is portability: `ChatCore` has **zero external dependencies**,
and nothing app-specific lives in the package. Domain tools, telemetry, theming
and context compression all arrive through protocols the host conforms to.

---

## ⚠️ Status: under construction

This package is being built incrementally. **Only the pieces listed under
"Available today" exist and compile.** The `ChatSession` engine, the Gemini
backend, the built-in file/shell tools, MCP and the SwiftUI renderer are
designed but **not yet implemented** — the API previews for them are marked
`Not built yet` and will not compile.

| Component | Module | Status |
|---|---|---|
| Markdown parser | `ChatCore` | ✅ Available |
| `ChatValue`, tool declarations, schemas | `ChatCore` | ✅ Available |
| `ChatMessage`, `Attachment` | `ChatCore` | ✅ Available |
| `PermissionService`, `QuestionService` | `ChatCore` | ✅ Available |
| Todo checklist, plan mode | `ChatCore` | ✅ Available |
| Protocol seams (`ChatBackend`, `ToolProvider`, …) | `ChatCore` | ✅ Available |
| Agent Skills discovery | `ChatCore` | ✅ Available |
| Transcript persistence | `ChatCore` | ✅ Available |
| System-prompt assembly | `ChatCore` | ✅ Available |
| Slash commands | `ChatCore` | ⬜ Not built yet |
| `ChatSession` agent loop | `ChatCore` | ✅ Available |
| Gemini backend | `ChatGemini` | ✅ Available |
| File + shell tool providers | `ChatTools` | ⬜ Not built yet |
| MCP client and manager | `ChatMCP` | ⬜ Not built yet |
| SwiftUI Markdown renderer, agent cards | `ChatUI` | ⬜ Not built yet |

Every code sample in the "Available today" sections is compile-checked by
`Tests/ChatCoreTests/READMEExamples.swift` and
`Tests/ChatGeminiTests/READMEExamples.swift`, which import the modules the way a
consumer does. If a sample stops compiling, the build breaks.

---

## Requirements

| | |
|---|---|
| Swift toolchain | **6.2** or later (`swift-tools-version: 6.2`) |
| Language mode | **Swift 6** — strict concurrency is on |
| Platforms | macOS 14+, iOS 17+ |
| Dependencies | none for `ChatCore`; `firebase-ios-sdk` 12.14+ for `ChatGemini` |

Strict concurrency is not optional here. Types that cross the tool boundary
(`ChatValue`, `ChatMessage`, `ToolDeclaration`, `ToolCall`, `ToolResult`,
`Attachment`) are all `Sendable`; `ToolProvider` and `ChatBackend` are `Sendable`
protocols, so conformers are typically `actor`s or `@MainActor` classes.

Dependencies are per-module. `ChatGemini` pulls in `firebase-ios-sdk`
(`FirebaseAILogic`); `ChatMCP` will pull in `modelcontextprotocol/swift-sdk`
when it lands. Neither affects consumers of the `SwiftChatKitCore` product,
which is `ChatCore` alone with no external dependencies.

Using `ChatGemini` additionally requires a Firebase project with Vertex AI
enabled, a `GoogleService-Info.plist` in the host app, and a
`FirebaseApp.configure()` call before the first turn — the package does not
configure Firebase for you, because the app owns that lifecycle.

## Installation

```swift
// Package.swift
dependencies: [
    .package(path: "../SwiftChatKit"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        // Engine + Gemini backend.
        .product(name: "SwiftChatKit", package: "SwiftChatKit"),
        // Or, bringing your own backend, the dependency-free core alone:
        // .product(name: "SwiftChatKitCore", package: "SwiftChatKit"),
    ])
]
```

In Xcode: **File → Add Package Dependencies → Add Local…** and pick the package
directory.

```swift
import ChatCore
```

---

## Quickstart

Everything is configured once; after that a host only calls `send` / `stop` and
reads `messages`.

```swift
import ChatCore
import ChatGemini

let session = ChatSession(configuration: ChatSessionConfiguration(
    backend: GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash)),
    toolProviders: [MyToolProvider()],
    persona: .default,
    workingDirectory: projectURL,
    skills: .claudeCompatible,
    maxTurns: 100,
    historyStore: .applicationSupport("MyApp"),
    telemetry: MyTelemetry(),
    onRunFinished: { outcome in
        if outcome == .completed { notifyUser("Your request is ready.") }
    }))

session.send("Refactor this view", attachments: [.image(data, mimeType: "image/png")])
session.stop()
```

`ChatSession` is `@MainActor @Observable`, so a SwiftUI view reads its state
directly and updates when it changes:

```swift
session.messages        // [ChatMessage] — the visible transcript
session.isStreaming     // true while a run is in flight, including while parked
session.error           // last failure, cleared at the start of each run
session.todos           // [TodoItem] — the model's checklist
session.usage           // cumulative TokenUsage; .lastTurnUsage for the last turn
session.planMode
session.permissions.pending   // render an approval card when non-nil
session.questions.pending     // render a question card when non-nil
```

And the actions:

```swift
session.setPlanMode(true)   // research only; mutating tools are refused
session.regenerate()        // redo the last user message
session.newChat()
session.load(storedSession)
session.save()
session.workingDirectory = url   // rescans project-local skills
```

---

# Available today

## Markdown parsing

A Foundation-only CommonMark-plus parser producing a document model. It is
deliberately tolerant of unterminated constructs, because a message being
streamed is half-written most of the time — an unclosed code fence or `$$` math
block still renders rather than collapsing the rest of the message.

```swift
let blocks = MarkdownBlockParser.parse("# Title\n\nSome **bold** text.")

for block in blocks {
    switch block {
    case .heading(let level, let content, let id):  ...
    case .paragraph(let inlines):                   ...
    case .codeBlock(let language, let code):        ...
    case .list(let items):                          ...   // items have .depth, .marker
    case .table(let table):                         ...   // .headers, .alignments, .rows
    case .blockQuote(let depth, let content):       ...
    case .mathBlock(let inlines):                   ...
    case .thematicBreak:                            ...
    case .definitionList(let definitions):          ...
    case .footnoteDefinition(let label, let body):  ...
    }
}
```

Inline spans nest explicitly, so `**bold *and* italic**` composes rather than
flattening into a single attribute set:

```swift
MarkdownInlineParser.parse("a `code` span and [a link](https://example.com)")
// [.text("a "), .code("code"), .text(" span and "),
//  .link(children: [.text("a link")], destination: "https://example.com")]
```

Supported: ATX headings (with `{#custom-id}`), lists including task and ordered
and nested, blockquotes with depth, fenced code, tables with alignment, footnote
definitions and references, definition lists, thematic breaks, strong, emphasis,
strikethrough, highlight, subscript, superscript, inline code, links, images,
escapes, and LaTeX math.

Math is translated into displayable inline nodes rather than rendered as an
image:

```swift
MarkdownMath.render(#"\frac{a}{b}"#)
MarkdownMath.looksLikeMath("x^2")   // false for "$5 and $10" — currency is not math
```

`MarkdownInline` and `MarkdownBlock` are `Equatable` and `Sendable`, and know
nothing about fonts, colors or platforms. Turning them into an attributed string
is the renderer's job (`ChatUI`, not yet built).

## `ChatValue` — the JSON type

Every tool argument, tool result and persisted payload passes through
`ChatValue`. It exists so that no model SDK's value type leaks into a tool
signature — swapping backends must not ripple through every tool you wrote.

```swift
let args: ChatValue = [
    "path": "/tmp/a.swift",
    "limit": 100,
    "replaceAll": false,
    "tags": ["x"],
]

args["path"]?.stringValue      // "/tmp/a.swift"
args["limit"]?.intValue        // 100
args["replaceAll"]?.boolValue  // false — not collapsed to a number
args["tags"]?.arrayValue       // [.string("x")]
args["nope"]                   // nil
```

Cases are `.null`, `.bool`, `.number(Double)`, `.string`, `.array`, `.object`.
Literal conformances mean you rarely write a case name.

```swift
args.jsonString()                    // sorted keys, so saved sessions diff cleanly
args.jsonString(prettyPrinted: true)
args.jsonObject                      // JSONSerialization-compatible

ChatValue.parse(#"{"ok":true}"#)     // ChatValue?
ChatValue.parse(#"{"trunca"#)        // nil — models do emit truncated arguments
ChatValue(json: someDecodedDictionary)
```

Two behaviours worth knowing, both covered by tests:

- **Booleans stay booleans.** `NSNumber` erases `Bool`, so the
  `JSONSerialization` bridge checks `CFBooleanGetTypeID` before reading a number.
- **`intValue` refuses to truncate.** `0.5` reads back as `nil`, not `0`.

## Declaring tools

```swift
let readTextFile = ToolDeclaration(
    name: "readTextFile",
    description: "Read a UTF-8 text file.",
    parameters: [
        "path":    .string(description: "Absolute path to the file."),
        "limit":   .integer(description: "Maximum number of lines."),
        "mode":    .enumeration(values: ["head", "tail"], description: "Which end to read."),
        "options": .object(properties: ["trim": .boolean()], optional: ["trim"]),
        "globs":   .array(items: .string(), description: "Filters."),
    ],
    optional: ["limit", "mode", "options", "globs"])
```

`ToolSchema` is a deliberate JSON-Schema *subset* — the intersection every
provider agrees on. Anything richer stops round-tripping cleanly between
providers, so `allOf`/`anyOf`/`$ref` are out of scope by design.

Note the direction: you list which parameters are **optional**, and everything
else is required. That matches how both Gemini and MCP express it.

## Calls and results

```swift
let call = ToolCall(name: "readTextFile", arguments: ["path": "/tmp/a.swift"])

ToolResult.success(call, ["content": "…"])
ToolResult.failure(call, "No such file")   // → payload ["error": "No such file"]

result.errorMessage   // String? — nil on success
```

**Tool failures are returned as data, never thrown past the agent loop.** A
failing tool is something the model should read and recover from, not something
that should tear down the turn.

## Messages and attachments

```swift
var transcript: [ChatMessage] = [
    .user("Read this file", attachments: [.image(jpegData)]),
    .assistant("", isStreaming: true),
]

transcript.append(.toolCall(call))
transcript.append(.toolResult(.success(call, ["content": "…"])))
```

Tool calls and results are **first-class messages**, not hidden protocol
traffic — the UI renders them, and replaying them is how history is rebuilt.

```swift
message.role          // .user | .assistant | .toolCall(toolName:) | .toolResult
message.content       // display text (lossy for tool messages)
message.rawArguments  // [String: ChatValue]? — the exact payload
message.rawResult     // [String: ChatValue]?
message.callID        // correlates .toolCall with its .toolResult
message.isStreaming
message.status        // .queued | .inProgress | .completed | .cancelled | .incomplete
message.duration      // TimeInterval? — set once completedAt lands
message.toolName
```

`content` is a lossy, human-readable rendering for tool messages;
`rawArguments`/`rawResult` keep the payload verbatim so a reloaded session can be
replayed to the backend as real function call/response parts rather than prose.
**Don't drop them when persisting** — history replay depends on it.

Attachments are `Data` + `mimeType` + `kind`, never a platform image. An
`NSImage`-backed attachment cannot cross to iOS, and the encoding decision
(JPEG quality, downscaling) belongs to whoever picked the file.

```swift
Attachment.image(jpegData, mimeType: "image/jpeg", filename: "shot.jpg")
Attachment.pdf(pdfData, filename: "spec.pdf")
Attachment.contentsOf(fileURL)   // Attachment? — infers MIME from the extension
```

Inferred types: jpg/jpeg, png, gif, webp, heic, pdf. Anything else returns `nil`
rather than guessing at a type no backend accepts inline.

## Permissions

Mutating tools suspend the agent loop until the user answers, so a model can
never write to disk or run a command without the user having seen exactly what
it asked for.

```swift
let permissions = PermissionService(
    autoAllowed: ["readTextFile", "listDirectory"],
    store: UserDefaultsPermissionStore(key: "MyApp.alwaysAllowedTools"))

if permissions.requiresApproval("writeFile") {
    // Suspends here until the UI calls resolve(_:).
    let decision = await permissions.request(
        PermissionRequest(kind: .tool,
                          toolName: "writeFile",
                          title: "Write Notes.swift",
                          detail: diffText))
    guard decision != .deny else { return }
}
```

Drive it from SwiftUI — `PermissionService` is `@MainActor @Observable`:

```swift
if let request = permissions.pending {
    VStack(alignment: .leading) {
        Text(request.title).bold()
        ScrollView { Text(request.detail).monospaced() }
        HStack {
            Button("Allow once")   { permissions.resolve(.allowOnce) }
            Button("Always allow") { permissions.resolve(.alwaysAllow) }
            Button("Deny")         { permissions.resolve(.deny) }
        }
    }
}
```

Also available: `cancelPending()` (deny and dismiss — call this when the user
stops streaming), `revokeAlwaysAllow(_:)`, and the `alwaysAllowed` /
`autoAllowed` sets.

`PermissionRequest.detail` is what the user actually judges, so make it
complete — the full command, the whole diff, the entire plan. A truncated detail
turns the gate into a rubber stamp.

Storage is injectable: `UserDefaultsPermissionStore` persists grants across
launches, `EphemeralPermissionStore` keeps them in memory, or conform
`PermissionStore` yourself to scope grants per project.

`PermissionRequest.kind` is `.tool` or `.plan`, the latter for approving an exit
from read-only plan mode.

---

## Asking the user

The counterpart to permissions: when the model needs a decision it cannot make
without guessing, it asks. A wrong guess costs a whole turn of wasted work.

```swift
let questions = QuestionService()

// Built from the `askUser` tool's arguments.
if let parsed = QuestionService.parse(call.arguments) {
    // Suspends until the host submits the card.
    let answers = await questions.request(parsed)
    let choice = answers?["Which backend?"]   // nil = the user declined
}
```

`QuestionService` is `@MainActor @Observable`, so drive it the same way as
permissions — read `pending`, call `resolve(_:)` with answers keyed by question
text, or `cancelPending()` when streaming stops.

```swift
UserQuestion(question: "Which backend?",
             header: "Backend",                              // short category label
             options: [UserQuestionOption(label: "Gemini",
                                          description: "Vertex AI")],
             multiSelect: false)
```

`parse` is defensive by design. It caps at `QuestionService.maxQuestions` (4 —
beyond that it stops being a clarification and becomes an interrogation), skips
options missing a label while keeping the question, and returns `nil` when
nothing usable remains so the loop can report a tool error instead of showing an
empty card.

## Agent Skills

A skill is a folder with a `SKILL.md` — YAML frontmatter for `name` and
`description`, Markdown body for the instructions. The model sees only the
name and description in the system prompt and loads the body on demand via the
`useSkill` tool. That progressive disclosure is the point: a dozen installed
skills would otherwise consume the context window before the first turn.

```swift
let skills = SkillsService(configuration: .claudeCompatible)
skills.refresh(workingDirectory: projectURL)

skills.skills            // [AgentSkill] — name, description, scope, directory
skills.skill(named: "code-review")   // case-insensitive
try skills.skillBody(skill)          // SKILL.md with frontmatter stripped
```

`.claudeCompatible` searches `~/.claude/skills` and `<project>/.claude/skills`.
Local skills shadow global ones of the same name, so a project can override a
machine-wide skill. Point it anywhere, or turn it off:

```swift
SkillsConfiguration(globalDirectory: URL(fileURLWithPath: "/opt/skills"),
                    projectRelativePath: ".myapp/skills")
SkillsConfiguration.disabled
```

Handling the tool call is one line — the result carries the instructions plus
the skill's folder path, so the model can read the support files a skill
references:

```swift
let result = skills.execute(call)
// payload: ["name": …, "directory": …, "instructions": …]
```

A call naming a skill that isn't installed fails with the list of ones that are,
so the model can self-correct rather than retrying blindly.

For the system prompt: `skillsText()` renders the listing block, and
`skillsHash()` is a cheap fingerprint for detecting changes without
regenerating it.

Symlinked skill folders are resolved before the directory check — installers
commonly link `~/.claude/skills/<name>` at a store elsewhere.

## Persisting transcripts

One JSON file per session, written atomically so an interrupted save cannot
truncate an existing transcript.

```swift
let store = ChatHistoryStore.applicationSupport("MyApp")
// or ChatHistoryStore(directory: someURL)

let session = StoredSession(
    title: ChatHistoryStore.derivedTitle(from: messages),
    messages: messages.map(StoredMessage.init(from:)),
    usage: TokenUsage(prompt: 10, completion: 5, total: 15),
    workingDirectoryPath: projectURL.path,
    modelName: "some-model")

store.save(session)
store.loadAll()          // newest first; corrupt files are skipped, not fatal
store.load(session.id)
store.delete(session.id)
```

`StoredSession` is the serialized form; the live engine type will be
`ChatSession`. Restoring is `loaded.messages.map { $0.toChatMessage() }`.

Two behaviours to know:

- **Attachment bytes are not persisted.** Inlining image and PDF data would
  bloat every transcript by megabytes. Filenames survive in `attachmentNames`,
  so the UI can still show what was sent.
- **`isReplayable` tells you whether a tool message can be rebuilt.** A
  `.toolCall` without `rawArguments` cannot become a real function-call part,
  and replay should skip it rather than fabricate one.

`derivedTitle(from:)` takes the first non-empty line of the first user message,
truncated to 60 characters, falling back to `"New chat"`.

## Building the system prompt

The persona is a set of independent blocks rather than one blob, because most of
them are conditional and a host swapping the identity shouldn't have to restate
the behavioural guidance it wants to keep.

```swift
var persona = ChatPersona.default
persona.identity = "You are Acme Helper, Acme's assistant for the Acme SDK."
persona.additionalBlocks = ["\n# House rules\nAlways prefer the Acme SDK."]

let prompt = SystemPromptBuilder.build(SystemPromptContext(
    persona: persona,
    planMode: false,
    skillsText: skills.skillsText(),
    compressorInstruction: compressor?.systemInstruction ?? "",
    projectContext: agentsMarkdown,
    projectContextTitle: "Project instructions (AGENTS.md)",
    additionalSections: ["# Component catalog\n- Button"]))
```

Blocks: `identity`, `communication`, `code`, `fileOperations`,
`runningCommands`, `taskManagement`, `doingTasks`. All but the first two are
optional — set one to `nil` and it disappears. Drop the tool blocks when you
haven't installed the matching providers, so the prompt never advertises tools
that don't exist.

```swift
ChatPersona.default   // every block — a general-purpose coding assistant
ChatPersona.minimal   // identity + communication only
```

**The defaults ship no host-specific identity.** A test asserts the assembled
default prompt contains no product, vendor, IDE or framework name — that
neutrality is the package's whole premise, so it's enforced rather than trusted.

Order is deliberate: identity and standing behaviour, then mode overrides
(plan mode, compression), then skills and host sections, then project context
**last** so it outranks the defaults it contradicts.

`SystemPromptBuilder.fingerprint(_:)` is a cheap identity for a built prompt.
Compare it against the value baked into the current model to decide whether a
rebuild is needed, instead of reassembling and re-uploading the prompt every
turn.

---

## The Gemini backend

`ChatGemini` is the one shipped `ChatBackend`, over Firebase AI Logic's Vertex AI
path. It is a thin translation layer: it owns every `FirebaseAILogic` type so
nothing above it has to.

```swift
import ChatCore
import ChatGemini

let backend = GeminiBackend(GeminiBackendConfig(
    model: .gemini3_5Flash,
    location: "global",          // Vertex region; "global" routes to nearest capacity
    enableGoogleSearch: true))   // offers the built-in search tool alongside your functions

await backend.configure(
    systemInstruction: SystemPromptBuilder.build(SystemPromptContext()),
    tools: myProvider.declarations,
    history: [])

for try await chunk in backend.stream(.message("What changed in this file?")) {
    // .text / .toolCall / .usage / .finish, exactly as the protocol describes
}
```

Firebase must already be configured — call `FirebaseApp.configure()` in your app
before the first turn.

### Models

`GeminiModel` is a `RawRepresentable` struct rather than an enum, because Google
ships model IDs faster than this package ships releases and a host must be able
to pass one that did not exist at compile time.

```swift
GeminiModel.known            // the seven IDs with curated display names
GeminiModel.gemini3_5Flash.displayName   // "Gemini 3.5 Flash"
GeminiModel("gemini-9-ultra-preview").displayName  // "Gemini 9 Ultra" — derived
await backend.setModel(.gemini2_5Pro)    // swaps models, carrying history across
```

### What the translation layer guarantees

- `ChatValue` ↔ `JSONValue` round-trips every case. Booleans stay booleans —
  a `true` degrading to `1` would break every boolean tool argument.
- `ToolSchema` maps onto the schema types Vertex accepts (`.number` becomes the
  SDK's `.double`); `optional:` is emitted as "everything not listed is
  `required`", which is the direction the wire format expresses it.
- Reasoning parts (`TextPart.isThought`) are dropped, never yielded as `.text`.
- Tool *results* are sent with role `"user"` whatever produced them, because
  Vertex AI rejects any other role on an incoming turn.
- A call arriving without an id gets a synthesized one, so parallel calls still
  pair back to their responses.
- Empty text parts are dropped rather than sent — Vertex rejects them.

These are the conversion tests, not prose: `Tests/ChatGeminiTests` covers each
point above without a network or a Firebase project.

---

## The agent loop

`ChatSession` runs the loop that makes this an agent rather than a chat box:
stream a turn, run whatever tools the model called, feed the results back,
repeat until it answers without calling anything or the turn cap is reached.

Behaviours worth knowing, because they are what the loop's tests pin down:

- **A turn that only called tools leaves no empty bubble.** The assistant
  message opened for it is removed rather than rendered blank.
- **Parallel calls run concurrently** and are answered as a single turn, in call
  order. Independent reads and searches are the common case, and serializing
  them wastes most of a turn.
- **The permission gate is sequential**, before any dispatch. Running it inside
  the parallel group would show the user several approval cards at once.
- **A refused call still reports back.** The model receives an instruction
  ("the user declined this — don't retry it") rather than a bare error, because
  a model told not to retry stops retrying.
- **An abnormal finish ends the run.** A truncated or filtered turn is noted in
  the bubble and the loop stops; continuing would feed the model back a turn it
  never finished.
- **Tool errors are never thrown past the loop.** They are data the model reads
  and recovers from. A network-shaped failure is retried once first.
- **Token usage is the last value a turn reported**, not the sum of its chunks —
  providers report cumulatively, so summing would multiply it.
- **The model is rebuilt only when its inputs change.** The system prompt, the
  assembled tool list and each provider's `declarationsVersion` form a
  fingerprint; an unchanged fingerprint skips the re-upload.

### Tools the session owns

Three tools act on the session's own state, so they are implemented by the
session rather than by a provider, and a provider cannot shadow them:

| Tool | Effect | Offered when |
|---|---|---|
| `todoWrite` | Replaces `session.todos` | `enableTodos` (default on) |
| `askUser` | Parks the loop on `questions.pending` | `enableQuestions` (default on) |
| `exitPlanMode` | Asks for approval, then turns plan mode off | only in plan mode |

None of them prompt for permission — a confirmation dialog for "update the
checklist" is noise. `useSkill` is added automatically when any skill is
installed.

### Plan mode

```swift
session.setPlanMode(true)
```

While on, any call to a tool listed in its provider's `mutatingToolNames` is
refused before it runs, and `exitPlanMode` appears in the tool list. Plan mode
outranks permissions: a tool the user already granted "Always allow" is still
refused. Approving the plan turns plan mode off and lets the model proceed in
the same run.

### History replay

`session.load(_:)` restores a transcript, and the next send replays it to the
backend as real function call/response parts rather than prose about them.
Consecutive calls and their results coalesce into one turn each way, mirroring
how the loop emits them. Two things are deliberately dropped: turns saved
without their raw payloads (they cannot be rebuilt faithfully), and a trailing
unanswered call (it would make the next send invalid).

---

## Implementing the seams

Everything host-specific plugs in here. These protocols exist and compile today;
what consumes them (`ChatSession`) does not yet.

### `ToolProvider` — add capabilities

```swift
final class EchoToolProvider: ToolProvider {

    var declarations: [ToolDeclaration] {
        get async {
            [ToolDeclaration(name: "echo",
                             description: "Echo text back.",
                             parameters: ["text": .string()])]
        }
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        guard let text = call.arguments["text"]?.stringValue else {
            return .failure(call, "Missing required argument: text")
        }
        return .success(call, ["echoed": .string(text)])
    }

    // Optional: render a better approval card than the generic one.
    func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        PermissionRequest(toolName: call.name, title: "Echo",
                          detail: call.arguments["text"]?.stringValue ?? "")
    }

    var autoAllowedToolNames: Set<String> { ["echo"] }   // safe, never prompts
    var mutatingToolNames: Set<String> { [] }            // blocked in plan mode
}
```

Defaults are provided for `handles(_:)` (matches against `declarations`),
`approvalCard(for:)` (nil → generic card), both name sets (empty), and
`declarationsVersion` (0 — bump it if your tool list changes at runtime, so the
session knows to rebuild the model).

### `ChatBackend` — talk to a model

An `actor` satisfies the `AnyObject, Sendable` requirement cleanly:

```swift
actor EchoBackend: ChatBackend {
    private var turns: [ChatTurn] = []
    var history: [ChatTurn] { turns }
    var modelName: String { "echo-1" }

    func configure(systemInstruction: String,
                   tools: [ToolDeclaration],
                   history: [ChatTurn]) {
        turns = history
    }

    nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("…"))
            continuation.yield(.usage(TokenUsage(prompt: 1, completion: 1, total: 2)))
            continuation.yield(.finish(.stop))
            continuation.finish()
        }
    }
}
```

Consuming a turn:

```swift
for try await chunk in backend.stream(.message("Hello")) {
    switch chunk {
    case .text(let delta):   reply += delta
    case .toolCall(let call): pending.append(call)
    case .usage(let usage):   total = total + usage
    case .finish(let reason): note = reason.userFacingNote
    }
}
```

Contract notes for implementors:

- **Never emit reasoning or "thought" text as `.text`.** The transcript shows
  only what the user should read.
- `configure` must not lose history — it is called between turns whenever tools
  or context go stale, so it has to be cheap and non-destructive.
- Cancelling the consuming task must stop the underlying request.
- Appending the turn and its response to `history` is the backend's job.

`ChatTurn` is distinct from `ChatMessage`: it is what the *backend* replays,
and several messages collapse into one turn when a model emits parallel tool
calls. Answer a batch of parallel calls together —
`TurnInput.toolResults([...])` — because splitting them desynchronizes
call/response pairing.

`FinishReason` maps provider raw values (`STOP`, `MAX_TOKENS`, `SAFETY`,
`PROHIBITED_CONTENT`, `RECITATION`, `MALFORMED_FUNCTION_CALL`, `LANGUAGE`) and
degrades unknown future values to `.other` rather than failing.
`userFacingNote` is `nil` for normal stops and a sentence to append to the
bubble otherwise.

### `ChatTelemetry` — analytics

Fire-and-forget. The session never waits on it and never surfaces its failures:
telemetry must not be able to break a chat.

```swift
struct MyTelemetry: ChatTelemetry {
    func record(_ metrics: TurnMetrics) async {
        // .sessionID .modelName .usage .toolsCalled .turnCount .duration .error
    }
}
```

### `ContextCompressor` — shrink oversized tool output

Long `grep` and `readFile` results otherwise dominate the context window within
a few turns.

```swift
struct MyCompressor: ContextCompressor {
    var threshold: Int { 4_000 }
    var declarations: [ToolDeclaration] { [retrieveTool] }
    var systemInstruction: String { "Long results are summarized; call retrieve to expand." }

    func compress(_ text: String, toolName: String) async -> String { ... }
    func retrieve(handle: String, query: String?) async throws -> String { ... }
}
```

`compress` **must fail open** — return `text` unchanged on error rather than
throwing. A compression outage should degrade context efficiency, not the chat.

### `FileSystemProviding` — back the built-in file tools

Abstracted so you can point the file tools at a sandboxed root, a virtual
project, or a remote workspace instead of the local disk. Covers
`currentDirectory`, `readText`/`readData`, `write`/`edit`, `createDirectory`,
`list`, `move`, `info`, `glob` and `grep`.

`edit` throws when the target string is absent, or — unless `replaceAll` — when
it appears more than once. An ambiguous edit is a bug, not something to guess at.

---

# Not built yet

Still to come: slash commands (`/clear`, `/compact`, `/plan`, `/init`), the
built-in file and shell tool providers (`ChatTools`), the MCP client
(`ChatMCP`), and the SwiftUI renderer and agent cards (`ChatUI`). Until
`ChatTools` lands, a host supplies its own `ToolProvider` for file access.

---

## Building and testing

```sh
swift build
swift test
```

Currently 135 tests across 21 suites. The Markdown suites are ported verbatim
from the originating app — that equivalence is the primary regression signal for
the parser.

## Known limitations

- **Session history replay requires payloads saved with `rawArguments` /
  `rawResult`.** Sessions persisted before those fields existed store only the
  lossy display rendering in `arguments`, which is not valid JSON and cannot be
  replayed to a backend as real tool turns.
- `ToolSchema` covers a JSON-Schema subset only; composition keywords are not
  represented.
- Skill frontmatter parsing handles single-line `key: value` pairs, quoted
  values and simple folded scalars — it is not a general YAML parser.
- `ChatCore` is platform-agnostic, but the built-in shell and stdio-transport
  tools will be macOS-only when they land — on iOS those targets compile to an
  empty provider list.
