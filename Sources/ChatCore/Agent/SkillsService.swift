//
//  SkillsService.swift
//  SwiftChatKit
//
//  Discovers Agent Skills — `SKILL.md` packages — from a set of search paths.
//  The Claude Code-compatible layout is the default:
//
//    ~/.claude/skills/<name>/SKILL.md          (global)
//    <project>/.claude/skills/<name>/SKILL.md  (local — wins on name collision)
//
//  Skills surface two ways: the model sees name + description in the system
//  prompt and loads the full body on demand via the `useSkill` tool
//  (progressive disclosure), and the user can invoke one directly by typing
//  /skill-name. Loading bodies lazily is the point — a dozen installed skills
//  would otherwise consume the context window before the first turn.
//

import Foundation

// MARK: - Model

public struct AgentSkill: Identifiable, Equatable, Sendable {

    public enum Scope: String, Equatable, Sendable {
        case global = "Global"
        case local = "Local"
    }

    public var id: String { "\(scope.rawValue):\(name)" }
    public let name: String
    public let description: String
    public let scope: Scope
    /// The skill's folder — holds SKILL.md plus any support files it references.
    public let directory: URL

    public init(name: String, description: String, scope: Scope, directory: URL) {
        self.name = name
        self.description = description
        self.scope = scope
        self.directory = directory
    }
}

// MARK: - Configuration

/// Where to look for skills. Injectable so a host can ship its own convention
/// rather than inheriting Claude Code's.
public struct SkillsConfiguration: Sendable {

    /// Directory searched regardless of the working directory.
    public var globalDirectory: URL?
    /// Path appended to the working directory to find project-local skills.
    public var projectRelativePath: String?
    /// Set false to disable skills entirely.
    public var isEnabled: Bool

    public init(globalDirectory: URL? = nil,
                projectRelativePath: String? = nil,
                isEnabled: Bool = true) {
        self.globalDirectory = globalDirectory
        self.projectRelativePath = projectRelativePath
        self.isEnabled = isEnabled
    }

    /// The Claude Code layout: `~/.claude/skills` plus `<project>/.claude/skills`.
    ///
    /// There is no user home directory on iOS, so only the project half applies
    /// there — a sandboxed app has nowhere global to read skills from anyway.
    public static var claudeCompatible: SkillsConfiguration {
        #if os(macOS)
        SkillsConfiguration(
            globalDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/skills", isDirectory: true),
            projectRelativePath: ".claude/skills")
        #else
        SkillsConfiguration(projectRelativePath: ".claude/skills")
        #endif
    }

    public static let disabled = SkillsConfiguration(isEnabled: false)
}

// MARK: - Service

@Observable
@MainActor
public final class SkillsService {

    public nonisolated static let toolName = "useSkill"

    public nonisolated static let declaration = ToolDeclaration(
        name: toolName,
        description: """
        Load the full instructions of an installed skill by name. Skills are listed in the \
        system prompt with a one-line description; when the user's request matches one, call \
        this BEFORE doing the task and follow the returned instructions. The result includes \
        the skill's folder path — read any support files it references with a file-reading \
        tool using that path as the directory.
        """,
        parameters: [
            "name": .string(description: "Exact name of the skill to load, as listed in the system prompt"),
        ])

    public private(set) var skills: [AgentSkill] = []

    private let configuration: SkillsConfiguration

    public init(configuration: SkillsConfiguration = .claudeCompatible) {
        self.configuration = configuration
    }

    // MARK: - Discovery

    /// Rescans the configured directories. Local skills shadow global ones of
    /// the same name, so a project can override a machine-wide skill.
    @discardableResult
    public func refresh(workingDirectory: URL?) -> [AgentSkill] {
        guard configuration.isEnabled else {
            skills = []
            return []
        }

        var found = configuration.globalDirectory.map { scan($0, scope: .global) } ?? []

        if let workingDirectory, let relative = configuration.projectRelativePath {
            let local = scan(workingDirectory.appendingPathComponent(relative, isDirectory: true),
                             scope: .local)
            let localNames = Set(local.map { $0.name.lowercased() })
            found = found.filter { !localNames.contains($0.name.lowercased()) } + local
        }

        skills = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return skills
    }

    /// Case-insensitive lookup — slash commands arrive lowercased.
    public func skill(named name: String) -> AgentSkill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
    }

    /// SKILL.md contents with the YAML frontmatter stripped.
    public func skillBody(_ skill: AgentSkill) throws -> String {
        let file = skill.directory.appendingPathComponent("SKILL.md")
        return Self.stripFrontmatter(try String(contentsOf: file, encoding: .utf8))
    }

    /// Handles a `useSkill` call. Returns the body plus the folder path, so the
    /// model can read the support files a skill references.
    public func execute(_ call: ToolCall) -> ToolResult {
        guard let name = call.arguments["name"]?.stringValue else {
            return .failure(call, "Missing required argument: name")
        }
        guard let skill = skill(named: name) else {
            let installed = skills.map(\.name).joined(separator: ", ")
            return .failure(call, "No skill named '\(name)'. Installed skills: \(installed.isEmpty ? "none" : installed)")
        }
        do {
            return .success(call, [
                "name": .string(skill.name),
                "directory": .string(skill.directory.path),
                "instructions": .string(try skillBody(skill)),
            ])
        } catch {
            return .failure(call, "Could not read SKILL.md for '\(skill.name)': \(error.localizedDescription)")
        }
    }

    private func scan(_ dir: URL, scope: AgentSkill.Scope) -> [AgentSkill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles) else { return [] }

        return entries.compactMap { entry in
            // Installers often symlink skill folders (`npx skills add` links
            // ~/.claude/skills/<name> → ~/.agents/skills/<name>), so resolve
            // before the directory check rather than trusting resource values.
            let folder = entry.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }

            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }

            let meta = Self.parseFrontmatter(raw)
            return AgentSkill(name: meta["name"] ?? folder.lastPathComponent,
                              description: meta["description"] ?? "",
                              scope: scope,
                              directory: folder)
        }
    }

    // MARK: - Prompt section & staleness

    /// System-prompt section listing every installed skill. Empty when none are.
    public func skillsText() -> String {
        guard !skills.isEmpty else { return "" }
        let lines = skills
            .map { "- \($0.name) (\($0.scope.rawValue.lowercased())): \($0.description)" }
            .joined(separator: "\n")
        return """

        # Skills
        The following skills are installed. A skill is a package of instructions for doing a \
        specific kind of task well. When the user's request matches a skill's description, call \
        \(Self.toolName) with its name BEFORE starting the task, then follow the returned \
        instructions. The user can also invoke a skill directly by typing /skill-name; never \
        guess a skill's contents — always load it.
        \(lines)
        """
    }

    /// Fingerprint used to detect skill changes without regenerating the full
    /// prompt text on every comparison.
    public func skillsHash() -> String {
        skills.map { "\($0.scope.rawValue):\($0.name):\($0.description)" }.joined(separator: "|")
    }

    // MARK: - Frontmatter parsing

    /// Extracts single-line `key: value` pairs from the leading `---` fenced YAML
    /// block. Handles quoted values and simple folded scalars (`>-` / `|` with
    /// indented continuation lines).
    public nonisolated static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var meta: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }

            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

                if value == ">-" || value == ">" || value == "|" || value == "|-" {
                    // Folded/literal scalar: consume the following indented lines.
                    var parts: [String] = []
                    var j = i + 1
                    while j < lines.count, lines[j].hasPrefix(" ") || lines[j].hasPrefix("\t") {
                        parts.append(lines[j].trimmingCharacters(in: .whitespaces))
                        j += 1
                    }
                    value = parts.joined(separator: " ")
                    i = j - 1
                } else if value.count >= 2,
                          (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                          (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                meta[key] = value
            }
            i += 1
        }
        return meta
    }

    /// The markdown after the closing `---` of the frontmatter block, if present.
    public nonisolated static func stripFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        for (i, line) in lines.enumerated() where i > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                return lines[(i + 1)...].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
