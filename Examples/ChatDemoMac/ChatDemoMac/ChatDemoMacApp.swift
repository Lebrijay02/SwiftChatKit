//
//  ChatDemoMacApp.swift
//  ChatDemoMac
//
//  The smallest possible SwiftChatKit host: a backend and nothing else. No
//  tools, no MCP, no skills — capabilities are opt-in, so leaving them out is
//  the whole configuration. `RootView` builds the session once the user has
//  said what to talk to.
//

import SwiftUI

@main
struct ChatDemoMacApp: App {
    var body: some Scene {
        WindowGroup("SwiftChatKit Demo") {
            RootView()
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}
