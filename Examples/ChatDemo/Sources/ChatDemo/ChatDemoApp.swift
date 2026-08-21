//
//  ChatDemoApp.swift
//  ChatDemo
//
//  Wiring a session is one initializer. Everything below is choosing what to put
//  in it.
//

import SwiftUI
import FirebaseCore
import ChatCore
import ChatTools
import ChatGemini

@main
struct ChatDemoApp: App {

    @State private var session: ChatSession

    init() {
        // Firebase is configured only if the host app actually shipped a plist.
        // Without one the demo still runs, on the echo backend — which keeps the
        // UI drivable for anyone who just cloned the package.
        let hasFirebase = Bundle.main.url(forResource: "GoogleService-Info",
                                          withExtension: "plist") != nil
        if hasFirebase { FirebaseApp.configure() }

        let backend: any ChatBackend = hasFirebase
            ? GeminiBackend(GeminiBackendConfig(model: .gemini3_5Flash))
            : EchoBackend()

        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        let fileSystem = LocalFileSystem(root: workingDirectory)

        _session = State(initialValue: ChatSession(configuration: .init(
            backend: backend,
            toolProviders: [
                FileToolProvider(fileSystem: fileSystem),
                ShellToolProvider(),
            ],
            workingDirectory: workingDirectory,
            // Read-only tools run unprompted; everything that writes or executes
            // stops for approval, which is what the permission card is for.
            autoAllowedTools: FileToolProvider.readOnlyNames,
            permissionStore: EphemeralPermissionStore())))
    }

    var body: some Scene {
        WindowGroup("SwiftChatKit Demo") {
            ChatDemoView(session: session)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
