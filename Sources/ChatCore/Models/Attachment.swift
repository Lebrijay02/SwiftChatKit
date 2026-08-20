//
//  Attachment.swift
//  SwiftChatKit
//
//  Multimodal input. Deliberately `Data` + MIME type rather than a platform
//  image: an `NSImage`-backed attachment cannot cross to iOS, and the encoding
//  decision (JPEG quality, downscaling) belongs to the host that picked the file.
//

import Foundation

public struct Attachment: Identifiable, Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable, Codable {
        case image
        case document
    }

    public let id: UUID
    public let kind: Kind
    /// Raw bytes, already in `mimeType`'s encoding. Backends inline these.
    public let data: Data
    public let mimeType: String
    /// For display only; nil for pasted content that never had a name.
    public let filename: String?

    public init(id: UUID = UUID(),
                kind: Kind,
                data: Data,
                mimeType: String,
                filename: String? = nil) {
        self.id = id
        self.kind = kind
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
    }

    public var isEmpty: Bool { data.isEmpty }

    /// Identity comparison — attachment payloads are large and two distinct
    /// picks of the same file are still two attachments.
    public static func == (lhs: Attachment, rhs: Attachment) -> Bool { lhs.id == rhs.id }
}

// MARK: - Convenience

public extension Attachment {
    static func image(_ data: Data, mimeType: String = "image/jpeg", filename: String? = nil) -> Attachment {
        Attachment(kind: .image, data: data, mimeType: mimeType, filename: filename)
    }

    static func pdf(_ data: Data, filename: String? = nil) -> Attachment {
        Attachment(kind: .document, data: data, mimeType: "application/pdf", filename: filename)
    }

    /// Reads a file and infers its type from the path extension. Returns nil if
    /// the file is unreadable or of a type no backend accepts inline.
    static func contentsOf(_ url: URL) -> Attachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let mime = mimeType(forPathExtension: url.pathExtension) else { return nil }
        return Attachment(kind: mime.hasPrefix("image/") ? .image : .document,
                          data: data,
                          mimeType: mime,
                          filename: url.lastPathComponent)
    }

    private static func mimeType(forPathExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png":         return "image/png"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "heic":        return "image/heic"
        case "pdf":         return "application/pdf"
        default:            return nil
        }
    }
}
