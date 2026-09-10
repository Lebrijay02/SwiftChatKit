//
//  ShellToolProvider.swift
//  SwiftChatKit
//
//  Running commands is the single most dangerous capability in the package, so
//  it ships as its own provider a host must opt into, is never auto-allowed,
//  and is always treated as mutating.
//
//  Two execution models sit side by side. `runCommand` blocks the turn and
//  returns the output, which is what you want for anything that finishes in
//  seconds. `startBackgroundProcess` returns an id immediately and streams to a
//  log the model pages through with `readProcessLog`, which is the only sane
//  way to run a build.
//

#if os(macOS)

import Foundation
import ChatCore

public final class ShellToolProvider: ToolProvider {

    public static let toolName = "runCommand"
    public static let startBackgroundProcess = "startBackgroundProcess"
    public static let readProcessLog = "readProcessLog"
    public static let killBackgroundProcess = "killBackgroundProcess"

    private let runner: CommandRunner
    private let background: BackgroundProcessManager

    public init(shell: String = "/bin/zsh",
                timeout: TimeInterval = 120,
                outputLimit: Int = 30_000,
                environment: [String: String]? = nil) {
        self.runner = CommandRunner(shell: shell, timeout: timeout,
                                    outputLimit: outputLimit, environment: environment)
        self.background = BackgroundProcessManager(shell: shell, environment: environment)
    }

    /// The manager backing the background tools, so a host can page the same
    /// logs from its own UI and stop everything when a tab closes.
    public var backgroundProcesses: BackgroundProcessManager { background }

    /// Stops every process this provider started. Call it when the owning
    /// conversation goes away — the children belong to it, not to the app.
    public func terminateBackgroundProcesses() async {
        await background.terminateAll()
    }

    // MARK: - Declarations

    public var declarations: [ToolDeclaration] { Self.allDeclarations }

    public static let allDeclarations: [ToolDeclaration] = [
        declaration, startDeclaration, readLogDeclaration, killDeclaration
    ]

    public static let declaration = ToolDeclaration(
        name: ShellToolProvider.toolName,
        description: """
            Runs a shell command in the working directory and returns its \
            stdout, stderr, and exit code. Prefer the dedicated file tools for \
            reading, searching, and editing — they are cheaper and safer. Use \
            this for git, package managers, and anything else that finishes in \
            seconds. Commands are killed after the timeout, so use \
            startBackgroundProcess instead for builds, test suites, servers, or \
            anything else that runs long or never exits.
            """,
        parameters: [
            "command": .string(description: "The command line to run."),
            "description": .string(description: "A short description of what this command does, shown to the user when they are asked to approve it.")
        ],
        optional: ["description"])

    public static let startDeclaration = ToolDeclaration(
        name: ShellToolProvider.startBackgroundProcess,
        description: """
            Starts a shell command detached and returns a processId immediately \
            without waiting for it to finish. Its stdout and stderr go to a log \
            file you read with readProcessLog. Use this for builds, test suites, \
            servers, watchers, and anything else that takes more than a few \
            seconds — it leaves you free to keep working while the command runs. \
            Poll readProcessLog rather than guessing how long to wait, and stop \
            anything long-lived with killBackgroundProcess when you are done.
            """,
        parameters: [
            "command": .string(description: "The command line to run."),
            "description": .string(description: "A short description of what this command does, shown to the user when they are asked to approve it."),
            "directory": .string(description: "Absolute path to run in. Defaults to the working directory.")
        ],
        optional: ["description", "directory"])

    public static let readLogDeclaration = ToolDeclaration(
        name: ShellToolProvider.readProcessLog,
        description: """
            Reads a page of output from a background process and reports whether \
            it is still running. Pass the nextOffset from the previous call to \
            read only what has arrived since, which is how you follow a live \
            build without re-reading the whole log. When 'running' comes back \
            true and there are no new lines, the command is still working — do \
            something else and check again rather than polling in a tight loop.
            """,
        parameters: [
            "processId": .string(description: "The id returned by startBackgroundProcess."),
            "offset": .integer(description: "0-indexed line to start from. Defaults to 0."),
            "limit": .integer(description: "Maximum lines to return. Defaults to 200.")
        ],
        optional: ["offset", "limit"])

    public static let killDeclaration = ToolDeclaration(
        name: ShellToolProvider.killBackgroundProcess,
        description: """
            Stops a background process started with startBackgroundProcess. Use \
            it to shut down a server or watcher you started, or to abandon a \
            build you no longer need. Returns false if it had already exited.
            """,
        parameters: [
            "processId": .string(description: "The id returned by startBackgroundProcess.")
        ])

    // MARK: - Policy

    /// Only the read. No shell command is safe enough to run unprompted, but
    /// making the model ask permission to look at output the user already
    /// approved producing would turn following a build into a prompt storm.
    public var autoAllowedToolNames: Set<String> { [Self.readProcessLog] }

    /// Killing is a mutation of the world too — but a process this session
    /// started, so it is no more dangerous than the start that was approved.
    public var mutatingToolNames: Set<String> {
        [Self.toolName, Self.startBackgroundProcess, Self.killBackgroundProcess]
    }

    public func executionMode(for call: ToolCall) async -> ToolExecutionMode {
        call.name == Self.readProcessLog ? .concurrent : .exclusive
    }

    public func retrySafety(for call: ToolCall) async -> ToolRetrySafety {
        call.name == Self.readProcessLog ? .idempotent : .never
    }

    public func timeout(for call: ToolCall) async -> Duration? {
        call.name == Self.toolName ? nil : .seconds(60)
    }

    public func interruptionBehavior(for call: ToolCall) async -> ToolInterruptionBehavior {
        call.name == Self.readProcessLog ? .cancel : .finishBeforeInterrupt
    }

    public func resultRetention(for call: ToolCall) async -> ToolResultRetention {
        call.name == Self.readProcessLog ? .summarize : .retain
    }

    public func handles(_ name: String) -> Bool {
        Self.allDeclarations.contains { $0.name == name }
    }

    public func directoryScopeChanged(to scope: DirectoryScope) async {
        // Only the root matters here: a shell command runs *in* one directory,
        // and the additions widen what may be read, not where `cd` starts.
        await runner.setWorkingDirectory(scope.root)
        await background.setWorkingDirectory(scope.root)
    }

    public func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        switch call.name {
        case Self.toolName, Self.startBackgroundProcess:
            let command = call.arguments["command"]?.stringValue ?? ""
            let fallback = call.name == Self.toolName ? "Run command" : "Run command in the background"
            return PermissionRequest(
                toolName: call.name,
                title: call.arguments["description"]?.stringValue ?? fallback,
                detail: command)

        case Self.killBackgroundProcess:
            let id = call.arguments["processId"]?.stringValue ?? "?"
            var detail = id
            if let uuid = UUID(uuidString: id), let record = await background.record(id: uuid) {
                detail = record.command
            }
            return PermissionRequest(toolName: call.name,
                                     title: "Stop background process",
                                     detail: detail)

        default:
            return nil
        }
    }

    // MARK: - Execution

    public func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case Self.toolName:                return await runForeground(call)
        case Self.startBackgroundProcess:  return await startBackground(call)
        case Self.readProcessLog:          return await readLog(call)
        case Self.killBackgroundProcess:   return await killProcess(call)
        default:
            return .failure(call, "ShellToolProvider does not handle \(call.name).")
        }
    }

    private func runForeground(_ call: ToolCall) async -> ToolResult {
        guard let command = call.arguments["command"]?.stringValue, !command.isEmpty else {
            return .failure(call, "runCommand requires a non-empty `command`.")
        }
        let output = await runner.run(command)
        return .success(call, [
            "stdout": .string(output.stdout),
            "stderr": .string(output.stderr),
            "exitCode": .number(Double(output.exitCode)),
            "timedOut": .bool(output.timedOut)
        ])
    }

    private func startBackground(_ call: ToolCall) async -> ToolResult {
        guard let command = call.arguments["command"]?.stringValue, !command.isEmpty else {
            return .failure(call, "startBackgroundProcess requires a non-empty `command`.")
        }
        let directory = call.arguments["directory"]?.stringValue.flatMap { path -> URL? in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
        }
        do {
            let record = try await background.start(
                command: command,
                purpose: call.arguments["description"]?.stringValue ?? "",
                directory: directory)
            return .success(call, [
                "processId": .string(record.id.uuidString),
                "started": .bool(true),
                "note": .string("""
                Running in the background. Read its output with readProcessLog using this \
                processId; it has produced nothing yet.
                """)
            ])
        } catch {
            return .failure(call, error.localizedDescription)
        }
    }

    private func readLog(_ call: ToolCall) async -> ToolResult {
        guard let id = call.arguments["processId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return .failure(call, "readProcessLog requires a `processId` from startBackgroundProcess.")
        }
        do {
            let page = try await background.readLog(
                id: id,
                offset: call.arguments["offset"]?.intValue ?? 0,
                limit: call.arguments["limit"]?.intValue)

            var payload: [String: ChatValue] = [
                "output": .string(page.lines.joined(separator: "\n")),
                "nextOffset": .number(Double(page.nextOffset)),
                "totalLines": .number(Double(page.totalLines)),
                "truncated": .bool(page.truncated),
                "running": .bool(page.record.isRunning)
            ]
            if let exitCode = page.record.exitCode {
                payload["exitCode"] = .number(Double(exitCode))
            }
            return .success(call, payload)
        } catch {
            return .failure(call, error.localizedDescription)
        }
    }

    private func killProcess(_ call: ToolCall) async -> ToolResult {
        guard let id = call.arguments["processId"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return .failure(call, "killBackgroundProcess requires a `processId`.")
        }
        do {
            let wasRunning = try await background.kill(id: id)
            return .success(call, [
                "terminated": .bool(wasRunning),
                "note": .string(wasRunning
                    ? "The process was stopped."
                    : "The process had already exited; read its log for the final output.")
            ])
        } catch {
            return .failure(call, error.localizedDescription)
        }
    }
}

#endif
