//
//  MarkdownParserTests.swift
//  SwiftChatKitTests
//
//  Ported verbatim from FridaGPT. Covers the Markdown Guide cheat sheet, construct by construct, plus the
//  partial-input cases the streaming renderer hits mid-turn.
//

import Testing
@testable import ChatCore

@Suite("Markdown block parsing")
struct MarkdownBlockParserTests {

    @Test("ATX headings h1 through h6")
    func headings() {
        for level in 1...6 {
            let source = String(repeating: "#", count: level) + " Heading"
            let blocks = MarkdownBlockParser.parse(source)
            #expect(blocks.count == 1)
            guard case .heading(let parsed, let content, _) = blocks[0] else {
                Issue.record("expected heading, got \(blocks[0])"); return
            }
            #expect(parsed == level)
            #expect(content == [.text("Heading")])
        }
    }

    @Test("#### is an h4, not an h3 carrying a stray hash")
    func deepHeadingRegression() {
        guard case .heading(let level, let content, _) = MarkdownBlockParser.parse("#### Four")[0] else {
            Issue.record("expected heading"); return
        }
        #expect(level == 4)
        #expect(content == [.text("Four")])
    }

    @Test("Headings render inline markup")
    func headingInlines() {
        guard case .heading(_, let content, _) = MarkdownBlockParser.parse("### The `foo()` function")[0] else {
            Issue.record("expected heading"); return
        }
        #expect(content == [.text("The "), .code("foo()"), .text(" function")])
    }

    @Test("Heading ID extension")
    func headingID() {
        guard case .heading(_, let content, let id) = MarkdownBlockParser.parse("### My Great Heading {#custom-id}")[0] else {
            Issue.record("expected heading"); return
        }
        #expect(id == "custom-id")
        #expect(content == [.text("My Great Heading")])
    }

    @Test("A hash without a following space is not a heading")
    func hashtagIsNotHeading() {
        #expect(MarkdownBlockParser.parse("#selector(foo)") == [.paragraph([.text("#selector(foo)")])])
    }

    @Test("Unordered list with all three bullet markers")
    func unorderedList() {
        guard case .list(let items) = MarkdownBlockParser.parse("- First\n* Second\n+ Third")[0] else {
            Issue.record("expected list"); return
        }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.marker == .bullet })
        #expect(items[0].content == [.text("First")])
    }

    @Test("Ordered list keeps its numbers")
    func orderedList() {
        guard case .list(let items) = MarkdownBlockParser.parse("1. First\n2. Second\n3. Third")[0] else {
            Issue.record("expected list"); return
        }
        #expect(items.map(\.marker) == [.ordered(number: 1), .ordered(number: 2), .ordered(number: 3)])
    }

    @Test("Task list checkbox state")
    func taskList() {
        guard case .list(let items) = MarkdownBlockParser.parse("- [x] Done\n- [ ] Pending")[0] else {
            Issue.record("expected list"); return
        }
        #expect(items.map(\.marker) == [.task(checked: true), .task(checked: false)])
        #expect(items[0].content == [.text("Done")])
    }

    @Test("Nested list depth from indentation")
    func nestedList() {
        guard case .list(let items) = MarkdownBlockParser.parse("- Top\n  - Nested\n    - Deeper")[0] else {
            Issue.record("expected list"); return
        }
        #expect(items.map(\.depth) == [0, 1, 2])
    }

    @Test("Blockquote, including nesting depth")
    func blockQuote() {
        guard case .blockQuote(let depth, let content) = MarkdownBlockParser.parse("> quoted text")[0] else {
            Issue.record("expected quote"); return
        }
        #expect(depth == 1)
        #expect(content == [.text("quoted text")])

        guard case .blockQuote(let nested, _) = MarkdownBlockParser.parse(">> deeper")[0] else {
            Issue.record("expected quote"); return
        }
        #expect(nested == 2)
    }

    @Test("Fenced code block keeps its language and body verbatim")
    func fencedCode() {
        let source = "```swift\nlet x = 1\n// a # that is not a heading\n```"
        guard case .codeBlock(let language, let code) = MarkdownBlockParser.parse(source)[0] else {
            Issue.record("expected code block"); return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\n// a # that is not a heading")
    }

    @Test("An unterminated fence still renders as code while streaming")
    func streamingFence() {
        guard case .codeBlock(let language, let code) = MarkdownBlockParser.parse("```swift\nlet x = ")[0] else {
            Issue.record("expected code block"); return
        }
        #expect(language == "swift")
        #expect(code == "let x = ")
    }

    @Test("Thematic break")
    func thematicBreak() {
        #expect(MarkdownBlockParser.parse("---") == [.thematicBreak])
        #expect(MarkdownBlockParser.parse("***") == [.thematicBreak])
        #expect(MarkdownBlockParser.parse("___") == [.thematicBreak])
    }

    @Test("Table with alignment row")
    func table() {
        let source = "| Syntax | Description |\n| :--- | ---: |\n| Header | Title |"
        guard case .table(let table) = MarkdownBlockParser.parse(source)[0] else {
            Issue.record("expected table"); return
        }
        #expect(table.headers.count == 2)
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.rows.count == 1)
        #expect(table.rows[0][0] == [.text("Header")])
    }

    @Test("Table cells keep their inline markup instead of being stripped")
    func tableCellsKeepMarkup() {
        let source = "| Name |\n| --- |\n| `__init__` |"
        guard case .table(let table) = MarkdownBlockParser.parse(source)[0] else {
            Issue.record("expected table"); return
        }
        #expect(table.rows[0][0] == [.code("__init__")])
    }

    @Test("A pipe line without a delimiter row is not a table")
    func pipeParagraph() {
        #expect(MarkdownBlockParser.parse("| not a table") == [.paragraph([.text("| not a table")])])
    }

    @Test("Footnote definition")
    func footnoteDefinition() {
        guard case .footnoteDefinition(let label, let content) = MarkdownBlockParser.parse("[^1]: This is the footnote.")[0] else {
            Issue.record("expected footnote"); return
        }
        #expect(label == "1")
        #expect(content == [.text("This is the footnote.")])
    }

    @Test("Definition list")
    func definitionList() {
        guard case .definitionList(let definitions) = MarkdownBlockParser.parse("term\n: definition")[0] else {
            Issue.record("expected definition list"); return
        }
        #expect(definitions.count == 1)
        #expect(definitions[0].term == [.text("term")])
        #expect(definitions[0].details == [[.text("definition")]])
    }

    @Test("A list interrupts an open paragraph without a blank line")
    func listInterruptsParagraph() {
        let blocks = MarkdownBlockParser.parse("Intro sentence:\n- First\n- Second")
        #expect(blocks.count == 2)
        #expect(blocks[0] == .paragraph([.text("Intro sentence:")]))
        guard case .list(let items) = blocks[1] else { Issue.record("expected list"); return }
        #expect(items.count == 2)
    }
}

@Suite("Markdown inline parsing")
struct MarkdownInlineParserTests {

    @Test("Bold and italic")
    func emphasis() {
        #expect(MarkdownInlineParser.parse("**bold text**") == [.strong([.text("bold text")])])
        #expect(MarkdownInlineParser.parse("*italicized text*") == [.emphasis([.text("italicized text")])])
    }

    @Test("Nested emphasis composes")
    func nestedEmphasis() {
        #expect(MarkdownInlineParser.parse("**bold *and* italic**")
                == [.strong([.text("bold "), .emphasis([.text("and")]), .text(" italic")])])
    }

    @Test("Inline code is literal inside")
    func codeSpan() {
        #expect(MarkdownInlineParser.parse("`code`") == [.code("code")])
        #expect(MarkdownInlineParser.parse("`a *b* c`") == [.code("a *b* c")])
    }

    @Test("Emphasis is not opened by a delimiter inside a code span")
    func codeSpanShieldsDelimiters() {
        #expect(MarkdownInlineParser.parse("`*` and `*`")
                == [.code("*"), .text(" and "), .code("*")])
    }

    @Test("Intraword underscores stay literal")
    func snakeCase() {
        #expect(MarkdownInlineParser.parse("__init__ and snake_case_name")
                == [.strong([.text("init")]), .text(" and snake_case_name")])
    }

    @Test("Link and image")
    func linksAndImages() {
        #expect(MarkdownInlineParser.parse("[Markdown Guide](https://www.markdownguide.org)")
                == [.link(children: [.text("Markdown Guide")], destination: "https://www.markdownguide.org")])
        #expect(MarkdownInlineParser.parse("![alt text](https://example.com/tux.png)")
                == [.image(alt: "alt text", source: "https://example.com/tux.png")])
    }

    @Test("Link destination drops an optional title")
    func linkTitle() {
        #expect(MarkdownInlineParser.parse("[x](https://example.com \"Title\")")
                == [.link(children: [.text("x")], destination: "https://example.com")])
    }

    @Test("Strikethrough, highlight, subscript, superscript")
    func extendedDelimiters() {
        #expect(MarkdownInlineParser.parse("~~The world is flat.~~")
                == [.strikethrough([.text("The world is flat.")])])
        #expect(MarkdownInlineParser.parse("==very important words==")
                == [.highlight([.text("very important words")])])
        #expect(MarkdownInlineParser.parse("H~2~O")
                == [.text("H"), .subscriptText([.text("2")]), .text("O")])
        #expect(MarkdownInlineParser.parse("X^2^")
                == [.text("X"), .superscriptText([.text("2")])])
    }

    @Test("Footnote reference")
    func footnoteReference() {
        #expect(MarkdownInlineParser.parse("a sentence [^1]")
                == [.text("a sentence "), .footnoteReference(label: "1")])
    }

    @Test("Unmatched delimiters stay literal")
    func unmatchedDelimiters() {
        // Arithmetic, not emphasis: a delimiter with whitespace on the inside cannot open.
        #expect(MarkdownInlineParser.parse("2 * 3 * 4 = 24") == [.text("2 * 3 * 4 = 24")])
        #expect(MarkdownInlineParser.parse("a * b") == [.text("a * b")])
        #expect(MarkdownInlineParser.parse("*open but never closed") == [.text("*open but never closed")])
        // Whitespace before the closer disqualifies it too.
        #expect(MarkdownInlineParser.parse("*a *") == [.text("*a *")])
    }

    @Test("Backslash escapes")
    func escapes() {
        #expect(MarkdownInlineParser.parse("\\*not italic\\*") == [.text("*not italic*")])
    }

    @Test("Percent signs survive — they used to be read as format specifiers")
    func percentIsLiteral() {
        #expect(MarkdownInlineParser.parse("100% and %@ and %d")
                == [.text("100% and %@ and %d")])
    }
}

@Suite("Math spans")
struct MarkdownMathTests {

    @Test("Display math from the reported screenshot")
    func displayMath() {
        let source = "$$0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, \\dots$$"
        guard case .mathBlock(let content) = MarkdownBlockParser.parse(source)[0] else {
            Issue.record("expected math block, got \(MarkdownBlockParser.parse(source)[0])"); return
        }
        #expect(content == [.text("0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, …")])
    }

    @Test("Inline math inside a list item")
    func inlineMath() {
        guard case .list(let items) = MarkdownBlockParser.parse("- $F(n) = F(n-1) + F(n-2)$ for $n \\ge 2$")[0] else {
            Issue.record("expected list"); return
        }
        #expect(items[0].content == [
            .math([.text("F(n) = F(n-1) + F(n-2)")]),
            .text(" for "),
            .math([.text("n ≥ 2")]),
        ])
    }

    @Test("Currency is not math")
    func currencyIsNotMath() {
        #expect(MarkdownInlineParser.parse("it costs $5 and $10 total")
                == [.text("it costs $5 and $10 total")])
    }

    @Test("Superscripts and subscripts")
    func scripts() {
        #expect(MarkdownMath.render("x^2") == [.text("x"), .superscriptText([.text("2")])])
        #expect(MarkdownMath.render("a_{i+1}") == [.text("a"), .subscriptText([.text("i+1")])])
        #expect(MarkdownMath.render("O(n^2)")
                == [.text("O(n"), .superscriptText([.text("2")]), .text(")")])
    }

    @Test("Fractions and roots")
    func fractionsAndRoots() {
        #expect(MarkdownMath.render("\\frac{1}{2}") == [.text("1⁄2")])
        #expect(MarkdownMath.render("\\frac{a+b}{2}") == [.text("(a+b)⁄2")])
        #expect(MarkdownMath.render("\\sqrt{5}") == [.text("√5")])
    }

    @Test("Greek letters and relations")
    func symbols() {
        #expect(MarkdownMath.render("\\pi \\approx 3.14") == [.text("π ≈ 3.14")])
        #expect(MarkdownMath.render("\\Sigma \\infty \\to") == [.text("Σ ∞ →")])
    }

    @Test("Text and grouping commands are unwrapped")
    func textCommands() {
        #expect(MarkdownMath.render("\\text{for } n \\ge 2") == [.text("for  n ≥ 2")])
        #expect(MarkdownMath.render("\\left( x \\right)") == [.text("( x )")])
    }

    @Test("An unknown command shows its source rather than vanishing")
    func unknownCommand() {
        #expect(MarkdownMath.render("\\weirdcmd x") == [.text("\\weirdcmd x")])
    }

    @Test("A dollar sign inside a code span stays literal")
    func codeSpanWins() {
        #expect(MarkdownInlineParser.parse("`let price = $x + $y`")
                == [.code("let price = $x + $y")])
    }

    @Test("An unterminated display block still renders while streaming")
    func streamingMath() {
        guard case .mathBlock = MarkdownBlockParser.parse("$$F(n) = F(n-1)")[0] else {
            Issue.record("expected math block"); return
        }
    }
}

