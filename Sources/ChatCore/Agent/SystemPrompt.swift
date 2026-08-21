//
//  SystemPrompt.swift
//  SwiftChatKit
//
//  Composable system-prompt blocks and the assembler that stitches them into
//  one instruction string.
//
//  Blocks are separate rather than one blob because most of them are
//  conditional: plan mode, skills and compression sections only appear when
//  those features are active, and a host swapping the persona should not have
//  to restate the behavioural guidance it wants to keep.
//

import Foundation

// MARK: - Persona

/// The assistant's identity and standing behavioural guidance. Every block is a
/// plain string, so a host can replace any one of them without inheriting the
/// rest — the defaults describe a general-purpose coding assistant.
public struct ChatPersona: Sendable, Equatable {

    /// Who the assistant is and what it is for. The one block worth customizing
    /// in almost every deployment.
    public var identity: String
    /// Output format and tone.
    public var communication: String
    /// How to write and edit code. Set nil for non-coding assistants.
    public var code: String?
    /// Scope discipline — do what was asked.
    public var doingTasks: String?
    /// Guidance for the file tools. Set nil when no file provider is installed.
    public var fileOperations: String?
    /// Guidance for the shell tool. Set nil when no shell provider is installed.
    public var runningCommands: String?
    /// Guidance for the todo tool.
    public var taskManagement: String?
    /// Appended verbatim after the standing blocks.
    public var additionalBlocks: [String]

    /// The tool-guidance blocks default to nil, matching the package's default
    /// of shipping no tools: a prompt that describes a file tool to a session
    /// that has none teaches the model to call something that isn't there.
    public init(identity: String,
                communication: String = ChatPersona.communicationBlock,
                code: String? = nil,
                doingTasks: String? = ChatPersona.doingTasksBlock,
                fileOperations: String? = nil,
                runningCommands: String? = nil,
                taskManagement: String? = nil,
                additionalBlocks: [String] = []) {
        self.identity = identity
        self.communication = communication
        self.code = code
        self.doingTasks = doingTasks
        self.fileOperations = fileOperations
        self.runningCommands = runningCommands
        self.taskManagement = taskManagement
        self.additionalBlocks = additionalBlocks
    }

    /// The blank canvas: a neutral assistant with no tool or code guidance,
    /// because a fresh session has no tools. Add the blocks that match the
    /// providers you installed, or start from `.codingAgent`.
    public static let `default` = ChatPersona(identity: assistantIdentityBlock)

    /// Identity and communication only — nothing about how to approach work.
    public static let minimal = ChatPersona(identity: assistantIdentityBlock,
                                            doingTasks: nil)

    /// Every behavioural block enabled, describing file, shell and todo tools.
    /// Pair it with `FileToolProvider`, `ShellToolProvider` and `enableTodos`;
    /// on its own it advertises tools the session doesn't have.
    public static let codingAgent = ChatPersona(identity: identityBlock,
                                                code: codeBlock,
                                                fileOperations: fileOperationsBlock,
                                                runningCommands: runningCommandsBlock,
                                                taskManagement: taskManagementBlock)
}

// MARK: - Default blocks

public extension ChatPersona {

    /// The default identity. Says nothing about tools or a domain, because the
    /// default session has neither.
    static let assistantIdentityBlock = """
    You are a helpful assistant. Answer the user's questions accurately and say so when \
    you don't know something rather than guessing.
    """

    static let identityBlock = """
    You are a coding assistant. You help developers work on their projects: writing and editing \
    code, exploring codebases, and answering questions about them.
    """

    static let communicationBlock = """

    # Communication
    Your output is rendered as Markdown in a chat panel. Be concise and direct: answer the user's \
    question first, then add only the detail that changes what they would do next. Avoid preamble \
    ("Great question!", "Sure, I can help with that") and postamble summaries of what you just did. \
    Don't use headers for short answers; use them only to structure genuinely long responses. Always \
    wrap code in fenced code blocks with a language tag. Refer to code locations as `path/File.ext:line` \
    so the user can find them. When you explain a problem, lead with the cause, not the investigation \
    story.
    """

    static let codeBlock = """

    # Code
    When editing existing code, match the file's style: its naming, idioms, indentation, and comment \
    density. Don't add comments that narrate what the code does or that talk to the reviewer; only \
    comment what the code can't say itself. Prefer editing existing files over creating new ones, and \
    never create files the task doesn't require. Don't refactor, rename, or "improve" code the user \
    didn't ask about.
    """

    static let doingTasksBlock = """

    # Doing tasks
    Do what was asked — nothing more, nothing less. If the request is ambiguous in a way that changes \
    the implementation, ask; otherwise proceed. Report outcomes faithfully: if something failed or you \
    skipped a step, say so plainly instead of glossing over it.
    """

    static let fileOperationsBlock = """

    # Working with files
    You have tools to read, search, and modify the user's working directory. They are always \
    available, but most messages don't need them: for general or conceptual questions, answer \
    directly without calling any tool. Touch the project only when the task requires reading or \
    changing its files, and never run a broad scan (recursive directory listings, bulk file reads) \
    unless the user explicitly asks you to analyze the project.

    When you do work with files:
    - Establish the working directory before the first file operation of a task, so paths resolve \
    correctly.
    - To find a file by name, use the glob tool with the filename. Use the grep tool only when \
    searching for text or code patterns inside file contents.
    - When the user names an existing folder, locate it with glob before creating files there.
    - Read a file before editing it. After reading, don't echo the file's contents back to the user — \
    acknowledge it and move on.
    - Verify a path exists before creating files under it, and check the result of every write or edit \
    instead of assuming it succeeded.
    """

    static let runningCommandsBlock = """

    # Running commands
    Use the command tool for builds, tests, and version control — always pass the working directory. \
    Explain what a non-obvious command does before running it. Never run destructive commands \
    (recursive deletes, force pushes, hard resets) unless the user explicitly asked for exactly that. \
    If a command fails, read the error and fix the cause instead of retrying blindly.
    """

    static let taskManagementBlock = """

    # Task management
    For any task that takes 3 or more distinct steps, use the todo tool to keep a visible checklist: \
    create it before starting, mark exactly one item in progress while you work on it, and mark items \
    completed the moment they're done. Don't batch completions. For trivial one-step tasks, skip the \
    checklist entirely.
    """

    /// Appended only while plan mode is active. The prohibition is restated here
    /// even though the loop hard-blocks mutating tools, because a model told it
    /// may not write produces a better plan than one that keeps trying and failing.
    static let planModeBlock = """

    # Plan mode (ACTIVE)
    You are in plan mode. You may ONLY gather information: read files, search, list directories, and \
    run read-only commands. You must NOT modify files, create files, or run mutating commands — those \
    tools will be rejected. First explore whatever is needed to design the change, then call \
    exitPlanMode with a concise Markdown plan (numbered steps, files to touch). Do not describe the \
    plan in a regular message — always deliver it through exitPlanMode so the user can approve it.
    """
}

// MARK: - Assembly

/// Everything that varies between model rebuilds. Held together so the
/// fingerprint covers exactly the inputs the prompt is built from.
public struct SystemPromptContext: Sendable, Equatable {

    public var persona: ChatPersona
    public var planMode: Bool
    /// Skill listing from `SkillsService.skillsText()`.
    public var skillsText: String
    /// Compression contract from an active `ContextCompressor`.
    public var compressorInstruction: String
    /// Project-level instructions read from the working directory.
    public var projectContext: String
    /// Heading for the project context block, e.g. the filename it came from.
    public var projectContextTitle: String
    /// Host-supplied sections appended last, such as a component catalog.
    public var additionalSections: [String]

    public init(persona: ChatPersona = .default,
                planMode: Bool = false,
                skillsText: String = "",
                compressorInstruction: String = "",
                projectContext: String = "",
                projectContextTitle: String = "Project instructions",
                additionalSections: [String] = []) {
        self.persona = persona
        self.planMode = planMode
        self.skillsText = skillsText
        self.compressorInstruction = compressorInstruction
        self.projectContext = projectContext
        self.projectContextTitle = projectContextTitle
        self.additionalSections = additionalSections
    }
}

public enum SystemPromptBuilder {

    /// Assembles the full system instruction. Order is deliberate: identity and
    /// standing behaviour first, then mode-specific overrides, then context that
    /// should take precedence over the defaults it contradicts.
    public static func build(_ context: SystemPromptContext) -> String {
        let persona = context.persona

        var instruction = persona.identity
        instruction += persona.communication
        if let code = persona.code { instruction += code }
        if let files = persona.fileOperations { instruction += files }
        if let commands = persona.runningCommands { instruction += commands }
        if let todos = persona.taskManagement { instruction += todos }
        if let tasks = persona.doingTasks { instruction += tasks }

        for block in persona.additionalBlocks {
            instruction += block
        }

        if context.planMode {
            instruction += ChatPersona.planModeBlock
        }

        if !context.compressorInstruction.isEmpty {
            instruction += context.compressorInstruction
        }

        if !context.skillsText.isEmpty {
            instruction += "\n\(context.skillsText)"
        }

        for section in context.additionalSections where !section.isEmpty {
            instruction += "\n\n\(section)"
        }

        // Last, so it outranks the defaults it contradicts.
        if !context.projectContext.isEmpty {
            instruction += """


            # \(context.projectContextTitle)
            The working directory contains instructions from the team. Follow them; they override \
            your defaults where they conflict.

            \(context.projectContext)
            """
        }

        return instruction
    }

    /// Cheap identity for a built prompt. The session compares this against the
    /// value baked into the current model to decide whether a rebuild is needed,
    /// which avoids reassembling and re-uploading the prompt every turn.
    public static func fingerprint(_ context: SystemPromptContext) -> String {
        [
            String(context.persona.identity.hashValue),
            context.planMode ? "plan" : "-",
            String(context.skillsText.hashValue),
            String(context.compressorInstruction.hashValue),
            String(context.projectContext.hashValue),
            String(context.additionalSections.joined().hashValue),
        ].joined(separator: "|")
    }
}
