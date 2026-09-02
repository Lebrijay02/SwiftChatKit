//
//  MCPManager.swift
//  SwiftChatKit
//
//  Owns the MCP server list and their connections, aggregates every connected
//  server's tools into one `ToolProvider`, and routes calls back to the server
//  that owns them.
//

import Foundation
import MCP
import ChatCore
#if os(macOS)
import Darwin
#endif

/// An actor rather than an `@Observable @MainActor` object: `ToolProvider`
/// inherits `Sendable`, and Swift 6 rejects a main-actor-isolated conformance
/// to it. Hosts that want to render connection state subscribe with
/// `onStatusChange` instead, which is delivered on the main actor.
public actor MCPManager: ToolProvider {

    /// One tool a server exposes: the name presented to the model, the name on
    /// the owning server, and the translated declaration.
    private struct ToolEntry {
        let exposed: String
        let original: String
        let declaration: ToolDeclaration
    }

    private let store: MCPServerStore
    private let seeds: [MCPServerConfig]
    private let authorization: (any MCPAuthorizationProvider)?
    private let elicitation: (any MCPElicitationHandler)?
    private let clientName: String
    private let connectTimeout: Duration
    private let requestTimeout: Duration
    private let makeTransport: MCPTransportFactory?
    private var onStatusChange: (@MainActor @Sendable ([UUID: MCPServerStatus]) -> Void)?
    private var onProgress: (@MainActor @Sendable (MCPToolProgress) -> Void)?
    /// Stdio servers are launched here, so they follow the session's directory.
    private var workingDirectory: URL?

    private var clients: [UUID: MCPClient] = [:]
    #if os(macOS)
    private var processes: [UUID: Process] = [:]
    #endif
    private var serverTools: [UUID: [ToolEntry]] = [:]

    /// The configured servers — the source of truth for the host's UI.
    public private(set) var servers: [MCPServerConfig] = []

    /// Per-server status, for the host to render.
    public private(set) var statuses: [UUID: MCPServerStatus] = [:] {
        didSet {
            guard statuses != oldValue, let onStatusChange else { return }
            let snapshot = statuses
            Task { @MainActor in onStatusChange(snapshot) }
        }
    }

    /// Tools the host knows to be read-only. MCP gives no way to tell, so
    /// everything not named here is treated as mutating and blocked in plan
    /// mode — assuming otherwise would let plan mode silently change things.
    public private(set) var readOnlyToolNames: Set<String> = []

    /// Declares which of a server's tools only observe, so plan mode can let
    /// them through. Nothing is assumed read-only by default.
    public func setReadOnly(_ names: Set<String>) { readOnlyToolNames = names }

    public private(set) var declarationsVersion: Int = 0

    public init(store: MCPServerStore = MCPServerStore(),
                seedServers: [MCPServerConfig] = [],
                authorization: (any MCPAuthorizationProvider)? = nil,
                elicitation: (any MCPElicitationHandler)? = nil,
                clientName: String = "SwiftChatKit",
                connectTimeout: Duration = .seconds(150),
                requestTimeout: Duration = .seconds(120),
                transportFactory: MCPTransportFactory? = nil,
                onStatusChange: (@MainActor @Sendable ([UUID: MCPServerStatus]) -> Void)? = nil,
                onProgress: (@MainActor @Sendable (MCPToolProgress) -> Void)? = nil) {
        self.store = store
        self.seeds = seedServers
        self.authorization = authorization
        self.elicitation = elicitation
        self.clientName = clientName
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.makeTransport = transportFactory
        self.onStatusChange = onStatusChange
        self.onProgress = onProgress
    }

    /// Replaces the status observer after init, for hosts that build the
    /// manager before the view that renders it.
    public func setStatusObserver(
        _ observer: (@MainActor @Sendable ([UUID: MCPServerStatus]) -> Void)?
    ) {
        onStatusChange = observer
    }

    /// Replaces the progress observer after init, for the same reason.
    public func setProgressObserver(
        _ observer: (@MainActor @Sendable (MCPToolProgress) -> Void)?
    ) {
        onProgress = observer
    }

    public func workingDirectoryChanged(to url: URL?) async {
        workingDirectory = url
    }

    // MARK: - Server list

    /// Loads the persisted list and connects every enabled server.
    public func loadAndConnectEnabled() async {
        await disconnectAll()
        servers = store.loadOrSeed(with: seeds)
        for config in servers {
            statuses[config.id] = MCPServerStatus(id: config.id, name: config.name,
                                                  state: .disconnected)
        }
        for config in servers where config.enabled {
            await connect(config)
        }
    }

    public func addServer(_ config: MCPServerConfig) async {
        servers.removeAll { $0.id == config.id }
        servers.append(config)
        store.save(servers)
        if config.enabled {
            await connect(config)
        } else {
            statuses[config.id] = MCPServerStatus(id: config.id, name: config.name,
                                                  state: .disconnected)
        }
    }

    public func removeServer(_ id: UUID) async {
        await disconnect(id)
        servers.removeAll { $0.id == id }
        statuses[id] = nil
        store.save(servers)
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        store.save(servers)
        if enabled {
            await connect(servers[index])
        } else {
            await disconnect(id)
        }
    }

    // MARK: - Connection lifecycle

    /// Everything a live connection needs, so the transport-specific setup
    /// stays out of `connect`.
    private struct Connection {
        let transport: any Transport
        // Only stdio servers have a child to own, and stdio is macOS-only.
        #if os(macOS)
        var process: Process?
        var stderr: OutputCollector?
        #endif
        /// Run if the handshake misses its deadline. A stdio child can stay
        /// alive and silent, in which case the transport read never returns and
        /// only killing the process unblocks it.
        var onTimeout: @Sendable () -> Void = {}
    }

    private func makeConnection(for config: MCPServerConfig) async throws -> Connection {
        if let makeTransport {
            return Connection(transport: try await makeTransport(config, workingDirectory))
        }

        switch config.transport {
        case .http(let url, let auth):
            let headers = try await authHeaders(for: auth, url: url)
            return Connection(transport: HTTPClientTransport(endpoint: url, requestModifier: { request in
                var request = request
                for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
                return request
            }))

        case .stdio(let command, let arguments, let environment, let directory):
            #if os(macOS)
            let launched = try StdioLauncher.launch(
                command: command,
                arguments: arguments,
                environment: environment,
                // A server checked out elsewhere runs from its own directory;
                // only servers that don't say otherwise follow the session's.
                workingDirectory: directory ?? workingDirectory)
            let pid = launched.process.processIdentifier
            return Connection(transport: launched.transport,
                              process: launched.process,
                              stderr: launched.stderr,
                              onTimeout: { kill(pid, SIGTERM) })
            #else
            throw MCPBridgeError.notConnected
            #endif
        }
    }

    public func connect(_ config: MCPServerConfig) async {
        await disconnect(config.id)
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            servers[index] = config
        }
        statuses[config.id] = MCPServerStatus(id: config.id, name: config.name, state: .connecting)

        // Captured for the catch below. Only stdio servers have a stderr to
        // read, and stdio is macOS-only.
        #if os(macOS)
        var collector: OutputCollector?
        #endif
        do {
            let connection = try await makeConnection(for: config)
            #if os(macOS)
            collector = connection.stderr
            processes[config.id] = connection.process
            #endif

            let client = MCPClient(transport: connection.transport,
                                   clientName: clientName,
                                   requestTimeout: config.requestTimeout ?? requestTimeout,
                                   elicitation: elicitation,
                                   serverName: config.name)
            let tools = try await withTimeout(connectTimeout, onTimeout: connection.onTimeout) {
                try await client.start()
                return try await client.listTools()
            }

            clients[config.id] = client
            register(tools: tools, for: config.id)
            statuses[config.id] = MCPServerStatus(id: config.id, name: config.name,
                                                  state: .connected, toolCount: tools.count)
        } catch {
            #if os(macOS)
            processes[config.id]?.terminate()
            processes[config.id] = nil
            #endif

            // A server that dies during the handshake usually explains itself
            // only on stderr, so fold that into the message the user sees.
            var details = ""
            #if os(macOS)
            details = collector?.text ?? ""
            #endif
            let message = details.isEmpty
                ? error.localizedDescription
                : "\(error.localizedDescription) — stderr: \(details)"

            let needsAuth: Bool
            if case .http(_, .oauth) = config.transport { needsAuth = true } else { needsAuth = false }
            statuses[config.id] = MCPServerStatus(
                id: config.id, name: config.name,
                state: needsAuth ? .needsAuth : .failed(message))
        }
    }

    public func disconnect(_ id: UUID) async {
        if let client = clients[id] { await client.stop() }
        clients[id] = nil
        #if os(macOS)
        if let process = processes[id], process.isRunning { process.terminate() }
        processes[id] = nil
        #endif
        serverTools[id] = nil
        rebuildExposedNames()
        if var status = statuses[id] {
            status.state = .disconnected
            status.toolCount = 0
            statuses[id] = status
        }
    }

    public func disconnectAll() async {
        for id in Array(clients.keys) { await disconnect(id) }
        clients.removeAll()
        #if os(macOS)
        for process in processes.values where process.isRunning { process.terminate() }
        processes.removeAll()
        #endif
        serverTools.removeAll()
        rebuildExposedNames()
        for (id, var status) in statuses {
            status.state = .disconnected
            status.toolCount = 0
            statuses[id] = status
        }
    }

    /// Races `operation` against a deadline, running `onTimeout` if it loses.
    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        onTimeout: @escaping @Sendable () -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let seconds = timeout.components.seconds
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                onTimeout()
                throw MCPBridgeError.timedOut("Handshake didn't complete in \(seconds)s.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MCPBridgeError.invalidResponse }
            return result
        }
    }

    // MARK: - Tool registration

    private func register(tools: [MCPClient.DiscoveredTool], for id: UUID) {
        pendingSchemas[id] = tools
        rebuildExposedNames()
    }

    /// Raw discovered tools, kept so exposed names can be recomputed from
    /// scratch whenever the connected set changes.
    private var pendingSchemas: [UUID: [MCPClient.DiscoveredTool]] = [:]

    /// Recomputes every exposed name in server-list order. Resolving collisions
    /// incrementally would make a tool's name depend on connection order, so a
    /// reconnect could rename tools mid-session and strand the model's memory
    /// of them.
    private func rebuildExposedNames() {
        var taken = Set<String>()
        var rebuilt: [UUID: [ToolEntry]] = [:]

        for config in servers {
            guard let tools = pendingSchemas[config.id], clients[config.id] != nil else { continue }
            var entries: [ToolEntry] = []
            for tool in tools {
                var exposed = tool.name
                if taken.contains(exposed) {
                    exposed = "\(Self.sanitize(config.name))_\(tool.name)"
                }
                taken.insert(exposed)

                let (properties, optional) = MCPSchemaConverter.parameters(tool.inputSchema)
                entries.append(ToolEntry(
                    exposed: exposed,
                    original: tool.name,
                    declaration: ToolDeclaration(name: exposed,
                                                 description: tool.description,
                                                 parameters: properties,
                                                 optional: optional)))
            }
            rebuilt[config.id] = entries
        }

        serverTools = rebuilt
        declarationsVersion += 1
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    private func route(_ exposed: String) -> (server: UUID, original: String)? {
        for config in servers {
            if let entry = serverTools[config.id]?.first(where: { $0.exposed == exposed }) {
                return (config.id, entry.original)
            }
        }
        return nil
    }

    // MARK: - ToolProvider

    public var declarations: [ToolDeclaration] {
        servers
            .filter(\.enabled)
            .flatMap { serverTools[$0.id]?.map(\.declaration) ?? [] }
    }

    public func handles(_ name: String) -> Bool { route(name) != nil }

    /// Never auto-allowed: the package cannot know what a third-party server
    /// will do, so the user decides.
    public nonisolated var autoAllowedToolNames: Set<String> { [] }

    public var mutatingToolNames: Set<String> {
        Set(declarations.map(\.name)).subtracting(readOnlyToolNames)
    }

    public func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        let serverName = route(call.name)
            .flatMap { routed in servers.first { $0.id == routed.server }?.name }
        return PermissionRequest(
            toolName: call.name,
            title: serverName.map { "\($0): \(call.name)" } ?? call.name,
            detail: ChatValue.object(call.arguments).jsonString(prettyPrinted: true))
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let routed = route(call.name) else {
            return .failure(call, MCPBridgeError.unknownTool(call.name).localizedDescription)
        }

        let progress = progressHandler(for: routed.server, toolName: call.name)
        do {
            guard let client = clients[routed.server] else { throw MCPBridgeError.notConnected }
            let response = try await client.callTool(name: routed.original,
                                                     arguments: call.arguments,
                                                     progress: progress)
            return Self.result(for: call, response)
        } catch MCPBridgeError.cancelled {
            // A cancelled call is the user's own doing. Reconnecting and
            // running it again is the last thing they asked for.
            return .failure(call, MCPBridgeError.cancelled.localizedDescription)
        } catch {
            // Stdio servers die quietly — a crashed child looks exactly like a
            // failed call until you try again. One reconnect, then give up.
            guard let config = servers.first(where: { $0.id == routed.server }) else {
                return .failure(call, error.localizedDescription)
            }
            await connect(config)
            guard let retry = route(call.name), let client = clients[retry.server] else {
                return .failure(call, error.localizedDescription)
            }
            do {
                let response = try await client.callTool(
                    name: retry.original,
                    arguments: call.arguments,
                    progress: progressHandler(for: retry.server, toolName: call.name))
                return Self.result(for: call, response)
            } catch {
                return .failure(call, error.localizedDescription)
            }
        }
    }

    /// Stops every in-flight call on every connected server, telling each one
    /// to abandon the work rather than leaving it running unwatched.
    public func cancelActiveCalls(reason: String = "Cancelled by the user.") async {
        for client in clients.values {
            await client.cancelActiveCalls(reason: reason)
        }
    }

    /// Nil when no host is watching, which keeps the `_meta.progressToken` off
    /// the wire — a server told to report progress nobody reads is doing work
    /// for nothing.
    private func progressHandler(for server: UUID,
                                 toolName: String) -> MCPClient.ProgressHandler? {
        guard let onProgress else { return nil }
        let name = servers.first { $0.id == server }?.name ?? ""
        return { fraction, message in
            let update = MCPToolProgress(serverID: server, serverName: name,
                                         toolName: toolName,
                                         fraction: fraction, message: message)
            Task { @MainActor in onProgress(update) }
        }
    }

    private static func result(for call: ToolCall,
                               _ response: (text: String, isError: Bool)) -> ToolResult {
        // A server reporting isError is a failed tool, not a failed turn: it
        // must reach the model as an error it can read and recover from.
        response.isError
            ? .failure(call, response.text)
            : .success(call, ["result": .string(response.text)])
    }

    // MARK: - Auth

    private func authHeaders(for auth: MCPAuth, url: URL) async throws -> [String: String] {
        switch auth {
        case .none:
            return [:]
        case .bearer(let token):
            return ["Authorization": "Bearer \(token)"]
        case .oauth:
            guard let authorization else { throw MCPBridgeError.authRequired(url) }
            return ["Authorization": "Bearer \(try await authorization.accessToken(for: url))"]
        }
    }
}
