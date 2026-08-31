//
//  MarkdownBlockParser.swift
//  SwiftChatKit
//
//  Line-oriented block parsing. Tolerant of half-finished input by design: the
//  renderer runs on partially streamed text, so an unterminated fence or table
//  has to produce the block it is on its way to becoming.
//

import Foundation

/// A parsed message, plus what it takes to parse the next version of it without
/// starting over.
///
/// Streaming appends: each delta re-renders the whole message, and at 60fps over a long
/// answer that re-parses text that cannot have changed. Holding on to where each block
/// began lets the next parse resume near the end instead.
public struct MarkdownDocument: Sendable {

    public let blocks: [MarkdownBlock]

    /// The line each block started on, parallel to ``blocks``.
    let blockStartLines: [Int]

    /// The source text preceding ``resumeLine``, kept verbatim so the next parse can
    /// confirm it really is dealing with an append and not an edit.
    let retainedPrefix: String

    /// The line the next parse may resume from, given the prefix still matches.
    let resumeLine: Int

    /// How many leading blocks the *next* parse may keep.
    public let stableBlockCount: Int

    /// How many leading blocks this parse actually carried over from the document it was
    /// given. Zero whenever the text was not an append and everything had to be re-read.
    ///
    /// The distinction matters to anything reusing work of its own: `stableBlockCount` is
    /// a promise about the future, while this is a statement about what just happened.
    /// Trusting the former after a full re-parse would keep rendered text for blocks that
    /// have since become something else entirely.
    public let reusedBlockCount: Int

    public static let empty = MarkdownDocument(blocks: [], blockStartLines: [],
                                               retainedPrefix: "", resumeLine: 0,
                                               stableBlockCount: 0, reusedBlockCount: 0)
}

public enum MarkdownBlockParser {

    /// Splits Markdown source into block-level nodes. Tolerant of unterminated
    /// constructs so a half-streamed message still renders.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        parse(text, reusing: nil).blocks
    }

    /// Parses `text`, reusing whatever of `previous` still applies.
    ///
    /// Sound because the parser is a forward scanner: a block's extent is decided by the
    /// lines from its own start onward, and appending changes only the final line and
    /// what follows it. Blocks that ended before the resume point therefore cannot be
    /// affected. The resume point is set one block further back than that argument
    /// strictly requires, which covers the one- and two-line lookaheads a block does into
    /// the start of the next one (a table's delimiter row, a definition's `: ` line, a
    /// paragraph interrupted by a fence).
    public static func parse(_ text: String, reusing previous: MarkdownDocument?) -> MarkdownDocument {
        let lines = text.components(separatedBy: "\n")

        if let previous, previous.stableBlockCount > 0,
           previous.resumeLine <= lines.count,
           // An append extends the prefix untouched; an edit or a wholly new message
           // fails here and falls through to a full parse.
           text.hasPrefix(previous.retainedPrefix) {
            let tail = scan(lines, from: previous.resumeLine)
            return assemble(lines: lines,
                            blocks: Array(previous.blocks[..<previous.stableBlockCount]) + tail.blocks,
                            starts: Array(previous.blockStartLines[..<previous.stableBlockCount]) + tail.starts,
                            reused: previous.stableBlockCount)
        }

        let all = scan(lines, from: 0)
        return assemble(lines: lines, blocks: all.blocks, starts: all.starts, reused: 0)
    }

    /// Chooses the next resume point and captures the prefix that has to hold for it.
    private static func assemble(lines: [String],
                                 blocks: [MarkdownBlock],
                                 starts: [Int],
                                 reused: Int) -> MarkdownDocument {
        // Two blocks back from the end: the last block is still growing, and the one
        // before it may have read the last block's opening lines while deciding where
        // it ended.
        let stable = max(0, blocks.count - 2)
        let resumeLine = stable > 0 ? starts[stable] : 0
        // `components(separatedBy:)` is exactly reversible, so this is the original text
        // up to that line — the string an appended version must still start with.
        let prefix = resumeLine > 0 ? lines[..<resumeLine].joined(separator: "\n") + "\n" : ""
        return MarkdownDocument(blocks: blocks,
                                blockStartLines: starts,
                                retainedPrefix: prefix,
                                resumeLine: resumeLine,
                                stableBlockCount: stable,
                                reusedBlockCount: min(reused, stable))
    }

    private static func scan(_ lines: [String], from start: Int) -> (blocks: [MarkdownBlock], starts: [Int]) {
        var blocks: [MarkdownBlock] = []
        var starts: [Int] = []
        var i = start

        /// Records where a block began, in step with appending it.
        func append(_ block: MarkdownBlock, at line: Int) {
            blocks.append(block)
            starts.append(line)
        }

        while i < lines.count {
            let blockStart = i
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if let fence = fenceInfo(trimmed) {
                let (block, next) = parseFencedCode(lines, from: i, fence: fence)
                append(block, at: blockStart)
                i = next
                continue
            }

            // Display math: a `$$` line on its own, or `$$...$$` all on one line.
            if trimmed.hasPrefix("$$") {
                let (block, next) = parseDisplayMath(lines, from: i)
                append(block, at: blockStart)
                i = next
                continue
            }

            if isThematicBreak(trimmed) {
                append(.thematicBreak, at: blockStart)
                i += 1
                continue
            }

            if let heading = parseATXHeading(trimmed) {
                append(heading, at: blockStart)
                i += 1
                continue
            }

            if isTableRow(trimmed) {
                let (block, next) = parseTable(lines, from: i)
                if let block { append(block, at: blockStart); i = next; continue }
            }

            if trimmed.hasPrefix(">") {
                let (block, next) = parseBlockQuote(lines, from: i)
                append(block, at: blockStart)
                i = next
                continue
            }

            if let footnote = parseFootnoteDefinition(trimmed) {
                append(footnote, at: blockStart)
                i += 1
                continue
            }

            if listMarker(line) != nil {
                let (block, next) = parseList(lines, from: i)
                append(block, at: blockStart)
                i = next
                continue
            }

            if isDefinitionTerm(lines, at: i) {
                let (block, next) = parseDefinitionList(lines, from: i)
                append(block, at: blockStart)
                i = next
                continue
            }

            let (block, next) = parseParagraph(lines, from: i)
            if let block { append(block, at: blockStart) }
            i = next
        }

        return (blocks, starts)
    }

    // MARK: - Fenced code

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func fenceInfo(_ trimmed: String) -> Fence? {
        for marker in ["`", "~"] as [Character] {
            guard trimmed.hasPrefix(String(repeating: marker, count: 3)) else { continue }
            let run = trimmed.prefix(while: { $0 == marker }).count
            let info = String(trimmed.dropFirst(run)).trimmingCharacters(in: .whitespaces)
            // An info string containing the fence character isn't an opener (``` inside prose).
            guard !info.contains(marker) else { continue }
            return Fence(marker: marker, length: run, language: info.isEmpty ? nil : info)
        }
        return nil
    }

    private static func parseFencedCode(_ lines: [String], from start: Int, fence: Fence) -> (MarkdownBlock, Int) {
        var code: [String] = []
        var i = start + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let run = trimmed.prefix(while: { $0 == fence.marker }).count
            if run >= fence.length, trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                i += 1
                break
            }
            code.append(lines[i])
            i += 1
        }
        // Trailing blank lines are fence padding, not content.
        while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
        return (.codeBlock(language: fence.language, code: code.joined(separator: "\n")), i)
    }

    // MARK: - Headings & rules

    /// `---` is always a rule rather than a setext H2: model output uses it as a
    /// separator far more often than as underlined heading syntax. `===` still
    /// makes a setext H1 because it has no competing meaning.
    /// Consumes a `$$` display equation. An unterminated one still renders, so a
    /// streaming turn does not flash raw LaTeX.
    private static func parseDisplayMath(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let afterOpener = String(first.dropFirst(2))

        if afterOpener.hasSuffix("$$"), afterOpener.count >= 2 {
            let body = String(afterOpener.dropLast(2))
            return (.mathBlock(MarkdownMath.render(body)), start + 1)
        }

        var body = afterOpener.isEmpty ? [] : [afterOpener]
        var i = start + 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("$$") {
                let tail = String(trimmed.dropLast(2))
                if !tail.isEmpty { body.append(tail) }
                i += 1
                break
            }
            body.append(String(lines[i]))
            i += 1
        }
        return (.mathBlock(MarkdownMath.render(body.joined(separator: " "))), i)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        for marker in ["-", "*", "_"] as [Character] {
            let stripped = trimmed.filter { $0 != " " }
            if stripped.count >= 3, stripped.allSatisfy({ $0 == marker }) { return true }
        }
        return false
    }

    private static func parseATXHeading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        var rest = String(trimmed.dropFirst(hashes))
        // `#hashtag` is not a heading — ATX requires a space after the run.
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        rest = rest.trimmingCharacters(in: .whitespaces)

        var id: String?
        if rest.hasSuffix("}"), let open = rest.range(of: "{#", options: .backwards) {
            id = String(rest[rest.index(open.lowerBound, offsetBy: 2)..<rest.index(before: rest.endIndex)])
            rest = String(rest[rest.startIndex..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        // Closing hashes are decoration.
        while rest.hasSuffix("#") { rest = String(rest.dropLast()) }

        return .heading(level: hashes,
                        content: MarkdownInlineParser.parse(rest.trimmingCharacters(in: .whitespaces)),
                        id: id)
    }

    // MARK: - Block quotes

    private static func parseBlockQuote(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var depth = 0
        var content: [String] = []
        var i = start
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            let markers = trimmed.prefix(while: { $0 == ">" || $0 == " " }).filter { $0 == ">" }.count
            depth = max(depth, markers)
            var text = trimmed
            for _ in 0..<markers {
                text = String(text.drop(while: { $0 == " " }).dropFirst())
            }
            content.append(text.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        return (.blockQuote(depth: max(depth, 1),
                            content: MarkdownInlineParser.parse(content.joined(separator: "\n"))), i)
    }

    // MARK: - Lists

    private struct ListMarkerScan {
        let depth: Int
        let marker: MarkdownListMarker
        let contentOffset: Int
    }

    private static func listMarker(_ line: String) -> ListMarkerScan? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let depth = indent / 2

        // Bullet: -, *, + followed by a space.
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") {
            let body = String(trimmed.dropFirst(2))
            // Task list: - [ ] / - [x]
            if body.hasPrefix("[ ]") || body.lowercased().hasPrefix("[x]") {
                return ListMarkerScan(depth: depth,
                                      marker: .task(checked: body.lowercased().hasPrefix("[x]")),
                                      contentOffset: indent + 2 + 3)
            }
            return ListMarkerScan(depth: depth, marker: .bullet, contentOffset: indent + 2)
        }

        // Ordered: 1. or 1)
        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 9 {
            let after = trimmed.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().hasPrefix(" ") {
                return ListMarkerScan(depth: depth,
                                      marker: .ordered(number: Int(digits) ?? 1),
                                      contentOffset: indent + digits.count + 2)
            }
        }
        return nil
    }

    private static func parseList(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var items: [MarkdownListItem] = []
        var pending: [String] = []
        var pendingScan: ListMarkerScan?
        var i = start

        func commit() {
            guard let scan = pendingScan else { return }
            items.append(MarkdownListItem(depth: scan.depth,
                                          marker: scan.marker,
                                          content: MarkdownInlineParser.parse(pending.joined(separator: "\n"))))
            pending = []
            pendingScan = nil
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let scan = listMarker(line) {
                commit()
                pendingScan = scan
                let body = String(line.dropFirst(min(scan.contentOffset, line.count)))
                pending.append(body.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }

            // A blank line ends the list unless the next line continues it.
            if trimmed.isEmpty {
                if i + 1 < lines.count, listMarker(lines[i + 1]) != nil { i += 1; continue }
                break
            }

            // Indented non-marker line: lazy continuation of the current item.
            if pendingScan != nil, line.hasPrefix("  ") || line.hasPrefix("\t") {
                pending.append(trimmed)
                i += 1
                continue
            }
            break
        }

        commit()
        return (.list(items), i)
    }

    // MARK: - Tables

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.count > 1
    }

    private static func splitRow(_ trimmed: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed.dropFirst(trimmed.hasPrefix("|") ? 1 : 0) {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(current) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignments(_ trimmed: String) -> [MarkdownTable.Alignment]? {
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            let body = cell.trimmingCharacters(in: .whitespaces)
            guard body.count >= 3 || body.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let core = body.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (body.hasPrefix(":"), body.hasSuffix(":")) {
            case (true, true):   result.append(.center)
            case (false, true):  result.append(.trailing)
            default:             result.append(.leading)
            }
        }
        return result
    }

    /// Returns nil when the `|` line isn't actually a table (no delimiter row), letting
    /// the caller fall through to paragraph handling.
    private static func parseTable(_ lines: [String], from start: Int) -> (MarkdownBlock?, Int) {
        guard start + 1 < lines.count,
              let aligns = alignments(lines[start + 1].trimmingCharacters(in: .whitespaces))
        else { return (nil, start) }

        let headers = splitRow(lines[start].trimmingCharacters(in: .whitespaces))
        var rows: [[[MarkdownInline]]] = []
        var i = start + 2
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard isTableRow(trimmed) else { break }
            rows.append(splitRow(trimmed).map { MarkdownInlineParser.parse($0) })
            i += 1
        }

        let table = MarkdownTable(headers: headers.map { MarkdownInlineParser.parse($0) },
                                  alignments: aligns,
                                  rows: rows)
        return (.table(table), i)
    }

    // MARK: - Footnotes & definitions

    private static func parseFootnoteDefinition(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("[^"), let close = trimmed.range(of: "]:") else { return nil }
        let label = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close.lowerBound])
        let body = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        return .footnoteDefinition(label: label, content: MarkdownInlineParser.parse(body))
    }

    /// A definition term is any line immediately followed by a `: ` line.
    private static func isDefinitionTerm(_ lines: [String], at i: Int) -> Bool {
        guard i + 1 < lines.count else { return false }
        let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
        return next.hasPrefix(": ") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func parseDefinitionList(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var definitions: [MarkdownDefinition] = []
        var i = start
        while i < lines.count, isDefinitionTerm(lines, at: i) {
            let term = MarkdownInlineParser.parse(lines[i].trimmingCharacters(in: .whitespaces))
            var details: [[MarkdownInline]] = []
            i += 1
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(": ") else { break }
                details.append(MarkdownInlineParser.parse(String(trimmed.dropFirst(2))))
                i += 1
            }
            definitions.append(MarkdownDefinition(term: term, details: details))
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
               i + 1 < lines.count, isDefinitionTerm(lines, at: i + 1) {
                i += 1
            }
        }
        return (.definitionList(definitions), i)
    }

    // MARK: - Paragraphs

    private static func parseParagraph(_ lines: [String], from start: Int) -> (MarkdownBlock?, Int) {
        var content: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            // Setext H1 — the only underline form kept, see isThematicBreak.
            if !content.isEmpty, trimmed.count >= 2, trimmed.allSatisfy({ $0 == "=" }) {
                return (.heading(level: 1,
                                 content: MarkdownInlineParser.parse(content.joined(separator: "\n")),
                                 id: nil), i + 1)
            }
            if i > start, startsNewBlock(lines, at: i) { break }
            content.append(line)
            i += 1
        }
        guard !content.isEmpty else { return (nil, max(i, start + 1)) }
        return (.paragraph(MarkdownInlineParser.parse(content.joined(separator: "\n"))), i)
    }

    /// Constructs that interrupt an open paragraph without a blank line — models
    /// routinely emit a list or fence straight after a sentence.
    private static func startsNewBlock(_ lines: [String], at i: Int) -> Bool {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        if fenceInfo(trimmed) != nil { return true }
        if isThematicBreak(trimmed) { return true }
        if parseATXHeading(trimmed) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if listMarker(lines[i]) != nil { return true }
        if isTableRow(trimmed), i + 1 < lines.count,
           alignments(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil { return true }
        return false
    }
}
