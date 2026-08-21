//
//  FileDiffPreviewView.swift
//  SwiftChatKit
//
//  A GitHub-style diff viewer with line numbers, used by the approval card so a
//  write or edit can be judged on what it actually changes rather than on raw
//  JSON arguments.
//

import SwiftUI

public struct DiffLine: Identifiable {
    public let id = UUID()
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let type: LineType
    public let text: String

    public enum LineType {
        case added
        case removed
        case normal
        case header
    }
}

public struct FileDiffPreviewView: View {

    @Environment(\.chatPalette) private var palette

    public let title: String
    public let additions: Int
    public let deletions: Int
    public let diffLines: [DiffLine]

    /// Reads the unified-ish output `FileSystemProviding.edit` returns.
    public init(title: String, rawDiff: String) {
        self.title = title
        let parsed = Self.parse(rawDiff: rawDiff)
        self.diffLines = parsed.lines
        self.additions = parsed.additions
        self.deletions = parsed.deletions
    }

    /// A whole-file write: every line is an addition.
    public init(title: String, writeFileContent: String) {
        self.title = title
        let parsed = Self.parseWriteFile(content: writeFileContent)
        self.diffLines = parsed.lines
        self.additions = parsed.additions
        self.deletions = 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(palette.divider)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { line in
                        row(line)
                    }
                }
            }
            .background(palette.codeBackground.opacity(0.4))
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.outline, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(palette.primaryText)

            Spacer()

            if additions > 0 || deletions > 0 {
                HStack(spacing: 6) {
                    if additions > 0 {
                        Text("Added \(additions) line\(additions == 1 ? "" : "s")")
                            .foregroundColor(.green)
                    }
                    if deletions > 0 {
                        Text("removed \(deletions) line\(deletions == 1 ? "" : "s")")
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
                .fontWeight(.medium)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.header)
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 35, alignment: .trailing)
                    .padding(.trailing, 8)

                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 35, alignment: .trailing)
                    .padding(.trailing, 8)

                Text(marker(for: line.type))
                    .frame(width: 15, alignment: .center)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(palette.secondaryText)
            .padding(.vertical, 2)
            .background(palette.codeBackground)

            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(palette.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(backgroundColor(for: line.type))
    }

    private func marker(for type: DiffLine.LineType) -> String {
        switch type {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }

    private func backgroundColor(for type: DiffLine.LineType) -> Color {
        switch type {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .header: return Color.blue.opacity(0.06)
        case .normal: return Color.clear
        }
    }

    // MARK: - Parsing

    nonisolated static func parse(rawDiff: String) -> (lines: [DiffLine], additions: Int, deletions: Int) {
        var lines: [DiffLine] = []
        var additions = 0
        var deletions = 0
        var oldCounter = 1
        var newCounter = 1

        for line in rawDiff.components(separatedBy: .newlines) {
            if line.hasPrefix("---") || line.hasPrefix("+++") {
                continue
            } else if line.hasPrefix("@@") {
                lines.append(DiffLine(oldLineNumber: nil, newLineNumber: nil, type: .header, text: line))
            } else if line.hasPrefix("+") {
                let text = String(line.dropFirst()).trimmingCharacters(in: .newlines)
                lines.append(DiffLine(oldLineNumber: nil, newLineNumber: newCounter, type: .added, text: text))
                newCounter += 1
                additions += 1
            } else if line.hasPrefix("-") {
                let text = String(line.dropFirst()).trimmingCharacters(in: .newlines)
                lines.append(DiffLine(oldLineNumber: oldCounter, newLineNumber: nil, type: .removed, text: text))
                oldCounter += 1
                deletions += 1
            } else {
                let clean = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append(DiffLine(oldLineNumber: oldCounter, newLineNumber: newCounter, type: .normal, text: clean))
                oldCounter += 1
                newCounter += 1
            }
        }

        return (lines, additions, deletions)
    }

    nonisolated static func parseWriteFile(content: String) -> (lines: [DiffLine], additions: Int, deletions: Int) {
        let rawLines = content.components(separatedBy: .newlines)
        let lines = rawLines.enumerated().map {
            DiffLine(oldLineNumber: nil, newLineNumber: $0.offset + 1, type: .added, text: $0.element)
        }
        return (lines, rawLines.count, 0)
    }
}
