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

struct RootView: View {

    @State private var session: ChatSession?
    @State private var isConfiguring = false

    @State private var configuration = DemoConfigurationStore.load() ?? .initial
    @State private var apiKey = DemoConfigurationStore.loadAPIKey()

    var body: some View {
        Group {
            if let session {
                ChatView(session: session) { isConfiguring = true }
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

        // `.default` is the persona that describes no tools, which matches a
        // session that has none.
        session = ChatSession(configuration: .init(backend: backend, persona: .default))
        isConfiguring = false
    }
}
