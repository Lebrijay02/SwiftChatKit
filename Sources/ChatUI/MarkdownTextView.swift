//
//  MarkdownTextView.swift
//  SwiftChatKit
//
//  A non-editable text view hosting one message's rendered Markdown. Sizes itself
//  to its content so the surrounding chat ScrollView still does the scrolling.
//
//  The decorations below — code panels, block-quote bars, horizontal rules —
//  cannot be expressed as text attributes, so both platforms draw them by reading
//  the marker attributes the builder left behind.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Corner radius shared by the code panel and its Copy button chrome.
enum MarkdownDecoration {
    static let codeCornerRadius: CGFloat = 8

    /// Draws the panels, bars and rules for `storage` into the current context.
    /// Written against TextKit 1 because `NSTextTable` — which GFM tables need on
    /// macOS — has no TextKit 2 equivalent.
    static func draw(storage: NSTextStorage,
                     layoutManager: NSLayoutManager,
                     container: NSTextContainer,
                     origin: CGPoint,
                     style: MarkdownStyle) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        func box(_ range: NSRange) -> CGRect {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.codeBlockAttribute, in: full) { value, range, _ in
            guard value != nil else { return }
            let rect = box(range).insetBy(dx: -4, dy: -6)
            style.codeBackground.setFill()
            fill(roundedRect: rect, radius: codeCornerRadius)
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.quoteDepthAttribute, in: full) { value, range, _ in
            guard let depth = value as? Int else { return }
            let rect = box(range)
            style.quoteBarColor.setFill()
            for level in 0..<depth {
                let x = rect.minX + CGFloat(level) * 18 + 2
                fill(rect: CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
            }
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.thematicBreakAttribute, in: full) { value, range, _ in
            guard value != nil else { return }
            let rect = box(range)
            style.dividerColor.setFill()
            fill(rect: CGRect(x: rect.minX, y: rect.midY, width: container.size.width, height: 1))
        }

        // NSTextTable lays out its own per-cell borders, but its automatic column
        // layout doesn't reliably land the last column's edge on the container
        // boundary, so that edge is sometimes clipped or missing depending on width.
        // One rounded stroke around the table's whole range, independent of column
        // layout, always closes it — and gets rounded corners the native grid can't.
        storage.enumerateAttribute(MarkdownAttributedBuilder.tableAttribute, in: full) { value, range, _ in
            guard value != nil else { return }
            // `box` measures the glyphs alone; the table's visible edge sits outside
            // that by the cell padding (6) set in `MarkdownAttributedBuilder.table`,
            // which is reserved space the glyph bounding rect doesn't include. The
            // builder zeroes the native border on the outer edges, so this stroke is
            // the only thing drawing them — there is no border width to add here.
            let rect = box(range).insetBy(dx: -6, dy: -6)

            // The header row's background is filled here rather than by
            // `NSTextTableBlock.backgroundColor` (see the builder), whose square
            // corners poked past the rounded stroke. It takes its width from the
            // table, not from its own glyph box: `boundingRect` over a multi-line
            // range returns the union of whole line fragments, which runs to the
            // container's edge rather than the table's. Clipping to the same
            // rounded path the stroke uses keeps the top corners exact.
            if let header = headerRange(in: storage, within: range) {
                // Stops just short of the header/body divider, which is an interior
                // border the native table still draws — and this fill runs after it.
                let bottom = box(header).maxY + 6
                clipped(to: rect, radius: codeCornerRadius) {
                    style.codeBackground.setFill()
                    fill(rect: CGRect(x: rect.minX, y: rect.minY,
                                      width: rect.width, height: bottom - rect.minY))
                }
            }

            style.dividerColor.setStroke()
            stroke(roundedRect: rect, radius: codeCornerRadius, lineWidth: 1)
        }
    }

    /// The header row's range inside a table's range, if it is marked.
    private static func headerRange(in storage: NSTextStorage, within table: NSRange) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(MarkdownAttributedBuilder.tableHeaderAttribute, in: table) { value, range, stop in
            if value != nil {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Runs `body` with the current context clipped to a rounded rect.
    private static func clipped(to rect: CGRect, radius: CGFloat, _ body: () -> Void) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        body()
        NSGraphicsContext.restoreGraphicsState()
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return body() }
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        body()
        context.restoreGState()
        #endif
    }

    private static func fill(roundedRect: CGRect, radius: CGFloat) {
        #if canImport(AppKit)
        NSBezierPath(roundedRect: roundedRect, xRadius: radius, yRadius: radius).fill()
        #else
        UIBezierPath(roundedRect: roundedRect, cornerRadius: radius).fill()
        #endif
    }

    private static func fill(rect: CGRect) {
        #if canImport(AppKit)
        NSBezierPath(rect: rect).fill()
        #else
        UIBezierPath(rect: rect).fill()
        #endif
    }


    private static func stroke(roundedRect rect: CGRect, radius: CGFloat, lineWidth: CGFloat) {
        // Matches the native table border's own bounding box exactly — this draws
        // on top of it (called after `super.drawBackground`/`super.draw` below), so
        // sizing it any smaller left both edges visible as a double border instead
        // of this one fully covering the native edge that goes missing on the right.
        #if canImport(AppKit)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #else
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #endif
        path.lineWidth = lineWidth
        path.stroke()
    }
}

// MARK: - AppKit

#if canImport(AppKit)

public final class MarkdownNSTextView: NSTextView {

    var style: MarkdownStyle?

    /// TextKit 1 ownership runs storage -> layout manager -> container, and the
    /// back-references are weak. The view has to keep the top of that chain alive.
    var chatTextStorage: NSTextStorage?
    var chatLayoutManager: NSLayoutManager?

    override public func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let style, let layoutManager, let textContainer, let textStorage else { return }
        MarkdownDecoration.draw(storage: textStorage, layoutManager: layoutManager,
                                container: textContainer, origin: textContainerOrigin,
                                style: style)
    }

    // Chat text is read-only, but it still has to take focus for selection to work.
    override public var acceptsFirstResponder: Bool { true }
}

public struct MarkdownTextViewRepresentable: NSViewRepresentable {

    public let attributed: NSAttributedString
    public let style: MarkdownStyle

    public init(attributed: NSAttributedString, style: MarkdownStyle) {
        self.attributed = attributed
        self.style = style
    }

    public func makeNSView(context: Context) -> MarkdownNSTextView {
        let (storage, layoutManager, container) = makeTextKitStack()

        let textView = MarkdownNSTextView(frame: .zero, textContainer: container)
        textView.chatTextStorage = storage
        textView.chatLayoutManager = layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: style.accentColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.style = style
        return textView
    }

    public func updateNSView(_ textView: MarkdownNSTextView, context: Context) {
        textView.style = style
        if textView.textStorage?.matchesChat(attributed) != true {
            textView.textStorage?.setAttributedString(attributed)
        }
        textView.needsDisplay = true
    }

    public func sizeThatFits(_ proposal: ProposedViewSize,
                             nsView: MarkdownNSTextView,
                             context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: measuredHeight(of: attributed, width: width))
    }
}

#endif

// MARK: - UIKit

#if canImport(UIKit) && !canImport(AppKit)

public final class MarkdownUITextView: UITextView {

    var style: MarkdownStyle?

    /// TextKit 1 ownership runs storage -> layout manager -> container, and the
    /// back-references are weak. The view has to keep the top of that chain alive.
    var chatTextStorage: NSTextStorage?
    var chatLayoutManager: NSLayoutManager?

    override public func draw(_ rect: CGRect) {
        guard let style, let container = textContainer as NSTextContainer? else {
            super.draw(rect)
            return
        }
        // Decorations go under the glyphs, so they are drawn before `super`.
        MarkdownDecoration.draw(storage: textStorage, layoutManager: layoutManager,
                                container: container,
                                origin: CGPoint(x: textContainerInset.left,
                                                y: textContainerInset.top),
                                style: style)
        super.draw(rect)
    }
}

public struct MarkdownTextViewRepresentable: UIViewRepresentable {

    public let attributed: NSAttributedString
    public let style: MarkdownStyle

    public init(attributed: NSAttributedString, style: MarkdownStyle) {
        self.attributed = attributed
        self.style = style
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let (storage, layoutManager, container) = makeTextKitStack()

        let textView = MarkdownUITextView(frame: .zero, textContainer: container)
        textView.chatTextStorage = storage
        textView.chatLayoutManager = layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false     // the transcript scrolls, not the message
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.linkTextAttributes = [.foregroundColor: style.accentColor]
        textView.style = style
        return textView
    }

    public func updateUIView(_ textView: MarkdownUITextView, context: Context) {
        textView.style = style
        if !textView.textStorage.matchesChat(attributed) {
            textView.textStorage.setAttributedString(attributed)
        }
        textView.setNeedsDisplay()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize,
                             uiView: MarkdownUITextView,
                             context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: measuredHeight(of: attributed, width: width))
    }
}

#endif

// MARK: - Shared plumbing

/// An explicit TextKit 1 stack. Both the decoration drawing above and macOS table
/// layout need a layout manager, which the default TextKit 2 stack does not vend.
func makeTextKitStack() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    return (storage, layoutManager, container)
}

/// Measures with a disposable TextKit stack rather than the live view's own container.
/// The live container tracks the view's actual bounds on its own (`widthTracksTextView`);
/// mutating it here too, to test a candidate width mid-layout, raced that auto-tracking
/// during a continuous resize — SwiftUI's speculative width and AppKit's committed one
/// fought over the same object, and the message bounced between the two from frame to
/// frame. A scratch stack settles that: this call can never be seen by the live view.
func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)

    layoutManager.ensureLayout(for: container)
    return ceil(layoutManager.usedRect(for: container).height)
}

extension NSTextStorage {
    /// Named to avoid colliding with NSAttributedString's own `isEqual(to:)`.
    func matchesChat(_ other: NSAttributedString) -> Bool {
        length == other.length && string == other.string
    }
}
