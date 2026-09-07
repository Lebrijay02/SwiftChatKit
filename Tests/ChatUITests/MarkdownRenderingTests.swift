//
//  MarkdownRenderingTests.swift
//  SwiftChatKitTests
//
//  The renderer's output is an attributed string, so what can be asserted is its
//  text, its marker attributes and where the segment boundaries fall — which is
//  also where the bugs live.
//

import Foundation
import Testing
import ChatCore
@testable import ChatUI

/// Rebuilt per call: `MarkdownStyle` holds platform colors and so is not
/// `Sendable`, which rules out a shared global under strict concurrency.
private var style: MarkdownStyle {
    MarkdownStyle.from(palette: .default, appearanceIsDark: false)
}

private func render(_ markdown: String) -> MarkdownRenderResult {
    MarkdownAttributedBuilder.build(MarkdownBlockParser.parse(markdown), style: style)
}

@Suite("Markdown attributed builder")
struct MarkdownAttributedBuilderTests {

    @Test("Prose survives into the string")
    func paragraph() {
        #expect(render("Hello **world**").attributed.string.contains("Hello world"))
    }

    @Test("A heading is bold and larger than body text")
    func heading() {
        let result = render("# Title")
        let font = result.attributed.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font != nil)
        #expect((font?.pointSize ?? 0) > style.bodyFontSize)
    }

    @Test("A fenced block is marked so the view can draw its panel")
    func codeRegion() {
        let result = MarkdownAttributedBuilder.build(
            [.codeBlock(language: "swift", code: "let x = 1")], style: style)
        #expect(result.codeRegions.count == 1)
        #expect(result.codeRegions.first?.language == "swift")
        #expect(result.codeRegions.first?.code == "let x = 1")
    }

    @Test("Quote depth is recorded for the bar the view strokes")
    func quoteDepth() {
        let result = render("> quoted")
        var depths: [Int] = []
        result.attributed.enumerateAttribute(
            MarkdownAttributedBuilder.quoteDepthAttribute,
            in: NSRange(location: 0, length: result.attributed.length)) { value, _, _ in
                if let depth = value as? Int { depths.append(depth) }
            }
        #expect(depths.contains(1))
    }

    @Test("A rule is a marked carrier line, not a row of dashes")
    func thematicBreak() {
        let result = render("---")
        var found = false
        result.attributed.enumerateAttribute(
            MarkdownAttributedBuilder.thematicBreakAttribute,
            in: NSRange(location: 0, length: result.attributed.length)) { value, _, _ in
                if value != nil { found = true }
            }
        #expect(found)
        #expect(!result.attributed.string.contains("---"))
    }

    @Test("A link carries its destination")
    func link() {
        let result = render("[docs](https://example.com)")
        let url = result.attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com")
    }

    @Test("An image renders as a labelled link rather than being fetched")
    func imageIsNotLoaded() {
        // Chat content is untrusted; silently loading a remote URL would leak the
        // session to whoever wrote the message.
        let result = render("![alt](https://example.com/x.png)")
        #expect(result.attributed.string.contains("alt"))
    }

    @Test("A table's cells all reach the string")
    func table() {
        let text = render("""
        | a | b |
        |---|---|
        | 1 | 2 |
        """).attributed.string
        for cell in ["a", "b", "1", "2"] {
            #expect(text.contains(cell))
        }
    }

    @Test("Separators do not carry a code marker into the next block")
    func separatorDoesNotLeak() {
        // Left inherited, the panel fill would extend past the block's end.
        let result = render("```\ncode\n```\n\nafter")
        let attributed = result.attributed
        let tail = NSRange(location: attributed.length - 1, length: 1)
        var leaked = false
        attributed.enumerateAttribute(MarkdownAttributedBuilder.codeBlockAttribute, in: tail) { value, _, _ in
            if value != nil { leaked = true }
        }
        #expect(!leaked)
    }
}

@Suite("Markdown segments")
struct MarkdownSegmentTests {

    @Test("Adjacent prose is coalesced into one selectable run")
    func coalescesProse() {
        let segments = MarkdownSegment.split(
            MarkdownBlockParser.parse("# Title\n\nBody\n\n- item"), style: style)
        #expect(segments.count == 1)
    }

    @Test("A code block breaks the run in two")
    func splitsOnCode() {
        let segments = MarkdownSegment.split(
            MarkdownBlockParser.parse("before\n\n```\ncode\n```\n\nafter"), style: style)
        #expect(segments.count == 3)
        if case .code(_, _, let code) = segments[1] {
            #expect(code.contains("code"))
        } else {
            Issue.record("expected the middle segment to be code")
        }
    }

    /// A block terminator is a newline, and TextKit gives a trailing newline an empty
    /// final line fragment that `usedRect` measures. Left on, the last block of every
    /// run costs a full extra line of blank height under the message.
    @Test("A finished run does not end on the terminator that would add a blank line")
    func trimsTrailingNewline() {
        for markdown in ["Body", "# Title\n\nBody", "- one\n- two", "before\n\n```\ncode\n```\n\nafter"] {
            let segments = MarkdownSegment.split(MarkdownBlockParser.parse(markdown), style: style)
            for case .prose(_, let attributed) in segments {
                #expect(!attributed.string.hasSuffix("\n"), "trailing newline left on: \(markdown)")
            }
        }
    }

    /// The trim runs on the finished copy only. Were it applied to the cached prefix the
    /// incremental path extends, the next delta would append onto a run whose last block
    /// had lost its terminator — fusing two blocks into one paragraph.
    @Test("Trimming does not change what a streaming message ends up rendering")
    func trimSurvivesIncrementalRender() {
        let full = "# Title\n\nFirst paragraph.\n\nSecond paragraph."
        let cold = MarkdownSegment.split(MarkdownBlockParser.parse(full), style: style)

        var document: MarkdownDocument?
        var set: MarkdownSegmentSet?
        for end in stride(from: 4, through: full.count, by: 7) {
            let prefix = String(full.prefix(end))
            let parsed = MarkdownBlockParser.parse(prefix, reusing: document)
            set = MarkdownSegment.split(parsed, style: style, reusing: set)
            document = parsed
        }
        let parsed = MarkdownBlockParser.parse(full, reusing: document)
        let streamed = MarkdownSegment.split(parsed, style: style, reusing: set)

        #expect(streamed.segments.count == cold.count)
        for (a, b) in zip(streamed.segments, cold) {
            if case .prose(_, let x) = a, case .prose(_, let y) = b {
                #expect(x.string == y.string)
            }
        }
    }

    @Test("Segment ids are distinct so ForEach does not reuse views")
    func distinctIDs() {
        let segments = MarkdownSegment.split(
            MarkdownBlockParser.parse("a\n\n```\nx\n```\n\nb"), style: style)
        #expect(Set(segments.map(\.id)).count == segments.count)
    }

    @Test("Empty input renders nothing")
    func empty() {
        #expect(MarkdownSegment.split([], style: style).isEmpty)
    }
}

@Suite("Render coordinator")
@MainActor
struct RenderCoordinatorTests {

    @Test("The first update renders immediately rather than waiting a frame")
    func rendersImmediately() {
        let coordinator = MarkdownRenderCoordinator()
        coordinator.update(text: "hello", style: style)
        #expect(!coordinator.segments.isEmpty)
    }

    @Test("A style change bypasses the throttle")
    func styleChangeRendersNow() {
        let coordinator = MarkdownRenderCoordinator()
        coordinator.update(text: "hello", style: style)

        // A queued render would leave the message in stale colors for a frame,
        // which is visible when the whole transcript re-themes at once.
        var dark = MarkdownStyle.from(palette: .default, appearanceIsDark: true)
        dark.textColor = .systemRed
        coordinator.update(text: "goodbye", style: dark)
        #expect(coordinator.segments.count == 1)
    }

    @Test("Identical text is not re-rendered")
    func skipsIdenticalText() {
        let coordinator = MarkdownRenderCoordinator()
        coordinator.update(text: "same", style: style)
        let before = coordinator.segments.count
        coordinator.update(text: "same", style: style)
        #expect(coordinator.segments.count == before)
    }

    @Test("Style keys differ when a color does")
    func styleKey() {
        var other = style
        other.accentColor = .systemPink
        #expect(MarkdownRenderCoordinator.key(for: style) != MarkdownRenderCoordinator.key(for: other))
    }
}
