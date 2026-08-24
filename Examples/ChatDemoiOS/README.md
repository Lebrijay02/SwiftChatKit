# ChatDemoiOS

A standalone iOS app that initializes a `ChatSession` and renders it — the
smallest host worth shipping. `ChatDemoMac` is the same app for macOS, and the
two share every file that isn't a view.

It is an **Xcode project depending on SwiftChatKit by path** (`../..`), exactly
the way a real consumer would. If it builds, the package stands on its own
rather than only inside its own test target.

```sh
open Examples/ChatDemoiOS/ChatDemoiOS.xcodeproj

# or, without opening Xcode
xcodebuild -project Examples/ChatDemoiOS/ChatDemoiOS.xcodeproj \
  -scheme ChatDemoiOS -destination 'generic/platform=iOS Simulator' build
```

Signing is automatic with no team set, so Xcode asks for yours the first time
you run on a device. The simulator needs nothing.

## First launch

There are no credentials in this repository and **no canned fallback backend** —
a demo echoing a fixed string proves nothing about the package. So the app opens
on a setup sheet and builds no `ChatSession` until it is filled in. The gear in
the toolbar reopens it later.

| Backend | What it needs |
|---|---|
| OpenAI-compatible | A base URL, a model id, and a key if the server checks one. Anything speaking `/chat/completions`: OpenAI, OpenRouter, a gateway, a local vLLM or Ollama. |
| Gemini (Firebase) | A `GoogleService-Info.plist` dropped into the app target. The sheet offers this option only when the build has one, and there is no key to type. |

The choice, the model and the optional `user_id` / `email` attribution fields go
to `UserDefaults`; **the API key goes to the Keychain** and nowhere else. That
split is the whole of `DemoConfigurationStore.swift`, and it is the smallest
honest version of the warning on `OpenAIBackendConfig.apiKey`: a key compiled
into a shipped app is a key that has already leaked.

## Shared with ChatDemoMac

`Examples/ChatDemoShared` is a synchronized folder in both Xcode projects:

| File | What it is |
|---|---|
| `DemoConfiguration.swift` | What the user picked, and what counts as complete. |
| `DemoConfigurationStore.swift` | `UserDefaults` for the settings, Keychain for the key. |
| `DemoBackend.swift` | Configuration in, `any ChatBackend` out. Both branches are one initializer — that is the whole backend seam. |
| `ConfigurationView.swift` | The setup sheet. |
| `RootView.swift` | The gate: no session exists until a backend does. |

Only `ChatDemoiOSApp.swift` and `ChatView.swift` are per-platform.

## What is different from the macOS version

| Piece | Why |
|---|---|
| `DragGesture` instead of `ManualScrollReporter` | The reporter watches scroll-wheel events and is AppKit-only. A drag is the iOS equivalent signal into `autoScroll.userDidScroll()`. |
| Send button, no `onSubmit` | Return inserts a newline on a software keyboard. |
| `.scrollDismissesKeyboard(.interactively)` | No equivalent problem on a Mac. |

Neither version wires up tools: `Sources/ChatTools`'s shell runner is
`os(macOS)` only and MCP's stdio transport launches a process, so keeping the
two apps identical means keeping both out. Capabilities are opt-in, so
`persona: .default` and an empty provider list is the entire configuration.

GFM tables also render plainer on iOS: the macOS path uses `NSTextTable` and iOS
falls back to tab stops at a fixed column width. Not a bug, and not something
this example works around.
