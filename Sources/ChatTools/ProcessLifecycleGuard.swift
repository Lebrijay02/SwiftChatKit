//
//  ProcessLifecycleGuard.swift
//  SwiftChatKit
//
//  Kills every still-running detached child when the app quits.
//
//  This cannot live on `BackgroundProcessManager`: the actor's state is only
//  reachable with an `await`, and `NSApplicationWillTerminate` does not wait for
//  one — the app is gone before the hop lands. So the pids are mirrored into a
//  plain lock-guarded set that the termination handler can read synchronously.
//

#if os(macOS)

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Process-wide registry of detached children, kept only so they can be reaped
/// synchronously at exit. A leaked `xcodebuild` outlives the app that spawned it
/// and keeps holding the derived-data lock, which breaks the *next* launch.
final class ProcessLifecycleGuard: @unchecked Sendable {

    static let shared = ProcessLifecycleGuard()

    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var installed = false

    private init() {}

    /// Starts observing app termination on first use. A manager that never
    /// spawns anything therefore installs nothing.
    func register(_ pid: pid_t) {
        lock.lock()
        pids.insert(pid)
        let needsObserver = !installed
        installed = true
        lock.unlock()

        if needsObserver { installTerminationObserver() }
    }

    func unregister(_ pid: pid_t) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    /// SIGTERM to everything still registered. Called on the main thread during
    /// termination, so it must not block: no wait, no escalation to SIGKILL —
    /// the kernel reaps whatever ignores the signal when the process group dies.
    func terminateAll() {
        lock.lock()
        let doomed = pids
        pids.removeAll()
        lock.unlock()

        for pid in doomed { kill(pid, SIGTERM) }
    }

    private func installTerminationObserver() {
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.terminateAll()
        }
        #endif
    }
}

#endif
