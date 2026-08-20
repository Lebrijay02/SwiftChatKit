//
//  READMEExamples.swift
//  SwiftChatKit
//
//  Compile-checks the `ChatTools` samples in README.md. Imports the way a
//  consumer does — no @testable — so a sample that stops compiling breaks the
//  build rather than quietly rotting in the docs.
//

import Foundation
import ChatCore
import ChatTools

private enum BuiltInToolExamples {

    /// From "## Built-in tools".
    static func configure(backend: any ChatBackend, projectURL: URL) -> ChatSessionConfiguration {
        ChatSessionConfiguration(
            backend: backend,
            toolProviders: [
                FileToolProvider(fileSystem: LocalFileSystem(root: projectURL)),
                ShellToolProvider()
            ],
            workingDirectory: projectURL)
    }

    /// From "### The shell tool".
    static let shell = ShellToolProvider(shell: "/bin/zsh", timeout: 120, outputLimit: 30_000)

    /// From "### The file tools".
    static let readOnly: Set<String> = FileToolProvider.readOnlyNames

    /// From the glob paragraph.
    static let matched = GlobPattern.matches("Sources/View.swift", pattern: "**/*.swift")
}
