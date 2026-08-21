# Handoff — build an iOS example app for SwiftChatKit

You are being asked to build a small iOS app that exercises SwiftChatKit end to
end: send a message, stream a reply, call a tool, approve it, stop mid-stream,
reload a saved session. There is already a macOS reference app at
`Examples/ChatDemo` — mirror it, don't invent a new shape.

Everything below was verified against the package at commit `35ef670`, not
inferred from the source.

## 1. What the package is

A neutral agentic chat engine. You configure one object and then `send` / `stop`
and read `messages`. No UI is required by the engine; an optional SwiftUI layer
ships alongside it.

Repo: `/Users/juan.lebrija/Desktop/Softtek/Packages/SwiftChatKit` (private,
`main`). Depend on it by path or by URL.

One product per capability — nothing arrives unless you ask for it:

| Product | Target | Use it for |
|---|---|---|
| `SwiftChatKit` | `ChatCore` | the engine: models, agent loop, seams. Zero external dependencies |
| `SwiftChatKitGemini` | `ChatGemini` | the Gemini backend (pulls in Firebase) |
| `SwiftChatKitTools` | `ChatTools` | the file and shell tool providers |
| `SwiftChatKitMCP` | `ChatMCP` | MCP servers as tools (pulls in the MCP SDK) |
| `SwiftChatKitUI` | `ChatUI` | Markdown renderer, permission/question/todo cards, auto-scroll |

Each capability product re-exports `ChatCore`, so `import ChatGemini` is enough
on its own. For this example, take `SwiftChatKitGemini`, `SwiftChatKitTools` and
`SwiftChatKitUI`.

Minimum platforms: macOS 14, iOS 17. Swift tools 6.2, Swift 6 language mode —
your example target should also use `swiftLanguageModes: [.v6]` so strict
concurrency problems surface in the example rather than in a consumer later.

## 2. What is macOS-only — read this before designing the app

The package builds clean for iOS, but three areas compile away to nothing there.
Do not build the example around them.

- **`ShellToolProvider` and `CommandRunner`** (`Sources/ChatTools`) are behind
  `#if os(macOS)`. There is no subprocess execution on iOS. Omit them from
  `toolProviders`.
- **MCP stdio transport** (`Sources/ChatMCP/StdioLauncher.swift`, and the
  process-owning fields of `MCPManager`) is macOS-only. `MCPServerTransport` has
  two cases; on iOS only `.http(url:auth:)` is usable. If the example
  demonstrates MCP at all, point it at an HTTP server.
- **`SkillsConfiguration.claudeCompatible`** silently degrades on iOS: there is
  no user home directory, so only the project-relative `.claude/skills` half
  applies. A sandboxed iOS app has nowhere global to read skills from anyway.
  Prefer `.disabled` for the example unless you are specifically testing skills.

Everything else — `ChatSession`, `FileToolProvider` + `LocalFileSystem`,
`ChatHistoryStore`, `GeminiBackend`, the whole of `ChatUI` — is cross-platform.

`LocalFileSystem` on iOS should be rooted at the app's Documents directory, not
`homeDirectoryForCurrentUser` (which does not exist there). Seed it with a couple
of sample files at first launch so the file tools have something to find.

## 3. The API you will use

```swift
let session = ChatSession(configuration: .init(
    backend: backend,                                  // any ChatBackend
    toolProviders: [FileToolProvider(fileSystem: fs)],  // no ShellToolProvider on iOS
    persona: .codingAgent,       // the tool-aware persona; `.default` describes no tools
    workingDirectory: documentsURL,
    skills: .disabled,
    enableTodos: true,           // off by default — nothing is pre-set
    enableQuestions: true,
    historyStore: .applicationSupport("ChatDemoiOS"),
    autoAllowedTools: FileToolProvider.readOnlyNames,
    permissionStore: EphemeralPermissionStore()))
```

Full initializer parameter list (all after `backend` have defaults):

```
backend, toolProviders, persona, projectContext, projectContextTitle,
additionalSections, workingDirectory, skills, maxTurns, enableTodos,
enableQuestions, autoAllowedTools, permissionStore, historyStore,
compressor, telemetry, onRunFinished
```

`ChatSession` is `@Observable @MainActor`. Read:

```
messages: [ChatMessage]   isStreaming: Bool   isThinking: Bool   error: String?
todos: [TodoItem]         usage: TokenUsage   planMode: Bool
sessionID: UUID           title: String
permissions: PermissionService   questions: QuestionService   skills: SkillsService
```

Call:

```
send(_ text: String, attachments: [Attachment] = [])
stop()   regenerate()   newChat()   load(_ id: UUID)   save()   setPlanMode(_:)
```

`Attachment` is `Data + mimeType + kind` — deliberately AppKit/UIKit-free, so
feeding it from `PhotosPicker` or `UIDocumentPicker` is a straight conversion.
Its `Kind` cases and convenience constructors are in
`Sources/ChatCore/Models/Attachment.swift`.

Permission stores: `EphemeralPermissionStore` (forget on quit — right for a demo)
or `UserDefaultsPermissionStore` (persist always-allow decisions).

History: `ChatHistoryStore.applicationSupport("YourApp")` works on iOS as-is;
`loadAll()` / `load(_:)` / `save(_:)` / `delete(_:)`. Wire a session list so the
reload-a-saved-session step of the acceptance list is actually testable.

## 4. Backends

Two options, and the example should support both the way the macOS demo does —
check for `GoogleService-Info.plist` at launch and fall back.

**Without credentials:** copy `Examples/ChatDemo/Sources/ChatDemo/EchoBackend.swift`
verbatim. It is ~70 lines, has no network behind it, streams word by word so the
renderer's throttling has something to throttle, and doubles as the minimal
documentation of the `ChatBackend` contract. This is what makes the example
runnable by anyone who just cloned the repo.

**With credentials:** `GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash,
location: "global", enableGoogleSearch: true))`, after `FirebaseApp.configure()`.

> Caveat, stated plainly: the Gemini path has unit tests but **has never been run
> against a live endpoint**. If you wire it up with a real Firebase project, you
> are the first to do so — treat any failure there as a likely package bug and
> report it rather than working around it.

The `ChatBackend` contract itself is small:

```swift
func configure(systemInstruction: String, tools: [ToolDeclaration], history: [ChatTurn]) async
nonisolated func stream(_ input: TurnInput) -> AsyncThrowingStream<TurnChunk, Error>
var history: [ChatTurn] { get async }
var modelName: String { get }
```

Two things that have tripped people up: `TurnInput` exposes `.parts`, **not**
`.text`; and finishing is two chunks, `.usage(_)` then `.finish(_)`, not a single
combined case. `TurnChunk` is `.text / .toolCall / .usage / .finish`.

## 5. UI

Import `ChatUI` and reuse:

- `StreamingTextView(text:)` — the Markdown renderer, 60 FPS coalesced. Use it
  for assistant messages.
- `PermissionRequestView(request:permissions:)`,
  `QuestionCardView(questions:service:assistantName:)`,
  `TodoListPanelView(todos:)`, `FileDiffPreviewView`.
- `ThinkingIndicatorView(label:)` — render it on `session.isThinking`, at the end
  of the transcript. It stops on its own at the first token.
- `ChatAutoScrollController` + `JumpToBottomButton`.
- `.chatPalette(.default)` on the root view; `ChatPalette` has eight colors and
  flows through the environment, so theming is one modifier.

Two iOS caveats in `ChatUI`:

- **`ManualScrollReporter` is AppKit-only.** It watches scroll-wheel events, which
  have no iOS equivalent. The macOS demo attaches it as the `ScrollView`
  background; on iOS drop it and detect manual scrolling with a
  `DragGesture(minimumDistance: 1)` or a scroll-offset `GeometryReader` instead,
  then call `autoScroll.userDidScroll()`. The controller itself is
  cross-platform.
- **GFM tables render differently.** The macOS path uses `NSTextTable`, which has
  no UIKit equivalent; iOS falls back to tab stops with a fixed 120pt column
  width. Expect tables to look plainer, not broken. Not a bug to fix in the
  example.

`Examples/ChatDemo/Sources/ChatDemo/ChatDemoView.swift` is ~130 lines and shows
the whole shape: transcript, agent cards, composer. Port it, swap the two items
above, and drop the `.frame(minWidth:minHeight:)` / `WindowGroup` for an iOS
scene.

## 6. Building and verifying

The example should be its own SwiftPM package or Xcode project depending on
SwiftChatKit **by path**, exactly as `Examples/ChatDemo` does. That is the point
of the structure: if the example builds, the package stands alone rather than
only inside its own test target.

```bash
xcodebuild -scheme SwiftChatKit -destination 'generic/platform=iOS' \
  -derivedDataPath <scratch>/sck-ios build
```

`swift build --triple arm64-apple-ios17.0` **silently uses the macOS SDK** and
produces a wall of misleading `Security`/`xpc` header errors. Use `xcodebuild`
with a destination, always.

For anything run against the package itself, pass both
`--package-path <repo>` and `--scratch-path <scratch>`; the package lives under
`~/Desktop` and `.DS_Store` races SwiftPM's binary-artifact extraction otherwise.

Current baseline to preserve: `swift test` is **289 tests across 46 suites,
green**, and the full `SwiftChatKit` scheme builds for `generic/platform=iOS`.

Acceptance for the example: send a message, watch it stream, trigger a file tool,
approve it at the permission card, stop mid-stream, quit and reload a saved
session from the history store.

## 7. Constraints to respect

The package is deliberately **free of any FridaGPT specifics** and must stay that
way. If the example needs app-specific behavior, add it as a `ToolProvider` /
`ChatTelemetry` / `ContextCompressor` conformer in the example target — never by
editing `Sources/`. Do not move any credential, endpoint, or app identifier into
the package; telemetry config is injected by the host.

The repo is private and has no LICENSE. Do not publish the example anywhere
public, and do not add one.
