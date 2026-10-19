import XCTest
@testable import PCOSyncCore

final class EngineTests: XCTestCase {
    var h: Harness!

    override func setUp() {
        h = Harness()
    }

    func testNormalProgression() {
        var d = h.fire("Countdown")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Countdown")
        XCTAssertEqual(h.pcoFake.controller, ME)
        for (name, title) in [("Way Maker", "Way Maker"), ("Goodness Of God", "Goodness of God"), ("Build My Life", "Build My Life")] {
            d = h.fire(name)
            XCTAssertEqual(d.action, "moved", d.describe())
            XCTAssertEqual(h.liveTitle, title)
        }
    }

    func testRefiredCueNeverTouchesLive() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        h.fire("Way Maker")
        let writesBefore = h.pcoFake.writes.count
        let requestsBefore = h.pcoFake.requests.count
        for _ in 0..<5 {
            h.clock.advance(1.0)
            XCTAssertEqual(h.engine.tick().action, "unchanged")
        }
        XCTAssertEqual(h.pcoFake.writes.count, writesBefore)
        XCTAssertEqual(h.pcoFake.requests.count, requestsBefore)  // not even a read
    }

    func testAlreadyInSyncDoesNothing() {
        h.pcoFake.place("s2")
        h.pcoFake.controller = ME
        XCTAssertEqual(h.fire("Goodness Of God").action, "in_sync")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testJumpBackLandsOnTarget() {
        h.pcoFake.place("s3")
        h.pcoFake.controller = ME
        let d = h.fire("Way Maker")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Way Maker")
        XCTAssertEqual(h.pcoFake.writes.map { $0.1.components(separatedBy: "/").last! }, ["go_to_previous_item", "go_to_previous_item"])
    }

    func testSkipAheadWithinLimitAndHeadersSkipped() {
        h.pcoFake.place("i1")  // Countdown; header WORSHIP sits between
        h.pcoFake.controller = ME
        let d = h.fire("Goodness Of God")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(d.steps, 2)
        XCTAssertEqual(h.liveTitle, "Goodness of God")
    }

    func testWorksWhenNextDoesNotSkipHeaders() {
        let h = Harness(pco: FakePCO(skipHeaders: false))
        h.pcoFake.place("i1")
        h.pcoFake.controller = ME
        let d = h.fire("Way Maker")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Way Maker")
    }

    func testBigJumpRefusedUntilConfirmed() {
        h.pcoFake.place("i1")
        h.pcoFake.controller = ME
        XCTAssertEqual(h.fire("Doxology").action, "refused")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        _ = h.engine.command("confirm")
        h.clock.advance(0.5)
        let d = h.engine.tick()
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Doxology")
    }

    func testUnmatchedItemNeverMoves() {
        h.ppFake.playlist.append(FakePPEntry("Mystery Video", isPCO: false))
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        let d = h.fire("Mystery Video")
        XCTAssertEqual(d.action, "skip")
        XCTAssertTrue(d.reason.contains("unmatched"))
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        XCTAssertEqual(h.liveTitle, "Way Maker")
    }

    func testIgnoredItemNeverMoves() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        let d = h.fire("Pre-Service Loop")
        XCTAssertEqual(d.action, "skip")
        XCTAssertTrue(d.reason.contains("ignore list"))
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testDryRunNeverWrites() {
        let h = Harness(armed: false)
        for name in ["Countdown", "Way Maker", "Build My Life", "Sermon"] {
            let d = h.fire(name)
            XCTAssertTrue(["dry_run", "refused"].contains(d.action), d.describe())
        }
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        XCTAssertNil(h.pcoFake.cursor)
    }

    func testProPresenterUnreachableDoesNothing() {
        h.ppFake.reachable = false
        let d = h.engine.tick()
        XCTAssertEqual(d.action, "error")
        XCTAssertTrue(d.reason.contains("unreachable"))
        XCTAssertEqual(h.pcoFake.requests.last?.0, "GET")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testPCOTimeoutOnReadIsErrorThenRecovers() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        h.pcoFake.failQueue = Array(repeating: .transport("timed out"), count: 10)
        XCTAssertEqual(h.fire("Goodness Of God").action, "error")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        h.pcoFake.failQueue = []
        h.clock.advance(1)
        let d = h.engine.tick()  // error did not mark item handled, so it retries
        XCTAssertEqual(d.action, "moved", d.describe())
    }

    func testPCOTimeoutOnWriteIsNotRetried() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        h.ppFake.fire("Goodness Of God")
        _ = h.engine.tick()
        h.clock.advance(1.5)
        // live read OK, then the POST times out.
        var posts = 0
        let fake = h.pcoFake
        h.pcoFake.transport.handler = { req in
            if req.method == "POST" {
                posts += 1
                throw TransportError("timed out")
            }
            return try fake.handle(req)
        }
        XCTAssertEqual(h.engine.tick().action, "error")
        XCTAssertEqual(posts, 1)
    }

    func testRateLimit429IsRetried() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        h.ppFake.fire("Goodness Of God")
        _ = h.engine.tick()
        h.clock.advance(1.5)
        h.pcoFake.failQueue = [.status(429), .status(429)]
        let d = h.engine.tick()
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.sleeps, [1.0, 1.0])
    }

    func testOtherControllerIsNotDisplaced() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = "555"
        let d = h.fire("Goodness Of God")
        XCTAssertEqual(d.action, "refused")
        XCTAssertTrue(d.reason.contains("another person"))
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        XCTAssertEqual(h.pcoFake.controller, "555")
    }

    func testTakeOverFlagTakesControl() {
        let h = Harness(settings: SyncSettings(debounceSeconds: 1.0, takeOver: true, planRefreshSeconds: 0))
        h.pcoFake.place("s1")
        h.pcoFake.controller = "555"
        let d = h.fire("Goodness Of God")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.pcoFake.controller, ME)
    }

    func testTakeoverMidServiceStopsMoves() {
        h.fire("Countdown")
        h.pcoFake.controller = "555"  // a human grabs control
        XCTAssertEqual(h.fire("Way Maker").action, "refused")
        XCTAssertEqual(h.liveTitle, "Countdown")
    }

    func testReleaseOnlyWhenWeHoldControl() {
        h.fire("Countdown")
        XCTAssertEqual(h.pcoFake.controller, ME)
        h.engine.release()
        XCTAssertNil(h.pcoFake.controller)
        // If someone else holds it, release must not toggle (that would steal it).
        h.pcoFake.controller = "555"
        h.engine.release()
        XCTAssertEqual(h.pcoFake.controller, "555")
    }

    func testReleaseWhenSomeoneElseTookOver() {
        h.fire("Countdown")
        h.pcoFake.controller = "555"
        h.engine.release()
        XCTAssertEqual(h.pcoFake.controller, "555")
        XCTAssertEqual(h.pcoFake.writes.filter { $0.1.hasSuffix("toggle_control") }.count, 1)
    }

    func testReleaseNoopIfWeNeverTookControl() {
        h.pcoFake.controller = "555"
        h.engine.release()
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testDebounceIgnoresFlicker() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        h.fire("Way Maker")
        h.ppFake.fire("Doxology")
        XCTAssertEqual(h.engine.tick().action, "debounce")
        h.clock.advance(0.3)
        h.ppFake.fire("Way Maker")
        XCTAssertEqual(h.engine.tick().action, "debounce")
        h.clock.advance(2)
        XCTAssertEqual(h.engine.tick().action, "unchanged")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testSecondServiceTimeNeedsOperator() {
        h.pcoFake.place("s4", "pt9")  // end of 9:00
        h.pcoFake.controller = ME
        var d = h.fire("Countdown")  // 11:00 begins
        XCTAssertEqual(d.action, "refused")  // would rewind the 9:00 service
        XCTAssertTrue(d.reason.contains("next-service"))
        _ = h.engine.command("next-service")
        h.clock.advance(0.5)
        d = h.engine.tick()
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.pcoFake.current()?.0, "pt11")
        XCTAssertEqual(h.liveTitle, "Countdown")
        d = h.fire("Way Maker")
        XCTAssertEqual(d.action, "moved")
        XCTAssertEqual(h.pcoFake.current()?.0, "pt11")
    }

    func testNotStartedLiveStartsAtTarget() {
        XCTAssertEqual(h.fire("Countdown").action, "moved")
        XCTAssertEqual(h.pcoFake.current()?.0, "pt9")
    }

    func testPauseBlocksMoves() {
        _ = h.engine.command("pause")
        h.ppFake.fire("Countdown")
        h.clock.advance(5)
        XCTAssertEqual(h.engine.tick().action, "paused")
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testPlaylistFilter() {
        let h = Harness(settings: SyncSettings(debounceSeconds: 1.0, planRefreshSeconds: 0, playlistNameContains: "Oct 25"))
        let d = h.fire("Countdown")
        XCTAssertEqual(d.action, "skip")
        XCTAssertTrue(d.reason.contains("doesn't contain"))
    }

    func testDuplicateTitlesResolvedByOccurrence() {
        let items = [FakeItem("a", "Prayer", "item"), FakeItem("b", "Song A"), FakeItem("c", "Prayer", "item")]
        let pl = [FakePPEntry("Prayer"), FakePPEntry("Song A"), FakePPEntry("Prayer")]
        let h = Harness(pco: FakePCO(items: items), pp: FakeProPresenter(playlist: pl))
        h.pcoFake.place("b")
        h.pcoFake.controller = ME
        h.ppFake.activeIndex = 2
        _ = h.engine.tick()
        h.clock.advance(1.5)
        let d = h.engine.tick()
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.pcoFake.current()?.1?.id, "c")
    }

    func testLiveParkedOnServiceStartSlot() {
        h.pcoFake.controller = ME
        h.pcoFake.cursor = 0  // (pt9, service start)
        let d = h.fire("Countdown")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Countdown")
        XCTAssertEqual(h.pcoFake.writes.count, 1)
    }

    func testWorksWithoutServiceStartSlots() {
        let h = Harness(pco: FakePCO(serviceMarkers: false))
        let d = h.fire("Countdown")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Countdown")
    }

    func testDryRunReportsServiceStart() {
        let h = Harness(armed: false)
        h.pcoFake.cursor = 0
        let d = h.fire("Countdown")
        XCTAssertEqual(d.action, "dry_run")
        XCTAssertTrue(d.describe().contains("service start 1"), d.describe())
    }

    func testDryRunSimulatesProgress() {
        let h = Harness(armed: false)
        for name in ["Countdown", "Way Maker", "Goodness Of God", "Build My Life", "Welcome and Announcements", "Sermon", "Doxology"] {
            let d = h.fire(name)
            XCTAssertEqual(d.action, "dry_run", d.describe())
            XCTAssertLessThanOrEqual(d.steps, 2)
        }
        XCTAssertEqual(h.fire("Way Maker").action, "refused")  // jump back 5 is still refused, as armed would
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testDescribeFormat() {
        h.pcoFake.place("s1")
        h.pcoFake.controller = ME
        let d = h.fire("Goodness Of God")
        XCTAssertEqual(d.describe(), "[moved] ProPresenter 'Goodness Of God' -> PCO 'Goodness of God'; LIVE on 'Goodness of God' (service 1): moved in 1 step(s)")
    }

    func testPlanRefreshPicksUpEdits() {
        let h = Harness(settings: SyncSettings(debounceSeconds: 1.0, planRefreshSeconds: 60))
        h.pcoFake.items.append(FakeItem("s9", "Benediction"))
        h.ppFake.playlist.append(FakePPEntry("Benediction"))
        h.clock.advance(61)
        h.pcoFake.place("s4")
        h.pcoFake.controller = ME
        let d = h.fire("Benediction")
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveTitle, "Benediction")
    }
}
