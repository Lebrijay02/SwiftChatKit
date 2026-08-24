# ChatDemoMac

`ChatDemoiOS`, adapted to macOS. Same app, same session wiring, same setup
sheet — the two share every file that isn't a view, out of
`Examples/ChatDemoShared`.

It is an **Xcode project depending on SwiftChatKit by path** (`../..`), exactly
the way a real consumer would.

```sh
open Examples/ChatDemoMac/ChatDemoMac.xcodeproj

# or, without opening Xcode
xcodebuild -project Examples/ChatDemoMac/ChatDemoMac.xcodeproj \
  -scheme ChatDemoMac -destination 'platform=macOS' build
```

Sandboxed, with `com.apple.security.network.client` and nothing else — the whole
app is one outgoing HTTPS connection to whichever backend the user configured.

## First launch

There are no credentials in this repository and **no canned fallback backend**.
The app opens on a setup sheet and builds no `ChatSession` until it is filled in;
the gear in the toolbar reopens it later. See
[`../ChatDemoiOS/README.md`](../ChatDemoiOS/README.md) for what each backend
needs and where the key is stored — it is identical here.

## What is different from the iOS version

| Piece | Why |
|---|---|
| `ManualScrollReporter` instead of `DragGesture` | It watches scroll-wheel events, which is the AppKit signal that the user took over the transcript. |
| `.onSubmit(send)` on the composer | Return is a real key here, so it sends rather than inserting a newline. |
| `.frame(minWidth:minHeight:)` on the scene | A window has a size to constrain; a phone screen does not. |
| Toolbar placements `.navigation` / `.primaryAction` | `.topBarLeading` / `.topBarTrailing` are iOS-only. |

That is the entire diff, and it is why both apps are worth having: everything
above the platform line is the same code.

## Not the same as `Examples/ChatDemo`

`Examples/ChatDemo` is also a macOS app, but a different demo: a SwiftPM package
that wires up `FileToolProvider`, `ShellToolProvider`, the permission card, the
todo panel and the question card. Read that one for what an **agent** looks like.
Read this one for the **minimum** — a backend and a transcript, nothing else.
