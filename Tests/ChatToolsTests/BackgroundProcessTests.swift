import Foundation
import Testing
import ChatCore
@testable import ChatTools

@Suite("Background processes")
struct BackgroundProcessTests {

    /// Logs go to a throwaway directory rather than Application Support, so a
    /// test run never touches the real one.
    private func manager(_ root: URL) -> BackgroundProcessManager {
        BackgroundProcessManager(logDirectory: root)
    }

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sck-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls until `predicate` holds. Sleeping a fixed interval instead would
    /// either be slow or flaky depending on the machine.
    private func eventually(timeout: TimeInterval = 10,
                            _ predicate: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @Test("Starting returns immediately, well before the command finishes")
    func startDoesNotBlock() async throws {
        let root = try scratch()
        let manager = manager(root)

        let began = Date()
        let record = try await manager.start(command: "sleep 3; echo done")
        let elapsed = Date().timeIntervalSince(began)

        #expect(elapsed < 1.0)
        #expect(await manager.record(id: record.id)?.isRunning == true)

        _ = try await manager.kill(id: record.id)
    }

    @Test("Output accumulates in the log and the exit code is recorded")
    func outputAndExit() async throws {
        let root = try scratch()
        let manager = manager(root)

        let record = try await manager.start(command: "echo hello; echo oops >&2; exit 3")

        let finished = try await eventually {
            await manager.record(id: record.id)?.isRunning == false
        }
        #expect(finished)

        let page = try await manager.readLog(id: record.id)
        #expect(page.lines.contains("hello"))
        // stdout and stderr share a handle, so both land in the one log.
        #expect(page.lines.contains("oops"))
        #expect(page.record.exitCode == 3)
        #expect(page.record.isRunning == false)
    }

    @Test("nextOffset pages a log without re-reading what was already seen")
    func pagingFollowsALog() async throws {
        let root = try scratch()
        let manager = manager(root)

        let record = try await manager.start(command: "for i in 1 2 3 4 5; do echo line$i; done")
        _ = try await eventually { await manager.record(id: record.id)?.isRunning == false }

        let first = try await manager.readLog(id: record.id, offset: 0, limit: 2)
        #expect(first.lines == ["line1", "line2"])
        #expect(first.nextOffset == 2)

        let second = try await manager.readLog(id: record.id, offset: first.nextOffset, limit: 2)
        #expect(second.lines == ["line3", "line4"])
        #expect(second.nextOffset == 4)

        // Polling past the end returns nothing rather than repeating the tail.
        let past = try await manager.readLog(id: record.id, offset: 99)
        #expect(past.lines.isEmpty)
    }

    @Test("A page is bounded by characters as well as by lines")
    func pageIsBounded() async throws {
        let root = try scratch()
        let manager = manager(root)

        // One line far longer than the whole page budget.
        let record = try await manager.start(
            command: "printf 'x%.0s' $(seq 1 60000); echo")
        _ = try await eventually { await manager.record(id: record.id)?.isRunning == false }

        let page = try await manager.readLog(id: record.id, limit: 500)
        let characters = page.lines.reduce(0) { $0 + $1.count }
        #expect(characters <= BackgroundProcessManager.maxCharactersPerPage)
    }

    @Test("Killing stops a long-running command; killing a finished one says so")
    func killing() async throws {
        let root = try scratch()
        let manager = manager(root)

        let record = try await manager.start(command: "sleep 30")
        #expect(try await manager.kill(id: record.id) == true)

        let stopped = try await eventually {
            await manager.record(id: record.id)?.isRunning == false
        }
        #expect(stopped)

        // Already gone: reported as false rather than thrown, so the model reads
        // it as a fact instead of an error to recover from.
        #expect(try await manager.kill(id: record.id) == false)
    }

    @Test("An unknown id is an error the model can act on")
    func unknownID() async throws {
        let root = try scratch()
        let manager = manager(root)

        await #expect(throws: BackgroundProcessManager.Failure.self) {
            _ = try await manager.readLog(id: UUID())
        }
    }

    @Test("terminateAll stops everything the manager started")
    func terminateAll() async throws {
        let root = try scratch()
        let manager = manager(root)

        let first = try await manager.start(command: "sleep 30")
        let second = try await manager.start(command: "sleep 30")

        await manager.terminateAll()

        let bothStopped = try await eventually {
            let a = await manager.record(id: first.id)?.isRunning == false
            let b = await manager.record(id: second.id)?.isRunning == false
            return a && b
        }
        #expect(bothStopped)
    }

    @Test("The tools round-trip a process from start to log to kill")
    func toolsRoundTrip() async throws {
        let provider = ShellToolProvider()

        let started = await provider.execute(ToolCall(
            name: ShellToolProvider.startBackgroundProcess,
            arguments: ["command": .string("echo from-tools; sleep 30")]))
        let processId = try #require(started.payload["processId"]?.stringValue)

        var output = ""
        _ = try await eventually {
            let read = await provider.execute(ToolCall(
                name: ShellToolProvider.readProcessLog,
                arguments: ["processId": .string(processId)]))
            output = read.payload["output"]?.stringValue ?? ""
            return output.contains("from-tools")
        }
        #expect(output.contains("from-tools"))

        let killed = await provider.execute(ToolCall(
            name: ShellToolProvider.killBackgroundProcess,
            arguments: ["processId": .string(processId)]))
        #expect(killed.payload["terminated"]?.boolValue == true)
    }

    @Test("A malformed processId is refused rather than crashing")
    func malformedID() async {
        let provider = ShellToolProvider()
        let result = await provider.execute(ToolCall(
            name: ShellToolProvider.readProcessLog,
            arguments: ["processId": .string("not-a-uuid")]))
        #expect(result.errorMessage != nil)
    }
}
