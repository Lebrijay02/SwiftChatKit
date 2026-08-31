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

        // A scroll event disengages on arrival, before the layout it causes has
        // happened — the controller cannot yet know whether it moved anywhere.
        controller.userDidScroll()
        // The layout lands, the transcript turns out not to have gone anywhere, and
        // following re-arms. This is the twitch surviving, one frame later.
        controller.reportDistanceFromBottom(10)
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
        controller.reportDistanceFromBottom(-120)
        #expect(controller.isFollowing)
        #expect(!controller.isAwayFromBottom, "past the end is not away from it")
    }

    @Test("Viewport and anchor edges combine into a distance, in either order")
    func geometryPairComposes() {
        let controller = ChatAutoScrollController()

        // One edge alone says nothing; the distance stays at its initial pinned value.
        controller.reportAnchorTop(900)
        controller.userDidScroll()
        #expect(!controller.isAwayFromBottom, "one edge is not a measurement")

        // The anchor sits 400pt below the viewport's bottom edge: scrolled well up.
        controller.reportViewportBottom(500)
        #expect(controller.isAwayFromBottom)

        // And the anchor rising back to the viewport's edge re-arms following.
        controller.reportAnchorTop(500)
        #expect(controller.isFollowing)
    }

    @Test("A restored transcript stays in restore until it reports it arrived")
    func restoreEndsOnArrival() {
        let controller = ChatAutoScrollController()
        controller.beginRestore()
        #expect(controller.isRestoring)

        // Lazy rows measuring: the end of the transcript is still way below the fold.
        controller.reportDistanceFromBottom(2_400)
        #expect(controller.isRestoring, "still catching up")

        controller.reportDistanceFromBottom(0)
        #expect(!controller.isRestoring, "arrived, so the restore is over")
    }

    @Test("A scroll view reporting its own geometry supersedes the anchor's")
    func scrollGeometryWins() {
        let controller = ChatAutoScrollController()
        controller.reportViewportBottom(500)
        controller.reportDistanceFromBottom(400)
        controller.userDidScroll()
        #expect(controller.isAwayFromBottom)

        // A stale anchor measurement from the older path must not overwrite it.
        controller.reportAnchorTop(500)
        #expect(controller.isAwayFromBottom)
        #expect(!controller.isFollowing)
    }
}
