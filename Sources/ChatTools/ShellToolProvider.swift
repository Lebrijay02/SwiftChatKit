//
//  ShellToolProvider.swift
//  SwiftChatKit
//
//  Running commands is the single most dangerous capability in the package, so
//  it ships as its own provider a host must opt into, is never auto-allowed,
//  and is always treated as mutating.
//

#if os(macOS)

import Foundation
import ChatCore

public final class ShellToolProvider: ToolProvider {

    public static let toolName = "runCommand"

    private let runner: CommandRunner

    public init(shell: String = "/bin/zsh",
                timeout: TimeInterval = 120,
                outputLimit: Int = 30_000,
                environment: [String: String]? = nil) {
        self.runner = CommandRunner(shell: shell, timeout: timeout,
                                    outputLimit: outputLimit, environment: environment)
    }

    public var declarations: [ToolDeclaration] { [Self.declaration] }

    public static let declaration = ToolDeclaration(
        name: ShellToolProvider.toolName,
        description: """
            Runs a shell command in the working directory and returns its \
            stdout, stderr, and exit code. Prefer the dedicated file tools for \
            reading, searching, and editing — they are cheaper and safer. Use \
            this for builds, tests, git, and package managers. Commands are \
            killed after the timeout, so avoid anything interactive or \
            long-running that never exits.
            """,
        parameters: [
            "command": .string(description: "The command line to run."),
            "description": .string(description: "A short description of what this command does, shown to the user when they are asked to approve it.")
        ],
        optional: ["description"])

    /// Deliberately empty: no shell command is safe enough to run unprompted.
    public var autoAllowedToolNames: Set<String> { [] }

    public var mutatingToolNames: Set<String> { [Self.toolName] }

    public func handles(_ name: String) -> Bool { name == Self.toolName }

    public func workingDirectoryChanged(to url: URL?) async {
        await runner.setWorkingDirectory(url)
    }

    public func approvalCard(for call: ToolCall) async -> PermissionRequest? {
        let command = call.arguments["command"]?.stringValue ?? ""
        return PermissionRequest(
            toolName: call.name,
            title: call.arguments["description"]?.stringValue ?? "Run command",
            detail: command)
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
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
}

#endif
