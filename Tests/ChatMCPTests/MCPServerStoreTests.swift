import Foundation
import Testing
@testable import ChatMCP

private func isolatedDefaults() -> UserDefaults {
    let suite = "swiftchatkit.tests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

private let seedA = MCPServerConfig(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
    name: "A", transport: .stdio(command: "npx", arguments: ["a"]))
private let seedB = MCPServerConfig(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
    name: "B", transport: .stdio(command: "npx", arguments: ["b"]))

@Suite("MCPServerStore")
struct MCPServerStoreTests {

    @Test("Servers round-trip through storage")
    func roundTrip() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        store.save([seedA])
        #expect(store.load() == [seedA])
    }

    @Test("An empty store is seeded on first run")
    func seedsOnFirstRun() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        #expect(store.loadOrSeed(with: [seedA, seedB]) == [seedA, seedB])
        #expect(store.load().count == 2)
    }

    @Test("A seed added later is merged in")
    func mergesNewSeeds() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        _ = store.loadOrSeed(with: [seedA])
        let merged = store.loadOrSeed(with: [seedA, seedB])
        #expect(merged.map(\.id) == [seedA.id, seedB.id])
    }

    @Test("A seed the user disabled stays disabled")
    func respectsUserChanges() {
        let store = MCPServerStore(defaults: isolatedDefaults())
        _ = store.loadOrSeed(with: [seedA])
        var disabled = seedA
        disabled.enabled = false
        store.save([disabled])

        // Re-seeding must not switch it back on: matching is by id, and the
        // stored entry wins.
        #expect(store.loadOrSeed(with: [seedA])[0].enabled == false)
    }

    @Test("Storage keys are independent")
    func separateKeys() {
        let defaults = isolatedDefaults()
        MCPServerStore(defaults: defaults, key: "one").save([seedA])
        #expect(MCPServerStore(defaults: defaults, key: "two").load().isEmpty)
    }
}

@Suite("mcpServers config import")
struct MCPServersConfigTests {

    private func decode(_ json: String) -> [MCPServerConfig] {
        MCPServerConfig.decodeMCPServers(from: Data(json.utf8))
    }

    @Test("A stdio entry is read with its command and arguments")
    func stdioEntry() {
        let configs = decode(#"{"mcpServers":{"files":{"command":"npx","args":["-y","pkg"]}}}"#)
        #expect(configs.count == 1)
        #expect(configs[0].name == "files")
        #expect(configs[0].transport == .stdio(command: "npx", arguments: ["-y", "pkg"]))
    }

    @Test("A url entry is read as an HTTP server")
    func httpEntry() {
        let configs = decode(#"{"mcpServers":{"remote":{"url":"https://example.com/mcp"}}}"#)
        #expect(configs[0].transport == .http(url: URL(string: "https://example.com/mcp")!, auth: .none))
    }

    @Test("A bearer Authorization header becomes bearer auth")
    func bearerHeader() {
        let configs = decode("""
            {"mcpServers":{"remote":{"url":"https://example.com/mcp",
             "headers":{"Authorization":"Bearer secret"}}}}
            """)
        #expect(configs[0].transport == .http(url: URL(string: "https://example.com/mcp")!,
                                              auth: .bearer(token: "secret")))
    }

    @Test("A disabled entry is imported switched off rather than skipped")
    func disabledEntry() {
        let configs = decode(#"{"mcpServers":{"x":{"command":"npx","disabled":true}}}"#)
        #expect(configs[0].enabled == false)
    }

    @Test("Unrecognised entries are skipped, not fatal")
    func skipsUnknown() {
        // These files routinely carry keys this package knows nothing about.
        let configs = decode(#"{"mcpServers":{"good":{"command":"npx"},"bad":{"type":"weird"}}}"#)
        #expect(configs.map(\.name) == ["good"])
    }

    @Test("Results are ordered by name, so an import is reproducible")
    func sorted() {
        let configs = decode(#"{"mcpServers":{"z":{"command":"a"},"a":{"command":"a"}}}"#)
        #expect(configs.map(\.name) == ["a", "z"])
    }

    @Test("Malformed JSON yields nothing")
    func malformed() {
        #expect(decode("not json").isEmpty)
        #expect(decode("{}").isEmpty)
    }
}
