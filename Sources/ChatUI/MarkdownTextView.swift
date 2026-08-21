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
        guard let width = proposal.width, width.isFinite, width > 0,
              let layoutManager = nsView.layoutManager,
              let container = nsView.textContainer
        else { return nil }
        return CGSize(width: width,
                      height: measuredHeight(width: width,
                                             layoutManager: layoutManager,
                                             container: container))
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
        guard let width = proposal.width, width.isFinite, width > 0,
              let layoutManager = uiView.layoutManager as NSLayoutManager?,
              let container = uiView.textContainer as NSTextContainer?
        else { return nil }
        return CGSize(width: width,
                      height: measuredHeight(width: width,
                                             layoutManager: layoutManager,
                                             container: container))
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

func measuredHeight(width: CGFloat,
                    layoutManager: NSLayoutManager,
                    container: NSTextContainer) -> CGFloat {
    container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: container)
    return ceil(layoutManager.usedRect(for: container).height)
}

extension NSTextStorage {
    /// Named to avoid colliding with NSAttributedString's own `isEqual(to:)`.
    func matchesChat(_ other: NSAttributedString) -> Bool {
        length == other.length && string == other.string
    }
}
