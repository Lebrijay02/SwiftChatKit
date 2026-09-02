//
//  StdioLauncher.swift
//  SwiftChatKit
//
//  Spawns a local MCP server subprocess and wires its stdio into the SDK's
//  `StdioTransport` — which reads and writes file descriptors but does not
//  spawn anything, so the child is launched here with Process + Pipes.
//
//  Requires the App Sandbox to be disabled in the host.
//

#if os(macOS)

import Foundation
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

/// Thread-safe accumulator for a child process's stderr. When a server dies
/// during the handshake, its stderr is usually the only explanation available.
public final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    public init() {}

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    public var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum StdioLauncher {

    public enum LaunchError: LocalizedError {
        case executableNotFound(String)
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let name):
                return "Could not find executable \"\(name)\" in PATH or the usual locations."
            case .launchFailed(let message):
                return "Failed to launch MCP subprocess: \(message)"
            }
        }
    }

    /// Directories searched ahead of the inherited PATH. A GUI app inherits
    /// launchd's minimal PATH, not the user's shell one, so `npx` is otherwise
    /// invisible — which is how most MCP servers are started.
    private static let fallbackBinDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
    ]

    /// Resolves an executable name to an absolute path, searching `path` — or
    /// the current process's `PATH` when none is given.
    public static func resolveExecutable(_ name: String, in path: String? = nil) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        var directories: [String] = []
        if let node = preferredNodeBinDirectory() { directories.append(node) }
        directories += fallbackBinDirectories
        if let path = path ?? ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The parent environment with the usual bin directories prepended to
    /// `PATH`, then `overrides` merged over the top — so a caller can replace
    /// `PATH` outright, and one that passes nothing still gets the
    /// augmentation.
    private static func augmentedEnvironment(
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories: [String] = []
        if let node = preferredNodeBinDirectory() { directories.append(node) }
        directories += fallbackBinDirectories

        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        environment["PATH"] = (directories + existing)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return environment.merging(overrides) { _, override in override }
    }

    /// Newest nvm-installed Node on a major version the ecosystem still
    /// supports, falling back to a system install. An MCP server launched under
    /// a Node too old for it fails with a stack trace rather than a clear error.
    private static func preferredNodeBinDirectory() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDirectory = "\(home)/.nvm/versions/node"
        let supportedMajors: Set<Int> = [24, 22, 20]

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDirectory) {
            let best = entries.compactMap { name -> (version: [Int], path: String)? in
                let trimmed = name.hasPrefix("v") ? String(name.dropFirst()) : name
                let parts = trimmed.split(separator: ".").compactMap { Int($0) }
                guard let major = parts.first, supportedMajors.contains(major) else { return nil }
                let bin = "\(nvmDirectory)/\(name)/bin"
                guard FileManager.default.isExecutableFile(atPath: "\(bin)/node") else { return nil }
                return (parts, bin)
            }.max { lexicographicallyPrecedes($0.version, $1.version) }
            if let best { return best.path }
        }

        return fallbackBinDirectories.first {
            FileManager.default.isExecutableFile(atPath: "\($0)/node")
        }
    }

    private static func lexicographicallyPrecedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Launches `command arguments…` and returns the running process plus a
    /// transport bound to its stdio.
    ///
    /// `environment` is merged over the inherited environment, which is how a
    /// host passes per-run secrets to one child without putting them in its own
    /// process environment, where they would reach every other child and every
    /// crash report.
    public static func launch(
        command: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) throws -> (process: Process, transport: StdioTransport, stderr: OutputCollector) {

        // Resolved against the merged environment, so an overridden `PATH` also
        // decides which executable this name refers to.
        let merged = augmentedEnvironment(overrides: environment)
        guard let executable = resolveExecutable(command, in: merged["PATH"]) else {
            throw LaunchError.executableNotFound(command)
        }

        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        process.environment = merged
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stderr = OutputCollector()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderr.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor))

        return (process, transport, stderr)
    }
}

#endif
