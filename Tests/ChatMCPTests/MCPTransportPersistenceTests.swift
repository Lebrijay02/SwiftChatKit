import Foundation
import Testing
@testable import ChatMCP

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "swiftchatkit.tests.\(UUID().uuidString)")!
}

@Suite("MCPTransport — environment and working directory")
struct MCPTransportPersistenceTests {

    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!

    @Test("A stdio transport carries an environment and a working directory")
    func carriesBoth() {
        let transport = MCPTransport.stdio(
            command: "uv", arguments: ["run", "python", "main.py"],
            environment: ["AZURE_API_KEY": "secret"],
            workingDirectory: URL(fileURLWithPath: "/srv/mcp", isDirectory: true))

        guard case .stdio(let command, let arguments, let environment, let directory) = transport
        else { Issue.record("wrong case"); return }
        #expect(command == "uv")
        #expect(arguments == ["run", "python", "main.py"])
        #expect(environment == ["AZURE_API_KEY": "secret"])
        #expect(directory?.path == "/srv/mcp")
    }

    @Test("The two-argument spelling still means an empty environment")
    func defaultsStayEmpty() {
        guard case .stdio(_, _, let environment, let directory) =
                MCPTransport.stdio(command: "npx", arguments: ["-y", "pkg"])
        else { Issue.record("wrong case"); return }
        #expect(environment.isEmpty)
        #expect(directory == nil)
    }

    // MARK: - Persistence

    @Test("Secrets in the environment are never written out")
    func environmentIsNotPersisted() throws {
        let transport = MCPTransport.stdio(command: "uv", arguments: [],
                                           environment: ["AWS_SECRET_ACCESS_KEY": "hunter2"])
        let data = try JSONEncoder().encode(transport)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("hunter2"))
        #expect(!json.contains("AWS_SECRET_ACCESS_KEY"))

        guard case .stdio(_, _, let decoded, _) =
                try JSONDecoder().decode(MCPTransport.self, from: data)
        else { Issue.record("wrong case"); return }
        #expect(decoded.isEmpty)
    }

    @Test("The working directory does round-trip")
    func workingDirectoryPersists() throws {
        let transport = MCPTransport.stdio(
            command: "uv", arguments: [],
            workingDirectory: URL(fileURLWithPath: "/srv/mcp", isDirectory: true))
        let decoded = try JSONDecoder().decode(
            MCPTransport.self, from: try JSONEncoder().encode(transport))

        guard case .stdio(_, _, _, let directory) = decoded else { Issue.record("wrong case"); return }
        #expect(directory?.path == "/srv/mcp")
    }

    @Test("An HTTP transport is unaffected")
    func httpRoundTrips() throws {
        let transport = MCPTransport.http(url: URL(string: "https://example.com/mcp")!,
                                          auth: .bearer(token: "t"))
        let decoded = try JSONDecoder().decode(
            MCPTransport.self, from: try JSONEncoder().encode(transport))
        #expect(decoded == transport)
    }

    @Test("A server list written before this change still loads")
    func decodesLegacyPayload() throws {
        // Exactly what the synthesized conformance used to write: no
        // `environment`, no `workingDirectory`. Dropping such a server would
        // lose the user's configuration on upgrade.
        let legacy = Data("""
        [{"id":"\(id.uuidString)","name":"Docs","enabled":true,
          "transport":{"stdio":{"command":"npx","arguments":["-y","pkg"]}}}]
        """.utf8)

        let configs = try JSONDecoder().decode([MCPServerConfig].self, from: legacy)
        #expect(configs.count == 1)
        guard case .stdio(let command, let arguments, let environment, let directory)? =
                configs.first?.transport else { Issue.record("wrong case"); return }
        #expect(command == "npx")
        #expect(arguments == ["-y", "pkg"])
        #expect(environment.isEmpty)
        #expect(directory == nil)
        #expect(configs[0].requestTimeoutSeconds == nil)
    }

    @Test("A seed's environment is restored onto the stored server on every launch")
    func seedRestoresEnvironment() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        let seed = MCPServerConfig(
            id: id, name: "Frida",
            transport: .stdio(command: "uv", arguments: ["run"],
                              environment: ["AZURE_API_KEY": "from-keychain"]))

        // First launch stores it — without the secrets.
        _ = store.loadOrSeed(with: [seed])
        guard case .stdio(_, _, let stored, _)? = store.load().first?.transport
        else { Issue.record("wrong case"); return }
        #expect(stored.isEmpty)

        // Second launch: the host supplies them again and they rejoin the
        // config the user has been editing.
        let merged = store.loadOrSeed(with: [seed])
        guard case .stdio(_, _, let environment, _)? = merged.first?.transport
        else { Issue.record("wrong case"); return }
        #expect(environment == ["AZURE_API_KEY": "from-keychain"])
    }

    @Test("Restoring an environment leaves the user's own edits alone")
    func seedDoesNotOverwriteEdits() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        let seed = MCPServerConfig(
            id: id, name: "Frida",
            transport: .stdio(command: "uv", arguments: ["run"],
                              environment: ["KEY": "value"]))
        store.save([MCPServerConfig(id: id, name: "Renamed",
                                    transport: .stdio(command: "uv", arguments: ["run", "--verbose"]),
                                    enabled: false)])

        let merged = store.loadOrSeed(with: [seed])
        #expect(merged.count == 1)
        #expect(merged[0].name == "Renamed")
        #expect(merged[0].enabled == false)
        guard case .stdio(_, let arguments, let environment, _) = merged[0].transport
        else { Issue.record("wrong case"); return }
        #expect(arguments == ["run", "--verbose"])
        #expect(environment == ["KEY": "value"])
    }

    // MARK: - Standard config format

    @Test("`env` and `cwd` are read from a standard mcpServers file")
    func importsEnvAndCwd() {
        let json = Data("""
        {"mcpServers": {"frida": {
            "command": "uv", "args": ["run", "main.py"],
            "env": {"PYTHONUNBUFFERED": "1"},
            "cwd": "/srv/frida-mcp"
        }}}
        """.utf8)

        let configs = MCPServerConfig.decodeMCPServers(from: json)
        guard case .stdio(_, _, let environment, let directory)? = configs.first?.transport
        else { Issue.record("wrong case"); return }
        #expect(environment == ["PYTHONUNBUFFERED": "1"])
        #expect(directory?.path == "/srv/frida-mcp")
    }
}
