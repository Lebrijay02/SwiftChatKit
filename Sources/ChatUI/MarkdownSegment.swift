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
//  Splitting can also reuse the previous version of a streaming message: see
//  ``MarkdownSegmentSet``. What comes out is identical either way — reuse is a matter of
//  how much work it took, never of what the reader ends up looking at.
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

    var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    /// Groups blocks into segments, coalescing consecutive prose so selection breaks
    /// only where a code block actually sits.
    public static func split(_ blocks: [MarkdownBlock], style: MarkdownStyle) -> [MarkdownSegment] {
        split(blocks, stableBlockCount: 0, carriedOver: 0, style: style, reusing: nil).segments
    }

    /// Splits `document`, keeping whatever of `previous` the parser says still stands.
    public static func split(_ document: MarkdownDocument,
                             style: MarkdownStyle,
                             reusing previous: MarkdownSegmentSet?) -> MarkdownSegmentSet {
        split(document.blocks, stableBlockCount: document.stableBlockCount,
              carriedOver: document.reusedBlockCount, style: style, reusing: previous)
    }

    private static func split(_ blocks: [MarkdownBlock],
                              stableBlockCount: Int,
                              carriedOver: Int,
                              style: MarkdownStyle,
                              reusing previous: MarkdownSegmentSet?) -> MarkdownSegmentSet {
        let styleKey = MarkdownStyle.key(for: style)

        // Blocks the parser carried over verbatim *and* that the old segments were
        // themselves built from. The previous set may have covered blocks past its own
        // stable point, and those were re-parsed since. When the parse started over —
        // a different message rendered by a recycled view — nothing carried over at all.
        var reusable = 0
        if let previous, previous.styleKey == styleKey {
            reusable = min(previous.validBlockCount, carriedOver)
        }

        var segments: [MarkdownSegment] = []
        var ranges: [Range<Int>] = []
        var next = 0

        // Whole segments first, and only up to a cut that the cold split would also make.
        // Prose runs to the next code block, so a boundary is only real with code on one
        // side of it — stopping mid-run would fuse differently and split a selection that
        // should have been continuous.
        if let previous {
            for (index, segment) in previous.segments.enumerated() {
                let range = previous.ranges[index]
                guard range.upperBound <= reusable else { break }
                let cutIsReal = segment.isCode
                    || (range.upperBound < blocks.count && blocks[range.upperBound].isCodeBlock)
                guard cutIsReal else { break }
                segments.append(segment)
                ranges.append(range)
                next = range.upperBound
            }
        }

        // The prose run that straddles the boundary can still reuse the text it had
        // rendered for the stable part of itself, and append only the rest.
        var proseTail: ProseTailCache?
        var pendingStart = next

        func flushProse(upTo end: Int) {
            guard end > pendingStart else { return }
            let run = Array(blocks[pendingStart..<end])
            let rendered: NSAttributedString

            if let cached = previous?.proseTail,
               previous?.styleKey == styleKey,
               cached.start == pendingStart,
               cached.stableEnd <= min(reusable, end) {
                // Extend the cached prefix to as far as the parser now vouches for, keep
                // that as the next round's starting point, then finish the run on a copy.
                let prefix = NSMutableAttributedString(attributedString: cached.attributed)
                let stableEnd = min(reusable, end)
                MarkdownAttributedBuilder.append(Array(blocks[cached.stableEnd..<stableEnd]),
                                                 to: prefix, style: style)
                proseTail = ProseTailCache(start: pendingStart, stableEnd: stableEnd,
                                           attributed: prefix.copy() as! NSAttributedString)

                let full = NSMutableAttributedString(attributedString: prefix)
                MarkdownAttributedBuilder.append(Array(blocks[stableEnd..<end]), to: full, style: style)
                rendered = full
            } else {
                rendered = MarkdownAttributedBuilder.build(run, style: style).attributed
                // Seed the cache for the next delta, covering the stable part of this run.
                let stableEnd = min(reusable, end)
                if stableEnd > pendingStart {
                    let prefix = NSMutableAttributedString()
                    MarkdownAttributedBuilder.append(Array(blocks[pendingStart..<stableEnd]),
                                                     to: prefix, style: style)
                    proseTail = ProseTailCache(start: pendingStart, stableEnd: stableEnd,
                                               attributed: prefix)
                } else {
                    proseTail = ProseTailCache(start: pendingStart, stableEnd: pendingStart,
                                               attributed: NSAttributedString())
                }
            }

            segments.append(.prose(id: segments.count, attributed: rendered))
            ranges.append(pendingStart..<end)
        }

        var i = next
        while i < blocks.count {
            if case .codeBlock(let language, let code) = blocks[i] {
                flushProse(upTo: i)
                segments.append(.code(id: segments.count, language: language, code: code))
                ranges.append(i..<(i + 1))
                pendingStart = i + 1
                // A code block ends the run the cache was tracking.
                proseTail = nil
            }
            i += 1
        }
        flushProse(upTo: blocks.count)

        return MarkdownSegmentSet(segments: segments,
                                  ranges: ranges,
                                  validBlockCount: stableBlockCount,
                                  styleKey: styleKey,
                                  proseTail: proseTail)
    }
}

/// The result of a split, plus what the next split needs to avoid redoing it.
public struct MarkdownSegmentSet {

    public let segments: [MarkdownSegment]

    /// The blocks each segment covers, parallel to ``segments``.
    let ranges: [Range<Int>]

    /// How many leading blocks a later split may trust these segments for — the stable
    /// count of the document they were built from, not of the one being built now.
    let validBlockCount: Int

    /// Rebuilt from scratch when the theme changes, since every attribute would differ.
    let styleKey: String

    /// Rendered text for the settled part of the trailing prose run.
    let proseTail: ProseTailCache?

}

struct ProseTailCache {
    /// First block of the run this covers.
    let start: Int
    /// One past the last block already rendered into ``attributed``.
    let stableEnd: Int
    let attributed: NSAttributedString
}

private extension MarkdownBlock {
    var isCodeBlock: Bool {
        if case .codeBlock = self { return true }
        return false
    }
}
