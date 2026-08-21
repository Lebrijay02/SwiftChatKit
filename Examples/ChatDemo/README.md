# ChatDemo

A standalone macOS app that initializes a `ChatSession` and renders it. Roughly
200 lines, most of which is the transcript layout.

It is a **separate package** that depends on SwiftChatKit by path, exactly the
way a real consumer would. That is the point of it: if this builds, the package
stands on its own rather than only inside its own test target.

```sh
swift run --package-path Examples/ChatDemo
```

## Without a Firebase project

The demo runs with no credentials at all. When there is no
`GoogleService-Info.plist` it falls back to `EchoBackend`, which streams a canned
reply back a word at a time — enough to drive the renderer, the auto-scroll and
the composer.

`EchoBackend.swift` is also the shortest possible answer to "what does a backend
have to do?": stream text, optionally emit tool calls, report usage, finish.

## With one

Drop a `GoogleService-Info.plist` beside the binary and the app configures
Firebase and uses `GeminiBackend` instead. The Vertex AI API has to be enabled on
that project.

## What it wires up

| Piece | Why it is here |
|---|---|
| `FileToolProvider` + `LocalFileSystem` | Gives the model real file tools, rooted at the home directory. |
| `ShellToolProvider` | The tool that most needs the permission gate. |
| `autoAllowedTools: FileToolProvider.readOnlyNames` | Reads run unprompted; writes and commands stop for approval. |
| `EphemeralPermissionStore` | A demo should not leave "always allow" decisions behind in `UserDefaults`. |
| `PermissionRequestView`, `QuestionCardView`, `TodoListPanelView` | The engine asking the user something mid-turn. |
| `ChatAutoScrollController` + `JumpToBottomButton` | Following while streaming, without trapping a reader who scrolled up. |
