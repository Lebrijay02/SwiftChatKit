//
//  MarkdownSegment.swift
//  SwiftChatKit
//
//  Splits a parsed message into the pieces that get their own view.
//
//  Everything that can share one text storage does, so selection runs continuously
//  through headings, prose, lists, quotes and tables. Code blocks are pulled out because
//  they scroll horizontally, which a shared text container cannot express — see
//  MarkdownCodeBlockView for why that trade is made in code's favour.
//

import Foundation
import ChatCore

public enum MarkdownSegment: Identifiable {

    /// A run of adjacent non-code blocks, pre-rendered into one attributed string.
    case prose(id: Int, attributed: NSAttributedString)
    case code(id: Int, language: String?, code: String)

    public var id: Int {
        switch self {
        case .prose(let id, _), .code(let id, _, _): return id
        }
    }

    /// Groups blocks into segments, coalescing consecutive prose so selection breaks
    /// only where a code block actually sits.
    public static func split(_ blocks: [MarkdownBlock], style: MarkdownStyle) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var pending: [MarkdownBlock] = []

        func flushProse() {
            guard !pending.isEmpty else { return }
            let rendered = MarkdownAttributedBuilder.build(pending, style: style)
            segments.append(.prose(id: segments.count, attributed: rendered.attributed))
            pending = []
        }

        for block in blocks {
            if case .codeBlock(let language, let code) = block {
                flushProse()
                segments.append(.code(id: segments.count, language: language, code: code))
            } else {
                pending.append(block)
            }
        }
        flushProse()
        return segments
    }
}
