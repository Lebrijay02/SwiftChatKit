//
//  AgentRuntime.swift
//  SwiftChatKit
//

import Foundation

public enum AgentContinuationReason: Equatable, Sendable {
    case toolResults
    case modelRetry(attempt: Int)
    case modelFallback
    case outputLimitRecovery(attempt: Int)
    case contextRecovery
    case completionFeedback
    case queuedInput
}

public enum AgentTerminationReason: Equatable, Sendable {
    case completed
    case stopped
    case turnLimit
    case tokenBudget
    case durationBudget
    case backendFailure(String)
    case contextOverflow
    case completionRejected(String)
}

public struct AgentRunState: Equatable, Sendable {
    public var input: TurnInput
    public var turn: Int
    public var usage: TokenUsage
    public var toolsCalled: [String]
    public var outputRecoveryCount: Int
    public var contextRecoveryAttempted: Bool
    public var continuation: AgentContinuationReason?

    public init(input: TurnInput,
                turn: Int = 0,
                usage: TokenUsage = .zero,
                toolsCalled: [String] = [],
                outputRecoveryCount: Int = 0,
                contextRecoveryAttempted: Bool = false,
                continuation: AgentContinuationReason? = nil) {
        self.input = input
        self.turn = turn
        self.usage = usage
        self.toolsCalled = toolsCalled
        self.outputRecoveryCount = outputRecoveryCount
        self.contextRecoveryAttempted = contextRecoveryAttempted
        self.continuation = continuation
    }
}

public enum BackendFailure: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case rateLimited(retryAfter: Duration?)
    case overloaded
    case authentication
    case connection(String)
    case timeout
    case contextOverflow
    case outputLimit
    case incompleteStream
    case safety(String)
    case invalidRequest(String)
    case permanent(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The request was cancelled."
        case .rateLimited:
            return "The model provider rate limited the request."
        case .overloaded:
            return "The model provider is temporarily overloaded."
        case .authentication:
            return "The model provider rejected authentication."
        case .connection(let message), .safety(let message), .invalidRequest(let message),
             .permanent(let message):
            return message
        case .timeout:
            return "The model request timed out."
        case .contextOverflow:
            return "The conversation exceeded the model context window."
        case .outputLimit:
            return "The response reached the model output limit."
        case .incompleteStream:
            return "The model stream ended before a finish event arrived."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .connection, .timeout, .incompleteStream:
            return true
        default:
            return false
        }
    }

    public static func classify(_ error: any Error) -> BackendFailure {
        if let failure = error as? BackendFailure { return failure }
        if error is CancellationError { return .cancelled }
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("429") || lower.contains("rate limit") { return .rateLimited(retryAfter: nil) }
        if lower.contains("529") || lower.contains("overload") { return .overloaded }
        if lower.contains("401") || lower.contains("403") || lower.contains("auth") { return .authentication }
        if lower.contains("context") && (lower.contains("window") || lower.contains("length")) {
            return .contextOverflow
        }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("network") || lower.contains("connection") || lower.contains("urlerror") {
            return .connection(message)
        }
        return .permanent(message)
    }
}

public struct RetryPolicy: Equatable, Sendable {
    public var maxAttempts: Int
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var jitter: Double

    public init(maxAttempts: Int = 3,
                initialDelay: Duration = .milliseconds(500),
                maximumDelay: Duration = .seconds(8),
                jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitter = max(0, jitter)
    }

    func delay(forAttempt attempt: Int) -> Duration {
        let base = initialDelay.timeInterval * pow(2, Double(max(0, attempt - 1)))
        let capped = min(base, maximumDelay.timeInterval)
        let randomized = capped * (1 + Double.random(in: 0...jitter))
        return .milliseconds(Int64(randomized * 1_000))
    }
}

public struct AgentBudget: Equatable, Sendable {
    public var maxTurns: Int
    public var maxPromptTokens: Int?
    public var maxCompletionTokens: Int?
    public var maxTotalTokens: Int?
    public var maximumDuration: Duration?

    public init(maxTurns: Int = 100,
                maxPromptTokens: Int? = nil,
                maxCompletionTokens: Int? = nil,
                maxTotalTokens: Int? = nil,
                maximumDuration: Duration? = nil) {
        self.maxTurns = max(1, maxTurns)
        self.maxPromptTokens = maxPromptTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.maxTotalTokens = maxTotalTokens
        self.maximumDuration = maximumDuration
    }

    func isExceeded(by usage: TokenUsage) -> Bool {
        if let maxPromptTokens, usage.prompt >= maxPromptTokens { return true }
        if let maxCompletionTokens, usage.completion >= maxCompletionTokens { return true }
        if let maxTotalTokens, usage.total >= maxTotalTokens { return true }
        return false
    }
}

public enum InFlightInputPolicy: Sendable {
    case reject
    case queue
    case interrupt
}

public enum ToolExecutionMode: Sendable {
    case concurrent
    case exclusive
}

public enum ToolInterruptionBehavior: Sendable {
    case cancel
    case finishBeforeInterrupt
}

public enum ToolRetrySafety: Sendable {
    case never
    case idempotent
    case idempotencyKey(String)
}

public enum ToolFailureKind: String, Equatable, Sendable {
    case transient
    case rateLimited
    case authentication
    case invalidInput
    case permissionDenied
    case permanent
    case cancelled
    case timedOut
}

public enum ToolResultRetention: Equatable, Sendable {
    case discard
    case summarize
    case retain
    case retainFields(Set<String>)
}

public struct ToolInvocation: Sendable {
    public let call: ToolCall
    public let turn: Int

    public init(call: ToolCall, turn: Int) {
        self.call = call
        self.turn = turn
    }
}

public enum ToolHookDecision: Sendable {
    case proceed
    case proceedWithArguments([String: ChatValue])
    case deny(String)
    case stopRun(String)
}

public protocol ToolHook: Sendable {
    func before(_ invocation: ToolInvocation) async -> ToolHookDecision
    func after(_ invocation: ToolInvocation, result: ToolResult) async -> ToolResult
}

public extension ToolHook {
    func before(_ invocation: ToolInvocation) async -> ToolHookDecision { .proceed }
    func after(_ invocation: ToolInvocation, result: ToolResult) async -> ToolResult { result }
}

public struct CompletionContext: Sendable {
    public let messages: [ChatMessage]
    public let usage: TokenUsage
    public let toolsCalled: [String]
    public let turn: Int

    public init(messages: [ChatMessage], usage: TokenUsage, toolsCalled: [String], turn: Int) {
        self.messages = messages
        self.usage = usage
        self.toolsCalled = toolsCalled
        self.turn = turn
    }
}

public enum CompletionDecision: Equatable, Sendable {
    case accept
    case continueWithFeedback(String)
    case reject(String)
}

public protocol CompletionValidator: Sendable {
    func validate(_ context: CompletionContext) async -> CompletionDecision
}

public struct AgentTransitionEvent: Equatable, Sendable {
    public let runID: UUID
    public let iteration: Int
    public let reason: AgentContinuationReason?
    public let termination: AgentTerminationReason?
    public let timestamp: Date
    public let toolCallIDs: [String]

    public init(runID: UUID,
                iteration: Int,
                reason: AgentContinuationReason? = nil,
                termination: AgentTerminationReason? = nil,
                timestamp: Date = Date(),
                toolCallIDs: [String] = []) {
        self.runID = runID
        self.iteration = iteration
        self.reason = reason
        self.termination = termination
        self.timestamp = timestamp
        self.toolCallIDs = toolCallIDs
    }
}

public protocol AgentTransitionTelemetry: Sendable {
    func record(_ event: AgentTransitionEvent) async
}

public protocol TokenEstimating: Sendable {
    func estimate(_ turns: [ChatTurn]) async -> Int
}

public struct CharacterTokenEstimator: TokenEstimating {
    public init() {}

    public func estimate(_ turns: [ChatTurn]) async -> Int {
        let characters = turns.reduce(into: 0) { total, turn in
            for part in turn.parts {
                switch part {
                case .text(let text): total += text.count
                case .inlineData(let data, _): total += data.count * 4 / 3
                case .toolCall(let call): total += call.name.count + ChatValue.object(call.arguments).jsonString().count
                case .toolResult(let result): total += result.name.count + ChatValue.object(result.payload).jsonString().count
                }
            }
        }
        return max(1, characters / 4)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
