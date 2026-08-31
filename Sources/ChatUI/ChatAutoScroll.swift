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

    /// Set once a scroll view reports its own geometry directly (iOS 18 / macOS 15).
    /// The anchor keeps measuring itself for older systems; when both are available the
    /// scroll view's own numbers win, so the two don't take turns overwriting each other.
    private var usesScrollGeometry = false

    /// Bottom edge of the viewport and top edge of the trailing anchor, both in global
    /// coordinates. Either can arrive first, so the distance is recomputed from whichever
    /// pair is current rather than from the order they land in.
    private var viewportBottomY: CGFloat?
    private var anchorTopY: CGFloat?

    /// When the last streaming follow ran. Discrete events landing inside this window
    /// drop their animation: a 0.22s ease-out started while unanimated frame-rate
    /// scrolling is underway gets cut off by the very next frame, and that interruption
    /// is the lurch. During a turn, everything scrolls the same continuous way.
    private var lastStreamFollow: ContinuousClock.Instant?
    private static let streamQuietWindow = Duration.milliseconds(250)

    private var isStreamActive: Bool {
        guard let lastStreamFollow else { return false }
        return ContinuousClock.now - lastStreamFollow < Self.streamQuietWindow
    }

    /// True while a whole transcript is being swapped in. The rows land over a few
    /// passes, and every one of them would otherwise start its own animated scroll —
    /// a slide through messages the reader never asked to see.
    private(set) var isRestoring = false

    /// Where to keep scrolling while the swapped-in transcript settles.
    private var restoreTarget: (proxy: ScrollViewProxy, anchor: String)?

    /// Ends a restore that never reports itself settled, so a transcript that cannot
    /// reach its own end doesn't leave every later scroll unanimated.
    private var restoreTimeout: Task<Void, Never>?

    /// True when the reader has scrolled far enough up to warrant a "jump to bottom"
    /// affordance rather than silently dragging them along.
    public var isAwayFromBottom: Bool { !isFollowing && distanceFromBottom > Self.pinnedThreshold }

    public func reportDistanceFromBottom(_ distance: CGFloat) {
        usesScrollGeometry = true
        apply(distance: distance)
    }

    /// Bottom edge of the transcript's viewport, in global coordinates.
    public func reportViewportBottom(_ y: CGFloat) {
        viewportBottomY = y
        recomputeDistanceFromGeometry()
    }

    /// Top edge of the trailing anchor row, in global coordinates. Below the viewport
    /// bottom means there is transcript the reader hasn't scrolled to yet.
    public func reportAnchorTop(_ y: CGFloat) {
        anchorTopY = y
        recomputeDistanceFromGeometry()
    }

    private func recomputeDistanceFromGeometry() {
        guard !usesScrollGeometry, let viewportBottomY, let anchorTopY else { return }
        apply(distance: anchorTopY - viewportBottomY)
    }

    private func apply(distance: CGFloat) {
        distanceFromBottom = max(0, distance)
        // Coming back to the bottom re-arms following; this is the only way to re-engage,
        // which is what makes manual scroll-up stick.
        if distanceFromBottom <= Self.pinnedThreshold {
            isFollowing = true
        }
        driveRestore()
    }

    /// A restored transcript's rows are lazy: the first scroll aims at a stack that has
    /// not measured itself yet, and lands short. Every subsequent measurement is a report
    /// through here, so the restore rides the layout passes as they actually happen
    /// rather than guessing at how many there will be and how far apart.
    private func driveRestore() {
        guard isRestoring else { return }
        guard distanceFromBottom > Self.pinnedThreshold else {
            endRestore()
            return
        }
        if let target = restoreTarget {
            target.proxy.scrollTo(target.anchor, anchor: .bottom)
        }
    }

    /// Enters the restore state. Split out from ``snapToBottom(_:anchor:)`` so it can be
    /// entered without a scroll view — which is also the only way to reach it from a test,
    /// since `ScrollViewProxy` cannot be constructed.
    func beginRestore() {
        isFollowing = true
        distanceFromBottom = 0
        isRestoring = true
        anchorTopY = nil
        lastStreamFollow = nil
    }

    private func endRestore() {
        isRestoring = false
        restoreTarget = nil
        restoreTimeout?.cancel()
        restoreTimeout = nil
    }

    /// Called when the reader drags or scrolls by hand.
    ///
    /// Disengages unconditionally rather than checking the distance first. A wheel event
    /// arrives before the layout pass it causes, so at the top of an upward scroll the
    /// distance is still the old ~0 — testing it there means the first few events are
    /// ignored and the reader gets dragged back down. Disengaging immediately and letting
    /// ``reportDistanceFromBottom(_:)`` re-arm costs at most one frame of following when
    /// the scroll turns out not to have moved anywhere.
    public func userDidScroll() {
        isFollowing = false
    }

    /// Follows a streaming update. No animation: at 60 fps the content grows by about a
    /// line at a time, and unanimated frame-rate scrolling is what actually reads as
    /// smooth. Animating each step is what causes the stutter.
    public func followStream(_ proxy: ScrollViewProxy, anchor: String) {
        guard isFollowing else { return }
        lastStreamFollow = ContinuousClock.now
        if distanceFromBottom > Self.animateAboveGap {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    /// Follows a discrete event — a new message, a sent prompt — where a short animation
    /// helps the reader see that something was appended.
    ///
    /// Mid-turn there is no such gap to show: the events that fire while a model is
    /// answering (the thinking indicator swapping out, a tool row appending) land in the
    /// same frames as the streaming text, so they follow it unanimated instead.
    public func followEvent(_ proxy: ScrollViewProxy, anchor: String) {
        isFollowing = true
        guard !isRestoring, !isStreamActive else {
            proxy.scrollTo(anchor, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(anchor, anchor: .bottom) }
    }

    /// Snaps to the end with no animation, for when the transcript is replaced wholesale —
    /// a new chat, or one restored from history. Whatever the reader had scrolled to
    /// belonged to the previous conversation, so following starts re-armed.
    ///
    /// Keeps scrolling until the transcript reports that it has arrived; callers do not
    /// have to chase the lazy rows themselves.
    public func snapToBottom(_ proxy: ScrollViewProxy, anchor: String) {
        // The incoming transcript's geometry has nothing to do with the outgoing one's.
        beginRestore()
        restoreTarget = (proxy, anchor)
        proxy.scrollTo(anchor, anchor: .bottom)

        restoreTimeout?.cancel()
        restoreTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.endRestore()
        }
    }

    /// Ends the restore window opened by ``snapToBottom(_:anchor:)`` early. Rarely needed:
    /// the restore ends itself as soon as the transcript reports it has reached the end.
    public func transcriptDidSettle() {
        endRestore()
    }

    /// Explicit jump, from the button offered when following is disengaged.
    public func jumpToBottom(_ proxy: ScrollViewProxy, anchor: String) {
        isFollowing = true
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .bottom) }
    }
}

// MARK: - Distance reporting

/// The transcript's trailing row: the target every scroll aims at, and — on systems
/// without `onScrollGeometryChange` — the thing that measures how far below the viewport
/// the end of the transcript sits.
///
/// Place it last inside the scrolling stack, and put ``chatScrollViewport(_:)`` on the
/// enclosing `ScrollView`.
public struct ChatBottomAnchor: View {

    /// The id `ScrollViewProxy` scrolls to. Pass it as the `anchor:` argument throughout.
    public static let id = "chat.bottom"

    private let controller: ChatAutoScrollController

    public init(controller: ChatAutoScrollController) {
        self.controller = controller
    }

    public var body: some View {
        Color.clear
            .frame(height: 1)
            .background {
                GeometryReader { geometry in
                    // Reporting from `onChange` rather than straight out of the
                    // GeometryReader's body keeps the write off the view-update pass,
                    // which is what otherwise trips "modifying state during update".
                    Color.clear.onChange(of: geometry.frame(in: .global).minY, initial: true) { _, y in
                        controller.reportAnchorTop(y)
                    }
                }
            }
            .id(Self.id)
    }
}

public extension View {

    /// Marks the transcript's `ScrollView` so the controller can tell "pinned to the
    /// bottom" from "the reader scrolled up to re-read something".
    func chatScrollViewport(_ controller: ChatAutoScrollController) -> some View {
        modifier(ChatScrollViewportModifier(controller: controller))
    }
}

private struct ChatScrollViewportModifier: ViewModifier {

    let controller: ChatAutoScrollController

    func body(content: Content) -> some View {
        // Anchoring the content to the bottom means growth extends downward from a
        // position the scroll view already holds, instead of being chased frame by frame.
        // From iOS 18 / macOS 15 that extends to size changes, which covers streaming
        // outright; before then it still gets the transcript to open in the right place.
        Group {
            if #available(iOS 18.0, macOS 15.0, *) {
                content
                    .defaultScrollAnchor(.bottom)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    // The scroll view's own geometry: exact, cheap, and updated during
                    // the drag rather than a layout pass behind it.
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentSize.height + geometry.contentInsets.bottom
                            - geometry.contentOffset.y - geometry.containerSize.height
                    } action: { _, distance in
                        controller.reportDistanceFromBottom(distance)
                    }
            } else {
                content
                    .defaultScrollAnchor(.bottom)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.frame(in: .global).maxY, initial: true) { _, y in
                                controller.reportViewportBottom(y)
                            }
                        }
                    }
            }
        }
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
