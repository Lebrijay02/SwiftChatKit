#if os(macOS)

import Foundation
import Testing
import ChatCore
@testable import ChatTools

@Suite("ShellToolProvider")
struct ShellToolProviderTests {

    @Test("A command's output and exit code come back")
    func runsACommand() async {
        let provider = ShellToolProvider(timeout: 10)
        let result = await provider.execute(
            ToolCall(name: ShellToolProvider.toolName, arguments: ["command": .string("echo hello")]))

        #expect(result.payload["stdout"]?.stringValue?.contains("hello") == true)
        #expect(result.payload["exitCode"]?.intValue == 0)
        #expect(result.payload["timedOut"]?.boolValue == false)
    }

    @Test("A non-zero exit is reported as data, not as an error")
    func nonZeroExit() async {
        let provider = ShellToolProvider(timeout: 10)
        let result = await provider.execute(
            ToolCall(name: ShellToolProvider.toolName, arguments: ["command": .string("exit 3")]))

        #expect(result.errorMessage == nil)
        #expect(result.payload["exitCode"]?.intValue == 3)
    }

    @Test("stderr is captured separately")
    func stderr() async {
        let provider = ShellToolProvider(timeout: 10)
        let result = await provider.execute(ToolCall(
            name: ShellToolProvider.toolName,
            arguments: ["command": .string("echo oops 1>&2")]))
        #expect(result.payload["stderr"]?.stringValue?.contains("oops") == true)
    }

    @Test("An empty command is refused")
    func emptyCommand() async {
        let result = await ShellToolProvider().execute(
            ToolCall(name: ShellToolProvider.toolName, arguments: [:]))
        #expect(result.errorMessage?.contains("non-empty") == true)
    }

    @Test("Shell commands are never auto-allowed and always count as mutating")
    func permissionPosture() {
        let provider = ShellToolProvider()
        #expect(provider.autoAllowedToolNames.isEmpty)
        #expect(provider.mutatingToolNames == [ShellToolProvider.toolName])
    }

    @Test("The approval card shows the command, titled by the model's description")
    func approvalCard() async {
        let card = await ShellToolProvider().approvalCard(for: ToolCall(
            name: ShellToolProvider.toolName,
            arguments: ["command": .string("git status"),
                        "description": .string("Check the working tree")]))
        #expect(card?.title == "Check the working tree")
        #expect(card?.detail == "git status")
    }
}

@Suite("CommandRunner")
struct CommandRunnerTests {

    @Test("Commands run in the working directory, and follow it when it changes")
    func workingDirectory() async throws {
        let sandbox = try Sandbox(["marker.txt": "x"])
        let runner = CommandRunner(timeout: 10)

        await runner.setWorkingDirectory(sandbox.root)
        let output = await runner.run("ls")
        #expect(output.stdout.contains("marker.txt"))
    }

    @Test("A command past the deadline is killed and flagged")
    func watchdog() async {
        let runner = CommandRunner(timeout: 0.3)
        let output = await runner.run("sleep 30")
        #expect(output.timedOut)
        #expect(output.exitCode == -1)
    }

    @Test("Output beyond the limit keeps the head and the tail")
    func truncation() async {
        let runner = CommandRunner(timeout: 20, outputLimit: 200)
        let output = await runner.run("seq 1 5000")

        #expect(output.stdout.contains("characters omitted"))
        #expect(output.stdout.hasPrefix("1\n2\n"))
        #expect(output.stdout.hasSuffix("5000\n"))
    }

    @Test("Output larger than a pipe buffer does not deadlock")
    func largeOutputDoesNotDeadlock() async {
        // 64 KB is the pipe buffer; a runner that drains only after waiting
        // hangs forever here.
        let runner = CommandRunner(timeout: 20, outputLimit: 10_000_000)
        let output = await runner.run("seq 1 200000")
        #expect(output.stdout.count > 100_000)
        #expect(output.exitCode == 0)
    }
}

#endif
