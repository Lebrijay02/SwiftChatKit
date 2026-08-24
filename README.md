# SwiftChatKit

A reusable, backend-neutral agentic chat engine for Swift. Configure one object
up front, then `send` / `stop` / read `messages`. UI handling stays outside the
engine.

The design goal is portability: `ChatCore` has **zero external dependencies**,
and nothing app-specific lives in the package. Domain tools, telemetry, theming
and context compression all arrive through protocols the host conforms to.

**Nothing is pre-set.** A fresh session ships no tools — no files, no shell, no
MCP, not even the todo checklist — and a persona that describes none. Every
capability is its own product you opt into, so what the model can do is exactly
what you wired up.

---

## ⚠️ Status: under construction

This package is being built incrementally. **Only the pieces listed under
"Available today" exist and compile.** MCP, the SwiftUI renderer and slash
commands are designed but **not yet implemented** — the API previews for them
are marked `Not built yet` and will not compile.

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
| OpenAI-compatible backend | `ChatOpenAI` | ✅ Available |
| File + shell tool providers | `ChatTools` | ✅ Available |
| MCP client and manager | `ChatMCP` | ✅ Available |
| SwiftUI Markdown renderer, agent cards | `ChatUI` | ✅ Available |

Every code sample in the "Available today" sections is compile-checked by
`Tests/ChatCoreTests/READMEExamples.swift`,
`Tests/ChatGeminiTests/READMEExamples.swift`,
`Tests/ChatOpenAITests/READMEExamples.swift`,
`Tests/ChatToolsTests/READMEExamples.swift`,
`Tests/ChatMCPTests/READMEExamples.swift` and
`Tests/ChatUITests/READMEExamples.swift`, which import the modules the way a
consumer does. If a sample stops compiling, the build breaks.

---

## Requirements

| | |
|---|---|
| Swift toolchain | **6.2** or later (`swift-tools-version: 6.2`) |
| Language mode | **Swift 6** — strict concurrency is on |
| Platforms | macOS 14+, iOS 17+ |
| Dependencies | none for `ChatCore` or `ChatOpenAI`; `firebase-ios-sdk` 12.14+ for `ChatGemini` |

Strict concurrency is not optional here. Types that cross the tool boundary
(`ChatValue`, `ChatMessage`, `ToolDeclaration`, `ToolCall`, `ToolResult`,
`Attachment`) are all `Sendable`; `ToolProvider` and `ChatBackend` are `Sendable`
protocols, so conformers are typically `actor`s or `@MainActor` classes.

Dependencies are per-product. `SwiftChatKitGemini` pulls in `firebase-ios-sdk`
(`FirebaseAILogic`); `SwiftChatKitOpenAI` pulls in nothing at all — it is
URLSession and Foundation; `SwiftChatKitMCP` pulls in `modelcontextprotocol/swift-sdk`,
though only for its transports — the JSON-RPC handshake is driven by hand.
Neither affects consumers of `SwiftChatKit` itself, which is `ChatCore` alone
with no external dependencies.

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
        // The engine. On its own: a chat with no tools and no backend.
        .product(name: "SwiftChatKit", package: "SwiftChatKit"),
        // Then one product per capability you actually want. Skip any of them
        // and neither its code nor its dependencies enter your build.
        .product(name: "SwiftChatKitGemini", package: "SwiftChatKit"),
        .product(name: "SwiftChatKitOpenAI", package: "SwiftChatKit"),
        .product(name: "SwiftChatKitTools", package: "SwiftChatKit"),
        .product(name: "SwiftChatKitMCP", package: "SwiftChatKit"),
        .product(name: "SwiftChatKitUI", package: "SwiftChatKit"),
    ])
]
```

| Product | Target | Brings |
|---|---|---|
| `SwiftChatKit` | `ChatCore` | The engine. No dependencies, no tools, no backend |
| `SwiftChatKitGemini` | `ChatGemini` | The Gemini backend (`firebase-ios-sdk`) |
| `SwiftChatKitOpenAI` | `ChatOpenAI` | The OpenAI-compatible backend (no dependencies) |
| `SwiftChatKitTools` | `ChatTools` | The file and shell tool providers |
| `SwiftChatKitMCP` | `ChatMCP` | MCP servers as tools (`swift-sdk`) |
| `SwiftChatKitUI` | `ChatUI` | The SwiftUI renderer and agent cards |

In Xcode: **File → Add Package Dependencies → Add Local…** and pick the package
directory.

Each capability module re-exports `ChatCore`, so one import is enough:

```swift
import ChatGemini   // ChatCore comes with it
```

---

## Quickstart

Everything is configured once; after that a host only calls `send` / `stop` and
reads `messages`. A backend is the only requirement — this is the whole of a
working chat, and it has no tools at all:

```swift
import ChatGemini

let session = ChatSession(configuration: ChatSessionConfiguration(
    backend: GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash))))
```

From there you add capabilities one at a time, and only what you add exists:

```swift
import ChatGemini

let session = ChatSession(configuration: ChatSessionConfiguration(
    backend: GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash)),
    toolProviders: [MyToolProvider()],
    // `.default` describes no tools. Switch to the persona that matches what
    // you installed, or edit the blocks yourself.
    persona: .codingAgent,
    workingDirectory: projectURL,
    skills: .claudeCompatible,
    maxTurns: 100,
    enableTodos: true,
    enableQuestions: true,
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
session.isThinking      // true while the model is working with nothing to show yet
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
is the renderer's job — see [Rendering](#rendering).

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
optional — set one to `nil` and it disappears. The tool blocks default to `nil`,
matching the session's default of no tools: a prompt that describes a file tool
to a session that has none teaches the model to call something that isn't there.

```swift
ChatPersona.default      // neutral assistant, no tool or code guidance
ChatPersona.minimal      // identity + communication only
ChatPersona.codingAgent  // every block — pair with the file, shell and todo tools

var persona = ChatPersona.default
persona.fileOperations = ChatPersona.fileOperationsBlock   // add back one at a time
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

`ChatGemini` is one of two shipped `ChatBackend`s, over Firebase AI Logic's
Vertex AI path. It is a thin translation layer: it owns every `FirebaseAILogic` type so
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

## The OpenAI-compatible backend

`ChatOpenAI` speaks the `/chat/completions` wire format, which by now is less a
vendor API than a lingua franca: OpenAI itself, but equally OpenRouter, Groq,
Together, Fireworks, vLLM, Ollama, LM Studio, or a gateway of your own. You give
it a base URL and an API key.

It has **no dependencies** — URLSession and Foundation, SSE parsed by hand. That
is deliberate rather than ascetic: the point of this backend is reaching servers
no SDK was written for, so binding it to one would defeat it.

```swift
import ChatCore
import ChatOpenAI

let backend = OpenAIBackend(OpenAIBackendConfig(
    baseURL: URL(string: "https://openrouter.ai/api/v1")!,
    apiKey: key,
    model: OpenAIModel("anthropic/claude-sonnet-4.5")))

await backend.configure(
    systemInstruction: SystemPromptBuilder.build(SystemPromptContext()),
    tools: myProvider.declarations,
    history: [])

for try await chunk in backend.stream(.message("What changed in this file?")) {
    // .text / .toolCall / .usage / .finish, exactly as the protocol describes
}
```

For OpenAI itself there is nothing to configure but a key:

```swift
let backend = OpenAIBackend(apiKey: key, model: .gpt5)
```

A `baseURL` typed by the user is likelier to arrive as a string, so there is a
failable initializer that validates it instead of trapping:

```swift
guard let config = OpenAIBackendConfig(baseURL: userTypedURL, apiKey: key,
                                       model: OpenAIModel(userTypedModel))
else { return .invalidEndpoint }
```

The URL is the root, up to but not including `chat/completions`. Trailing slashes
are tolerated, and a URL that already ends in the endpoint is left alone rather
than doubled — pasting the full URL is the likelier mistake to make.

> Read the key from the Keychain or a server-side proxy. A key compiled into a
> shipped app is a key that has already leaked.

### Configuration

| Field | Effect |
|---|---|
| `baseURL`, `apiKey`, `model` | The three things a compatible server needs. An empty key sends no `Authorization` header, which is what local servers want |
| `temperature`, `maxCompletionTokens` | Nil omits the parameter entirely, so the server's own default applies |
| `includeUsage` | Asks for the final usage-only chunk. Turn off for servers that reject `stream_options` rather than ignoring it |
| `extraBody` | Merged into every request body, overriding anything above it. The escape hatch for provider-specific parameters — OpenRouter routing, vLLM sampling knobs, reasoning effort |
| `extraHeaders` | Merged into every request's headers: `HTTP-Referer` and `X-Title` for OpenRouter, a tenant id for a gateway |
| `timeout` | Cap on one streaming request, end to end. Default 300s |

`OpenAIModel` is a `RawRepresentable` struct for the same reason `GeminiModel`
is, only more so — the model list here is genuinely open:

```swift
OpenAIModel.known                        // the handful with curated names
OpenAIModel("qwen3-coder:30b")           // whatever your server serves
await backend.setModel(.gpt4oMini)       // swaps models, carrying history across
```

### What the translation layer guarantees

- Tool arguments travel as a JSON **string**, not an object — sending the object
  is the single most common way to get a 400 out of this API.
- `optional:` is inverted into JSON Schema's `required`, and `.enumeration`
  renders as a string with an `enum` constraint rather than a type of its own.
- `content` stays present-but-null on a pure tool-call turn; several compatible
  servers reject the message when the key is missing outright.
- Parallel tool results become one `tool` message each, keyed by `tool_call_id`.
  Folding them together loses the pairing and the server rejects the whole
  conversation.
- A single text part is sent as a plain string rather than a one-element content
  array: the array form is valid in the spec and rejected by a few servers.
- Attachments are inlined as `data:` URLs in an `image_url` content part.
- Streamed tool calls are reassembled across frames by `index` — id, name and
  argument fragments all arrive separately — and emitted **before** the `.finish`
  chunk, since the agent loop stops reading at it.
- Truncated tool arguments degrade to an empty argument map rather than throwing,
  so the tool reports the real problem back to the model, which is recoverable.
- A malformed SSE frame costs one delta, not the turn. Third-party servers do
  emit them.
- History is this backend's own state, since there is no chat object holding it,
  and it is committed only once a turn succeeds — a retry replays that turn
  rather than a conversation with a hole in it.

`Tests/ChatOpenAITests` covers each point above with no network and no key.

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
session rather than by a provider, and a provider cannot shadow them. Like
everything else, none of them are on unless you say so:

| Tool | Effect | Offered when |
|---|---|---|
| `todoWrite` | Replaces `session.todos` | `enableTodos` (default **off**) |
| `askUser` | Parks the loop on `questions.pending` | `enableQuestions` (default **off**) |
| `exitPlanMode` | Asks for approval, then turns plan mode off | only in plan mode |

A disabled one isn't merely withheld from the tool list: a model that calls the
name anyway gets "no tool named that", so it cannot reach state the host
switched off. Enable `askUser` only if you render `questions.pending` — a
question nobody displays parks the run forever.

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

## The file and shell tools

`SwiftChatKitTools` is the product that ships the file and shell providers.
Nothing installs them for you — they are plain `ToolProvider`s you list in the
configuration, and a session that doesn't list them cannot touch a disk.

```swift
import ChatTools

let session = ChatSession(configuration: .init(
    backend: backend,
    toolProviders: [
        FileToolProvider(fileSystem: LocalFileSystem(root: projectURL)),
        ShellToolProvider()
    ],
    persona: .codingAgent,   // the prompt guidance that matches these two
    workingDirectory: projectURL))
```

Neither provider takes a directory per call. They follow the session's
`workingDirectory`, which is pushed to every provider at init and again whenever
it changes — a model repeating a stale path back at you is a whole class of
error that not having the parameter removes. `getCurrentDirectory` stays, so the
model can still report and build absolute paths.

### The file tools

Thirteen tools over `FileSystemProviding`:

| | |
|---|---|
| Read | `getCurrentDirectory`, `readTextFile`, `readMediaFile`, `readMultipleFiles` |
| Search | `globFiles`, `grepFiles` |
| Inspect | `listDirectory`, `listDirectoryWithSizes`, `getFileInfo` |
| Write | `writeFile`, `editFile`, `createDirectory`, `moveFile` |

The nine read tools are in `FileToolProvider.readOnlyNames` and auto-allow
themselves; the four write tools are in `mutatingNames`, so they prompt for
approval and are blocked outright in plan mode.

Behaviour worth knowing:

- `readTextFile` returns `cat -n` numbered lines, and `offset`/`limit` page
  through a large file while keeping absolute line numbers.
- `editFile` applies its edits in order and **throws if any `oldText` is
  absent** — an edit that silently matched nothing would leave the model
  building its next change on a file state that never existed. The whole batch
  is then unapplied. Its approval card shows the real diff, computed with a dry
  run, rather than the raw arguments.
- `moveFile` never overwrites an existing destination.
- `readMultipleFiles` reports a bad path inline instead of failing the batch.
- `grepFiles` defaults to `files_with_matches`, which costs far less context
  than returning the matching lines.

`LocalFileSystem` is the default conformer. It skips hidden files and the usual
noise directories (`.git`, `node_modules`, `.build`, `DerivedData`, …) when
walking, configurable via `excludedNames`. Pass `securityScoped: true` when the
root came from a bookmark or an open panel and the host is sandboxed — every
operation is then wrapped in a balanced start/stop access pair.

Globs are matched properly, not by stripping the wildcards and testing
`contains`: `*`, `**`, `?` and `[a-z]` classes all mean what they mean, `*`
stops at a path separator and `**` does not, and a pattern with no slash matches
at any depth. `GlobPattern.matches(_:pattern:)` is public if you want it.

### The shell tool

`ShellToolProvider` exposes a single `runCommand`, macOS-only. It is never
auto-allowed and always counts as mutating — no shell command is safe enough to
run unprompted.

```swift
ShellToolProvider(shell: "/bin/zsh", timeout: 120, outputLimit: 30_000)
```

A command past the deadline gets `SIGTERM`, then `SIGKILL` a second later, and
comes back with `timedOut: true`. Output beyond `outputLimit` keeps the head and
the tail and drops the middle — a build log's first error and its final summary
both matter. stdout and stderr are drained concurrently with the wait, so a
command that fills the 64 KB pipe buffer does not deadlock.

Non-zero exits are returned as data, not as errors: the model should read the
exit code and recover, not have the turn fail.

---

## MCP servers

`ChatMCP` exposes any number of [Model Context Protocol](https://modelcontextprotocol.io)
servers to the model as ordinary tools. `MCPManager` is itself a `ToolProvider`,
so wiring it up is a one-liner in the session configuration.

```swift
let manager = MCPManager(
    store: MCPServerStore(),
    seedServers: [
        MCPServerConfig(name: "Docs",
                        transport: .http(url: URL(string: "https://example.com/mcp")!,
                                         auth: .bearer(token: "…")))
    ])

await manager.loadAndConnectEnabled()
await manager.setReadOnly(["search_docs"])

let configuration = ChatSessionConfiguration(backend: backend,
                                             toolProviders: [manager])
```

`MCPServerStore` persists the user's server list in `UserDefaults` (key and suite
both injectable). `loadAndConnectEnabled()` merges the seeds you pass with what
the user has saved — seeds never resurrect a server the user disabled.

### Transports

| Transport | Availability | Notes |
|---|---|---|
| `.stdio(command:arguments:)` | macOS only | Launches a child process. `PATH` is augmented with the usual Homebrew and `nvm` locations, because a GUI app inherits launchd's minimal `PATH` and would not otherwise find `npx`. |
| `.http(url:auth:)` | macOS and iOS | Streamable HTTP. `auth` is `.none`, `.bearer(token:)`, or `.oauth`. |

OAuth is a seam, not an implementation: a server configured with `.oauth` is
reported as `.needsAuth` unless you supply an `MCPAuthorizationProvider`. The
browser flow and token storage belong to the host, which knows its own identity
and keychain.

### Importing an existing config

The standard `mcpServers` file format is read directly, so a user can paste the
config they already use elsewhere:

```swift
let servers = MCPServerConfig.decodeMCPServers(from: data)
```

Unrecognised keys are skipped rather than failing the whole import — these files
routinely contain fields this package knows nothing about.

### Tool naming and permissions

Tool names are recomputed across all servers in list order whenever the connected
set changes. The first server to claim a name keeps it; later ones are prefixed
with their server name (`Beta_Server_read`). Resolving collisions incrementally
would make a name depend on connection order, so a reconnect could rename a tool
mid-session and strand the model's memory of it.

No MCP tool is ever auto-allowed, and every one counts as mutating in plan mode
unless you name it in `setReadOnly(_:)`. The package cannot know what a
third-party tool does, so it assumes the worst.

### Connection state

`MCPManager` is an `actor` — `ToolProvider` inherits `Sendable`, and Swift 6
rejects a main-actor-isolated conformance to it. Hosts that render connection
state pass `onStatusChange`, which is delivered on the main actor:

```swift
let manager = MCPManager(store: MCPServerStore()) { statuses in
    for status in statuses.values where status.state == .needsAuth {
        promptSignIn(for: status.id)
    }
}
```

A call to a dead server is retried once after reconnecting. Stdio children die
quietly, and a crashed child looks exactly like a failed call until you try again.

---

## Rendering

`ChatUI` is its own product (`SwiftChatKitUI`) and its own target. The
engine never imports it, so a headless host — a CLI, a server, a test — pays
nothing for it.

```swift
import ChatUI

ScrollView {
    LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(messages) { message in
            StreamingTextView(text: message.content)
        }
    }
    .padding()
}
.chatPalette(.default)
```

`StreamingTextView` renders one message. It coalesces streaming deltas to one
render per frame: text arrives at roughly 60 fps, and re-parsing the whole
message on every token append is what makes a fast turn stutter.

### One text storage per message

Everything that can share a single text view does — headings, prose, lists,
quotes, tables — so a drag selects across all of them in one gesture. Per-block
SwiftUI views each own their own selection scope, which is why selection stops at
every boundary when they are used instead.

Fenced code blocks are the deliberate exception. Code cannot both scroll
sideways and live in the message's text storage: TextKit gives one container one
width, so a non-wrapping paragraph either clips or forces the whole message to
scroll. Scrolling wins, because wrapped code misleads — a wrapped line looks like
a new statement and indentation stops meaning anything. The cost is that a
selection stops at a code block's edge.

`MarkdownSegment.split` is where that trade is made, and it is testable on its
own:

```swift
let segments = MarkdownSegment.split(MarkdownBlockParser.parse(text), style: style)
```

### Theming

The renderer's entire theming surface is `ChatPalette`, injected through the
environment. The default is built from system semantic colors, so a host that
never sets one still gets a renderer that follows light and dark mode.

```swift
let palette = ChatPalette(
    accent: .blue,
    background: Color(white: 0.1),
    codeBackground: Color(white: 0.16),
    header: Color(white: 0.2),
    divider: Color(white: 0.3),
    outline: Color(white: 0.3),
    primaryText: .white,
    secondaryText: Color(white: 0.65))

ChatView().chatPalette(palette)
```

`MarkdownStyle.from(palette:appearanceIsDark:)` resolves a palette into the
concrete fonts and colors the builder works in. It is needed because the builder
runs below SwiftUI and cannot resolve a `Color` itself. To render Markdown
outside a view hierarchy entirely:

```swift
let style = MarkdownStyle.from(palette: .default, appearanceIsDark: false)
let result = MarkdownAttributedBuilder.build(MarkdownBlockParser.parse(text), style: style)
result.attributed     // NSAttributedString
result.codeRegions    // where the fenced blocks landed
```

### Agent cards

| View | Shows |
|---|---|
| `PermissionRequestView` | A pending approval. Renders a real diff for `writeFile` / `editFile` rather than raw JSON arguments — an edit should be judged on what it changes. |
| `QuestionCardView` | The `askUser` questions, paged one at a time, with options and a free-text "Other". `assistantName` supplies the title, since the package has no product name of its own. |
| `TodoListPanelView` | The agent's task list. Collapsed it shows only the task in progress. |
| `ThinkingIndicatorView` | Animated dots for `session.isThinking`. `label:` is the text beside them, or `nil` for dots alone. |
| `FileDiffPreviewView` | A GitHub-style diff with line numbers, used by the approval card and usable on its own. |
| `JumpToBottomButton` | Offered while the reader is scrolled up during a turn. |

Put the indicator at the end of the transcript, where the answer will appear:

```swift
if session.isThinking {
    ThinkingIndicatorView()
}
```

`isThinking` is deliberately narrower than `isStreaming`. It goes false on the
first token — streaming text is its own indicator, and showing both reads as two
things happening at once — and it is false while a permission card or question
is parked, because the run is waiting on the *user* then. It goes true again
between turns, while tools run and there is nothing to look at.

### Auto-scroll

`ChatAutoScrollController` is the follow/disengage state machine, separated from
any view so it can be tested:

```swift
let controller = ChatAutoScrollController()
controller.reportDistanceFromBottom(distance)
controller.followStream(proxy, anchor: "bottom")   // per streaming update
controller.followEvent(proxy, anchor: "bottom")    // per new message
```

Following is unanimated at frame rate, because the deltas are line-sized and
animating each step is what causes the lurch. Only a large jump — a restored
session, a big code block — is animated. Scrolling up disengages following
entirely; returning to the bottom re-arms it, which is what makes a manual
scroll-up stick instead of yanking the reader back down.

### Platforms

Both platforms are supported from one source. AppKit and UIKit differences are
funnelled through `Platform.swift`, and the two places they genuinely diverge are
called out where they happen: macOS lays out GFM tables with `NSTextTable`, which
UIKit has no equivalent for and where tab stops stand in; and the scroll-wheel
monitor that detects manual scrolling is macOS-only, since iOS surfaces drags
through the gesture system.

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

`LocalFileSystem` is the default, but conform your own type to point the file
tools at a virtual project, an in-memory fixture, or a remote workspace. Covers
`currentDirectory`/`setCurrentDirectory`, `readText`/`readData`,
`write`/`edit`, `createDirectory`, `list`, `move`, `info`, `glob` and `grep`.

Paths arrive relative to `currentDirectory()` unless absolute — resolving them
is the conformer's job. `edit` must throw when an `oldText` is absent rather
than reporting a success that changed nothing.

---

# Not built yet

Still to come: slash commands (`/clear`, `/compact`, `/plan`, `/init`).

---

## The demo app

`Examples/ChatDemo` is a standalone macOS app — a separate package that depends
on SwiftChatKit **by path, the way a real consumer would**. If it builds, the
package stands on its own rather than only inside its own test target.

```sh
swift run --package-path Examples/ChatDemo
```

It needs no credentials: with no `GoogleService-Info.plist` present it falls back
to an `EchoBackend` that streams a canned reply, which is enough to drive the
renderer, the permission card and the auto-scroll. Drop a plist in and it uses
`GeminiBackend` instead.

`EchoBackend.swift` is worth reading on its own — it is the shortest possible
answer to what a backend has to do.

There is no iOS demo yet. `Examples/iOS-Example-Handoff.md` is the brief for
building one: which products to depend on, which pieces compile away on iOS
(shell tools, MCP stdio, the scroll-wheel reporter), and the acceptance list.

---

## Building and testing

```sh
swift build
swift test

# iOS. The whole package builds; the shell tools and the MCP stdio transport
# compile away to nothing there. `swift build --triple …ios…` silently uses the
# macOS SDK, so a destination is required.
xcodebuild -scheme SwiftChatKit -destination 'generic/platform=iOS' build

# The demo, as an external consumer.
swift build --package-path Examples/ChatDemo
```

Currently 328 tests across 52 suites. The Markdown suites are ported verbatim
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
