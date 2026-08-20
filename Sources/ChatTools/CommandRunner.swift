//
//  CommandRunner.swift
//  SwiftChatKit
//

#if os(macOS)

import Foundation
import ChatCore

/// Runs shell commands with a watchdog and bounded output.
public actor CommandRunner {

    public struct Output: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool
    }

    private let shell: String
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let environment: [String: String]?
    private var workingDirectory: URL?

    public init(shell: String = "/bin/zsh",
                timeout: TimeInterval = 120,
                outputLimit: Int = 30_000,
                environment: [String: String]? = nil,
                workingDirectory: URL? = nil) {
        self.shell = shell
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func setWorkingDirectory(_ url: URL?) { workingDirectory = url }

    public func run(_ command: String) async -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Output(stdout: "", stderr: error.localizedDescription,
                          exitCode: -1, timedOut: false)
        }

        // Read both pipes concurrently with the wait. Draining after
        // termination deadlocks as soon as a command fills the 64 KB buffer.
        async let stdoutData = Self.read(stdoutPipe)
        async let stderrData = Self.read(stderrPipe)

        let timedOut = await Self.wait(for: process, timeout: timeout)
        let out = await stdoutData
        let err = await stderrData

        return Output(
            stdout: truncate(String(decoding: out, as: UTF8.self)),
            stderr: truncate(String(decoding: err, as: UTF8.self)),
            exitCode: timedOut ? -1 : process.terminationStatus,
            timedOut: timedOut)
    }

    /// Waits for `process`, killing it past the deadline. Returns whether the
    /// watchdog fired.
    private static func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                // SIGTERM is a request; a wedged process needs SIGKILL.
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private static func read(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Keeps the head and the tail: a build log's first error and its final
    /// summary both matter, and the middle rarely does.
    private func truncate(_ text: String) -> String {
        guard text.count > outputLimit else { return text }
        let half = outputLimit / 2
        let head = text.prefix(half)
        let tail = text.suffix(half)
        let omitted = text.count - outputLimit
        return "\(head)\n\n… \(omitted) characters omitted …\n\n\(tail)"
    }
}

#endif
