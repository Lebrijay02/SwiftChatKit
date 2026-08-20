//
//  FileToolError.swift
//  SwiftChatKit
//

import Foundation

public enum FileToolError: LocalizedError, Equatable {
    case notFound(String)
    case notADirectory(String)
    case notUTF8(String)
    case destinationExists(String)
    case editTextNotFound(oldText: String, path: String)
    case invalidRegex(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No such file or directory: \(path)"
        case .notADirectory(let path):
            return "Not a directory: \(path)"
        case .notUTF8(let path):
            return "File is not valid UTF-8 text: \(path). Use readMediaFile for binary files."
        case .destinationExists(let path):
            return "Destination already exists: \(path)"
        case .editTextNotFound(let oldText, let path):
            let preview = oldText.count > 120 ? String(oldText.prefix(120)) + "…" : oldText
            return "Could not find the text to replace in \(path). Searched for:\n\(preview)"
        case .invalidRegex(let pattern):
            return "Invalid regular expression: \(pattern)"
        }
    }
}
