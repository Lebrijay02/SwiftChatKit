//
//  PermissionService.swift
//  SwiftChatKit
//
//  Tool permission gate. Mutating tools suspend the agent loop until the host
//  answers Allow once / Always allow / Deny, so a model can never write to disk
//  or run a command without the user having seen exactly what it asked for.
//

import Foundation

// MARK: - Decision

public enum PermissionDecision: Equatable, Sendable {
    case allowOnce
    case alwaysAllow
    case deny
}

// MARK: - Request

public struct PermissionRequest: Identifiable, Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// File edit, shell command, MCP call…
        case tool
        /// Leaving plan mode to start executing.
        case plan
    }

    public let id: UUID
    public let kind: Kind
    public let toolName: String
    /// One-line human title, e.g. "Run command" or "Edit ContentView.swift".
    public let title: String
    /// Card body: the command text, the file path plus a content preview, or the
    /// plan itself. This is what the user actually judges, so it must be complete.
    public let detail: String

    public init(id: UUID = UUID(),
                kind: Kind = .tool,
                toolName: String,
                title: String,
                detail: String) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.title = title
        self.detail = detail
    }
}

// MARK: - Storage

/// Where "Always allow" grants persist. Injectable so a host can scope them per
/// project, or keep them in memory for a sandboxed preview.
public protocol PermissionStore: Sendable {
    func load() -> Set<String>
    func save(_ tools: Set<String>)
}

/// `@unchecked` because `UserDefaults` is not marked `Sendable` even though it
/// is documented as thread-safe; there is no mutable state of our own here.
public struct UserDefaultsPermissionStore: PermissionStore, @unchecked Sendable {
    private let key: String
    private let defaults: UserDefaults

    public init(key: String = "SwiftChatKit.alwaysAllowedTools",
                defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    public func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func save(_ tools: Set<String>) {
        defaults.set(Array(tools).sorted(), forKey: key)
    }
}

public struct EphemeralPermissionStore: PermissionStore {
    public init() {}
    public func load() -> Set<String> { [] }
    public func save(_ tools: Set<String>) {}
}

// MARK: - Service

@MainActor
@Observable
public final class PermissionService {

    /// The request awaiting a decision. Non-nil means the agent loop is parked.
    public private(set) var pending: PermissionRequest?

    /// Tools approved with "Always allow", restored from the store on init.
    public private(set) var alwaysAllowed: Set<String>

    /// Tools that never prompt — read-only operations and the agent's own
    /// bookkeeping tools. Supplied by configuration rather than hardcoded,
    /// because which tools are safe depends on which providers are installed.
    public let autoAllowed: Set<String>

    /// Global override: when set, nothing prompts, regardless of tool name.
    /// Unlike `autoAllowed`/`alwaysAllowed` — which only cover tools known by
    /// name up front — this also silences tools a host has no static list for,
    /// such as an MCP server's. A host offering this as a user-facing choice
    /// should make the risk explicit: it approves file writes and shell
    /// commands with no review.
    public var autoApproveAll: Bool

    private var continuation: CheckedContinuation<PermissionDecision, Never>?
    private let store: PermissionStore

    public init(autoAllowed: Set<String> = [],
                autoApproveAll: Bool = false,
                store: PermissionStore = UserDefaultsPermissionStore()) {
        self.autoAllowed = autoAllowed
        self.autoApproveAll = autoApproveAll
        self.store = store
        self.alwaysAllowed = store.load()
    }

    public func requiresApproval(_ toolName: String) -> Bool {
        !autoApproveAll && !autoAllowed.contains(toolName) && !alwaysAllowed.contains(toolName)
    }

    /// Suspends until the host answers. One request at a time — the agent loop
    /// asks sequentially, so this never needs a queue.
    public func request(_ request: PermissionRequest) async -> PermissionDecision {
        // An unanswered previous request would deadlock the loop. Deny it.
        if continuation != nil { resolve(.deny) }

        return await withCheckedContinuation { cont in
            continuation = cont
            pending = request
        }
    }

    /// Called by the approval UI.
    public func resolve(_ decision: PermissionDecision) {
        if decision == .alwaysAllow, let name = pending?.toolName {
            alwaysAllowed.insert(name)
            store.save(alwaysAllowed)
        }
        pending = nil
        continuation?.resume(returning: decision)
        continuation = nil
    }

    /// Deny and dismiss anything pending — used when the user stops streaming.
    public func cancelPending() {
        guard continuation != nil else { return }
        resolve(.deny)
    }

    public func revokeAlwaysAllow(_ toolName: String) {
        alwaysAllowed.remove(toolName)
        store.save(alwaysAllowed)
    }
}
