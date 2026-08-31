//
//  MarkdownAttributedBuilder.swift
//  SwiftChatKit
//
//  Turns parsed blocks into one NSAttributedString. Everything a message contains
//  ends up in a single text storage, which is what lets a drag select across
//  headings, prose, lists, tables and code in one gesture.
//

import Foundation
import ChatCore
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Where a fenced code block landed in the built string, so the view can draw its
/// backing panel and float a Copy button over it.
public struct MarkdownCodeRegion: Equatable, Identifiable {
    public let id: Int
    public let range: NSRange
    public let language: String?
    public let code: String

    public init(id: Int, range: NSRange, language: String?, code: String) {
        self.id = id
        self.range = range
        self.language = language
        self.code = code
    }
}

public struct MarkdownRenderResult {
    public let attributed: NSAttributedString
    public let codeRegions: [MarkdownCodeRegion]
}

public enum MarkdownAttributedBuilder {

    /// Attribute key marking a run as belonging to a fenced code block. The text view
    /// reads it back to lay out backgrounds without re-deriving ranges.
    public static let codeBlockAttribute = NSAttributedString.Key("SwiftChatKitMarkdownCodeBlock")

    /// Marks a table's whole range so the text view can stroke one rounded outer
    /// border around it. `NSTextTable`'s own per-cell borders are left in place for
    /// the internal grid, but its automatic layout doesn't reliably land the last
    /// column's edge on the container boundary — the outer border needs a pass
    /// that doesn't depend on that.
    public static let tableAttribute = NSAttributedString.Key("SwiftChatKitMarkdownTable")

    /// Marks a table's header row range so the text view can fill it with a shape
    /// that respects the outer border's corner radius at the top. The native
    /// `NSTextTableBlock.backgroundColor` fill is square-cornered, and pokes past
    /// that curve — this replaces it rather than layering on top of it.
    public static let tableHeaderAttribute = NSAttributedString.Key("SwiftChatKitMarkdownTableHeader")

    public static func build(_ blocks: [MarkdownBlock], style: MarkdownStyle) -> MarkdownRenderResult {
        let result = NSMutableAttributedString()
        var regions: [MarkdownCodeRegion] = []

        for (index, block) in blocks.enumerated() {
            if index > 0 { appendSeparator(to: result) }
            switch block {
            case .heading(let level, let content, _):
                append(heading(level: level, content: content, style: style), to: result)

            case .paragraph(let content):
                append(paragraph(content, style: style), to: result)

            case .blockQuote(let depth, let content):
                append(blockQuote(depth: depth, content: content, style: style), to: result)

            case .codeBlock(let language, let code):
                // Reached only if a code block is fed to the builder directly; the chat
                // renderer splits them out into MarkdownCodeBlockView so they can scroll.
                let start = result.length
                append(codeBlock(code, style: style), to: result)
                let range = NSRange(location: start, length: result.length - start)
                result.addAttribute(codeBlockAttribute, value: regions.count, range: range)
                regions.append(MarkdownCodeRegion(id: regions.count, range: range,
                                                  language: language, code: code))

            case .list(let items):
                append(list(items, style: style), to: result)

            case .table(let table):
                append(self.table(table, style: style), to: result)

            case .mathBlock(let content):
                append(mathBlock(content, style: style), to: result)

            case .thematicBreak:
                append(thematicBreak(style: style), to: result)

            case .definitionList(let definitions):
                append(definitionList(definitions, style: style), to: result)

            case .footnoteDefinition(let label, let content):
                append(footnote(label: label, content: content, style: style), to: result)
            }
        }

        return MarkdownRenderResult(attributed: result, codeRegions: regions)
    }

    private static func append(_ piece: NSAttributedString, to target: NSMutableAttributedString) {
        target.append(piece)
        if !piece.string.hasSuffix("\n") { target.append(NSAttributedString(string: "\n")) }
    }

    // MARK: - Blocks

    private static func heading(level: Int, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let scale = style.headingScales[min(max(level, 1), 6) - 1]
        let size = style.bodyFontSize * scale
        let base = PlatformFont.chatSystem(size: size, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = level <= 2 ? size * 0.5 : size * 0.4
        paragraph.paragraphSpacing = size * 0.15
        paragraph.lineHeightMultiple = 1.05

        let out = inlines(content, style: style, font: base, color: style.textColor)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func paragraph(_ content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatSystem(size: style.bodyFontSize)
        let out = inlines(content, style: style, font: font, color: style.textColor)
        out.addAttribute(.paragraphStyle, value: bodyParagraphStyle(style),
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func bodyParagraphStyle(_ style: MarkdownStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = style.bodyFontSize * 0.3
        return paragraph
    }

    private static func blockQuote(depth: Int, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatSystem(size: style.bodyFontSize)
        let out = inlines(content, style: style, font: font, color: style.secondaryColor)

        let indent = CGFloat(depth) * 18
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = style.bodyFontSize * 0.3
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        // The bar itself is drawn by the text view; the indent reserves room for it.
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        out.addAttribute(quoteDepthAttribute, value: depth, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Marks quoted runs so the text view can stroke the vertical bar beside them.
    public static let quoteDepthAttribute = NSAttributedString.Key("SwiftChatKitMarkdownQuoteDepth")

    /// A code block taller than this collapses to a preview until expanded.
    public static let collapsedCodeLines = 6

    /// The newline between blocks inherits the preceding run's attributes; left plain it
    /// picks up the default 12pt font and adds a visible gap of its own.
    private static func appendSeparator(to text: NSMutableAttributedString) {
        var attributes: [NSAttributedString.Key: Any] = [:]
        if text.length > 0 {
            attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
            // Carried onto the next block these would extend its panel or quote bar.
            attributes[codeBlockAttribute] = nil
            attributes[quoteDepthAttribute] = nil
            attributes[thematicBreakAttribute] = nil
            attributes[tableAttribute] = nil
            attributes[tableHeaderAttribute] = nil
            // A code block's or table's paragraph style carries indents, spacing, and —
            // for tables — an NSTextTableBlock with its own border and padding. Left in
            // place, the separator becomes one more (empty) cell or code line, padding
            // out whatever follows it. Only the font/color need to survive.
            attributes[.paragraphStyle] = nil
        }
        text.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    private static func codeBlock(_ code: String, style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatMono(size: style.bodyFontSize * 0.95)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.tailIndent = -12
        // Long lines wrap rather than scroll: a nested scroll view would break the
        // single selection scope this whole renderer exists to provide.
        paragraph.lineBreakMode = .byWordWrapping

        let out = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ])

        // Every newline inside the code is a paragraph break, so block spacing has to be
        // applied to the first and last lines only — putting it on `paragraph` would
        // insert the gap between every single line of code.
        applyOuterSpacing(before: 10, after: 10, to: out, base: paragraph)
        return out
    }

    /// Adds leading/trailing block spacing to a multi-paragraph run without spacing out
    /// its interior lines.
    private static func applyOuterSpacing(before: CGFloat, after: CGFloat,
                                          to text: NSMutableAttributedString,
                                          base: NSParagraphStyle) {
        guard text.length > 0 else { return }
        let ns = text.string as NSString

        let first = base.mutableCopy() as! NSMutableParagraphStyle
        first.paragraphSpacingBefore = before
        text.addAttribute(.paragraphStyle, value: first, range: ns.lineRange(for: NSRange(location: 0, length: 0)))

        let last = base.mutableCopy() as! NSMutableParagraphStyle
        last.paragraphSpacing = after
        let lastRange = ns.lineRange(for: NSRange(location: text.length - 1, length: 0))
        // A single-line block needs both, so merge rather than overwrite.
        if lastRange.location == 0 { last.paragraphSpacingBefore = before }
        text.addAttribute(.paragraphStyle, value: last, range: lastRange)
    }

    private static func list(_ items: [MarkdownListItem], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatSystem(size: style.bodyFontSize)
        let out = NSMutableAttributedString()

        for (index, item) in items.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }

            let indent = CGFloat(item.depth) * 18
            let markerText: String
            var markerColor = style.secondaryColor
            switch item.marker {
            case .bullet:
                markerText = item.depth % 2 == 0 ? "•\t" : "◦\t"
            case .ordered(let number):
                markerText = "\(number).\t"
            case .task(let checked):
                markerText = checked ? "☑\t" : "☐\t"
                if checked { markerColor = style.accentColor }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = style.bodyFontSize * 0.2
            paragraph.firstLineHeadIndent = indent
            // Wrapped lines align with the text, not the marker.
            paragraph.headIndent = indent + 20
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]

            out.append(NSAttributedString(string: markerText, attributes: [
                .font: font,
                .foregroundColor: markerColor,
            ]))

            let body = inlines(item.content, style: style, font: font, color: style.textColor)
            if case .task(let checked) = item.marker, checked {
                body.addAttribute(.foregroundColor, value: style.secondaryColor,
                                  range: NSRange(location: 0, length: body.length))
            }
            out.append(body)

            out.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: out.length - markerText.count - body.length,
                                            length: markerText.count + body.length))
        }
        return out
    }

    /// A display equation: centred, on its own line, in the serif-ish italic that
    /// reads as mathematics without pulling in a TeX renderer.
    private static func mathBlock(_ content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacingBefore = style.bodyFontSize * 0.5
        paragraph.paragraphSpacing = style.bodyFontSize * 0.5
        paragraph.lineSpacing = 3

        let out = inlines(content, style: style,
                          font: mathFont(size: style.bodyFontSize * 1.05),
                          color: style.textColor)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Italic system font stands in for a math face; it distinguishes variables from
    /// prose without shipping a font.
    public static func mathFont(size: CGFloat) -> PlatformFont {
        PlatformFont.chatSystem(size: size).addingChatTrait(.italic)
    }

    private static func thematicBreak(style: MarkdownStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 2
        paragraph.paragraphSpacing = 2
        // The carrier line is collapsed to a hairline; without a line-height clamp it
        // reserves a full line box and the rule floats in a band of empty space.
        paragraph.minimumLineHeight = 7
        paragraph.maximumLineHeight = 7
        // A styled empty line; the rule is stroked by the text view.
        let out = NSMutableAttributedString(string: " ", attributes: [
            .font: PlatformFont.chatSystem(size: style.bodyFontSize * 0.4),
            .paragraphStyle: paragraph,
            thematicBreakAttribute: true,
        ])
        return out
    }

    public static let thematicBreakAttribute = NSAttributedString.Key("SwiftChatKitMarkdownRule")

    private static func definitionList(_ definitions: [MarkdownDefinition], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatSystem(size: style.bodyFontSize)
        let termFont = PlatformFont.chatSystem(size: style.bodyFontSize, weight: .semibold)
        let out = NSMutableAttributedString()

        for (index, definition) in definitions.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let term = inlines(definition.term, style: style, font: termFont, color: style.textColor)
            term.addAttribute(.paragraphStyle, value: bodyParagraphStyle(style),
                              range: NSRange(location: 0, length: term.length))
            out.append(term)

            for detail in definition.details {
                out.append(NSAttributedString(string: "\n"))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.firstLineHeadIndent = 18
                paragraph.headIndent = 18
                paragraph.paragraphSpacing = style.bodyFontSize * 0.3
                let body = inlines(detail, style: style, font: font, color: style.secondaryColor)
                body.addAttribute(.paragraphStyle, value: paragraph,
                                  range: NSRange(location: 0, length: body.length))
                out.append(body)
            }
        }
        return out
    }

    private static func footnote(label: String, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.chatSystem(size: style.bodyFontSize * 0.9)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 18
        paragraph.paragraphSpacing = style.bodyFontSize * 0.3

        let out = NSMutableAttributedString(string: "\(label). ", attributes: [
            .font: PlatformFont.chatSystem(size: style.bodyFontSize * 0.9, weight: .semibold),
            .foregroundColor: style.secondaryColor,
        ])
        out.append(inlines(content, style: style, font: font, color: style.secondaryColor))
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Tables

    #if canImport(AppKit)

    /// Built with NSTextTable so cells stay inside the one text storage — a SwiftUI
    /// grid here would reintroduce exactly the selection break this replaces.
    private static func table(_ table: MarkdownTable, style: MarkdownStyle) -> NSAttributedString {
        let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let textTable = NSTextTable()
        textTable.numberOfColumns = columnCount
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false

        let out = NSMutableAttributedString()
        let headerFont = PlatformFont.chatSystem(size: style.bodyFontSize * 0.95, weight: .semibold)
        let bodyFont = PlatformFont.chatSystem(size: style.bodyFontSize * 0.95)

        let rowCount = (table.hasHeader ? 1 : 0) + table.rows.count

        func appendRow(_ cells: [[MarkdownInline]], row: Int, font: PlatformFont, isHeader: Bool) {
            for column in 0..<columnCount {
                let block = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setBorderColor(style.dividerColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                // The outer edges are left to MarkdownDecoration, which strokes one
                // rounded rect around the whole table. Drawn here too they would be
                // a square rectangle underneath it, and no rounded path can mask a
                // square corner — the corners poked out. Only the interior grid
                // lines are the native table's to draw.
                if row == 0 { block.setWidth(0, type: .absoluteValueType, for: .border, edge: .minY) }
                if row == rowCount - 1 { block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxY) }
                if column == 0 { block.setWidth(0, type: .absoluteValueType, for: .border, edge: .minX) }
                if column == columnCount - 1 {
                    block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX)
                }
                // The header's background is filled by MarkdownDecoration too, for
                // the same reason: its square corners overhung the rounded border.

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.lineSpacing = 2
                switch table.alignments[safe: column] ?? .leading {
                case .leading:  paragraph.alignment = .left
                case .center:   paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }

                let content = cells[safe: column] ?? []
                let cell = inlines(content, style: style, font: font,
                                   color: isHeader ? style.textColor : style.textColor)
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttribute(.paragraphStyle, value: paragraph,
                                  range: NSRange(location: 0, length: cell.length))
                out.append(cell)
            }
        }

        // A blank header row is skipped entirely rather than rendered as an empty
        // band; the body rows then start at row 0 so the table stays contiguous.
        var nextRow = 0
        if table.hasHeader {
            let headerStart = out.length
            appendRow(table.headers, row: nextRow, font: headerFont, isHeader: true)
            out.addAttribute(tableHeaderAttribute, value: true,
                             range: NSRange(location: headerStart, length: out.length - headerStart))
            nextRow += 1
        }
        for row in table.rows {
            appendRow(row, row: nextRow, font: bodyFont, isHeader: false)
            nextRow += 1
        }
        out.addAttribute(tableAttribute, value: true, range: NSRange(location: 0, length: out.length))
        return out
    }

    #else

    /// UIKit has no `NSTextTable`, so columns are laid out with tab stops. It
    /// loses the cell borders, but keeps the content in the same text storage —
    /// which is the property the whole renderer is built around.
    private static func table(_ table: MarkdownTable, style: MarkdownStyle) -> NSAttributedString {
        let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let columnWidth: CGFloat = 120
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = style.bodyFontSize * 0.2
        paragraph.tabStops = (1..<columnCount).map {
            NSTextTab(textAlignment: .left, location: CGFloat($0) * columnWidth)
        }
        paragraph.defaultTabInterval = columnWidth

        let out = NSMutableAttributedString()
        let headerFont = PlatformFont.chatSystem(size: style.bodyFontSize * 0.95, weight: .semibold)
        let bodyFont = PlatformFont.chatSystem(size: style.bodyFontSize * 0.95)

        func appendRow(_ cells: [[MarkdownInline]], font: PlatformFont) {
            for column in 0..<columnCount {
                if column > 0 { out.append(NSAttributedString(string: "\t")) }
                out.append(inlines(cells[safe: column] ?? [], style: style,
                                   font: font, color: style.textColor))
            }
            out.append(NSAttributedString(string: "\n"))
        }

        if table.hasHeader { appendRow(table.headers, font: headerFont) }
        for row in table.rows { appendRow(row, font: bodyFont) }

        out.addAttribute(.paragraphStyle, value: paragraph,
                         range: NSRange(location: 0, length: out.length))
        out.addAttribute(tableAttribute, value: true, range: NSRange(location: 0, length: out.length))
        return out
    }

    #endif

    // MARK: - Inlines

    private static func inlines(_ nodes: [MarkdownInline], style: MarkdownStyle,
                                font: PlatformFont, color: PlatformColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for node in nodes {
            out.append(inline(node, style: style, font: font, color: color))
        }
        return out
    }

    private static func inline(_ node: MarkdownInline, style: MarkdownStyle,
                               font: PlatformFont, color: PlatformColor) -> NSAttributedString {
        switch node {
        case .text(let string):
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])

        case .strong(let children):
            return inlines(children, style: style, font: font.addingChatTrait(.bold), color: color)

        case .emphasis(let children):
            return inlines(children, style: style, font: font.addingChatTrait(.italic), color: color)

        case .strikethrough(let children):
            let out = inlines(children, style: style, font: font, color: color)
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .highlight(let children):
            let out = inlines(children, style: style, font: font, color: color)
            out.addAttribute(.backgroundColor, value: style.highlightColor,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .subscriptText(let children):
            let out = inlines(children, style: style, font: font.withSize(font.pointSize * 0.75), color: color)
            out.addAttribute(.baselineOffset, value: -font.pointSize * 0.2,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .superscriptText(let children):
            let out = inlines(children, style: style, font: font.withSize(font.pointSize * 0.75), color: color)
            out.addAttribute(.baselineOffset, value: font.pointSize * 0.35,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .math(let children):
            // Already translated out of LaTeX; the italic face marks it as math.
            return inlines(children, style: style,
                           font: mathFont(size: font.pointSize), color: color)

        case .code(let string):
            // Hair spaces pad the background fill so it doesn't touch the glyphs.
            return NSAttributedString(string: "\u{200A}\(string)\u{200A}", attributes: [
                .font: PlatformFont.chatMono(size: font.pointSize * 0.92),
                .foregroundColor: color,
                .backgroundColor: style.codeBackground,
            ])

        case .link(let children, let destination):
            let out = inlines(children, style: style, font: font, color: style.accentColor)
            let range = NSRange(location: 0, length: out.length)
            if let url = URL(string: destination) {
                out.addAttribute(.link, value: url, range: range)
            }
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            return out

        case .image(let alt, let source):
            // Images render as a labelled link rather than being fetched: chat content
            // is untrusted, and silently loading remote URLs would leak the session.
            let label = alt.isEmpty ? source : alt
            let out = NSMutableAttributedString(string: "🖼 \(label)", attributes: [
                .font: font,
                .foregroundColor: style.accentColor,
            ])
            if let url = URL(string: source) {
                out.addAttribute(.link, value: url, range: NSRange(location: 0, length: out.length))
            }
            return out

        case .footnoteReference(let label):
            return NSAttributedString(string: label, attributes: [
                .font: PlatformFont.chatSystem(size: font.pointSize * 0.75),
                .foregroundColor: style.accentColor,
                .baselineOffset: font.pointSize * 0.35,
            ])
        }
    }
}

// MARK: - Helpers


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
