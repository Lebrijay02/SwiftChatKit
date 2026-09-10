//
//  AgentTools.swift
//  SwiftChatKit
//
//  The tools the session implements itself, because they act on the session's
//  own state rather than on the outside world: the todo checklist, plan-mode
//  exit, and structured questions back to the user.
//
//  A provider can't own these — they'd need a reference back to the session
//  that owns them. Everything that touches the world outside the session is a
//  `ToolProvider` instead.
//

import Foundation

public enum AgentTools {

    public static let todoWrite = "todoWrite"
    public static let exitPlanMode = "exitPlanMode"
    public static let askUser = "askUser"
    public static let toolSearch = "toolSearch"

    /// Every name the session can handle itself. Whichever of them are enabled
    /// are dispatched before any provider is consulted, so a provider cannot
    /// shadow them — but none of them are offered unless the host asks.
    public static let allNames: Set<String> = [todoWrite, exitPlanMode, askUser, toolSearch]

    public static let todoWriteDeclaration = ToolDeclaration(
        name: todoWrite,
        description: """
        Create or update the visible task checklist for the current job. Call it when a task \
        needs 3+ distinct steps: once up front with all steps, then again as each step starts \
        (mark it in_progress — exactly one at a time) and finishes (mark it completed immediately). \
        Always send the complete list, not a delta. Skip it for trivial single-step tasks.
        """,
        parameters: [
            "todos": .array(
                items: .object(
                    properties: [
                        "content": .string(description: "Imperative description of the step"),
                        "status": .string(description: "pending | in_progress | completed"),
                    ],
                    description: "One todo item"),
                description: "The full todo list, replacing the previous one"),
        ])

    public static let askUserDeclaration = ToolDeclaration(
        name: askUser,
        description: """
        Ask the user structured questions and wait for their answers. Use it when a decision \
        is genuinely the user's to make (requirements, preferences, trade-offs) instead of \
        asking in prose. Send 1-4 questions at once, each with 2-4 mutually exclusive options; \
        the user can always answer with their own free text instead of picking an option. \
        When the decision is about something concrete — a snippet, a diff, a layout — put it in \
        previewContent so they can see what they are choosing between. \
        Don't use it for facts you can discover yourself or choices with an obvious default.
        """,
        parameters: [
            "questions": .array(
                items: .object(
                    properties: [
                        "question": .string(description: "The complete question, ending with a question mark"),
                        "header": .string(description: "Very short topic label (max ~12 chars), e.g. 'Platform', 'Database'"),
                        "options": .array(
                            items: .object(
                                properties: [
                                    "label": .string(description: "Concise display text for the choice (1-5 words)"),
                                    "description": .string(description: "One sentence on what this choice means or implies"),
                                ],
                                description: "One selectable option"),
                            description: "2-4 distinct choices for this question"),
                        "multiSelect": .boolean(description: "true when several options may be chosen together"),
                        "previewContent": .string(description: "Optional Markdown shown above the choices — the code, diff, or layout the question is about. Use a fenced block for code. Include it whenever the user is choosing between things they need to see to judge."),
                    ],
                    optional: ["multiSelect", "previewContent"],
                    description: "One question"),
                description: "The questions to ask (1-4)"),
        ])

    /// Offered only while some deferred tool is still hidden. Once the model has
    /// loaded them all there is nothing left to search for, and leaving the tool
    /// in the prompt would just invite calls that return nothing.
    public static let toolSearchDeclaration = ToolDeclaration(
        name: toolSearch,
        description: """
        Find specialized tools that are not listed in your prompt. This session keeps rarely-used \
        tools out of the way until they are needed, so if a task sounds like it needs a capability \
        you cannot see — scaffolding a project, indexing a workspace, a specific integration — \
        search for it here before concluding it is impossible. Describe the capability in plain \
        words ("create a new Xcode project"), not a guessed tool name. Anything found becomes \
        callable on your next step, so search first and call it after.
        """,
        parameters: [
            "query": .string(description: "What you are trying to do, in plain words. Omit to list every available tool."),
        ],
        optional: ["query"])

    /// Offered to the model only while plan mode is active. A model that can see
    /// this tool outside plan mode will eventually call it.
    public static let exitPlanModeDeclaration = ToolDeclaration(
        name: exitPlanMode,
        description: """
        Only available in plan mode. Call it when you finished researching and have a concrete \
        implementation plan, to present the plan and ask the user to approve leaving plan mode. \
        Do NOT call it for read-only work — only when the next step would modify files or run commands.
        """,
        parameters: [
            "plan": .string(description: "The implementation plan in Markdown (concise: numbered steps, files to touch)"),
        ])
}

// MARK: - Standard refusals

/// Messages sent back to the model in place of a result. Phrased as instructions
/// rather than bare errors: a model that reads "don't retry" stops retrying,
/// where one that reads "failed" tries again and burns the turn budget.
enum AgentRefusal {

    static let denied = """
    The user declined this tool call. Don't retry it — ask the user how they'd like to \
    proceed instead.
    """

    static let planModeBlocked = """
    Plan mode is active — modifications are not allowed. Finish researching and call \
    \(AgentTools.exitPlanMode) with your plan instead.
    """

    static let cancelled = "The user stopped the run before this tool finished."

    static func unhandled(_ name: String) -> String {
        "No tool named '\(name)' is available. Don't retry it."
    }
}
