//
//  BackgroundProcessManager.swift
//  SwiftChatKit
//
//  Detached command execution: the caller gets an id back immediately and the
//  command's output accumulates in a log file it can page through later.
//
//  `CommandRunner` holds the agent turn open for as long as the command runs,
//  which is right for `git status` and useless for `xcodebuild`. A ten-minute
//  compile should not cost ten minutes of a parked turn, so long work is
//  started here and the model polls the log while it does something else.
//

#if os(macOS)

import Foundation
import Darwin
import ChatCore

public actor BackgroundProcessManager {

    // MARK: - Types

    public struct Record: Sendable, Equatable {
        public let id: UUID
        public let command: String
        public let purpose: String
        public let logURL: URL
        public let startedAt: Date
        public var exitCode: Int32?
        public var finishedAt: Date?

        public var isRunning: Bool { finishedAt == nil }
    }

    /// One page of a process log, plus enough state for the model to decide
    /// whether to poll again.
    public struct LogPage: Sendable {
        public let lines: [String]
        /// Line index to pass as the next `offset`. Polling with this reads only
        /// what arrived since, which is the whole point of paging a live log.
        public let nextOffset: Int
        public let totalLines: Int
        public let truncated: Bool
        public let record: Record
    }

    public enum Failure: LocalizedError, Equatable {
        case unknownProcess(String)
        case launchFailed(String)
        case logUnreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unknownProcess(let id):
                return """
                No background process with id '\(id)'. Ids do not survive a restart of the app — \
                start the command again rather than retrying this call.
                """
            case .launchFailed(let detail):
                return "Could not start the background process: \(detail)"
            case .logUnreadable(let detail):
                return "Could not read the process log: \(detail)"
            }
        }
    }

    // MARK: - Limits

    /// Default page size. Large enough to carry a compiler error with its
    /// context, small enough that an idle poll costs almost nothing.
    public static let defaultLimit = 200
    /// Hard ceiling on one page, whatever the model asks for. A build log is
    /// tens of megabytes; handing it back whole is how a context window dies.
    public static let maxCharactersPerPage = 30_000

    // MARK: - State

    private var records: [UUID: Record] = [:]
    private var processes: [UUID: Process] = [:]
    private var logHandles: [UUID: FileHandle] = [:]

    private let shell: String
    private let environment: [String: String]?
    private let logDirectory: URL
    private var workingDirectory: URL?

    public init(shell: String = "/bin/zsh",
                environment: [String: String]? = nil,
                workingDirectory: URL? = nil,
                logDirectory: URL? = nil) {
        self.shell = shell
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logDirectory = logDirectory ?? Self.defaultLogDirectory()
    }

    public func setWorkingDirectory(_ url: URL?) { workingDirectory = url }

    // MARK: - Starting

    /// Spawns `command` detached and returns immediately. `directory` overrides
    /// the session's working directory for this one command.
    public func start(command: String,
                      purpose: String = "",
                      directory: URL? = nil) throws -> Record {
        let id = UUID()
        let logURL = try prepareLogFile(for: id)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        if let directory = directory ?? workingDirectory {
            process.currentDirectoryURL = directory
        }
        if let environment { process.environment = environment }

        // stdout and stderr share one handle so the log reads in the order the
        // command actually produced it — a compiler error and the line that
        // caused it are useless interleaved wrongly.
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: logURL)
        } catch {
            throw Failure.logUnreadable(error.localizedDescription)
        }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let pid = finished.processIdentifier
            ProcessLifecycleGuard.shared.unregister(pid)
            Task { await self?.finish(id: id, exitCode: status) }
        }

        do {
            try process.run()
        } catch {
            try? handle.close()
            throw Failure.launchFailed(error.localizedDescription)
        }

        ProcessLifecycleGuard.shared.register(process.processIdentifier)

        let record = Record(id: id, command: command, purpose: purpose,
                            logURL: logURL, startedAt: Date())
        records[id] = record
        processes[id] = process
        logHandles[id] = handle
        return record
    }

    // MARK: - Reading

    /// Reads a page of `id`'s log starting at line `offset`.
    public func readLog(id: UUID, offset: Int = 0, limit: Int? = nil) throws -> LogPage {
        guard let record = records[id] else {
            throw Failure.unknownProcess(id.uuidString)
        }

        let text: String
        do {
            let data = try Data(contentsOf: record.logURL)
            text = String(decoding: data, as: UTF8.self)
        } catch {
            throw Failure.logUnreadable(error.localizedDescription)
        }

        // A log ending in a newline would otherwise report a phantom final line,
        // and the model would poll forever waiting for it to fill.
        var allLines = text.components(separatedBy: "\n")
        if allLines.last == "" { allLines.removeLast() }

        let start = max(0, min(offset, allLines.count))
        let count = max(0, limit ?? Self.defaultLimit)
        var page = Array(allLines[start..<min(start + count, allLines.count)])

        // Bound by characters as well as lines: one `-showBuildSettings` line
        // can be longer than the page budget on its own.
        var truncated = false
        var budget = Self.maxCharactersPerPage
        var bounded: [String] = []
        for line in page {
            if budget <= 0 { truncated = true; break }
            bounded.append(String(line.prefix(budget)))
            budget -= line.count + 1
        }
        page = bounded

        return LogPage(lines: page,
                       nextOffset: start + page.count,
                       totalLines: allLines.count,
                       truncated: truncated,
                       record: record)
    }

    public func record(id: UUID) -> Record? { records[id] }

    public func allRecords() -> [Record] {
        records.values.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Stopping

    /// SIGTERM, then SIGKILL a second later if it is still up. Returns false
    /// when the process had already exited.
    @discardableResult
    public func kill(id: UUID) async throws -> Bool {
        guard let record = records[id] else {
            throw Failure.unknownProcess(id.uuidString)
        }
        guard let process = processes[id], process.isRunning, record.isRunning else {
            return false
        }

        process.terminate()
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        return true
    }

    /// Stops everything this manager started. The host calls it when a chat tab
    /// closes — the processes belong to that conversation, not to the app.
    public func terminateAll() async {
        for id in processes.keys {
            _ = try? await kill(id: id)
        }
    }

    // MARK: - Internals

    private func finish(id: UUID, exitCode: Int32) {
        records[id]?.exitCode = exitCode
        records[id]?.finishedAt = Date()
        try? logHandles[id]?.close()
        logHandles[id] = nil
        processes[id] = nil
    }

    private func prepareLogFile(for id: UUID) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: logDirectory, withIntermediateDirectories: true)
        } catch {
            throw Failure.logUnreadable(error.localizedDescription)
        }
        let url = logDirectory.appendingPathComponent("\(id.uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw Failure.logUnreadable("Could not create \(url.path)")
        }
        return url
    }

    /// Inside Application Support, which is the sandbox container when the host
    /// is sandboxed and a real path when it is not — either way it is writable
    /// without asking the user for anything.
    private static func defaultLogDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SwiftChatKit", isDirectory: true)
            .appendingPathComponent("BackgroundProcesses", isDirectory: true)
    }
}

#endif
