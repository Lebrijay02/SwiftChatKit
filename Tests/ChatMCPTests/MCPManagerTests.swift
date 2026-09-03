import Foundation
import Testing
import MCP
import ChatCore
@testable import ChatMCP

/// Hands out a fresh `ScriptedTransport` per connect and keeps the latest one
/// per server, so a test can inspect traffic after a reconnect.
actor TransportRegistry {
    private var scripts: [UUID: [ScriptedTransport.Tool]] = [:]
    private var behaviours: [UUID: [String: ScriptedTransport.Behaviour]] = [:]
    private(set) var latest: [UUID: ScriptedTransport] = [:]
    private(set) var connectCount = 0

    func register(_ id: UUID,
                  tools: [ScriptedTransport.Tool],
                  behaviours: [String: ScriptedTransport.Behaviour] = [:]) {
        scripts[id] = tools
        self.behaviours[id] = behaviours
    }

    func make(for config: MCPServerConfig) -> ScriptedTransport {
        connectCount += 1
        let transport = ScriptedTransport(tools: scripts[config.id] ?? [],
                                          behaviours: behaviours[config.id] ?? [:])
        latest[config.id] = transport
        return transport
    }

    func transport(for id: UUID) -> ScriptedTransport? { latest[id] }

    var factory: MCPTransportFactory {
        { [self] config, _ in await make(for: config) }
    }
}

private func makeConfig(_ name: String, id: UUID = UUID()) -> MCPServerConfig {
    MCPServerConfig(id: id, name: name, transport: .stdio(command: "unused", arguments: []))
}

private func makeStore() -> MCPServerStore {
    MCPServerStore(defaults: UserDefaults(suiteName: "sck.mcp.\(UUID().uuidString)")!)
}

@Suite("MCPManager — connection and discovery")
struct MCPManagerConnectionTests {

    @Test("Connecting discovers tools and reports connected")
    func connectAndDiscover() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read"), .init("write")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        #expect(await manager.statuses[config.id]?.state == .connected)
        #expect(await manager.statuses[config.id]?.toolCount == 2)
        #expect(await manager.declarations.map(\.name) == ["read", "write"])
    }

    @Test("A disabled server is neither launched nor exposed")
    func disabledServer() async {
        var config = makeConfig("Files")
        config.enabled = false
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        #expect(await manager.statuses[config.id]?.state == .disconnected)
        #expect(await manager.declarations.isEmpty)
        #expect(await registry.connectCount == 0)
    }

    @Test("A failing connect is reported without taking the manager down")
    func failedConnect() async {
        let good = makeConfig("Good")
        let bad = makeConfig("Bad")
        let registry = TransportRegistry()
        await registry.register(good.id, tools: [.init("read")])

        let manager = MCPManager(
            store: makeStore(), seedServers: [good, bad],
            transportFactory: { config, _ in
                guard config.id == good.id else { throw MCPBridgeError.notConnected }
                return await registry.make(for: config)
            })
        await manager.loadAndConnectEnabled()

        #expect(await manager.statuses[good.id]?.state == .connected)
        if case .failed = await manager.statuses[bad.id]?.state {} else {
            Issue.record("expected the bad server to be marked failed")
        }
        // The healthy server's tools must still be available.
        #expect(await manager.declarations.map(\.name) == ["read"])
    }

    @Test("An OAuth server with no authorization provider is marked as needing auth")
    func oauthNeedsAuth() async {
        let config = MCPServerConfig(
            name: "Remote",
            transport: .http(url: URL(string: "https://example.com/mcp")!, auth: .oauth))
        let manager = MCPManager(store: makeStore(), seedServers: [config])
        await manager.loadAndConnectEnabled()

        #expect(await manager.statuses[config.id]?.state == .needsAuth)
    }

    @Test("Disabling a connected server disconnects it and withdraws its tools")
    func toggleEnabled() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()
        #expect(await manager.declarations.count == 1)

        await manager.setEnabled(config.id, false)
        #expect(await manager.declarations.isEmpty)
        #expect(await manager.handles("read") == false)
        #expect(await manager.statuses[config.id]?.state == .disconnected)
    }

    @Test("Status changes are delivered to the host")
    func statusObserver() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let recorder = StatusRecorder()
        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory,
                                 onStatusChange: { snapshot in recorder.record(snapshot) })
        await manager.loadAndConnectEnabled()

        // The callback hops to the main actor, so let it drain. Polled rather
        // than slept on a fixed deadline: under a loaded parallel test run the
        // hop can take longer than any figure short enough to be worth waiting.
        var drained = false
        for _ in 0..<200 where !drained {
            if await recorder.sawConnected { drained = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(drained)
    }

    @Test("The tool list version changes when the connected set does")
    func declarationsVersionBumps() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        let before = await manager.declarationsVersion
        await manager.loadAndConnectEnabled()
        // Without this the session would keep sending a stale tool list.
        #expect(await manager.declarationsVersion > before)
    }
}

@Suite("MCPManager — routing and naming")
struct MCPManagerRoutingTests {

    @Test("A colliding tool name is namespaced by server, in list order")
    func namespacesCollisions() async {
        let first = makeConfig("Alpha")
        let second = makeConfig("Beta Server")
        let registry = TransportRegistry()
        await registry.register(first.id, tools: [.init("read")])
        await registry.register(second.id, tools: [.init("read"), .init("write")])

        let manager = MCPManager(store: makeStore(), seedServers: [first, second],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        // The first server in the list keeps the bare name; the second's copy is
        // prefixed with its sanitised server name.
        #expect(await Set(manager.declarations.map(\.name)) == ["read", "Beta_Server_read", "write"])
    }

    @Test("Names stay stable across a reconnect")
    func namesAreStable() async {
        let first = makeConfig("Alpha")
        let second = makeConfig("Beta")
        let registry = TransportRegistry()
        await registry.register(first.id, tools: [.init("read")])
        await registry.register(second.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [first, second],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()
        let before = await Set(manager.declarations.map(\.name))

        // Reconnecting the first server must not hand its bare name to the
        // second — the model would be left holding a name that no longer exists.
        await manager.connect(first)
        #expect(await Set(manager.declarations.map(\.name)) == before)
    }

    @Test("A call is routed to its owning server under the original name")
    func routesToOwner() async {
        let first = makeConfig("Alpha")
        let second = makeConfig("Beta")
        let registry = TransportRegistry()
        await registry.register(first.id, tools: [.init("read")], behaviours: ["read": .text("from alpha")])
        await registry.register(second.id, tools: [.init("read")], behaviours: ["read": .text("from beta")])

        let manager = MCPManager(store: makeStore(), seedServers: [first, second],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        let result = await manager.execute(ToolCall(name: "Beta_read", arguments: [:]))
        #expect(result.payload["result"]?.stringValue == "from beta")

        // The server must be asked for "read", not the namespaced name.
        let calls = await registry.transport(for: second.id)?.receivedCalls ?? []
        #expect(calls.map(\.name) == ["read"])
    }

    @Test("An unknown tool is reported rather than crashing")
    func unknownTool() async {
        let manager = MCPManager(store: makeStore())
        let result = await manager.execute(ToolCall(name: "nope", arguments: [:]))
        #expect(result.errorMessage?.contains("nope") == true)
    }
}

@Suite("MCPManager — execution")
struct MCPManagerExecutionTests {

    @Test("A tool result comes back as data")
    func execute() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")], behaviours: ["read": .text("contents")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        let result = await manager.execute(ToolCall(name: "read", arguments: ["path": .string("a")]))
        #expect(result.errorMessage == nil)
        #expect(result.payload["result"]?.stringValue == "contents")
    }

    @Test("A server-reported tool error reaches the model as an error")
    func toolErrorBecomesFailure() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")],
                                behaviours: ["read": .toolError("no such file")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        // It must be a failure the model can read and recover from, not a
        // success whose text happens to describe a problem.
        let result = await manager.execute(ToolCall(name: "read", arguments: [:]))
        #expect(result.errorMessage == "no such file")
    }

    @Test("A dead server is reconnected once and the call retried")
    func reconnectsAndRetries() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")], behaviours: ["read": .text("ok")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        // Simulate the stdio child crashing between calls.
        await registry.transport(for: config.id)?.die()

        let result = await manager.execute(ToolCall(name: "read", arguments: [:]))
        #expect(result.payload["result"]?.stringValue == "ok")
        #expect(await registry.connectCount == 2)
    }

    @Test("MCP tools are never auto-allowed and default to mutating")
    func permissionPosture() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read"), .init("write")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        #expect(manager.autoAllowedToolNames.isEmpty)
        // The package cannot know what a third-party tool does, so plan mode
        // has to assume the worst.
        #expect(await manager.mutatingToolNames == ["read", "write"])

        await manager.setReadOnly(["read"])
        #expect(await manager.mutatingToolNames == ["write"])
    }

    @Test("The approval card names the server and shows the arguments")
    func approvalCard() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        let card = await manager.approvalCard(for: ToolCall(name: "read",
                                                            arguments: ["path": .string("a.txt")]))
        #expect(card?.title == "Files: read")
        #expect(card?.detail.contains("a.txt") == true)
    }
}

// MARK: - Helpers

@MainActor
private final class StatusRecorder: @unchecked Sendable {
    private var snapshots: [[UUID: MCPServerStatus]] = []

    nonisolated func record(_ snapshot: [UUID: MCPServerStatus]) {
        Task { @MainActor in self.snapshots.append(snapshot) }
    }

    var sawConnected: Bool {
        snapshots.contains { $0.values.contains { $0.state == .connected } }
    }
}

@Suite("MCPManager — recovery")
struct MCPManagerRecoveryTests {

    @Test("Force restarting relaunches the server and rediscovers its tools")
    func forceRestartReconnects() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read"), .init("write")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()
        #expect(await registry.connectCount == 1)

        await manager.forceRestart(config.id)

        #expect(await registry.connectCount == 2)
        #expect(await manager.statuses[config.id]?.state == .connected)
        // The tools must come back under the same names: a restart that renamed
        // them would strand whatever the model already knows about them.
        #expect(await manager.declarations.map(\.name) == ["read", "write"])
    }

    @Test("Force restarting a server the manager doesn't know is a no-op")
    func forceRestartUnknownServer() async {
        let config = makeConfig("Files")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        await manager.forceRestart(UUID())

        #expect(await registry.connectCount == 1)
        #expect(await manager.statuses[config.id]?.state == .connected)
    }

    @Test("A call arriving mid-handshake waits for the server instead of failing")
    func waitUntilReadyWaitsOutTheHandshake() async throws {
        let config = makeConfig("Slow")
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("read")])

        let manager = MCPManager(
            store: makeStore(), seedServers: [config],
            transportFactory: { config, _ in
                try await Task.sleep(for: .milliseconds(200))
                return await registry.make(for: config)
            })

        let connecting = Task { await manager.loadAndConnectEnabled() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await manager.statuses[config.id]?.state == .connecting)

        #expect(await manager.waitUntilReady(config.id) == true)
        await connecting.value
    }

    @Test("Waiting gives up at the deadline rather than blocking the turn forever")
    func waitUntilReadyTimesOut() async throws {
        let config = makeConfig("Wedged")
        let manager = MCPManager(
            store: makeStore(), seedServers: [config],
            transportFactory: { _, _ in
                try await Task.sleep(for: .seconds(30))
                throw MCPBridgeError.notConnected
            })

        let connecting = Task { await manager.loadAndConnectEnabled() }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await manager.waitUntilReady(config.id, timeout: .milliseconds(200)) == false)
        connecting.cancel()
    }

    @Test("Waiting on a server that failed to connect returns immediately")
    func waitUntilReadyOnFailedServer() async {
        let config = makeConfig("Bad")
        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 transportFactory: { _, _ in throw MCPBridgeError.notConnected })
        await manager.loadAndConnectEnabled()

        #expect(await manager.waitUntilReady(config.id) == false)
    }

    @Test("Waiting on an unknown server returns false rather than hanging")
    func waitUntilReadyOnUnknownServer() async {
        let manager = MCPManager(store: makeStore())
        #expect(await manager.waitUntilReady(UUID()) == false)
    }
}
