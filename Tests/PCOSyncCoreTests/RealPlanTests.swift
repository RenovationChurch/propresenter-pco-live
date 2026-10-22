import XCTest
@testable import PCOSyncCore

// Weekend Gatherings, October 25, 2026 (plan 90700205), as Planning Center
// returns it, and the playlist names ProPresenter reported in the Oct 20 log.

let OCT25: [FakeItem] = [
    FakeItem("h1", "WALK IN", "header"),
    FakeItem("preroll", "PREROLL SLIDES", "item", "AUDIO/CG: Reno Atmosphere Playlist\n\nCorporate Preroll\nComms Preroll:\n1) Current Series \"Gospel of John\"\n3) Baptism Celebration today"),
    FakeItem("count", "5 MIN COUNTDOWN", "item"),
    FakeItem("h2", "OPENING", "header"),
    FakeItem("welcome", "WELCOME IN PERSON & ONLINE", "item"),
    FakeItem("h3", "WORSHIP", "header"),
    FakeItem("jtg1", "Just That Good", "song", "Alex lead"),
    FakeItem("jbtn", "Jesus Be The Name", "song", "Rachel / Chris lead"),
    FakeItem("wawn1", "What A Worthy Name", "song", "Rachel lead"),
    FakeItem("setup", "BAPTISM SETUP - Emily", "item"),
    FakeItem("bapt", "BAPTISMS - Joey", "item", "9:00 Baptisms\n1. Ezra Estupinan (child)\n2.\n3.\n\n10:50 Baptisms\n1. Jaxton Mosley (child)"),
    FakeItem("wawn2", "What A Worthy Name", "song", "Rachel lead"),
    FakeItem("h4", "WELCOME", "header"),
    FakeItem("hostw", "HOST WELCOME - Emily", "item", "MC MIC\n\n• Transition from worship\n• Welcome to all platforms\n• Message setup: Week 4 of Signs"),
    FakeItem("prayer", "HOST PRAYER", "item", "MC MIC"),
    FakeItem("h5", "BUMPER", "header"),
    FakeItem("bumper", "SERMON BUMPER", "item", "DREAM TEAM VIDEO"),
    FakeItem("h6", "MESSAGE", "header"),
    FakeItem("msg", "MESSAGE - Jon", "item", "Gospel of John Week 4\nSign: Ripple / Water\nTheme: Jesus meets us where we’ve been stuck.\n\nPASTOR MIC"),
    FakeItem("h7", "OFFERING", "header"),
    FakeItem("hostc", "HOST CLOSING - Jon", "item", "• Transition from message\n• Salvation & all other next steps TXT renonext to 97000 (SLIDE)"),
    FakeItem("h8", "CLOSING WORSHIP", "header"),
    FakeItem("jtg2", "Just That Good", "song", "Alex lead"),
]

/// Built by hand, as ProPresenter reported it.
let OCT25_PLAYLIST = ["PREROLL SLIDES", "5 MIN COUNTDOWN", "Just That Good", "Jesus Be The Name", "What A Worthy Name",
                      "Baptisms", "What A Worthy Name", "HOST WELCOME", "Bumper", "Gospel of John - Week 3", "Closing",
                      "Just That Good"]

func oct25Items() -> [PlanItem] {
    OCT25.enumerated().map { PlanItem(id: $1.id, title: $1.title, itemType: $1.itemType, sequence: $0 + 1, description: $1.description) }
}

func handBuilt(_ names: [String]) -> [PPPlaylistItem] {
    // Copies of a presentation share one uuid, as in ProPresenter.
    names.enumerated().map { PPPlaylistItem(uuid: "u\(names.firstIndex(of: $1)!)", name: $1, index: $0, type: "presentation", isPCO: false, isHidden: false) }
}

func oct25Harness(armed: Bool = true, playlist: [String] = OCT25_PLAYLIST, wall: String = "2026-10-25T13:05:00Z") -> Harness {
    let pco = FakePCO(items: OCT25)
    pco.planTimes = [("pt9", "service", "2026-10-25T13:00:00Z"), ("pt1050", "service", "2026-10-25T14:50:00Z")]
    let pp = FakeProPresenter(playlist: playlist.map { FakePPEntry($0, isPCO: false) })
    let h = Harness(armed: armed, pco: pco, pp: pp)
    h.clock.wall = iso(wall)
    return h
}

extension Harness {
    /// Fire the Nth playlist entry (for playlists with repeated names).
    @discardableResult
    func fireAt(_ index: Int) -> Decision {
        ppFake.activeIndex = index
        _ = engine.tick()
        clock.advance(1.5)
        return engine.tick()
    }

    var liveId: String? { pcoFake.current()?.1?.id }
    var livePt: String? { pcoFake.current()?.0 }
}

final class RealPlanMatchTests: XCTestCase {
    func testHandBuiltPlaylistLinesUp() {
        let m = Matcher(oct25Items())
        let pl = handBuilt(OCT25_PLAYLIST)
        let got = pl.map { m.match(PPRef(uuid: $0.uuid, name: $0.name, index: $0.index), pl).item?.id ?? "-" }
        XCTAssertEqual(got, ["preroll", "count", "jtg1", "jbtn", "wawn1", "bapt", "wawn2", "hostw", "bumper", "msg", "hostc", "jtg2"])
    }

    func testOtherNamesFromTheLog() {
        let m = Matcher(oct25Items())
        let pl = handBuilt(["Pre-roll", "Countdown", "Just That Good", "Baptisms", "HOST WELCOME", "Groundbreaking - Message", "Closing"])
        let got = pl.map { m.match(PPRef(uuid: $0.uuid, name: $0.name, index: $0.index), pl).item?.id ?? "-" }
        XCTAssertEqual(got, ["preroll", "count", "jtg1", "bapt", "hostw", "msg", "hostc"])
    }

    func testBaptismsWithoutPlaylist() {
        let r = Matcher(oct25Items()).match(ref("Baptisms"))
        XCTAssertEqual(r.item?.id, "bapt")
        XCTAssertEqual(r.method, "title")
    }

    func testMessageMatchesDescriptionAndFlagsWeek() {
        let pl = handBuilt(OCT25_PLAYLIST)
        let r = Matcher(oct25Items()).match(PPRef(uuid: "u9", name: "Gospel of John - Week 3", index: 9), pl)
        XCTAssertEqual(r.item?.id, "msg")
        XCTAssertEqual(r.method, "description")
        XCTAssertTrue(r.warning.contains("3") && r.warning.contains("4"), r.warning)
    }

    func testSongInPlaylistOnceOffersTheRepeat() {
        let pl = handBuilt(["Just That Good", "What A Worthy Name", "Baptisms", "HOST WELCOME"])
        let m = Matcher(oct25Items())
        let r = m.match(PPRef(uuid: "u1", name: "What A Worthy Name", index: 1), pl)
        XCTAssertEqual(r.item?.id, "wawn1")
        XCTAssertEqual(r.alternatives.map(\.id), ["wawn2"])
        let j = m.match(PPRef(uuid: "u0", name: "Just That Good", index: 0), pl)
        XCTAssertEqual([j.item!.id] + j.alternatives.map(\.id), ["jtg1", "jtg2"])
    }

    func testUnrelatedNamesStayUnmatched() {
        let m = Matcher(oct25Items())
        let pl = handBuilt(["Mystery Video", "Just That Good"])
        XCTAssertNil(m.match(PPRef(uuid: "u0", name: "Mystery Video", index: 0), pl).item)
        XCTAssertNil(m.match(ref("Hillsong Medley")).item)
    }

    func testRepeatedSongCopiesShareUUID() {
        let m = Matcher(oct25Items())
        let pl = handBuilt(OCT25_PLAYLIST)
        let at = { (n: Int) in m.match(PPRef(uuid: pl[n].uuid, name: pl[n].name, index: n), pl).item?.id }
        XCTAssertEqual(pl[4].uuid, pl[6].uuid)
        XCTAssertEqual(at(6), "wawn2")
        XCTAssertEqual(at(4), "wawn1")
        XCTAssertEqual(at(11), "jtg2")
    }

    func testHeadersAreNeverTargets() {
        // "Closing" must not land on the CLOSING WORSHIP header.
        XCTAssertEqual(Matcher(oct25Items()).match(ref("Closing")).item?.id, "hostc")
    }
}

final class RealPlanEngineTests: XCTestCase {
    func testWholeServiceWithDefaultSafety() {
        let h = oct25Harness()
        let expect = ["preroll", "count", "jtg1", "jbtn", "wawn1", "bapt", "wawn2", "hostw", "bumper", "msg", "hostc", "jtg2"]
        for (n, id) in expect.enumerated() {
            let d = h.fireAt(n)
            XCTAssertEqual(d.action, "moved", d.describe())
            XCTAssertEqual(h.liveId, id)
            XCTAssertEqual(h.livePt, "pt9")
        }
    }

    func testRepeatedSongPlayedFromOneSlide() {
        let h = oct25Harness(playlist: ["PREROLL SLIDES", "Just That Good", "Jesus Be The Name", "What A Worthy Name", "Baptisms", "HOST WELCOME"])
        h.pcoFake.place("jbtn")
        h.pcoFake.controller = ME
        XCTAssertEqual(h.fireAt(3).action, "moved")
        XCTAssertEqual(h.liveId, "wawn1")
        XCTAssertEqual(h.fireAt(4).action, "moved")
        XCTAssertEqual(h.liveId, "bapt")
        // Same slide again after the baptisms: the second copy, not a rewind.
        let d = h.fireAt(3)
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveId, "wawn2")
    }

    func testSecondCopyOfRepeatedSongMovesForward() {
        let h = oct25Harness()
        h.pcoFake.place("jbtn")
        h.pcoFake.controller = ME
        XCTAssertEqual(h.fireAt(4).action, "moved")
        XCTAssertEqual(h.liveId, "wawn1")
        h.fireAt(5)
        let d = h.fireAt(6)
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.liveId, "wawn2")
        h.pcoFake.place("hostc")
        let c = h.fireAt(11)
        XCTAssertEqual(c.action, "moved", c.describe())
        XCTAssertEqual(h.liveId, "jtg2")
    }

    func testNextServiceStartsOnItsOwn() {
        let h = oct25Harness()
        h.pcoFake.place("jtg2", "pt9")
        h.pcoFake.controller = ME
        h.clock.wall = iso("2026-10-25T14:35:00Z")  // 10:35, preroll for 10:50
        let d = h.fireAt(0)
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.livePt, "pt1050")
        XCTAssertEqual(h.liveId, "preroll")
        XCTAssertEqual(h.fireAt(1).action, "moved")
        XCTAssertEqual(h.livePt, "pt1050")
    }

    func testOverrunningFirstServiceStaysPut() {
        let h = oct25Harness()
        h.pcoFake.place("msg", "pt9")
        h.pcoFake.controller = ME
        h.clock.wall = iso("2026-10-25T14:32:00Z")  // inside the 10:50 lead, 9:00 still going
        let d = h.fireAt(10)  // Closing
        XCTAssertEqual(d.action, "moved", d.describe())
        XCTAssertEqual(h.livePt, "pt9")
        XCTAssertEqual(h.liveId, "hostc")
    }

    func testRunThroughNeverRecords() {
        let h = oct25Harness(wall: "2026-10-25T11:50:00Z")  // 7:50 run-through
        let d = h.fireAt(2)
        XCTAssertEqual(d.action, "skip", d.describe())
        XCTAssertTrue(d.reason.contains("service time"))
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
        // Mid-week test (like Oct 20) too.
        let t = oct25Harness(wall: "2026-10-20T13:06:00Z")
        XCTAssertEqual(t.fireAt(0).action, "skip")
        XCTAssertTrue(t.pcoFake.writes.isEmpty)
    }

    func testDryRunStillReportsOutsideServiceTimes() {
        let h = oct25Harness(armed: false, wall: "2026-10-20T13:06:00Z")
        let d = h.fireAt(5)
        XCTAssertEqual(d.action, "refused")  // not started -> Baptisms passes 5 matched items
        let c = h.fireAt(0)
        XCTAssertEqual(c.action, "dry_run", c.describe())
        XCTAssertTrue(c.reason.contains("not near a service time"))
    }

    func testSkippingRealSlidesStillNeedsConfirm() {
        let h = oct25Harness()
        h.pcoFake.place("jtg1")
        h.pcoFake.controller = ME
        let d = h.fireAt(9)  // straight to the message
        XCTAssertEqual(d.action, "refused", d.describe())
        XCTAssertTrue(h.pcoFake.writes.isEmpty)
    }

    func testDescribeShowsWarning() {
        let h = oct25Harness()
        h.pcoFake.place("bumper")
        h.pcoFake.controller = ME
        let d = h.fireAt(9)
        XCTAssertEqual(d.action, "moved")
        XCTAssertTrue(d.describe().contains("check: ProPresenter says 3 but the plan says 4"), d.describe())
    }
}

final class AutoPlanTests: XCTestCase {
    /// Two service types: a workshop (no songs) tonight, Christmas services tomorrow.
    func transport(xmasOnlyInPast: Bool = false) -> HTTPTransport {
        ClosureTransport { req in
            let p = req.path
            let st = "/services/v2/service_types"
            switch p {
            case st:
                return .json(["data": [["type": "ServiceType", "id": "10", "attributes": ["name": "Weekend Gatherings"]],
                                       ["type": "ServiceType", "id": "20", "attributes": ["name": "Other Events"]]]])
            case st + "/10/plans":
                return .json(["data": [["type": "Plan", "id": "sun", "attributes": ["dates": "December 27, 2026", "title": ""]]]])
            case st + "/20/plans" where xmasOnlyInPast:
                let xmas: JSONObject = ["type": "Plan", "id": "xmas", "attributes": ["dates": "December 23 & 24, 2026", "title": "Christmas"]]
                return .json(["data": req.queryValue("filter") == "past" ? [xmas] : []])
            case st + "/20/plans":
                return .json(["data": [["type": "Plan", "id": "workshop", "attributes": ["dates": "December 22, 2026", "title": "Vocal Workshop"]],
                                       ["type": "Plan", "id": "xmas", "attributes": ["dates": "December 23 & 24, 2026", "title": "Christmas"]]]])
            default:
                break
            }
            func times(_ ts: [String]) -> HTTPResponse {
                .json(["data": ts.enumerated().map { ["type": "PlanTime", "id": "t\($0)", "attributes": ["time_type": "service", "starts_at": $1]] }])
            }
            func items(_ song: Bool) -> HTTPResponse {
                .json(["data": [["type": "Item", "id": "i1", "attributes": ["title": song ? "O Holy Night" : "Warmups", "item_type": song ? "song" : "item", "sequence": 1]]]])
            }
            if p.hasSuffix("/sun/plan_times") { return times(["2026-12-27T14:00:00Z", "2026-12-27T15:50:00Z"]) }
            if p.hasSuffix("/workshop/plan_times") { return times(["2026-12-22T23:00:00Z"]) }
            if p.hasSuffix("/xmas/plan_times") { return times(["2026-12-23T22:00:00Z", "2026-12-24T20:00:00Z", "2026-12-24T22:00:00Z"]) }
            if p.hasSuffix("/workshop/items") { return items(false) }
            if p.contains("/items") { return items(true) }
            return HTTPResponse(status: 404)
        }
    }

    func resolve(_ now: String, _ s: PCOSettings = PCOSettings(), xmasOnlyInPast: Bool = false) throws -> PlanRef {
        let pco = try PCOClient(appId: FAKE_APP_ID, secret: FAKE_SECRET, transport: transport(xmasOnlyInPast: xmasOnlyInPast))
        return try pco.resolvePlan(s, now: iso(now))
    }

    func testSkipsPlansWithoutSongsAndCrossesServiceTypes() throws {
        let r = try resolve("2026-12-22T12:00:00Z")
        XCTAssertEqual(r, PlanRef(serviceTypeId: "20", planId: "xmas"))
        XCTAssertTrue(r.label.contains("Other Events"))
    }

    func testStaysOnMultiDayPlanUntilItsLastService() throws {
        XCTAssertEqual(try resolve("2026-12-24T22:30:00Z").planId, "xmas")
        XCTAssertEqual(try resolve("2026-12-25T03:00:00Z").planId, "sun")
    }

    func testMultiDayPlanFoundAmongPastPlansOnDayTwo() throws {
        XCTAssertEqual(try resolve("2026-12-24T19:45:00Z", xmasOnlyInPast: true).planId, "xmas")
    }

    func testLimitToServiceTypes() throws {
        XCTAssertEqual(try resolve("2026-12-22T12:00:00Z", PCOSettings(serviceTypeIds: ["10"])).planId, "sun")
    }

    func testNextModeStillUsesOneServiceType() throws {
        XCTAssertEqual(try resolve("2026-12-22T12:00:00Z", PCOSettings(serviceTypeId: "20", plan: "next")).planId, "workshop")
    }
}
