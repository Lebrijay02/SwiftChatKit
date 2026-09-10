//
//  MarkdownCodeBlockViewHighlighted.swift
//  SwiftChatKit
//
//  A duplicate of MarkdownCodeBlockView with Swift syntax highlighting wired into the
//  attributed-string builder, kept as a separate type so the two can be swapped at a
//  call site and A/B'd for rendering cost — see SwiftSyntaxHighlighter for the regex
//  passes and where the color choices come from. Once a highlighter is picked for
//  keeping, this should replace MarkdownCodeBlockView rather than live alongside it.
//
//  Everything below is identical to MarkdownCodeBlockView except CodeScrollView's
//  `attributed()`, which now branches on `language`.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct MarkdownCodeBlockViewHighlighted: View {

    public let language: String?
    public let code: String

    @Environment(\.chatPalette) private var palette
    @State private var isExpanded = false
    @State private var contentSize: CGSize = .zero

    /// Rendered height of one line, used to cap a collapsed block.
    @State private var lineHeight: CGFloat = 17

    static let verticalInset: CGFloat = 10
    static let outerSpacing: CGFloat = 8

    public init(language: String?, code: String) {
        self.language = language
        self.code = code
    }

    private var lineCount: Int { code.components(separatedBy: "\n").count }
    private var isExpandable: Bool { lineCount > MarkdownAttributedBuilder.collapsedCodeLines }
    private var isCollapsed: Bool { isExpandable && !isExpanded }

    private var visibleHeight: CGFloat {
        let full = max(contentSize.height, lineHeight)
        guard isCollapsed else { return full }
        return min(full, lineHeight * (CGFloat(MarkdownAttributedBuilder.collapsedCodeLines) + 0.5))
    }

    private var frameHeight: CGFloat { max(visibleHeight, lineHeight) + Self.verticalInset * 2 }

    private var fontSize: CGFloat { PlatformFont.chatBodySize * 0.95 }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().frame(height: 0.5).overlay(palette.divider)
            HighlightedCodeScrollView(
                code: code,
                language: language,
                fontSize: fontSize,
                textColor: PlatformColor.from(chat: palette.primaryText),
                maxHeight: frameHeight
            )
            .frame(height: frameHeight)
            .clipped()
            .overlay(alignment: .bottom) {
                if isCollapsed {
                    LinearGradient(
                        colors: [palette.codeBackground.opacity(0), palette.codeBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: lineHeight * 1.6)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(palette.codeBackground)
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.divider, lineWidth: 0.5))
        .padding(.vertical, Self.outerSpacing)
        .onAppear { measure() }
        .onChange(of: code) { _, _ in measure() }
    }

    private func measure() {
        (contentSize, lineHeight) = HighlightedCodeScrollView.measure(code: code, language: language, fontSize: fontSize)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text((language?.isEmpty == false ? language! : "code").uppercased())
                .font(.caption2.weight(.medium))
                .foregroundColor(palette.secondaryText)

            Spacer(minLength: 4)

            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        Text(isCollapsed ? "Expand \(lineCount) lines" : "Collapse")
                    }
                    .font(.caption2)
                    .foregroundColor(palette.secondaryText)
                }
                .buttonStyle(.plain)
            }

            HighlightedCodeCopyButton(code: code)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(palette.header)
    }
}

// MARK: - Copy

private struct HighlightedCodeCopyButton: View {

    let code: String

    @Environment(\.chatPalette) private var palette
    @State private var isCopied = false

    var body: some View {
        Button {
            copy(code)
            isCopied = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                isCopied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                Text(isCopied ? "Copied" : "Copy")
            }
            .font(.caption2)
            .foregroundColor(palette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.primaryText.opacity(0.1))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Scrolling text

/// Same as `CodeScrollView`, plus `language` so `attributed()` knows whether to run
/// `SwiftSyntaxHighlighter` or fall back to a single flat color.
private struct HighlightedCodeScrollView {
    let code: String
    let language: String?
    let fontSize: CGFloat
    let textColor: PlatformColor
    let maxHeight: CGFloat

    final class TextKitStack {
        var storage: NSTextStorage?
        var layoutManager: NSLayoutManager?
    }

    func makeCoordinator() -> TextKitStack { TextKitStack() }

    /// The attributed form and its measured size. Highlighting only applies when
    /// `language` names Swift (case-insensitive); anything else — including a missing
    /// language, which is the common case in a chat transcript — gets the same flat
    /// color `CodeScrollView` always used, so this stays a fair performance baseline
    /// against it rather than a strictly heavier version.
    func attributed() -> (NSAttributedString, NSParagraphStyle) {
        let font = PlatformFont.chatMono(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byClipping

        let isSwift = (language ?? "").caseInsensitiveCompare("swift") == .orderedSame
        let base = isSwift
            ? SwiftSyntaxHighlighter.highlight(code, font: font, baseColor: textColor)
            : NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: textColor])

        let string = NSMutableAttributedString(attributedString: base)
        string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        return (string, paragraph)
    }

    static let unbounded = CGSize(width: 1_000_000, height: 1_000_000)

    func measure(layoutManager: NSLayoutManager,
                 container: NSTextContainer,
                 paragraph: NSParagraphStyle) -> (CGSize, CGFloat) {
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let size = CGSize(width: ceil(used.width), height: ceil(used.height))
        let font = PlatformFont.chatMono(size: fontSize)
        #if canImport(AppKit)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        #else
        let lineHeight = font.lineHeight
        #endif
        return (size, lineHeight + paragraph.lineSpacing)
    }

    static func measure(code: String, language: String?, fontSize: CGFloat) -> (size: CGSize, lineHeight: CGFloat) {
        let view = HighlightedCodeScrollView(code: code, language: language, fontSize: fontSize,
                                             textColor: .clear, maxHeight: 0)
        let (string, paragraph) = view.attributed()

        let storage = NSTextStorage(attributedString: string)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: unbounded)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let (size, lineHeight) = view.measure(layoutManager: layoutManager, container: container,
                                              paragraph: paragraph)
        return (size, lineHeight)
    }
}

#if canImport(AppKit)

private final class HighlightedHorizontalOnlyScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

private final class HighlightedTopPinnedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.y = 0
        return rect
    }
}

extension HighlightedCodeScrollView: NSViewRepresentable {

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = HighlightedHorizontalOnlyScrollView()
        scrollView.contentView = HighlightedTopPinnedClipView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let container = NSTextContainer(size: Self.unbounded)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        context.coordinator.storage = storage
        context.coordinator.layoutManager = layoutManager

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 12, height: MarkdownCodeBlockViewHighlighted.verticalInset)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let (string, paragraph) = attributed()
        if textView.textStorage?.matchesChat(string) != true {
            textView.textStorage?.setAttributedString(string)
        }

        let (size, _) = measure(layoutManager: layoutManager, container: container,
                                paragraph: paragraph)
        let inset = MarkdownCodeBlockViewHighlighted.verticalInset * 2
        let height = min(size.height + inset, maxHeight)
        textView.minSize = CGSize(width: size.width, height: max(height - inset, 0))
        textView.maxSize = CGSize(width: Self.unbounded.width, height: height)
        textView.frame = NSRect(origin: .zero,
                                size: CGSize(width: size.width + 24, height: height))
    }
}

#else

extension HighlightedCodeScrollView: UIViewRepresentable {

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear

        let container = NSTextContainer(size: Self.unbounded)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        context.coordinator.storage = storage
        context.coordinator.layoutManager = layoutManager

        let textView = UITextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        let inset = MarkdownCodeBlockViewHighlighted.verticalInset
        textView.textContainerInset = UIEdgeInsets(top: inset, left: 12, bottom: inset, right: 12)

        scrollView.addSubview(textView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = scrollView.subviews.compactMap({ $0 as? UITextView }).first,
              let container = textView.textContainer as NSTextContainer?
        else { return }
        let layoutManager = textView.layoutManager

        container.size = Self.unbounded

        let (string, paragraph) = attributed()
        if !textView.textStorage.matchesChat(string) {
            textView.textStorage.setAttributedString(string)
        }

        let (size, _) = measure(layoutManager: layoutManager, container: container,
                                paragraph: paragraph)
        let frame = CGRect(origin: .zero,
                           size: CGSize(width: size.width + 24,
                                        height: min(size.height + MarkdownCodeBlockViewHighlighted.verticalInset * 2, maxHeight)))
        textView.frame = frame
        scrollView.contentSize = frame.size
    }
}

#endif
