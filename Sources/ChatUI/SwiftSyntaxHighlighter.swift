//
//  SwiftSyntaxHighlighter.swift
//  SwiftChatKit
//
//  A regex-based Swift syntax highlighter, colored to match Xcode's default theme
//  (light and dark). This is deliberately not a real tokenizer — no lexer, no AST,
//  just NSRegularExpression passes applied in priority order over the plain text.
//  That is enough for a chat transcript's code blocks, which run well under a
//  thousand characters, and avoids pulling in swift-syntax for a cosmetic feature.
//
//  Patterns are precompiled once as static `let`s: this file exists to be measured
//  against MarkdownCodeBlockView's plain rendering (see
//  MarkdownCodeBlockViewHighlighted), so recompiling a regex on every keystroke of a
//  streamed response would defeat the comparison before it started.
//

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public enum SwiftSyntaxHighlighter {

    /// Colors matching Xcode's default theme, light and dark. Xcode ships different
    /// hexes per appearance rather than one color with adjusted opacity, so this does
    /// too — the dynamic providers below switch on the live system appearance.
    ///
    /// `@unchecked Sendable`: `PlatformColor` (`NSColor`/`UIColor`) is safe to share
    /// across threads in practice — the dynamic ones built below just resolve a stored
    /// hex against the live appearance on read — but isn't declared `Sendable` itself,
    /// which is what `.xcode` being a global `static let` requires.
    public struct Palette: @unchecked Sendable {
        public var keyword: PlatformColor       // if, func, var, class, return...
        public var string: PlatformColor        // "literal"
        public var number: PlatformColor        // 1, 1.5, 0xFF
        public var comment: PlatformColor       // // and /* */
        public var type: PlatformColor          // capitalized identifiers: String, MyView
        public var attribute: PlatformColor     // @State, @MainActor

        public init(keyword: PlatformColor, string: PlatformColor, number: PlatformColor,
                    comment: PlatformColor, type: PlatformColor, attribute: PlatformColor) {
            self.keyword = keyword
            self.string = string
            self.number = number
            self.comment = comment
            self.type = type
            self.attribute = attribute
        }

        /// Xcode's shipped "Default (Light)" / "Default (Dark)" theme colors, switching
        /// automatically with the system appearance.
        public static let xcode = Palette(
            keyword: dynamic(light: "#AD3DA4", dark: "#FC5FA3"),
            string: dynamic(light: "#D12F1B", dark: "#FC6A5D"),
            number: dynamic(light: "#1C00CF", dark: "#D0BF69"),
            comment: dynamic(light: "#536579", dark: "#6C7986"),
            type: dynamic(light: "#3F6E75", dark: "#5DD8FF"),
            attribute: dynamic(light: "#7A3E9D", dark: "#E9C062"))
    }

    /// Swift's reserved words, as Xcode colors them (declarations, statements, and the
    /// contextual keywords — `some`, `any`, `async` — that read the same way in practice).
    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
        "import", "init", "inout", "internal", "let", "open", "operator", "private",
        "precedencegroup", "protocol", "public", "rethrows", "static", "struct",
        "subscript", "typealias", "var",
        "break", "case", "catch", "continue", "default", "defer", "do", "else",
        "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw",
        "switch", "where", "while",
        "as", "Any", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try",
        "associativity", "convenience", "didSet", "dynamic", "final", "get", "indirect",
        "infix", "lazy", "left", "mutating", "none", "nonmutating", "optional",
        "override", "postfix", "precedence", "prefix", "required", "right", "set",
        "some", "unowned", "weak", "willSet",
        "async", "await", "actor", "any", "isolated", "nonisolated", "distributed",
    ]

    // MARK: Precompiled patterns

    private static let blockComment = try! NSRegularExpression(
        pattern: #"/\*[\s\S]*?\*/"#)
    private static let lineComment = try! NSRegularExpression(
        pattern: #"//[^\n]*"#)
    private static let tripleString = try! NSRegularExpression(
        pattern: #""""[\s\S]*?""""#)
    private static let singleString = try! NSRegularExpression(
        pattern: #""(?:\\.|[^"\\\n])*""#)
    private static let attributeToken = try! NSRegularExpression(
        pattern: #"@\w+"#)
    private static let numberToken = try! NSRegularExpression(
        pattern: #"\b(0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(\.[\d_]+)?([eE][+-]?\d+)?)\b"#)
    private static let identifier = try! NSRegularExpression(
        pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    /// Highlights `code` as Swift, returning a fresh attributed string. `font` and
    /// `baseColor` set the unhighlighted defaults; only the ranges a pattern claims get
    /// recolored, in the priority order below — a keyword regex inside a string never
    /// gets the chance to run because the string's range is already spoken for.
    public static func highlight(_ code: String, font: PlatformFont,
                                  baseColor: PlatformColor,
                                  palette: Palette = .xcode) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: baseColor,
        ])
        let full = NSRange(code.startIndex..., in: code)
        var claimed = IndexSet()

        func apply(_ regex: NSRegularExpression, color: PlatformColor) {
            regex.enumerateMatches(in: code, range: full) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                let bounds = range.location..<(range.location + range.length)
                guard !claimed.contains(integersIn: bounds) else { return }
                claimed.insert(integersIn: bounds)
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        // Comments and strings first: whatever they contain is never re-colored.
        apply(blockComment, color: palette.comment)
        apply(lineComment, color: palette.comment)
        apply(tripleString, color: palette.string)
        apply(singleString, color: palette.string)
        apply(attributeToken, color: palette.attribute)
        apply(numberToken, color: palette.number)

        // Keywords vs. types share one identifier pass: capitalized identifiers not in
        // the keyword set read as Xcode colors them — a type name — everything else
        // stays the base text color unless it is a reserved word.
        identifier.enumerateMatches(in: code, range: full) { match, _, _ in
            guard let range = match?.range, range.location != NSNotFound,
                  let swiftRange = Range(range, in: code) else { return }
            let bounds = range.location..<(range.location + range.length)
            guard !claimed.contains(integersIn: bounds) else { return }
            let word = String(code[swiftRange])
            if keywords.contains(word) {
                claimed.insert(integersIn: bounds)
                result.addAttribute(.foregroundColor, value: palette.keyword, range: range)
            } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                claimed.insert(integersIn: bounds)
                result.addAttribute(.foregroundColor, value: palette.type, range: range)
            }
        }

        return result
    }
}

// MARK: - Dynamic color

/// A color that reads its hex from whichever appearance is live, so the same
/// `NSAttributedString` looks right after a light/dark switch without being rebuilt.
private func dynamic(light: String, dark: String) -> PlatformColor {
    #if canImport(AppKit)
    return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? PlatformColor(chatHex: dark) : PlatformColor(chatHex: light)
    }
    #else
    return UIColor { traits in
        traits.userInterfaceStyle == .dark ? PlatformColor(chatHex: dark) : PlatformColor(chatHex: light)
    }
    #endif
}

private extension PlatformColor {
    convenience init(chatHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
