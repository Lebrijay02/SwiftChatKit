//
//  GlobPattern.swift
//  SwiftChatKit
//
//  A real glob matcher. The obvious shortcut — strip the wildcards and test
//  `contains` — makes `*.swift` match `swifty.txt` and `src/*.ts` match anything
//  anywhere, and the model has no way to tell a wrong result from a right one.
//

import Foundation

public enum GlobPattern {

    /// Matches `path` against a glob pattern, case-insensitively.
    ///
    /// Supported: `*` (any run of characters except `/`), `**` (any run
    /// including `/`), `?` (one character except `/`), and `[abc]` / `[a-z]` /
    /// `[!abc]` character classes. Everything else is literal.
    ///
    /// A pattern with no `/` is matched at any depth, so `*.swift` finds nested
    /// files — that is what callers mean by it.
    public static func matches(_ path: String, pattern: String) -> Bool {
        let pattern = pattern.contains("/") ? pattern : "**/" + pattern
        return match(Array(path.lowercased()), 0, Array(pattern.lowercased()), 0)
    }

    private static func match(_ path: [Character], _ pathStart: Int,
                              _ pattern: [Character], _ patternStart: Int) -> Bool {
        var p = pathStart
        var q = patternStart

        while q < pattern.count {
            let token = pattern[q]

            if token == "*" {
                let isDoubleStar = q + 1 < pattern.count && pattern[q + 1] == "*"
                var next = q + (isDoubleStar ? 2 : 1)
                // `**/` also matches zero directories, so `**/x.swift` finds a
                // top-level x.swift and not only nested ones.
                if isDoubleStar, next < pattern.count, pattern[next] == "/" {
                    if match(path, p, pattern, next + 1) { return true }
                    next += 1
                }
                var index = p
                while true {
                    if match(path, index, pattern, next) { return true }
                    guard index < path.count else { return false }
                    if !isDoubleStar && path[index] == "/" { return false }
                    index += 1
                }
            }

            guard p < path.count else { return false }

            switch token {
            case "?":
                guard path[p] != "/" else { return false }
            case "[":
                guard let end = classEnd(pattern, from: q),
                      matchesClass(path[p], pattern[(q + 1)..<end])
                else { return false }
                q = end
            default:
                guard path[p] == token else { return false }
            }
            p += 1
            q += 1
        }

        return p == path.count
    }

    /// Index of the `]` closing a class opened at `open`, or nil when unclosed.
    private static func classEnd(_ pattern: [Character], from open: Int) -> Int? {
        var index = open + 1
        if index < pattern.count, pattern[index] == "!" { index += 1 }
        // A `]` immediately after the opener is a literal, not the terminator.
        if index < pattern.count, pattern[index] == "]" { index += 1 }
        while index < pattern.count {
            if pattern[index] == "]" { return index }
            index += 1
        }
        return nil
    }

    private static func matchesClass(_ character: Character,
                                     _ body: ArraySlice<Character>) -> Bool {
        var body = body
        var negated = false
        if body.first == "!" {
            negated = true
            body = body.dropFirst()
        }

        var found = false
        var index = body.startIndex
        while index < body.endIndex {
            let low = body[index]
            let dash = body.index(after: index)
            if dash < body.endIndex, body[dash] == "-" {
                let highIndex = body.index(after: dash)
                if highIndex < body.endIndex {
                    if character >= low, character <= body[highIndex] { found = true }
                    index = body.index(after: highIndex)
                    continue
                }
            }
            if character == low { found = true }
            index = dash
        }

        return found != negated
    }
}
