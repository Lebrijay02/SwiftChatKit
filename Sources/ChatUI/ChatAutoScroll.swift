//
//  ChatAutoScroll.swift
//  SwiftChatKit
//
//  Keeps the transcript pinned to the bottom while a turn streams in.
//
//  The naive version — `withAnimation { proxy.scrollTo(.bottom) }` on every content
//  change — is what makes streaming feel harsh. Text arrives at ~60 fps, so each frame
//  starts a fresh 0.15s ease-out that interrupts the one still running. The scroll never
//  settles into a constant velocity; it lurches. Worse, it fires even when the reader has
//  scrolled up to re-read something, yanking them back down.
//
//  So: follow unanimated at frame rate (continuous, because the deltas are line-sized),
//  animate only the occasional large jump, and stop following the moment the reader
//  scrolls away.
//

import SwiftUI

/// Reports how far the transcript's bottom anchor sits below the viewport.
public struct ChatBottomOffsetKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
@Observable
public final class ChatAutoScrollController {

    public init() {}

    /// Within this many points of the bottom still counts as "pinned", so a stray
    /// trackpad twitch doesn't disengage following.
    private static let pinnedThreshold: CGFloat = 48

    /// A gap this large means content appeared in one lump — a code block or a restored
    /// session — where an instant jump would be jarring and an animation reads better.
    private static let animateAboveGap: CGFloat = 240

    /// False once the reader scrolls up; restored when they come back to the bottom.
    public private(set) var isFollowing = true

    /// Distance from the viewport bottom to the transcript's end, in points.
    private var distanceFromBottom: CGFloat = 0

    /// True while a whole transcript is being swapped in. The rows land over a few
    /// passes, and every one of them would otherwise start its own animated scroll —
    /// a slide through messages the reader never asked to see.
    private var isRestoring = false

    /// True when the reader has scrolled far enough up to warrant a "jump to bottom"
    /// affordance rather than silently dragging them along.
    public var isAwayFromBottom: Bool { !isFollowing && distanceFromBottom > Self.pinnedThreshold }

    public func reportDistanceFromBottom(_ distance: CGFloat) {
        distanceFromBottom = max(0, distance)
        // Coming back to the bottom re-arms following; this is the only way to re-engage,
        // which is what makes manual scroll-up stick.
        if distanceFromBottom <= Self.pinnedThreshold {
            isFollowing = true
        }
    }

    /// Called when the reader drags or scrolls by hand.
    public func userDidScroll() {
        if distanceFromBottom > Self.pinnedThreshold {
            isFollowing = false
        }
    }

    /// Follows a streaming update. No animation: at 60 fps the content grows by about a
    /// line at a time, and unanimated frame-rate scrolling is what actually reads as
    /// smooth. Animating each step is what causes the stutter.
    public func followStream(_ proxy: ScrollViewProxy, anchor: String) {
        guard isFollowing else { return }
        if distanceFromBottom > Self.animateAboveGap {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    /// Follows a discrete event — a new message, a sent prompt — where a short animation
    /// helps the reader see that something was appended.
    public func followEvent(_ proxy: ScrollViewProxy, anchor: String) {
        isFollowing = true
        guard !isRestoring else {
            proxy.scrollTo(anchor, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(anchor, anchor: .bottom) }
    }

    /// Snaps to the end with no animation, for when the transcript is replaced wholesale —
    /// a new chat, or one restored from history. Whatever the reader had scrolled to
    /// belonged to the previous conversation, so following starts re-armed.
    public func snapToBottom(_ proxy: ScrollViewProxy, anchor: String) {
        isFollowing = true
        distanceFromBottom = 0
        isRestoring = true
        proxy.scrollTo(anchor, anchor: .bottom)
    }

    /// Ends the restore window opened by ``snapToBottom(_:anchor:)``; call it once the
    /// swapped-in rows have laid out.
    public func transcriptDidSettle() {
        isRestoring = false
    }

    /// Explicit jump, from the button offered when following is disengaged.
    public func jumpToBottom(_ proxy: ScrollViewProxy, anchor: String) {
        isFollowing = true
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .bottom) }
    }
}

#if canImport(AppKit)
import AppKit

// MARK: - Manual scroll detection

/// Reports trackpad and wheel scrolling, which SwiftUI's ScrollView does not surface.
/// Used to tell "the reader scrolled up" apart from "we scrolled because text arrived".
public struct ManualScrollReporter: NSViewRepresentable {

    public let onScroll: () -> Void

    public init(onScroll: @escaping () -> Void) { self.onScroll = onScroll }

    public func makeNSView(context: Context) -> NSView {
        let view = ScrollMonitorView()
        view.onScroll = onScroll
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollMonitorView)?.onScroll = onScroll
    }

    private final class ScrollMonitorView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Leaving the hierarchy is the teardown hook: `removeMonitor` is
            // main-actor-only and so cannot be called from a nonisolated deinit.
            guard window != nil else {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            // Local monitor rather than a scrollWheel override: this view is a zero-size
            // probe, so the events land on the enclosing scroll view, not on it.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                self.onScroll?()
                return event
            }
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

#endif

// MARK: - Jump to bottom

/// Offered while the reader is scrolled up during a turn, so following can be dropped
/// without stranding them.
public struct JumpToBottomButton: View {

    public let action: () -> Void

    public init(action: @escaping () -> Void) { self.action = action }

    @Environment(\.chatPalette) private var palette
    @State private var isHovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("Jump to latest")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(palette.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(palette.header)
                    .overlay(Capsule().stroke(palette.divider, lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(isHovering ? 0.25 : 0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
