//
//  ChatAutoScrollTests.swift
//  SwiftChatKitTests
//
//  The follow/disengage state machine. Scroll smoothness itself can only be judged by
//  eye, but "does it stop following when the reader scrolls up" is testable and is the
//  part that actually loses people's place.
//

import Testing
@testable import ChatUI

@Suite("Chat auto-scroll")
@MainActor
struct ChatAutoScrollTests {

    @Test("Follows by default")
    func followsInitially() {
        #expect(ChatAutoScrollController().isFollowing)
    }

    @Test("Scrolling up disengages following")
    func manualScrollDisengages() {
        let controller = ChatAutoScrollController()
        controller.reportDistanceFromBottom(500)
        controller.userDidScroll()
        #expect(!controller.isFollowing)
    }

    @Test("A twitch near the bottom keeps following")
    func smallScrollKeepsFollowing() {
        let controller = ChatAutoScrollController()
        controller.reportDistanceFromBottom(10)
        controller.userDidScroll()
        #expect(controller.isFollowing)
    }

    @Test("Scrolling back to the bottom re-engages")
    func returningReEngages() {
        let controller = ChatAutoScrollController()
        controller.reportDistanceFromBottom(500)
        controller.userDidScroll()
        #expect(!controller.isFollowing)

        controller.reportDistanceFromBottom(0)
        #expect(controller.isFollowing)
    }

    @Test("Streaming while disengaged does not re-engage on its own")
    func streamingDoesNotReEngage() {
        let controller = ChatAutoScrollController()
        controller.reportDistanceFromBottom(500)
        controller.userDidScroll()

        // Content continuing to arrive must not drag the reader back down.
        controller.reportDistanceFromBottom(600)
        controller.reportDistanceFromBottom(700)
        #expect(!controller.isFollowing)
    }

    @Test("The jump affordance appears only once the reader is away and disengaged")
    func jumpAffordanceVisibility() {
        let controller = ChatAutoScrollController()
        #expect(!controller.isAwayFromBottom)

        controller.reportDistanceFromBottom(500)
        #expect(!controller.isAwayFromBottom, "still following, so no affordance yet")

        controller.userDidScroll()
        #expect(controller.isAwayFromBottom)
    }

    @Test("A negative offset is clamped rather than disengaging")
    func negativeOffsetClamped() {
        let controller = ChatAutoScrollController()
        // Bounce scrolling can push the anchor above the viewport bottom.
        controller.reportDistanceFromBottom(-120)
        controller.userDidScroll()
        #expect(controller.isFollowing)
    }
}
