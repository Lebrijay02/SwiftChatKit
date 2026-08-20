//
//  ChatValue.swift
//  SwiftChatKit
//
//  The package's own JSON value. Tool arguments, tool results and persisted
//  payloads all speak this type so that no backend SDK's value type leaks into
//  a tool signature — swapping backends must not ripple into every tool.
//
//  The case set matches the shape backends already use, so conversion at the
//  boundary (see ChatGemini) is total and lossless in both directions.
//

import Foundation

public enum ChatValue: Equatable, Sendable, Hashable {
    case null
    case bool(Bool)
    /// All numbers are doubles, matching JSON. Use `intValue` to read one back
    /// as an integer when the schema promised an integer.
    case number(Double)
    case string(String)
    case array([ChatValue])
    case object([String: ChatValue])
}

// MARK: - Reading

public extension ChatValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Nil rather than a silent truncation when the value has a fractional part.
    var intValue: Int? {
        guard case .number(let n) = self, n.rounded() == n else { return nil }
        return Int(n)
    }

    var arrayValue: [ChatValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: ChatValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Member lookup on an object value; nil for every other case.
    subscript(key: String) -> ChatValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
}

// MARK: - Writing

extension ChatValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension ChatValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension ChatValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension ChatValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension ChatValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension ChatValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: ChatValue...) { self = .array(elements) }
}

extension ChatValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ChatValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension ChatValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([ChatValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: ChatValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let b):   try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - JSON bridging

public extension ChatValue {
    /// Builds a value from `JSONSerialization` output, so callers can hand over
    /// a decoded payload without walking it themselves.
    init(json: Any) {
        switch json {
        case is NSNull:                       self = .null
        case let n as NSNumber:
            // NSNumber erases Bool, so ask the underlying type before reading.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String:                 self = .string(s)
        case let a as [Any]:                  self = .array(a.map { ChatValue(json: $0) })
        case let o as [String: Any]:          self = .object(o.mapValues { ChatValue(json: $0) })
        default:                              self = .null
        }
    }

    /// The `JSONSerialization`-compatible representation.
    var jsonObject: Any {
        switch self {
        case .null:          return NSNull()
        case .bool(let b):   return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a):  return a.map(\.jsonObject)
        case .object(let o): return o.mapValues(\.jsonObject)
        }
    }

    /// Sorted keys, so persisted sessions diff cleanly between writes.
    func jsonString(prettyPrinted: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Parses a JSON document. Returns nil for malformed input — models do emit
    /// truncated tool arguments, and that has to be a recoverable case.
    static func parse(_ text: String) -> ChatValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ChatValue.self, from: data)
    }
}
