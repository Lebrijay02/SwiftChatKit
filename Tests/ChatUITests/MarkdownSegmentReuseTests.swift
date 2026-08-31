//
//  MarkdownSegmentReuseTests.swift
//  SwiftChatKitTests
//
//  The rendering half of incremental streaming. Reuse is only allowed to change how much
//  work a delta costs, so these stream messages in and demand the reused split match a
//  cold split exactly — same segment structure, same attributed text, character for
//  character and attribute for attribute.
//

import Testing
import Foundation
@testable import ChatCore
@testable import ChatUI

@Suite("Markdown segment reuse")
@MainActor
struct MarkdownSegmentReuseTests {

    private var style: MarkdownStyle {
        MarkdownStyle.from(palette: .default, appearanceIsDark: true)
    }

    /// Compares two renderings by their full text-and-attributes description, with object
    /// addresses masked out.
    ///
    /// `NSAttributedString ==` is unusable here: a table's attributes hold
    /// `NSTextTableBlock` objects, which compare by identity, so two renderings of the
    /// same table are never equal — not even two cold ones. Descriptions carry the same
    /// information without that trap, once the pointers in them are normalised away.
    private func renderingsMatch(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        func normalised(_ string: NSAttributedString) -> String {
            // Two identical renders still describe themselves differently: pointers
            // appear in font descriptions, and a dynamic colour resolved twice carries
            // a fresh UUID each time. Neither says anything about the text.
            var text = string.description
            for pattern in ["0x[0-9a-f]+",
                            "[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}"] {
                text = text.replacingOccurrences(of: pattern,
                                                 with: "#",
                                                 options: .regularExpression)
            }
            return text
        }
        return normalised(a) == normalised(b)
    }

    /// Streams `source` a line at a time and compares each step against a cold render.
    @discardableResult
    private func replay(_ source: String,
                        sourceLocation: SourceLocation = #_sourceLocation) -> MarkdownSegmentSet? {
        var document: MarkdownDocument?
        var set: MarkdownSegmentSet?
        var text = ""

        for line in source.components(separatedBy: "\n") {
            text += text.isEmpty ? line : "\n" + line

            let parsed = MarkdownBlockParser.parse(text, reusing: document)
            let incremental = MarkdownSegment.split(parsed, style: style, reusing: set)
            let cold = MarkdownSegment.split(MarkdownBlockParser.parse(text), style: style)

            #expect(incremental.segments.count == cold.count,
                    "segment count diverged at \(text.count) characters",
                    sourceLocation: sourceLocation)

            for (a, b) in zip(incremental.segments, cold) {
                switch (a, b) {
                case (.prose(let ia, let aa), .prose(let ib, let ab)):
                    #expect(ia == ib, sourceLocation: sourceLocation)
                    #expect(renderingsMatch(aa, ab),
                            "rendered text diverged at \(text.count) characters",
                            sourceLocation: sourceLocation)
                case (.code(let ia, let la, let ca), .code(let ib, let lb, let cb)):
                    #expect(ia == ib, sourceLocation: sourceLocation)
                    #expect(la == lb, sourceLocation: sourceLocation)
                    #expect(ca == cb, sourceLocation: sourceLocation)
                default:
                    Issue.record("segment kinds diverged at \(text.count) characters",
                                 sourceLocation: sourceLocation)
                }
            }

            document = parsed
            set = incremental
        }
        return set
    }

    @Test("Prose only, where the whole message is one segment")
    func proseOnly() {
        replay("""
        # Title

        First paragraph with **bold** and `code` in it.

        Second paragraph.

        - a list
        - with items

        Third paragraph, closing things out.
        """)
    }

    @Test("Prose interleaved with code blocks")
    func withCodeBlocks() {
        replay("""
        Some prose first.

        ```swift
        let a = 1
        ```

        More prose in between.

        ```python
        b = 2
        ```

        And a closing paragraph.
        """)
    }

    @Test("Tables and quotes, which render through the heavier paths")
    func richBlocks() {
        replay("""
        > a quote

        | a | b |
        |---|---|
        | 1 | 2 |

        Closing prose.
        """)
    }

    @Test("A theme change rebuilds rather than reusing text in the old colours")
    func styleChangeInvalidates() {
        let text = "# Title\n\nSome prose.\n\nMore prose.\n\nEven more."
        let document = MarkdownBlockParser.parse(text, reusing: nil)
        let dark = MarkdownSegment.split(document, style: MarkdownStyle.from(palette: .default,
                                                                            appearanceIsDark: true),
                                         reusing: nil)

        let lightStyle = MarkdownStyle.from(palette: .default, appearanceIsDark: false)
        let light = MarkdownSegment.split(document, style: lightStyle, reusing: dark)
        let cold = MarkdownSegment.split(document.blocks, style: lightStyle)

        for (a, b) in zip(light.segments, cold) {
            guard case .prose(_, let aa) = a, case .prose(_, let ab) = b else { continue }
            #expect(renderingsMatch(aa, ab), "a reused segment kept the previous theme's attributes")
        }
    }

    @Test("Settled prose is handed back as the same object, not an equal one")
    func reusedSegmentsKeepIdentity() {
        // Identity is what lets the text views skip re-applying and re-measuring, so it
        // is the property worth pinning down — equality alone would not buy anything.
        let head = "Intro paragraph.\n\n```swift\nlet x = 1\n```\n\n"
        let document = MarkdownBlockParser.parse(head + "Tail paragraph.", reusing: nil)
        let first = MarkdownSegment.split(document, style: style, reusing: nil)

        let grown = MarkdownBlockParser.parse(head + "Tail paragraph, now longer.\n\nAnd another.",
                                              reusing: document)
        let second = MarkdownSegment.split(grown, style: style, reusing: first)

        guard case .prose(_, let before) = first.segments[0],
              case .prose(_, let after) = second.segments[0] else {
            Issue.record("expected the message to open with prose"); return
        }
        #expect(before === after, "the settled opening paragraph was rebuilt")
    }

    @Test("A different message rendered through the same views reuses nothing")
    func recycledViewRendersTheNewMessage() {
        // A row scrolled out of a LazyVStack and back in comes back holding a different
        // message. The parse starts over, and the split has to notice: the previous
        // segments describe blocks that no longer exist, at indices the new message
        // happens to have too.
        let first = "Alpha paragraph.\n\n```swift\nlet x = 1\n```\n\nOmega paragraph."
        let firstDocument = MarkdownBlockParser.parse(first, reusing: nil)
        let firstSet = MarkdownSegment.split(firstDocument, style: style, reusing: nil)

        let second = "Totally different.\n\n```swift\nlet y = 2\n```\n\nAlso different."
        let secondDocument = MarkdownBlockParser.parse(second, reusing: firstDocument)
        let reused = MarkdownSegment.split(secondDocument, style: style, reusing: firstSet)
        let cold = MarkdownSegment.split(MarkdownBlockParser.parse(second), style: style)

        #expect(secondDocument.reusedBlockCount == 0, "nothing should have carried over")
        #expect(reused.segments.count == cold.count)
        for (a, b) in zip(reused.segments, cold) {
            guard case .prose(_, let aa) = a, case .prose(_, let ab) = b else { continue }
            #expect(renderingsMatch(aa, ab), "a segment from the previous message survived")
        }
    }
}
