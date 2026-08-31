//
//  MarkdownIncrementalParseTests.swift
//  SwiftChatKitTests
//
//  Resuming a parse near the end of a streaming message is only worth doing if it is
//  invisible. These replay real messages the way a turn delivers them — a character at a
//  time — and demand the resumed parse match a parse from scratch at every single step.
//  Anything less and a message would render differently depending on how it arrived.
//

import Testing
@testable import ChatCore

@Suite("Markdown incremental parsing")
struct MarkdownIncrementalParseTests {

    /// Streams `source` one character at a time, reusing each step's document, and checks
    /// every intermediate state against a cold parse of the same prefix.
    private func replay(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var document: MarkdownDocument?
        var text = ""

        for character in source {
            text.append(character)
            let incremental = MarkdownBlockParser.parse(text, reusing: document)
            let cold = MarkdownBlockParser.parse(text)
            #expect(incremental.blocks == cold,
                    "diverged at \(text.count) characters", sourceLocation: sourceLocation)
            document = incremental
        }
    }

    @Test("Prose, headings and a list")
    func prose() {
        replay("""
        # Title

        A paragraph that runs on for a while.

        ## Section

        - one
        - two
        - three

        A closing paragraph.
        """)
    }

    @Test("A fenced code block, including while the fence is still open")
    func fencedCode() {
        replay("""
        Here is some code:

        ```swift
        let x = 1

        let y = 2
        ```

        And after it.
        """)
    }

    @Test("A table gaining rows one at a time")
    func table() {
        replay("""
        | a | b |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |

        After the table.
        """)
    }

    @Test("Constructs that read ahead into the block after them")
    func lookahead() {
        // Definition lists decide on the *next* line, tables on their delimiter row, and
        // a setext underline retroactively turns a paragraph into a heading. Each one can
        // rewrite a block the parser had already moved past.
        replay("""
        Term
        : definition

        Another term
        : its definition

        Underlined heading
        ===

        | x | y |
        |---|---|
        | 1 | 2 |
        """)
    }

    @Test("Block quotes, math, rules and footnotes")
    func mixed() {
        replay("""
        > quoted text
        > more of it

        $$
        a + b = c
        $$

        ---

        [^1]: a footnote

        Trailing paragraph.
        """)
    }

    @Test("A reused document is discarded when the text is not an append")
    func editFallsBackToFullParse() {
        let first = MarkdownBlockParser.parse("# One\n\nTwo\n\nThree\n\nFour", reusing: nil)
        #expect(first.stableBlockCount > 0, "there should be something to reuse")

        // Not a prefix of the previous text: the whole thing has to be re-read.
        let replaced = MarkdownBlockParser.parse("# Different\n\nEntirely\n\nNew", reusing: first)
        #expect(replaced.blocks == MarkdownBlockParser.parse("# Different\n\nEntirely\n\nNew"))
    }

    @Test("Switching messages mid-stream never reuses the wrong document")
    func crossMessageReuse() {
        var document = MarkdownBlockParser.parse("# A\n\nfirst message body\n\nwith blocks", reusing: nil)
        // A shorter, unrelated message arriving against the previous one's document.
        document = MarkdownBlockParser.parse("short", reusing: document)
        #expect(document.blocks == MarkdownBlockParser.parse("short"))
    }

    @Test("Long messages actually resume rather than re-reading everything")
    func resumesNearTheEnd() {
        let body = (1...200).map { "Paragraph number \($0) with some words in it." }
            .joined(separator: "\n\n")
        let document = MarkdownBlockParser.parse(body, reusing: nil)

        #expect(document.stableBlockCount == document.blocks.count - 2)
        // The retained prefix is nearly the whole message, so an append re-reads a
        // couple of blocks rather than two hundred.
        #expect(document.resumeLine > 0)
        #expect(Double(document.retainedPrefix.count) > Double(body.count) * 0.9)
    }
}
