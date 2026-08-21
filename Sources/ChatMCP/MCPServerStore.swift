//
//  MCPServerStore.swift
//  SwiftChatKit
//
//  Persistence for the server list. The storage key and the seed list are both
//  injected — a package that hardcoded either would leak one host's setup into
//  every other host.
//

import Foundation

/// `@unchecked` because `UserDefaults` is not marked `Sendable` even though it
/// is documented as thread-safe.
public struct MCPServerStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "swiftchatkit.mcp.servers.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [MCPServerConfig] {
        guard let data = defaults.data(forKey: key),
              let configs = try? JSONDecoder().decode([MCPServerConfig].self, from: data)
        else { return [] }
        return configs
    }

    public func save(_ configs: [MCPServerConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: key)
    }

    /// Returns the stored list, seeding it on first run and merging in any
    /// seed the host has added since — matched by id, so a seed the user
    /// disabled stays disabled rather than reappearing switched on.
    public func loadOrSeed(with seeds: [MCPServerConfig]) -> [MCPServerConfig] {
        var stored = load()
        guard !stored.isEmpty else {
            save(seeds)
            return seeds
        }
        let existing = Set(stored.map(\.id))
        let missing = seeds.filter { !existing.contains($0.id) }
        guard !missing.isEmpty else { return stored }
        stored.append(contentsOf: missing)
        save(stored)
        return stored
    }
}

// MARK: - Standard config format

public extension MCPServerConfig {

    /// Decodes the `mcpServers` format shared by Claude Desktop, VS Code and
    /// most MCP tooling, so a host can import an existing config verbatim:
    ///
    /// ```json
    /// { "mcpServers": { "name": { "command": "npx", "args": ["-y", "pkg"] } } }
    /// ```
    ///
    /// Entries carrying a `url` instead of a `command` are read as HTTP servers.
    /// Anything unrecognised is skipped rather than failing the whole import —
    /// these files routinely contain keys this package knows nothing about.
    static func decodeMCPServers(from data: Data) -> [MCPServerConfig] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any]
        else { return [] }

        return servers.compactMap { name, value -> MCPServerConfig? in
            guard let entry = value as? [String: Any] else { return nil }
            // A disabled entry is still worth importing — the user can flip it on.
            let enabled = !(entry["disabled"] as? Bool ?? false)

            if let command = entry["command"] as? String {
                let arguments = entry["args"] as? [String] ?? []
                return MCPServerConfig(name: name,
                                       transport: .stdio(command: command, arguments: arguments),
                                       enabled: enabled)
            }
            if let urlString = entry["url"] as? String, let url = URL(string: urlString) {
                let auth: MCPAuth = (entry["headers"] as? [String: String])?["Authorization"]
                    .flatMap { header in
                        header.hasPrefix("Bearer ")
                            ? .bearer(token: String(header.dropFirst("Bearer ".count)))
                            : nil
                    } ?? .none
                return MCPServerConfig(name: name,
                                       transport: .http(url: url, auth: auth),
                                       enabled: enabled)
            }
            return nil
        }
        .sorted { $0.name < $1.name }
    }
}
