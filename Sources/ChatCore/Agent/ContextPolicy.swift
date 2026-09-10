//
//  ContextPolicy.swift
//  SwiftChatKit
//
//  Keeping a long-running agentic session inside the model's context window.
//

import Foundation

/// Bounds on how much a session is allowed to accumulate before it prunes
/// itself.
///
/// An agentic loop grows its history without limit: every tool result stays in
/// the transcript so the model can refer back to it, and a handful of large
/// file reads or MCP responses can carry more text than everything the user
/// typed all session. Left alone this ends one way — the provider rejects the
/// next request for exceeding the window, and because *every* subsequent
/// request carries the same oversized history, the conversation is stuck. The
/// user's only escape is to throw the session away.
///
/// Both knobs exist to keep that from happening: a ceiling on what any single
/// tool result may contribute, and a threshold past which the session
/// summarizes itself and continues from the summary.
public struct ContextPolicy: Sendable, Equatable {

    /// What the session does once the prompt crosses `compactionThreshold`.
    public enum Overflow: String, Sendable, Equatable, CaseIterable {
        /// Summarize the conversation and continue from the summary.
        case compact
        /// Keep the full transcript on screen but replay only its recent tail.
        case slidingWindow
    }

    /// The model's input limit in tokens, or nil to never compact on size.
    ///
    /// There is no portable way to ask a backend for this, and guessing wrong
    /// in either direction is worse than not guessing: too high and the policy
    /// never fires, too low and the session compacts a conversation that had
    /// plenty of room. So the host states it.
    public var contextWindow: Int?

    /// Fraction of `contextWindow` that triggers compaction, measured against
    /// the prompt tokens the provider reported for the last turn.
    ///
    /// Well below 1.0 on purpose. The check happens *after* a turn, so the
    /// margin has to cover everything the next one might add before it is
    /// checked again — a long user message and several tool results.
    public var compactionThreshold: Double

    /// Ceiling on the characters a single tool result may contribute to the
    /// history, or nil for no ceiling.
    ///
    /// This is the blunt backstop that runs even when no `ContextCompressor` is
    /// configured. A compressor is the better answer — it keeps the content
    /// retrievable instead of discarding it — but a session without one should
    /// still not be one `readFile` away from an unusable window.
    public var maxToolResultCharacters: Int?

    /// How the session sheds context once the threshold is crossed.
    ///
    /// Compaction preserves meaning at the cost of detail; a sliding window
    /// preserves detail for the turns it keeps and drops the rest outright.
    /// Neither is right for every host, and the choice is often the user's, so
    /// it is a setting rather than a policy this type picks.
    public var overflow: Overflow

    /// Fraction of the transcript kept when a sliding window slides. Ignored
    /// under `.compact`.
    public var retainedFraction: Double

    public init(contextWindow: Int? = nil,
                compactionThreshold: Double = 0.75,
                maxToolResultCharacters: Int? = nil,
                overflow: Overflow = .compact,
                retainedFraction: Double = 0.5) {
        self.contextWindow = contextWindow
        self.compactionThreshold = compactionThreshold
        self.maxToolResultCharacters = maxToolResultCharacters
        self.overflow = overflow
        self.retainedFraction = retainedFraction
    }

    /// No truncation and no automatic compaction: the session grows until the
    /// provider refuses it. The default, because silently rewriting a host's
    /// transcript is not something to opt anyone into by surprise.
    public static let unbounded = ContextPolicy()

    /// The usual arrangement: compact at `threshold` of the window, and cap any
    /// one tool result at 100k characters — roughly 25k tokens, enough for a
    /// large file and far short of a window on its own.
    public static func window(_ tokens: Int,
                              threshold: Double = 0.75,
                              maxToolResultCharacters: Int? = 100_000,
                              overflow: Overflow = .compact) -> ContextPolicy {
        ContextPolicy(contextWindow: tokens,
                      compactionThreshold: threshold,
                      maxToolResultCharacters: maxToolResultCharacters,
                      overflow: overflow)
    }

    /// Whether `promptTokens` from the turn just finished has crossed the line.
    func shouldCompact(afterPromptTokens promptTokens: Int) -> Bool {
        guard let contextWindow, contextWindow > 0, promptTokens > 0 else { return false }
        return Double(promptTokens) >= Double(contextWindow) * compactionThreshold
    }
}

// MARK: - Truncation

extension ContextPolicy {

    /// Trims oversized string values in a tool result, leaving a marker in
    /// place of what was dropped.
    ///
    /// Only strings, and only the top level: the payloads that get large are
    /// file contents and command output, which arrive as one big string under
    /// one key. Walking arbitrary nesting to shave structured data would risk
    /// corrupting a shape the model is expected to parse.
    func truncating(_ result: ToolResult) -> ToolResult {
        guard let limit = maxToolResultCharacters, limit > 0 else { return result }

        var payload = result.payload
        var changed = false

        for (key, value) in payload {
            guard let text = value.stringValue, text.count > limit else { continue }
            let kept = String(text.prefix(limit))
            let dropped = text.count - limit
            // Said in the payload rather than logged, because the model is the
            // one that needs to know it is looking at a fragment — otherwise it
            // reports confidently on a file whose second half it never saw.
            payload[key] = .string(
                kept + "\n\n[… truncated \(dropped) characters of \(text.count) "
                     + "to stay within the context window. "
                     + "Read the rest in smaller ranges if you need it.]")
            changed = true
        }

        return changed ? ToolResult(callID: result.callID, name: result.name, payload: payload)
                       : result
    }
}
