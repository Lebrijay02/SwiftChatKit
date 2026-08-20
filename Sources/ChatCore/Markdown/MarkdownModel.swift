//
//  MarkdownModel.swift
//  SwiftChatKit
//
//  Document model for the chat Markdown renderer. The parser produces these;
//  a renderer (see the ChatUI product) turns them into a single attributed
//  string so an entire message lives in one text view and one selection scope.
//
//  Foundation only — nothing here knows about a platform, a font or a color.
//

import Foundation

// MARK: - Inline

/// A span of formatted text inside a block. Nesting is explicit so `**bold *and*
/// italic**` composes rather than being flattened to one attribute set.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    case highlight([MarkdownInline])
    case subscriptText([MarkdownInline])
    case superscriptText([MarkdownInline])
    /// Inline code span. Content is literal — no nested parsing.
    case code(String)
    /// A `$...$` span, already translated from LaTeX into displayable nodes.
    case math([MarkdownInline])
    case link(children: [MarkdownInline], destination: String)
    case image(alt: String, source: String)
    case footnoteReference(label: String)
}

// MARK: - Block

public enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    case ordered(number: Int)
    case task(checked: Bool)
}

public struct MarkdownListItem: Equatable, Sendable {
    /// Indent level, 0-based. Derived from leading whitespace in units of 2 columns.
    public let depth: Int
    public let marker: MarkdownListMarker
    public let content: [MarkdownInline]

    public init(depth: Int, marker: MarkdownListMarker, content: [MarkdownInline]) {
        self.depth = depth
        self.marker = marker
        self.content = content
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }
    public let headers: [[MarkdownInline]]
    public let alignments: [Alignment]
    public let rows: [[[MarkdownInline]]]

    public init(headers: [[MarkdownInline]], alignments: [Alignment], rows: [[[MarkdownInline]]]) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }
}

public struct MarkdownDefinition: Equatable, Sendable {
    public let term: [MarkdownInline]
    public let details: [[MarkdownInline]]

    public init(term: [MarkdownInline], details: [[MarkdownInline]]) {
        self.term = term
        self.details = details
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    /// `id` carries an explicit `{#custom-id}` when the source supplied one.
    case heading(level: Int, content: [MarkdownInline], id: String?)
    case paragraph([MarkdownInline])
    /// `depth` counts the `>` markers, so nested quotes indent further.
    case blockQuote(depth: Int, content: [MarkdownInline])
    case codeBlock(language: String?, code: String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
    /// A `$$...$$` display equation, set on its own centred line.
    case mathBlock([MarkdownInline])
    case thematicBreak
    case definitionList([MarkdownDefinition])
    case footnoteDefinition(label: String, content: [MarkdownInline])
}
