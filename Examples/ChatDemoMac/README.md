# ChatDemoMac

`ChatDemoiOS`'s sibling, minus the two things a phone can't offer: file and
shell tools. They share every file that isn't a view, out of
`Examples/ChatDemoShared`, and both wire up MCP, history, skills-viewing and
plan mode identically — see [`../ChatDemoiOS/README.md`](../ChatDemoiOS/README.md)
for that shared half.

It is an **Xcode project depending on SwiftChatKit by path** (`../..`), exactly
the way a real consumer would.

```sh
open Examples/ChatDemoMac/ChatDemoMac.xcodeproj

# or, without opening Xcode
xcodebuild -project Examples/ChatDemoMac/ChatDemoMac.xcodeproj \
  -scheme ChatDemoMac -destination 'platform=macOS' build
```

**Not sandboxed.** `ShellToolProvider` launches arbitrary commands and
`FileToolProvider` reads and writes anywhere under the user's home directory —
there is no App Sandbox entitlement that permits either, so
`ChatDemoMac.entitlements` turns the sandbox off rather than pretending. Same
tradeoff `Examples/ChatDemo` already makes.

## First launch

There are no credentials in this repository and **no canned fallback backend**.
The app opens on a setup sheet and builds no `ChatSession` until it is filled in;
the toolbar menu reopens it later. See
[`../ChatDemoiOS/README.md`](../ChatDemoiOS/README.md) for what each backend
needs and where the key is stored — it is identical here.

## What is different from the iOS version

| Piece | Why |
|---|---|
| `FileToolProvider` + `ShellToolProvider` | `Sources/ChatTools`'s shell runner is `os(macOS)` only, so this is the one platform that gets a filesystem to work in. `persona: .codingAgent` and `enableTodos`/`enableQuestions` follow from having tools worth planning and checklisting. |
| `SkillsConfiguration.claudeCompatible` | Reads `~/.claude/skills`, the same folder Claude Code reads. iOS has no home directory a user manages, so skills stay `.disabled` there and the settings screen hides the section. |
| `workingDirectory` set to the user's home | Scopes tool path resolution and skill discovery; iOS leaves it `nil`. |
| `ManualScrollReporter` instead of `DragGesture` | It watches scroll-wheel events, which is the AppKit signal that the user took over the transcript. |
| `.onSubmit(send)` on the composer | Return is a real key here, so it sends rather than inserting a newline. |
| `.frame(minWidth:minHeight:)` on the scene | A window has a size to constrain; a phone screen does not. |
| Toolbar placements `.navigation` / `.primaryAction` | `.topBarLeading` / `.topBarTrailing` are iOS-only. |

Everything else — MCP (seeded from `DefaultMCPServers`), `ChatHistoryStore`,
the settings sheet, the plan-mode toggle — is identical code shared out of
`Examples/ChatDemoShared`.

## Not the same as `Examples/ChatDemo`

`Examples/ChatDemo` is also a macOS app, and now overlaps this one more than it
used to: both wire up `FileToolProvider` and `ShellToolProvider`. The
difference is `Examples/ChatDemo` ships an `EchoBackend` fallback so it always
runs with zero configuration, has no setup sheet, no MCP, no history and no
skills — it is the smaller, single-file illustration of "what does an agent
look like". This one is the fuller host: real backend configuration, MCP
servers, saved conversations, and Agent Skills, all through the same
`ChatSession` initializer.
