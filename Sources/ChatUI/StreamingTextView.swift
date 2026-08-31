//
//  StreamingTextView.swift
//  SwiftChatKit
//
//  Renders one chat message's Markdown. The whole message lives in a single text
//  view, so a drag selects across headings, prose, lists, tables and code in one
//  gesture — per-block SwiftUI views each own their own selection scope, which is
//  why selection stops at every boundary when they are used instead.
//

import SwiftUI
import ChatCore

// MARK: - Frame-rate throttle

/// Coalesces streaming deltas to one render per frame. Without it a fast model
/// turn re-parses the whole message on every token append.
final class PrecisionTimer60FPS: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.swiftchatkit.fps60timer", qos: .userInteractive)
    private var isProcessing = false

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_666), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isProcessing else { return }
            self.isProcessing = true
            DispatchQueue.main.async {
                self.callback()
                self.isProcessing = false
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isProcessing = false
    }

    deinit { stop() }
}

// MARK: - Render coordinator

@MainActor
@Observable
public final class MarkdownRenderCoordinator {

    public private(set) var segments: [MarkdownSegment] = []

    private var timer: PrecisionTimer60FPS?
    private var pendingText: String?
    private var renderedText: String?
    private var renderedStyleKey: String?
    private var currentStyle: MarkdownStyle?

    /// The last parse and the last split, each kept so the next delta can pick up where
    /// they left off rather than re-reading and re-rendering the whole message. Both
    /// verify for themselves that they still apply, so a wholly different message or a
    /// theme change simply falls back to doing the work.
    private var document: MarkdownDocument?
    private var segmentSet: MarkdownSegmentSet?
    /// Frames observed with nothing pending; the timer stops once the stream goes quiet.
    private var idleFrames = 0

    public init() {}

    /// Queues a render. Style changes (theme or appearance) bypass the throttle so the
    /// message never sits in stale colors.
    public func update(text: String, style: MarkdownStyle) {
        let styleKey = Self.key(for: style)
        if styleKey != renderedStyleKey {
            renderedStyleKey = styleKey
            renderNow(text: text, style: style)
            return
        }
        guard text != renderedText else { return }
        pendingText = text
        currentStyle = style
        if timer == nil {
            timer = PrecisionTimer60FPS { [weak self] in
                Task { @MainActor in self?.tick() }
            }
            timer?.start()
        }
    }

    private func tick() {
        guard let pending = pendingText, let style = currentStyle else {
            idleFrames += 1
            // ~1s of quiet: the turn is over, stop burning a timer per message.
            if idleFrames > 60 { stop() }
            return
        }
        idleFrames = 0
        pendingText = nil
        renderNow(text: pending, style: style)
    }

    private func renderNow(text: String, style: MarkdownStyle) {
        renderedText = text
        currentStyle = style
        let parsed = MarkdownBlockParser.parse(text, reusing: document)
        let split = MarkdownSegment.split(parsed, style: style, reusing: segmentSet)
        document = parsed
        segmentSet = split
        segments = split.segments
    }

    public func stop() {
        timer?.stop()
        timer = nil
        pendingText = nil
        idleFrames = 0
    }

    static func key(for style: MarkdownStyle) -> String {
        MarkdownStyle.key(for: style)
    }
}

// MARK: - View

public struct StreamingTextView: View {

    public let text: String

    @Environment(\.chatPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var coordinator = MarkdownRenderCoordinator()

    public init(text: String) {
        self.text = text
    }

    private var style: MarkdownStyle {
        MarkdownStyle.from(palette: palette, appearanceIsDark: colorScheme == .dark)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(coordinator.segments) { segment in
                switch segment {
                case .prose(_, let attributed):
                    MarkdownTextViewRepresentable(attributed: attributed, style: style)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                case .code(_, let language, let code):
                    MarkdownCodeBlockView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { coordinator.update(text: text, style: style) }
        .onChange(of: text) { _, newValue in coordinator.update(text: newValue, style: style) }
        .onChange(of: colorScheme) { _, _ in coordinator.update(text: text, style: style) }
        .onDisappear { coordinator.stop() }
    }
}
