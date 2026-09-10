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

    /// Whether this invocation may overlap other concurrent-safe invocations.
    func executionMode(for call: ToolCall) async -> ToolExecutionMode

    /// Whether retrying this invocation can duplicate a side effect.
    func retrySafety(for call: ToolCall) async -> ToolRetrySafety

    /// Maximum execution time for this invocation. Nil leaves timeout ownership
    /// with the provider.
    func timeout(for call: ToolCall) async -> Duration?

    /// Whether new user input may cancel this invocation.
    func interruptionBehavior(for call: ToolCall) async -> ToolInterruptionBehavior

    /// Which result data should survive conversation compaction.
    func resultRetention(for call: ToolCall) async -> ToolResultRetention

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

    /// Told which directories the conversation may reach, once at session init
    /// and again whenever the scope widens. Providers that resolve paths or
    /// spawn processes need to follow it; the default does nothing.
    ///
    /// `scope.root` is the working directory. After the first message it never
    /// changes again, so a provider only ever sees additions.
    func directoryScopeChanged(to scope: DirectoryScope) async

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

    func executionMode(for call: ToolCall) async -> ToolExecutionMode { .exclusive }

    func retrySafety(for call: ToolCall) async -> ToolRetrySafety { .never }

    func timeout(for call: ToolCall) async -> Duration? { nil }

    func interruptionBehavior(for call: ToolCall) async -> ToolInterruptionBehavior {
        .finishBeforeInterrupt
    }

    func resultRetention(for call: ToolCall) async -> ToolResultRetention { .summarize }

    var autoAllowedToolNames: Set<String> { [] }

    var mutatingToolNames: Set<String> { get async { [] } }

    var declarationsVersion: Int { get async { 0 } }

    func directoryScopeChanged(to scope: DirectoryScope) async {}
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
