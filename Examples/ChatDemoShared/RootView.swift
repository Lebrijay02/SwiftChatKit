//
//  RootView.swift
//  ChatDemo
//
//  The gate. A `ChatSession` is only built once a backend is configured, so
//  there is no half-working state to reason about: either there is a session
//  and the chat is live, or the sheet is up.
//

import SwiftUI
import ChatCore
import ChatMCP
#if os(macOS)
import ChatTools
#endif

struct RootView: View {

    @State private var session: ChatSession?
    @State private var isConfiguring = false
    @State private var isShowingHistory = false
    @State private var isShowingSettings = false

    @State private var configuration = DemoConfigurationStore.load() ?? .initial
    @State private var apiKey = DemoConfigurationStore.loadAPIKey()

    /// Seeded with the public test servers in `DefaultMCPServers`; persists
    /// under the same name across both platforms, so it lives for the app,
    /// not the session. `.http` transport works cross-platform, so it is
    /// offered to both apps, unlike the macOS-only file and shell tools.
    private let mcpManager = MCPManager(
        store: MCPServerStore(),
        seedServers: DefaultMCPServers.all)

    private let historyStore = ChatHistoryStore.applicationSupport(
        Bundle.main.bundleIdentifier ?? "ChatDemo")

    var body: some View {
        Group {
            if let session {
                ChatView(
                    session: session,
                    onConfigure: { isConfiguring = true },
                    onShowHistory: { isShowingHistory = true },
                    onShowSettings: { isShowingSettings = true })
            } else {
                unconfigured
            }
        }
        .sheet(isPresented: $isConfiguring) {
            ConfigurationView(
                configuration: configuration,
                apiKey: apiKey,
                // Nothing to go back to until a session exists.
                onCancel: session == nil ? nil : { isConfiguring = false },
                onSave: start)
        }
        .sheet(isPresented: $isShowingHistory) {
            if let session {
                HistoryView(historyStore: historyStore, session: session) {
                    isShowingHistory = false
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(mcpManager: mcpManager, session: session) { isShowingSettings = false }
        }
        // Dismissing the launch gate by swiping would leave the app with no
        // backend and no way back to the sheet.
        .interactiveDismissDisabled(session == nil)
        .onAppear {
            guard session == nil else { return }
            // A saved configuration starts straight away; anything else asks.
            if configuration.isComplete(apiKey: apiKey), DemoConfigurationStore.load() != nil {
                start(configuration, apiKey)
            } else {
                isConfiguring = true
            }
        }
    }

    private var unconfigured: some View {
        ContentUnavailableView {
            Label("No backend", systemImage: "network.slash")
        } description: {
            Text("This demo ships with no credentials and no canned fallback. "
                 + "Point it at a server to start.")
        } actions: {
            Button("Configure") { isConfiguring = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func start(_ configuration: DemoConfiguration, _ apiKey: String) {
        guard let backend = DemoBackend.make(configuration, apiKey: apiKey) else { return }

        DemoConfigurationStore.save(configuration)
        DemoConfigurationStore.saveAPIKey(apiKey)
        self.configuration = configuration
        self.apiKey = apiKey

        var toolProviders: [any ToolProvider] = [mcpManager]
        var workingDirectory: URL?
        var persona = ChatPersona.default
        var skills = SkillsConfiguration.disabled
        var enableAgentTools = false
        var autoAllowedTools: Set<String> = []

        #if os(macOS)
        // The file and shell tools are `os(macOS)` only — see `ChatTools`'s
        // `ShellToolProvider` — so this is the only platform that gets a
        // filesystem to work in, a persona that describes doing so, and
        // `~/.claude/skills`, the same folder Claude Code reads. iOS has no
        // home directory a user manages, so skills stay off there.
        workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        toolProviders.append(FileToolProvider(fileSystem: LocalFileSystem(root: workingDirectory!)))
        toolProviders.append(ShellToolProvider())
        persona = .codingAgent
        skills = .claudeCompatible
        enableAgentTools = true
        autoAllowedTools = FileToolProvider.readOnlyNames
        #endif

        session = ChatSession(configuration: .init(
            backend: backend,
            toolProviders: toolProviders,
            persona: persona,
            workingDirectory: workingDirectory,
            skills: skills,
            enableTodos: enableAgentTools,
            enableQuestions: enableAgentTools,
            autoAllowedTools: autoAllowedTools,
            permissionStore: EphemeralPermissionStore(),
            historyStore: historyStore))

        session?.permissions.autoApproveAll = DemoConfigurationStore.autoApproveTools

        Task { await mcpManager.loadAndConnectEnabled() }
        isConfiguring = false
    }
}
