//
//  ConfigurationView.swift
//  ChatDemo
//
//  The first thing the app shows. Nothing is compiled in, so this sheet is the
//  only way a backend gets configured — and until it is filled in there is no
//  session to talk to.
//

import SwiftUI
import ChatGemini
import ChatOpenAI

struct ConfigurationView: View {

    @State var configuration: DemoConfiguration
    @State var apiKey: String

    /// Nil when the sheet is the launch gate — there is nothing to go back to.
    var onCancel: (() -> Void)?
    let onSave: (DemoConfiguration, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Backend", selection: $configuration.kind) {
                        ForEach(DemoConfiguration.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .onChange(of: configuration.kind) { _, kind in
                        configuration.model = defaultModel(for: kind)
                    }
                } footer: {
                    if !DemoConfiguration.hasFirebasePlist {
                        Text("Gemini needs a GoogleService-Info.plist in the app target. "
                             + "There isn't one in this build.")
                    }
                }

                switch configuration.kind {
                case .openAI: openAISections
                case .gemini: geminiSections
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Configure a backend")
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { onSave(configuration, apiKey) }
                        .disabled(!isValid)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private var isValid: Bool {
        configuration.isComplete(apiKey: apiKey)
    }

    // MARK: - OpenAI-compatible

    @ViewBuilder
    private var openAISections: some View {
        Section {
            TextField("Base URL", text: $configuration.baseURL, prompt: Text("https://api.openai.com/v1"))
                .textContentType(.URL)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            SecureField("API key", text: $apiKey)

            modelField(known: OpenAIModel.known.map(\.rawValue))
        } header: {
            Text("Server")
        } footer: {
            Text("Any server speaking the OpenAI chat-completions format. "
                 + "Leave the key empty for a local server that doesn't check one. "
                 + "It is stored in the Keychain, never in the project.")
        }

        Section {
            TextField("user_id", text: $configuration.userID)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            TextField("email", text: $configuration.email)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } header: {
            Text("Caller attribution (optional)")
        } footer: {
            Text("Sent as top-level fields via `extraBody`, for gateways that want "
                 + "their own attribution rather than OpenAI's `user`.")
        }
    }

    // MARK: - Gemini

    @ViewBuilder
    private var geminiSections: some View {
        Section {
            modelField(known: GeminiModel.known.map(\.rawValue))

            TextField("Location", text: $configuration.location, prompt: Text("global"))
                .autocorrectionDisabled()

            Toggle("Google Search grounding", isOn: $configuration.enableGoogleSearch)
        } header: {
            Text("Vertex AI")
        } footer: {
            Text("Credentials come from the bundled GoogleService-Info.plist, so "
                 + "there is no key to enter. The Vertex AI API has to be enabled "
                 + "on that project.")
        }
    }

    // MARK: - Shared

    /// Free text with suggestions rather than a closed picker: the model list is
    /// open, and both backends accept identifiers this package has never heard of.
    @ViewBuilder
    private func modelField(known: [String]) -> some View {
        Picker("Model", selection: $configuration.model) {
            ForEach(known, id: \.self) { Text($0).tag($0) }
            if !known.contains(configuration.model) {
                Text(configuration.model).tag(configuration.model)
            }
        }

        TextField("Or type a model id", text: $configuration.model)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
    }

    private func defaultModel(for kind: DemoConfiguration.Kind) -> String {
        switch kind {
        case .openAI: OpenAIModel.gpt4oMini.rawValue
        case .gemini: GeminiModel.gemini3_5Flash.rawValue
        }
    }
}
