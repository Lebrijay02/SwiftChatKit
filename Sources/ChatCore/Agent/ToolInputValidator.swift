//
//  ToolInputValidator.swift
//  SwiftChatKit
//

import Foundation

public enum ToolInputError: Error, Equatable, Sendable, LocalizedError {
    case missing(String)
    case unexpected(String)
    case typeMismatch(path: String, expected: String)
    case invalidEnum(path: String, values: [String])

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "Missing required parameter '\(name)'."
        case .unexpected(let name):
            return "Unexpected parameter '\(name)'."
        case .typeMismatch(let path, let expected):
            return "Parameter '\(path)' must be \(expected)."
        case .invalidEnum(let path, let values):
            return "Parameter '\(path)' must be one of: \(values.joined(separator: ", "))."
        }
    }
}

public enum ToolInputValidator {
    public static func validate(_ arguments: [String: ChatValue],
                                against declaration: ToolDeclaration) -> Result<Void, ToolInputError> {
        let optional = Set(declaration.optional)
        for name in declaration.parameters.keys where !optional.contains(name) && arguments[name] == nil {
            return .failure(.missing(name))
        }
        for name in arguments.keys where declaration.parameters[name] == nil {
            return .failure(.unexpected(name))
        }
        for (name, value) in arguments {
            guard let schema = declaration.parameters[name] else { continue }
            if let error = validate(value, against: schema, path: name) { return .failure(error) }
        }
        return .success(())
    }

    private static func validate(_ value: ChatValue,
                                 against schema: ToolSchema,
                                 path: String) -> ToolInputError? {
        switch schema {
        case .string:
            return value.stringValue == nil ? .typeMismatch(path: path, expected: "a string") : nil
        case .enumeration(let values, _):
            guard let string = value.stringValue else {
                return .typeMismatch(path: path, expected: "a string")
            }
            return values.contains(string) ? nil : .invalidEnum(path: path, values: values)
        case .integer:
            return value.intValue == nil ? .typeMismatch(path: path, expected: "an integer") : nil
        case .number:
            return value.doubleValue == nil ? .typeMismatch(path: path, expected: "a number") : nil
        case .boolean:
            return value.boolValue == nil ? .typeMismatch(path: path, expected: "a boolean") : nil
        case .array(let item, _):
            guard let array = value.arrayValue else {
                return .typeMismatch(path: path, expected: "an array")
            }
            for (index, child) in array.enumerated() {
                if let error = validate(child, against: item, path: "\(path)[\(index)]") { return error }
            }
            return nil
        case .object(let properties, let optional, _):
            guard let object = value.objectValue else {
                return .typeMismatch(path: path, expected: "an object")
            }
            let optional = Set(optional)
            for name in properties.keys where !optional.contains(name) && object[name] == nil {
                return .missing("\(path).\(name)")
            }
            for (name, child) in object {
                guard let childSchema = properties[name] else {
                    return .unexpected("\(path).\(name)")
                }
                if let error = validate(child, against: childSchema, path: "\(path).\(name)") { return error }
            }
            return nil
        }
    }
}
