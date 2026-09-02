import Foundation
import Testing
import MCP
import ChatCore
@testable import ChatMCP

/// Collects progress updates delivered on the main actor.
@MainActor
private final class ProgressRecorder {
    var updates: [MCPToolProgress] = []
    func record(_ update: MCPToolProgress) { updates.append(update) }
}

private func makeStore() -> MCPServerStore {
    MCPServerStore(defaults: UserDefaults(suiteName: "sck.mcp.\(UUID().uuidString)")!)
}

@Suite("MCPClient — timeouts, cancellation and progress")
struct MCPRequestControlTests {

    @Test("A silent server gives up at the configured deadline, not at two minutes")
    func requestTimeoutIsHonoured() async throws {
        let transport = ScriptedTransport(tools: [.init("swarm")],
                                          behaviours: ["swarm": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .milliseconds(100))
        try await client.start()

        let started = ContinuousClock.now
        await #expect(throws: MCPBridgeError.self) {
            try await client.callTool(name: "swarm", arguments: [:])
        }
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test("A long call outlives the default deadline when the timeout allows it")
    func longCallSurvives() async throws {
        let transport = ScriptedTransport(tools: [.init("swarm")],
                                          behaviours: ["swarm": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .seconds(30))
        try await client.start()

        // Nothing answers, so the only way this returns early is the deadline.
        // At 30s it must still be waiting well past the point a 100ms one gave up.
        let call = Task { try await client.callTool(name: "swarm", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!call.isCancelled)
        call.cancel()
        await client.cancelActiveCalls()
        _ = await call.result
    }

    @Test("Cancelling tells the server to stop and frees the call")
    func cancellation() async throws {
        let transport = ScriptedTransport(tools: [.init("swarm")],
                                          behaviours: ["swarm": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .seconds(60))
        try await client.start()

        let call = Task { try await client.callTool(name: "swarm", arguments: [:]) }
        // Let the call reach the transport before pulling it out from under.
        try await Task.sleep(for: .milliseconds(50))
        await client.cancelActiveCalls(reason: "Stopped")

        await #expect(throws: MCPBridgeError.cancelled) { try await call.value }
        #expect(await transport.cancelledRequests.isEmpty == false)
    }

    @Test("Progress notifications reach the caller as a fraction")
    func progress() async throws {
        // Silent, so the call is still open when the notification arrives —
        // progress reported after a result would have nowhere to go.
        let transport = ScriptedTransport(tools: [.init("swarm")],
                                          behaviours: ["swarm": .silent])
        let client = MCPClient(transport: transport, requestTimeout: .seconds(30))
        try await client.start()

        let updates = Updates()
        let call = Task {
            try await client.callTool(name: "swarm", arguments: [:]) { fraction, message in
                Task { await updates.append(fraction, message) }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let token = try #require(await transport.progressTokens["swarm"])
        await transport.sendProgress(token: token, progress: 3, total: 10, message: "cycle 3")
        try await Task.sleep(for: .milliseconds(150))

        await client.cancelActiveCalls()
        _ = await call.result

        let recorded = await updates.values
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == 0.3)
        #expect(recorded.first?.1 == "cycle 3")
    }

    @Test("No progress token is sent when nobody is listening")
    func noTokenWithoutAHandler() async throws {
        let transport = ScriptedTransport(tools: [.init("read")])
        let client = MCPClient(transport: transport)
        try await client.start()

        _ = try await client.callTool(name: "read", arguments: [:])
        #expect(await transport.progressTokens["read"] == nil)
    }
}

/// Actor-isolated sink for the progress callback, which is `@Sendable`.
private actor Updates {
    private(set) var values: [(Double?, String?)] = []
    func append(_ fraction: Double?, _ message: String?) { values.append((fraction, message)) }
}

@Suite("MCPManager — timeouts and progress")
struct MCPManagerRequestControlTests {

    @Test("A per-server timeout overrides the manager's")
    func perServerTimeout() async {
        let config = MCPServerConfig(name: "Swarm",
                                     transport: .stdio(command: "unused", arguments: []),
                                     requestTimeoutSeconds: 0.1)
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("swarm")],
                                behaviours: ["swarm": .silent])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 requestTimeout: .seconds(600),
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()

        // The manager-wide 600s would hang the test; the server's own 0.1s wins.
        let started = ContinuousClock.now
        let result = await manager.execute(ToolCall(name: "swarm"))
        #expect(started.duration(to: .now) < .seconds(30))
        #expect(result.errorMessage != nil)
    }

    @Test("Progress is reported with the server and tool it came from")
    func managerProgress() async throws {
        let config = MCPServerConfig(name: "Swarm",
                                     transport: .stdio(command: "unused", arguments: []))
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("swarm")],
                                behaviours: ["swarm": .silent])

        let recorder = await ProgressRecorder()
        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 requestTimeout: .seconds(30),
                                 transportFactory: await registry.factory,
                                 onProgress: { update in recorder.record(update) })
        await manager.loadAndConnectEnabled()

        let call = Task { await manager.execute(ToolCall(name: "swarm")) }
        try await Task.sleep(for: .milliseconds(100))

        let transport = await registry.transport(for: config.id)
        let token = await transport?.progressTokens["swarm"]
        #expect(token != nil)
        if let token {
            await transport?.sendProgress(token: token, progress: 1, total: 4, message: "planning")
            try await Task.sleep(for: .milliseconds(150))
        }

        let updates = await recorder.updates
        #expect(updates.count == 1)
        #expect(updates.first?.serverName == "Swarm")
        #expect(updates.first?.toolName == "swarm")
        #expect(updates.first?.fraction == 0.25)

        await manager.cancelActiveCalls()
        _ = await call.value
    }

    @Test("Cancelling a call reports it as cancelled rather than reconnecting")
    func cancelDoesNotRetry() async throws {
        let config = MCPServerConfig(name: "Swarm",
                                     transport: .stdio(command: "unused", arguments: []))
        let registry = TransportRegistry()
        await registry.register(config.id, tools: [.init("swarm")],
                                behaviours: ["swarm": .silent])

        let manager = MCPManager(store: makeStore(), seedServers: [config],
                                 requestTimeout: .seconds(60),
                                 transportFactory: await registry.factory)
        await manager.loadAndConnectEnabled()
        let connectsBefore = await registry.connectCount

        let call = Task { await manager.execute(ToolCall(name: "swarm")) }
        try await Task.sleep(for: .milliseconds(100))
        await manager.cancelActiveCalls()

        let result = await call.value
        #expect(result.errorMessage?.contains("cancelled") == true)
        // Reconnecting would run the work the user just stopped all over again.
        #expect(await registry.connectCount == connectsBefore)
    }
}
