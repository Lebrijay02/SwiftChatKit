//
//  ToolProvider.swift
//  SwiftChatKit
//
//  The extension point. A host adds capabilities by conforming a type here and
//  listing it in the session configuration — nothing app-specific belongs in
//  this package, so every domain tool arrives this way.
//

import Foundation

public protocol ToolProvider: AnyObject, Sendable {

    /// Tools this provider exposes to the model. Read once per model rebuild,
    /// so a provider whose tool list changes must signal via `declarationsVersion`.
    var declarations: [ToolDeclaration] { get async }

    /// Whether this provider owns `name`. The session dispatches to the first
    /// provider that claims a call, in configuration order.
    func handles(_ name: String) async -> Bool

    /// Runs the call. Must not throw past the loop: a failed tool is data the
    /// model should read and recover from, so return `ToolResult.failure`.
    func execute(_ call: ToolCall) async -> ToolResult

    /// The approval card shown before the call runs, or nil to use the generic
    /// one. Override to render a diff, a command line, or a target path.
    func approvalCard(for call: ToolCall) async -> PermissionRequest?

    /// Tools this provider considers safe to run unprompted. Merged into the
    /// permission service's auto-allow set at session init.
    var autoAllowedToolNames: Set<String> { get }

    /// Tools that must be blocked in plan mode because they mutate state.
    /// Async because a provider whose tool list is discovered at runtime — an
    /// MCP bridge, say — cannot answer this from a static set.
    var mutatingToolNames: Set<String> { get async }

    /// Told when the session's working directory changes, and once at session
    /// init. Providers that resolve paths or spawn processes need to follow it;
    /// the default does nothing.
    func workingDirectoryChanged(to url: URL?) async

    /// Bumped when `declarations` changes, so the session knows to rebuild the
    /// model. Constant for providers with a fixed tool list.
    var declarationsVersion: Int { get async }
}

// MARK: - Defaults

public extension ToolProvider {

    func handles(_ name: String) async -> Bool {
        await declarations.contains { $0.name == name }
    }

    func approvalCard(for call: ToolCall) async -> PermissionRequest? { nil }

    var autoAllowedToolNames: Set<String> { [] }

    var mutatingToolNames: Set<String> { get async { [] } }

    var declarationsVersion: Int { get async { 0 } }

    func workingDirectoryChanged(to url: URL?) async {}
}

// MARK: - Generic approval

public extension PermissionRequest {
    /// Fallback card for a provider that supplied none: name the tool and show
    /// its arguments, which is the least the user needs to make a decision.
    static func generic(for call: ToolCall) -> PermissionRequest {
        PermissionRequest(
            toolName: call.name,
            title: "Run \(call.name)",
            detail: ChatValue.object(call.arguments).jsonString(prettyPrinted: true))
    }
}
