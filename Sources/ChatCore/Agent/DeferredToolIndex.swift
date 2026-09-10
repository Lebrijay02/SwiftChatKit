//
//  DeferredToolIndex.swift
//  SwiftChatKit
//
//  Ranks withheld tools against a plain-language query for `toolSearch`.
//
//  Deliberately a keyword score rather than anything cleverer: the corpus is a
//  handful of tool descriptions the host wrote, the query is a sentence the
//  model wrote, and an embedding model to compare them would cost more than the
//  tokens the whole mechanism exists to save.
//

import Foundation

enum DeferredToolIndex {

    /// Most tools returned by one search. A search that loads twenty schemas has
    /// undone the saving it was called to produce.
    static let maxResults = 8

    /// Words carried by nearly every tool description, so matching on them ranks
    /// everything equally and tells the model nothing.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "for", "on", "with",
        "is", "it", "this", "that", "you", "your", "use", "used", "using",
        "tool", "tools", "call", "calls", "when", "from", "at", "by", "as",
        "be", "can", "will", "into", "new", "up", "do", "does", "not"
    ]

    /// Scored best-first. An empty query returns everything, which is how the
    /// model asks "what else is there?".
    static func search(_ query: String, in candidates: [ToolDeclaration]) -> [ToolDeclaration] {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return Array(candidates.prefix(maxResults)) }

        var scored: [(tool: ToolDeclaration, score: Int)] = []
        for candidate in candidates {
            let value = score(candidate, terms: terms)
            if value > 0 { scored.append((tool: candidate, score: value)) }
        }

        // Name ties broken alphabetically, so repeated searches are stable.
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.tool.name < rhs.tool.name : lhs.score > rhs.score
        }

        return scored.prefix(maxResults).map { $0.tool }
    }

    /// A hit in the name is worth far more than one in the description: a tool
    /// called `indexWorkspace` matching "index" is almost certainly the answer,
    /// where a tool that merely mentions indexing in passing is not.
    private static func score(_ tool: ToolDeclaration, terms: Set<String>) -> Int {
        let nameTokens = tokenize(splitCamelCase(tool.name))
        let descriptionTokens = tokenize(tool.description)

        var total = 0
        for term in terms {
            if nameTokens.contains(term) {
                total += 5
            } else if nameTokens.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
                total += 3
            }
            if descriptionTokens.contains(term) { total += 1 }
        }
        return total
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// `createXcodeProject` → `create Xcode Project`, so a query saying "create
    /// project" can reach it.
    private static func splitCamelCase(_ name: String) -> String {
        var out = ""
        for character in name {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        return out
    }

    // MARK: - Rendering

    /// A compact signature per tool. The authoritative schema arrives with the
    /// next request — this only has to be precise enough for the model to decide
    /// which tool it wants, so spending a full JSON Schema here would pay the
    /// token cost the deferral exists to avoid.
    static func summary(of tool: ToolDeclaration) -> String {
        let optional = Set(tool.optional)
        let parameters = tool.parameters
            .sorted { lhs, rhs in
                // Required first, then alphabetical — the reading order that
                // makes a signature scannable.
                let lhsOptional = optional.contains(lhs.key)
                let rhsOptional = optional.contains(rhs.key)
                return lhsOptional == rhsOptional ? lhs.key < rhs.key : !lhsOptional
            }
            .map { name, schema -> String in
                let rendered = "\(name): \(typeName(schema))"
                return optional.contains(name) ? "[\(rendered)]" : rendered
            }
            .joined(separator: ", ")

        return "\(tool.name)(\(parameters))\n    \(firstSentence(of: tool.description))"
    }

    private static func typeName(_ schema: ToolSchema) -> String {
        switch schema {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .enumeration(let values, _): return values.joined(separator: "|")
        case .array(let items, _): return "\(typeName(items))[]"
        case .object: return "object"
        }
    }

    /// Descriptions are written as several sentences of guidance; the first one
    /// says what the tool is, which is all a search result needs.
    private static func firstSentence(of description: String) -> String {
        let flattened = description
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let end = flattened.firstIndex(of: ".") else { return flattened }
        return String(flattened[...end])
    }
}
