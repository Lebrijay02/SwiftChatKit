import Foundation
import Testing
@testable import ChatCore

@Suite("Deferred tool search")
struct DeferredToolIndexTests {

    private let catalog: [ToolDeclaration] = [
        ToolDeclaration(
            name: "createXcodeProject",
            description: "Scaffolds a brand new Xcode project on disk. Picks a template and writes the pbxproj.",
            parameters: [
                "name": .string(description: "Project name"),
                "directory": .string(description: "Where to create it"),
                "platform": .enumeration(values: ["macOS", "iOS"], description: "Target platform"),
            ],
            optional: ["platform"]),
        ToolDeclaration(
            name: "indexWorkspace",
            description: "Builds a symbol index over the workspace so later searches are fast.",
            parameters: ["path": .string(description: "Workspace root")]),
        ToolDeclaration(
            name: "saveResearchReport",
            description: "Writes a research report to docs/research as Markdown.",
            parameters: ["title": .string(), "body": .string()]),
    ]

    @Test("A plain-language query finds the tool it describes")
    func findsByIntent() {
        let matches = DeferredToolIndex.search("create a new Xcode project", in: catalog)
        #expect(matches.first?.name == "createXcodeProject")
    }

    @Test("camelCase names are searchable by their words")
    func splitsCamelCase() {
        // "index" only appears inside `indexWorkspace`'s name, never as its own
        // word, so this only works if the name is split.
        let matches = DeferredToolIndex.search("index the workspace", in: catalog)
        #expect(matches.first?.name == "indexWorkspace")
    }

    @Test("A name hit outranks a description hit")
    func nameBeatsDescription() {
        // "project" is in createXcodeProject's name and in nothing else's.
        let matches = DeferredToolIndex.search("project", in: catalog)
        #expect(matches.first?.name == "createXcodeProject")
    }

    @Test("An unrelated query matches nothing rather than guessing")
    func noSpuriousMatches() {
        #expect(DeferredToolIndex.search("send an email to my accountant", in: catalog).isEmpty)
    }

    @Test("An empty query lists everything")
    func emptyQueryLists() {
        #expect(DeferredToolIndex.search("", in: catalog).count == catalog.count)
    }

    @Test("Results are capped, so a search cannot undo the saving it exists for")
    func resultsAreCapped() {
        let many = (0..<40).map {
            ToolDeclaration(name: "buildThing\($0)", description: "Builds a thing numbered \($0).")
        }
        #expect(DeferredToolIndex.search("build a thing", in: many).count
                <= DeferredToolIndex.maxResults)
    }

    @Test("Ties break alphabetically, so repeated searches are stable")
    func stableOrdering() {
        let first = DeferredToolIndex.search("report", in: catalog).map(\.name)
        let second = DeferredToolIndex.search("report", in: catalog).map(\.name)
        #expect(first == second)
    }

    @Test("A summary carries the signature, marking optionals")
    func summaryShape() {
        let summary = DeferredToolIndex.summary(of: catalog[0])

        #expect(summary.hasPrefix("createXcodeProject("))
        #expect(summary.contains("name: string"))
        #expect(summary.contains("directory: string"))
        // Optional parameters are bracketed and sort last.
        #expect(summary.contains("[platform: macOS|iOS]"))
        // Only the first sentence of the description, not the whole guidance.
        #expect(summary.contains("Scaffolds a brand new Xcode project on disk."))
        #expect(summary.contains("Picks a template") == false)
    }
}
