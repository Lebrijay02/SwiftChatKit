//
//  MarkdownCodeBlockView.swift
//  SwiftChatKit
//
//  A code block with a header and horizontal scrolling.
//
//  This is the one place the unified-text-view approach is deliberately broken. Code
//  cannot both scroll sideways and live in the message's single text storage: TextKit
//  gives one container one width, so a non-wrapping paragraph either clips or forces the
//  whole message to scroll. Scrolling wins here because wrapped code misleads — a wrapped
//  line looks like a new statement, and indentation stops meaning anything.
//
//  The cost is that a drag-selection stops at a code block's edge. Prose on either side
//  still selects continuously within its own run.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct MarkdownCodeBlockView: View {

    public let language: String?
    public let code: String

    @Environment(\.chatPalette) private var palette
    @State private var isExpanded = false
    @State private var contentSize: CGSize = .zero

    /// Rendered height of one line, used to cap a collapsed block.
    @State private var lineHeight: CGFloat = 17

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
        // Half a line past the cut-off, so the fade has a genuinely partial line to act
        // on. Stopping exactly on a line boundary would just dim a complete line and
        // leave no hint that more follows.
        return min(full, lineHeight * (CGFloat(MarkdownAttributedBuilder.collapsedCodeLines) + 0.5))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().frame(height: 0.5).overlay(palette.divider)
            CodeScrollView(
                code: code,
                fontSize: PlatformFont.chatBodySize * 0.95,
                textColor: PlatformColor.from(chat: palette.primaryText),
                onMeasure: { size, line in
                    contentSize = size
                    lineHeight = line
                }
            )
            .frame(height: max(visibleHeight, lineHeight) + 16)
            .clipped()
            .overlay(alignment: .bottom) {
                // Collapsing cuts the last visible line mid-glyph, which reads as a
                // rendering fault. Fading it into the panel says "there is more" instead.
                if isCollapsed {
                    LinearGradient(
                        colors: [palette.codeBackground.opacity(0), palette.codeBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: lineHeight * 1.6)
                    // The fade is decoration; clicks and drags belong to the code under it.
                    .allowsHitTesting(false)
                }
            }
        }
        .background(palette.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.divider, lineWidth: 0.5))
        .padding(.vertical, 4)
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

            CodeCopyButton(code: code)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
        .background(palette.header)
    }
}

// MARK: - Copy

private struct CodeCopyButton: View {

    let code: String

    @Environment(\.chatPalette) private var palette
    @State private var isCopied = false

    var body: some View {
        Button {
            copy(code)
            isCopied = true
            // Copy always takes the whole block, collapsed or not.
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

/// A non-wrapping, horizontally scrollable text view. Selectable within itself.
private struct CodeScrollView {
    let code: String
    let fontSize: CGFloat
    let textColor: PlatformColor
    let onMeasure: (CGSize, CGFloat) -> Void

    /// TextKit 1 ownership runs storage -> layout manager -> container, and the
    /// back-references are weak. The text view here is a stock one with nowhere to
    /// hang the stack, so the coordinator holds it for the lifetime of the view.
    final class TextKitStack {
        var storage: NSTextStorage?
        var layoutManager: NSLayoutManager?
    }

    func makeCoordinator() -> TextKitStack { TextKitStack() }

    /// The attributed form and its measured size. Shared so both platform bridges
    /// lay the code out identically.
    func attributed() -> (NSAttributedString, NSParagraphStyle) {
        let font = PlatformFont.chatMono(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        // The whole point of this view: never wrap.
        paragraph.lineBreakMode = .byClipping

        return (NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]), paragraph)
    }

    /// An "unbounded" container. `greatestFiniteMagnitude` overflows TextKit's own
    /// arithmetic on UIKit and lays out nothing past the first fragment, so the bound is
    /// large but finite — no code block is a million points wide.
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
        // UIKit's layout manager has no `defaultLineHeight`; the font's own metrics
        // are what it would compute anyway.
        let lineHeight = font.lineHeight
        #endif
        return (size, lineHeight + paragraph.lineSpacing)
    }
}

#if canImport(AppKit)

extension CodeScrollView: NSViewRepresentable {

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        // Vertical scrolling belongs to the transcript; the block sizes itself instead.
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
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainerInset = NSSize(width: 12, height: 8)

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

        let (size, line) = measure(layoutManager: layoutManager, container: container,
                                   paragraph: paragraph)
        textView.minSize = size
        textView.frame = NSRect(origin: .zero,
                                size: CGSize(width: size.width + 24, height: size.height + 16))

        let report = onMeasure
        Task { @MainActor in report(size, line) }
    }
}

#else

extension CodeScrollView: UIViewRepresentable {

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
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        scrollView.addSubview(textView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = scrollView.subviews.compactMap({ $0 as? UITextView }).first,
              let container = textView.textContainer as NSTextContainer?
        else { return }
        let layoutManager = textView.layoutManager

        // A non-scrolling UITextView clamps its container to its own bounds on every
        // layout pass. The frame starts at zero, so without restoring the container the
        // measurement below only ever sees the first line.
        container.size = Self.unbounded

        let (string, paragraph) = attributed()
        if !textView.textStorage.matchesChat(string) {
            textView.textStorage.setAttributedString(string)
        }

        let (size, line) = measure(layoutManager: layoutManager, container: container,
                                   paragraph: paragraph)
        let frame = CGRect(origin: .zero,
                           size: CGSize(width: size.width + 24, height: size.height + 16))
        textView.frame = frame
        scrollView.contentSize = frame.size

        let report = onMeasure
        Task { @MainActor in report(size, line) }
    }
}

#endif
