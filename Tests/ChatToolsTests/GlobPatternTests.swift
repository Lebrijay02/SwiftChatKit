import Testing
@testable import ChatTools

@Suite("Glob patterns")
struct GlobPatternTests {

    @Test("A bare pattern matches at any depth")
    func bareMatchesAtAnyDepth() {
        #expect(GlobPattern.matches("View.swift", pattern: "*.swift"))
        #expect(GlobPattern.matches("Sources/App/View.swift", pattern: "*.swift"))
    }

    @Test("A bare pattern does not match a different extension")
    func extensionIsNotASubstring() {
        // The naive strip-and-`contains` matcher gets both of these wrong.
        #expect(!GlobPattern.matches("swifty.txt", pattern: "*.swift"))
        #expect(!GlobPattern.matches("View.swift.bak", pattern: "*.swift"))
    }

    @Test("A single star stops at a path separator")
    func singleStarDoesNotCrossDirectories() {
        #expect(GlobPattern.matches("Sources/View.swift", pattern: "Sources/*.swift"))
        #expect(!GlobPattern.matches("Sources/App/View.swift", pattern: "Sources/*.swift"))
    }

    @Test("A double star crosses directories")
    func doubleStarCrossesDirectories() {
        #expect(GlobPattern.matches("Sources/App/UI/View.swift", pattern: "Sources/**/*.swift"))
    }

    @Test("A double star also matches zero directories")
    func doubleStarMatchesNothing() {
        #expect(GlobPattern.matches("Sources/View.swift", pattern: "Sources/**/*.swift"))
    }

    @Test("A question mark matches exactly one character")
    func questionMark() {
        #expect(GlobPattern.matches("a1.txt", pattern: "a?.txt"))
        #expect(!GlobPattern.matches("a12.txt", pattern: "a?.txt"))
        #expect(!GlobPattern.matches("a/1.txt", pattern: "a?1.txt"))
    }

    @Test("Character classes match sets, ranges, and negations")
    func characterClasses() {
        #expect(GlobPattern.matches("a1.txt", pattern: "a[0-9].txt"))
        #expect(!GlobPattern.matches("ax.txt", pattern: "a[0-9].txt"))
        #expect(GlobPattern.matches("ax.txt", pattern: "a[!0-9].txt"))
        #expect(GlobPattern.matches("ab.txt", pattern: "a[bcd].txt"))
    }

    @Test("Matching ignores case")
    func caseInsensitive() {
        #expect(GlobPattern.matches("View.SWIFT", pattern: "*.swift"))
    }

    @Test("A literal pattern matches only itself")
    func literals() {
        #expect(GlobPattern.matches("Package.swift", pattern: "Package.swift"))
        #expect(!GlobPattern.matches("Packages.swift", pattern: "Package.swift"))
    }
}
