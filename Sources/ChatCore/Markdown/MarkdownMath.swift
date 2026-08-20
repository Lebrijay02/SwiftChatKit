//
//  MarkdownMath.swift
//  SwiftChatKit
//
//  LaTeX-lite: turns the `$...$` and `$$...$$` spans models emit into readable
//  inline nodes. This is deliberately not a TeX engine — it covers the symbol,
//  fraction, root and script forms that show up in chat answers, and falls back
//  to the source text for anything it does not know rather than guessing.
//

import Foundation

public enum MarkdownMath {

    /// Converts a math span's LaTeX source into inline nodes.
    public static func render(_ latex: String) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var literal = ""

        func flush() {
            if !literal.isEmpty { out.append(.text(literal)); literal = "" }
        }

        let c = Array(latex)
        var i = 0
        while i < c.count {
            switch c[i] {
            case "\\":
                let (replacement, next) = command(c, at: i)
                literal += replacement
                i = next

            case "^", "_":
                let isSuper = c[i] == "^"
                let (body, next) = scriptArgument(c, after: i + 1)
                if body.isEmpty { literal.append(c[i]); i += 1; continue }
                flush()
                out.append(isSuper ? .superscriptText(render(body)) : .subscriptText(render(body)))
                i = next

            case "{", "}":
                // Grouping braces carry no meaning once the group is already inline.
                i += 1

            case "$":
                i += 1

            default:
                literal.append(c[i])
                i += 1
            }
        }
        flush()
        return out.isEmpty ? [.text(latex)] : out
    }

    /// True when a `$...$` span looks like math rather than a currency amount.
    /// Without this, "costs $5 and $10" would parse as one math span.
    public static func looksLikeMath(_ body: String) -> Bool {
        guard !body.isEmpty, !body.contains("\n") else { return false }
        if body.contains(where: { "\\^_{}=<>".contains($0) }) { return true }
        // A bare token with no spaces (`$n$`, `$F(n)$`) is a variable reference.
        return !body.contains(" ") && body.contains(where: { $0.isLetter })
    }

    // MARK: - Commands

    /// Expands the command starting at the backslash, returning its text and the index
    /// just past what was consumed.
    private static func command(_ c: [Character], at start: Int) -> (String, Int) {
        var i = start + 1
        var name = ""
        while i < c.count, c[i].isLetter { name.append(c[i]); i += 1 }

        if name.isEmpty {
            // An escaped literal such as `\{`, `\%` or `\$`.
            guard i < c.count else { return ("\\", i) }
            return (String(c[i]), i + 1)
        }

        switch name {
        case "frac", "tfrac", "dfrac":
            let (numerator, afterNumerator) = braceArgument(c, from: i)
            let (denominator, afterDenominator) = braceArgument(c, from: afterNumerator)
            guard let numerator, let denominator else { return (symbols[name] ?? name, i) }
            return ("\(parenthesized(numerator))⁄\(parenthesized(denominator))", afterDenominator)

        case "sqrt":
            let (radicand, after) = braceArgument(c, from: i)
            guard let radicand else { return ("√", i) }
            return ("√\(parenthesized(radicand))", after)

        case "text", "mathrm", "mathbb", "mathcal", "mathbf", "operatorname":
            let (body, after) = braceArgument(c, from: i)
            guard let body else { return ("", i) }
            return (body, after)

        case "left", "right", "displaystyle", "limits", "big", "Big", "bigg", "Bigg":
            return ("", i)

        case "quad":  return ("  ", i)
        case "qquad": return ("    ", i)

        default:
            if let symbol = symbols[name] { return (symbol, i) }
            // Unknown command: show the source rather than silently dropping it.
            return ("\\" + name, i)
        }
    }

    /// Wraps a fraction or root operand in parentheses when it is more than one token.
    private static func parenthesized(_ body: String) -> String {
        let needsBrackets = body.count > 1 && body.contains(where: { !$0.isLetter && !$0.isNumber })
        return needsBrackets ? "(\(body))" : body
    }

    /// Reads `{...}` starting at `from`, honouring nesting. Returns nil when the next
    /// character is not an opening brace.
    private static func braceArgument(_ c: [Character], from: Int) -> (String?, Int) {
        var i = from
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count, c[i] == "{" else { return (nil, from) }

        var depth = 0
        var body = ""
        while i < c.count {
            if c[i] == "{" {
                depth += 1
                if depth == 1 { i += 1; continue }
            } else if c[i] == "}" {
                depth -= 1
                if depth == 0 { return (body, i + 1) }
            }
            body.append(c[i])
            i += 1
        }
        return (body, i)
    }

    /// The operand of `^` or `_`: either a braced group or a single character.
    private static func scriptArgument(_ c: [Character], after: Int) -> (String, Int) {
        if c.indices.contains(after), c[after] == "{",
           case let (body, end) = braceArgument(c, from: after), let body {
            return (body, end)
        }
        var i = after
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count else { return ("", after) }
        if c[i] == "\\" {
            let (text, next) = command(c, at: i)
            return (text, next)
        }
        return (String(c[i]), i + 1)
    }

    // MARK: - Symbol table

    private static let symbols: [String: String] = [
        // Relations and operators
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "ge": "≥", "geq": "≥", "le": "≤", "leq": "≤", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "cdot": "⋅", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "ll": "≪", "gg": "≫", "prec": "≺", "succ": "≻",

        // Structures
        "infty": "∞", "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫",
        "iint": "∬", "oint": "∮", "partial": "∂", "nabla": "∇", "surd": "√",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "triangle": "△",

        // Sets and logic
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
        "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄",
        "land": "∧", "lor": "∨", "neg": "¬", "lnot": "¬",
        "therefore": "∴", "because": "∵",
        "mathbb": "", "aleph": "ℵ",

        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "implies": "⟹", "iff": "⟺",

        // Named functions
        "log": "log", "ln": "ln", "exp": "exp", "sin": "sin", "cos": "cos",
        "tan": "tan", "min": "min", "max": "max", "lim": "lim", "gcd": "gcd",
        "det": "det", "dim": "dim", "deg": "deg", "arg": "arg", "bmod": "mod",

        // Greek, lower case
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",

        // Greek, upper case
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
}
