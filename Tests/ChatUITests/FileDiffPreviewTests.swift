//
//  FileDiffPreviewTests.swift
//  SwiftChatKitTests
//
//  The approval card's diff parser. Miscounting here means the user approves an
//  edit on the strength of a wrong summary.
//

import Testing
@testable import ChatUI

@Suite("Diff preview parsing")
struct FileDiffPreviewTests {

    @Test("Additions and deletions are counted separately")
    func counts() {
        let parsed = FileDiffPreviewView.parse(rawDiff: """
        --- a.swift
        +++ a.swift
        @@ Replacement @@
        - let x = 1
        + let x = 2
        + let y = 3
        """)
        #expect(parsed.additions == 2)
        #expect(parsed.deletions == 1)
    }

    @Test("File headers are dropped, hunk headers kept")
    func headers() {
        let parsed = FileDiffPreviewView.parse(rawDiff: """
        --- a.swift
        +++ a.swift
        @@ Replacement @@
         context
        """)
        #expect(parsed.lines.count == 2)
        #expect(parsed.lines.first?.type == .header)
    }

    @Test("Context lines carry both line numbers")
    func contextNumbering() {
        let parsed = FileDiffPreviewView.parse(rawDiff: " one\n two")
        #expect(parsed.lines.map(\.oldLineNumber) == [1, 2])
        #expect(parsed.lines.map(\.newLineNumber) == [1, 2])
        #expect(parsed.additions == 0 && parsed.deletions == 0)
    }

    @Test("The leading marker is stripped from the rendered text")
    func stripsMarker() {
        let parsed = FileDiffPreviewView.parse(rawDiff: "+ added")
        #expect(parsed.lines.first?.text == " added")
    }

    @Test("A whole-file write is all additions")
    func writeFile() {
        let parsed = FileDiffPreviewView.parseWriteFile(content: "a\nb\nc")
        #expect(parsed.additions == 3)
        #expect(parsed.deletions == 0)
        #expect(parsed.lines.allSatisfy { $0.type == .added })
        #expect(parsed.lines.map(\.newLineNumber) == [1, 2, 3])
    }

    @Test("An empty diff produces no rows")
    func empty() {
        #expect(FileDiffPreviewView.parse(rawDiff: "").lines.count == 1)
    }
}
