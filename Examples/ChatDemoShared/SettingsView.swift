//
//  SettingsView.swift
//  ChatDemo
//
//  What tools the model can reach beyond the backend: the configured MCP
//  servers on both platforms, and installed Agent Skills on macOS, where
//  `~/.claude/skills` is a real, meaningful folder. iOS has no home directory
//  a user manages, so there is nothing honest to show there.
//

import SwiftUI
import ChatCore
import ChatMCP

struct SettingsView: View {

    let mcpManager: MCPManager
    let onDismiss: () -> Void

    @State private var servers: [MCPServerConfig] = []
    @State private var statuses: [UUID: MCPServerStatus] = [:]
    #if os(macOS)
    @State private var skills: [AgentSkill] = []
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(servers) { server in
                        row(for: server)
                    }
                } header: {
                    Text("MCP servers")
                } footer: {
                    Text("Seeded with public test servers on first launch. "
                         + "Toggling one off disconnects it.")
                }

                #if os(macOS)
                Section {
                    if skills.isEmpty {
                        Text("No skills found in ~/.claude/skills")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(skills) { skill in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Skills")
                } footer: {
                    Text("Read from ~/.claude/skills, the same folder Claude Code "
                         + "reads — this demo installs nothing of its own.")
                }
                #endif
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        // A macOS sheet with no intrinsic size shrinks to fit its toolbar,
        // squeezing the list to nothing — force a reasonable window size.
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { await refresh() }
    }

    @ViewBuilder
    private func row(for server: MCPServerConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(statusLabel(for: server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: enabledBinding(for: server))
                .labelsHidden()
        }
    }

    private func statusLabel(for server: MCPServerConfig) -> String {
        guard let status = statuses[server.id] else { return "Not connected" }
        switch status.state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(status.toolCount) tools"
        case .needsAuth: return "Needs authentication"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private func enabledBinding(for server: MCPServerConfig) -> Binding<Bool> {
        Binding(
            get: { server.enabled },
            set: { newValue in
                Task {
                    await mcpManager.setEnabled(server.id, newValue)
                    await refresh()
                }
            })
    }

    private func refresh() async {
        servers = await mcpManager.servers
        statuses = await mcpManager.statuses
        #if os(macOS)
        skills = SkillsService(configuration: .claudeCompatible).refresh(workingDirectory: nil)
        #endif
    }
}
